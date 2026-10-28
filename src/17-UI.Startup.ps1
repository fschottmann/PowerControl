# PowerControl - 17-UI.Startup.ps1
# handler registration, navigation refresh, UI tick, window events, ShowDialog, shutdown
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

# ---- handler registration + live refresh --------------------------------------------------------------------
$menuBar.Add_MouseRightButtonUp($menuBar_MouseRightButtonUp)

$OutputGrid.Add_Loaded($OutputGrid_Loaded)
$OutputGrid.Add_GotFocus($OutputGrid_GotFocus)
$OutputGrid.Add_SelectionChanged($OutputGrid_SelectionChanged)
$OutputGrid.Add_PreviewKeyDown($OutputGrid_PreviewKeyDown)
# Ctrl+Tab never bubbles up to the window's InputBindings (the DataGrid and WPF's control-tab navigation take it
# first; Ctrl+Shift+Tab did arrive). The tunnelling handler runs the matching XML KeyBinding itself, so the tab
# shortcuts stay data-driven (Command elements in main.xml) and nothing is hard-coded here.
$PowerControlWindow.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -ne [System.Windows.Input.Key]::Tab -or $e.KeyboardDevice.Modifiers -eq [System.Windows.Input.ModifierKeys]::None) { return }
    foreach ($binding in @($s.InputBindings)) {
        if ($binding -isnot [System.Windows.Input.KeyBinding] -or $binding.Key -ne $e.Key -or $binding.Modifiers -ne $e.KeyboardDevice.Modifiers) { continue }
        $e.Handled = $true
        if ($binding.Command.CanExecute($binding.CommandParameter, $s)) { $binding.Command.Execute($binding.CommandParameter, $s) }
        return
    }
})
$OutputGrid.Add_MouseDoubleClick($PowerControlAction_UseDefaultAction)
$OutputGrid.Add_MouseRightButtonUp($OutputGrid_MouseRightButtonUp)

$StatusDataGrid.Add_SelectionChanged($StatusDataGrid_SelectionChanged)
$StatusDataGrid.Add_PreviewKeyDown($StatusDataGrid_PreviewKeyDown)
$StatusDataGrid.Add_MouseDoubleClick($PowerControlAction_UseDefaultAction)
$StatusDataGrid.Add_MouseRightButtonUp($StatusDataGrid_MouseRightButtonUp)

