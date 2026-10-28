# PowerControl - 03-Core.Bridge.ps1
# functions injected into action runspaces: grid data, external interpreters, settings, theme, notifications, UI commands, UI bridge
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

function Get-PowerControlGridData {
    <#
      .SYNOPSIS
      Returns the rows and the visible column headers of a DataGrid of the main window.

      .DESCRIPTION
      WPF objects may only be touched on the UI thread. Action scripts run in their own
      runspaces, so this helper marshals the read through the window dispatcher and hands back
      plain data: Columns (visible headers in display order) and Rows (the bound objects).
      Export actions (ExportData.xml) and "Edit DataGrid" use it instead of touching the grid.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)][string]$GridName = 'OutputGrid',
        [Parameter(Mandatory = $false)][switch]$SelectedOnly
    )

    $window = $PowerControl.SynchronizedWindow
    $reader = $PowerControl.UI.GridReader
    $empty = [pscustomobject]@{ Columns = @(); Rows = @() }

    if ($null -eq $window -or $null -eq $window.Dispatcher -or $null -eq $reader) { return $empty }

    # The delegate belongs to the main runspace (Initialize-PowerControlUIBridge). A script block created
    # in this action runspace must not be executed by the UI thread: it is bound to a busy runspace and
    # the call either deadlocks or runs in the wrong session state.
    $arguments = [object[]]@([string]$GridName, [bool]$SelectedOnly)
    $data = if ($window.Dispatcher.CheckAccess()) {
        $reader.DynamicInvoke($arguments)
    }
    else {
        $window.Dispatcher.Invoke($reader, $arguments)
    }

    if ($null -eq $data) { return $empty }
    $data
}

