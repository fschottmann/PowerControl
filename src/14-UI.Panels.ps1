# PowerControl - 14-UI.Panels.ps1
# navigation rail + popup, actions rail + popup, jobs bar + toolbar
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

# ---- navigation: rail, flyout, pin ---------------------------------------------------------------------
function Set-PowerControlNavigationState {
    <# expanded = full tree (flyout over the content, or pushing it when pinned); collapsed = icon rail #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][bool]$Expanded)

    $script:NavigationExpanded = $Expanded
    $L = $script:Layout
    if ($Expanded) {
        $NavigationPanel.Width = $L.NavWidth
        $NavigationRail.Visibility = 'Collapsed'
        $NavigationMenuTree.Visibility = 'Visible'
        $NavigationTitle.Visibility = 'Visible'
    }
    else {
        $NavigationPanel.Width = $L.RailWidth
        $NavigationRail.Visibility = 'Visible'
        $NavigationMenuTree.Visibility = 'Collapsed'
        $NavigationTitle.Visibility = 'Collapsed'
    }
    # pinned: the content moves aside; unpinned: the flyout overlays it
    $NavigationColumn.Width = [System.Windows.GridLength]::new($(if ($script:NavigationPinned -and $Expanded) { $L.NavWidth } else { $L.RailWidth }))
    Set-PowerControlButtonIcon -Button $NavigationPinButton -Icon $(if ($script:NavigationPinned) { 'lucide\panel-left-close.svg' } else { 'lucide\panel-left-open.svg' })
    $NavigationPinButton.ToolTip = if ($script:NavigationPinned) { 'Unpin navigation (collapses to the icon rail)' } else { 'Pin navigation' }
}

function New-PowerControlLabelContent {
    <# [icon] [label] row for code-built buttons, menu items and tabs #>
    param ([string]$Icon, [string]$Label, [double]$Size = 16, [string]$Text = $Label)
    $panel = [System.Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'
    [void]$panel.Children.Add((New-PowerControlIconElement -Icon $Icon -Label $Label -Size $Size))
    $textBlock = [System.Windows.Controls.TextBlock]::new(); $textBlock.Text = $Text; $textBlock.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0); $textBlock.VerticalAlignment = 'Center'
    $textBlock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'PowerControlTextBrush')
    [void]$panel.Children.Add($textBlock)
    $panel
}

function Invoke-PowerControlElementEditor {
    <# right click on a rail icon or popup entry: opens the element editor (EditTreeView) for that element, like the right click in the expanded trees #>
    param ([Parameter(Mandatory = $true)][string]$Uid)
    $NavigationPopup.IsOpen = $false
    $ActionPopup.IsOpen = $false
    $editor = @($PowerControl.JsonCache.PCtrlItems.Where({ $_.type -eq 'EditTreeView' }))
    if ($editor.Count -ne 1) { return }
    # the editor script reads the element id from $PowerControl.EventParams.Sender.uid
    $Global:PowerControl.EventParams.Sender = [pscustomobject]@{ uid = $Uid; tag = $null; Parent = $null; Header = $null; PlacementTarget = $null }
    $Global:PowerControl.EventParams.Args = $null
    Invoke-PowerControlSequence -ID $editor[0].id -SkipPostScript
}

