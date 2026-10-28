# PowerControl - 04-Core.Jobs.ps1
# job runspaces: stop, watchers (history, UI update, thread)
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

function Stop-PowerControlThreads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [object]$HistoryItem
    )

    begin {
        $logMessage = if ($HistoryItem) {
            "Starting to stop PowerControl thread: $($HistoryItem.id)"
        } else {
            "Starting to stop all PowerControl threads"
        }
        Write-DebugLog $logMessage -Level 1 -LogFileName 'PowerControl.log'
    }

    process {
        # Take a snapshot under the lock so a concurrent Add/replace on the UI thread cannot
        # invalidate the enumeration.
        $historyToProcess = if ($HistoryItem) {
            @($HistoryItem)
        } else {
            [System.Threading.Monitor]::Enter($PowerControl.HistoryLock)
            try { @($PowerControl.History.ToArray()) } finally { [System.Threading.Monitor]::Exit($PowerControl.HistoryLock) }
        }

        foreach ($item in $historyToProcess) {
            Write-DebugLog "Processing thread: $($item.id)" -Level 2 -LogFileName 'PowerControl.log'

            try {
                $thread = $item.Thread

                # Stop the PowerShell instance if it's running. Bounded: a synchronous Stop() blocks until the
                # pipeline reacts, and a pipeline sitting in a modal dialog or a blocking .NET call never does.
                $stopped = $true
                if ($thread.PowerShell -and $thread.PowerShell.InvocationStateInfo.State -eq 'Running') {
                    Write-DebugLog "Stopping PowerShell instance for thread: $($item.id)" -Level 3 -LogFileName 'PowerControl.log'
                    $stopHandle = $thread.PowerShell.BeginStop($null, $null)
                    $stopped = $stopHandle.AsyncWaitHandle.WaitOne(3000)
                }

                # Wait for the handle to complete if it exists
                if ($stopped -and $thread.Handle) {
                    Write-DebugLog "Waiting for handle to complete for thread: $($item.id)" -Level 3 -LogFileName 'PowerControl.log'
                    [void]$thread.Handle.AsyncWaitHandle.WaitOne(2000)
                }

                if (-not $stopped) {
                    # Dispose() would block as well (it stops synchronously). The runspace thread is a background
                    # thread, so it dies with the process; leaking it is the lesser evil than a frozen shutdown.
                    Write-DebugLog "Runspace of $($item.id) did not stop within 3 s (blocked in a dialog or a native call), left behind without Dispose" -Level 1 -LogFileName 'PowerControl.log'
                    $PowerControl.WatcherState.LeakedRunspaces = [int]$PowerControl.WatcherState.LeakedRunspaces + 1
                    continue
                }

                # Surface errors from the runspace before it is thrown away. Until now the error
                # stream of the action runspace was never read, so a failing script (e.g. a save
                # blocked by an endpoint protection product) left no trace anywhere.
                if ($thread.PowerShell -and $thread.PowerShell.Streams.Error.Count -gt 0) {
                    $errorText = foreach ($err in $thread.PowerShell.Streams.Error) {
                        "Error occurred: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')`r`nAction: $($item.Name) [$($item.id)]`r`nMessage: $($err.Exception.Message)`r`nPosition: $($err.InvocationInfo.PositionMessage)`r`n"
                    }
                    try { [System.IO.File]::AppendAllText([System.IO.Path]::Combine($LogsPath, 'scripts.log'), ($errorText -join "`r`n") + "`r`n") } catch { }
                    Write-DebugLog "Runspace for $($item.id) reported $($thread.PowerShell.Streams.Error.Count) error(s), see scripts.log" -Level 1 -LogFileName 'PowerControl.log'
                    try { Add-PowerControlNotification -Source $item.Name -Message ($thread.PowerShell.Streams.Error[0].Exception.Message) } catch { }
                    # repeating jobs: the UI tick turns this into a tray balloon (Update-PowerControlRepeatState)
                    if ($item.PSObject.Properties['Repeat'] -and [int]$item.Repeat -gt 0) { try { $item | Add-Member -NotePropertyName LastError -NotePropertyValue ($thread.PowerShell.Streams.Error[0].Exception.Message) -Force } catch { } }
                }

                # Dispose of the PowerShell instance
                if ($thread.PowerShell) {
                    Write-DebugLog "Disposing PowerShell instance for thread: $($item.id)" -Level 3 -LogFileName 'PowerControl.log'
                    $thread.PowerShell.Dispose()
                }

                # Close and dispose of the runspace
                if ($thread.Runspace) {
                    if ($thread.Runspace.RunspaceStateInfo.State -eq 'Opened') {
                        Write-DebugLog "Closing runspace for thread: $($item.id)" -Level 3 -LogFileName 'PowerControl.log'
                        $thread.Runspace.Close()
                    }
                    Write-DebugLog "Disposing runspace for thread: $($item.id)" -Level 3 -LogFileName 'PowerControl.log'
                    $thread.Runspace.Dispose()
                }

                # Clear the thread references on the history item (the item itself stays in the history)
                # (not $historyItem: that would overwrite the -HistoryItem parameter and confuse the end block)
                [System.Threading.Monitor]::Enter($PowerControl.HistoryLock)
                try {
                    $trackedItem = $PowerControl.History.where({($_.id -eq $item.id) -and ($_.TimeStamp -eq $item.TimeStamp)}, 'First')[0]
                }
                finally { [System.Threading.Monitor]::Exit($PowerControl.HistoryLock) }

                if ($null -ne $trackedItem) {
                    $trackedItem.Thread.Powershell = $null
                    $trackedItem.Thread.Runspace = $null
                    $trackedItem.Thread.Handle = $null
                }

                Write-DebugLog "Thread stopped, cleaned up, and removed: $($item.id)" -Level 2 -LogFileName 'PowerControl.log'
            }
            catch {
                Write-DebugLog "Error occurred while stopping thread $($item.id): $_" -Level 1 -LogFileName 'PowerControl.log'
            }
        }
    }

    end {
        $logMessage = if ($HistoryItem) {
            "Finished stopping PowerControl thread: $($HistoryItem.id)"
        } else {
            "Finished stopping all PowerControl threads"
        }
        Write-DebugLog $logMessage -Level 1 -LogFileName 'PowerControl.log'
    }
}

