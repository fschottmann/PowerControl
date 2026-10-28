# PowerControl - 06-Core.Sequence.ps1
# history/environment per element, Invoke-PowerControlSequence, breadcrumb buttons, menu visibility, key bindings, context menus
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

function Get-PowerControlProtectedHistoryKeys {
    <# keys ("id_timestamp") of the child actions of pinned menus: they are the context of a pinned tab and survive pruning. Caller holds HistoryLock. #>
    $keys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($menu in @($PowerControl.History)) {
        if ($menu.Pinned -ne $true -or $menu.NodeType -notin 'Menu', 'MenuBar') { continue }
        foreach ($child in @($menu.Children)) { if ($null -ne $child) { [void]$keys.Add("$($child.Id)_$($child.Timestamp)") } }
    }
    , $keys
}

#not optimized
function Initialize-ScriptEnvironment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$ID,
        [Parameter(Mandatory = $false)][object]$SelectedEntries,
        [Parameter(Mandatory = $false)][switch]$NoButton
    )   
    
    $jsonElement = $PowerControl.JsonCache.PCtrlItems | Where-Object {$_.id -eq $ID}

    if ($null -eq $jsonElement) {
			Write-DebugLog -Message $('No JSON element found for ID: ' + $ID) -Level 2 -LogFileName 'ScriptEnvironment.log' 
      return
    }
    
    Set-Variable -Name jsonElement -Value $jsonElement -Option ReadOnly

    # Every mutation of the history below runs under the shared lock (the watcher runspaces
    # prune the same list). The function returns the history item it created or re-used, so
    # callers no longer have to guess it from $PowerControl.History[-1].
    [System.Threading.Monitor]::Enter($Global:PowerControl.HistoryLock)
    try {

    if (@('MenuBar','Menu') -notcontains $jsonElement.type) {
        $PowerControl_HistoryItem = [PSCustomObject]@{
            ID = $jsonElement.ID
            Name = ([string]$jsonElement.Label) -replace '_', ''   # without the menu access-key underscore
            NodeType = $jsonElement.type
            SelectedEntries = $(if ($null -ne $SelectedEntries) { $SelectedEntries } else { $null })
            Output = $null
            ExcludeProperty = $null
            DisplayProperty = $null
            Parent = $null
            ActiveAction = $null
            Pinned = $false
            Timestamp = $(Get-Date -UFormat %s)
            Children = @()
            Thread = [PSCustomObject]@{
                'PowerShell' = $null
                'Runspace' = $null
                'Handle' = $null
                'Ports' = @()
            }
        }
        
        # Add the new entry to the history array list
        $Global:PowerControl.History.Add($PowerControl_HistoryItem) | Out-Null

        if(($null -ne $Global:PowerControl.ActiveMenu.ID) -and ($jsonElement.type -notin 'OutputGridHeaderMenu', 'Command')) {
            # Note: .where() returns a collection; setting a property on that collection fails
            # silently inside event handlers. That is why Children/ActiveAction were "sometimes
            # empty". Resolve the single item first, then assign.
            $activeMenuItem = $Global:PowerControl.History.where({($_.id -ceq $Global:PowerControl.ActiveMenu.ID) -and ($_.TimeStamp -eq $Global:PowerControl.ActiveMenu.TimeStamp)}, 'First')[0]
            if ($null -ne $activeMenuItem) {
                $activeMenuItem.Children += @($PowerControl_HistoryItem | Select-Object Id, TimeStamp)
                $activeMenuItem.ActiveAction = $PowerControl_HistoryItem | Select-Object Id, TimeStamp
            }
        }
    }
    else {
        <#
          change windows title according menu and action
          somelike menue - action and so on
        #>
        # a pinned entry of the same menu is left alone (its output stays available as a tab); the new run
        # gets its own history item instead of resetting the pinned one
        $existingMenuItem = $Global:PowerControl.History.where({ ($_.ID -ceq $ID) -and ($_.Pinned -ne $true) }, 'First')[0]

        if ($null -ne $existingMenuItem) {

            <#
              if same action goes called remove any actions exclude pinned or still running
            #>

            $itemsToRemove = @()
            $existingMenuItem.Children | ForEach-Object {
                $itemsToRemove += @("$($_.id)_$($_.Timestamp)")
            }

            $existingMenuItem.Output = $null
            $existingMenuItem.Timestamp = $(Get-Date -UFormat %s)
            $existingMenuItem.ActiveAction = $null
            $existingMenuItem.Children = @()

            $PowerControl_HistoryItem = $existingMenuItem

            $itemsNotToRemove = @()
            $itemsNotToRemove += @("$($PowerControl_HistoryItem.id)_$($PowerControl_HistoryItem.Timestamp)")            
            
            # actions that belong to a pinned menu stay with it (their output is that tab's context)
            $protectedKeys = Get-PowerControlProtectedHistoryKeys
            $PowerControl.History = [System.Collections.ArrayList](@($PowerControl.History | Where-Object {
                $item = $_
                $key = "$($item.id)_$($item.Timestamp)"
                $isNotCompleted = $item.Thread.Handle.IsCompleted -eq $false
                $isPinned = $item.Pinned -eq $true

                $itemsNotToRemove.Contains($key) -or
                $protectedKeys.Contains($key) -or
                ($itemsToRemove.Contains($key) -and ($isNotCompleted -or $isPinned)) -or
                $isNotCompleted -or
                $isPinned
            }))
            
        }
        else {
            $PowerControl_HistoryItem = [PSCustomObject]@{
                    ID = $jsonElement.ID
                    Name = ([string]$jsonElement.Label) -replace '_', ''   # without the menu access-key underscore
                    NodeType = $jsonElement.type
                    SelectedEntries = $null 
                    Output = $null
                    ExcludeProperty = $null
                    DisplayProperty = $null
                    Parent = $null
                    ActiveAction = $null
                    Pinned = $false
                    Timestamp = $(Get-Date -UFormat %s)
                    Children = @()
                    Thread = [PSCustomObject]@{
                        'PowerShell' = $null
                        'Runspace' = $null
                        'Handle' = $null
                        'Ports' = @()
                    }
            }

            $PowerControl.History.Add($PowerControl_HistoryItem) | Out-Null
        }
        
        $Global:PowerControl.ActiveMenu = $PowerControl_HistoryItem | Select-Object Id, TimeStamp
        
        <#
          remove any other menu excluding pinned or still running actions
        #>
        
        $itemsNotToRemove = @("$($PowerControl_HistoryItem.id)_$($PowerControl_HistoryItem.Timestamp)")
        $protectedKeys = Get-PowerControlProtectedHistoryKeys

        $PowerControl.History = [System.Collections.ArrayList](@($PowerControl.History | Where-Object {
            $item = $_
            $key = "$($item.id)_$($item.Timestamp)"
            ($itemsNotToRemove.Contains($key)) -or
            ($protectedKeys.Contains($key)) -or
            ($item.Thread.Handle.IsCompleted -eq $false) -or
            ($item.Pinned -eq $true)
        }))
    }

    }
    finally {
        [System.Threading.Monitor]::Exit($Global:PowerControl.HistoryLock)
    }

    Remove-Variable -Name 'jsonElement' -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    # hand the created/re-used item back to the caller
    $PowerControl_HistoryItem
}