function Update-PowerControlNavigationRail {
    <# one icon button per top-level navigation node; hovering shows that group's entries in a popup (the full tree only when pinned) #>
    $NavigationRail.Children.Clear()
    # favourite menus (settings FavoriteMenus): star badge at the top with their popup
    $favorites = @(Get-PowerControlFavoriteMenuNodes)
    if ($favorites.Count -gt 0) {
        $button = [System.Windows.Controls.Button]::new()
        $button.Width = 40; $button.Height = 34; $button.Padding = [System.Windows.Thickness]::new(0)
        $button.Margin = [System.Windows.Thickness]::new(4, 1, 4, 1)
        $button.Background = [System.Windows.Media.Brushes]::Transparent; $button.BorderThickness = [System.Windows.Thickness]::new(0)
        $button.ToolTip = "Favorites  ($($favorites.Count) menus)"
        $button.Tag = 'Favorites'
        $button.Content = New-PowerControlIconElement -Icon 'lucide\star.svg' -Label 'Favorites' -Size 18
        $button.Add_MouseEnter({ param($s, $e) $script:NavigationCollapseTimer.Stop(); Show-PowerControlNavigationPopup -Target $s -Entries (Get-PowerControlFavoriteMenuNodes) -Title 'Favorites' })
        $button.Add_MouseLeave({ param($s, $e) $script:NavigationCollapseTimer.Start() })
        $button.Add_Click({ param($s, $e) Show-PowerControlNavigationPopup -Target $s -Entries (Get-PowerControlFavoriteMenuNodes) -Title 'Favorites' })
        [void]$NavigationRail.Children.Add($button)
    }
    foreach ($node in @($NavigationMenuTree.Items)) {
        $json = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $node.Uid }, 'First')[0]
        $label = if ($node.Tag) { [string]$node.Tag } else { 'Menu' }
        $button = [System.Windows.Controls.Button]::new()
        $button.Width = 40; $button.Height = 34; $button.Padding = [System.Windows.Thickness]::new(0)
        $button.Margin = [System.Windows.Thickness]::new(4, 1, 4, 1)
        $button.Background = [System.Windows.Media.Brushes]::Transparent
        $button.BorderThickness = [System.Windows.Thickness]::new(0)
        $button.ToolTip = $label
        $button.Tag = $node
        $button.Content = New-PowerControlIconElement -Icon $(if ($json) { $json.icon } else { '' }) -Label $label -Size 18
        $button.Add_MouseEnter({ param($s, $e) $script:NavigationCollapseTimer.Stop(); Show-PowerControlNavigationPopup -Target $s })
        $button.Add_MouseLeave({ param($s, $e) $script:NavigationCollapseTimer.Start() })
        $button.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PowerControlElementEditor -Uid ([string]$s.Tag.Uid) })
        $button.Add_Click({
            param($s, $e)
            $node = $s.Tag
            $json = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $node.Uid }, 'First')[0]
            if ($node.Items.Count -eq 0 -and $null -ne $json -and $json.HasScript) {
                # a single menu (no group): the icon itself runs it
                $NavigationPopup.IsOpen = $false
                Invoke-PowerControlSequence -ID $node.Uid
            }
            else { Show-PowerControlNavigationPopup -Target $s }
        })
        [void]$NavigationRail.Children.Add($button)
    }
}

