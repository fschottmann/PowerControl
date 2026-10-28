<#PSScriptInfo

	.VERSION 10.1.0

	.GUID 99b2b1e5-2292-424f-80f4-4e598c57346e

	.AUTHOR Frank Schottmann

	.COMPANYNAME fschottmann.eu

	.COPYRIGHT @2026 Frank Schottmann

	.TAGS 

	.LICENSEURI 

	.PROJECTURI 

	.ICONURI 

	.EXTERNALMODULEDEPENDENCIES 

	.REQUIREDSCRIPTS 

	.EXTERNALSCRIPTDEPENDENCIES 

	.RELEASENOTES
	Version 8.0.0
	- remove dependency from pstoolbox module for runtogo feeling 
	- catch Invoke-Expression errors in a variable ExpressionError
	- check $HashItem.Value.NextAction and $HashItem.Value.PrevAction for $null value
	- remove output variable after initiating code
	- if no UserCertificateSerialNumber is provided, user specfic code will be loaded with a hint to sign the code
	- don't create empty Categories
	- fix refresh handling bug; wrong data in ShowResultSelectedEntries
	- don't override existing EndpointCollection for better session handling
	- remove broken Endpoints before creating new ones
	- remove release notes till 7.0.0
	- remove Debug-PreScript function because it can not track the nested actions
	- add right click menu for actions
	- add a remote endpoint possiblity and remove local endpoint creation; code can be found in config.xml
	- No ShowUI Module is needed 
	- remove ShowUI GUI Drawing and set WPF directly in code
	- remove DelegateCommand Class
	- replace New-KeyBinding (ShowUI)
	- remove autoupdate, the new preferd way is to update over the menu bar
	- remove compare function
	- remove old quest module as a needed component
	- correct Add-Type call with CSharp as language
	- replace set-property (ShowUI)
	- replace Show-Window (ShowUI)
  Version 9.0.0
  - remove post sorting @($ShowResult.ItemsSource | Sort-Object { $_.$($_.PSObject.Properties.Name[0]) })
  Version 10.0.0
  - renamed to PowerControl.ps1; code split into src\*.ps1 (core 01-07, Windows shell 10-17), bootstrap stays here
  - Fluent (light/dark/system) shell: icon rails with popups, output tabs per pinned job, command palette,
    start page, error banner, tray icon, global hotkey, favorites, English UI
  - engine: atomic XML saves, change log with history (diff, restore), bundles (export/import/subscriptions),
    duplicate/move elements, dry run, engine check, headless mode (-Run, -Headless, -OutFile)
  - jobs: repeat with change detection and previous runs, compare outputs (table or line diff), notifications
  - external interpreters (Python, Node) via Invoke-PowerControlExternal, import menus (CSV, JSON, CliXML,
    clipboard incl. Markdown tables, REST, SQL, folder), export menus (HTML, Excel, Markdown, JSON, ...)
  - tests\Test-CoreFunctions.ps1, tools\Test-EngineXml.ps1, tools\Export-DrawGuiStandalone.ps1
  Version 10.1.0
  - element editor: opens in about a second again (icon cache helpers were missing in the action runspaces),
    read-only ID field, icon preview left of the picker, keeps the Children order, dialogs fit the work area
  - start page: right click on tiles and shortcut rows opens the editor; edit/dry run/move/export only on element rows
  - breadcrumb: re-running an element replaces its entry, cancelled dialog actions remove theirs
  - setting CodeEditorColors (Auto | Light): readable syntax colors in the dark theme
  - shortcuts shared by several actions resolve by DisplayCondition SortOrder, like the default action
  - tools\Get-ActionTimeline.ps1: PrevAction/NextAction workflow of an element outside the shell
  - README: dialog builder, workflows, visibility/children/shortcuts, packages
  - renamed: Show-ITuSGUI -> Show-PCtrlGUI, New-ITuSButton -> New-PCtrlButton (older engine files must be adapted),
    dialog titles "Edit element" / "New element", menu "Create a new element"
  - AvalonEdit 6.3.1.120
#>