$script:CommandFastPath = @{}
function Get-PowerControlCommandFastPath {
    <# UI command name when the element is a Command whose script is exactly "Invoke-PowerControlUICommand -Name X", else $null (cached per ID; Update-PowerControlNavigation clears the cache) #>
    param ([Parameter(Mandatory = $true)][string]$ID)
    if ($script:CommandFastPath.ContainsKey($ID)) { return $script:CommandFastPath[$ID] }
    $name = $null
    try {
        $json = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $ID }, 'First')[0]
        if ($null -ne $json -and $json.type -eq 'Command') {
            $element = Get-ElementByIdFromIndex -id $ID
            $code = [string]$element.PCtrl.Script.'#cdata-section'
            if (@($element.PCtrl.SelectNodes('PrevAction|NextAction')).Count -eq 0 -and $code -match '^\s*Invoke-PowerControlUICommand\s+-Name\s+([A-Za-z]+)\s*$') { $name = $Matches[1] }
        }
    }
    catch { $name = $null }
    $script:CommandFastPath[$ID] = $name
    $name
}

function Invoke-PowerControlSequence {
    <#
      .SYNOPSIS
      The one execution path for a PCtrl element: history entry, action-bar button, runspace, post-processing.

      .DESCRIPTION
      This sequence used to be copy-pasted into eight event handlers, each one reading the
      "new" item from $PowerControl.History[-1], which is wrong as soon as a pinned or still
      running item sits at the end of the list. All handlers now call this function.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$ID,
        [Parameter(Mandatory = $false)][object]$SelectedEntries,
        # Thread/EditTreeView actions triggered via right click do not refresh the output grid
        [Parameter(Mandatory = $false)][switch]$SkipPostScript,
        [Parameter(Mandatory = $false)][string]$ChangeActionButton = '',
        [Parameter(Mandatory = $false)][string]$MessageBox = ''
    )

    Write-DebugLog -Message "Sequence start: $ID (selected entries: $(@($SelectedEntries).Count), skip post script: $SkipPostScript)" -Level 1 -LogFileName 'UI.log'
    $sequenceWatch = [System.Diagnostics.Stopwatch]::StartNew()

    # fast path: a shell Command whose whole script is one Invoke-PowerControlUICommand call (Ctrl+Tab, palette,
    # filter, ...) needs no runspace; it is dispatched in-process, which saves 30 to 50 ms per key press
    $uiCommand = Get-PowerControlCommandFastPath -ID $ID
    if ($uiCommand) {
        Write-DebugLog -Message "Command $ID handled in-process (UI command $uiCommand)" -Level 2 -LogFileName 'UI.log'
        Invoke-PowerControlUICommand -Name $uiCommand
        return
    }

    try {
    $historyItem = Initialize-ScriptEnvironment -ID $ID -SelectedEntries $SelectedEntries
    if ($null -eq $historyItem) {
        Write-DebugLog -Message "No history item for ID $ID, nothing to execute" -Level 1 -LogFileName 'UI.log'
        return
    }

    # header-menu actions (Hide This Column, ...) only manipulate the grid: no button, no post-processing
    if ($historyItem.NodeType -in 'OutputGridHeaderMenu', 'Command') { $SkipPostScript = $true }

    if ($historyItem.NodeType -notin $Global:PowerControl.General.TransientNodeTypes) {
        if (@('MenuBar','Menu') -contains $historyItem.NodeType) {
            $ActionBar.Children.Clear()
            # remember the menu for the start page
            $settings = $Global:PowerControl.Settings
            if ($null -ne $settings) {
                $settings.RecentMenus = @(@($historyItem.ID) + @($settings.RecentMenus | Where-Object { $_ -ne $historyItem.ID }) | Select-Object -First 8)
                Save-PowerControlSettings
            }
        }
        # running an element that is already in the breadcrumb restarts the chain from there: "menu › edit" stays
        # "menu › edit" instead of growing to "menu › edit › edit › edit" (the earlier run's entry is replaced)
        $existingIndex = -1
        for ($i = 0; $i -lt $ActionBar.Children.Count; $i++) { if ("$($ActionBar.Children[$i].Uid)".StartsWith("$($historyItem.ID)_")) { $existingIndex = $i; break } }
        if ($existingIndex -ge 0) { $ActionBar.Children.RemoveRange($existingIndex, $ActionBar.Children.Count - $existingIndex) }
        # breadcrumb: every entry after the first gets a separator
        $label = if ($ActionBar.Children.Count -gt 0) { "›  $($historyItem.Name)" } else { $historyItem.Name }
        $newButton = New-PCtrlButton -Label $label -ID "$($historyItem.ID)_$($historyItem.Timestamp)"
        [void]$ActionBar.Children.Add($newButton)
    }

    $window = $Global:PowerControl.SynchronizedWindow
    $previousCursor = $window.Cursor
    $window.Cursor = [System.Windows.Input.Cursors]::Wait

    try {
        Get-ActionSequence -ID $historyItem.ID | Invoke-ActionScriptThreading -HistoryItem $historyItem

        if (-not $SkipPostScript) {
            $postScriptParams = @{
                OutputGrid = $window.FindName('OutputGrid')
                ID = $historyItem.ID
                TimeStamp = $historyItem.Timestamp
                ChangeActionButton = $ChangeActionButton
                MessageBox = $MessageBox
            }
            Initialize-PostScript @postScriptParams
        }
    }
    finally {
        $window.Cursor = $previousCursor
    }

    Write-DebugLog -Message "Sequence end: $ID ($($historyItem.NodeType) '$($historyItem.Name)') after $($sequenceWatch.ElapsedMilliseconds) ms on the UI thread, history items: $($Global:PowerControl.History.Count)" -Level 1 -LogFileName 'UI.log'
    }
    catch {
        # the handler path is the one place where failures were only visible on the console
        Write-DebugLog -Message "Sequence FAILED: $ID : $_ | $($_.InvocationInfo.PositionMessage) | $($_.ScriptStackTrace)" -Level 1 -LogFileName 'UI.log'
        try { Add-PowerControlNotification -Source $ID -Message "$_" } catch { }
        try { [System.IO.File]::AppendAllText([System.IO.Path]::Combine($script:LogsPath, 'scripts.log'), "UI sequence failed $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') for $ID`r`n$($_)`r`n$($_.ScriptStackTrace)`r`n`r`n") } catch { }
        throw
    }
}

