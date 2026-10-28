# PowerControl - 15-UI.Tabs.ps1
# output tabs: contexts per menu and pinned job
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

# ---- output tabs: the active menu plus one tab per pinned job ---------------------------------------------
$script:ShownTab = $null             # $null = output of the active menu/action; otherwise @{ Id; Timestamp } of a pinned item
$script:ShownTabOutputRef = $null    # last Output reference shown for that tab (live refresh of running jobs)
$script:OutputTabsSignature = ''

function Get-PowerControlHistorySnapshot {
    [System.Threading.Monitor]::Enter($Global:PowerControl.HistoryLock)
    try { @($Global:PowerControl.History.ToArray()) } finally { [System.Threading.Monitor]::Exit($Global:PowerControl.HistoryLock) }
}

function Find-PowerControlHistoryItem {
    param ([string]$Id, [string]$Timestamp)
    $found = $null
    foreach ($item in (Get-PowerControlHistorySnapshot)) {
        if ($item.ID -ceq $Id -and "$($item.Timestamp)" -eq "$Timestamp") { $found = $item; break }
    }
    $found
}

function Get-PowerControlPinnedItems {
    @((Get-PowerControlHistorySnapshot) | Where-Object { $_.Pinned -eq $true -and $_.NodeType -notin $Global:PowerControl.General.TransientNodeTypes })
}

$script:TabState = @{}               # per tab key: Filter, SelectedIndex, ActionBar (breadcrumb buttons)

function Get-PowerControlTabKey { param ($Item) "$($Item.ID)|$($Item.Timestamp)" }

function Get-PowerControlContextItem {
    <# what a menu tab shows: the menu's active action if it produced rows, otherwise the menu itself #>
    param ($Menu)
    if ($null -eq $Menu) { return $null }
    if ($null -ne $Menu.ActiveAction) {
        $action = Find-PowerControlHistoryItem -Id $Menu.ActiveAction.Id -Timestamp $Menu.ActiveAction.Timestamp
        # ($null -ne ...) first: @($null).Count is 1 and indexing into $null throws
        if ($null -ne $action -and $null -ne $action.Output -and @($action.Output).Count -gt 0 -and @($action.Output)[0] -isnot [bool]) { return $action }
    }
    $Menu
}

function Get-PowerControlActiveMenuItem {
    $active = $Global:PowerControl.ActiveMenu
    if ($null -eq $active) { return $null }
    Find-PowerControlHistoryItem -Id $active.Id -Timestamp $active.TimeStamp
}

function Get-PowerControlOutputTabList {
    <#
      Ordered tab descriptors: every menu that is pinned or the active one, each followed by its pinned
      child actions (so a job pinned from inside a menu stays next to that menu), then pinned actions
      whose menu is gone. Fields: Key, Item, IsMenu, IsChild, IsCurrent, Parent.
      Inside one UI tick the list is computed once (tabs, shown tab, title and tray all ask for it).
    #>
    if ($script:InUiTick -and $script:TabListCacheTick -eq $script:UiTickCount -and $null -ne $script:TabListCache) { return $script:TabListCache }
    $items = Get-PowerControlHistorySnapshot
    $transient = $Global:PowerControl.General.TransientNodeTypes
    $active = $Global:PowerControl.ActiveMenu
    $tabs = [System.Collections.Generic.List[object]]::new()
    $placed = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($item in $items) {
        if ($item.NodeType -in $transient -or $item.NodeType -notin 'Menu', 'MenuBar') { continue }
        $isActive = ($null -ne $active) -and ($item.ID -ceq $active.Id) -and ("$($item.Timestamp)" -eq "$($active.TimeStamp)")
        if (-not ($item.Pinned -eq $true -or $isActive)) { continue }
        $key = Get-PowerControlTabKey $item
        if (-not $placed.Add($key)) { continue }
        $tabs.Add([pscustomobject]@{ Key = $key; Item = $item; IsMenu = $true; IsChild = $false; IsCurrent = ($isActive -and $item.Pinned -ne $true); Parent = $null })
        foreach ($child in @($item.Children)) {
            if ($null -eq $child) { continue }
            $childItem = $null
            foreach ($candidate in $items) { if ($candidate.ID -ceq $child.Id -and "$($candidate.Timestamp)" -eq "$($child.Timestamp)") { $childItem = $candidate; break } }
            if ($null -eq $childItem -or $childItem.Pinned -ne $true) { continue }
            $childKey = Get-PowerControlTabKey $childItem
            if ($placed.Add($childKey)) { $tabs.Add([pscustomobject]@{ Key = $childKey; Item = $childItem; IsMenu = $false; IsChild = $true; IsCurrent = $false; Parent = $item }) }
        }
    }
    foreach ($item in $items) {
        if ($item.NodeType -in $transient -or $item.Pinned -ne $true) { continue }
        $key = Get-PowerControlTabKey $item
        if ($placed.Add($key)) { $tabs.Add([pscustomobject]@{ Key = $key; Item = $item; IsMenu = ($item.NodeType -in 'Menu', 'MenuBar'); IsChild = $false; IsCurrent = $false; Parent = $null }) }
    }
    # plain array: callers wrap it in @(); a ", $list" return would become one element inside that @()
    $result = $tabs.ToArray()
    if ($script:InUiTick) { $script:TabListCache = $result; $script:TabListCacheTick = $script:UiTickCount }
    $result
}

