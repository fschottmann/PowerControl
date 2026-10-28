# PowerControl - 05-Core.Output.ps1
# output of actions: type names, grid focus, wait handle, Show-PowerControlOutput, deferred output, post script
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

# does not work, fix it
function Set-ColumnVisibility {
    param ($OutputGrid, $InvisibleColumns, $VisibleColumns)

    Write-DebugLog -Message 'Entering Set-ColumnVisibility function' -Level 1 -LogFileName 'ColumnVisibility.log' 

    $allColumns = $OutputGrid.Columns

    if ($InvisibleColumns.Count -gt 0) {
        Write-DebugLog -Message $('Processing InvisibleColumns: ' + $($InvisibleColumns -join ', ')) -Level 2 -LogFileName 'ColumnVisibility.log' 
        $allColumns | Where-Object { $InvisibleColumns -contains $_.Header } | ForEach-Object {
            Write-DebugLog -Message $('Hiding Column: ' + $_.Header) -Level 2 -LogFileName 'ColumnVisibility.log' 
            $_.Visibility = 'Collapsed'
        }
    }

    if ($VisibleColumns.Count -gt 0) {
        Write-DebugLog -Message $('Processing VisibleColumns: ' + $($VisibleColumns -join ', ')) -Level 2 -LogFileName 'ColumnVisibility.log' 
        $allColumns | Where-Object { $VisibleColumns -notcontains $_.Header } | ForEach-Object {
            Write-DebugLog -Message $('Hiding Column: ' + $_.Header) -Level 2 -LogFileName 'ColumnVisibility.log' 
            $_.Visibility = 'Collapsed'
        }
    }

    Write-DebugLog -Message 'Exiting Set-ColumnVisibility function' -Level 1 -LogFileName 'ColumnVisibility.log' 
}

function Show-MessageBox {
    param ([string]$Message)

    $xaml = @'
<Window
   xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
   xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
   MinWidth="200" Width="400" SizeToContent="Height"
   Title="PowerControl - MessageWindow" Topmost="True">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Name="MessageBox" TextWrapping="Wrap" Width="300"/>
        <Button Name="ButtonOK" Grid.Row="1" MinWidth="80" Height="22" Margin="0,10,0,0" HorizontalAlignment="Center">_OK</Button>
    </Grid>
</Window>
'@
    
    # Convert-XAMLtoWindow only exists inside action runspaces (main.xml), not in this script,
    # and $Window_XAML is removed after start-up. Parse the XAML directly instead.
    $messageWindow = [Windows.Markup.XamlReader]::Parse($xaml)
    $messageTheme = if ($Global:PowerControl.General.ThemeMode) { $Global:PowerControl.General.ThemeMode } else { $Global:PowerControl.General.Theme }
    if ($messageTheme -and $messageTheme -ne 'Classic') {
        try { $messageWindow.ThemeMode = [System.Windows.ThemeMode]::($messageTheme) } catch { }
    }
    $messageWindow.FindName('MessageBox').Text = $Message
    $messageWindow.FindName('ButtonOK').add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
    if ($null -ne $PowerControlWindow) { $messageWindow.Owner = $PowerControlWindow }

    [void]$messageWindow.ShowDialog()
}

function Add-DynamicTypeNames {
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [Object[]]$InputObject,
        
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Mappings
    )

    begin {
        $processedCount = 0

        # Compile every DisplayCondition exactly once. The former implementation ran
        # Invoke-Expression per row and per mapping, i.e. it re-parsed the same code
        # thousands of times for large outputs.
        $compiled = foreach ($mapping in $Mappings) {
            $condition = $mapping.DisplayCondition.Code
            if ([string]::IsNullOrWhiteSpace($condition)) { continue }

            if ($condition -match '\.(Where|ForEach)\(') {
                $condition = $condition -replace '(?<!\.(?:Where|ForEach)\([^{]*)\$_(?![^{]*\{)', '###PLACEHOLDER###'
            }
            $condition = $condition -replace '\$_', '$item'
            $condition = $condition.replace('###PLACEHOLDER###', '$_')

            try {
                [PSCustomObject]@{
                    Id          = $mapping.id
                    ScriptBlock = [ScriptBlock]::Create($condition)
                }
            }
            catch {
                Write-DebugLog -Message "DisplayCondition of $($mapping.id) does not parse and is ignored: $($_.Exception.Message)" -Level 1 -LogFileName 'PowerControl.log'
            }
        }
    }

    process {
        foreach ($item in $InputObject) {
            $processedCount++

            foreach ($entry in $compiled) {
                try {
                    if (& $entry.ScriptBlock) {
                        $item.PSObject.TypeNames.Insert(0, $entry.Id)
                    }
                }
                catch {
                    # one broken condition must not stop the classification of the remaining rows
                    Write-DebugLog -Message "DisplayCondition of $($entry.Id) failed on an item: $($_.Exception.Message)" -Level 3 -LogFileName 'PowerControl.log'
                }
            }

            $item
        }
    }

    end {
        Write-Verbose "Processed $processedCount items."
    }
}