# button check
function New-PCtrlButton {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$ID
    )

    Write-DebugLog -Message "Creating new button with Label: $Label and ID: $ID" -Level 1 -LogFileName 'PowerControl.log'

    $button = [System.Windows.Controls.Button]::new()
    $button.Content = $Label
    $button.Uid = $ID
    # breadcrumb style: compact, no fixed height, subtle until hovered
    $button.MinHeight = 24
    $button.Padding = '8,2,8,2'
    $button.Margin = '0,0,2,0'
    $button.MinWidth = 30
    $button.HorizontalAlignment = 'Left'
    $button.ToolTip = 'Click: show the output again · Right click: job menu (Pin it, Stop, Rerun, ...)'
    # right click: the same job menu as on the tabs and in the jobs list (Uid = "id_timestamp")
    $button.Add_MouseRightButtonUp({
        param($sender, $e)
        $e.Handled = $true
        if (-not (Get-Command Show-PowerControlTabContextMenu -ErrorAction SilentlyContinue)) { return }
        $split = $sender.Uid.LastIndexOf('_')
        if ($split -lt 1) { return }
        Show-PowerControlTabContextMenu -Key ($sender.Uid.Substring(0, $split) + '|' + $sender.Uid.Substring($split + 1)) -Target $sender
    })

    Write-DebugLog -Message "Button object created" -Level 2 -LogFileName 'PowerControl.log'

    $button.Add_Click({
        param($sender, $e)
        
        Write-DebugLog -Message "Button clicked: $($sender.Content)" -Level 1 -LogFileName 'PowerControl.log'

        $objectIdentify = $sender.Uid.Split('_', [System.StringSplitOptions]::None)
        Write-DebugLog -Message "Object identified: $($objectIdentify -join ', ')" -Level 2 -LogFileName 'PowerControl.log'

        $PowerControlItem = $Global:PowerControl.History | Where-Object {
            $key = "$($_.id)_$($_.Timestamp)"
            $key -eq "$($objectIdentify[0])_$($objectIdentify[1])"
        }
        
        $SelectedEntries = $PowerControlItem.SelectedEntries
        
        $index = $ActionBar.Children.IndexOf($($ActionBar.Children | Where-Object { $_.Uid -eq $sender.Uid }))
        
        if ($index -ge 0) {
            $itemsToRemove = @()
            $ActionBar.Children[$index..$ActionBar.Children.Count] | ForEach-Object { 
              $itemsToRemove += @($_.Uid)
            }
            
            $ActionBar.Children.RemoveRange($index, $ActionBar.Children.Count - $index)
            
            $ActionBar.UpdateLayout()
        }
        
        if($itemsToRemove.count -gt 0) {
            [System.Threading.Monitor]::Enter($Global:PowerControl.HistoryLock)
            try {
                $PowerControl.History = [System.Collections.ArrayList](@($PowerControl.History | Where-Object {
                    $item = $_
                    $key = "$($item.id)_$($item.Timestamp)"
                    $isNotCompleted = $item.Thread.Handle.IsCompleted -eq $false
                    $isPinned = $item.Pinned -eq $true

                    (-not $itemsToRemove.Contains($key)) -or $isNotCompleted -or $isPinned
                }))

                $PowerControlItem = $Global:PowerControl.History.where({($_.id -ceq $Global:PowerControl.ActiveMenu.ID) -and ($_.TimeStamp -eq $Global:PowerControl.ActiveMenu.TimeStamp)}, 'First')[0]

                if($null -ne $PowerControlItem -and $PowerControlItem.Children.count -gt 0) {
                  $PowerControlItem.Children = @($PowerControlItem.Children | Where-Object {
                      $key = "$($_.id)_$($_.Timestamp)"
                      -not $itemsToRemove.Contains($key)
                  })
                }
            }
            finally { [System.Threading.Monitor]::Exit($Global:PowerControl.HistoryLock) }
        }

        Write-DebugLog -Message "Initializing script environment" -Level 1 -LogFileName 'PowerControl.log'

        Invoke-PowerControlSequence -ID $objectIdentify[0] -SelectedEntries $SelectedEntries
    })

    Write-DebugLog -Message "Button click event handler added" -Level 2 -LogFileName 'PowerControl.log'

    Write-DebugLog -Message "Returning button object" -Level 1 -LogFileName 'PowerControl.log'
    $button
}

