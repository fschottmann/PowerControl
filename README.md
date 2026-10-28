# PowerControl

PowerControl is a PowerShell 7 / WPF desktop shell that turns small XML-defined building blocks into a working tool
collection: menus that produce rows, actions that work on the selected rows, background jobs that never block the
window, and everything you need around it (filtering, export, import, comparison, scheduling, favorites, bundles).

New menus and actions are created inside PowerControl itself: `Customization > Create a new element` opens the
element editor (script with syntax check, icon picker, key binding, workflow, children), saves the element into an
engine file and it shows up right away. Anyone who can write a few lines of PowerShell is done in minutes. The
XML files in `engine\` can also be edited by hand, and Python or Node.js scripts plug in the same way. No build
step, no module installation.

[Deutsche Fassung: README.de.md](README.de.md)

![start page](images/01-start-page-light.png)

## Requirements

| Component | Version |
|-----------|---------|
| Windows | 10 / 11 (the shell is WPF; the engine itself is portable, see `-Headless`) |
| PowerShell | 7.6 or later (x64; the Fluent theme needs .NET 10 WPF) |
| Optional | Python 3 and/or Node.js 18+ for elements that call `Invoke-PowerControlExternal` |

The code editor (AvalonEdit) ships in `dll\`.

## Quick start

```powershell
git clone <this repository>
cd PowerControl
pwsh -NoProfile -ExecutionPolicy Bypass -File .\PowerControl.ps1
```

The first start creates `ini\settings.json`, `temp\` (element index, icon cache) and `Logs\` with defaults:
theme follows Windows, navigation and actions collapsed to icon rails, DebugLevel 2.

Useful parameters:

```powershell
.\PowerControl.ps1 -Theme Dark                              # Light | Dark | System | Settings
.\PowerControl.ps1 -Run 'Recently changed'                  # run an element right after start
.\PowerControl.ps1 -Headless -Run 'Import clipboard'        # no window, rows go to the pipeline
.\PowerControl.ps1 -Headless -Run 'List all PCtrl Elements' -OutFile out.json   # .json | .csv | .xml | .txt
.\PowerControl.ps1 -DebugLevel 5                            # verbose logs in Logs\
```

## How it works

Every file in `engine\*.xml` is a list of `PCtrl` elements. The element type decides where it shows up:

| Type | Shows up as | Script receives | Script returns |
|------|-------------|-----------------|----------------|
| `Menu` | navigation rail / tree, start page, palette | nothing (or a dialog) | rows via `$Script:PowerControlItem_Output` |
| `MenuBar` | entry of the top menu (`View`, `Customization`, ...) | nothing (or a dialog) | rows |
| `Action` | actions panel, offered for the rows that match its `DisplayCondition` | `$script:SelectedEntries` | rows (become the output of the job) |
| `Thread` | job list context menu (tabs, breadcrumbs); `Toolbar="Jobs"` puts it on the jobs bar | the selected jobs | nothing (works on the job objects) |
| `Command` | shortcuts of the shell (Ctrl+K, Ctrl+Tab, ...) | nothing | nothing, usually `Invoke-PowerControlUICommand` |
| `OutputGridHeaderMenu` | right click on a column header | the column | nothing |
| `EditTreeView` | the element editor | the element | nothing |

A minimal menu:

```xml
<PCtrl type="Menu" Label="Services" ID="Services-0001" Icon="lucide\server.svg" ToolTip="Running services">
  <Script><![CDATA[
    $Script:PowerControlItem_Output += Get-Service | Where-Object Status -eq Running |
        ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DisplayName = $_.DisplayName } }
  ]]></Script>
</PCtrl>
```

An action that applies to those rows (the `DisplayCondition` is evaluated against each selected row as `$_`):

```xml
<PCtrl type="Action" Label="Restart service" ID="RestartService-0001" Icon="lucide\refresh-cw.svg">
  <DisplayCondition Categorie="Services" SortOrder="1"><![CDATA[ $null -ne $_.Name -and $null -ne $_.DisplayName ]]></DisplayCondition>
  <KeyBinding Key="R" Modifiers="Ctrl+Shift" />
  <Script><![CDATA[
    foreach ($row in @($script:SelectedEntries)) { Restart-Service -Name $row.Name; $Script:PowerControlItem_Output += [PSCustomObject]@{ Name = $row.Name; Result = 'restarted' } }
  ]]></Script>
