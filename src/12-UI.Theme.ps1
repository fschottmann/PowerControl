# PowerControl - 12-UI.Theme.ps1
# Fluent theme switch at runtime and compact styles
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

# ---- theme -----------------------------------------------------------------------------------------
function New-PowerControlIconElement {
    <# parsed icon element (Grid with the vector icon or a two letter badge) for use in code-built UI #>
    param ([string]$Icon, [string]$Label = '', [double]$Size = 16)
    $xaml = New-PowerControlIconXaml -Icon $Icon -Size $Size -Margin '0'
    if (-not $xaml) {
        $short = Get-PowerControlShortLabel -Label $Label
        $xaml = "<Border Width=`"$($Size + 4)`" Height=`"$($Size + 4)`" CornerRadius=`"4`" Background=`"{DynamicResource PowerControlBadgeBrush}`"><TextBlock Text=`"$([System.Security.SecurityElement]::Escape($short))`" FontSize=`"9`" FontWeight=`"SemiBold`" HorizontalAlignment=`"Center`" VerticalAlignment=`"Center`"/></Border>"
    }
    [Windows.Markup.XamlReader]::Parse("<Grid xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" xmlns:x=`"http://schemas.microsoft.com/winfx/2006/xaml`" Width=`"$($Size + 4)`" Height=`"$($Size + 4)`">$xaml</Grid>")
}

function Set-PowerControlButtonIcon {
    param ($Button, [string]$Icon, [double]$Size = 16)
    $Button.Content = New-PowerControlIconElement -Icon $Icon -Size $Size
}

function Update-PowerControlTheme {
    <# applies Light / Dark / System at runtime: ThemeMode of the window, the colour resources, dialogs follow via $PowerControl.General #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][ValidateSet('Light', 'Dark', 'System')][string]$Theme)

    $effective = Get-PowerControlEffectiveTheme -Theme $Theme
    # unchanged theme (e.g. the settings dialog saved other values): skip the rebuild, it flashes the window white
    if ($script:AppliedThemeKey -eq "$Theme|$effective") { return }
    $script:AppliedThemeKey = "$Theme|$effective"
    $Global:PowerControl.General.ThemeMode = $Theme
    $Global:PowerControl.General.Theme = $effective

    # 1) colour resources first: writing to Window.Resources AFTER ThemeMode drops the Fluent dictionary again
    $colors = Get-PowerControlThemeBrushes -Effective $effective
    foreach ($entry in $colors.GetEnumerator()) {
        $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($entry.Value))
        $brush.Freeze()
        $PowerControlWindow.Resources["PowerControl$($entry.Key)Brush"] = $brush
    }
    # plain TextBlocks inherit the window foreground; the theme does not restyle them on its own
    $PowerControlWindow.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($effective -eq 'Dark') { '#FFF0F0F0' } else { '#FF1B1B1B' })))

    # 2) theme (set to None first so a re-apply of the same value still re-merges the dictionary)
    try {
        $PowerControlWindow.ThemeMode = [System.Windows.ThemeMode]::None
        $PowerControlWindow.ThemeMode = [System.Windows.ThemeMode]::$Theme
        Write-DebugLog -Message "Theme applied: $Theme (effective $effective)" -Level 1 -LogFileName 'PowerControl.log'
    }
    catch {
        Write-DebugLog -Message "Fluent theme not available ($($_.Exception.Message)), default WPF look stays" -Level 1 -LogFileName 'PowerControl.log'
    }

    # 3) compact styles derive from the theme's implicit styles, so they come last
    Set-PowerControlCompactStyles
}

