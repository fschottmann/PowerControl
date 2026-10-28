# PowerControl - 16-UI.Content.ps1
# filter, row count, column profiles, error banner, start page, command palette, UI command runner
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

# ---- filter + row count ---------------------------------------------------------------------------------
function Update-PowerControlRowCount {
    # @($null).Count is 1, so an empty grid must be handled before wrapping the source
    # (direct assignments: an array returned from an if-expression is enumerated again)
    $source = @()
    if ($null -ne $OutputGrid.ItemsSource) { $source = @($OutputGrid.ItemsSource) }
    $total = $source.Count
    if ($total -eq 1 -and $source[0].PSObject.TypeNames -contains 'PowerControl.Placeholder') { $total = 0 }
    # direct assignment: inside an if/pipeline the ICollectionView (IEnumerable) would be enumerated into its rows
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($OutputGrid.ItemsSource)
    $filtered = ($null -ne $view) -and ($null -ne $view.Filter)
    $shown = if ($filtered) { $OutputGrid.Items.Count } else { $total }
    Write-DebugLog -Message "Row count: $shown of $total (filter active: $filtered, Items.Count: $($OutputGrid.Items.Count))" -Level 5 -LogFileName 'UI.log'
    $RowCountText.Text = if ($total -eq 0) { '' } elseif ($shown -ne $total) { "$shown of $total rows" } else { "$total row$(if ($total -ne 1) { 's' })" }
}

function Set-PowerControlGridFilter {
    param ([string]$Text)
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($OutputGrid.ItemsSource)
    if ($null -eq $view) { return }
    $FilterClearButton.Visibility = if ([string]::IsNullOrEmpty($Text)) { 'Collapsed' } else { 'Visible' }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $view.Filter = $null
    }
    else {
        $columns = @($OutputGrid.Columns | Where-Object { $_.Visibility -eq 'Visible' } | ForEach-Object { [string]$_.Header })
        $needle = $Text.Trim()
        $view.Filter = [System.Predicate[object]]{
            param($row)
            foreach ($column in $columns) {
                $value = $row.$column
                if ($null -ne $value -and ([string]$value).IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
            $false
        }.GetNewClosure()
    }
    Update-PowerControlRowCount
}

$FilterBox.Add_TextChanged({ param($s, $e) Set-PowerControlGridFilter -Text $s.Text })
$FilterClearButton.Add_Click({ param($s, $e) $FilterBox.Text = ''; $OutputGrid.Focus() | Out-Null })

# ---- column profiles (per menu) ------------------------------------------------------------------------
function Save-PowerControlColumnProfile {
    <# remembers width, visibility and order of the current output columns for the current menu #>
    $menuId = $script:CurrentOutputMenuId
    if (-not $menuId -or $OutputGrid.Columns.Count -eq 0) { return }
    $profile = @{}
    foreach ($column in $OutputGrid.Columns) {
        $profile[[string]$column.Header] = @{ Width = [double]$column.ActualWidth; Visible = ($column.Visibility -eq 'Visible'); Index = $column.DisplayIndex }
    }
    # sorting belongs to the profile as well (reserved key, never a column header)
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($OutputGrid.ItemsSource)
    if ($null -ne $view -and $view.SortDescriptions.Count -gt 0) {
        $profile['__sort'] = @($view.SortDescriptions | ForEach-Object { @{ Property = $_.PropertyName; Direction = [string]$_.Direction } })
    }
    $Global:PowerControl.Settings.ColumnProfiles[$menuId] = $profile
}

function Restore-PowerControlColumnProfile {
    param ([string]$MenuId)
    if (-not $MenuId) { return }
    $profile = $Global:PowerControl.Settings.ColumnProfiles[$MenuId]
    if ($null -eq $profile) { return }
    foreach ($column in $OutputGrid.Columns) {
        $saved = $profile[[string]$column.Header]
        if ($null -eq $saved) { continue }
        if ($saved.Width -gt 20) { $column.Width = [System.Windows.Controls.DataGridLength]::new([double]$saved.Width) }
        if ($saved.Visible -eq $false) { $column.Visibility = 'Collapsed' }
    }
    $sort = $profile['__sort']
    if ($null -ne $sort) {
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($OutputGrid.ItemsSource)
        if ($null -ne $view) {
            $view.SortDescriptions.Clear()
            foreach ($entry in @($sort)) {
                $direction = if ("$($entry.Direction)" -eq 'Descending') { [System.ComponentModel.ListSortDirection]::Descending } else { [System.ComponentModel.ListSortDirection]::Ascending }
                $view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new([string]$entry.Property, $direction))
                $sortedColumn = $OutputGrid.Columns | Where-Object { [string]$_.Header -eq [string]$entry.Property } | Select-Object -First 1
                if ($null -ne $sortedColumn) { $sortedColumn.SortDirection = $direction }
            }
        }
    }
    $ordered = @($OutputGrid.Columns | Where-Object { $null -ne $profile[[string]$_.Header] } | Sort-Object { [int]$profile[[string]$_.Header].Index })
    $index = 0
    foreach ($column in $ordered) { try { $column.DisplayIndex = $index } catch { }; $index++ }
}