function Find-PowerControlInterpreter {
    <#
      .SYNOPSIS
      Locates python.exe / node.exe: settings.json first, then PATH, then the usual installation folders.
      Returns the full path or $null. Used by Invoke-PowerControlExternal and as the prefill of the settings dialog.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][ValidateSet('Python', 'Node')][string]$Language)

    $configured = if ($null -ne $PowerControl.Settings -and $PowerControl.Settings.Interpreters) { [string]$PowerControl.Settings.Interpreters[$Language] } else { '' }
    if ($configured -and (Test-Path -LiteralPath $configured -PathType Leaf)) { return $configured }

    $names = switch ($Language) { 'Python' { @('python', 'py', 'python3') } 'Node' { @('node') } }
    foreach ($name in $names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        # the App Execution Aliases in WindowsApps are stubs that open the Store
        if ($command -and -not ($command.Source -like '*\WindowsApps\*')) { return $command.Source }
    }

    $patterns = switch ($Language) {
        'Python' { @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", 'C:\Python3*\python.exe', "$env:ProgramFiles\Python3*\python.exe", "${env:ProgramFiles(x86)}\Python3*\python.exe", "$env:LOCALAPPDATA\Programs\Python\Launcher\py.exe", "$env:WINDIR\py.exe") }
        'Node'   { @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe", "$env:NVM_SYMLINK\node.exe", "$env:APPDATA\nvm\v*\node.exe", "$env:APPDATA\fnm\aliases\default\node.exe", "$env:LOCALAPPDATA\Volta\bin\node.exe") }
    }
    foreach ($pattern in $patterns) {
        if (-not $pattern -or $pattern.StartsWith('\')) { continue }
        $found = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if ($found.Count -gt 0) { return $found[0].FullName }
    }
    $null
}

function Invoke-PowerControlExternal {
    <#
      .SYNOPSIS
      Runs a piece of code in an external interpreter (Python, Node.js or any command) from an action script.

      .DESCRIPTION
      The selected entries (or any objects) are passed to the program as a JSON array on stdin. Every
      stdout line that is a JSON object or array is turned back into PowerShell objects, other lines are
      returned as strings. The code is written to a temporary file and removed afterwards. A non-zero
      exit code or a timeout throws, so the problem shows up in logs\scripts.log like any other error.

      .PARAMETER Language
      Python (python.exe / py.exe from PATH), Node (node.exe from PATH) or Custom (-Interpreter required).

      .PARAMETER Code
      The program text. For Python read the input with  rows = json.load(sys.stdin)  and print one
      json.dumps(...) per result row.

      .EXAMPLE
      $Script:PowerControlItem_Output += Invoke-PowerControlExternal -Language Python -InputObject $script:SelectedEntries -Code @'
import sys, json
for row in json.load(sys.stdin):
    print(json.dumps({"Label": row["Label"], "Upper": row["Label"].upper()}))
'@
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('Python', 'Node', 'Custom')][string]$Language,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $false)][object[]]$InputObject,
        [Parameter(Mandatory = $false)][string]$Interpreter,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @(),
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 300,
        [Parameter(Mandatory = $false)][int]$Depth = 5,
        [Parameter(Mandatory = $false)][switch]$Raw
    )

    # explicit parameter, otherwise settings.json, PATH and the usual installation folders (Find-PowerControlInterpreter)
    $executable = $null
    if ($Interpreter) {
        $command = Get-Command $Interpreter -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $executable = if ($command) { $command.Source } elseif (Test-Path -LiteralPath $Interpreter -PathType Leaf) { $Interpreter } else { $null }
        if (-not $executable) { throw "Invoke-PowerControlExternal: interpreter '$Interpreter' not found" }
    }
    elseif ($Language -eq 'Custom') { throw 'Invoke-PowerControlExternal: -Interpreter is required for -Language Custom' }
    else {
        $executable = Find-PowerControlInterpreter -Language $Language
        if (-not $executable) { throw "Invoke-PowerControlExternal: no $Language interpreter found (settings.json, PATH, standard folders). Set the path in View > Settings." }
    }

    $extension = switch ($Language) { 'Python' { '.py' } 'Node' { '.js' } default { '.txt' } }
    $tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'PowerControl')
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $codeFile = [System.IO.Path]::Combine($tempDir, 'external_' + [guid]::NewGuid().ToString('N') + $extension)
    [System.IO.File]::WriteAllText($codeFile, $Code, [System.Text.UTF8Encoding]::new($false))

    Write-DebugLog -Message "External ($Language): $executable $codeFile, $(@($InputObject).Count) input object(s)" -Level 2 -LogFileName 'External.log'

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $executable
        foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.ArgumentList.Add($codeFile)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $startInfo.Environment['PYTHONIOENCODING'] = 'utf-8'
        $startInfo.Environment['PYTHONUTF8'] = '1'
        $startInfo.Environment['POWERCONTROL_INPUT_COUNT'] = [string]@($InputObject).Count

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $json = if ($null -eq $InputObject) { '[]' } else { ConvertTo-Json -InputObject @($InputObject) -Depth $Depth -Compress }
        $utf8Stdin = [System.IO.StreamWriter]::new($process.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
        $utf8Stdin.Write($json)
        $utf8Stdin.Dispose()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            throw "Invoke-PowerControlExternal: $Language program did not finish within $TimeoutSeconds seconds"
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            throw "Invoke-PowerControlExternal: $Language program exited with code $($process.ExitCode)`r`n$stderr"
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-DebugLog -Message "External ($Language) stderr: $stderr" -Level 2 -LogFileName 'External.log'
        }

        $lines = $stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($Raw) { return $lines }

        foreach ($line in $lines) {
            $trimmed = $line.TrimStart()
            if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
                try { ConvertFrom-Json -InputObject $trimmed; continue } catch { }
            }
            $line
        }
    }
    finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $codeFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PowerControlSettings {
    <#
      .SYNOPSIS
      Loads ini\settings.json (theme, pinned panels, recent menus, column profiles, interpreter paths).
      Missing keys get their defaults; the result is a synchronized hashtable shared with the runspaces.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Path = $PowerControl.General.SettingsPath)

    $settings = [hashtable]::Synchronized(@{
        Theme            = 'System'
        NavigationPinned = $false
        JobsPinned       = $false
        ActionsCollapsed = $true      # actions panel starts as icon rail; the Settings dialog can pin it
        RestorePinnedTabs = $true     # menus that were pinned when the window closed run again at the next start
        PinnedMenus      = @()
        NotifyOnFinish   = $true      # balloon tip + taskbar flash when a job of 5 s or longer finishes in the background
        CodeEditorColors = 'Auto'     # Auto: the dialog script editor follows the theme (brightened colors on dark); Light: white editor always
        BundleSources    = @()        # folders, .xml URLs or GitHub repository/folder URLs with element bundles (Sync-PowerControlBundles)
        BundleState      = @{}        # source|bundle -> SHA256 of the last imported version
        FavoriteActions  = @()        # action IDs shown first in the actions rail and the palette
        FavoriteMenus    = @()        # menu IDs: star badge in the navigation rail, first on the start page and in the palette
        GlobalHotkey     = ''         # e.g. 'Ctrl+Alt+P': system wide shortcut that brings the window to the front (empty = off)
        RecentMenus      = @()
        ColumnProfiles   = @{}
        Interpreters     = @{ Python = ''; Node = '' }
    })

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $stored = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
            foreach ($key in $stored.Keys) { $settings[$key] = $stored[$key] }
            if ($settings.ColumnProfiles -isnot [hashtable]) { $settings.ColumnProfiles = @{} }
            if ($settings.Interpreters -isnot [hashtable]) { $settings.Interpreters = @{ Python = ''; Node = '' } }
            $settings.RecentMenus = @($settings.RecentMenus)
            $settings.BundleSources = @($settings.BundleSources | Where-Object { $_ })
            $settings.FavoriteActions = @($settings.FavoriteActions | Where-Object { $_ })
            $settings.FavoriteMenus = @($settings.FavoriteMenus | Where-Object { $_ })
            if ($settings.BundleState -isnot [hashtable]) { $settings.BundleState = @{} }
        }
        catch {
            Write-DebugLog -Message "settings.json could not be read, using defaults: $($_.Exception.Message)" -Level 1 -LogFileName 'PowerControl.log'
        }
    }
    $settings
}