</PCtrl>
```

More attributes and child nodes: `Children` (comma separated IDs for groups and sub menus), `PrevAction` /
`NextAction` with `Priority` (chains of elements, see "Workflows" below), `ApartmentState="STA"` (dialogs,
clipboard), `KeyBinding`, `Toolbar="Jobs"`. Every script runs in its own runspace, so a hanging script never
freezes the window; the job list shows it and `Stop` ends it.

Dialogs are described as hashtables and drawn by the built-in dialog builder, see the next section.

Other languages: `Invoke-PowerControlExternal -Language Python|Node -InputObject $rows -Code '...'` sends the rows
as JSON to stdin and turns every JSON line on stdout into a row. Interpreter paths are detected automatically or
set in `View > Settings`.

## The dialog builder

Most elements need a few inputs before they can work: a file, a delimiter, a choice, a flag. Writing XAML for that
every time is the part nobody wants to do, so PowerControl ships a dialog builder. You describe the dialog as a
hashtable, call `Show-PCtrlGUI`, and get the values back as `$GUIResults`. The builder draws the window in the
current theme, wires validation, default button, Enter/Esc, file pickers and icon previews.

### Hooking it into an element

The builder lives in the action `Draw GUI` (`engine\main.xml`). An element that wants a dialog declares it as
`PrevAction`; the chain then runs STA, so your element needs no further attribute:

```xml
<PCtrl type="Menu" Label="Import CSV file" ID="ImportCsv-0001" Icon="lucide\file-spreadsheet.svg">
  <PrevAction ID="DrawGUI-e7670e8344194a828558f726" Priority="100" />
  <Script><![CDATA[
    $GUItable = @{
      'window' = @{ 'title' = 'Import CSV'; 'description' = 'The first line of the file provides the column names.' }
      'dialog' = @{
        0 = @{ 'Label' = 'File';      'OpenFile' = @{ 'Name' = 'Path'; 'Filter' = 'CSV (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*' } }
        1 = @{ 'Label' = 'Delimiter'; 'ComboBox' = @{ 'Name' = 'Delimiter'; 'IsEditable' = $true; 'Text' = ';'; 'Elements' = @(';', ',', 'Tab', '|') } }
        2 = @{ 'CheckBox' = @{ 'Name' = 'Trim'; 'Text' = 'Trim values'; 'IsChecked' = $true } }
      }
      'actionButtons' = @{ 0 = @{ 'Label' = '_Import'; 'Name' = 'Import'; 'isDefault' = $true } }
      'OnResult' = {
        $path = ([string]$GUIResults.Path).Trim('"', ' ')
        $delimiter = if ($GUIResults.Delimiter -is [string]) { $GUIResults.Delimiter } else { [string]$GUIResults.Delimiter.Content }
        if ($delimiter -eq 'Tab') { $delimiter = "`t" }
        foreach ($row in Import-Csv -LiteralPath $path -Delimiter $delimiter[0]) { $Script:PowerControlItem_Output += $row }
      }
    }
    Show-PCtrlGUI -GUItable $GUItable
  ]]></Script>