function Set-DataGridCellFocus {
    <#
      needs adjustments like the datagrid switch
    #>
    if ($OutputGrid.Items.Count -gt 0 -and $OutputGrid.Columns.Count -gt 0) {
        $OutputGrid.UpdateLayout()

        $OutputGrid.Dispatcher.InvokeAsync({
            try {
                # Debug information

                # Determine the index and column to focus
                $focusIndex = if ($OutputGrid.SelectedIndex -ge 0) { $OutputGrid.SelectedIndex } else { 0 }
                $focusColumn = $OutputGrid.Columns | Where-Object { $_.Visibility -eq 'Visible' } | Select-Object -First 1

                #Write-Host "Focus Index: $focusIndex"
                #Write-Host "Focus Column: $($focusColumn.Header)"

                # Ensure the index is within bounds
                if ($focusIndex -ge $OutputGrid.Items.Count) {
                    $focusIndex = $OutputGrid.Items.Count - 1
                }

                # Set the selected index
                $OutputGrid.SelectedIndex = $focusIndex

                # Create and set the current cell
                if ($focusIndex -ge 0 -and $null -ne $focusColumn) {
                    $cellInfo = New-Object System.Windows.Controls.DataGridCellInfo(
                        $OutputGrid.Items[$focusIndex], $focusColumn)
                    $OutputGrid.CurrentCell = $cellInfo
                    $OutputGrid.ScrollIntoView($OutputGrid.SelectedItem)

                    # Attempt to focus the cell
                    $cell = $OutputGrid.ItemContainerGenerator.ContainerFromIndex($focusIndex)
                    if ($null -ne $cell) {
                        $cellContent = $focusColumn.GetCellContent($cell)
                        if ($null -ne $cellContent) {
                            $targetCell = $cellContent.Parent -as [System.Windows.Controls.DataGridCell]
                            if ($null -ne $targetCell) {
                                $targetCell.Focus()
                                [System.Windows.Input.Keyboard]::Focus($targetCell)
                            }
                        }
                    }
                }
            }
            catch {
                Write-Host "Error in Set-DataGridCellFocus: $_"
            }
        }, [System.Windows.Threading.DispatcherPriority]::Render)
    }
}

function Wait-PowerControlHandle {
    <#
      .SYNOPSIS
      Waits for the runspace of a history item to finish without freezing the WPF window.

      .DESCRIPTION
      Replaces the former Start-Sleep busy loops in Initialize-PostScript. On the UI thread a
      nested DispatcherFrame keeps pumping messages (redraw, resize, other clicks) while a
      DispatcherTimer polls the async handle. Off the UI thread it simply blocks on the handle.
      Returns $true when the handle completed, $false when the optional timeout elapsed first.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$HistoryItem,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = -1,
        [Parameter(Mandatory = $false)][int]$PollMs = 50
    )

    $handle = $HistoryItem.Thread.Handle
    if ($null -eq $handle -or $handle.IsCompleted) { return $true }

    $dispatcher = [System.Windows.Threading.Dispatcher]::FromThread([System.Threading.Thread]::CurrentThread)
    if ($null -eq $dispatcher) {
        if ($TimeoutMs -ge 0) { return $handle.AsyncWaitHandle.WaitOne($TimeoutMs) }
        [void]$handle.AsyncWaitHandle.WaitOne()
        return $true
    }

    # State travels in the timer's Tag. No GetNewClosure(): a closure runs in its own module scope and
    # does not see the script's functions (Write-DebugLog, Show-PowerControlOutput, ...).
    $state = @{
        Completed   = $false
        Frame       = [System.Windows.Threading.DispatcherFrame]::new()
        HistoryItem = $HistoryItem
        TimeoutMs   = $TimeoutMs
        Stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background, $dispatcher)
    $timer.Interval = [TimeSpan]::FromMilliseconds($PollMs)
    $timer.Tag = $state

    $timer.add_Tick({
        param($sender, $e)
        $s = $sender.Tag
        # the ThreadWatcher clears Thread.Handle after cleanup, so re-read it on every tick
        $current = $s.HistoryItem.Thread.Handle
        if ($null -eq $current -or $current.IsCompleted) {
            $s.Completed = $true
            $sender.Stop()
            $s.Frame.Continue = $false
        }
        elseif ($s.TimeoutMs -ge 0 -and $s.Stopwatch.ElapsedMilliseconds -ge $s.TimeoutMs) {
            $sender.Stop()
            $s.Frame.Continue = $false
        }
        elseif ($PowerControl.WatcherState.Closing -or $PowerControl.WatcherState.Stop) {
            # the main window is closing: a nested frame that keeps waiting (e.g. for a dialog of a
            # menu action) would keep ShowDialog from returning and the process alive
            $sender.Stop()
            $s.Frame.Continue = $false
        }
    })

    $timer.Start()
    try {
        [System.Windows.Threading.Dispatcher]::PushFrame($state.Frame)
    }
    finally {
        $timer.Stop()
    }

    return $state.Completed
}