function Set-TreeItemHeight {
    <# Classic theme sizes TreeViewItems by hand (25 px rows); the Fluent theme has its own item
       templates, so there the height stays Auto and visibility alone hides items. #>
    param($Item, [double]$Height)
    # the Fluent templates size the rows themselves; Visibility alone hides items
    $Item.Height = [double]::NaN
}

function Set-MenuNodeVisibility {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object]$MenuItems,
        
        [Parameter(Mandatory=$true)]
        [object]$SelectedItem,
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(16,25)]
        [int]$ItemHeight = 25,
        
        [Parameter(Mandatory=$false)]
        [switch]$IsTreeView
    )

    begin {
        Write-DebugLog -Message "Processing menu items for selected type(s): $($SelectedItem.PSObject.TypeNames -join ', ')" -Level 1 -LogFileName 'PowerControl.log'
    }

    process {
        $MenuItems.foreach({
            $parentNode = $_
            $categoryVisibility = 0

            Write-DebugLog -Message "Processing parent node: $($parentNode.Header)" -Level 6 -LogFileName 'PowerControl.log'

            # Process child items
            $parentNode.Items.foreach({
                $childNode = $_
                $isVisible = $SelectedItem.PSObject.TypeNames.Contains($childNode.UID)
                
                if ($isVisible) {
                    $childNode.Visibility = 'Visible'
                    Set-TreeItemHeight $childNode $ItemHeight
                    if ($IsTreeView) { $childNode.IsExpanded = $true }
                    $categoryVisibility++
                    
                    Write-DebugLog -Message "Item $($childNode.Header) (UID: $($childNode.UID)) set to Visible" -Level 6 -LogFileName 'PowerControl.log'
                } else {
                    $childNode.Visibility = 'Collapsed'
                    Set-TreeItemHeight $childNode 0
                    if ($IsTreeView) { $childNode.IsExpanded = $false }
                    
                    Write-DebugLog -Message "Item $($childNode.Header) (UID: $($childNode.UID)) set to Collapsed" -Level 6 -LogFileName 'PowerControl.log'
                }
            })
            
            $isVisible = $SelectedItem.PSObject.TypeNames.Contains($parentNode.UID)
                
            if ($isVisible) {
                $parentNode.Visibility = 'Visible'
                Set-TreeItemHeight $parentNode $ItemHeight
               # if ($IsTreeView) { $parentNode.IsExpanded = $true }
                Write-DebugLog -Message "Item $($parentNode.Header) (UID: $($parentNode.UID)) set to Visible" -Level 6 -LogFileName 'PowerControl.log'
            } else {
                $parentNode.Visibility = 'Collapsed'
                Set-TreeItemHeight $parentNode 0
                #if ($IsTreeView) { $parentNode.IsExpanded = $false }
                Write-DebugLog -Message "Item $($parentNode.Header) (UID: $($parentNode.UID)) set to Collapsed" -Level 6 -LogFileName 'PowerControl.log'
            }
            
            # Process parent node visibility
            $isParentVisible = $SelectedItem.PSObject.TypeNames.Contains($parentNode.UID)
            if ($isParentVisible) {
                $parentNode.Visibility = 'Visible'
                Set-TreeItemHeight $parentNode $ItemHeight
                $categoryVisibility++
            }

            # Set final parent node visibility based on category visibility
            $parentNode.Visibility = if ($categoryVisibility -gt 0) { 'Visible' } else { 'Collapsed' }
            if ($IsTreeView) {
                # Check if this node should be expanded based on saved state
                $shouldBeExpanded = $Global:PowerControl.General.Settings.expandedUID -contains $parentNode.Uid
                $parentNode.IsExpanded = $shouldBeExpanded -and ($categoryVisibility -gt 0)

                # Set height based on expansion state
                if ($shouldBeExpanded -and $categoryVisibility -gt 0) {
                    $visibleChildren = $parentNode.Items | 
                        Where-Object { $_.Visibility -eq 'Visible' } | 
                        Measure-Object | 
                        Select-Object -ExpandProperty Count
                    Set-TreeItemHeight $parentNode (($visibleChildren + 1) * $ItemHeight)
                } else {
                    Set-TreeItemHeight $parentNode $(if ($categoryVisibility -gt 0) { $ItemHeight } else { 0 })
                }
            } else {
                Set-TreeItemHeight $parentNode $(if ($categoryVisibility -gt 0) { $ItemHeight } else { 0 })
            }

            Write-DebugLog -Message "Parent node $($parentNode.Header) visibility set to $($parentNode.Visibility)" -Level 6 -LogFileName 'PowerControl.log'
        })
    }

    end {
        if ($IsTreeView) {
            $MenuItems.Refresh()
            $MenuItems.UpdateLayout()
        }
        
        Write-DebugLog -Message "Menu processing completed" -Level 1 -LogFileName 'PowerControl.log'
    }
}