function Show-PowerControlNavigationPopup {
    <#
      popup next to a rail icon with the runnable entries of that group; -Entries / -Title show an explicit
      list instead (favourites badge). Every row carries the favourite star.
    #>
    param ($Target, $Entries, [string]$Title)
    $node = $Target.Tag
    if ($null -eq $Entries) {
        if ($node.Items.Count -gt 0) { $Entries = @($node.Items) } else { $Entries = @($node) }
        if (-not $Title) { $Title = if ($node.Tag) { [string]$node.Tag } else { 'Menu' } }
    }
    $NavigationPopupPanel.Children.Clear()

    # not $title: PowerShell variable names are case-insensitive and the [string] parameter would turn the TextBlock into a string
    $titleBlock = [System.Windows.Controls.TextBlock]::new()
    $titleBlock.Text = $Title
    $titleBlock.FontWeight = 'SemiBold'; $titleBlock.Margin = [System.Windows.Thickness]::new(10, 6, 10, 6)
    $titleBlock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'PowerControlSubtleBrush')
    [void]$NavigationPopupPanel.Children.Add($titleBlock)

    foreach ($entry in @($Entries)) {
        $json = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $entry.Uid }, 'First')[0]
        if ($null -eq $json -or -not $json.HasScript) { continue }
        $row = [System.Windows.Controls.DockPanel]::new(); $row.LastChildFill = $true
        $star = New-PowerControlStarButton -Id ([string]$entry.Uid) -Kind 'Menu' -Size 13
        [System.Windows.Controls.DockPanel]::SetDock($star, 'Right')
        [void]$row.Children.Add($star)
        $button = [System.Windows.Controls.Button]::new()
        $button.Content = New-PowerControlLabelContent -Icon $json.icon -Label ([string]$json.Label)
        $button.HorizontalContentAlignment = 'Left'; $button.HorizontalAlignment = 'Stretch'
        $button.Background = [System.Windows.Media.Brushes]::Transparent; $button.BorderThickness = [System.Windows.Thickness]::new(0)
        $button.Padding = [System.Windows.Thickness]::new(8, 5, 12, 5); $button.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1); $button.MinWidth = 200
        $button.ToolTip = if ($json.ToolTip) { $json.ToolTip } else { $json.Label }
        $button.Tag = $entry.Uid
        $button.Add_Click({ param($s, $e) $NavigationPopup.IsOpen = $false; Invoke-PowerControlSequence -ID $s.Tag })
        $button.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PowerControlElementEditor -Uid ([string]$s.Tag) })
        [void]$row.Children.Add($button)
        [void]$NavigationPopupPanel.Children.Add($row)
    }

    if ($NavigationPopupPanel.Children.Count -le 1) { $NavigationPopup.IsOpen = $false; return }
    $NavigationPopup.PlacementTarget = $Target
    $NavigationPopup.IsOpen = $true
}

# the popup closes when neither the rail nor the popup is under the mouse any more
$script:NavigationCollapseTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:NavigationCollapseTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:NavigationCollapseTimer.add_Tick({
    param($s, $e)
    $s.Stop()
    if (-not $NavigationPopupBorder.IsMouseOver -and -not $NavigationRail.IsMouseOver) { $NavigationPopup.IsOpen = $false }
})
$NavigationPopupBorder.Add_MouseEnter({ param($s, $e) $script:NavigationCollapseTimer.Stop() })
$NavigationPopupBorder.Add_MouseLeave({ param($s, $e) $script:NavigationCollapseTimer.Start() })
$PowerControlWindow.Add_Deactivated({ param($s, $e) $NavigationPopup.IsOpen = $false })
$NavigationPinButton.Add_Click({
    param($s, $e)
    $script:NavigationPinned = -not $script:NavigationPinned
    $Global:PowerControl.Settings.NavigationPinned = $script:NavigationPinned
    Save-PowerControlSettings
    Set-PowerControlNavigationState -Expanded $script:NavigationPinned
    if ($script:NavigationPinned) { foreach ($node in @($NavigationMenuTree.Items)) { $node.IsExpanded = $true } }
})

# ---- actions panel: icon rail, flyout on hover, pinned = pushes the content ---------------------------
function Set-PowerControlActionPanelState {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][bool]$Expanded)
    $script:ActionsExpanded = $Expanded
    $L = $script:Layout
    $ActionPanel.Width = if ($Expanded) { $L.ActionWidth } else { $L.ActionRailWidth }
    $ActionMenuTree.Visibility = if ($Expanded) { 'Visible' } else { 'Collapsed' }
    $ActionRailScroll.Visibility = if ($Expanded) { 'Collapsed' } else { 'Visible' }
    $ActionPanelTitle.Visibility = if ($Expanded) { 'Visible' } else { 'Collapsed' }
    # pinned: the content moves aside; unpinned: the flyout overlays it
    $ActionColumn.Width = [System.Windows.GridLength]::new($(if ($script:ActionsPinned -and $Expanded) { $L.ActionWidth } else { $L.ActionRailWidth }))
    Set-PowerControlButtonIcon -Button $ActionPanelToggle -Icon $(if ($script:ActionsPinned) { 'lucide\panel-right-close.svg' } else { 'lucide\panel-right-open.svg' })
    $ActionPanelToggle.ToolTip = if ($script:ActionsPinned) { 'Unpin actions (collapses to the icon rail, popups on hover)' } else { 'Pin actions' }
}