function Find-PowerControlOutputTab {
    param ([string]$Key)
    $found = $null
    foreach ($tab in (Get-PowerControlOutputTabList)) { if ($tab.Key -eq $Key) { $found = $tab; break } }
    $found
}

function Get-PowerControlTabShownItem {
    param ($Tab)
    if ($Tab.IsMenu) { return (Get-PowerControlContextItem -Menu $Tab.Item) }
    $Tab.Item
}

function Set-PowerControlShownTabFromContext {
    <# after a sequence showed its output: the tab of the active menu is the one on screen #>
    $menu = Get-PowerControlActiveMenuItem
    if ($null -eq $menu) { $script:ShownTab = $null; return }
    $script:ShownTab = Get-PowerControlTabKey $menu
    $context = Get-PowerControlContextItem -Menu $menu
    $script:ShownTabOutputRef = $context.Output
    $script:ShownTabItemKey = Get-PowerControlTabKey $context
}

function Save-PowerControlTabState {
    if (-not $script:ShownTab) { return }
    $script:TabState[$script:ShownTab] = @{ Filter = [string]$FilterBox.Text; SelectedIndex = $OutputGrid.SelectedIndex; ActionBar = @($ActionBar.Children) }
}

function Restore-PowerControlActionBar {
    <# breadcrumb of a tab: the buttons saved when the tab was left, otherwise menu [› action] #>
    param ($Tab)
    $buttons = @()
    $state = $script:TabState[$Tab.Key]
    if ($null -ne $state -and @($state.ActionBar).Count -gt 0) { $buttons = @($state.ActionBar) }
    elseif ($Tab.IsChild -and $null -ne $Tab.Parent) {
        $parentState = $script:TabState[(Get-PowerControlTabKey $Tab.Parent)]
        if ($null -ne $parentState -and @($parentState.ActionBar).Count -gt 0) { $buttons = @($parentState.ActionBar) }
        else { $buttons = @((New-PCtrlButton -Label ([string]$Tab.Parent.Name) -ID "$($Tab.Parent.ID)_$($Tab.Parent.Timestamp)")) }
        $ownUid = "$($Tab.Item.ID)_$($Tab.Item.Timestamp)"
        if (-not @($buttons | Where-Object { $_.Uid -eq $ownUid })) { $buttons += New-PCtrlButton -Label "›  $($Tab.Item.Name)" -ID $ownUid }
    }
    else { $buttons = @((New-PCtrlButton -Label ([string]$Tab.Item.Name) -ID "$($Tab.Item.ID)_$($Tab.Item.Timestamp)")) }

    $ActionBar.Children.Clear()
    foreach ($button in $buttons) {
        $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($button)
        if ($null -ne $parent -and $parent -is [System.Windows.Controls.Panel]) { $parent.Children.Remove($button) }
        [void]$ActionBar.Children.Add($button)
    }
}