function Start-HistoryWatcher {
    Write-DebugLog -Message "Starting History Watcher" -Level 1 -LogFileName 'PowerControl.log'

    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    
    @(
        [PSCustomObject]@{Name="DebugLevel"; Value=$script:DebugLevel},
        [PSCustomObject]@{Name="LogsPath"; Value=$script:LogsPath},
        [PSCustomObject]@{Name="PowerControl"; Value=$Global:PowerControl}
    ).ForEach({
        $initialSessionState.Variables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($_.Name, $_.Value, $null)
        )
    })

    @('Write-DebugLog').ForEach({
        $definition = Get-Content Function:$_ -ErrorAction Stop
        $initialSessionState.Commands.Add(
            [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($_, $definition)
        )
    })

    Write-DebugLog -Message "Initial session state configured" -Level 2 -LogFileName 'PowerControl.log'

    $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher' = @{
        Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host, $initialSessionState)
    }

    $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.Runspace.ApartmentState = "MTA"
    $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.Runspace.ThreadOptions = "Default"
    $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.Runspace.Open()
    
    Write-DebugLog -Message "Runspace created and opened" -Level 2 -LogFileName 'PowerControl.log'

    $Code = {
        $updateInterval = 3750
        $lastUpdate = [DateTime]::MinValue

        while (-not $PowerControl.WatcherState.Stop) {
            try {
                $currentTime = [DateTime]::Now

                if (($currentTime - $lastUpdate).TotalMilliseconds -ge $updateInterval) {
                    $lastUpdate = $currentTime

                    if ($null -ne $PowerControl -and $null -ne $PowerControl.History) {
                        # The whole read-modify-write runs under the shared lock. Without it the UI
                        # thread could Add() a new item while this loop computed its filtered copy,
                        # and the assignment below silently dropped the new item.
                        [System.Threading.Monitor]::Enter($PowerControl.HistoryLock)
                        try {
                            $PowerControlItem = $PowerControl.History | Where-Object {($_.id -ceq $PowerControl.ActiveMenu.ID) -and ($_.TimeStamp -ceq $PowerControl.ActiveMenu.TimeStamp)}

                            if($PowerControlItem.ActiveAction.count -gt 0){
                                $PowerControlItem = $PowerControl.History | Where-Object { ($_.id -eq $PowerControlItem.ActiveAction.ID) -and ($_.TimeStamp -eq $PowerControlItem.ActiveAction.Timestamp)}
                            }

                            $currentTimestamp = [int][double]::Parse((Get-Date -UFormat "%s"))

                            $keep = @($PowerControl.History | Where-Object {
                                $item = $_
                                $isNotCompleted = $item.Thread.Handle.IsCompleted -eq $false
                                $isPinned = $item.Pinned -eq $true
                                $timestampDifference = $currentTimestamp - [int]$item.TimeStamp

                                ($PowerControlItem.ID -ceq $item.ID -and $PowerControlItem.TimeStamp -eq $item.TimeStamp) -or
                                (($null -ne $item.Output -and $item.Output.count -gt 0) -and ($item.NodeType -notin $PowerControl.General.TransientNodeTypes)) -or
                                $isNotCompleted -or
                                $isPinned -or
                                ($timestampDifference -le 0)
                            })

                            if ($keep.Count -ne $PowerControl.History.Count) {
                                $PowerControl.History = [System.Collections.ArrayList]$keep
                            }
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($PowerControl.HistoryLock)
                        }
                    }
                }
            }
            catch {
                Write-DebugLog -Message "HistoryWatcher: unexpected error in the update loop: $_" -Level 1 -LogFileName 'PowerControl.log'
            }

            Start-Sleep -Milliseconds 100
        }
        Write-DebugLog -Message "HistoryWatcher loop ended" -Level 1 -LogFileName 'PowerControl.log'
    }

    $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.PowerShell = [PowerShell]::Create().AddScript($Code)
    $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.PowerShell.Runspace = $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.Runspace
    $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.Handle = $Global:PowerControl.'PowerControlThreads'.'HistoryWatcher'.PowerShell.BeginInvoke()

    Write-DebugLog -Message "History Watcher started" -Level 1 -LogFileName 'PowerControl.log'
}