function New-PowerControlRailButton {
    param ($Content, [string]$ToolTip, $Tag)
    $button = [System.Windows.Controls.Button]::new()
    $button.Width = 40; $button.Height = 34; $button.Padding = [System.Windows.Thickness]::new(0)
    $button.Margin = [System.Windows.Thickness]::new(4, 1, 4, 1)
    $button.Background = [System.Windows.Media.Brushes]::Transparent
    $button.BorderThickness = [System.Windows.Thickness]::new(0)
    $button.ToolTip = $ToolTip
    $button.Tag = $Tag
    $button.Content = $Content
    $button
}

function Update-PowerControlActionRail {
    <#
      The collapsed panel does not open on hover (that would move the icon the user is aiming at).
      Single actions get an icon button that runs them; a category gets a badge button that opens a
      menu with the category's applicable actions, so the rail stays short even with many actions.
    #>
    $ActionRail.Children.Clear()
    $knownIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Global:PowerControl.JsonCache.PCtrlItems.id))
    # favourites (settings FavoriteActions, star in the popups): one badge at the top with the applicable favourites of all categories
    $favorites = @(Get-PowerControlFavoriteLeaves)
    if ($favorites.Count -gt 0) {
        $button = New-PowerControlRailButton -Content (New-PowerControlIconElement -Icon 'lucide\star.svg' -Label 'Favorites' -Size 18) -ToolTip "Favorites  ($($favorites.Count) actions)" -Tag 'Favorites'
        $button.Add_MouseEnter({ param($s, $e) $script:ActionPopupTimer.Stop(); Show-PowerControlActionPopup -Target $s -Leaves (Get-PowerControlFavoriteLeaves) -Title 'Favorites' })
        $button.Add_MouseLeave({ param($s, $e) $script:ActionPopupTimer.Start() })
        $button.Add_Click({ param($s, $e) Show-PowerControlActionPopup -Target $s -Leaves (Get-PowerControlFavoriteLeaves) -Title 'Favorites' })
        [void]$ActionRail.Children.Add($button)
    }
    foreach ($node in @($ActionMenuTree.Items)) {
        if ($node.Visibility -ne 'Visible') { continue }
        if ($knownIds.Contains([string]$node.Uid)) {
            $json = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $node.Uid }, 'First')[0]
            if ($null -eq $json) { continue }
            $button = New-PowerControlRailButton -Content (New-PowerControlIconElement -Icon $json.icon -Label $json.Label -Size 18) -ToolTip ([string]$json.Label) -Tag $node
            $button.Add_Click({ param($s, $e) Invoke-PowerControlAction -Sender $s.Tag -DataGrid $OutputGrid })
            $button.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PowerControlElementEditor -Uid ([string]$s.Tag.Uid) })
            $button.Add_MouseEnter({ param($s, $e) $script:ActionPopupTimer.Stop(); $ActionPopup.IsOpen = $false })
            [void]$ActionRail.Children.Add($button)
        }
        else {
            $leaves = @($node.Items | Where-Object { $_.Visibility -eq 'Visible' })
            if ($leaves.Count -eq 0) { continue }
            $category = if ($node.Tag) { [string]$node.Tag } else { 'Kategorie' }
            $button = New-PowerControlRailButton -Content (New-PowerControlIconElement -Icon '' -Label $category -Size 18) -ToolTip "$category  ($($leaves.Count) actions)" -Tag $node
            # same behaviour as the navigation rail: the popup opens on hover (and on click)
            $button.Add_MouseEnter({ param($s, $e) $script:ActionPopupTimer.Stop(); Show-PowerControlActionPopup -Target $s })
            $button.Add_MouseLeave({ param($s, $e) $script:ActionPopupTimer.Start() })
            $button.Add_Click({ param($s, $e) Show-PowerControlActionPopup -Target $s })
            [void]$ActionRail.Children.Add($button)
        }
    }
}