function New-PowerControlOutputTab {
    param ([string]$Label, [string]$Sub, [bool]$Active, [bool]$Pinned, [bool]$Running, [bool]$Child, [string]$Key, [bool]$Closable)
    $border = [System.Windows.Controls.Border]::new()
    $border.CornerRadius = [System.Windows.CornerRadius]::new(4, 4, 0, 0)
    $border.Padding = [System.Windows.Thickness]::new($(if ($Child) { 6 } else { 10 }), 4, 8, 4); $border.Margin = [System.Windows.Thickness]::new(0, 0, 2, 0)
    $border.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 2)
    $border.Cursor = [System.Windows.Input.Cursors]::Hand
    $border.Tag = $Key
    $border.ToolTip = 'Click: show · Right click: job menu (Stop, Rerun, Unpin, ...)'
    if ($Active) {
        $border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'PowerControlTileBrush')
        $border.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'PowerControlAccentBrush')
    }
    else {
        $border.Background = [System.Windows.Media.Brushes]::Transparent
        $border.BorderBrush = [System.Windows.Media.Brushes]::Transparent
    }
    $panel = [System.Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'
    if ($Child) {
        # pinned action of the menu to its left
        $arrow = [System.Windows.Controls.TextBlock]::new(); $arrow.Text = '›'; $arrow.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0); $arrow.VerticalAlignment = 'Center'
        $arrow.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'PowerControlSubtleBrush')
        [void]$panel.Children.Add($arrow)
    }
    if ($Pinned) {
        $pin = New-PowerControlIconElement -Icon 'lucide\pin.svg' -Size 12
        $pin.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0); $pin.VerticalAlignment = 'Center'
        [void]$panel.Children.Add($pin)
    }
    if ($Running) {
        $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 7; $dot.Height = 7; $dot.Fill = [System.Windows.Media.Brushes]::SeaGreen
        $dot.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0); $dot.VerticalAlignment = 'Center'
        [void]$panel.Children.Add($dot)
    }
    $text = [System.Windows.Controls.TextBlock]::new(); $text.Text = $Label; $text.VerticalAlignment = 'Center'
    $text.FontWeight = if ($Active) { 'SemiBold' } else { 'Normal' }
    $text.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'PowerControlTextBrush')
    [void]$panel.Children.Add($text)
    if ($Sub) {
        $subText = [System.Windows.Controls.TextBlock]::new(); $subText.Text = $Sub; $subText.FontSize = 11; $subText.VerticalAlignment = 'Center'
        $subText.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        $subText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'PowerControlSubtleBrush')
        [void]$panel.Children.Add($subText)
    }
    if ($Closable) {
        $close = [System.Windows.Controls.Button]::new()
        $close.Width = 18; $close.Height = 18; $close.Padding = [System.Windows.Thickness]::new(0); $close.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        $close.Background = [System.Windows.Media.Brushes]::Transparent; $close.BorderThickness = [System.Windows.Thickness]::new(0)
        $close.Content = New-PowerControlIconElement -Icon 'lucide\x.svg' -Size 10
        $close.ToolTip = 'Unpin: the tab disappears, the entry stays in the job list'
        $close.Tag = $Key
        $close.Add_Click({ param($s, $e) $e.Handled = $true; Remove-PowerControlOutputTab -Key $s.Tag })
        [void]$panel.Children.Add($close)
    }
    $border.Child = $panel
    $border.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Select-PowerControlOutputTab -Key $s.Tag })
    $border.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Show-PowerControlTabContextMenu -Key $s.Tag -Target $s })
    $border
}

function Show-PowerControlTabContextMenu {
    <# the jobs list menu (Pin it, Unpin, Stop, Rerun, Display Output, ...) for the job behind a tab #>
    param ([string]$Key, $Target)
    $id, $timestamp = $Key -split '\|', 2
    $row = $null
    foreach ($candidate in @($StatusDataGrid.ItemsSource)) {
        if ($null -ne $candidate -and $candidate.ID -ceq $id -and "$($candidate.TimeStamp)" -eq "$timestamp") { $row = $candidate; break }
    }
    if ($null -eq $row) {
        Write-DebugLog -Message "Tab menu: job $Key not in the jobs list yet" -Level 2 -LogFileName 'UI.log'
        return
    }
    # the actions of the menu work on StatusDataGrid.SelectedItems; visibility is refreshed explicitly because
    # SelectionChanged does not fire when the row was selected already (e.g. right after pinning it)
    $StatusDataGrid.SelectedItem = $row
    Register-PowerControlKeyBinding -Target $StatusDataGrid -BindingType 'Thread'
    Set-MenuNodeVisibility -MenuItems $StatusDataGridMenu.Items -SelectedItem $row
    $StatusDataGridMenu.PlacementTarget = $Target
    $StatusDataGridMenu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $StatusDataGridMenu.IsOpen = $true
}

function Select-PowerControlOutputTab {
    param ([string]$Key)
    $tab = Find-PowerControlOutputTab -Key $Key
    if ($null -eq $tab) { return }
    if ($script:ShownTab -eq $Key) { Update-PowerControlOutputTabs -Force; return }   # already on screen: keep filter and selection
    Save-PowerControlTabState
    $script:ShownTab = $Key

    # context: a menu tab makes its menu the active menu again, so actions started here attach to it;
    # a pinned action tab hands the context to its menu
    $menu = $null
    if ($tab.IsMenu) { $menu = $tab.Item } elseif ($null -ne $tab.Parent) { $menu = $tab.Parent }
    if ($null -ne $menu) { $Global:PowerControl.ActiveMenu = $menu | Select-Object Id, TimeStamp }
    Restore-PowerControlActionBar -Tab $tab

    $state = $script:TabState[$Key]
    $FilterBox.Text = if ($null -ne $state) { [string]$state.Filter } else { '' }
    $shownItem = Get-PowerControlTabShownItem -Tab $tab
    $script:ShownTabOutputRef = $shownItem.Output
    $script:ShownTabItemKey = Get-PowerControlTabKey $shownItem
    Show-PowerControlOutput -OutputGrid $OutputGrid -HistoryItem $shownItem -FromTab
    if ($null -ne $state -and $state.SelectedIndex -ge 0 -and $state.SelectedIndex -lt $OutputGrid.Items.Count) { $OutputGrid.SelectedIndex = $state.SelectedIndex }
    Update-PowerControlOutputTabs -Force
    Write-DebugLog -Message "Tab selected: $Key ($($tab.Item.Name))" -Level 2 -LogFileName 'UI.log'
}

