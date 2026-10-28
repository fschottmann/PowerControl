# PowerControl - 11-UI.Window.ps1
# index load, settings, theme state, window XAML, watchers start, window parse, control variables
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

Update-JsonIndex -JsonFilePath $Global:PowerControl.General.JsonFilePath -xmlFolderPath $Global:PowerControl.General.enginePath

$Global:PowerControl.JsonCache = [System.IO.File]::ReadAllText($Global:PowerControl.General.JsonFilePath) | ConvertFrom-Json

# =================================================================================================
#  Shell: settings, theme, window XAML, controls, handlers, panels, start page, command palette
# =================================================================================================

$Global:PowerControl.Settings = Get-PowerControlSettings
# DebugLevel from settings.json unless given on the command line (the watchers below pick up $script:DebugLevel)
if (-not $script:DebugLevelFromCommandLine -and $null -ne $Global:PowerControl.Settings.DebugLevel -and "$($Global:PowerControl.Settings.DebugLevel)" -match '^[0-6]$') {
    $script:DebugLevel = [int]$Global:PowerControl.Settings.DebugLevel
}
$themeSetting = if ($Theme -eq 'Settings') { [string]$Global:PowerControl.Settings.Theme } else { $Theme }
if ($themeSetting -notin 'Light', 'Dark', 'System') { $themeSetting = 'System' }
$Global:PowerControl.General.ThemeMode = $themeSetting
$Global:PowerControl.General.Theme = Get-PowerControlEffectiveTheme -Theme $themeSetting

$script:NavigationPinned  = [bool]$Global:PowerControl.Settings.NavigationPinned
$script:NavigationExpanded = $script:NavigationPinned
$script:JobsPinned        = [bool]$Global:PowerControl.Settings.JobsPinned
$script:ActionsPinned     = -not [bool]$Global:PowerControl.Settings.ActionsCollapsed   # pinned = full panel pushes the content; otherwise icon rail + hover flyout
$script:CurrentOutputMenuId = $null
$script:Layout = @{ RailWidth = 48; NavWidth = 250; ActionWidth = 240; ActionRailWidth = 48 }

function Get-PowerControlThemeBrushes {
    <# colour set per effective theme; keys become window resources PowerControl<Key>Brush #>
    param ([Parameter(Mandatory = $true)][string]$Effective)
    if ($Effective -eq 'Dark') {
        @{ Icon = '#FFE6E6E6'; Badge = '#FF3C3C3C'; Panel = '#FF1F1F1F'; PanelBorder = '#FF3A3A3A'; Handle = '#FF4A4A4A'; HandleHover = '#FF6A6A6A'
           Accent = '#FF4CC2FF'; Selection = '#FF0A5DA8'; Subtle = '#FFA6A6A6'; Banner = '#FF442626'; BannerBorder = '#FFE37D7D'; Tile = '#FF2B2B2B'; TileHover = '#FF363636'; Text = '#FFF0F0F0' }
    }
    else {
        @{ Icon = '#FF3A3A3A'; Badge = '#FFE4E4E4'; Panel = '#FFF6F6F6'; PanelBorder = '#FFE1E1E1'; Handle = '#FFCCCCCC'; HandleHover = '#FFA9A9A9'
           Accent = '#FF0067C0'; Selection = '#FF0067C0'; Subtle = '#FF6B6B6B'; Banner = '#FFFDE7E9'; BannerBorder = '#FFC42B1C'; Tile = '#FFFFFFFF'; TileHover = '#FFEAF3FB'; Text = '#FF1B1B1B' }
    }
}

$brushes = Get-PowerControlThemeBrushes -Effective $Global:PowerControl.General.Theme
$navDef = Get-PowerControlNavigationDefinition

# ---- window XAML -----------------------------------------------------------------------------------
$Window_XAML = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="PowerControl"
    WindowStartupLocation="CenterScreen"
    Name="PowerControlWindow"
    Width="1500"
    Height="860"
    MinWidth="900"
    MinHeight="600"
    FontSize="12">
    <Window.Resources>