function Show-PowerControlOutput {
    <#
      .SYNOPSIS
      Fills the output grid with the output of a history item and applies its column rules.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]$OutputGrid,
        [Parameter(Mandatory = $true)]$HistoryItem,
        [Parameter(Mandatory = $false)][switch]$LeaveAsIs,
        # set by the tab strip: a tab is being shown, do not fall back to the "current" tab
        [Parameter(Mandatory = $false)][switch]$FromTab
    )

    $output = @($HistoryItem.Output | Where-Object { $null -ne $_ })
    Write-DebugLog -Message "Showing $($output.Count) row(s) of $($HistoryItem.ID)" -Level 2 -LogFileName 'PostScript.log'
    $hasTabs = [bool](Get-Command Update-PowerControlOutputTabs -ErrorAction SilentlyContinue)

    $window = $PowerControl.SynchronizedWindow
    # the shell (if present): start page disappears, filter is reset (a tab switch keeps its own filter),
    # column profile of the previous menu is kept
    $startPage = if ($window) { $window.FindName('StartPage') } else { $null }
    $filterBox = if ($window) { $window.FindName('FilterBox') } else { $null }
    if ($null -ne $startPage) { $startPage.Visibility = [System.Windows.Visibility]::Collapsed }
    if ($null -ne $filterBox -and $filterBox.Text -and -not $FromTab) { $filterBox.Text = '' }
    if (Get-Command Save-PowerControlColumnProfile -ErrorAction SilentlyContinue) { Save-PowerControlColumnProfile }

    $OutputGrid.ItemsSource = $null
    $OutputGrid.Items.Clear()

    if ($output.Count -gt 0) {
        $mappings = $PowerControl.JsonCache.PCtrlItems.Where({ $null -ne $_.DisplayCondition.Code })
        if ($mappings.Count -gt 0) {
            Add-DynamicTypeNames -InputObject $output -Mappings $mappings | Out-Null
        }
        $OutputGrid.ItemsSource = $output
    }

    $OutputGrid.Columns | ForEach-Object { $_.CanUserSort = $true }
    if (Get-Command Restore-PowerControlColumnProfile -ErrorAction SilentlyContinue) { Restore-PowerControlColumnProfile -MenuId $HistoryItem.ID }
    $script:CurrentOutputMenuId = $HistoryItem.ID
    if (Get-Command Update-PowerControlRowCount -ErrorAction SilentlyContinue) { Update-PowerControlRowCount }

    if ($HistoryItem.DisplayProperty.Count -gt 0) {
        $OutputGrid.Columns.where({ $HistoryItem.DisplayProperty -notcontains $_.Header }).foreach({ $_.Visibility = [System.Windows.Visibility]::Collapsed })
    }
    if ($HistoryItem.ExcludeProperty.Count -gt 0) {
        $OutputGrid.Columns.where({ $HistoryItem.ExcludeProperty -contains $_.Header }).foreach({ $_.Visibility = [System.Windows.Visibility]::Collapsed })
    }

    if (-not $LeaveAsIs) {
        if ($OutputGrid.Items.Count -gt 0) {
            $OutputGrid.SelectedIndex = 0
        }
        else {
            Write-DebugLog -Message 'No results received, setting default message' -Level 2 -LogFileName 'PostScript.log'
            $placeholder = [PSCustomObject]@{ Message = 'Received no results' }
            $placeholder.PSObject.TypeNames.Insert(0, 'PowerControl.Placeholder')   # row count ignores it
            $OutputGrid.ItemsSource = @($placeholder)
            if (Get-Command Update-PowerControlRowCount -ErrorAction SilentlyContinue) { Update-PowerControlRowCount }
        }
    }
    if ($hasTabs) {
        if ($FromTab) {
            # the tab keeps its filter: re-apply it to the new rows
            if ($null -ne $filterBox -and $filterBox.Text) { Set-PowerControlGridFilter -Text $filterBox.Text }
        }
        else {
            # output of a sequence: the tab of the active menu is the context on screen
            Set-PowerControlShownTabFromContext
            Update-PowerControlOutputTabs
        }
    }
}