function Get-PowerControlFavoriteLeaves {
    <# the tree items (single actions or category children) whose ID is in settings FavoriteActions and that apply to the selected row #>
    $favoriteIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Global:PowerControl.Settings.FavoriteActions | Where-Object { $_ }))
    if ($favoriteIds.Count -eq 0) { return @() }
    $knownIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Global:PowerControl.JsonCache.PCtrlItems.id))
    $leaves = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @($ActionMenuTree.Items)) {
        if ($node.Visibility -ne 'Visible') { continue }
        $candidates = if ($knownIds.Contains([string]$node.Uid)) { @($node) } else { @($node.Items) }
        foreach ($leaf in $candidates) { if ($leaf.Visibility -eq 'Visible' -and $favoriteIds.Contains([string]$leaf.Uid)) { $leaves.Add($leaf) } }
    }
    $leaves.ToArray()
}

# ---- favourites (actions and menus) --------------------------------------------------------------------
# settings FavoriteActions / FavoriteMenus hold element IDs. Stars in the popups, in both expanded trees and the
# job menu ("Favorit an/aus", main.xml) toggle them; the rails get a star badge, palette and start page list them first.
function Get-PowerControlFavoriteSettingKey { param ([string]$Kind) if ($Kind -eq 'Menu') { 'FavoriteMenus' } else { 'FavoriteActions' } }

function Test-PowerControlFavorite {
    param ([string]$Id, [string]$Kind = 'Action')
    @($Global:PowerControl.Settings[(Get-PowerControlFavoriteSettingKey $Kind)] | Where-Object { $_ }) -contains $Id
}

function Set-PowerControlFavorite {
    <# toggles an element in the favourites and refreshes every view that shows them #>
    param ([string]$Id, [string]$Kind = 'Action')
    $key = Get-PowerControlFavoriteSettingKey $Kind
    $current = @($Global:PowerControl.Settings[$key] | Where-Object { $_ })
    $Global:PowerControl.Settings[$key] = if ($current -contains $Id) { @($current | Where-Object { $_ -ne $Id }) } else { @($current) + @($Id) }
    Save-PowerControlSettings
    Update-PowerControlFavoriteViews
}

function Set-PowerControlFavoriteAction { param ([string]$Id) Set-PowerControlFavorite -Id $Id -Kind 'Action' }

function Update-PowerControlFavoriteViews {
    <# after a toggle (UI or the job menu via UI command RefreshFavorites): rails, tree stars, start page #>
    Update-PowerControlActionRail
    Update-PowerControlNavigationRail
    Update-PowerControlFavoriteStars
    Update-PowerControlStartPage
}

function New-PowerControlStarButton {
    <# the star toggle used in popups and trees; state (opacity, tooltip) comes from Update-PowerControlFavoriteStars #>
    param ([string]$Id, [string]$Kind = 'Action', [double]$Size = 12)
    $star = [System.Windows.Controls.Button]::new()
    $star.Content = New-PowerControlIconElement -Icon 'lucide\star.svg' -Label '*' -Size $Size
    $star.Background = [System.Windows.Media.Brushes]::Transparent; $star.BorderThickness = [System.Windows.Thickness]::new(0)
    $star.Padding = [System.Windows.Thickness]::new(5, 2, 4, 2); $star.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0); $star.VerticalAlignment = 'Center'
    $star.Tag = @{ Id = $Id; Kind = $Kind }
    $star.Add_Click({ param($s, $e) $e.Handled = $true; $ActionPopup.IsOpen = $false; $NavigationPopup.IsOpen = $false; Set-PowerControlFavorite -Id $s.Tag.Id -Kind $s.Tag.Kind })
    $star.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true })
    $isFavorite = Test-PowerControlFavorite -Id $Id -Kind $Kind
    $star.Opacity = if ($isFavorite) { 1.0 } else { 0.3 }
    $star.ToolTip = if ($isFavorite) { 'Remove from favorites' } else { 'Add to favorites (star badge at the top of the icon rail, first in palette and start page)' }
    $star
}