<#
	.DESCRIPTION 
	- Display XML Config in a graphical user interface and runs powershell commands 
	on the local or remote endpoint/computer
	- it is possible to run ps commands on each powershell object that are displayed
	- a custom keybinding is also possible
	- custom code in myconfig.xml is also possible
	- right click menu on every displayed psobject
  
  Structure (2026-10): this file is the bootstrap, the code lives in src\*.ps1 (dot-sourced, see the end of
  this file). Engine XML in engine\, Lucide icons in icons\lucide, settings in ini\settings.json, logs in logs\.

  Former TODOs and their state:
  - duplicate IDs: Update-JsonIndex logs them and shows them in the error banner, tools\Test-EngineXml.ps1 reports them
  - New-ContextMenuXaml / Add-*Items / New-MenuItemXaml: merged into New-XamlElement, Add-XamlContextMenu, New-XamlMenuItem
  - non-conform XML (duplicate DisplayCondition/KeyBinding nodes): the index takes the first node, a broken element is logged and skipped
  - missing PrevAction/NextAction (e.g. Draw GUI): the sequence fails inside Invoke-PowerControlSequence, the GUI stays up and the banner shows the error
  - XML nodes in $SelectedEntries: selected rows are passed as plain objects (ConvertTo-Json/ConvertFrom-Json), no live XML nodes any more
  - "Programm XML in data": not clear what was meant, left open
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    # 0 = off, 1 = errors/milestones, 2-4 = flow details, 5 = everything except per-item trace lines, 6 = trace
    # default 2: enough to follow sequences and errors; raise it (here or in View > Settings) when hunting a problem
    [ValidateRange(0, 6)]
    [int]$DebugLevel = 2,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$LogsPath = [System.IO.Path]::Combine($PSScriptRoot, 'Logs'),

    [Parameter(Mandatory = $false)]
    [switch]$ReturnOutput,

    # Light / Dark / System (follows Windows) use the WPF Fluent theme that ships with .NET 9+.
    # 'Settings' takes the value stored in ini\settings.json (the View menu changes it at runtime).
    [Parameter(Mandatory = $false)]
    [ValidateSet('Light', 'Dark', 'System', 'Settings')]
    [string]$Theme = 'Settings',

    # start with this element (ID, label or label fragment): with the window it runs right after start,
    # with -Headless it runs without a window and the rows go to the pipeline or to -OutFile (.json/.csv/.xml/.txt)
    [Parameter(Mandatory = $false)]
    [string]$Run,

    [Parameter(Mandatory = $false)]
    [switch]$Headless,

    [Parameter(Mandatory = $false)]
    [string]$OutFile
)

# Set strict mode and error action preference
#Set-StrictMode -Version Latest
#$ErrorActionPreference = 'Stop'

$script:StartupWatch = [System.Diagnostics.Stopwatch]::StartNew()

# Create logs directory if it doesn't exist
if (-not (Test-Path -Path $LogsPath)) {
    New-Item -ItemType Directory -Path $LogsPath | Out-Null
}

# ---- platform ------------------------------------------------------------------------------------------------
# The engine (XML, index, runspaces, export/import) is portable; the shell is WPF and therefore Windows only.
# PowerControl detects the OS here and loads the matching shell from $script:ShellFiles below. A platform without
# a shell gets a clear message instead of a stack of "type not found" errors.
$script:Platform = if ($IsLinux) { 'Linux' } elseif ($IsMacOS) { 'macOS' } else { 'Windows' }

if ($script:Platform -eq 'Windows') {
    Add-Type -AssemblyName `
        PresentationCore,`
        PresentationFrameWork,`
        WindowsBase,`
        System.Windows.Forms,`
        System.Drawing,`
        System.Security
}

# remembered here: $PSBoundParameters is empty inside the dot-sourced src files
$script:DebugLevelFromCommandLine = $PSBoundParameters.ContainsKey('DebugLevel')

# version from the PSScriptInfo header, shown by the About menu entry
$scriptVersion = 'unknown'
if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    $versionMatch = [regex]::Match([System.IO.File]::ReadAllText($PSCommandPath), '(?m)^\s*\.VERSION\s+(\S+)')
    if ($versionMatch.Success) { $scriptVersion = $versionMatch.Groups[1].Value }
}

$Global:PowerControl = [pscustomobject]@{
    'General' = [pscustomobject]@{
        'CurrentPath' = $PSScriptRoot ?? $PWD.Path
        'Version' = $scriptVersion
        # Theme = effective look (Light/Dark) used for brushes and dialogs, ThemeMode = configured value (may be System)
        'Theme' = 'Light'
        'ThemeMode' = 'System'
        'SettingsPath' = $null
        # node types that run "beside" the normal flow: no action-bar button, not listed as jobs,
        # never registered as the active action of a menu
        # Command = menu bar utilities (theme switch, settings dialog): run and forget
        'TransientNodeTypes' = @('Thread', 'EditTreeView', 'OutputGridHeaderMenu', 'Command')
        'JsonFilePath' = $null
        'enginePath' = $null
        'ExportPath' = $null
        'Settings' = [pscustomobject]@{
            'expandedUID' = @()
        }
    }
    'ActiveMenu' = $null
    'Data' = @{}
    'History' = New-Object System.Collections.ArrayList
    # Shared lock object: every read-modify-write on History (UI thread and watcher runspaces) goes through it
    'HistoryLock' = [object]::new()
    # Shared, thread-safe flag so the watcher loops can be ended cleanly on shutdown
    # NavigationDirty: menus/trees must be rebuilt from the engine XML (set after saves and external edits)
    'WatcherState' = [hashtable]::Synchronized(@{ Stop = $false; Closing = $false; NavigationDirty = $false })
    'PowerControlThreads' = [pscustomobject]@{
        'ThreadWatcher' = $null
        'HistoryWatcher' = $null
        'UIUpdateWatcher' = $null
    }
    'SynchronizedWindow' = [hashtable]::Synchronized(@{})
    # delegates created by the main runspace (see Initialize-PowerControlUIBridge); action runspaces
    # hand them to the window dispatcher to read UI state without running their own script blocks on the UI thread
    'UI' = [pscustomobject]@{
        GridReader    = $null
        ThemeSetter   = $null
        CommandRunner = $null   # Action[string] created by the shell, see Invoke-PowerControlUICommand
        # runspace errors and UI failures land here; the UI tick shows them in the error banner
        Notifications = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
        # dialog windows opened by action runspaces (Draw GUI); the shutdown closes them so their runspaces can end
        OpenDialogs   = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        PendingRun    = $null   # @{ ID; Entries } handed from an engine script to the shell (UI command RunPending)
        PendingCompare = $null  # @{ AKey; BKey; RerunId; BRows; Filters } from "Compare with..." (job menu) for "Compare job outputs..."
        PendingSnapshot = $null # @{ Name; Time; Rows } from "Previous runs..." for the "Previous run" menu entry
    }
    # ini\settings.json (theme, pinned panels, recent menus, column profiles), loaded by Get-PowerControlSettings
    'Settings' = $null
    'JsonCache' = $null
    'EventParams' = [pscustomobject]@{
        'Sender' = $null
        'Args'   = $null
    }
}