function Set-PowerControlCompactStyles {
    <# derives compact styles from the theme's implicit styles (the Fluent defaults are generous) #>
    $PowerControlWindow.FontSize = 12

    # two levels: a style must not reference itself (WPF seals styles recursively)
    $implicitTree = $PowerControlWindow.TryFindResource([System.Windows.Controls.TreeViewItem])
    $newTreeStyle = {
        $style = [System.Windows.Style]::new([System.Windows.Controls.TreeViewItem])
        if ($implicitTree -is [System.Windows.Style]) { $style.BasedOn = $implicitTree }
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::PaddingProperty, [System.Windows.Thickness]::new(2, 0, 2, 0)))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::MinHeightProperty, [double]26))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::MarginProperty, [System.Windows.Thickness]::new(0)))
        $style
    }
    $childTreeStyle = & $newTreeStyle
    $treeStyle = & $newTreeStyle
    $treeStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.ItemsControl]::ItemContainerStyleProperty, $childTreeStyle))
    $NavigationMenuTree.ItemContainerStyle = $treeStyle
    $ActionMenuTree.ItemContainerStyle = $treeStyle

    # The Fluent theme has no DataGrid styles, so header and cells fall back to the classic look
    # (white header with white text in dark mode). Both grids get theme brushes via DynamicResource.
    $implicitHeader = $OutputGrid.TryFindResource([System.Windows.Controls.Primitives.DataGridColumnHeader])
    $newHeaderStyle = {
        param([int]$VerticalPadding, [int]$MinHeight)
        $style = [System.Windows.Style]::new([System.Windows.Controls.Primitives.DataGridColumnHeader])
        if ($implicitHeader -is [System.Windows.Style]) { $style.BasedOn = $implicitHeader }
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::PaddingProperty, [System.Windows.Thickness]::new(6, $VerticalPadding, 6, $VerticalPadding)))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::MinHeightProperty, [double]$MinHeight))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::BackgroundProperty, [System.Windows.DynamicResourceExtension]::new('PowerControlPanelBrush')))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::ForegroundProperty, [System.Windows.DynamicResourceExtension]::new('PowerControlTextBrush')))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::BorderBrushProperty, [System.Windows.DynamicResourceExtension]::new('PowerControlPanelBorderBrush')))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::BorderThicknessProperty, [System.Windows.Thickness]::new(0, 0, 1, 1)))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::FontWeightProperty, [System.Windows.FontWeights]::SemiBold))
        $style
    }
    $headerStyle = & $newHeaderStyle 2 26
    $headerStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::ContextMenuProperty, $OutputGridHeaderMenu))
    $OutputGrid.ColumnHeaderStyle = $headerStyle
    $StatusDataGrid.ColumnHeaderStyle = & $newHeaderStyle 1 24

    # cells: flat, theme foreground, accent colour for the selection
    $implicitCell = $OutputGrid.TryFindResource([System.Windows.Controls.DataGridCell])
    $newCellStyle = {
        $style = [System.Windows.Style]::new([System.Windows.Controls.DataGridCell])
        if ($implicitCell -is [System.Windows.Style]) { $style.BasedOn = $implicitCell }
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::BorderThicknessProperty, [System.Windows.Thickness]::new(0)))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::PaddingProperty, [System.Windows.Thickness]::new(4, 0, 4, 0)))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::BackgroundProperty, [System.Windows.Media.Brushes]::Transparent))
        $style.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::ForegroundProperty, [System.Windows.DynamicResourceExtension]::new('PowerControlTextBrush')))
        $selected = [System.Windows.Trigger]::new()
        $selected.Property = [System.Windows.Controls.DataGridCell]::IsSelectedProperty
        $selected.Value = $true
        $selected.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::BackgroundProperty, [System.Windows.DynamicResourceExtension]::new('PowerControlSelectionBrush')))
        $selected.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::ForegroundProperty, [System.Windows.Media.Brushes]::White))
        $style.Triggers.Add($selected)
        $style
    }
    foreach ($grid in @($OutputGrid, $StatusDataGrid)) {
        $grid.CellStyle = & $newCellStyle
        $grid.Background = [System.Windows.Media.Brushes]::Transparent
        $grid.RowBackground = [System.Windows.Media.Brushes]::Transparent
        $grid.AlternatingRowBackground = $null
        $grid.BorderThickness = [System.Windows.Thickness]::new(0)
    }

    foreach ($item in @($menuBar.Items)) { $item.Padding = [System.Windows.Thickness]::new(8, 4, 8, 4) }
}

$Global:PowerControl.UI.ThemeSetter = [System.Action[string]]{ param([string]$requested) Update-PowerControlTheme -Theme $requested }
Update-PowerControlTheme -Theme $themeSetting