</PCtrl>
```

The hashtable has four parts:

| Key | Content |
|-----|---------|
| `window` | `title`, optional `description` (text under the title bar), `Width` / `MinWidth` |
| `dialog` | the rows, numbered from 0; each row is `@{ 'Label' = '...'; '<Control>' = @{ 'Name' = '...'; ... } }`. The label becomes the left column, the control the right one. `Label` is optional. |
| `actionButtons` | numbered buttons with `Label` (`_` marks the access key), `Name`, `isDefault`. A button without `Code` validates the fields and closes the dialog with "OK"; `Code = { ... }` runs your own script block instead (set `$DrawGuiWindow.DialogResult = $false` to cancel). |
| `OnResult` | script block that runs after "OK" with the values in `$GUIResults`, keyed by the `Name` of each control. It runs inside the element's job, so `$Script:PowerControlItem_Output`, `$script:SelectedEntries` and all engine functions are available. |

### Controls

| Control | Options | Value in `$GUIResults` |
|---------|---------|------------------------|
| `TextBox` | `Text`, `MultiLine`, `Width`, `Height`, `IsEnabled`, `ToolTip`, `Focus`, `check` | string |
| `PasswordBox` | `ToolTip` | `SecureString` |
| `CheckBox` | `Text` (the caption), `IsChecked`, `ToolTip` | `$true` / `$false` |
| `ComboBox` | `Elements`, `Text` (preselected), `IsEditable`, `IconPreview`, `Width`, `ToolTip`, `check` | the selected item; read it as a string with `$GUIResults.X.Content` (or `$GUIResults.X` when the user typed free text) |
| `OpenFile` | `Text`, `Filter` (Windows file dialog filter), `InitialDirectory` | path as string |
| `ListBox` | `Items`, `Text` (preselected entries), `SelectionMode`, `ToolTip` | the selected items |
| `RadioButton` | `Text` (the caption) | the caption of the checked button |
| `CodeEditor` | `text`, `Syntax` (default `PowerShell`), `MinWidth`, `MinHeight`, `check` | string; syntax colored editor (AvalonEdit) |
| `DatePicker`, `Slider`, `ToggleButton`, `RichTextBox` | WPF defaults | date, number, bool, text |
| `DataGrid` | `Columns` (each `Type` = `TextColumn`, `CheckBoxColumn` or `ComboBoxColumn` with `Header`, `Binding`, `Width`, `Items`), `Rows`, `AddRows`, `IsReadOnly`, `Filter` (text box that narrows the choice lists) | the rows as objects |
| `GroupBox`, `Expander`, `TabControl`, `StackPanel` | `Header` / `Tabs` (`@{ Header; Elements }`) and `Elements`: nested rows in the same syntax | the nested controls report under their own names |
| `TextBlock`, `Separator`, `Image`, `ProgressBar`, `Button` | static or decorative | none |

Validation: `'check' = { $sender.Text -match '^[0-6]$' }` runs when the field loses focus and again on "OK". A
failing field gets a red border and the dialog stays open and names it. `Focus = $true` puts the cursor into that
field. `Events = @{ TextChanged = '...' }` attaches WPF events; the handler text is compiled into a script block.

### Tips

- `ComboBox` values arrive as `ComboBoxItem`; the helper pattern in the examples (`$asText`) turns both the item
  and free text into a plain string.
- Do not name variables you read inside `OnResult` like the builder's own loop variables (`$item`, `$element`,
  `$control`): `OnResult` runs inside the builder and they would be shadowed.
- Larger dialogs: `TabControl` with one tab per topic (the element editor does this), `GroupBox` for related
  fields, `DataGrid` with `ComboBoxColumn` for lists of choices.
- Test a dialog without running the real work: select the element in `List all PCtrl Elements` and use `Dry run`,
  or `Save + Dry run` in the editor. The values the dialog would deliver appear as rows.
- Everything also works outside PowerControl: `tools\Test-DrawGUI.ps1` is the builder as a standalone script
  (generated from main.xml), handy for designing a dialog in a plain console before pasting it into an element.
- Complete real examples: `Settings...`, `Compare job outputs...`, `Export settings...` and the element editor in
  `engine\main.xml`, all import menus in `engine\ImportData.xml`.

## Workflows: chaining elements

An element rarely does everything itself. It declares other elements as `PrevAction` (run before the element's
own script) or `NextAction` (run after it), each with a `Priority`. The element itself does not even need a
script: it can be nothing more than the sum of the steps it chains. That is how PowerControl stays modular:
small actions such as "ask for a user", "fetch the password from the vault", "start PuTTY" are written once and
reused by every element that needs them. The dialog builder is the same mechanism, `Draw GUI` is simply a
`PrevAction`.

### Order of execution

1. All `PrevAction` elements, highest `Priority` first.
2. The element's own `Script`.
3. All `NextAction` elements, highest `Priority` first.

Chains nest: a `PrevAction` can have its own `PrevAction`/`NextAction` entries (`Draw GUI` pulls in
`Convert-XAMLtoWindow` and `Show-WPFWindow` this way). Cycles are detected and skipped with a warning. If any
member carries `ApartmentState="STA"`, the whole chain runs STA.

### One job, one scope

The whole chain runs as one job in one runspace. Everything a step leaves behind is available to the next steps:

- `$script:` variables (`$script:PasswordFilter = '...'` in a dialog step, read by the credential step)
- functions declared as `function script:Name { ... }` (this is how `Show-PCtrlGUI` reaches your element)
- `$GUIResults` after a dialog, `$script:SelectedEntries` (the selected rows), `$Script:PowerControlItem_Output`
  (the rows the job returns; every step may add to it)

### Building blocks

Helper actions have no `DisplayCondition` and no `KeyBinding`. They never show up in the actions panel, the
palette or the start page; they exist only to be chained. The core ships `Draw GUI`, `History helper`,
`Convert-XAMLtoWindow` and `Show-WPFWindow` this way.

An example: one action opens SSH with the stored credentials, the other asks for a user first. Both reuse the
same helper actions, only the position and the order differ:

```xml
<PCtrl type="Action" Label="open SSH" ID="OpenSSH-0001" Icon="lucide\terminal.svg">
  <KeyBinding Key="P" Modifiers="Ctrl"/>
  <DisplayCondition Categorie="Machine Control" SortOrder="3"><![CDATA[ $_.Protocol -eq 'SSH2' ]]></DisplayCondition>
  <PrevAction ID="CollectActions-0001"         Priority="999"/>   <!-- 1. log who did what on which machine (audit trail) -->
  <PrevAction ID="GetCredentialFromVault-0001" Priority="100"/>   <!-- 2. password from the credential vault -->
  <NextAction ID="ProgramStartPutty-0001"      Priority="90"/>    <!-- 4. start PuTTY with host + credentials -->