$script:FavoriteStars = @{}
function Add-PowerControlFavoriteStar {
    <#
      Appends the star to the header of a tree leaf (expanded actions panel or navigation). The header is
      Border > StackPanel (New-PowerControlTreeHeaderXaml); it becomes Border > Grid[StackPanel | star] so the
      star sits at the right edge, independent of the label length.
    #>
    param ($Item, [string]$Kind = 'Action')
    $border = $Item.Header
    if ($border -isnot [System.Windows.Controls.Border] -or $border.Child -isnot [System.Windows.Controls.StackPanel]) { return }
    $panel = $border.Child
    $border.Child = $null
    $grid = [System.Windows.Controls.Grid]::new()
    $textColumn = [System.Windows.Controls.ColumnDefinition]::new(); $textColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $starColumn = [System.Windows.Controls.ColumnDefinition]::new(); $starColumn.Width = [System.Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($textColumn); [void]$grid.ColumnDefinitions.Add($starColumn)
    $star = New-PowerControlStarButton -Id ([string]$Item.Uid) -Kind $Kind
    [System.Windows.Controls.Grid]::SetColumn($star, 1)
    [void]$grid.Children.Add($panel); [void]$grid.Children.Add($star)
    $border.Child = $grid
    $border.HorizontalAlignment = 'Stretch'
    $Item.HorizontalContentAlignment = 'Stretch'
    $script:FavoriteStars["$Kind|$($Item.Uid)"] = $star
}

function Update-PowerControlFavoriteStars {
    <# opacity + tooltip of the tree stars follow the settings #>
    foreach ($entry in @($script:FavoriteStars.GetEnumerator())) {
        $star = $entry.Value
        if ($null -eq $star) { continue }
        $isFavorite = Test-PowerControlFavorite -Id $star.Tag.Id -Kind $star.Tag.Kind
        $star.Opacity = if ($isFavorite) { 1.0 } else { 0.3 }
        $star.ToolTip = if ($isFavorite) { 'Remove from favorites' } else { 'Add to favorites (star badge at the top of the icon rail, first in palette and start page)' }
    }
}

function Get-PowerControlFavoriteMenuNodes {
    <# navigation tree items (single menus or group children) whose ID is a favourite menu and that are runnable #>
    $favoriteIds = @($Global:PowerControl.Settings.FavoriteMenus | Where-Object { $_ })
    if ($favoriteIds.Count -eq 0) { return @() }
    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @($NavigationMenuTree.Items)) {
        $candidates = if ($node.Items.Count -gt 0) { @($node.Items) } else { @($node) }
        foreach ($leaf in $candidates) { if ($favoriteIds -contains [string]$leaf.Uid) { $nodes.Add($leaf) } }
    }
    $nodes.ToArray()
}