function ConvertTo-ModifierKeys {
    param ([string]$Modifiers)
    $modifierKeys = [System.Windows.Input.ModifierKeys]::None
    foreach ($modifier in $Modifiers -split '\+') {
        switch ($modifier.Trim()) {
            'Ctrl'  { $modifierKeys = $modifierKeys -bor [System.Windows.Input.ModifierKeys]::Control }
            'Alt'   { $modifierKeys = $modifierKeys -bor [System.Windows.Input.ModifierKeys]::Alt }
            'Shift' { $modifierKeys = $modifierKeys -bor [System.Windows.Input.ModifierKeys]::Shift }
            'Win'   { $modifierKeys = $modifierKeys -bor [System.Windows.Input.ModifierKeys]::Windows }
        }
    }
    return $modifierKeys
}

function Format-JsonOutput {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [int]$MaxLength = 1000,
        [int]$Depth = 2        
    )

    $jsonOutput = $Object | ConvertTo-Json -Compress -Depth $Depth 3> $null

    if ($jsonOutput.Length -gt $MaxLength) {
        $jsonOutput = $jsonOutput.Substring(0, $MaxLength) + '...'
    }

    return $jsonOutput
}

function Get-AvailableActions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$SelectedItem
    )
    
    $PowerControl.JsonCache.PCtrlItems | 
        Where-Object { $SelectedItem.PSObject.TypeNames -contains $_.id } | 
        Sort-Object -Property @{
            Expression = { 
                if ($null -ne $_.DisplayCondition.SortOrder) {
                    return [int]$_.DisplayCondition.SortOrder
                }
                return [int]::MaxValue
            }
            Ascending = $true
        }
}