</PCtrl>                                                           <!-- 3. = the element itself, it has no script -->

<PCtrl type="Action" Label="open SSH as ..." ID="OpenSSHAs-0001" Icon="lucide\terminal.svg">
  <KeyBinding Key="P" Modifiers="Ctrl+Alt"/>
  <DisplayCondition><![CDATA[ $_.Protocol -eq 'SSH2' ]]></DisplayCondition>
  <PrevAction ID="CollectActions-0001"         Priority="999"/>
  <PrevAction ID="DrawGUI-e7670e8344194a828558f726" Priority="100"/>   <!-- the dialog builder -->
  <NextAction ID="GetCredentialFromVault-0001" Priority="100"/>   <!-- credentials only after the dialog -->
  <NextAction ID="ProgramStartPutty-0001"      Priority="50"/>
  <Script><![CDATA[
    # asks for user name and password source; the credential step reads $GUIResults, PuTTY reads the result
    Show-PCtrlGUI -GUItable $GUItable
  ]]></Script>
</PCtrl>
```

The credential and PuTTY actions know nothing about SSH dialogs; they read `$GUIResults` or `$script:` variables
if present and fall back to the selected row otherwise. New protocols (RDP, WinRM, a web console) are then one
small element each.

### Visibility, children and shortcuts

- `DisplayCondition` decides where an action appears. Its script runs for every row with the row as `$_`; the
  action is offered for the rows where it returns `$true`. `Categorie` groups the actions in the panel and the
  palette, `SortOrder` orders them inside the group. A condition may also look at the context, e.g.
  `$PowerControl.ActiveMenu.ID -eq '...'` for actions that belong to one menu only. No `DisplayCondition` at all
  means helper element, never shown.
- `Children` exist only on `Menu` and `MenuBar` elements: a comma separated list of IDs that become the entries
  of a navigation group or of a menu bar submenu. The IDs may come from any engine file; the editor's `Children`
  tab offers all elements of the same type.
- `KeyBinding` is per element, and the same key may serve several actions: `C` on "connect SSH" and on "connect
  RDP" does the right thing for the selected row. If several actions of one row share a key, the lowest
  `SortOrder` wins, the same rule that picks the default action for Enter and double click.
- Everything is reachable without a mouse: menus and commands through their bindings and the palette (Ctrl+K),
  actions through their bindings, Enter for the default action, `e` for the editor on element rows.

### Tools for workflows

- Element editor, tab `Workflow`: a table of the `PrevAction`/`NextAction` entries with priority and target,
  filter box over the element list.
- `display action timeline` on a row of `List all PCtrl Elements`: the complete chain in execution order, with
  priority, owner, apartment state and whether the step has a script.
- `Check engine`: dangling `PrevAction`/`NextAction` references, duplicate IDs.
- `Dry run`: runs the dialog of a chain and reports its values without executing the real work.
- `tools\Get-ActionTimeline.ps1`: the same timeline outside PowerControl. It reads `engine\*.xml` directly and
  prints the chain in execution order, as text or Markdown (`-Markdown`), handy for long workflows and docs:

```powershell
pwsh -NoProfile -File .\tools\Get-ActionTimeline.ps1 -Element 'open SSH as ...'
pwsh -NoProfile -File .\tools\Get-ActionTimeline.ps1 -Element 'Settings...' -Markdown > workflow.md
```

## Shell features

- Light / dark / Windows theme (Fluent), collapsed icon rails with hover popups, pinnable panels
- Output tabs: one per pinned job, each with its own filter, selection and action breadcrumb; Ctrl+Tab cycles
- Command palette (Ctrl+K), filter box over the grid (Ctrl+Shift+F), column profiles per menu, start page
- Jobs bar: running / finished / pinned, right click menu (pin, stop, rerun, repeat, compare, favorite, ...)
- Repeat a job every N seconds or minutes, with change notification and a history of previous outputs
- Compare the outputs of two jobs or of two runs of the same job: as a table with `old → new` cells or as a
  line diff; colored HTML export
- Favorites for menus and actions (star in the popups and trees), tray icon with tabs and repeating jobs,
  configurable global hotkey, window title follows the shown job
- Error banner for script errors, finished-job notification, `Logs\` with configurable detail
- Import: CSV, JSON, CliXML, clipboard (tab separated, CSV, JSON, Markdown tables), REST, SQL, folder contents
- Export: clipboard, TXT, CSV, HTML (sortable), Markdown, JSON, CliXML

## Screenshots

Output grid with the dark theme, a pinned tab, the navigation rail on the left and the actions rail on the right:

![output grid, dark theme](images/02-output-dark.png)

Navigation popup of a group and the actions popup of a category (hover over the rail icons):

![navigation popup](images/03-navigation-popup.png)

![actions popup](images/04-actions-popup.png)

Command palette (Ctrl+K) and the jobs bar (hover over the bottom bar):

![command palette](images/05-command-palette.png)

![jobs bar](images/06-jobs-bar.png)

"Compare with..." from the job menu and the result as a table (changed cells as `old → new`):

![compare dialog](images/07a-compare-dialog.png)

![compare table](images/07-compare-table.png)

Settings dialog and element editor, both described as hashtables and drawn by the dialog builder:

![settings](images/08-settings.png)

![element editor](images/09-element-editor.png)

## Customizing and sharing elements

`Customization` in the top menu:

- `List all PCtrl Elements` / `KeyBindings`: every element with its file, condition and shortcut; select a row
  and press `e` to edit it (script with syntax check, icon picker, key binding, workflow, children);
  `Duplicate`, `Move to file`, `Dry run` (runs the dialog without the real work), `Export elements...`
- `Create a new element`
- `Import elements...` and `Fetch bundles`: bundles are plain engine files; subscriptions (folders, `.xml` URLs
  or GitHub repository / folder links in `View > Settings`) are merged into `engine\Subscribed.xml` at every start
- `Recently changed`: who changed which element when; `Show diff` and `Restore version` use the history in
  `ini\history\`
- `Check engine`: parse errors, duplicate IDs, dangling references, missing icons
- `Export settings...` / `Import settings...`: favorites, column profiles, bundle sources, hotkey, ...

## Packages

This repository ships the core only: the shell, the engine and the three core engine files. Ready-made
packages for specific tasks (machine management, protocol connections, reporting, ...) will be published as
separate repositories. They are plain engine files, so they plug in like any other bundle:

- `View > Settings > Bundle sources`: the repository or folder URL, fetched at every start into
  `engine\Subscribed.xml`
- or `Customization > Import elements...` for a one-time import of a downloaded file

A list of available packages will appear here once the first ones are published.

## Folder layout

```
PowerControl.ps1      bootstrap: parameters, platform, $PowerControl object, dot-sources src\
src\01..07-Core.*     engine: index, execution, runspaces, jobs, output, sequences, headless
src\10..17-UI.*       Windows shell (WPF)
engine\               your elements: main.xml (shell, editor, bundles), ExportData.xml, ImportData.xml
icons\lucide\         Lucide icons (ISC license), referenced as Icon="lucide\name.svg"
dll\                  AvalonEdit code editor (6.3.1.120)
images\               screenshots for this README
tools\                Test-EngineXml.ps1 (validator), Get-ActionTimeline.ps1 (workflow printer), Export-DrawGuiStandalone.ps1,
                      Test-DrawGUI.ps1 (dialog playground)
tests\                Test-CoreFunctions.ps1 (89 checks, run with pwsh -NoProfile -File)
ini\, temp\, Logs\, Export\   created at runtime, not part of the repository
```

## Development

```powershell
pwsh -NoProfile -File .\tests\Test-CoreFunctions.ps1      # engine, settings, jobs, bundles, history, headless actions
pwsh -NoProfile -File .\tools\Test-EngineXml.ps1          # validates engine\*.xml (exit code = number of errors)
pwsh -NoProfile -File .\tools\Export-DrawGuiStandalone.ps1 # regenerates tools\Test-DrawGUI.ps1 after editing the dialog builder
pwsh -NoProfile -File .\tools\Get-ActionTimeline.ps1 -Element 'Edit element'   # workflow of an element, no shell needed
```

Conventions: functions `Verb-PowerControlNoun`, four spaces, no hard-coded shortcuts in the shell (they are
`Command` elements with `KeyBinding`), every new core function that engine scripts may call goes into the
`$functions` list of `Invoke-ActionScriptThreading` and into the `$wanted` list of the tests.

## License

Apache License 2.0, see `LICENSE`. Lucide icons: ISC license. AvalonEdit: MIT license.