function Remove-PowerControlOutputTab {
    <# unpin via the tab's close button #>
    param ([string]$Key)
    $id, $timestamp = $Key -split '\|', 2
    $item = Find-PowerControlHistoryItem -Id $id -Timestamp $timestamp
    if ($null -ne $item) { $item.Pinned = $false }
    $script:TabState.Remove($Key)
    if ($script:ShownTab -eq $Key) {
        $script:ShownTab = $null
        $remaining = @(Get-PowerControlOutputTabList)
        if ($remaining.Count -gt 0) { Select-PowerControlOutputTab -Key $remaining[0].Key; return }
    }
    Update-PowerControlOutputTabs -Force
}

function Update-PowerControlOutputTabs {
    <# rebuilds the tab strip when something changed (tabs, states, active tab); hidden while nothing is pinned #>
    param ([switch]$Force)
    $tabs = @(Get-PowerControlOutputTabList)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($tab in $tabs) {
        $running = $null -ne $tab.Item.Thread -and $null -ne $tab.Item.Thread.Handle -and -not $tab.Item.Thread.Handle.IsCompleted
        $parts.Add("$($tab.Key)|$($tab.Item.Name)|$($tab.IsCurrent)|$($tab.IsChild)|$running|$(@($tab.Item.Output).Count)")
    }
    $parts.Add("shown|$($script:ShownTab)")
    $signature = $parts -join ';'
    if (-not $Force -and $signature -eq $script:OutputTabsSignature) { return }
    $script:OutputTabsSignature = $signature

    # forget the state of tabs that no longer exist
    foreach ($key in @($script:TabState.Keys)) { if (-not ($tabs | Where-Object { $_.Key -eq $key })) { $script:TabState.Remove($key) } }

    $OutputTabs.Children.Clear()
    $pinnedCount = @($tabs | Where-Object { $_.Item.Pinned -eq $true }).Count
    if ($pinnedCount -eq 0) {
        $OutputTabStrip.Visibility = 'Collapsed'
        return
    }
    $OutputTabStrip.Visibility = 'Visible'
    foreach ($tab in $tabs) {
        $running = $null -ne $tab.Item.Thread -and $null -ne $tab.Item.Thread.Handle -and -not $tab.Item.Thread.Handle.IsCompleted
        $count = @($tab.Item.Output | Where-Object { $null -ne $_ }).Count
        $sub = if ($tab.IsCurrent) { 'current' } elseif ($running) { 'running' } else { "$count row$(if ($count -ne 1) { 's' })" }
        [void]$OutputTabs.Children.Add((New-PowerControlOutputTab -Label ([string]$tab.Item.Name) -Sub $sub -Active ($script:ShownTab -eq $tab.Key) -Pinned ($tab.Item.Pinned -eq $true) -Running $running -Child $tab.IsChild -Key $tab.Key -Closable ($tab.Item.Pinned -eq $true)))
    }
}

function Update-PowerControlShownTab {
    <# UI tick: new output of the shown context (running job) is refreshed in place #>
    if (-not $script:ShownTab) { return }
    $tab = Find-PowerControlOutputTab -Key $script:ShownTab
    if ($null -eq $tab) { $script:ShownTab = $null; return }   # tab vanished (unpinned, pruned): the grid keeps what it shows
    $shownItem = Get-PowerControlTabShownItem -Tab $tab
    if (-not [object]::ReferenceEquals($shownItem.Output, $script:ShownTabOutputRef)) {
        $script:ShownTabOutputRef = $shownItem.Output
        $itemKey = Get-PowerControlTabKey $shownItem
        if ($itemKey -ne $script:ShownTabItemKey) {
            # the context now shows another entry (menu rows -> output of a started action): a filter typed
            # for the previous rows would only hide the new ones
            $script:ShownTabItemKey = $itemKey
            if ($FilterBox.Text) { $FilterBox.Text = '' }
            Show-PowerControlOutput -OutputGrid $OutputGrid -HistoryItem $shownItem -FromTab
            return
        }
        $selected = $OutputGrid.SelectedIndex
        Show-PowerControlOutput -OutputGrid $OutputGrid -HistoryItem $shownItem -FromTab -LeaveAsIs
        if ($selected -ge 0 -and $selected -lt $OutputGrid.Items.Count) { $OutputGrid.SelectedIndex = $selected }
    }
}