#$Global:PowerControl.History = [System.Collections.ArrayList]@($Global:PowerControl.History)
#$Global:PowerControl.History = New-Object System.Collections.ArrayList

$basePath = $Global:PowerControl.General.CurrentPath
$Global:PowerControl.General.JsonFilePath = [System.IO.Path]::Combine($basePath, 'temp', 'index.json')
$Global:PowerControl.General.enginePath = [System.IO.Path]::Combine($basePath, 'engine')
$Global:PowerControl.General.ExportPath = [System.IO.Path]::Combine($basePath, 'Export')
$Global:PowerControl.General.SettingsPath = [System.IO.Path]::Combine($basePath, 'ini', 'settings.json')

# optional data\ folder: every file is reachable from engine scripts as $PowerControl.Data['<name without extension>']
$DataPath = [System.IO.Path]::Combine($basePath, 'data')
$Global:PowerControl.Data = @{}
if (Test-Path -LiteralPath $DataPath) {
    [System.IO.Directory]::GetFiles($DataPath, "*.*").ForEach({
        $Global:PowerControl.Data[[System.IO.Path]::GetFileNameWithoutExtension($_)] = $_
    })
}
foreach ($folder in 'temp', 'ini', 'Export') {
    $folderPath = [System.IO.Path]::Combine($basePath, $folder)
    if (-not (Test-Path -LiteralPath $folderPath)) { New-Item -ItemType Directory -Path $folderPath -Force | Out-Null }
}

# Clean up unused variables
Remove-Variable -Name basePath, DataPath


# ---- source files -----------------------------------------------------------------------------------------
# The core is split into src\*.ps1 for maintainability. The files are dot-sourced in this order into the
# script scope of this file, so functions, $script: variables and the window controls behave exactly as in
# the former single file (functions are still injected into action runspaces by name). The numeric prefix only
# makes the load order visible in the folder; the order itself is this list.
$script:CoreFiles = @(
    '01-Core.Engine.ps1',
    '02-Core.Execution.ps1',
    '03-Core.Bridge.ps1',
    '04-Core.Jobs.ps1',
    '05-Core.Output.ps1',
    '06-Core.Sequence.ps1',
    '07-Core.Headless.ps1'
)
# one shell per platform; a Linux/macOS shell (terminal UI or Avalonia) would be added here
$script:ShellFiles = @{
    Windows = @(
        '10-UI.Xaml.ps1',
        '11-UI.Window.ps1',
        '12-UI.Theme.ps1',
        '13-UI.Handlers.ps1',
        '14-UI.Panels.ps1',
        '15-UI.Tabs.ps1',
        '16-UI.Content.ps1',
        '17-UI.Startup.ps1'
    )
}

foreach ($sourceFile in $script:CoreFiles) {
    $sourcePath = [System.IO.Path]::Combine($PSScriptRoot, 'src', $sourceFile)
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw "PowerControl source file missing: $sourcePath" }
    . $sourcePath
}

# ---- headless: run one element and leave (no window, works on every platform the engine runs on) ----------
if ($Headless) {
    if (-not $Run) { throw 'PowerControl: -Headless needs -Run <ID or label>' }
    $script:HeadlessExitCode = 0
    Invoke-PowerControlHeadless -Run $Run -OutFile $OutFile
    exit $script:HeadlessExitCode
}

if (-not $script:ShellFiles.ContainsKey($script:Platform)) {
    Write-Warning "PowerControl: no shell for $($script:Platform) yet. The engine (engine\*.xml, index, runspaces) is portable, the user interface is WPF and runs on Windows only. Use -Headless -Run <element> to run elements without a window."
    exit 2
}
$script:RunAtStart = $Run
foreach ($sourceFile in $script:ShellFiles[$script:Platform]) {
    $sourcePath = [System.IO.Path]::Combine($PSScriptRoot, 'src', $sourceFile)
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw "PowerControl source file missing: $sourcePath" }
    . $sourcePath
}