function Show-PowerControlActionPopup {
    <#
      popup next to a category badge with the applicable actions of that category; -Leaves / -Title
      show an explicit list instead (favourites badge). Every row has a star that toggles the favourite.
    #>
    param ($Target, $Leaves, [string]$Title)
    $node = $Target.Tag
    if ($null -eq $Leaves) { $Leaves = @($node.Items); if (-not $Title) { $Title = if ($node.Tag) { [string]$node.Tag } else { 'Actions' } } }
    $ActionPopupPanel.Children.Clear()
    # not $title: PowerShell variable names are case-insensitive and the [string] parameter would turn the TextBlock into a string
    $titleBlock = [System.Windows.Controls.TextBlock]::new()
    $titleBlock.Text = $Title
    $titleBlock.FontWeight = 'SemiBold'; $titleBlock.Margin = [System.Windows.Thickness]::new(10, 6, 10, 6)
    $titleBlock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'PowerControlSubtleBrush')
    [void]$ActionPopupPanel.Children.Add($titleBlock)
    foreach ($leaf in @($Leaves)) {
        if ($leaf.Visibility -ne 'Visible') { continue }
        $json = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $leaf.Uid }, 'First')[0]
        if ($null -eq $json) { continue }
        $shortcut = if ($json.KeyBinding.Key) { "$(if ($json.KeyBinding.Modifiers -and $json.KeyBinding.Modifiers -ne 'None') { $json.KeyBinding.Modifiers + '+' })$($json.KeyBinding.Key)" } else { '' }
        $row = [System.Windows.Controls.DockPanel]::new(); $row.LastChildFill = $true
        $star = New-PowerControlStarButton -Id ([string]$leaf.Uid) -Kind 'Action' -Size 13
        [System.Windows.Controls.DockPanel]::SetDock($star, 'Right')
        [void]$row.Children.Add($star)
        $button = [System.Windows.Controls.Button]::new()
        $content = New-PowerControlLabelContent -Icon $json.icon -Label ([string]$json.Label)
        if ($shortcut) {
            $hint = [System.Windows.Controls.TextBlock]::new(); $hint.Text = $shortcut; $hint.Margin = [System.Windows.Thickness]::new(14, 0, 0, 0); $hint.VerticalAlignment = 'Center'; $hint.FontSize = 11
            $hint.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'PowerControlSubtleBrush')
            [void]$content.Children.Add($hint)
        }
        $button.Content = $content
        $button.HorizontalContentAlignment = 'Left'; $button.HorizontalAlignment = 'Stretch'
        $button.Background = [System.Windows.Media.Brushes]::Transparent; $button.BorderThickness = [System.Windows.Thickness]::new(0)
        $button.Padding = [System.Windows.Thickness]::new(8, 5, 12, 5); $button.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1); $button.MinWidth = 200
        if ($json.ToolTip) { $button.ToolTip = $json.ToolTip }
        $button.Tag = $leaf
        $button.Add_Click({ param($s, $e) $ActionPopup.IsOpen = $false; Invoke-PowerControlAction -Sender $s.Tag -DataGrid $OutputGrid })
        $button.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Invoke-PowerControlElementEditor -Uid ([string]$s.Tag.Uid) })
        [void]$row.Children.Add($button)
        [void]$ActionPopupPanel.Children.Add($row)
    }
    if ($ActionPopupPanel.Children.Count -le 1) { $ActionPopup.IsOpen = $false; return }
    $ActionPopup.PlacementTarget = $Target
    $ActionPopup.IsOpen = $true
}

$script:ActionPopupTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:ActionPopupTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:ActionPopupTimer.add_Tick({
    param($s, $e)
    $s.Stop()
    if (-not $ActionPopupBorder.IsMouseOver -and -not $ActionRail.IsMouseOver) { $ActionPopup.IsOpen = $false }
})
$ActionPopupBorder.Add_MouseEnter({ param($s, $e) $script:ActionPopupTimer.Stop() })
$ActionPopupBorder.Add_MouseLeave({ param($s, $e) $script:ActionPopupTimer.Start() })
$PowerControlWindow.Add_Deactivated({ param($s, $e) $ActionPopup.IsOpen = $false })
$ActionPanelToggle.Add_Click({
    param($s, $e)
    $script:ActionsPinned = -not $script:ActionsPinned
    $Global:PowerControl.Settings.ActionsCollapsed = -not $script:ActionsPinned
    Save-PowerControlSettings
    Set-PowerControlActionPanelState -Expanded $script:ActionsPinned
})

# ---- jobs panel -------------------------------------------------------------------------------------
function Set-PowerControlJobsState {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][bool]$Expanded)
    $StatusDataGrid.Visibility = if ($Expanded) { 'Visible' } else { 'Collapsed' }
    Set-PowerControlButtonIcon -Button $JobsPinButton -Icon $(if ($script:JobsPinned) { 'lucide\pin-off.svg' } else { 'lucide\pin.svg' }) -Size 14
    $JobsPinButton.ToolTip = if ($script:JobsPinned) { 'Unpin job list' } else { 'Pin job list' }
}