function Start-UIUpdateWatcher {
    <#
      .SYNOPSIS
      Keeps the job list (StatusDataGrid) in sync with $PowerControl.History.

      .DESCRIPTION
      Rows are updated in place: new jobs are added, finished ones removed, changed properties
      written into the existing row objects and the grid is refreshed only when something changed.
      The former version serialised every job's complete output to JSON each tick and replaced the
      whole ItemsSource, which reset selection and moved the keyboard focus while a running job
      reported progress. Output previews are built from the first two rows only.
    #>
    Write-DebugLog -Message "Starting UIUpdate Watcher" -Level 1 -LogFileName 'PowerControl.log'

    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    @(
        [PSCustomObject]@{Name="DebugLevel"; Value=$script:DebugLevel},
        [PSCustomObject]@{Name="LogsPath"; Value=$script:LogsPath},
        [PSCustomObject]@{Name="PowerControl"; Value=$Global:PowerControl}
    ).ForEach({
        $initialSessionState.Variables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($_.Name, $_.Value, $null)
        )
    })

    @('Write-DebugLog','Format-JsonOutput','Add-DynamicTypeNames').ForEach({
        $definition = Get-Content Function:$_ -ErrorAction Stop
        $initialSessionState.Commands.Add(
            [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($_, $definition)
        )
    })

    Write-DebugLog -Message "Initial session state configured" -Level 2 -LogFileName 'PowerControl.log'

    $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher' = @{
        Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host, $initialSessionState)
    }

    $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.Runspace.ApartmentState = "STA"
    $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.Runspace.ThreadOptions = "Default"
    $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.Runspace.Open()

    Write-DebugLog -Message "Runspace created and opened" -Level 2 -LogFileName 'PowerControl.log'

    $Code = {
        $updateInterval = 2000
        $lastUpdate = [DateTime]::MinValue
        $transientTypes = @($PowerControl.General.TransientNodeTypes)
        $previewCache = @{}   # job key -> @{ Output (reference); Preview }: the JSON preview is rebuilt only when the output object changed

        while (-not $PowerControl.WatcherState.Stop) {
            try {
                $currentTime = [DateTime]::Now

                if (($currentTime - $lastUpdate).TotalMilliseconds -ge $updateInterval) {
                    $lastUpdate = $currentTime

                    if ($null -ne $PowerControl -and $null -ne $PowerControl.History) {
                        [System.Threading.Monitor]::Enter($PowerControl.HistoryLock)
                        try { $historySnapshot = @($PowerControl.History.ToArray()) } finally { [System.Threading.Monitor]::Exit($PowerControl.HistoryLock) }

                        # desired state of the job list, computed off the UI thread
                        $desiredRows = @(foreach ($h in $historySnapshot) {
                            if ($h.NodeType -in $transientTypes) { continue }

                            $preview = $false
                            if ($null -ne $h.Output -and $h.Output.Count -gt 0) {
                                $cacheKey = "$($h.ID)|$($h.Timestamp)"
                                $cached = $previewCache[$cacheKey]
                                if ($null -ne $cached -and [object]::ReferenceEquals($cached.Output, $h.Output)) { $preview = $cached.Preview }
                                else {
                                    $preview = Format-JsonOutput -Object @($h.Output | Select-Object -First 2) -MaxLength 250
                                    $previewCache[$cacheKey] = @{ Output = $h.Output; Preview = $preview }
                                }
                            }

                            $running = $null -ne $h.Thread -and $null -ne $h.Thread.Handle -and -not $h.Thread.Handle.IsCompleted
                            $repeatSeconds = if ($h.PSObject.Properties['Repeat']) { [int]$h.Repeat } else { 0 }
                            $every = if ($repeatSeconds -le 0) { '' } elseif ($repeatSeconds -lt 60) { " · every $repeatSeconds s" } elseif ($repeatSeconds -lt 3600) { " · every $([math]::Round($repeatSeconds / 60, 1)) min" } else { " · every $([math]::Round($repeatSeconds / 3600, 1)) h" }
                            [PSCustomObject]@{
                                Name      = $h.Name
                                ID        = $h.ID
                                TimeStamp = $h.Timestamp
                                Pinned    = $h.Pinned
                                Running   = $running
                                # display columns of the job list
                                State     = "$(if ($running) { 'running' } elseif ($null -ne $h.Output -and $h.Output.Count -gt 0) { 'finished' } else { 'no output' })$every$(if ($h.PSObject.Properties['RunCount'] -and [int]$h.RunCount -gt 1) { " · run $([int]$h.RunCount)" })"
                                History   = $(if ($h.PSObject.Properties['OutputHistory'] -and $null -ne $h.OutputHistory) { @($h.OutputHistory).Count } else { 0 })
                                Pin       = if ($h.Pinned) { '●' } else { '' }
                                Started   = $(try { [DateTimeOffset]::FromUnixTimeSeconds([long][double]$h.Timestamp).ToLocalTime().ToString('HH:mm:ss') } catch { "$($h.Timestamp)" })
                                # Rerun / Repeat update LastRun on the history item (the Timestamp stays, it is the job's identity)
                                LastRun   = $(if ($h.PSObject.Properties['LastRun'] -and $h.LastRun) { try { ([datetime]$h.LastRun).ToString('HH:mm:ss') } catch { '' } } else { '' })
                                Output    = $preview
                            }
                        })

                        # forget previews of jobs that left the history
                        if ($previewCache.Count -gt 0) {
                            $liveKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@($historySnapshot | ForEach-Object { "$($_.ID)|$($_.Timestamp)" }))
                            foreach ($staleKey in @($previewCache.Keys)) { if (-not $liveKeys.Contains($staleKey)) { $previewCache.Remove($staleKey) } }
                        }

                        if ($desiredRows.Count -gt 0) {
                            $statusMappings = $PowerControl.JsonCache.PCtrlItems.Where({ ($null -ne $_.DisplayCondition.Code) -and ($_.type -eq 'Thread' -or $_.type -eq 'EditTreeView') })
                            if ($statusMappings.Count -gt 0) {
                                Add-DynamicTypeNames -InputObject $desiredRows -Mappings $statusMappings | Out-Null
                            }
                        }

                        $dispatcher = if ($null -ne $PowerControl.SynchronizedWindow) { $PowerControl.SynchronizedWindow.Dispatcher } else { $null }
                        if ($null -ne $dispatcher -and -not $dispatcher.HasShutdownStarted -and -not $PowerControl.WatcherState.Stop) {
                            # bounded Invoke: after the window closed nobody pumps the dispatcher, an unbounded call would hang the shutdown
                            $dispatcher.Invoke([System.Action]{
                                $StatusDataGrid = $PowerControl.SynchronizedWindow.FindName('StatusDataGrid')
                                if ($null -eq $StatusDataGrid) { return }

                                $source = $StatusDataGrid.ItemsSource
                                if ($source -isnot [System.Collections.ObjectModel.ObservableCollection[object]]) {
                                    $source = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
                                    $StatusDataGrid.ItemsSource = $source
                                }

                                $changed = $false
                                $existing = @{}
                                foreach ($row in $source) { $existing["$($row.ID)_$($row.TimeStamp)"] = $row }
                                $seen = @{}

                                foreach ($desired in $desiredRows) {
                                    $key = "$($desired.ID)_$($desired.TimeStamp)"
                                    $seen[$key] = $true

                                    if ($existing.ContainsKey($key)) {
                                        $row = $existing[$key]
                                        foreach ($property in 'Name', 'Pinned', 'Running', 'State', 'Pin', 'LastRun', 'History', 'Output') {
                                            if ("$($row.$property)" -cne "$($desired.$property)") {
                                                $row.$property = $desired.$property
                                                $changed = $true
                                            }
                                        }
                                        # dynamic type names drive the context menu / key bindings of the row
                                        if (($row.PSObject.TypeNames -join '|') -ne ($desired.PSObject.TypeNames -join '|')) {
                                            $row.PSObject.TypeNames.Clear()
                                            foreach ($typeName in $desired.PSObject.TypeNames) { $row.PSObject.TypeNames.Add($typeName) }
                                            $changed = $true
                                        }
                                    }
                                    else {
                                        $source.Add($desired)
                                        $changed = $true
                                    }
                                }

                                for ($i = $source.Count - 1; $i -ge 0; $i--) {
                                    $key = "$($source[$i].ID)_$($source[$i].TimeStamp)"
                                    if (-not $seen.ContainsKey($key)) {
                                        $source.RemoveAt($i)
                                        $changed = $true
                                    }
                                }

                                if ($changed) {
                                    # row objects are the same instances, so selection and focus survive the refresh
                                    $StatusDataGrid.Items.Refresh()
                                }
                            }, [System.Windows.Threading.DispatcherPriority]::Background, [System.Threading.CancellationToken]::None, [TimeSpan]::FromSeconds(3))
                        }
                    }
                }
            }
            catch {
                Write-DebugLog -Message "UIUpdateWatcher: unexpected error in the update loop: $_" -Level 1 -LogFileName 'PowerControl.log'
            }

            Start-Sleep -Milliseconds 100
        }
        Write-DebugLog -Message "UIUpdateWatcher loop ended" -Level 1 -LogFileName 'PowerControl.log'
    }

    $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.PowerShell = [PowerShell]::Create().AddScript($Code)
    $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.PowerShell.Runspace = $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.Runspace
    $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.Handle = $Global:PowerControl.'PowerControlThreads'.'UIUpdateWatcher'.PowerShell.BeginInvoke()

    Write-DebugLog -Message "UIUpdate Watcher started" -Level 1 -LogFileName 'PowerControl.log'
}