function Reset-PowerControlColumnProfile {
    <# header menu "Reset column profile": forgets the stored profile of the current menu and shows the columns as generated #>
    $menuId = $script:CurrentOutputMenuId
    if ($menuId -and $Global:PowerControl.Settings.ColumnProfiles.ContainsKey($menuId)) {
        $Global:PowerControl.Settings.ColumnProfiles.Remove($menuId)
        Save-PowerControlSettings
    }
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($OutputGrid.ItemsSource)
    if ($null -ne $view) { $view.SortDescriptions.Clear() }
    $index = 0
    foreach ($column in @($OutputGrid.Columns)) {
        $column.Visibility = 'Visible'
        $column.Width = [System.Windows.Controls.DataGridLength]::Auto
        $column.SortDirection = $null
        try { $column.DisplayIndex = $index } catch { }
        $index++
    }
    Update-PowerControlRowCount
    Write-DebugLog -Message "Column profile reset for $menuId" -Level 1 -LogFileName 'UI.log'
}

# ---- error banner ---------------------------------------------------------------------------------------
function Show-PowerControlNotification {
    param ($Notification, [int]$Pending = 0)
    $suffix = if ($Pending -gt 0) { "  (+$Pending more)" } else { '' }
    $source = if ($Notification.Source) { "$($Notification.Source): " } else { '' }
    $ErrorBannerText.Text = "$($Notification.Time.ToString('HH:mm:ss'))  $source$($Notification.Message)$suffix"
    $ErrorBannerText.ToolTip = $Notification.Message
    # errors red, everything else in the neutral tile colours without the log button
    $isError = "$($Notification.Severity)" -eq 'Error'
    $ErrorBanner.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $(if ($isError) { 'PowerControlBannerBrush' } else { 'PowerControlTileBrush' }))
    $ErrorBanner.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $(if ($isError) { 'PowerControlBannerBorderBrush' } else { 'PowerControlAccentBrush' }))
    $ErrorBannerLogButton.Visibility = if ($isError) { 'Visible' } else { 'Collapsed' }
    $ErrorBanner.Visibility = 'Visible'
}

function Select-PowerControlOutputTabByOffset {
    <# Ctrl+Tab / Ctrl+Shift+Tab (Commands in main.xml): cycles through the tab strip #>
    param ([int]$Offset)
    $tabs = @(Get-PowerControlOutputTabList)
    if ($tabs.Count -lt 2) { return }
    $index = 0
    for ($i = 0; $i -lt $tabs.Count; $i++) { if ($tabs[$i].Key -eq $script:ShownTab) { $index = $i; break } }
    $next = ($index + $Offset) % $tabs.Count
    if ($next -lt 0) { $next += $tabs.Count }
    Select-PowerControlOutputTab -Key $tabs[$next].Key
}
$ErrorBannerCloseButton.Add_Click({ param($s, $e) $ErrorBanner.Visibility = 'Collapsed' })
$ErrorBannerLogButton.Add_Click({ param($s, $e) $log = Join-Path $script:LogsPath 'scripts.log'; if (Test-Path $log) { Invoke-Item $log } else { Invoke-Item $script:LogsPath } })