$script:JobsCollapseTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:JobsCollapseTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$script:JobsCollapseTimer.add_Tick({
    param($s, $e)
    $s.Stop()
    if (-not $script:JobsPinned -and -not $JobsPanel.IsMouseOver -and -not $StatusDataGridMenu.IsOpen) { Set-PowerControlJobsState -Expanded $false }
})
$JobsPanel.Add_MouseEnter({ param($s, $e) $script:JobsCollapseTimer.Stop(); Set-PowerControlJobsState -Expanded $true })
$JobsPanel.Add_MouseLeave({ param($s, $e) if (-not $script:JobsPinned) { $script:JobsCollapseTimer.Start() } })
$JobsPinButton.Add_Click({
    param($s, $e)
    $script:JobsPinned = -not $script:JobsPinned
    $Global:PowerControl.Settings.JobsPinned = $script:JobsPinned
    Save-PowerControlSettings
    Set-PowerControlJobsState -Expanded $true
})
function Update-PowerControlJobsToolbar {
    <# the buttons of the jobs bar come from Thread elements with Toolbar="Jobs" in the engine XML (e.g. "Clear finished jobs") #>
    $JobsToolbar.Children.Clear()
    $items = @($Global:PowerControl.JsonCache.PCtrlItems | Where-Object { $_.type -eq 'Thread' -and "$($_.Toolbar)" -eq 'Jobs' -and $_.Label } |
        Sort-Object @{ Expression = { if ($_.DisplayCondition.SortOrder) { [int]$_.DisplayCondition.SortOrder } else { 1000 } } }, Label)
    foreach ($item in $items) {
        $shortcut = if ($item.KeyBinding.Key) { " ($(if ($item.KeyBinding.Modifiers -and $item.KeyBinding.Modifiers -ne 'None') { $item.KeyBinding.Modifiers + '+' })$($item.KeyBinding.Key))" } else { '' }
        $panel = [System.Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'
        [void]$panel.Children.Add((New-PowerControlIconElement -Icon $item.icon -Label $item.Label -Size 14))
        $text = [System.Windows.Controls.TextBlock]::new(); $text.Text = [string]$item.Label; $text.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0); $text.VerticalAlignment = 'Center'
        [void]$panel.Children.Add($text)
        $button = [System.Windows.Controls.Button]::new()
        $button.Content = $panel; $button.MinHeight = 22; $button.Padding = [System.Windows.Thickness]::new(8, 0, 8, 0); $button.Margin = [System.Windows.Thickness]::new(4, 0, 4, 0)
        $button.ToolTip = "$(if ($item.ToolTip) { $item.ToolTip } else { $item.Label })$shortcut"
        $button.Tag = $item.id
        $button.Add_Click({
            param($s, $e)
            $rows = @()
            if ($StatusDataGrid.SelectedItems.Count -gt 0) { $rows = @($StatusDataGrid.SelectedItems) | ConvertTo-Json | ConvertFrom-Json }
            Invoke-PowerControlSequence -ID $s.Tag -SelectedEntries $rows -SkipPostScript
        })
        [void]$JobsToolbar.Children.Add($button)
    }
}

function Update-PowerControlJobsSummary {
    [System.Threading.Monitor]::Enter($Global:PowerControl.HistoryLock)
    try { $items = @($Global:PowerControl.History.ToArray()) } finally { [System.Threading.Monitor]::Exit($Global:PowerControl.HistoryLock) }
    $jobs = @($items | Where-Object { $_.NodeType -notin $Global:PowerControl.General.TransientNodeTypes })
    $running = @($jobs | Where-Object { $null -ne $_.Thread -and $null -ne $_.Thread.Handle -and -not $_.Thread.Handle.IsCompleted }).Count
    $pinned = @($jobs | Where-Object { $_.Pinned -eq $true }).Count
    $JobsSummary.Text = if ($jobs.Count -eq 0) { 'No jobs' } else { "$($jobs.Count) job$(if ($jobs.Count -ne 1) { 's' }) · $running running · $pinned pinned" }
}