function Start-ThreadWatcher {
    Write-DebugLog -Message "Starting Thread Watcher" -Level 1 -LogFileName 'PowerControl.log'

    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    
    @(
        [PSCustomObject]@{Name="DebugLevel"; Value=$script:DebugLevel},
        [PSCustomObject]@{Name="LogsPath"; Value=$script:LogsPath},
        [PSCustomObject]@{Name="PowerControl"; Value=$Global:PowerControl}
    ).ForEach({
        $initialSessionState.Variables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($_.Name, $_.Value, $null)
        )
    })

    @('Stop-PowerControlThreads', 'Write-DebugLog').ForEach({
        $definition = Get-Content Function:$_ -ErrorAction Stop
        $initialSessionState.Commands.Add(
            [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($_, $definition)
        )
    })

    Write-DebugLog -Message "Initial session state configured" -Level 2 -LogFileName 'PowerControl.log'

    $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher' = @{
        Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host, $initialSessionState)
    }
    $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.Runspace.ApartmentState = "MTA"
    $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.Runspace.ThreadOptions = "Default"
    $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.Runspace.Open()
    
    Write-DebugLog -Message "Runspace created and opened" -Level 2 -LogFileName 'PowerControl.log'

    $Code = {
        $updateInterval = 3750

        while (-not $PowerControl.WatcherState.Stop) {
            try {
                [System.Threading.Monitor]::Enter($PowerControl.HistoryLock)
                try { $historySnapshot = @($PowerControl.History.ToArray()) } finally { [System.Threading.Monitor]::Exit($PowerControl.HistoryLock) }

                $historySnapshot.Where({
                    $_.Thread.PowerShell -and $_.Thread.PowerShell.InvocationStateInfo.State -in @('Completed', 'Failed', 'Stopped')
                }).ForEach({
                    Stop-PowerControlThreads -HistoryItem $_
                })
            }
            catch {
                Write-DebugLog -Message "ThreadWatcher: unexpected error: $_" -Level 1 -LogFileName 'PowerControl.log'
            }

            # sleep in small slices so a stop request is honoured quickly
            $waited = 0
            while ($waited -lt $updateInterval -and -not $PowerControl.WatcherState.Stop) {
                Start-Sleep -Milliseconds 250
                $waited += 250
            }
        }
        Write-DebugLog -Message "ThreadWatcher loop ended" -Level 1 -LogFileName 'PowerControl.log'
    }

    $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.PowerShell = [PowerShell]::Create().AddScript($Code)
    $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.PowerShell.Runspace = $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.Runspace
    $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.Handle = $Global:PowerControl.'PowerControlThreads'.'ThreadWatcher'.PowerShell.BeginInvoke()

    Write-DebugLog -Message "Thread Watcher started" -Level 1 -LogFileName 'PowerControl.log'
}