function Get-PowerControlHistoryItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$ActiveMenu,
        [Parameter()]
        [switch]$IncludeActiveAction
    )

    $historyItem = $PowerControl.History | 
        Where-Object { ($_.id -ceq $ActiveMenu.ID) -and ($_.TimeStamp -ceq $ActiveMenu.TimeStamp) }

    if ($IncludeActiveAction -and $historyItem.ActiveAction.count -gt 0) {
        $historyItem = $PowerControl.History | 
            Where-Object { 
                ($_.id -eq $historyItem.ActiveAction.ID) -and 
                ($_.TimeStamp -eq $historyItem.ActiveAction.Timestamp)
            }
    }

    return $historyItem
}

function Invoke-PowerControlAction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$Sender,
        [Parameter(Mandatory)]
        [object]$DataGrid,
        [Parameter()]
        [switch]$UseDefaultAction,
        [Parameter()]
        [switch]$ExcludeActiveAction
    )

    $actionId = if ($UseDefaultAction) {
        $availableActions = Get-AvailableActions -SelectedItem $Sender.SelectedItem
        if ($availableActions.Count -gt 0) {
            ($availableActions | Select-Object -First 1).id
        }
    } else {
        if (Get-Member -InputObject $Sender -Name 'UID' -MemberType Properties) {
            $Sender.UID
        } 
        elseif (Get-Member -InputObject $Sender -Name 'ID' -MemberType Properties) {
            $Sender.ID
        } 
        else {
            $Sender.Name
        }
    }

    if ($actionId) {
        $SelectedEntries = $Global:PowerControl.SynchronizedWindow.FindName($DataGrid.Name).SelectedItems | ConvertTo-Json | ConvertFrom-Json

        Invoke-PowerControlSequence -ID $actionId -SelectedEntries $SelectedEntries
    }
}

