# PowerControl - 13-UI.Handlers.ps1
# event handler script blocks of menu bar, trees, grids
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

# ---- handlers --------------------------------------------------------------------------------------
$PowerControlTemp_senderUID = {
    param($sender, $e)
    $e.Handled = $true
    $Global:PowerControl.EventParams.Sender = $sender | Select-Object uid, tag, Parent, Header, @{
        Name = 'PlacementTarget'
        Expression = { if ($_.Parent -and $_.Parent.PlacementTarget) { ($_.Parent.PlacementTarget.ToString() -split ':')[-1].Trim() } else { $null } }
    }
    $Global:PowerControl.EventParams.Args = $e
}

$HandledTrue = { param($sender, $e) $e.Handled = $true }

$PowerControlAction_UseDefaultAction = {
    param($sender, $e)
    if ($null -ne $sender.SelectedItem) { Invoke-PowerControlAction -Sender $sender -DataGrid $sender -UseDefaultAction }
}

$OnSpaceRaiseEvent_ClickEvent = {
    param($sender, $e)
    if ($e.Key -eq 'Space') { $sender.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent)) }
}

$MenuBar_AddClick = {
    param($sender, $e)
    if ($sender -eq $e.Source) { Invoke-PowerControlSequence -ID $sender.UID }
}

$menuBar_MouseRightButtonUp = {
    param($sender, $e)
    $editor = $PowerControl.JsonCache.PCtrlItems.Where({ $_.type -eq 'EditTreeView' })
    if ($editor.count -eq 1) {
        $e.Handled = $true
        Invoke-PowerControlSequence -ID $editor.id
    }
}

$NavigationMenuTree_MouseLeftButtonUp = {
    param($sender, $e)
    $e.Handled = $true
    $json = $PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $sender.UID }, 'First')[0]
    if ($null -ne $json -and -not $json.HasScript) {
        # container node such as "Folder Management": nothing to run, just open or close the group
        $sender.IsExpanded = -not $sender.IsExpanded
        return
    }
    Invoke-PowerControlSequence -ID $sender.UID
    if (-not $script:NavigationPinned) { Set-PowerControlNavigationState -Expanded $false }
}

$NavigationMenuTree_MouseRightButtonUp = {
    param($sender, $e)
    $editor = $PowerControl.JsonCache.PCtrlItems.Where({ $_.type -eq 'EditTreeView' })
    if ($editor.count -eq 1) {
        $e.Handled = $true
        Invoke-PowerControlSequence -ID $editor.id -SkipPostScript
    }
}

$ActionMenuTree_MouseLeftButtonUp = {
    param($sender, $e)
    Invoke-PowerControlAction -Sender $sender -DataGrid $OutputGrid
}

$ActionMenuTree_MouseRightButtonUp = {
    param($sender, $e)
    $e.Handled = $true
    $editor = $PowerControl.JsonCache.PCtrlItems.Where({ $_.type -eq 'EditTreeView' })
    if ($editor.count -eq 1) { Invoke-PowerControlSequence -ID $editor.id -SkipPostScript }
}

$ActionMenuTree_Expanded = {
    param($sender, $e)
    if ($e.OriginalSource -eq $sender -and $Global:PowerControl.General.Settings.expandedUID -notcontains $sender.Uid) {
        $Global:PowerControl.General.Settings.expandedUID += $sender.Uid
    }
}

$ActionMenuTree_Collapsed = {
    param($sender, $e)
    if ($e.OriginalSource -eq $sender) {
        $Global:PowerControl.General.Settings.expandedUID = @($Global:PowerControl.General.Settings.expandedUID | Where-Object { $_ -ne $sender.Uid })
    }
}

$TreeViewMenu_AddClick = {
    param($sender, $e)
    if ($sender -eq $e.Source) { Invoke-PowerControlSequence -ID $sender.UID }
}

$OutputGrid_Loaded = { param($sender, $e) Set-DataGridCellFocus }

$OutputGrid_GotFocus = { if (-not $OutputGrid.IsKeyboardFocusWithin) { Set-DataGridCellFocus } }

$OutputGrid_SelectionChanged = {
    param($sender, $e)
    if ($null -ne $sender.SelectedItem) {
        Register-PowerControlKeyBinding -Target $sender -BindingType 'Action'
        Set-MenuNodeVisibility -MenuItems $OutputGridMenu.Items -SelectedItem $sender.SelectedItem
        Set-MenuNodeVisibility -MenuItems $ActionMenuTree.Items -SelectedItem $sender.SelectedItem -IsTreeView
        Update-PowerControlActionRail
    }
}

$OutputGrid_PreviewKeyDown = {
    param($sender, $e)
    if ($e.Key -eq 'Tab') { Switch-DataGridFocus -KeyEventArgs $e -SourceGrid $OutputGrid -TargetGrid $StatusDataGrid }
    if ($e.Key -eq 'Space') { Show-ContextMenuForDataGrid -DataGrid $OutputGrid -EventArgs $e }
    if ($e.Key -eq 'Enter' -and $null -ne $sender.SelectedItem) { Invoke-PowerControlAction -Sender $sender -DataGrid $sender -UseDefaultAction }
}

$OutputGrid_MouseRightButtonUp = {
    param($sender, $e)
    if ($null -ne $sender.SelectedItem) { Set-MenuNodeVisibility -MenuItems $OutputGridMenu.Items -SelectedItem $sender.SelectedItem }
}

$OutputGridHeaderMenu_AddClick = {
    param($sender, $e)
    $e.Handled = $true
    $Global:PowerControl.EventParams.Sender = $sender | Select-Object uid, tag, Parent, Header, @{
        Name = 'PlacementTarget'
        Expression = { if ($_.Parent -and $_.Parent.PlacementTarget) { ($_.Parent.PlacementTarget.ToString() -split ':')[-1].Trim() } else { $null } }
    }
    $Global:PowerControl.EventParams.Args = $e
    Invoke-PowerControlAction -Sender $sender -DataGrid $sender -ExcludeActiveAction
}

$OutputGridMenu_AddClick = {
    param($sender, $e)
    Invoke-PowerControlAction -Sender $sender -DataGrid $OutputGrid -ExcludeActiveAction
}

$StatusDataGrid_SelectionChanged = {
    param($sender, $e)
    if ($null -ne $sender.SelectedItem) {
        Register-PowerControlKeyBinding -Target $sender -BindingType 'Thread'
        Set-MenuNodeVisibility -MenuItems $StatusDataGridMenu.Items -SelectedItem $sender.SelectedItem
    }
}

$StatusDataGrid_PreviewKeyDown = {
    param($sender, $e)
    if ($e.Key -eq 'Tab') { Switch-DataGridFocus -KeyEventArgs $e -SourceGrid $StatusDataGrid -TargetGrid $OutputGrid }
    if ($e.Key -eq 'Space') { Show-ContextMenuForDataGrid -DataGrid $StatusDataGrid -EventArgs $e }
    if ($e.Key -eq 'Enter' -and $null -ne $sender.SelectedItem) { Invoke-PowerControlAction -Sender $sender -DataGrid $sender -UseDefaultAction }
}

$StatusDataGrid_MouseRightButtonUp = {
    param($sender, $e)
    if ($null -ne $sender.SelectedItem) { Set-MenuNodeVisibility -MenuItems $StatusDataGridMenu.Items -SelectedItem $sender.SelectedItem }
}

$StatusDataGridMenu_AddClick = {
    param($sender, $e)
    Invoke-PowerControlAction -Sender $sender -DataGrid $StatusDataGrid
}