function Register-PowerControlDeferredOutput {
    <#
      .SYNOPSIS
      Shows the output of an action that finishes later (typically after a dialog) once it arrives.

      .DESCRIPTION
      Initialize-PostScript waits at most 480 ms for a child action. Dialog based actions such as
      "Edit DataGrid" produce their output only after the user closed the dialog, so their result
      never reached the grid. A UI timer now polls the action's handle and shows the output when it
      completes, as long as the action is still the active action of the current menu.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]$HistoryItem,
        [Parameter(Mandatory = $true)]$OutputGrid,
        [Parameter(Mandatory = $false)][int]$MaxMinutes = 30
    )

    # state in the timer's Tag instead of GetNewClosure(): a closure runs in a module scope that cannot
    # see the script's functions, which made the first version fail with "Write-DebugLog is not recognized"
    $timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Tag = @{
        HistoryItem = $HistoryItem
        OutputGrid  = $OutputGrid
        Deadline    = [DateTime]::Now.AddMinutes($MaxMinutes)
    }

    $timer.add_Tick({
        param($sender, $e)
        $s = $sender.Tag
        try {
            $handle = $s.HistoryItem.Thread.Handle
            $completed = ($null -eq $handle) -or $handle.IsCompleted

            if (-not $completed) {
                if ([DateTime]::Now -gt $s.Deadline) {
                    $sender.Stop()
                    Write-DebugLog -Message "Deferred output of $($s.HistoryItem.ID): giving up after the deadline, action still running" -Level 2 -LogFileName 'PostScript.log'
                }
                return
            }

            $sender.Stop()

            $output = @($s.HistoryItem.Output)
            if ($output.Count -eq 0 -or $output[0] -is [System.Boolean]) {
                # finished without rows (dialog cancelled, nothing to report): the breadcrumb entry goes and the
                # tab falls back to the menu rows (Get-PowerControlContextItem ignores actions without output)
                $uid = "$($s.HistoryItem.ID)_$($s.HistoryItem.Timestamp)"
                for ($i = 0; $i -lt $ActionBar.Children.Count; $i++) {
                    if ($ActionBar.Children[$i].Uid -eq $uid) { $ActionBar.Children.RemoveRange($i, $ActionBar.Children.Count - $i); $ActionBar.UpdateLayout(); break }
                }
                Write-DebugLog -Message "Deferred output of $($s.HistoryItem.ID): finished without output, breadcrumb entry removed" -Level 2 -LogFileName 'PostScript.log'
                return
            }

            [System.Threading.Monitor]::Enter($PowerControl.HistoryLock)
            try {
                $activeMenu = $PowerControl.History.where({ ($_.id -ceq $PowerControl.ActiveMenu.ID) -and ($_.TimeStamp -ceq $PowerControl.ActiveMenu.TimeStamp) }, 'First')[0]
            }
            finally { [System.Threading.Monitor]::Exit($PowerControl.HistoryLock) }

            $isStillActive = ($null -ne $activeMenu) -and ($activeMenu.ActiveAction.Id -ceq $s.HistoryItem.ID) -and ("$($activeMenu.ActiveAction.Timestamp)" -eq "$($s.HistoryItem.Timestamp)")
            if (-not $isStillActive) {
                Write-DebugLog -Message "Deferred output of $($s.HistoryItem.ID) not shown, another action is active" -Level 2 -LogFileName 'PostScript.log'
                return
            }

            Write-DebugLog -Message "Showing deferred output of $($s.HistoryItem.ID)" -Level 1 -LogFileName 'PostScript.log'
            Show-PowerControlOutput -OutputGrid $s.OutputGrid -HistoryItem $s.HistoryItem
            Set-DataGridCellFocus
        }
        catch {
            $sender.Stop()
            Write-DebugLog -Message "Deferred output failed for $($s.HistoryItem.ID): $_ | $($_.ScriptStackTrace)" -Level 1 -LogFileName 'UI.log'
        }
    })

    $timer.Start()
}