function Switch-DataGridFocus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Windows.Input.KeyEventArgs]$KeyEventArgs,
        
        [Parameter(Mandatory)]
        [System.Windows.Controls.DataGrid]$SourceGrid,
        
        [Parameter(Mandatory)]
        [System.Windows.Controls.DataGrid]$TargetGrid
    )
    
    begin {
        # Handle the key event
        $KeyEventArgs.Handled = $true
    }
    
    process {
        # Get current selection details
        $selectedItem = $SourceGrid.SelectedItems[0]
        $currentCell = $SourceGrid.CurrentCell
        $currentColumnIndex = if ($currentCell -and $currentCell.Column) {
            $currentCell.Column.DisplayIndex
        } else { 0 }
        
        # Check if we can switch to target grid
        $currentIndex = $TargetGrid.SelectedIndex
        if ($currentIndex -lt 0 -and $TargetGrid.Items.Count -gt 0) {
            $currentIndex = 0
        }
        
        if ($currentIndex -ge 0 -and $currentIndex -lt $TargetGrid.Items.Count) {
            $TargetGrid.SelectedIndex = $currentIndex
            $TargetGrid.UpdateLayout()

            # Create dispatcher action
            $dispatcherAction = '               
                Start-Sleep -Milliseconds 50
                
                $grid = $PowerControl.SynchronizedWindow.FindName("' + $TargetGrid.Name + '")
                $targetItem = $grid.Items[' + $currentIndex + ']

                if ($targetItem) {
                    $grid.CurrentCell = [System.Windows.Controls.DataGridCellInfo]::new(
                        $targetItem, 
                        $grid.Columns[0]
                    )
                    $grid.CurrentItem = $targetItem

                    $row = $grid.ItemContainerGenerator.ContainerFromIndex(' + $currentIndex + ') -as [System.Windows.Controls.DataGridRow]
                    if ($row) {
                        $row.MoveFocus(
                            [System.Windows.Input.TraversalRequest]::new(
                                [System.Windows.Input.FocusNavigationDirection]::Next
                            )
                        )
                    }
                }'

            $TargetGrid.Dispatcher.InvokeAsync([System.Management.Automation.ScriptBlock]::Create($dispatcherAction), [System.Windows.Threading.DispatcherPriority]::Render)
        }
    }
}