# ---- start page -------------------------------------------------------------------------------------------
function New-PowerControlTile {
    param ([string]$Label, [string]$Icon, [string]$Id, [string]$ToolTip = '')
    $button = [System.Windows.Controls.Button]::new()
    $button.Uid = $Id
    $button.MinWidth = 150; $button.Height = 44; $button.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
    $button.Padding = [System.Windows.Thickness]::new(10, 0, 12, 0)
    $button.HorizontalContentAlignment = 'Left'
    if ($ToolTip) { $button.ToolTip = $ToolTip }
    $panel = [System.Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'
    [void]$panel.Children.Add((New-PowerControlIconElement -Icon $Icon -Label $Label -Size 18))
    $text = [System.Windows.Controls.TextBlock]::new(); $text.Text = $Label; $text.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0); $text.VerticalAlignment = 'Center'
    [void]$panel.Children.Add($text)
    $button.Content = $panel
    $button.Add_Click({ param($s, $e) Invoke-PowerControlSequence -ID $s.Uid })
    # right click = element editor, like on the rail icons and popup entries
    $button.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PowerControlElementEditor -Uid $s.Uid })
    $button
}

function Update-PowerControlStartPage {
    <# welcome view in place of the empty grid: recent menus, all runnable menus, key bindings #>
    $StartPagePanel.Children.Clear()
    $items = $Global:PowerControl.JsonCache.PCtrlItems

    $title = [System.Windows.Controls.TextBlock]::new(); $title.Text = 'PowerControl'; $title.FontSize = 24; $title.FontWeight = 'SemiBold'
    [void]$StartPagePanel.Children.Add($title)
    $subtitle = [System.Windows.Controls.TextBlock]::new()
    $subtitle.Text = "Version $($Global:PowerControl.General.Version) · $($items.Count) elements in $(@($Global:PowerControl.JsonCache.files).Count) engine files · Ctrl+K opens the command palette"
    $subtitle.Margin = [System.Windows.Thickness]::new(0, 2, 0, 18); $subtitle.Foreground = $PowerControlWindow.TryFindResource('PowerControlSubtleBrush')
    [void]$StartPagePanel.Children.Add($subtitle)

    $sections = [System.Collections.Generic.List[object]]::new()
    $favorites = @($Global:PowerControl.Settings.FavoriteMenus | ForEach-Object { $id = $_; $items.Where({ $_.id -eq $id }, 'First')[0] } | Where-Object { $_ -and $_.HasScript })
    if ($favorites.Count -gt 0) { $sections.Add(@{ Title = 'Favorites'; Items = $favorites }) }
    $recent = @($Global:PowerControl.Settings.RecentMenus | ForEach-Object { $id = $_; $items.Where({ $_.id -eq $id }, 'First')[0] } | Where-Object { $_ -and $_.HasScript })
    if ($recent.Count -gt 0) { $sections.Add(@{ Title = 'Recently used'; Items = $recent }) }

    $childIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($parent in $items.Where({ $_.type -eq 'Menu' -and $_.Children })) { foreach ($c in ([string]$parent.Children).Split(',')) { [void]$childIds.Add($c.Trim()) } }
    $runnable = @($items.Where({ $_.type -eq 'Menu' -and $_.HasScript -and ($childIds.Contains($_.id) -or -not $_.Children) }) | Sort-Object Label)
    if ($runnable.Count -gt 0) { $sections.Add(@{ Title = 'Menus'; Items = $runnable }) }

    foreach ($section in $sections) {
        $header = [System.Windows.Controls.TextBlock]::new(); $header.Text = $section.Title; $header.FontSize = 14; $header.FontWeight = 'SemiBold'; $header.Margin = [System.Windows.Thickness]::new(0, 6, 0, 8)
        [void]$StartPagePanel.Children.Add($header)
        $wrap = [System.Windows.Controls.WrapPanel]::new()
        foreach ($entry in $section.Items) { [void]$wrap.Children.Add((New-PowerControlTile -Label (([string]$entry.Label) -replace '_', '') -Icon $entry.icon -Id $entry.id -ToolTip $entry.ToolTip)) }
        [void]$StartPagePanel.Children.Add($wrap)
    }

    $bindings = @($items.Where({ -not [string]::IsNullOrEmpty($_.KeyBinding.Key) }) | Sort-Object type, Label | Select-Object -First 12)
    if ($bindings.Count -gt 0) {
        $header = [System.Windows.Controls.TextBlock]::new(); $header.Text = 'Shortcuts'; $header.FontSize = 14; $header.FontWeight = 'SemiBold'; $header.Margin = [System.Windows.Thickness]::new(0, 10, 0, 8)
        [void]$StartPagePanel.Children.Add($header)
        $grid = [System.Windows.Controls.Grid]::new()
        [void]$grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()); $grid.ColumnDefinitions[0].Width = [System.Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
        $row = 0
        foreach ($binding in $bindings) {
            [void]$grid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
            $shortcut = [System.Windows.Controls.TextBlock]::new()
            $shortcut.Text = $(if ($binding.KeyBinding.Modifiers -and $binding.KeyBinding.Modifiers -ne 'None') { "$($binding.KeyBinding.Modifiers)+$($binding.KeyBinding.Key)" } else { $binding.KeyBinding.Key })
            $shortcut.FontFamily = 'Consolas'; $shortcut.Margin = [System.Windows.Thickness]::new(0, 1, 16, 1); $shortcut.Foreground = $PowerControlWindow.TryFindResource('PowerControlAccentBrush')
            [System.Windows.Controls.Grid]::SetRow($shortcut, $row)
            $label = [System.Windows.Controls.TextBlock]::new(); $label.Text = "$($binding.Label)  ($($binding.type))"; $label.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
            $label.Uid = $binding.id; $label.ToolTip = 'Right click: edit this element'
            $label.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PowerControlElementEditor -Uid $s.Uid })
            [System.Windows.Controls.Grid]::SetRow($label, $row); [System.Windows.Controls.Grid]::SetColumn($label, 1)
            [void]$grid.Children.Add($shortcut); [void]$grid.Children.Add($label)
            $row++
        }
        [void]$StartPagePanel.Children.Add($grid)
    }
}