function Register-PowerControlNavigationHandlers {
    <# attaches the handlers to the items of menu bar, both trees and the four context menus (called at start-up and after every refresh) #>
    [CmdletBinding()]
    param()

    foreach ($menuItem in @($menuBar.Items)) {
        $menuItem.Add_Click($MenuBar_AddClick)
        foreach ($secondLevelItem in @($menuItem.Items)) {
            $secondLevelItem.Add_Click($MenuBar_AddClick)
            $secondLevelItem.Add_PreviewMouseRightButtonDown($PowerControlTemp_senderUID)
        }
    }

    $script:FavoriteStars = @{}
    $runnableIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.HasScript }).id))
    foreach ($menuItem in @($NavigationMenuTree.Items)) {
        $menuItem.Add_MouseRightButtonDown($PowerControlTemp_senderUID)
        $menuItem.Add_MouseLeftButtonUp($NavigationMenuTree_MouseLeftButtonUp)
        $menuItem.Add_MouseRightButtonUp($NavigationMenuTree_MouseRightButtonUp)
        if ($menuItem.Items.Count -eq 0 -and $runnableIds.Contains([string]$menuItem.Uid)) { Add-PowerControlFavoriteStar -Item $menuItem -Kind 'Menu' }
        foreach ($secondLevelItem in @($menuItem.Items)) {
            $secondLevelItem.Add_MouseRightButtonDown($PowerControlTemp_senderUID)
            $secondLevelItem.Add_MouseLeftButtonUp($NavigationMenuTree_MouseLeftButtonUp)
            $secondLevelItem.Add_MouseRightButtonUp($NavigationMenuTree_MouseRightButtonUp)
            if ($runnableIds.Contains([string]$secondLevelItem.Uid)) { Add-PowerControlFavoriteStar -Item $secondLevelItem -Kind 'Menu' }
        }
    }

    $knownIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Global:PowerControl.JsonCache.PCtrlItems.id))
    foreach ($menuItem in @($ActionMenuTree.Items)) {
        if ($knownIds.Contains([string]$menuItem.Uid)) {
            $menuItem.Add_MouseRightButtonDown($PowerControlTemp_senderUID)
            $menuItem.Add_MouseLeftButtonUp($ActionMenuTree_MouseLeftButtonUp)
            $menuItem.Add_MouseRightButtonUp($ActionMenuTree_MouseRightButtonUp)
            Add-PowerControlFavoriteStar -Item $menuItem -Kind 'Action'
        }
        else {
            $menuItem.Add_Expanded($ActionMenuTree_Expanded)
            $menuItem.Add_Collapsed($ActionMenuTree_Collapsed)
            $menuItem.Add_MouseRightButtonUp($HandledTrue)
            $menuItem.Add_MouseLeftButtonUp($HandledTrue)
            $menuItem.FontWeight = 'SemiBold'
            foreach ($secondLevelItem in @($menuItem.Items)) {
                $secondLevelItem.FontWeight = 'Normal'
                $secondLevelItem.Add_MouseRightButtonDown($PowerControlTemp_senderUID)
                $secondLevelItem.Add_MouseLeftButtonUp($ActionMenuTree_MouseLeftButtonUp)
                $secondLevelItem.Add_MouseRightButtonUp($ActionMenuTree_MouseRightButtonUp)
                Add-PowerControlFavoriteStar -Item $secondLevelItem -Kind 'Action'
            }
        }
    }

    foreach ($menuItem in @($TreeViewMenu.Items)) {
        $menuItem.Add_Click($TreeViewMenu_AddClick)
        foreach ($secondLevelItem in @($menuItem.Items)) { $secondLevelItem.Add_Click($TreeViewMenu_AddClick) }
    }
    foreach ($menuItem in @($OutputGridHeaderMenu.Items)) {
        $menuItem.Add_Click($OutputGridHeaderMenu_AddClick)
        foreach ($secondLevelItem in @($menuItem.Items)) { $secondLevelItem.Add_Click($OutputGridHeaderMenu_AddClick) }
    }
    foreach ($menuItem in @($OutputGridMenu.Items)) {
        $menuItem.Add_Click($OutputGridMenu_AddClick)
        $menuItem.Add_KeyDown($OnSpaceRaiseEvent_ClickEvent)
        foreach ($secondLevelItem in @($menuItem.Items)) {
            $secondLevelItem.Add_Click($OutputGridMenu_AddClick)
            $secondLevelItem.Add_KeyDown($OnSpaceRaiseEvent_ClickEvent)
        }
    }
    foreach ($menuItem in @($StatusDataGridMenu.Items)) {
        $menuItem.Add_Click($StatusDataGridMenu_AddClick)
        $menuItem.Add_KeyDown($OnSpaceRaiseEvent_ClickEvent)
        foreach ($secondLevelItem in @($menuItem.Items)) {
            $secondLevelItem.Add_Click($StatusDataGridMenu_AddClick)
            $secondLevelItem.Add_KeyDown($OnSpaceRaiseEvent_ClickEvent)
        }
    }

    foreach ($item in @($menuBar.Items)) { $item.Padding = [System.Windows.Thickness]::new(8, 4, 8, 4) }
}

function Update-PowerControlNavigation {
    <# rebuilds menu bar, both trees, the context menus, the rail and the start page from the engine XML (no restart) #>
    [CmdletBinding()]
    param()

    Write-DebugLog -Message 'Refreshing navigation from engine XML' -Level 1 -LogFileName 'PowerControl.log'
    $script:CommandFastPath = @{}   # Command scripts may have changed
    Update-JsonIndex -JsonFilePath $Global:PowerControl.General.JsonFilePath -xmlFolderPath $Global:PowerControl.General.enginePath
    $Global:PowerControl.JsonCache = [System.IO.File]::ReadAllText($Global:PowerControl.General.JsonFilePath) | ConvertFrom-Json
    $navDef = Get-PowerControlNavigationDefinition
    $xmlns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

    $moveItems = {
        param($From, $To)
        $items = @($From.Items)
        $From.Items.Clear()
        $To.Items.Clear()
        foreach ($item in $items) { [void]$To.Items.Add($item) }
    }

    foreach ($name in 'StatusDataGridMenu', 'OutputGridMenu', 'TreeViewMenu', 'OutputGridHeaderMenu') {
        $fragment = New-XamlElement -ElementType ContextMenu -ElementProperties $navDef[$name]
        $fragment = [regex]::Replace($fragment, '<ContextMenu Name="(\w+)" x:Key="\w+">', "<ContextMenu $xmlns Name=`"`$1`">", 1)
        & $moveItems ([Windows.Markup.XamlReader]::Parse($fragment)) $PowerControlWindow.Resources[$name]
    }

    $fragment = New-XamlElement -ElementType MenuBar -ElementProperties $navDef.MenuBar
    $fragment = [regex]::Replace($fragment, '<Menu ', "<Menu $xmlns ", 1)
    & $moveItems ([Windows.Markup.XamlReader]::Parse($fragment)) $menuBar

    foreach ($name in 'NavigationMenuTree', 'ActionMenuTree') {
        $fragment = New-XamlElement -ElementType TreeView -ElementProperties $navDef[$name]
        $fragment = $fragment.Replace('{StaticResource ', '{DynamicResource ')
        $fragment = [regex]::Replace($fragment, '<TreeView ', "<TreeView $xmlns ", 1)
        & $moveItems ([Windows.Markup.XamlReader]::Parse($fragment)) $PowerControlWindow.FindName($name)
    }

    Register-PowerControlNavigationHandlers
    Register-PowerControlKeyBinding -Target $PowerControlWindow -BindingType 'Menu'
    Update-PowerControlNavigationRail
    Update-PowerControlJobsToolbar
    Update-PowerControlStartPage
    if ($script:NavigationPinned) { foreach ($node in @($NavigationMenuTree.Items)) { $node.IsExpanded = $true } }

    if ($null -ne $OutputGrid.SelectedItem) {
        Set-MenuNodeVisibility -MenuItems $OutputGridMenu.Items -SelectedItem $OutputGrid.SelectedItem
        Set-MenuNodeVisibility -MenuItems $ActionMenuTree.Items -SelectedItem $OutputGrid.SelectedItem -IsTreeView
    }
    Update-PowerControlActionRail

    Write-DebugLog -Message "Navigation refreshed: $($menuBar.Items.Count) menu bar entries, $($NavigationMenuTree.Items.Count) navigation nodes, $($ActionMenuTree.Items.Count) action categories, $($Global:PowerControl.JsonCache.PCtrlItems.Count) elements" -Level 1 -LogFileName 'PowerControl.log'
    Save-PowerControlIconCache
}