function Save-PowerControlSettings {
    <# writes the settings atomically (temp file + move), callable from action runspaces #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][hashtable]$Settings = $PowerControl.Settings, [Parameter(Mandatory = $false)][string]$Path = $PowerControl.General.SettingsPath)

    if ($null -eq $Settings -or -not $Path) { return }
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Settings -Depth 8
        [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $Path, $true)
    }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-DebugLog -Message "settings.json could not be written: $($_.Exception.Message)" -Level 1 -LogFileName 'PowerControl.log'
    }
}

function Get-PowerControlEffectiveTheme {
    <# resolves 'System' to Light/Dark via the Windows "Apps use light theme" setting #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Theme)

    if ($Theme -ne 'System') { return $Theme }
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        if ([int]$value -eq 0) { return 'Dark' }
    }
    catch { }
    'Light'
}

function Set-PowerControlTheme {
    <#
      .SYNOPSIS
      Switches the theme at runtime (Light, Dark or System) and stores the choice in settings.json.
      Safe to call from action scripts: the change is marshalled to the UI thread through the UI bridge.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('Light', 'Dark', 'System')][string]$Theme,
        [Parameter(Mandatory = $false)][switch]$NoSave
    )

    $window = $PowerControl.SynchronizedWindow
    $setter = $PowerControl.UI.ThemeSetter
    if ($null -ne $window -and $null -ne $window.Dispatcher -and $null -ne $setter) {
        if ($window.Dispatcher.CheckAccess()) { $setter.DynamicInvoke([object[]]@($Theme)) }
        else { $window.Dispatcher.Invoke($setter, [object[]]@($Theme)) }
    }
    if (-not $NoSave -and $null -ne $PowerControl.Settings) {
        $PowerControl.Settings.Theme = $Theme
        Save-PowerControlSettings
    }
}