function Initialize-PostScript {
    <#
      .SYNOPSIS
      Post-processing on the UI thread after an action was started: waits for the result and shows it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]$OutputGrid,
        [Parameter(Mandatory = $true)][string]$ID,
        [Parameter(Mandatory = $true)][string]$TimeStamp,
        [Parameter(Mandatory = $false)][string]$ChangeActionButton = '',
        [Parameter(Mandatory = $false)][string]$MessageBox = '',
        [Parameter(Mandatory = $false)][switch]$LeaveAsIs
    )

    Write-DebugLog -Message 'Entering Initialize-PostScript function' -Level 1 -LogFileName 'PostScript.log'

    [System.Threading.Monitor]::Enter($PowerControl.HistoryLock)
    try {
        $PowerControlItem_ActiveMenu = $PowerControl.History.where({($_.id -ceq $PowerControl.ActiveMenu.ID) -and ($_.TimeStamp -ceq $PowerControl.ActiveMenu.TimeStamp)}, 'First')[0]
        $PowerControlItem = $PowerControl.History.where({($_.id -ceq $ID) -and ($_.TimeStamp -ceq $TimeStamp)}, 'First')[0]
    }
    finally { [System.Threading.Monitor]::Exit($PowerControl.HistoryLock) }

    if ($null -eq $PowerControlItem) {
        Write-DebugLog -Message "History item $ID / $TimeStamp not found, nothing to show" -Level 1 -LogFileName 'PostScript.log'
        return
    }

    if (($PowerControlItem.NodeType -eq 'Thread') -or ($PowerControlItem.NodeType -eq 'EditTreeView')) {
        # e.g. "Display Output": wait for the thread action and show what it collected
        Write-DebugLog -Message "$($PowerControlItem.NodeType) start and wait" -Level 2 -LogFileName 'PostScript.log'
        [void](Wait-PowerControlHandle -HistoryItem $PowerControlItem)
        if ($PowerControlItem.Output.Count -gt 0) {
            Show-PowerControlOutput -OutputGrid $OutputGrid -HistoryItem $PowerControlItem -LeaveAsIs:$LeaveAsIs
        }
        Write-DebugLog -Message "$($PowerControlItem.NodeType) finished" -Level 2 -LogFileName 'PostScript.log'
    }
    elseif ($PowerControl.ActiveMenu.ID -ceq $ID) {
        # a menu: its output replaces the grid content
        $OutputGrid.ItemsSource = $null
        $OutputGrid.Items.Clear()

        if ($null -ne $PowerControlItem_ActiveMenu) {
            [void](Wait-PowerControlHandle -HistoryItem $PowerControlItem_ActiveMenu)
            Show-PowerControlOutput -OutputGrid $OutputGrid -HistoryItem $PowerControlItem_ActiveMenu -LeaveAsIs:$LeaveAsIs
        }
    }
    elseif ($PowerControlItem_ActiveMenu.Children.Id -contains $ID) {
        # a child action of the current menu: short grace period, then show whatever it produced
        $completed = Wait-PowerControlHandle -HistoryItem $PowerControlItem -TimeoutMs 480

        if (($PowerControlItem.Output.Count -gt 0) -and ($PowerControlItem.Output[0] -isnot [System.Boolean])) {
            Show-PowerControlOutput -OutputGrid $OutputGrid -HistoryItem $PowerControlItem -LeaveAsIs:$LeaveAsIs
        }
        else {
            $index = $ActionBar.Children.IndexOf($($ActionBar.Children | Where-Object { $_.Uid -eq "$($PowerControlItem.id)_$($PowerControlItem.Timestamp)" }))
            # finished without output: the breadcrumb entry goes; a still running job keeps its entry
            if ($index -ge 0 -and $completed) {
                $ActionBar.Children.RemoveRange($index, $ActionBar.Children.Count - $index)
                $ActionBar.UpdateLayout()
            }

            if (-not $completed) {
                # still running (dialog, long job): show the result when it arrives
                Register-PowerControlDeferredOutput -HistoryItem $PowerControlItem -OutputGrid $OutputGrid
            }
        }
    }

    if ($ChangeActionButton) {
        Write-DebugLog -Message $('Changing action button content to: ' + $ChangeActionButton) -Level 2 -LogFileName 'PostScript.log'
        $ActionBar.Children | Where-Object { $_.uID -ceq $ID } | ForEach-Object { $_.Content = $ChangeActionButton }
    }

    if ($MessageBox) {
        Write-DebugLog -Message $('Displaying message box: ' + $MessageBox) -Level 2 -LogFileName 'PostScript.log'
        Show-MessageBox -Message $MessageBox
    }

    Set-DataGridCellFocus

    Write-DebugLog -Message 'Exiting Initialize-PostScript function' -Level 1 -LogFileName 'PostScript.log'
}