# ---- command palette (Ctrl+K) -------------------------------------------------------------------------------
function Show-PowerControlCommandPalette {
    <# searchable list of every menu and action; Enter runs it with the current grid selection #>
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Command palette" Width="620" Height="440" WindowStartupLocation="CenterOwner" WindowStyle="ToolWindow" ShowInTaskbar="False" FontSize="12">
  <Grid Margin="10">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBox Name="PaletteInput" MinHeight="30" Padding="6,0" VerticalContentAlignment="Center"/>
    <ListBox Name="PaletteList" Grid.Row="1" Margin="0,8,0,0" BorderThickness="0">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <Grid Margin="2,1">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Text="{Binding Label}" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" Text="{Binding Detail}" Opacity="0.6" Margin="12,0,0,0" VerticalAlignment="Center"/>
          </Grid>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
    <TextBlock Grid.Row="2" Margin="0,6,0,0" Opacity="0.6" Text="Enter: run · Esc: close · actions use the selected rows of the grid"/>
  </Grid>
</Window>
'@
    $palette = [Windows.Markup.XamlReader]::Parse($xaml)
    $palette.Owner = $PowerControlWindow
    try { $palette.ThemeMode = [System.Windows.ThemeMode]::($Global:PowerControl.General.ThemeMode) } catch { }
    $input = $palette.FindName('PaletteInput')
    $list = $palette.FindName('PaletteList')

    $shortcutOf = { param($item) if ($item.KeyBinding.Key) { "$(if ($item.KeyBinding.Modifiers -and $item.KeyBinding.Modifiers -ne 'None') { $item.KeyBinding.Modifiers + '+' })$($item.KeyBinding.Key)" } else { '' } }
    $entries = [System.Collections.Generic.List[object]]::new()

    # navigation: menus and menu bar entries that have code, plus Commands (containers like "Folder Management" stay out)
    $favoriteMenuIds = @($Global:PowerControl.Settings.FavoriteMenus | Where-Object { $_ })
    $navigation = @($Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.Label -and $_.HasScript -and $_.type -in 'Menu', 'MenuBar', 'Command' }) |
        Sort-Object @{ Expression = { $favoriteMenuIds -notcontains [string]$_.id } }, @{ Expression = { switch ($_.type) { 'Menu' { 0 } 'MenuBar' { 1 } default { 2 } } } }, Label)
    foreach ($item in $navigation) {
        $plainLabel = ([string]$item.Label) -replace '_', ''   # drop the WPF access-key underscore
        $kind = switch ($item.type) { 'Menu' { 'Menu' } 'MenuBar' { 'Menu bar' } default { 'Command' } }
        if ($favoriteMenuIds -contains [string]$item.id) { $plainLabel = "★ $plainLabel" }
        $entries.Add([pscustomobject]@{ Id = $item.id; Type = $item.type; Node = $null; Label = $plainLabel; Detail = (@($kind, (& $shortcutOf $item)) | Where-Object { $_ }) -join ' · '; Search = "$plainLabel $kind".ToLowerInvariant() })
    }

    # actions: only those the action panel offers for the selected row right now. Helper actions without a
    # DisplayCondition (parts of Prev/NextAction chains such as "Close SSHSession") never appear here.
    if ($null -ne $OutputGrid.SelectedItem) {
        $knownIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Global:PowerControl.JsonCache.PCtrlItems.id))
        $favoriteIds = @($Global:PowerControl.Settings.FavoriteActions | Where-Object { $_ })
        $actionEntries = [System.Collections.Generic.List[object]]::new()
        foreach ($node in @($ActionMenuTree.Items)) {
            if ($node.Visibility -ne 'Visible') { continue }
            $leaves = @()
            if ($knownIds.Contains([string]$node.Uid)) { $leaves = @($node) } else { $leaves = @($node.Items) }
            foreach ($leaf in $leaves) {
                if ($leaf.Visibility -ne 'Visible') { continue }
                $item = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $leaf.Uid }, 'First')[0]
                if ($null -eq $item) { continue }
                $isFavorite = $favoriteIds -contains [string]$item.id
                $actionEntries.Add([pscustomobject]@{ Id = $item.id; Type = 'Action'; Node = $leaf; Favorite = $isFavorite; Label = "$(if ($isFavorite) { '★ ' })$($item.Label)"; Detail = (@('Action', $item.DisplayCondition.Categorie, (& $shortcutOf $item)) | Where-Object { $_ }) -join ' · '; Search = "$($item.Label) action $($item.DisplayCondition.Categorie)".ToLowerInvariant() })
            }
        }
        # favourites first, in front of the navigation entries
        $ordered = @($actionEntries | Sort-Object @{ Expression = { -not $_.Favorite } }, Label)
        $favoriteEntries = @($ordered | Where-Object { $_.Favorite })
        foreach ($entry in @($ordered | Where-Object { -not $_.Favorite })) { $entries.Add($entry) }
        for ($i = $favoriteEntries.Count - 1; $i -ge 0; $i--) { $entries.Insert(0, $favoriteEntries[$i]) }
    }
    $list.ItemsSource = $entries
    $list.SelectedIndex = 0
    $palette.Tag = @{ Entries = $entries; List = $list; Input = $input }

    $input.Add_TextChanged({
        param($s, $e)
        $state = $s.Parent.Parent.Tag   # Grid > Window
        $needle = $s.Text.Trim().ToLowerInvariant()
        # a typed list: PowerShell unwraps a one-element array when it is assigned to a .NET property
        $filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $state.Entries) { if (-not $needle -or $entry.Search.Contains($needle)) { $filtered.Add($entry) } }
        $state.List.ItemsSource = $filtered
        $state.List.SelectedIndex = 0
    })

    $run = {
        param($window)
        $selected = $window.Tag.List.SelectedItem
        if ($null -eq $selected) { return }
        $window.Close()
        if ($selected.Type -eq 'Action' -and $null -ne $selected.Node) {
            # same path as a click in the action panel (selected rows, default action handling)
            Invoke-PowerControlAction -Sender $selected.Node -DataGrid $OutputGrid
        }
        else {
            Invoke-PowerControlSequence -ID $selected.Id
        }
    }
    $palette.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { $s.Close(); $e.Handled = $true }
        elseif ($e.Key -eq 'Enter') { $e.Handled = $true; & $script:PaletteRun $s }
        elseif ($e.Key -eq 'Down' -and $s.Tag.List.SelectedIndex -lt $s.Tag.List.Items.Count - 1) { $s.Tag.List.SelectedIndex++; $s.Tag.List.ScrollIntoView($s.Tag.List.SelectedItem); $e.Handled = $true }
        elseif ($e.Key -eq 'Up' -and $s.Tag.List.SelectedIndex -gt 0) { $s.Tag.List.SelectedIndex--; $s.Tag.List.ScrollIntoView($s.Tag.List.SelectedItem); $e.Handled = $true }
    })
    $list.Add_MouseDoubleClick({ param($s, $e) & $script:PaletteRun $s.Parent.Parent })
    $script:PaletteRun = $run
    $palette.add_ContentRendered({ param($s, $e) $s.Tag.Input.Focus() | Out-Null })
    [void]$palette.ShowDialog()
}