$(($brushes.GetEnumerator() | ForEach-Object { "      <SolidColorBrush x:Key=`"PowerControl$($_.Key)Brush`" Color=`"$($_.Value)`"/>" }) -join "`r`n")
"@

$Window_XAML += New-XamlElement -ElementType ContextMenu -ElementProperties $navDef.StatusDataGridMenu
$Window_XAML += New-XamlElement -ElementType ContextMenu -ElementProperties $navDef.OutputGridMenu
$Window_XAML += New-XamlElement -ElementType ContextMenu -ElementProperties $navDef.TreeViewMenu
$Window_XAML += New-XamlElement -ElementType ContextMenu -ElementProperties $navDef.OutputGridHeaderMenu

$Window_XAML += @"
    </Window.Resources>
    <Grid Name="MainLayoutGrid">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
"@

$Window_XAML += New-XamlElement -ElementType MenuBar -ElementProperties $navDef.MenuBar

$Window_XAML += @"
        <Grid Grid.Row="1" Name="BodyGrid">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Name="NavigationColumn" Width="$($script:Layout.RailWidth)"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Name="ActionColumn" Width="$($script:Layout.ActionWidth)"/>
            </Grid.ColumnDefinitions>

            <!-- content: header bar, error banner, output grid / start page -->
            <Grid Grid.Column="1" Name="ContentGrid" Margin="8,2,8,4">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid Name="HeaderBar" Grid.Row="0" MinHeight="30" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <WrapPanel Name="ActionBar" Grid.Column="0" VerticalAlignment="Center"/>
                    <TextBlock Name="RowCountText" Grid.Column="1" VerticalAlignment="Center" Margin="8,0" Foreground="{DynamicResource PowerControlSubtleBrush}"/>
                    <Border Grid.Column="2" Name="FilterBorder" Width="240" Height="26" CornerRadius="4" BorderThickness="1" BorderBrush="{DynamicResource PowerControlPanelBorderBrush}" Background="{DynamicResource PowerControlPanelBrush}" VerticalAlignment="Center">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Grid Width="14" Height="14" Margin="7,0,0,0">$(New-PowerControlIconXaml -Icon 'lucide\search.svg' -Size 14 -Margin '0')</Grid>
                            <TextBox Name="FilterBox" Grid.Column="1" BorderThickness="0" Background="Transparent" VerticalContentAlignment="Center" Padding="4,0,0,0" MinHeight="22" ToolTip="Filter (Ctrl+Shift+F): text in all visible columns"/>
                            <Button Name="FilterClearButton" Grid.Column="2" Width="22" Height="22" Padding="0" Margin="0,0,2,0" Background="Transparent" BorderThickness="0" Visibility="Collapsed" ToolTip="Clear filter">$(New-PowerControlIconXaml -Icon 'lucide\x.svg' -Size 12 -Margin '0')</Button>
                        </Grid>
                    </Border>
                </Grid>
                <!-- output tabs: the active menu plus one tab per pinned job (hidden while nothing is pinned) -->
                <Border Name="OutputTabStrip" Grid.Row="1" Visibility="Collapsed" Margin="0,0,0,4" BorderThickness="0,0,0,1" BorderBrush="{DynamicResource PowerControlPanelBorderBrush}">
                    <ScrollViewer HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled">
                        <StackPanel Name="OutputTabs" Orientation="Horizontal"/>
                    </ScrollViewer>
                </Border>
                <Border Name="ErrorBanner" Grid.Row="2" Visibility="Collapsed" CornerRadius="4" Padding="8,5" Margin="0,0,0,4" Background="{DynamicResource PowerControlBannerBrush}" BorderBrush="{DynamicResource PowerControlBannerBorderBrush}" BorderThickness="1">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Grid Width="16" Height="16">$(New-PowerControlIconXaml -Icon 'lucide\triangle-alert.svg' -Size 16 -Margin '0')</Grid>
                        <TextBlock Name="ErrorBannerText" Grid.Column="1" Margin="8,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                        <Button Name="ErrorBannerLogButton" Grid.Column="2" Content="Open log" Padding="8,2" Margin="4,0" MinHeight="22"/>
                        <Button Name="ErrorBannerCloseButton" Grid.Column="3" Width="22" Height="22" Padding="0" Background="Transparent" BorderThickness="0" ToolTip="Close">$(New-PowerControlIconXaml -Icon 'lucide\x.svg' -Size 12 -Margin '0')</Button>
                    </Grid>
                </Border>
                <Grid Grid.Row="3">
                    <DataGrid Name="OutputGrid"
                              CanUserResizeColumns="True" IsReadOnly="True" CanUserSortColumns="True" CanUserReorderColumns="True"
                              ContextMenu="{StaticResource OutputGridMenu}"
                              ScrollViewer.HorizontalScrollBarVisibility="Auto" ScrollViewer.VerticalScrollBarVisibility="Auto"
                              VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling"
                              RowHeight="26" HeadersVisibility="Column" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource PowerControlPanelBorderBrush}">
                        <DataGrid.ItemBindingGroup>
                            <BindingGroup Name="{x:Null}" NotifyOnValidationError="False" ValidatesOnNotifyDataError="True" SharesProposedValues="True" />
                        </DataGrid.ItemBindingGroup>
                    </DataGrid>
                    <ScrollViewer Name="StartPage" VerticalScrollBarVisibility="Auto" Background="{DynamicResource PowerControlPanelBrush}">
                        <StackPanel Name="StartPagePanel" Margin="28,20,28,20"/>
                    </ScrollViewer>
                </Grid>
            </Grid>

            <!-- navigation: icon rail; expands as flyout on hover, or stays open when pinned -->
            <Border Grid.Column="0" Grid.ColumnSpan="2" Name="NavigationPanel" Width="$($script:Layout.RailWidth)" HorizontalAlignment="Left" Panel.ZIndex="20"
                    Background="{DynamicResource PowerControlPanelBrush}" BorderBrush="{DynamicResource PowerControlPanelBorderBrush}" BorderThickness="0,0,1,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Height="34">
                        <Button Name="NavigationPinButton" Width="32" Height="28" Padding="0" Margin="8,3,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Background="Transparent" BorderThickness="0" ToolTip="Pin navigation">$(New-PowerControlIconXaml -Icon 'lucide\panel-left-open.svg' -Size 16 -Margin '0')</Button>
                        <TextBlock Name="NavigationTitle" Text="Navigation" Margin="48,0,0,0" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="{DynamicResource PowerControlSubtleBrush}" Visibility="Collapsed"/>
                    </Grid>
                    <StackPanel Name="NavigationRail" Grid.Row="1" Margin="0,2,0,0"/>
                    <!-- hover popup of the rail: only the entries of the hovered group, not the whole tree -->
                    <Popup Name="NavigationPopup" Placement="Right" HorizontalOffset="2" AllowsTransparency="True" StaysOpen="True" PopupAnimation="Fade">
                        <Border Name="NavigationPopupBorder" Background="{DynamicResource PowerControlPanelBrush}" BorderBrush="{DynamicResource PowerControlPanelBorderBrush}" BorderThickness="1" CornerRadius="6" Padding="4" MinWidth="210" Margin="0,0,8,8">
                            <Border.Effect><DropShadowEffect BlurRadius="10" ShadowDepth="2" Opacity="0.25"/></Border.Effect>
                            <StackPanel Name="NavigationPopupPanel"/>
                        </Border>
                    </Popup>
"@

$Window_XAML += New-XamlElement -ElementType TreeView -ElementProperties $navDef.NavigationMenuTree

$Window_XAML += @"
                </Grid>
            </Border>

            <!-- actions for the selected row: icon rail, flyout on hover, pinned = pushes the content -->
            <Border Grid.Column="1" Grid.ColumnSpan="2" Name="ActionPanel" Width="$($script:Layout.ActionWidth)" HorizontalAlignment="Right" Panel.ZIndex="20" Background="{DynamicResource PowerControlPanelBrush}" BorderBrush="{DynamicResource PowerControlPanelBorderBrush}" BorderThickness="1,0,0,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Height="34">
                        <TextBlock Name="ActionPanelTitle" Text="Actions" Margin="12,0,0,0" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="{DynamicResource PowerControlSubtleBrush}"/>
                        <Button Name="ActionPanelToggle" Width="32" Height="28" Padding="0" Margin="0,3,8,0" HorizontalAlignment="Right" VerticalAlignment="Top" Background="Transparent" BorderThickness="0" ToolTip="Pin actions">$(New-PowerControlIconXaml -Icon 'lucide\panel-right-close.svg' -Size 16 -Margin '0')</Button>
                    </Grid>
                    <ScrollViewer Name="ActionRailScroll" Grid.Row="1" Margin="0,2,0,0" Visibility="Collapsed" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Name="ActionRail"/>
                    </ScrollViewer>
                    <!-- hover popup of a category badge in the rail: the applicable actions of that category -->
                    <Popup Name="ActionPopup" Placement="Left" HorizontalOffset="-2" AllowsTransparency="True" StaysOpen="True" PopupAnimation="Fade">
                        <Border Name="ActionPopupBorder" Background="{DynamicResource PowerControlPanelBrush}" BorderBrush="{DynamicResource PowerControlPanelBorderBrush}" BorderThickness="1" CornerRadius="6" Padding="4" MinWidth="210" Margin="8,0,0,8">
                            <Border.Effect><DropShadowEffect BlurRadius="10" ShadowDepth="2" Opacity="0.25"/></Border.Effect>
                            <StackPanel Name="ActionPopupPanel"/>
                        </Border>
                    </Popup>
"@

$Window_XAML += New-XamlElement -ElementType TreeView -ElementProperties $navDef.ActionMenuTree

$Window_XAML += @"
                </Grid>
            </Border>
        </Grid>

        <!-- jobs: one line summary, the table opens on hover or stays open when pinned -->
        <Border Grid.Row="2" Name="JobsPanel" BorderThickness="0,1,0,0" BorderBrush="{DynamicResource PowerControlPanelBorderBrush}" Background="{DynamicResource PowerControlPanelBrush}">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Name="JobsBar" Height="26">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Grid Width="14" Height="14" Margin="12,0,0,0">$(New-PowerControlIconXaml -Icon 'lucide\activity.svg' -Size 14 -Margin '0')</Grid>
                    <TextBlock Name="JobsSummary" Grid.Column="1" Margin="8,0" VerticalAlignment="Center" Text="No jobs"/>
                    <StackPanel Name="JobsToolbar" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center"/>
                    <Button Name="JobsPinButton" Grid.Column="3" Width="28" Height="22" Padding="0" Margin="0,0,8,0" Background="Transparent" BorderThickness="0" ToolTip="Pin job list">$(New-PowerControlIconXaml -Icon 'lucide\pin.svg' -Size 14 -Margin '0')</Button>
                </Grid>
                <DataGrid Name="StatusDataGrid" Grid.Row="1" Height="170" Visibility="Collapsed" Margin="4,0,4,4"
                          ContextMenu="{StaticResource StatusDataGridMenu}" AutoGenerateColumns="False" IsReadOnly="True"
                          RowHeight="24" HeadersVisibility="Column" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource PowerControlPanelBorderBrush}">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Job" Binding="{Binding Name}" Width="220" />
                        <DataGridTextColumn Header="Status" Binding="{Binding State}" Width="190" />
                        <DataGridTextColumn Header="Pin" Binding="{Binding Pin}" Width="36" />
                        <DataGridTextColumn Header="Start" Binding="{Binding Started}" Width="70" />
                        <DataGridTextColumn Header="Last run" Binding="{Binding LastRun}" Width="70" />
                        <DataGridTextColumn Header="Output" Binding="{Binding Output}" Width="*" />
                    </DataGrid.Columns>
                </DataGrid>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

Write-DebugLog -Message $Window_XAML -Level 3 -LogFileName 'PowerControlGUI.xaml'

Start-ThreadWatcher
Start-UIUpdateWatcher
Start-HistoryWatcher

[xml]$Window_XAML = $Window_XAML
$strWriter = New-Object System.IO.StringWriter
$Window_XAML.Save($strWriter)
$xamlContent = $strWriter.ToString()
$strWriter.Dispose()
Remove-Variable -Name Window_XAML -ErrorAction SilentlyContinue

$Global:PowerControl.SynchronizedWindow = [Windows.Markup.XamlReader]::Parse($xamlContent)
$PowerControlWindow = $Global:PowerControl.SynchronizedWindow
Initialize-PowerControlUIBridge -Window $PowerControlWindow

# ---- controls --------------------------------------------------------------------------------------
$menuBar              = $PowerControlWindow.FindName('MenuBar')
$NavigationMenuTree   = $PowerControlWindow.FindName('NavigationMenuTree')
$NavigationPanel      = $PowerControlWindow.FindName('NavigationPanel')
$NavigationRail       = $PowerControlWindow.FindName('NavigationRail')
$NavigationPinButton  = $PowerControlWindow.FindName('NavigationPinButton')
$NavigationTitle      = $PowerControlWindow.FindName('NavigationTitle')
$NavigationColumn     = $PowerControlWindow.FindName('NavigationColumn')
$ActionMenuTree       = $PowerControlWindow.FindName('ActionMenuTree')
$ActionPanel          = $PowerControlWindow.FindName('ActionPanel')
$ActionPanelToggle    = $PowerControlWindow.FindName('ActionPanelToggle')
$ActionPanelTitle     = $PowerControlWindow.FindName('ActionPanelTitle')
$OutputGrid           = $PowerControlWindow.FindName('OutputGrid')
$StartPage            = $PowerControlWindow.FindName('StartPage')
$StartPagePanel       = $PowerControlWindow.FindName('StartPagePanel')
$FilterBox            = $PowerControlWindow.FindName('FilterBox')
$FilterClearButton    = $PowerControlWindow.FindName('FilterClearButton')
$RowCountText         = $PowerControlWindow.FindName('RowCountText')
$ErrorBanner          = $PowerControlWindow.FindName('ErrorBanner')
$ErrorBannerText      = $PowerControlWindow.FindName('ErrorBannerText')
$ErrorBannerLogButton = $PowerControlWindow.FindName('ErrorBannerLogButton')
$ErrorBannerCloseButton = $PowerControlWindow.FindName('ErrorBannerCloseButton')
$JobsPanel            = $PowerControlWindow.FindName('JobsPanel')
$JobsSummary          = $PowerControlWindow.FindName('JobsSummary')
$JobsToolbar          = $PowerControlWindow.FindName('JobsToolbar')
$ActionRail           = $PowerControlWindow.FindName('ActionRail')
$ActionRailScroll     = $PowerControlWindow.FindName('ActionRailScroll')
$ActionColumn         = $PowerControlWindow.FindName('ActionColumn')
$NavigationPopup      = $PowerControlWindow.FindName('NavigationPopup')
$NavigationPopupBorder = $PowerControlWindow.FindName('NavigationPopupBorder')
$NavigationPopupPanel = $PowerControlWindow.FindName('NavigationPopupPanel')
$ActionPopup          = $PowerControlWindow.FindName('ActionPopup')
$ActionPopupBorder    = $PowerControlWindow.FindName('ActionPopupBorder')
$ActionPopupPanel     = $PowerControlWindow.FindName('ActionPopupPanel')
$OutputTabStrip       = $PowerControlWindow.FindName('OutputTabStrip')
$OutputTabs           = $PowerControlWindow.FindName('OutputTabs')
$JobsPinButton        = $PowerControlWindow.FindName('JobsPinButton')
$StatusDataGrid       = $PowerControlWindow.FindName('StatusDataGrid')
$OutputGridMenu       = $PowerControlWindow.Resources['OutputGridMenu']
$StatusDataGridMenu   = $PowerControlWindow.Resources['StatusDataGridMenu']
$TreeViewMenu         = $PowerControlWindow.Resources['TreeViewMenu']
$OutputGridHeaderMenu = $PowerControlWindow.Resources['OutputGridHeaderMenu']

$global:OutputGrid = $OutputGrid
$script:ActionBar = $PowerControlWindow.FindName('ActionBar')

$OutputGrid.Focusable = $true
$StatusDataGrid.IsTabStop = $true
[System.Windows.Input.KeyboardNavigation]::SetDirectionalNavigation($OutputGrid, [System.Windows.Input.KeyboardNavigationMode]::Contained)
[System.Windows.Input.KeyboardNavigation]::SetDirectionalNavigation($StatusDataGrid, [System.Windows.Input.KeyboardNavigationMode]::Contained)
[System.Windows.Input.KeyboardNavigation]::SetTabNavigation($StatusDataGrid, [System.Windows.Input.KeyboardNavigationMode]::Cycle)
[System.Windows.Input.KeyboardNavigation]::SetTabNavigation($OutputGrid, [System.Windows.Input.KeyboardNavigationMode]::Cycle)