function Stop-PowerControlWatchers {
    <#
      .SYNOPSIS
      Ends the three watcher runspaces (ThreadWatcher, UIUpdateWatcher, HistoryWatcher).

      .DESCRIPTION
      Previously these runspaces ran endless loops and were never disposed, so they kept
      running after the main window was closed. The loops now observe the shared stop flag;
      this function sets it, waits briefly and then disposes PowerShell instance and runspace.
    #>
    [CmdletBinding()]
    param()

    Write-DebugLog -Message "Stopping watcher runspaces" -Level 1 -LogFileName 'PowerControl.log'
    $Global:PowerControl.WatcherState.Stop = $true

    foreach ($name in 'ThreadWatcher', 'UIUpdateWatcher', 'HistoryWatcher') {
        $watcher = $Global:PowerControl.PowerControlThreads.$name
        if ($null -eq $watcher) { continue }

        try {
            if ($watcher.Handle -and -not $watcher.Handle.IsCompleted) {
                [void]$watcher.Handle.AsyncWaitHandle.WaitOne(2000)
            }
            if ($watcher.PowerShell) {
                if ($watcher.PowerShell.InvocationStateInfo.State -eq 'Running') { $watcher.PowerShell.Stop() }
                $watcher.PowerShell.Dispose()
            }
            if ($watcher.Runspace) {
                if ($watcher.Runspace.RunspaceStateInfo.State -eq 'Opened') { $watcher.Runspace.Close() }
                $watcher.Runspace.Dispose()
            }
            Write-DebugLog -Message "$name stopped and disposed" -Level 2 -LogFileName 'PowerControl.log'
        }
        catch {
            Write-DebugLog -Message "Error while stopping ${name}: $_" -Level 1 -LogFileName 'PowerControl.log'
        }
        finally {
            $Global:PowerControl.PowerControlThreads.$name = $null
        }
    }
}