# No hard-coded window shortcuts: palette, filter etc. are Command elements in main.xml (View menu) whose
# KeyBindings the user can change there. Their scripts call Invoke-PowerControlUICommand, which lands here.
$Global:PowerControl.UI.CommandRunner = [System.Action[string]]{
    param([string]$name)
    Write-DebugLog -Message "UI command: $name" -Level 2 -LogFileName 'UI.log'
    $click = { param($button) $button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
    switch ($name) {
        'CommandPalette'   { Show-PowerControlCommandPalette }
        'ResetColumns'     { Reset-PowerControlColumnProfile }
        'NextTab'          { Select-PowerControlOutputTabByOffset -Offset 1 }
        'PreviousTab'      { Select-PowerControlOutputTabByOffset -Offset -1 }
        'UnpinTab'         { if ($script:ShownTab) { Remove-PowerControlOutputTab -Key $script:ShownTab } }
        'RefreshFavorites' { Update-PowerControlFavoriteViews }   # after "Favorit an/aus" from the job menu (settings changed in a runspace)
        'RunPending'       {
            # an engine script asks the shell to run an element as a new job (e.g. "Speichern + Dry Run" in the editor)
            $request = $Global:PowerControl.UI.PendingRun
            $Global:PowerControl.UI.PendingRun = $null
            if ($null -eq $request -or -not $request.ID) { return }
            $requested = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $request.ID }, 'First')[0]
            if ($null -ne $requested -and $requested.type -eq 'Action' -and $null -eq $Global:PowerControl.ActiveMenu) { Add-PowerControlNotification -Source 'Dry run' -Message 'Run a menu first (e.g. List all PCtrl Elements); the dry run runs as an action of it.' -Severity Info; return }
            Invoke-PowerControlSequence -ID $request.ID -SelectedEntries @($request.Entries)
        }
        'RegisterHotkey'   { Register-PowerControlGlobalHotkey }   # settings dialog changed the global hotkey
        'FocusFilter'      { $FilterBox.Focus() | Out-Null; $FilterBox.SelectAll() }
        'ClearFilter'      { $FilterBox.Text = ''; $OutputGrid.Focus() | Out-Null }
        'ToggleNavigation' { & $click $NavigationPinButton }
        'ToggleActions'    { & $click $ActionPanelToggle }
        'ToggleJobs'       { & $click $JobsPinButton }
        'StartPage'        { Update-PowerControlStartPage; $StartPage.Visibility = 'Visible' }
        default            { Write-DebugLog -Message "Unknown UI command: $name" -Level 1 -LogFileName 'UI.log' }
    }
}
# Esc inside the filter box clears it (local to the control, not a global shortcut)
$FilterBox.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Text = ''; $OutputGrid.Focus() | Out-Null; $e.Handled = $true } })