Register-PowerControlNavigationHandlers
Update-PowerControlNavigationRail
Update-PowerControlStartPage
Set-PowerControlNavigationState -Expanded $script:NavigationExpanded
if ($script:NavigationPinned) { foreach ($node in @($NavigationMenuTree.Items)) { $node.IsExpanded = $true } }
Set-PowerControlActionPanelState -Expanded $script:ActionsPinned
Update-PowerControlJobsToolbar
Update-PowerControlOutputTabs -Force
Set-PowerControlJobsState -Expanded $script:JobsPinned
Update-PowerControlJobsSummary

<#
  UI tick (1 s): navigation refresh (dirty flag from saves, external edits of engine\*.xml),
  job summary, error banner, Windows theme changes while "System" is selected
#>
# ---- finished-job notification (balloon tip + taskbar flash while the window is in the background) ------------
if (-not ('PowerControlNative' -as [type])) {
    Add-Type -Namespace Win32 -Name PowerControlNative -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr hWnd, bool bInvert);'
}
$script:RunningJobKeys = @{}
$script:NotifyIcon = $null

# ---- tray icon: find PowerControl quickly, switch tabs, open the palette, quit -----------------------------
function New-PowerControlTrayIconImage {
    <# renders the Lucide "zap" icon into a 32 px icon; falls back to the pwsh icon #>
    try {
        # white glyph on an accent tile: readable on light and dark taskbars
        $xaml = (New-PowerControlIconXaml -Icon 'lucide\zap.svg' -Size 22 -Margin '5') -replace '\{DynamicResource PowerControlIconBrush\}', '#FFFFFFFF'
        $element = [Windows.Markup.XamlReader]::Parse("<Border xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" xmlns:x=`"http://schemas.microsoft.com/winfx/2006/xaml`" Width=`"32`" Height=`"32`" CornerRadius=`"7`" Background=`"#FF0067C0`"><Grid Width=`"32`" Height=`"32`">$xaml</Grid></Border>")
        $element.Measure([System.Windows.Size]::new(32, 32)); $element.Arrange([System.Windows.Rect]::new(0, 0, 32, 32)); $element.UpdateLayout()
        $target = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(32, 32, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $target.Render($element)
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($target))
        $stream = [System.IO.MemoryStream]::new(); $encoder.Save($stream); $stream.Position = 0
        $bitmap = [System.Drawing.Bitmap]::new($stream)
        return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
    }
    catch { return [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path) }
}

function Show-PowerControlWindowFromTray {
    if ($PowerControlWindow.WindowState -eq [System.Windows.WindowState]::Minimized) { $PowerControlWindow.WindowState = [System.Windows.WindowState]::Normal }
    $PowerControlWindow.Show()
    [void]$PowerControlWindow.Activate()
}

function Update-PowerControlTrayMenu {
    <# rebuilt every time the menu opens: the open tabs (click switches), show, palette, quit #>
    param ($Menu)
    $Menu.Items.Clear()
    $tabs = @(Get-PowerControlOutputTabList)
    if ($tabs.Count -gt 0) {
        $header = $Menu.Items.Add('Tabs'); $header.Enabled = $false
        foreach ($tab in $tabs) {
            $label = "$(if ($tab.IsChild) { '    › ' })$($tab.Item.Name)$(if ($tab.Key -eq $script:ShownTab) { '  •' })"
            $item = $Menu.Items.Add($label)
            $item.Tag = $tab.Key
            $item.add_Click({ param($s, $e) Show-PowerControlWindowFromTray; Select-PowerControlOutputTab -Key $s.Tag })
        }
        [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    }
    # repeating jobs ("Repeat..." in the job menu): interval, last run, run count; click shows the job
    $repeating = @(Get-PowerControlHistorySnapshot | Where-Object { $_.PSObject.Properties['Repeat'] -and [int]$_.Repeat -gt 0 })
    if ($repeating.Count -gt 0) {
        $header = $Menu.Items.Add('Repeating jobs'); $header.Enabled = $false
        foreach ($job in $repeating) {
            $last = if ($job.PSObject.Properties['LastRun'] -and $job.LastRun) { ([datetime]$job.LastRun).ToString('HH:mm:ss') } else { 'not yet' }
            $runs = if ($job.PSObject.Properties['RunCount']) { [int]$job.RunCount } else { 1 }
            $running = $null -ne $job.Thread.Handle -and -not $job.Thread.Handle.IsCompleted
            $seconds = [int]$job.Repeat
            $every = if ($seconds -lt 60) { "$seconds s" } elseif ($seconds -lt 3600) { "$([math]::Round($seconds / 60, 1)) min" } else { "$([math]::Round($seconds / 3600, 1)) h" }
            $item = $Menu.Items.Add("$($job.Name)  ·  every $every  ·  last $last  ·  $runs run$(if ($runs -ne 1) { 's' })$(if ($running) { '  ·  running' })")
            $item.Tag = Get-PowerControlTabKey $job
            $item.add_Click({ param($s, $e) Show-PowerControlWindowFromTray; Select-PowerControlOutputTab -Key $s.Tag })
        }
        [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    }
    $show = $Menu.Items.Add('Show PowerControl'); $show.Font = [System.Drawing.Font]::new($show.Font, [System.Drawing.FontStyle]::Bold)
    $show.add_Click({ param($s, $e) Show-PowerControlWindowFromTray })
    $palette = $Menu.Items.Add('Command palette (Ctrl+K)')
    $palette.add_Click({ param($s, $e) Show-PowerControlWindowFromTray; Show-PowerControlCommandPalette })
    [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $quit = $Menu.Items.Add('Quit')
    $quit.add_Click({ param($s, $e) $PowerControlWindow.Close() })
}

function Initialize-PowerControlTrayIcon {
    try {
        $script:NotifyIcon = [System.Windows.Forms.NotifyIcon]::new()
        $script:NotifyIcon.Icon = New-PowerControlTrayIconImage
        $script:NotifyIcon.Text = 'PowerControl'
        $script:NotifyIcon.Visible = $true
        $script:NotifyIcon.add_MouseDoubleClick({ param($s, $e) Show-PowerControlWindowFromTray })
        $script:NotifyIcon.add_BalloonTipClicked({ param($s, $e) Show-PowerControlWindowFromTray })
        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        $menu.add_Opening({ param($s, $e) Update-PowerControlTrayMenu -Menu $s })
        $script:NotifyIcon.ContextMenuStrip = $menu
    }
    catch { Write-DebugLog -Message "Tray icon failed: $_" -Level 1 -LogFileName 'UI.log' }
}
Initialize-PowerControlTrayIcon

function Show-PowerControlJobNotification {
    param ([string]$Name, [int]$Seconds)
    try {
        if ($null -eq $script:NotifyIcon) { Initialize-PowerControlTrayIcon }
        $script:NotifyIcon.ShowBalloonTip(5000, 'PowerControl: job finished', "$Name finished after $Seconds s.", [System.Windows.Forms.ToolTipIcon]::Info)
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($PowerControlWindow).Handle
        if ($handle -ne [IntPtr]::Zero) { [void][Win32.PowerControlNative]::FlashWindow($handle, $true) }
        Write-DebugLog -Message "Job notification: $Name after $Seconds s" -Level 2 -LogFileName 'UI.log'
    }
    catch { Write-DebugLog -Message "Job notification failed: $_" -Level 1 -LogFileName 'UI.log' }
}

function Update-PowerControlJobWatch {
    <# UI tick: a job that ran 5 s or longer and finished while the window is not active triggers a notification #>
    $now = @{}
    foreach ($item in (Get-PowerControlHistorySnapshot)) {
        if ($item.NodeType -in $Global:PowerControl.General.TransientNodeTypes) { continue }
        if ($null -ne $item.Thread -and $null -ne $item.Thread.Handle -and -not $item.Thread.Handle.IsCompleted) { $now["$($item.ID)|$($item.Timestamp)"] = $item }
    }
    foreach ($key in @($script:RunningJobKeys.Keys)) {
        if ($now.ContainsKey($key)) { continue }
        $item = $script:RunningJobKeys[$key]
        $seconds = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long][double]$item.Timestamp)
        if ($seconds -ge 5 -and -not $PowerControlWindow.IsActive -and $Global:PowerControl.Settings.NotifyOnFinish -ne $false) {
            Show-PowerControlJobNotification -Name ([string]$item.Name) -Seconds $seconds
        }
    }
    $script:RunningJobKeys = $now
}

function Update-PowerControlWindowTitle {
    <# "PowerControl - <menu or job>" for the shown tab: context sensitive tools can key on the window title #>
    $name = ''
    if ($script:ShownTab) {
        $tab = Find-PowerControlOutputTab -Key $script:ShownTab
        if ($null -ne $tab) {
            $name = [string]$tab.Item.Name
            if ($tab.IsChild -and $null -ne $tab.Parent) { $name = "$($tab.Parent.Name) - $name" }
        }
    }
    $title = if ($name) { "PowerControl - $name" } else { 'PowerControl' }
    if ($PowerControlWindow.Title -ne $title) { $PowerControlWindow.Title = $title }
}

function Invoke-PowerControlRepeatJobs {
    <# jobs with Repeat (seconds; "Repeat..." in the job menu) run again on their own history entry once the interval passed #>
    [System.Threading.Monitor]::Enter($Global:PowerControl.HistoryLock)
    try { $items = @($Global:PowerControl.History | Where-Object { $_.PSObject.Properties['Repeat'] -and [int]$_.Repeat -gt 0 }) }
    finally { [System.Threading.Monitor]::Exit($Global:PowerControl.HistoryLock) }
    foreach ($item in $items) {
        if ($null -ne $item.Thread.Handle -and -not $item.Thread.Handle.IsCompleted) { continue }
        if ($null -ne $item.RepeatNext -and (Get-Date) -lt $item.RepeatNext) { continue }
        $item.RepeatNext = (Get-Date).AddSeconds([int]$item.Repeat)
        # keep the output of the run that is about to be replaced (Previous runs..., Compare with... > previous run)
        if ($null -ne $item.Output -and @($item.Output).Count -gt 0) {
            if (-not $item.PSObject.Properties['OutputHistory']) { $item | Add-Member -NotePropertyName OutputHistory -NotePropertyValue ([System.Collections.Generic.List[object]]::new()) }
            $when = if ($item.PSObject.Properties['LastRun'] -and $item.LastRun) { [datetime]$item.LastRun } else { try { [DateTimeOffset]::FromUnixTimeSeconds([long][double]$item.Timestamp).LocalDateTime } catch { Get-Date } }
            $item.OutputHistory.Insert(0, @{ Time = $when; Rows = @($item.Output) })
            $keep = if ($item.PSObject.Properties['RepeatHistory']) { [int]$item.RepeatHistory } else { 10 }
            while ($item.OutputHistory.Count -gt [Math]::Max(0, $keep)) { $item.OutputHistory.RemoveAt($item.OutputHistory.Count - 1) }
            # baseline for the change notification (first time only)
            if (-not $item.PSObject.Properties['LastSignature']) { $item | Add-Member -NotePropertyName LastSignature -NotePropertyValue (Get-PowerControlOutputSignature -Rows $item.Output) }
        }
        # LastRun / RunCount: shown in the jobs list ("Last run" column, "run N") and the tray menu
        $item | Add-Member -NotePropertyName LastRun -NotePropertyValue (Get-Date) -Force
        $item | Add-Member -NotePropertyName RunCount -NotePropertyValue ([int]$(if ($item.PSObject.Properties['RunCount']) { $item.RunCount } else { 1 }) + 1) -Force
        Write-DebugLog -Message "Repeat: running $($item.Name) again (every $($item.Repeat) s, run $($item.RunCount))" -Level 1 -LogFileName 'UI.log'
        try { Get-ActionSequence -ID $item.ID | Invoke-ActionScriptThreading -HistoryItem $item }
        catch { Add-PowerControlNotification -Source 'Repeat' -Message "$($item.Name): $($_.Exception.Message)" }
    }
}

function Get-PowerControlOutputSignature {
    <# cheap fingerprint of a job's rows (column=value per row) to notice changes between repeated runs #>
    param ($Rows)
    $text = (@($Rows | ForEach-Object { if ($null -ne $_) { (@($_.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|') } }) -join "`n")
    "$(@($Rows).Count):$($text.GetHashCode()):$($text.Length)"
}

function Show-PowerControlTrayMessage {
    param ([string]$Title, [string]$Text, [switch]$IsError)
    try {
        if ($null -eq $script:NotifyIcon) { Initialize-PowerControlTrayIcon }
        $script:NotifyIcon.ShowBalloonTip(6000, $Title, $Text, $(if ($IsError) { [System.Windows.Forms.ToolTipIcon]::Error } else { [System.Windows.Forms.ToolTipIcon]::Info }))
    }
    catch { Write-DebugLog -Message "Tray message failed: $_" -Level 1 -LogFileName 'UI.log' }
}

$script:RepeatSeenRun = @{}
function Update-PowerControlRepeatState {
    <#
      UI tick, repeating jobs: once a run has finished (RunCount advanced since the last look and the job is
      idle again; short jobs never show up as "running" between two ticks), its output fingerprint is compared
      with the previous run (banner + tray balloon on change, if RepeatNotify is set); errors the ThreadWatcher
      recorded in LastError go to the tray as well.
    #>
    foreach ($item in (Get-PowerControlHistorySnapshot)) {
        if (-not ($item.PSObject.Properties['Repeat'] -and [int]$item.Repeat -gt 0)) { continue }
        $key = "$($item.ID)|$($item.Timestamp)"
        $running = $null -ne $item.Thread -and $null -ne $item.Thread.Handle -and -not $item.Thread.Handle.IsCompleted
        $runCount = if ($item.PSObject.Properties['RunCount']) { [int]$item.RunCount } else { 1 }
        if (-not $script:RepeatSeenRun.ContainsKey($key)) { $script:RepeatSeenRun[$key] = $runCount }
        if (-not $running -and $script:RepeatSeenRun[$key] -ne $runCount) {
            $script:RepeatSeenRun[$key] = $runCount
            $signature = Get-PowerControlOutputSignature -Rows $item.Output
            $previous = if ($item.PSObject.Properties['LastSignature']) { $item.LastSignature } else { $null }
            $item | Add-Member -NotePropertyName LastSignature -NotePropertyValue $signature -Force
            if ($null -ne $previous -and $previous -ne $signature -and -not ($item.PSObject.Properties['RepeatNotify'] -and $item.RepeatNotify -eq $false)) {
                $count = @($item.Output).Count
                Add-PowerControlNotification -Source $item.Name -Message "Output changed at $((Get-Date).ToString('HH:mm:ss')): $count row(s) now. Compare with... > previous run shows the difference." -Severity Info
                Show-PowerControlTrayMessage -Title 'PowerControl: output changed' -Text "$($item.Name): $count row(s)"
                Write-DebugLog -Message "Repeat: output of $($item.Name) changed ($count rows)" -Level 1 -LogFileName 'UI.log'
            }
        }
        if ($item.PSObject.Properties['LastError'] -and $item.LastError) {
            Show-PowerControlTrayMessage -Title 'PowerControl: repeat failed' -Text "$($item.Name): $($item.LastError)" -IsError
            $item.LastError = $null
        }
    }
}

# ---- global hotkey (settings GlobalHotkey, e.g. "Ctrl+Alt+P"): brings the window to the front from anywhere -----
if (-not ('PowerControl.HotKey' -as [type])) {
    Add-Type -Namespace PowerControl -Name HotKey -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
'@
}
$script:GlobalHotkeyId = 0x5043   # 'PC'
$script:GlobalHotkeyHookAdded = $false
$script:GlobalHotkeyHook = {
    param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
    if ($msg -eq 0x0312 -and $wParam.ToInt32() -eq $script:GlobalHotkeyId) {   # WM_HOTKEY
        Show-PowerControlWindowFromTray
        $handled.Value = $true
    }
    [IntPtr]::Zero
}

function Register-PowerControlGlobalHotkey {
    <# (re)registers the gesture of settings GlobalHotkey; an empty setting switches it off. Nothing is hard-coded. #>
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($PowerControlWindow).Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    [void][PowerControl.HotKey]::UnregisterHotKey($hwnd, $script:GlobalHotkeyId)
    $gesture = [string]$Global:PowerControl.Settings.GlobalHotkey
    if ([string]::IsNullOrWhiteSpace($gesture)) { return }
    $parts = @($gesture.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $modifiers = 0x4000   # MOD_NOREPEAT
    if ($parts.Count -gt 1) {
        foreach ($part in $parts[0..($parts.Count - 2)]) {
            switch ($part.ToLowerInvariant()) {
                'ctrl'    { $modifiers = $modifiers -bor 0x2 }
                'control' { $modifiers = $modifiers -bor 0x2 }
                'alt'     { $modifiers = $modifiers -bor 0x1 }
                'shift'   { $modifiers = $modifiers -bor 0x4 }
                'win'     { $modifiers = $modifiers -bor 0x8 }
                default   { Add-PowerControlNotification -Source 'Global hotkey' -Message "Unknown modifier '$part' in '$gesture' (use Ctrl, Alt, Shift, Win)"; return }
            }
        }
    }
    $keyName = $parts[-1]
    if ($keyName -match '^\d$') { $keyName = "D$keyName" }
    $key = $keyName -as [System.Windows.Input.Key]
    if ($null -eq $key -or $key -eq [System.Windows.Input.Key]::None) { Add-PowerControlNotification -Source 'Global hotkey' -Message "Unknown key '$keyName' in '$gesture'"; return }
    $virtualKey = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
    if (-not [PowerControl.HotKey]::RegisterHotKey($hwnd, $script:GlobalHotkeyId, [uint32]$modifiers, [uint32]$virtualKey)) {
        Add-PowerControlNotification -Source 'Global hotkey' -Message "Could not register '$gesture' (already taken by another program?)"
        return
    }
    if (-not $script:GlobalHotkeyHookAdded) {
        [System.Windows.Interop.HwndSource]::FromHwnd($hwnd).AddHook([System.Windows.Interop.HwndSourceHook]$script:GlobalHotkeyHook)
        $script:GlobalHotkeyHookAdded = $true
    }
    Write-DebugLog -Message "Global hotkey registered: $gesture" -Level 1 -LogFileName 'UI.log'
}

$script:EngineLastWrite = (Get-ChildItem -Path (Join-Path $Global:PowerControl.General.enginePath '*.xml') | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
$script:EnginePendingWrite = $null
$script:UiTickCount = 0
$script:UiTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:UiTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:UiTimer.add_Tick({
    try {
        $script:UiTickCount++
        $script:InUiTick = $true   # Get-PowerControlOutputTabList caches its result for this tick

        # engine files on disk (every 2 s)
        if ($script:UiTickCount % 2 -eq 0) {
            $latest = (Get-ChildItem -Path (Join-Path $Global:PowerControl.General.enginePath '*.xml') | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
            if ($latest -ne $script:EngineLastWrite) {
                if ($script:EnginePendingWrite -eq $latest) {
                    $script:EngineLastWrite = $latest
                    $script:EnginePendingWrite = $null
                    $Global:PowerControl.WatcherState.NavigationDirty = $true
                    Write-DebugLog -Message 'Engine XML changed on disk, navigation refresh requested' -Level 1 -LogFileName 'PowerControl.log'
                }
                else { $script:EnginePendingWrite = $latest }
            }
        }
        if ($Global:PowerControl.WatcherState.NavigationDirty) {
            $Global:PowerControl.WatcherState.NavigationDirty = $false
            Update-PowerControlNavigation
            $script:EngineLastWrite = (Get-ChildItem -Path (Join-Path $Global:PowerControl.General.enginePath '*.xml') | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
        }

        Update-PowerControlJobsSummary
        Update-PowerControlOutputTabs
        Update-PowerControlShownTab
        Update-PowerControlJobWatch
        Update-PowerControlWindowTitle
        Update-PowerControlRepeatState
        Invoke-PowerControlRepeatJobs

        # error banner
        $queue = $Global:PowerControl.UI.Notifications
        if ($queue.Count -gt 0) {
            $last = $null
            while ($queue.Count -gt 0) { $last = $queue.Dequeue() }
            Show-PowerControlNotification -Notification $last
        }

        # Windows switched between light and dark while "System" is selected (every 5 s)
        if ($script:UiTickCount % 5 -eq 0 -and $Global:PowerControl.General.ThemeMode -eq 'System') {
            $effective = Get-PowerControlEffectiveTheme -Theme 'System'
            if ($effective -ne $Global:PowerControl.General.Theme) { Update-PowerControlTheme -Theme 'System' }
        }
    }
    catch {
        Write-DebugLog -Message "UI tick failed: $_ | $($_.ScriptStackTrace)" -Level 1 -LogFileName 'UI.log'
    }
    finally { $script:InUiTick = $false }
})
$script:UiTimer.Start()

# ---- window -----------------------------------------------------------------------------------------------
function Restore-PowerControlStartState {
    <# after the window is up: pinned menus of the last session run again and get their tabs back, then -Run #>
    $settings = $Global:PowerControl.Settings
    if ($settings.RestorePinnedTabs -ne $false -and @($settings.PinnedMenus).Count -gt 0) {
        foreach ($menuId in @($settings.PinnedMenus)) {
            $json = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $menuId }, 'First')[0]
            if ($null -eq $json -or -not $json.HasScript) { continue }
            Write-DebugLog -Message "Restoring pinned menu $($json.Label) [$menuId]" -Level 1 -LogFileName 'UI.log'
            try {
                Invoke-PowerControlSequence -ID $menuId
                $menu = Get-PowerControlActiveMenuItem
                if ($null -ne $menu -and $menu.ID -ceq $menuId) { $menu.Pinned = $true }
            }
            catch { Write-DebugLog -Message "Restoring pinned menu $menuId failed: $_" -Level 1 -LogFileName 'UI.log' }
        }
        Update-PowerControlOutputTabs -Force
    }
    if ($script:RunAtStart) {
        $id = Resolve-PowerControlElementId -Name $script:RunAtStart
        if ($id) { Invoke-PowerControlSequence -ID $id }
        else { Add-PowerControlNotification -Source '-Run' -Message "Element '$($script:RunAtStart)' nicht gefunden" }
    }
    # bundle subscriptions: fetched in the background (own runspace), results land in the jobs list and the banner
    if (@($settings.BundleSources | Where-Object { $_ }).Count -gt 0) {
        $syncId = 'BundleSync-1b2c3d4e5f60718293a4b5c6d7e8f9a0'
        if ($Global:PowerControl.JsonCache.PCtrlItems.Where({ $_.id -eq $syncId }, 'First')[0]) { Invoke-PowerControlSequence -ID $syncId -SkipPostScript }
    }
}

$PowerControlWindow.Add_Loaded({
    param($sender, $e)
    Register-PowerControlKeyBinding -Target $PowerControlWindow -BindingType 'Menu'
    Write-DebugLog -Message "Finished processing KeyBindings" -Level 2 -LogFileName 'PowerControl.log'
    try { Register-PowerControlGlobalHotkey } catch { Write-DebugLog -Message "Global hotkey failed: $_" -Level 1 -LogFileName 'UI.log' }
    $PowerControlWindow.Dispatcher.InvokeAsync({ Set-DataGridCellFocus }, [System.Windows.Threading.DispatcherPriority]::Render) | Out-Null
    $PowerControlWindow.Dispatcher.InvokeAsync({ Restore-PowerControlStartState }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
})
$PowerControlWindow.Add_Activated({ Set-DataGridCellFocus })
$PowerControlWindow.Add_Closing({
    param($sender, $e)
    Write-DebugLog -Message "Window closing requested (running jobs: $(@($PowerControl.History | Where-Object { $_.Thread.Handle -and -not $_.Thread.Handle.IsCompleted }).Count))" -Level 1 -LogFileName 'UI.log'
    $Global:PowerControl.WatcherState.Closing = $true   # releases nested wait frames (Wait-PowerControlHandle)
    try { $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($PowerControlWindow).Handle; if ($hwnd -ne [IntPtr]::Zero) { [void][PowerControl.HotKey]::UnregisterHotKey($hwnd, $script:GlobalHotkeyId) } } catch { }
    # an open modal child (command palette) would keep ShowDialog of the main window from returning
    foreach ($owned in @($sender.OwnedWindows)) { try { $owned.Close() } catch { } }
    try {
        # pinned menus come back at the next start (see Restore-PowerControlStartState)
        $Global:PowerControl.Settings.PinnedMenus = @((Get-PowerControlHistorySnapshot) | Where-Object { $_.Pinned -eq $true -and $_.NodeType -in 'Menu', 'MenuBar' } | ForEach-Object { [string]$_.ID } | Select-Object -Unique)
        Save-PowerControlColumnProfile
        Save-PowerControlSettings
    }
    catch { Write-DebugLog -Message "Saving settings on close failed: $_" -Level 1 -LogFileName 'UI.log' }
})

if ($script:StartupWatch) { Write-DebugLog -Message "Shell ready after $($script:StartupWatch.ElapsedMilliseconds) ms ($($Global:PowerControl.JsonCache.PCtrlItems.Count) elements, platform $($script:Platform))" -Level 1 -LogFileName 'UI.log' }
Save-PowerControlIconCache
[void]$PowerControlWindow.ShowDialog()

# shutdown: stop flag first (the watchers must not touch the dispatcher any more), UI timers, action runspaces, watcher loops
$shutdownWatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-DebugLog -Message "Window closed, shutdown started" -Level 1 -LogFileName 'UI.log'
$Global:PowerControl.WatcherState.Stop = $true
foreach ($timer in @($script:UiTimer, $script:NavigationCollapseTimer, $script:JobsCollapseTimer)) { if ($timer) { $timer.Stop() } }
# dialogs of action runspaces (Draw GUI) block their pipelines in ShowDialog; shutting down their dispatchers
# ends those message loops so Stop-PowerControlThreads can stop the runspaces instead of waiting for them
foreach ($dialog in @($Global:PowerControl.UI.OpenDialogs)) {
    try { $dialog.Dispatcher.BeginInvokeShutdown([System.Windows.Threading.DispatcherPriority]::Send) } catch { Write-DebugLog -Message "Closing dialog on shutdown failed: $_" -Level 1 -LogFileName 'UI.log' }
}
if ($Global:PowerControl.UI.OpenDialogs.Count -gt 0) { Write-DebugLog -Message "Shutdown closed $($Global:PowerControl.UI.OpenDialogs.Count) open dialog(s)" -Level 1 -LogFileName 'UI.log'; Start-Sleep -Milliseconds 300 }
if ($null -ne $script:NotifyIcon) { try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch { } }
Stop-PowerControlThreads
Stop-PowerControlWatchers
Write-DebugLog -Message "Shutdown finished after $($shutdownWatch.ElapsedMilliseconds) ms" -Level 1 -LogFileName 'UI.log'
if ([int]$Global:PowerControl.WatcherState.LeakedRunspaces -gt 0) {
    # a runspace stuck in a native call keeps a foreground thread alive, so the process would never exit on its own
    Write-DebugLog -Message "$($Global:PowerControl.WatcherState.LeakedRunspaces) runspace(s) could not be stopped, ending the process explicitly" -Level 1 -LogFileName 'UI.log'
    [System.Environment]::Exit(0)
}