function Add-PowerControlNotification {
    <# queues a message for the error banner of the main window (thread-safe) #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$Source = '',
        [Parameter(Mandatory = $false)][ValidateSet('Error', 'Warning', 'Info')][string]$Severity = 'Error'
    )
    $queue = $PowerControl.UI.Notifications
    if ($null -eq $queue) { return }
    $queue.Enqueue([pscustomobject]@{ Time = [DateTime]::Now; Severity = $Severity; Source = $Source; Message = $Message })
}

function Invoke-PowerControlUICommand {
    <#
      .SYNOPSIS
      Triggers a shell command of the main window (command palette, filter, panels) from an engine script.

      .DESCRIPTION
      Lets Command elements in the engine XML drive the shell, so their key bindings stay configurable there
      instead of being hard-coded in the window. The call is queued on the UI thread (BeginInvoke) and returns
      immediately; the runner delegate is created by the shell (`$PowerControl.UI.CommandRunner`).
      Names: CommandPalette, FocusFilter, ClearFilter, ToggleNavigation, ToggleActions, ToggleJobs, StartPage.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    $window = $PowerControl.SynchronizedWindow
    $runner = $PowerControl.UI.CommandRunner
    if ($null -eq $window -or $null -eq $window.Dispatcher -or $null -eq $runner) {
        Write-DebugLog -Message "UI command '$Name' ignored: no window or runner" -Level 2 -LogFileName 'UI.log'
        return
    }
    [void]$window.Dispatcher.BeginInvoke($runner, [object[]]@($Name))
}

function Initialize-PowerControlUIBridge {
    <#
      .SYNOPSIS
      Creates the delegates action runspaces use to read UI state through the window dispatcher.

      .DESCRIPTION
      Must run in the main (UI) runspace after the window exists. The script blocks are converted to
      .NET delegates here, so when another runspace passes them to Dispatcher.Invoke they execute in
      the main runspace on the UI thread, exactly like a WPF event handler.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][System.Windows.Window]$Window
    )

    $Global:PowerControl.SynchronizedWindow = $Window

    # no GetNewClosure() here either: the window is taken from the shared state when the delegate runs
    $Global:PowerControl.UI.GridReader = [System.Func[string, bool, object]]{
        param([string]$gridName, [bool]$selectedOnly)

        $grid = $Global:PowerControl.SynchronizedWindow.FindName($gridName)
        if ($null -eq $grid) { return $null }

        $columns = @($grid.Columns.Where({ $_.Visibility -eq 'Visible' }) | Sort-Object DisplayIndex | ForEach-Object { [string]$_.Header })
        # direct assignments: an array coming out of an if-expression is enumerated (one row -> scalar, none -> $null)
        $rows = @()
        if ($selectedOnly) { $rows = @($grid.SelectedItems) } else { $rows = @($grid.Items) }

        [pscustomobject]@{ Columns = $columns; Rows = $rows }
    }

    # every exception that escapes a WPF event handler ends up in the log instead of on the console
    # (and does not take the window down); the stack trace shows which handler failed
    $Window.Dispatcher.add_UnhandledException({
        param($sender, $e)
        try {
            $inner = $e.Exception
            $detail = if ($inner -is [System.Management.Automation.RuntimeException] -and $inner.ErrorRecord) {
                "$($inner.ErrorRecord.ToString()) | $($inner.ErrorRecord.InvocationInfo.PositionMessage) | $($inner.ErrorRecord.ScriptStackTrace)"
            } else { "$($inner.GetType().Name): $($inner.Message) | $($inner.StackTrace)" }
            Write-DebugLog -Message "UI thread exception: $detail" -Level 1 -LogFileName 'UI.log'
            [System.IO.File]::AppendAllText([System.IO.Path]::Combine($script:LogsPath, 'scripts.log'), "UI thread exception $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')`r`n$detail`r`n`r`n")
        } catch { }
        $e.Handled = $true
    })

    Write-DebugLog -Message 'UI bridge delegates and dispatcher exception logging created' -Level 2 -LogFileName 'PowerControl.log'
}