function Register-PowerControlKeyBinding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Controls.Control]$Target,

        [Parameter(Mandatory)]
        [ValidateSet('Action','Thread', 'Menu')]
        [string]$BindingType
    )

    begin {
        $validKeys = [System.Enum]::GetNames([System.Windows.Input.Key])

        # bindings are rebuilt from scratch (also for the window after a navigation refresh)
        $Target.CommandBindings.Clear()
        $Target.InputBindings.Clear()
    }

    process {
        # Filter items based on binding type
        # window-level ('Menu') bindings cover menus, menu bar entries and Commands; grid bindings only the
        # actions that apply to the selected row
        $filteredItems = $PowerControl.JsonCache.PCtrlItems.Where({
            (($_.type -eq $BindingType) -or ($BindingType -eq 'Menu' -and $_.type -in 'MenuBar', 'Command')) -and
            (($null -ne $_.KeyBinding.Key) -or ($null -ne $_.KeyBinding.Modifiers)) -and
            ($BindingType -eq 'Menu' -or $Target.SelectedItem.PSObject.TypeNames -contains $_.id)
        })
        # the same shortcut may belong to several actions (e.g. "C" = connect on SSH and on RDP rows); WPF runs the
        # first matching binding, so the order follows the DisplayCondition SortOrder like the default action
        # on Enter / double click: the lowest SortOrder wins
        $filteredItems = @($filteredItems | Sort-Object -Stable { if ($null -ne $_.DisplayCondition.SortOrder) { [int]$_.DisplayCondition.SortOrder } else { [int]::MaxValue } })

        foreach ($item in $filteredItems) {
            $modifiers = if ([string]::IsNullOrEmpty($item.KeyBinding.Modifiers) -or $item.KeyBinding.Modifiers -eq 'None') { 
                [System.Windows.Input.ModifierKeys]::None 
            } else { 
                ConvertTo-ModifierKeys -Modifiers $item.KeyBinding.Modifiers 
            }

            Write-DebugLog -Message "Creating KeyGesture for $($item.ID)" -Level 6 -LogFileName 'PowerControl.log'

            if ($item.KeyBinding.key -notin $validKeys) {
                Write-DebugLog -Message "Invalid key: $($item.KeyBinding.key)" -Level 2 -LogFileName 'PowerControl.log'
                continue
            }

            try {
                $key = [System.Windows.Input.Key]::$($item.KeyBinding.key)
                # The command carries no gesture of its own: a KeyGesture rejects a plain letter without
                # modifiers ("'None+E' ... not supported"), the KeyBinding below accepts it, so bindings
                # such as Key="e" from the engine XML work.
                $routedUICommand = [System.Windows.Input.RoutedUICommand]::new('', $item.ID, [System.Object])
                # property setters (not the constructor): they build the gesture without validation, like XAML does
                $inputBinding = [System.Windows.Input.KeyBinding]::new()
                $inputBinding.Command = $routedUICommand
                $inputBinding.Key = $key
                $inputBinding.Modifiers = $modifiers
                $Target.InputBindings.Add($inputBinding) | Out-Null

                $commandAction = if (($BindingType -eq 'Action') -or ($BindingType -eq 'Thread')) {
                    {
                        param($sender, $e)
                        Write-DebugLog -Message "Command executed: $($e.Command.Name)" -Level 2 -LogFileName 'PowerControl.log'
                        
                        Invoke-PowerControlAction -Sender $($e.Command) -DataGrid $sender
                    }
                } else {
                    {
                        param($sender, $e)
                        Write-DebugLog -Message "Command executed: $($e.Command.Name)" -Level 2 -LogFileName 'PowerControl.log'
                        
                        $SelectedEntries = $Global:PowerControl.SynchronizedWindow.FindName('OutputGrid').SelectedItems | ConvertTo-Json | ConvertFrom-Json

                        Invoke-PowerControlSequence -ID $($e.Command.Name) -SelectedEntries $SelectedEntries
                    }
                }

                $commandBinding = [System.Windows.Input.CommandBinding]::new($routedUICommand, $commandAction)
                $Target.CommandBindings.Add($commandBinding)

                Write-DebugLog -Message "Added CommandBinding for $($item.ID)" -Level 6 -LogFileName 'PowerControl.log'
            }
            catch {
                Write-DebugLog -Message "Error creating KeyGesture: $_" -Level 1 -LogFileName 'PowerControl.log'
            }
        }
    }
}

function Show-ContextMenuForDataGrid {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [System.Windows.Controls.DataGrid]
        $DataGrid,

        [Parameter(Mandatory, Position = 1)]
        [System.Windows.RoutedEventArgs]
        $EventArgs
    )

    begin {
        # Validate if DataGrid has a ContextMenu
        if ($null -eq $DataGrid.ContextMenu) {
            Write-Warning "DataGrid does not have a ContextMenu defined"
            return
        }
    }

    process {
        try {
            $selectedItem = $DataGrid.SelectedItem
            if ($null -eq $selectedItem) { return }

            # Get the selected row using the ItemContainerGenerator
            $row = $DataGrid.ItemContainerGenerator.ContainerFromItem($selectedItem)
            if ($null -eq $row) { return }

            # Get and configure the ContextMenu
            $contextMenu = $DataGrid.ContextMenu

            # Check if the event is from mouse or keyboard
            $isMouseEvent = $EventArgs.OriginalSource -is [System.Windows.Controls.DataGridCell] -or 
                           $EventArgs.OriginalSource -is [System.Windows.Controls.DataGridRow]

            if ($isMouseEvent) {
                # For mouse events, use the mouse position
                $contextMenu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
                $contextMenu.PlacementTarget = $row
                $contextMenu.HorizontalOffset = 0
                $contextMenu.VerticalOffset = 0
            }
            else {
                # For keyboard events, calculate position based on the selected row
                $rowPosition = $row.TranslatePoint([System.Windows.Point]::new(0, $row.ActualHeight), $DataGrid)
                $contextMenu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Relative
                $contextMenu.PlacementTarget = $DataGrid
                $contextMenu.HorizontalOffset = $rowPosition.X
                $contextMenu.VerticalOffset = $rowPosition.Y
            }

            # Set the DataContext and show the ContextMenu
            $contextMenu.DataContext = $selectedItem
            $contextMenu.IsOpen = $true

            # Mark the event as handled
            $EventArgs.Handled = $true
        }
        catch {
            Write-Error -ErrorRecord $_
        }
    }
}

