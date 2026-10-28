# Isolated checks for the core functions of PowerControl.ps1 and the core engine XMLs.
# Functions are extracted from the script via AST so the GUI part is never executed.
# Run:  pwsh -NoProfile -STA -File .\tests\Test-CoreFunctions.ps1
param(
    [string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'PowerControl.ps1'),
    [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Continue'
$script:LogsPath = Join-Path ([System.IO.Path]::GetTempPath()) 'PowerControl_testlogs'
New-Item -ItemType Directory -Force $script:LogsPath | Out-Null
$script:DebugLevel = 5
$script:ReturnOutput = $false

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

# the core lives in the main script plus src\*.ps1 (dot-sourced); functions are collected from all of them
$sourceFiles = @($ScriptPath) + @(Get-ChildItem -Path (Join-Path (Split-Path $ScriptPath -Parent) 'src\*.ps1') -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
$functionAsts = foreach ($file in $sourceFiles) {
    $tokens = $null; $errors = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "parse errors in $file" }
    $fileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
}
$wanted = 'Write-DebugLog','Get-ElementByIdFromIndex','Get-ActionSequence','Test-HereStringValidity',
          'Add-DynamicTypeNames','Initialize-ScriptEnvironment','Wait-PowerControlHandle','Invoke-ActionScript','Get-PropertySelection',
          'Invoke-ActionScriptThreading','Stop-PowerControlThreads','Test-STAApartmentState','Save-PowerControlXml','Update-JsonIndex','Get-PowerControlGridData',
          'Show-PowerControlOutput','Initialize-PowerControlUIBridge','Register-PowerControlDeferredOutput','Set-DataGridCellFocus','Invoke-PowerControlExternal',
          'Get-PowerControlSettings','Save-PowerControlSettings','Set-PowerControlTheme','Get-PowerControlEffectiveTheme','Add-PowerControlNotification',
          'Invoke-PowerControlUICommand','Get-PowerControlProtectedHistoryKeys','Find-PowerControlInterpreter',
          'Write-PowerControlChangeLog','Import-PowerControlBundle','Sync-PowerControlBundles'
$functionAsts |
    Where-Object { $_.Name -in $wanted } |
    ForEach-Object { . ([ScriptBlock]::Create($_.Extent.Text)) }

$results = [System.Collections.Generic.List[string]]::new()
function Assert($name, $condition, $detail = '') {
    $results.Add(("{0} {1}{2}" -f ($(if ($condition) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { " -- $detail" } else { '' })))
}

# ---- shared state like the real script ---------------------------------------------------
$Global:PowerControl = [pscustomobject]@{
    General = [pscustomobject]@{
        CurrentPath  = $ProjectRoot
        Version      = 'test'
        JsonFilePath = Join-Path $ProjectRoot 'temp\index.json'
        enginePath   = Join-Path $ProjectRoot 'engine'
        ExportPath   = Join-Path $script:LogsPath 'Export'
        TransientNodeTypes = @('Thread', 'EditTreeView', 'OutputGridHeaderMenu', 'Command')
        Theme        = 'Light'
        ThemeMode    = 'Light'
        SettingsPath = Join-Path $script:LogsPath 'settings.json'
    }
    ActiveMenu = $null
    History = New-Object System.Collections.ArrayList
    HistoryLock = [object]::new()
    WatcherState = [hashtable]::Synchronized(@{ Stop = $false; Closing = $false; NavigationDirty = $false })
    SynchronizedWindow = $null
    UI = [pscustomobject]@{
        GridReader    = $null
        ThemeSetter   = $null
        Notifications = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
        OpenDialogs   = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    }
    Settings = $null
    EventParams = [pscustomobject]@{ Sender = $null; Args = $null }
    JsonCache = $null
}
# a fresh clone has no temp\index.json yet (the shell builds it at start) and an old one may be stale:
# refresh it here so the suite runs on a plain checkout and always sees the current engine files
$indexFolder = Split-Path -Parent $Global:PowerControl.General.JsonFilePath
if (-not (Test-Path -LiteralPath $indexFolder)) { New-Item -ItemType Directory -Path $indexFolder -Force | Out-Null }
Update-JsonIndex -JsonFilePath $Global:PowerControl.General.JsonFilePath -xmlFolderPath $Global:PowerControl.General.enginePath
$Global:PowerControl.JsonCache = Get-Content $Global:PowerControl.General.JsonFilePath -Raw | ConvertFrom-Json
$OutputGrid = $null

# ---- 1. Test-HereStringValidity ------------------------------------------------------------
$r = Test-HereStringValidity -Script "`$x = 'a@`"b'; Write-Host `"c@'d`"; `$y = `"mail@`"; # @`" in a comment"
Assert 'HereString: @" inside a line is not a false positive' $r.IsValid $r.ErrorMessage

$r = Test-HereStringValidity -Script "`$x = @`"`r`nfoo`r`n`"@`r`n`$x"
Assert 'HereString: valid here-string accepted' $r.IsValid $r.ErrorMessage

$r = Test-HereStringValidity -Script "`$x = @`"`r`nfoo`r`n  `"@`r`n"
Assert 'HereString: indented terminator rejected' (-not $r.IsValid) $r.ErrorMessage

$r = Test-HereStringValidity -Script "`$x = @`"`r`nfoo`r`n"
Assert 'HereString: unclosed here-string rejected' (-not $r.IsValid) $r.ErrorMessage

$r = Test-HereStringValidity -Script 'if ($a -eq 1 { }'
Assert 'HereString: general syntax error rejected' (-not $r.IsValid) $r.ErrorMessage

# ---- 2. Get-ElementByIdFromIndex ------------------------------------------------------------
$allIds = $Global:PowerControl.JsonCache.PCtrlItems.id
$missing = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($id in $allIds) {
    $el = Get-ElementByIdFromIndex -id $id
    if ($null -eq $el -or $el.DocumentElement.ID -ne $id) { $missing += $id }
}
$sw.Stop()
Assert "ElementByIdFromIndex: all $($allIds.Count) index entries resolve via XPath" ($missing.Count -eq 0) ("missing: " + ($missing -join ','))
$results.Add("INFO ElementByIdFromIndex: $($allIds.Count) lookups in $($sw.ElapsedMilliseconds) ms")

$lower = $Global:PowerControl.JsonCache.PCtrlItems.where({ $_.type -ceq 'action' }, 'First')[0]
if ($lower) {
    $el = Get-ElementByIdFromIndex -id $lower.id
    Assert 'ElementByIdFromIndex: lowercase type="action" resolves' ($null -ne $el)
}

# ---- 3. Get-ActionSequence ------------------------------------------------------------------
$seq = Get-ActionSequence -ID 'Editaction-59be3b8811e44da689672'
Assert 'ActionSequence: editAction resolves with nested PrevAction DrawGUI' ($seq.ContainsKey('Editaction-59be3b8811e44da689672') -and $seq['Editaction-59be3b8811e44da689672'].PrevAction.ContainsKey('DrawGUI-e7670e8344194a828558f726'))
$drawGui = $seq['Editaction-59be3b8811e44da689672'].PrevAction['DrawGUI-e7670e8344194a828558f726']
Assert 'ActionSequence: DrawGUI PrevActions (Convert-XAML / Show-WPF) resolved two levels deep' ($drawGui.PrevAction.Count -ge 2) ("found: " + ($drawGui.PrevAction.Keys -join ','))

# cycle: mock the lookup with A -> Next B -> Next A
# (keep the definition as text: FunctionInfo objects are updated in place when a function is redefined)
$realLookupDefinition = (Get-Item Function:Get-ElementByIdFromIndex).ScriptBlock.ToString()
function Get-ElementByIdFromIndex([string]$id) {
    switch ($id) {
        'A' { return [xml]'<PCtrl type="Action" Label="A" ID="A"><NextAction ID="B" Priority="1"/><Script><![CDATA[1]]></Script></PCtrl>' }
        'B' { return [xml]'<PCtrl type="Action" Label="B" ID="B"><NextAction ID="A" Priority="1"/><Script><![CDATA[2]]></Script></PCtrl>' }
    }
}
$cycleOk = $true
try { $seq = Get-ActionSequence -ID 'A' -WarningAction SilentlyContinue } catch { $cycleOk = $false; $cycleErr = $_.Exception.Message }
Assert 'ActionSequence: cyclic Prev/Next references terminate' ($cycleOk -and $seq.ContainsKey('A') -and $seq['A'].NextAction.ContainsKey('B')) $cycleErr
Set-Item Function:Get-ElementByIdFromIndex -Value ([ScriptBlock]::Create($realLookupDefinition))
$restored = Get-ElementByIdFromIndex -id 'Editaction-59be3b8811e44da689672'
Assert 'ActionSequence: real lookup restored after the cycle mock' ($null -ne $restored -and $restored.DocumentElement.ID -eq 'Editaction-59be3b8811e44da689672')

# ---- 4. Add-DynamicTypeNames vs. old Invoke-Expression behaviour -----------------------------
$mappings = $Global:PowerControl.JsonCache.PCtrlItems.Where({ $null -ne $_.DisplayCondition.Code })
$sample = @(
    [pscustomobject]@{ Label = 'host1'; Hostname = 'srv01'; Protocol = 'SSH2'; HW_Kategorie_PC = 'Physisch'; Name = 'x'; ID = 'y'; Running = $true; Output = 'abc' },
    [pscustomobject]@{ Label = 'host2'; Hostname = 'srv02'; Protocol = 'RDP'; Name = 'z'; ID = 'q'; Running = $false; Output = $false }
)
function Invoke-OldDynamicTypeNames($InputObject, $Mappings) {
    foreach ($item in $InputObject) {
        foreach ($mapping in $Mappings) {
            $condition = $mapping.DisplayCondition.Code
            if ($condition -match '\.(Where|ForEach)\(') {
                $condition = $condition -replace '(?<!\.(?:Where|ForEach)\([^{]*)\$_(?![^{]*\{)', '###PLACEHOLDER###'
            }
            $condition = $condition -replace '\$_', '$item'
            $condition = $condition.replace('###PLACEHOLDER###', '$_')
            try { if (Invoke-Expression $condition) { $item.PSObject.TypeNames.Insert(0, $mapping.id) } } catch { }
        }
        $item
    }
}
$oldSet = $sample | ForEach-Object { $_.PSObject.Copy() }
$newSet = $sample | ForEach-Object { $_.PSObject.Copy() }
$null = Invoke-OldDynamicTypeNames -InputObject $oldSet -Mappings $mappings 2>$null
$null = Add-DynamicTypeNames -InputObject $newSet -Mappings $mappings
$same = $true
for ($i = 0; $i -lt $oldSet.Count; $i++) {
    $a = @($oldSet[$i].PSObject.TypeNames | Sort-Object); $b = @($newSet[$i].PSObject.TypeNames | Sort-Object)
    if (($a -join '|') -ne ($b -join '|')) { $same = $false }
}
Assert "DynamicTypeNames: compiled version classifies like the old Invoke-Expression version ($($mappings.Count) conditions)" $same

# ---- 5. Initialize-ScriptEnvironment ----------------------------------------------------------
$menuId = $Global:PowerControl.JsonCache.PCtrlItems.where({ $_.type -eq 'Menu' }, 'First')[0].id
$actionId = $Global:PowerControl.JsonCache.PCtrlItems.where({ $_.type -eq 'Action' }, 'First')[0].id

$menuItem = Initialize-ScriptEnvironment -ID $menuId
Assert 'ScriptEnvironment: menu call returns the history item' ($null -ne $menuItem -and $menuItem.ID -eq $menuId -and $menuItem.NodeType -eq 'Menu')
Assert 'ScriptEnvironment: ActiveMenu set' ($Global:PowerControl.ActiveMenu.ID -eq $menuId)

$pinned = [pscustomobject]@{ ID = 'pinned'; Name = 'pinned'; NodeType = 'Action'; Pinned = $true; Timestamp = '1'; Children = @(); Output = @(1); Thread = [pscustomobject]@{ PowerShell = $null; Runspace = $null; Handle = $null } }
[void]$Global:PowerControl.History.Add($pinned)

$actionItem = Initialize-ScriptEnvironment -ID $actionId -SelectedEntries @('row1')
Assert 'ScriptEnvironment: action call returns the new item (not History[-1])' ($null -ne $actionItem -and $actionItem.ID -eq $actionId -and $actionItem.SelectedEntries -contains 'row1')
$menuAgain = $Global:PowerControl.History.where({ $_.ID -eq $menuId }, 'First')[0]
Assert 'ScriptEnvironment: ActiveAction on active menu is set' ($menuAgain.ActiveAction.Id -eq $actionId)
Assert 'ScriptEnvironment: Children on active menu populated' ($menuAgain.Children.Count -eq 1 -and $menuAgain.Children[0].Id -eq $actionId)

Start-Sleep -Seconds 1
$menuItem2 = Initialize-ScriptEnvironment -ID $menuId
Assert 'ScriptEnvironment: second menu call re-uses the same item and resets it' ($menuItem2.ID -eq $menuId -and $menuItem2.Children.Count -eq 0 -and $null -eq $menuItem2.ActiveAction)
Assert 'ScriptEnvironment: pinned item survives the menu switch' ($Global:PowerControl.History.ID -contains 'pinned')
Assert 'ScriptEnvironment: completed, unpinned action was pruned on menu switch' ($Global:PowerControl.History.where({ $_.ID -eq $actionId }).Count -eq 0)
Assert 'ScriptEnvironment: lock released after calls' ([System.Threading.Monitor]::TryEnter($Global:PowerControl.HistoryLock, 100))
[System.Threading.Monitor]::Exit($Global:PowerControl.HistoryLock)
$Global:PowerControl.History.Clear()
$Global:PowerControl.ActiveMenu = $null

# ---- 6. Wait-PowerControlHandle -------------------------------------------------------------
function New-FakeHistoryItem($seconds) {
    $ps = [PowerShell]::Create().AddScript("Start-Sleep -Seconds $seconds")
    [pscustomobject]@{ Thread = [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() } }
}
$item = New-FakeHistoryItem 2
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Wait-PowerControlHandle -HistoryItem $item -TimeoutMs 300
Assert 'WaitHandle (no dispatcher): timeout returns $false after ~300 ms' (($r -eq $false) -and $sw.ElapsedMilliseconds -lt 1500) "$($sw.ElapsedMilliseconds) ms"
$r = Wait-PowerControlHandle -HistoryItem $item
Assert 'WaitHandle (no dispatcher): completion returns $true' ($r -eq $true -and $item.Thread.Handle.IsCompleted)
$item.Thread.PowerShell.Dispose()

$isSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if ($isSta) {
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $item = New-FakeHistoryItem 1
    $ticks = @{ n = 0 }
    $pump = [System.Windows.Threading.DispatcherTimer]::new()
    $pump.Interval = [TimeSpan]::FromMilliseconds(20)
    $pump.add_Tick({ $ticks.n++ }.GetNewClosure())
    $pump.Start()
    $r = Wait-PowerControlHandle -HistoryItem $item
    $pump.Stop()
    Assert 'WaitHandle (dispatcher): returns $true when runspace completes' ($r -eq $true)
    Assert 'WaitHandle (dispatcher): message loop kept pumping while waiting' ($ticks.n -gt 5) "$($ticks.n) ticks of an unrelated timer"
    $item.Thread.PowerShell.Dispose()

    $item = New-FakeHistoryItem 3
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Wait-PowerControlHandle -HistoryItem $item -TimeoutMs 400
    Assert 'WaitHandle (dispatcher): timeout honoured' (($r -eq $false) -and $sw.ElapsedMilliseconds -lt 1500) "$($sw.ElapsedMilliseconds) ms"
    $item.Thread.PowerShell.Stop(); $item.Thread.PowerShell.Dispose()
} else {
    $results.Add('INFO WaitHandle dispatcher tests skipped (not STA)')
}

# ---- 7. Write-DebugLog concurrency ---------------------------------------------------------------
$logFile = Join-Path $script:LogsPath 'Concurrency.log'
Remove-Item $logFile -ErrorAction SilentlyContinue
$def = (Get-Item Function:Write-DebugLog).ScriptBlock.ToString()
$jobs = 1..4 | ForEach-Object {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript("function Write-DebugLog { $def }; 1..100 | ForEach-Object { Write-DebugLog -Message ('runspace $_ line ' + `$_) -Level 1 -DebugLevel 5 -LogsPath '$($script:LogsPath)' -LogFileName 'Concurrency.log' }")
    [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() }
}
$jobs | ForEach-Object { $_.PS.EndInvoke($_.H); $_.PS.Dispose() }
$lines = Get-Content $logFile
$broken = @($lines | Where-Object { $_ -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} - runspace \d line \d+$' })
Assert 'DebugLog: 4 runspaces x 100 lines land complete and unmixed' ($lines.Count -eq 400 -and $broken.Count -eq 0) "$($lines.Count) lines, $($broken.Count) malformed"
Assert 'DebugLog: no lock files left behind' (-not (Test-Path (Join-Path $script:LogsPath '*.lock')))

# ---- 8. Save-PowerControlXml -----------------------------------------------------------------
$saveDir = Join-Path $script:LogsPath 'save'
New-Item -ItemType Directory -Force $saveDir | Out-Null
$target = Join-Path $saveDir 'test.xml'
$doc = [System.Xml.XmlDocument]::new()
$doc.LoadXml('<Engine><PCtrl type="Action" Label="x" ID="x1"><Script><![CDATA[ Write-Host "a" ]]></Script></PCtrl></Engine>')
Save-PowerControlXml -XmlDocument $doc -Path $target
$reloaded = [xml](Get-Content $target -Raw)
Assert 'SaveXml: document written and readable' ($reloaded.Engine.PCtrl.ID -eq 'x1' -and $reloaded.Engine.PCtrl.Script.'#cdata-section'.Trim() -eq 'Write-Host "a"')
Assert 'SaveXml: no temp files left behind' (@(Get-ChildItem $saveDir -Filter '*.tmp').Count -eq 0)

# a locked target must not corrupt the file and must surface an error
$lock = [System.IO.File]::Open($target, 'Open', 'ReadWrite', 'None')
$threw = $false
try { Save-PowerControlXml -XmlDocument $doc -Path $target -MaxRetries 2 } catch { $threw = $true }
$lock.Dispose()
Assert 'SaveXml: locked target throws instead of failing silently' $threw
Assert 'SaveXml: locked target left no temp file behind' (@(Get-ChildItem $saveDir -Filter '*.tmp').Count -eq 0)
Assert 'SaveXml: original file still intact after failed save' (([xml](Get-Content $target -Raw)).Engine.PCtrl.ID -eq 'x1')

# ---- 9. Get-PowerControlGridData (same thread) ------------------------------------------------
if ($isSta) {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="100" Height="100" Visibility="Hidden">
  <DataGrid Name="OutputGrid" AutoGenerateColumns="False">
    <DataGrid.Columns>
      <DataGridTextColumn Header="B" Binding="{Binding B}" DisplayIndex="1"/>
      <DataGridTextColumn Header="A" Binding="{Binding A}" DisplayIndex="0"/>
      <DataGridTextColumn Header="Hidden" Binding="{Binding Hidden}" Visibility="Collapsed" DisplayIndex="2"/>
    </DataGrid.Columns>
  </DataGrid>
</Window>
'@
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    $grid = $win.FindName('OutputGrid')
    $grid.ItemsSource = @([pscustomobject]@{ A = 1; B = 2; Hidden = 3 }, [pscustomobject]@{ A = 4; B = 5; Hidden = 6 })
    $Global:PowerControl.SynchronizedWindow = $win
    Initialize-PowerControlUIBridge -Window $win
    $data = Get-PowerControlGridData
    Assert 'GridData: visible columns in display order' (($data.Columns -join ',') -eq 'A,B') ($data.Columns -join ',')
    Assert 'GridData: all rows returned as plain objects' ($data.Rows.Count -eq 2 -and $data.Rows[1].B -eq 5)
    $grid.SelectedIndex = 1
    $sel = Get-PowerControlGridData -SelectedOnly
    Assert 'GridData: -SelectedOnly returns the selection' ($sel.Rows.Count -eq 1 -and $sel.Rows[0].A -eq 4)
    $Global:PowerControl.SynchronizedWindow = $null
    $win.Close()
}

# ---- 10. core engine XMLs ---------------------------------------------------------------------
$coreXml = 'main.xml', 'ExportData.xml'
$allIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($f in Get-ChildItem (Join-Path $ProjectRoot 'engine\*.xml')) {
    ([xml](Get-Content $f.FullName -Raw)).SelectNodes('//PCtrl') | ForEach-Object { [void]$allIds.Add($_.ID) }
}
$syntaxErrors = @(); $dangling = @(); $legacyRefs = @()
foreach ($name in $coreXml) {
    $path = Join-Path $ProjectRoot "engine\$name"
    [xml]$x = Get-Content $path -Raw
    foreach ($n in $x.SelectNodes('//PCtrl')) {
        foreach ($kind in 'Script', 'DisplayCondition') {
            $code = $n.$kind.'#cdata-section'
            if ([string]::IsNullOrWhiteSpace($code)) { continue }
            $t = $null; $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$t, [ref]$e)
            if ($e.Count -gt 0) { $syntaxErrors += "$name '$($n.Label)' $kind" }
            if ($code -match 'global:INIConfig|ShowResultSelectedEntries|\$ShowResult\b|Configuration_XML') { $legacyRefs += "$name '$($n.Label)'" }
        }
        foreach ($ref in $n.SelectNodes('PrevAction|NextAction')) { if (-not $allIds.Contains($ref.ID)) { $dangling += "$name '$($n.Label)' -> $($ref.ID)" } }
        foreach ($c in ($n.Children ?? '').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) { if (-not $allIds.Contains($c)) { $dangling += "$name '$($n.Label)' Children -> $c" } }
    }
}
Assert 'Core XML: every Script/DisplayCondition block parses' ($syntaxErrors.Count -eq 0) ($syntaxErrors -join '; ')
Assert 'Core XML: no dangling PrevAction/NextAction/Children references' ($dangling.Count -eq 0) ($dangling -join '; ')
Assert 'Core XML: no references to the old configuration model' ($legacyRefs.Count -eq 0) ($legacyRefs -join '; ')

# ---- 11. headless execution of real engine actions through the runspace path -------------------
function Invoke-HeadlessAction([string]$Id, $SelectedEntries, [int]$TimeoutSec = 30) {
    $json = $Global:PowerControl.JsonCache.PCtrlItems.where({ $_.id -eq $Id }, 'First')[0]
    $item = [PSCustomObject]@{
        ID = $json.ID; Name = $json.Label; NodeType = $json.type; SelectedEntries = $SelectedEntries
        Output = $null; ExcludeProperty = $null; DisplayProperty = $null; Parent = $null; ActiveAction = $null
        Pinned = $false; Timestamp = $(Get-Date -UFormat %s); Children = @()
        Thread = [PSCustomObject]@{ PowerShell = $null; Runspace = $null; Handle = $null; Ports = @() }
    }
    [void]$Global:PowerControl.History.Add($item)
    Get-ActionSequence -ID $Id | Invoke-ActionScriptThreading -HistoryItem $item
    $done = $item.Thread.Handle.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)
    $errors = @($item.Thread.PowerShell.Streams.Error | ForEach-Object { $_.Exception.Message })
    $out = @($item.Output)
    Stop-PowerControlThreads -HistoryItem $item
    [pscustomobject]@{ Done = $done; Output = $out; Errors = $errors }
}

# ImportData.xml: the clipboard import is a menu that needs no dialog (STA runspace, Get-Clipboard)
Set-Clipboard -Value "Name`tWert`r`nAlpha`t1`r`nBeta`t2"
$Global:PowerControl.Settings = Get-PowerControlSettings -Path (Join-Path $script:LogsPath 'settings-import.json')
$clipMenu = Invoke-HeadlessAction -Id 'ImportClipboard-7c1d2e3f4a5b6c7d8e9f0a1f'
Assert 'Headless: "Import clipboard" menu runs in a runspace and returns the pasted rows' ($clipMenu.Done -and $clipMenu.Output.Count -eq 2 -and $clipMenu.Errors.Count -eq 0) ("rows=$($clipMenu.Output.Count) errors=" + ($clipMenu.Errors -join ' | '))
Assert 'Headless: imported rows carry the columns and the PowerControl.Import type name' ($clipMenu.Output.Count -gt 0 -and $clipMenu.Output[0].Name -eq 'Alpha' -and "$($clipMenu.Output[0].Wert)" -eq '1' -and $clipMenu.Output[0].PSObject.TypeNames -contains 'PowerControl.Import')
$Global:PowerControl.Settings = $null

$about = Invoke-HeadlessAction -Id 'Bgx1qllGw2Qs8RgXAjVmhF5703Va5Da2'
Assert 'Headless: ported "About" entry returns one row with version' ($about.Done -and $about.Output.Count -eq 1 -and $about.Output[0].Version -eq 'test' -and $about.Errors.Count -eq 0) ($about.Errors -join ' | ')

$keys = Invoke-HeadlessAction -Id 'MwHxLGGoGG7y6YNQm3LAMjGZ0VHqtyGm'
Assert 'Headless: ported "KeyBindings" entry lists bound elements' ($keys.Done -and $keys.Output.Count -gt 0 -and $keys.Output[0].Shortcut -and $keys.Errors.Count -eq 0) ("rows=$($keys.Output.Count) " + ($keys.Errors -join ' | '))

$listAll = Invoke-HeadlessAction -Id 'ListAllPctrlElements-08a0f591298'
Assert 'Headless: "List all PCtrl Elements" returns every index entry' ($listAll.Done -and $listAll.Output.Count -eq $Global:PowerControl.JsonCache.PCtrlItems.Count -and $listAll.Errors.Count -eq 0) ("rows=$($listAll.Output.Count) " + ($listAll.Errors -join ' | '))

$timeline = Invoke-HeadlessAction -Id 'DisplayActionTimeline-i7PkZZVzIZ' -SelectedEntries ([pscustomobject]@{ id = 'Editaction-59be3b8811e44da689672'; Label = 'Element editor' })
$steps = @($timeline.Output | Sort-Object Sort | ForEach-Object { $_.Step.Trim() })
Assert 'Headless: ported "display action timeline" walks the workflow in execution order' ($timeline.Done -and $timeline.Errors.Count -eq 0 -and $steps.Count -ge 4 -and $steps[0] -eq 'Show-WPFWindow' -and $steps[-1] -eq 'Element editor') ("steps=" + ($steps -join ' > ') + ' errors=' + ($timeline.Errors -join ' | '))

# ---- 12. cross-runspace grid access, transient node types, output display ----------------------
if ($isSta) {
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    $grid = $win.FindName('OutputGrid')
    $grid.ItemsSource = @([pscustomobject]@{ A = 1; B = 2; Hidden = 3 }, [pscustomobject]@{ A = 4; B = 5; Hidden = 6 })
    $Global:PowerControl.SynchronizedWindow = $win
    Initialize-PowerControlUIBridge -Window $win

    # an action script in its own runspace reads the grid through the dispatcher while this (UI) thread pumps
    $probe = [PSCustomObject]@{
        ID = 'gridprobe'; Name = 'gridprobe'; NodeType = 'Action'; SelectedEntries = $null
        Output = $null; ExcludeProperty = $null; DisplayProperty = $null; Parent = $null; ActiveAction = $null
        Pinned = $false; Timestamp = $(Get-Date -UFormat %s); Children = @()
        Thread = [PSCustomObject]@{ PowerShell = $null; Runspace = $null; Handle = $null; Ports = @() }
    }
    [void]$Global:PowerControl.History.Add($probe)
    $sequence = @{ gridprobe = @{ ID = 'gridprobe'; Label = 'gridprobe'; ApartmentState = $null; PrevAction = @{}; NextAction = @{}
        ScriptBlock = '$d = Get-PowerControlGridData; $Script:PowerControlItem_Output += [pscustomobject]@{ Columns = ($d.Columns -join ","); Rows = $d.Rows.Count; FirstB = $d.Rows[0].B }' } }
    Invoke-ActionScriptThreading -Hashtable $sequence -HistoryItem $probe
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $finished = Wait-PowerControlHandle -HistoryItem $probe -TimeoutMs 15000
    $probeErrors = @($probe.Thread.PowerShell.Streams.Error | ForEach-Object { $_.Exception.Message })
    Assert 'GridData: readable from an action runspace via the dispatcher' ($finished -and $probeErrors.Count -eq 0 -and $probe.Output.Count -eq 1 -and $probe.Output[0].Columns -eq 'A,B' -and $probe.Output[0].Rows -eq 2 -and $probe.Output[0].FirstB -eq 2) ("errors=" + ($probeErrors -join ' | ') + " output=" + ($probe.Output | ConvertTo-Json -Compress))
    Stop-PowerControlThreads -HistoryItem $probe
    $Global:PowerControl.History.Clear()

    # Show-PowerControlOutput: fills a grid with auto-generated columns and hides excluded columns
    $shown = [PSCustomObject]@{ ID = 'shown'; Output = @([pscustomobject]@{ Name = 'n1'; Secret = 's'; Value = 1 }, [pscustomobject]@{ Name = 'n2'; Secret = 's'; Value = 2 }); ExcludeProperty = @('Secret'); DisplayProperty = $null }
    $win.Close()
    # a DataGrid only auto-generates columns once it is loaded, so show the window off-screen
    $win = [Windows.Markup.XamlReader]::Parse('<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="100" Height="100" WindowStartupLocation="Manual" Left="-20000" Top="-20000" ShowInTaskbar="False" ShowActivated="False"><DataGrid Name="OutputGrid" AutoGenerateColumns="True"/></Window>')
    $grid = $win.FindName('OutputGrid')
    $Global:PowerControl.SynchronizedWindow = $win
    $win.Show()
    Show-PowerControlOutput -OutputGrid $grid -HistoryItem $shown
    $grid.UpdateLayout()
    $visible = @($grid.Columns | Where-Object { $_.Visibility -eq 'Visible' } | ForEach-Object { [string]$_.Header })
    Assert 'ShowOutput: rows bound and excluded column collapsed' ($grid.Items.Count -eq 2 -and $visible -contains 'Name' -and $visible -notcontains 'Secret') ("visible=" + ($visible -join ','))

    $empty = [PSCustomObject]@{ ID = 'empty'; Output = @(); ExcludeProperty = $null; DisplayProperty = $null }
    Show-PowerControlOutput -OutputGrid $grid -HistoryItem $empty
    Assert 'ShowOutput: empty output shows the "no results" row' ($grid.Items.Count -eq 1 -and $grid.Items[0].Message -eq 'Received no results')

    $Global:PowerControl.SynchronizedWindow = $null
    $win.Close()
}

# ---- 13. deferred output display (dialog actions) through the UI timer ------------------------
if ($isSta) {
    function Invoke-TestPump([int]$Milliseconds) {
        # keeps the dispatcher running for a while so DispatcherTimers can fire
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $stop = [System.Windows.Threading.DispatcherTimer]::new()
        $stop.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
        $stop.Tag = $frame
        $stop.add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Continue = $false })
        $stop.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    $win = [Windows.Markup.XamlReader]::Parse('<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="100" Height="100" WindowStartupLocation="Manual" Left="-20000" Top="-20000" ShowInTaskbar="False" ShowActivated="False"><DataGrid Name="OutputGrid" AutoGenerateColumns="True"/></Window>')
    $grid = $win.FindName('OutputGrid')
    Initialize-PowerControlUIBridge -Window $win
    $win.Show()

    $menuStamp = '1700000000'
    $deferredMenu = [PSCustomObject]@{ ID = 'defmenu'; Name = 'menu'; NodeType = 'Menu'; Timestamp = $menuStamp; Pinned = $false; Output = @(); Children = @(); ActiveAction = $null; Thread = [PSCustomObject]@{ PowerShell = $null; Runspace = $null; Handle = $null } }
    $slow = [PowerShell]::Create().AddScript('Start-Sleep -Milliseconds 900')
    $deferredAction = [PSCustomObject]@{ ID = 'defaction'; Name = 'dialog action'; NodeType = 'Action'; Timestamp = '1700000001'; Pinned = $false; Output = @([pscustomobject]@{ Result = 'late'; Value = 42 }); ExcludeProperty = $null; DisplayProperty = $null; Children = @()
        Thread = [PSCustomObject]@{ PowerShell = $slow; Runspace = $null; Handle = $slow.BeginInvoke() } }
    $deferredMenu.ActiveAction = [pscustomobject]@{ Id = 'defaction'; Timestamp = '1700000001' }
    [void]$Global:PowerControl.History.Add($deferredMenu)
    [void]$Global:PowerControl.History.Add($deferredAction)
    $Global:PowerControl.ActiveMenu = [pscustomobject]@{ Id = 'defmenu'; TimeStamp = $menuStamp }

    Register-PowerControlDeferredOutput -HistoryItem $deferredAction -OutputGrid $grid
    Invoke-TestPump 400
    Assert 'Deferred: nothing shown while the action is still running' ($grid.Items.Count -eq 0)
    Invoke-TestPump 1500
    $grid.UpdateLayout()
    Assert 'Deferred: output appears once the action completed (timer handler sees the script functions)' ($grid.Items.Count -eq 1 -and $grid.Items[0].Result -eq 'late') "items=$($grid.Items.Count)"
    $slow.Dispose()

    # superseded: another action became active in the meantime, the late result must not replace the grid
    $grid.ItemsSource = $null
    $slow2 = [PowerShell]::Create().AddScript('Start-Sleep -Milliseconds 300')
    $late = [PSCustomObject]@{ ID = 'late'; Name = 'late'; NodeType = 'Action'; Timestamp = '1700000002'; Pinned = $false; Output = @([pscustomobject]@{ Result = 'ignored' }); ExcludeProperty = $null; DisplayProperty = $null; Children = @()
        Thread = [PSCustomObject]@{ PowerShell = $slow2; Runspace = $null; Handle = $slow2.BeginInvoke() } }
    [void]$Global:PowerControl.History.Add($late)
    Register-PowerControlDeferredOutput -HistoryItem $late -OutputGrid $grid
    Invoke-TestPump 1200
    Assert 'Deferred: result of a superseded action is not shown' ($grid.Items.Count -eq 0)
    $slow2.Dispose()

    $win.Close()
    $Global:PowerControl.SynchronizedWindow = $null
    $Global:PowerControl.History.Clear()
    $Global:PowerControl.ActiveMenu = $null
}

# ---- 14. Invoke-PowerControlExternal (Python wrapper) ------------------------------------------
$pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
if ($pythonCommand) {
    $pyCode = @'
import sys, json
rows = json.load(sys.stdin)
for r in rows:
    print(json.dumps({"Name": r["Name"], "Double": r["Value"] * 2, "Umlaut": "äöü"}))
print("plain text line")
'@
    $pyResult = @(Invoke-PowerControlExternal -Language Python -Code $pyCode -InputObject @([pscustomobject]@{ Name = 'a'; Value = 2 }, [pscustomobject]@{ Name = 'b'; Value = 5 }))
    Assert 'External: Python receives JSON rows and returns objects plus plain lines' ($pyResult.Count -eq 3 -and $pyResult[0].Double -eq 4 -and $pyResult[1].Double -eq 10 -and $pyResult[0].Umlaut -eq 'äöü' -and $pyResult[2] -eq 'plain text line') ($pyResult | ConvertTo-Json -Compress)

    $pyThrew = $false
    try { Invoke-PowerControlExternal -Language Python -Code 'import sys; sys.exit(3)' | Out-Null } catch { $pyThrew = $_.Exception.Message -like '*exited with code 3*' }
    Assert 'External: non-zero exit code throws with the exit code' $pyThrew
    Assert 'External: temp code files are cleaned up' (@(Get-ChildItem (Join-Path ([System.IO.Path]::GetTempPath()) 'PowerControl') -Filter 'external_*' -ErrorAction SilentlyContinue).Count -eq 0)
} else {
    $results.Add('INFO External: python not found, wrapper test skipped')
}

# ---- 15. "Clear finished jobs" thread action (headless) -----------------------------------------
$Global:PowerControl.History.Clear()
$clearMenu = [PSCustomObject]@{ ID = 'cmenu'; Name = 'menu'; NodeType = 'Menu'; Timestamp = '1800000000'; Pinned = $false; Output = @(1); Children = @(); ActiveAction = [pscustomobject]@{ Id = 'cactive'; Timestamp = '1800000001' }; Thread = [PSCustomObject]@{ PowerShell = $null; Runspace = $null; Handle = $null } }
$clearActive = [PSCustomObject]@{ ID = 'cactive'; Name = 'active'; NodeType = 'Action'; Timestamp = '1800000001'; Pinned = $false; Output = @(1); Children = @(); Thread = [PSCustomObject]@{ PowerShell = $null; Runspace = $null; Handle = $null } }
$clearOld = [PSCustomObject]@{ ID = 'cold'; Name = 'old finished'; NodeType = 'Action'; Timestamp = '1800000002'; Pinned = $false; Output = @(1); Children = @(); Thread = [PSCustomObject]@{ PowerShell = $null; Runspace = $null; Handle = $null } }
$clearPinned = [PSCustomObject]@{ ID = 'cpinned'; Name = 'pinned'; NodeType = 'Action'; Timestamp = '1800000003'; Pinned = $true; Output = @(1); Children = @(); Thread = [PSCustomObject]@{ PowerShell = $null; Runspace = $null; Handle = $null } }
$slowPs = [PowerShell]::Create().AddScript('Start-Sleep -Seconds 20')
$clearRunning = [PSCustomObject]@{ ID = 'crunning'; Name = 'running'; NodeType = 'Action'; Timestamp = '1800000004'; Pinned = $false; Output = $null; Children = @(); Thread = [PSCustomObject]@{ PowerShell = $slowPs; Runspace = $null; Handle = $slowPs.BeginInvoke() } }
foreach ($h in $clearMenu, $clearActive, $clearOld, $clearPinned, $clearRunning) { [void]$Global:PowerControl.History.Add($h) }
$Global:PowerControl.ActiveMenu = [pscustomobject]@{ Id = 'cmenu'; TimeStamp = '1800000000' }

$clearResult = Invoke-HeadlessAction -Id 'ClearFinishedJobs-7a3d9e1b5c2f4a68'
$remaining = @($Global:PowerControl.History | Where-Object { $_.ID -notin 'ClearFinishedJobs-7a3d9e1b5c2f4a68' } | ForEach-Object { $_.ID } | Sort-Object)
Assert 'Clear: removes finished unpinned jobs, keeps running, pinned, active menu and active action' ($clearResult.Done -and $clearResult.Errors.Count -eq 0 -and ($remaining -join ',') -eq 'cactive,cmenu,cpinned,crunning') ("remaining=" + ($remaining -join ',') + " errors=" + ($clearResult.Errors -join ' | '))
$slowPs.Stop(); $slowPs.Dispose()
$Global:PowerControl.History.Clear()
$Global:PowerControl.ActiveMenu = $null

# header-menu actions must not become the active action of the current menu
$menuItem = Initialize-ScriptEnvironment -ID $menuId
$headerId = $Global:PowerControl.JsonCache.PCtrlItems.where({ $_.type -eq 'OutputGridHeaderMenu' }, 'First')[0].id
$headerItem = Initialize-ScriptEnvironment -ID $headerId
$menuAgain = $Global:PowerControl.History.where({ $_.ID -eq $menuId }, 'First')[0]
Assert 'Transient: OutputGridHeaderMenu action is not registered as ActiveAction/Child of the menu' ($null -ne $headerItem -and $null -eq $menuAgain.ActiveAction -and $menuAgain.Children.Count -eq 0)
Assert 'Transient: TransientNodeTypes covers Thread, EditTreeView and OutputGridHeaderMenu' (@('Thread','EditTreeView','OutputGridHeaderMenu') | ForEach-Object { $_ -in $Global:PowerControl.General.TransientNodeTypes }) -notcontains $false
$Global:PowerControl.History.Clear()
$Global:PowerControl.ActiveMenu = $null

# ---- 16. settings, theme resolution, notifications ------------------------------------------------
$settingsPath = $Global:PowerControl.General.SettingsPath
Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
$defaults = Get-PowerControlSettings -Path $settingsPath
Assert 'Settings: defaults when the file is missing' ($defaults.Theme -eq 'System' -and $defaults.ColumnProfiles -is [hashtable] -and $defaults.Interpreters.Python -eq '' -and @($defaults.RecentMenus).Count -eq 0)
$defaults.Theme = 'Dark'; $defaults.RecentMenus = @('m1'); $defaults.ColumnProfiles['menuA'] = @{ col1 = @{ Width = 120.5; Visible = $true; Index = 0 } }; $defaults.Interpreters.Python = 'C:\py\python.exe'
Save-PowerControlSettings -Settings $defaults -Path $settingsPath
$reloaded = Get-PowerControlSettings -Path $settingsPath
Assert 'Settings: round trip keeps theme, recent menus, column profiles and interpreters' ($reloaded.Theme -eq 'Dark' -and @($reloaded.RecentMenus)[0] -eq 'm1' -and [double]$reloaded.ColumnProfiles['menuA']['col1']['Width'] -eq 120.5 -and $reloaded.Interpreters.Python -eq 'C:\py\python.exe')
Assert 'Settings: save leaves no temp file behind' (@(Get-ChildItem (Split-Path $settingsPath) -Filter 'settings.json.*.tmp').Count -eq 0)
[System.IO.File]::WriteAllText($settingsPath, '{ not json')
$broken = Get-PowerControlSettings -Path $settingsPath
Assert 'Settings: corrupt file falls back to defaults instead of throwing' ($broken.Theme -eq 'System')
Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue

Assert 'Theme: Light/Dark pass through unchanged' ((Get-PowerControlEffectiveTheme -Theme 'Light') -eq 'Light' -and (Get-PowerControlEffectiveTheme -Theme 'Dark') -eq 'Dark')
$windowsLight = try { [int](Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop) } catch { 1 }
Assert 'Theme: System follows the Windows app theme' ((Get-PowerControlEffectiveTheme -Theme 'System') -eq $(if ($windowsLight -eq 0) { 'Dark' } else { 'Light' }))

# Set-PowerControlTheme without a window: only the setting is stored (no exception)
$Global:PowerControl.Settings = Get-PowerControlSettings -Path $settingsPath
Set-PowerControlTheme -Theme 'Dark'
Assert 'Theme: Set-PowerControlTheme without window stores and saves the choice' ($Global:PowerControl.Settings.Theme -eq 'Dark' -and (Get-PowerControlSettings -Path $settingsPath).Theme -eq 'Dark')
$Global:PowerControl.Settings = $null
Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue

$Global:PowerControl.UI.Notifications.Clear()
Add-PowerControlNotification -Source 'test' -Message 'boom'
$note = $Global:PowerControl.UI.Notifications.Dequeue()
Assert 'Notifications: queued with source, message and severity' ($note.Source -eq 'test' -and $note.Message -eq 'boom' -and $note.Severity -eq 'Error')
# from a runspace (shared queue, as Invoke-ActionScript does on a failing script)
$noteRs = [runspacefactory]::CreateRunspace(); $noteRs.Open()
$noteRs.SessionStateProxy.SetVariable('PowerControl', $Global:PowerControl)
$notePs = [PowerShell]::Create(); $notePs.Runspace = $noteRs
[void]$notePs.AddScript("function Add-PowerControlNotification { $((Get-Command Add-PowerControlNotification).Definition) }; Add-PowerControlNotification -Source 'rs' -Message 'from runspace'")
[void]$notePs.Invoke(); $notePs.Dispose(); $noteRs.Dispose()
Assert 'Notifications: a runspace can enqueue through the shared queue' ($Global:PowerControl.UI.Notifications.Count -eq 1 -and $Global:PowerControl.UI.Notifications.Dequeue().Source -eq 'rs')

# ---- 17. shutdown behaviour: nested wait frames and blocked runspaces ---------------------------------
# Wait-PowerControlHandle on the UI thread must give up when the window is closing (otherwise ShowDialog never returns)
$neverDone = [PSCustomObject]@{ ID = 'never'; Thread = [PSCustomObject]@{ Handle = [pscustomobject]@{ IsCompleted = $false } } }
$Global:PowerControl.WatcherState.Closing = $false
$release = [System.Windows.Threading.DispatcherTimer]::new()
$release.Interval = [TimeSpan]::FromMilliseconds(300)
$release.add_Tick({ param($s, $e) $s.Stop(); $Global:PowerControl.WatcherState.Closing = $true })
$release.Start()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$waitResult = Wait-PowerControlHandle -HistoryItem $neverDone     # no timeout: only the Closing flag can end it
$sw.Stop()
Assert 'WaitHandle (dispatcher): nested frame is released by the Closing flag' ($waitResult -eq $false -and $sw.ElapsedMilliseconds -lt 3000) "$($sw.ElapsedMilliseconds) ms, result=$waitResult"
$Global:PowerControl.WatcherState.Closing = $false

# Stop-PowerControlThreads must not block on a runspace that sits in a native call
$stuckPs = [PowerShell]::Create().AddScript('[System.Threading.Thread]::Sleep(8000)')
$stuckItem = [PSCustomObject]@{ ID = 'stuck'; Name = 'stuck'; NodeType = 'Action'; Timestamp = '1800000010'; Pinned = $false; Output = $null; Children = @(); Thread = [PSCustomObject]@{ PowerShell = $stuckPs; Runspace = $null; Handle = $stuckPs.BeginInvoke() } }
Start-Sleep -Milliseconds 300
$Global:PowerControl.WatcherState.LeakedRunspaces = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Stop-PowerControlThreads -HistoryItem $stuckItem
$sw.Stop()
Assert 'Stop: blocked runspace is abandoned after ~3 s instead of freezing the shutdown' ($sw.ElapsedMilliseconds -lt 6000 -and [int]$Global:PowerControl.WatcherState.LeakedRunspaces -eq 1) "$($sw.ElapsedMilliseconds) ms, leaked=$($Global:PowerControl.WatcherState.LeakedRunspaces)"
$quickPs = [PowerShell]::Create().AddScript('Start-Sleep -Seconds 30')
$quickItem = [PSCustomObject]@{ ID = 'quick'; Name = 'quick'; NodeType = 'Action'; Timestamp = '1800000011'; Pinned = $false; Output = $null; Children = @(); Thread = [PSCustomObject]@{ PowerShell = $quickPs; Runspace = $null; Handle = $quickPs.BeginInvoke() } }
Start-Sleep -Milliseconds 300
$Global:PowerControl.WatcherState.LeakedRunspaces = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Stop-PowerControlThreads -HistoryItem $quickItem
$sw.Stop()
Assert 'Stop: interruptible runspace (Start-Sleep) is stopped and disposed promptly' ($sw.ElapsedMilliseconds -lt 3000 -and [int]$Global:PowerControl.WatcherState.LeakedRunspaces -eq 0 -and $quickItem.Thread.Handle.IsCompleted) "$($sw.ElapsedMilliseconds) ms, completed=$($quickItem.Thread.Handle.IsCompleted)"

# ---- 18b. a pinned menu entry survives a re-run of the same menu -----------------------------------------
$Global:PowerControl.History.Clear(); $Global:PowerControl.ActiveMenu = $null
$firstRun = Initialize-ScriptEnvironment -ID $menuId
$firstRun.Output = @([pscustomobject]@{ Message = 'first' })
$firstRun.Pinned = $true
$firstStamp = $firstRun.Timestamp
Start-Sleep -Milliseconds 1100
$secondRun = Initialize-ScriptEnvironment -ID $menuId
$pinnedStill = $Global:PowerControl.History.where({ $_.ID -eq $menuId -and $_.Pinned -eq $true }, 'First')[0]
Assert 'Pin: re-running a pinned menu creates a new entry and keeps the pinned one (output intact)' ($null -ne $pinnedStill -and "$($pinnedStill.Timestamp)" -eq "$firstStamp" -and $pinnedStill.Output.Count -eq 1 -and -not [object]::ReferenceEquals($secondRun, $pinnedStill) -and $secondRun.Pinned -ne $true) "pinned=$($null -ne $pinnedStill) same=$([object]::ReferenceEquals($secondRun, $pinnedStill))"
Assert 'Pin: the new run becomes the active menu' ($Global:PowerControl.ActiveMenu.Id -eq $menuId -and "$($Global:PowerControl.ActiveMenu.TimeStamp)" -eq "$($secondRun.Timestamp)")
$Global:PowerControl.History.Clear(); $Global:PowerControl.ActiveMenu = $null

# ---- 18a. index fields used by the shell (schema 2): HasScript, Toolbar; UI commands without a window ---
$index = $Global:PowerControl.JsonCache
$folderGroup = $index.PCtrlItems.where({ $_.id -eq 'ImportGroup-7c1d2e3f4a5b6c7d8e9f0a1b' }, 'First')[0]     # "Import" container (no script)
$folderMenu  = $index.PCtrlItems.where({ $_.id -eq 'ImportClipboard-7c1d2e3f4a5b6c7d8e9f0a1f' }, 'First')[0] # "Import clipboard"
$clearJobs   = $index.PCtrlItems.where({ $_.id -eq 'ClearFinishedJobs-7a3d9e1b5c2f4a68' }, 'First')[0]
Assert 'Index: schema 3 with HasScript (container false, menu true)' ([int]$index.schema -eq 3 -and $folderGroup.HasScript -eq $false -and $folderMenu.HasScript -eq $true) "schema=$($index.schema) group=$($folderGroup.HasScript) menu=$($folderMenu.HasScript)"
Assert 'Index: Toolbar="Jobs" of "Clear finished jobs" is indexed' ($clearJobs.Toolbar -eq 'Jobs')
$orphanAction = $index.PCtrlItems.where({ $_.Label -eq 'Edit DataGrid' }, 'First')[0]
Assert 'Index: a missing Categorie attribute stays $null (orphan actions are not grouped under an empty category)' ($null -ne $orphanAction -and $null -eq $orphanAction.DisplayCondition.Categorie -and $null -ne $orphanAction.DisplayCondition.Code)
Assert 'Interpreter: Find-PowerControlInterpreter locates python or returns $null without throwing' ($null -eq (Find-PowerControlInterpreter -Language Python) -or (Test-Path -LiteralPath (Find-PowerControlInterpreter -Language Python)))
$shellCommands = @($index.PCtrlItems.where({ $_.type -eq 'Command' -and $_.KeyBinding.Key }))
Assert 'Shell shortcuts live in main.xml as Command elements with KeyBindings (palette, filter)' ($shellCommands.Count -ge 2 -and ($shellCommands.Label -join '|') -match 'Command _palette' -and ($shellCommands.Label -join '|') -match 'Filter output')
$uiCommandThrew = $false
try { Invoke-PowerControlUICommand -Name 'CommandPalette' } catch { $uiCommandThrew = $true }
Assert 'UICommand: without a window the call is ignored instead of throwing' (-not $uiCommandThrew)

# ---- 18. Draw GUI: dialogs register themselves for the shutdown ----------------------------------------
$showWindowScript = ([xml](Get-Content (Join-Path $ProjectRoot 'engine\main.xml') -Raw)).Engine.PCtrl | Where-Object { $_.ID -eq 'ShowWpfwindow-46d45a0025184690a1' } | ForEach-Object { $_.Script.InnerText }
Assert 'DrawGUI: Show-WPFWindow registers the dialog in PowerControl.UI.OpenDialogs and removes it afterwards' ($showWindowScript -match 'OpenDialogs\.Add\(\$Window\)' -and $showWindowScript -match 'openDialogs\.Remove\(\$Window\)')

# ---- 19. bundles, subscriptions and the change log (in a temporary engine folder) ----------------------
$savedGeneral = @{ CurrentPath = $Global:PowerControl.General.CurrentPath; enginePath = $Global:PowerControl.General.enginePath; JsonFilePath = $Global:PowerControl.General.JsonFilePath; SettingsPath = $Global:PowerControl.General.SettingsPath }
$savedCache = $Global:PowerControl.JsonCache
$savedSettings = $Global:PowerControl.Settings
$sandbox = Join-Path $script:LogsPath "bundles-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
New-Item -ItemType Directory -Path (Join-Path $sandbox 'engine'), (Join-Path $sandbox 'temp'), (Join-Path $sandbox 'source') -Force | Out-Null
$Global:PowerControl.General.CurrentPath = $sandbox
$Global:PowerControl.General.enginePath = Join-Path $sandbox 'engine'
$Global:PowerControl.General.JsonFilePath = Join-Path $sandbox 'temp\index.json'
$Global:PowerControl.General.SettingsPath = Join-Path $sandbox 'settings.json'
$ownXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Engine>
  <PCtrl type="Menu" Label="Own" ID="Own-1" Icon="lucide\zap.svg">
    <Script><![CDATA[ 'own' ]]></Script>
  </PCtrl>
</Engine>
'@
[System.IO.File]::WriteAllText((Join-Path $sandbox 'engine\Own.xml'), $ownXml, [System.Text.UTF8Encoding]::new($false))
Copy-Item (Join-Path $ProjectRoot 'engine\main.xml') (Join-Path $sandbox 'engine\main.xml')   # the history actions (Show diff, Restore version) live there
Update-JsonIndex -JsonFilePath $Global:PowerControl.General.JsonFilePath -xmlFolderPath $Global:PowerControl.General.enginePath
$Global:PowerControl.JsonCache = Get-Content $Global:PowerControl.General.JsonFilePath -Raw | ConvertFrom-Json
$Global:PowerControl.Settings = Get-PowerControlSettings -Path $Global:PowerControl.General.SettingsPath
$bundleXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Engine>
  <PCtrl type="Menu" Label="Own (bundle)" ID="Own-1" Icon="lucide\zap.svg">
    <Script><![CDATA[ 'bundle version' ]]></Script>
  </PCtrl>
  <PCtrl type="Menu" Label="New" ID="New-1" Icon="lucide\zap.svg">
    <Script><![CDATA[ 'new' ]]></Script>
  </PCtrl>
</Engine>
'@
[System.IO.File]::WriteAllText((Join-Path $sandbox 'source\team.xml'), $bundleXml, [System.Text.UTF8Encoding]::new($false))
$importRows = @(Import-PowerControlBundle -Path (Join-Path $sandbox 'source\team.xml') -TargetName 'Imported.xml')
Assert 'Bundle import: existing ID is skipped, new ID lands in Imported.xml' ((($importRows | Where-Object { $_.ID -eq 'Own-1' }).Result -like 'skipped*') -and (($importRows | Where-Object { $_.ID -eq 'New-1' }).Result -eq 'imported') -and (Test-Path (Join-Path $sandbox 'engine\Imported.xml'))) ($importRows | ForEach-Object { "$($_.ID)=$($_.Result)" }) -join '; '
Assert 'Bundle import: the own element was not touched' (([xml](Get-Content (Join-Path $sandbox 'engine\Own.xml') -Raw)).Engine.PCtrl.Label -eq 'Own')
$Global:PowerControl.Settings.BundleSources = @((Join-Path $sandbox 'source'))
$syncRows = @(Sync-PowerControlBundles)
$subscribedPath = Join-Path $sandbox 'engine\Subscribed.xml'
Assert 'Bundle sync (folder source): own and already imported elements stay untouched, nothing new to take over' (@($syncRows | Where-Object { $_.Result -like 'skipped (own*' }).Count -eq 2 -and -not (Test-Path $subscribedPath)) ($syncRows | ForEach-Object { $_.Result }) -join '; '
$bundleXml2 = $bundleXml.Replace('ID="New-1"', 'ID="Sub-1"').Replace('ID="Own-1"', 'ID="Sub-2"')
[System.IO.File]::WriteAllText((Join-Path $sandbox 'source\team.xml'), $bundleXml2, [System.Text.UTF8Encoding]::new($false))
$syncRows = @(Sync-PowerControlBundles)
Assert 'Bundle sync: changed bundle is taken over into Subscribed.xml and the hash is remembered' (@($syncRows | Where-Object { $_.Result -eq 'imported' }).Count -eq 2 -and (Test-Path $subscribedPath) -and $Global:PowerControl.Settings.BundleState.Count -eq 1) ($syncRows | ForEach-Object { $_.Result }) -join '; '
$syncRows = @(Sync-PowerControlBundles)
Assert 'Bundle sync: unchanged bundle is not imported again' ($syncRows.Count -eq 1 -and $syncRows[0].Result -like 'unchanged*') ($syncRows | ForEach-Object { $_.Result }) -join '; '
[System.IO.File]::WriteAllText((Join-Path $sandbox 'source\team.xml'), $bundleXml2.Replace("'new'", "'new v2'"), [System.Text.UTF8Encoding]::new($false))
$syncRows = @(Sync-PowerControlBundles)
Assert 'Bundle sync: a changed subscribed element is replaced (Subscribed.xml only)' (@($syncRows | Where-Object { $_.Result -like 'replaced*Script*' }).Count -eq 1 -and @($syncRows | Where-Object { $_.Result -eq 'unchanged' }).Count -eq 1) ($syncRows | ForEach-Object { $_.Result }) -join '; '
$changeLogPath = Join-Path $sandbox 'ini\changes.json'
$changeLog = if (Test-Path $changeLogPath) { @(Get-Content $changeLogPath -Raw | ConvertFrom-Json) } else { @() }
Assert 'Change log: replacing a subscribed element writes a "changed" entry with user, file and ID' (@($changeLog | Where-Object { $_.Change -eq 'changed' -and $_.ID -eq 'Sub-1' -and $_.File -eq 'Subscribed.xml' -and $_.User }).Count -eq 1) "entries=$($changeLog.Count)"
$historyFiles = @(Get-ChildItem -LiteralPath (Join-Path $sandbox 'ini\history\Sub-1') -Filter '*.xml' -File -ErrorAction SilentlyContinue)
Assert 'Change log: the previous version of the changed element is kept in ini\history\<ID>' ($historyFiles.Count -eq 1 -and (Get-Content $historyFiles[0].FullName -Raw) -match "'new'") "files=$($historyFiles.Count)"
$oldDoc = [xml]$ownXml; $newDoc = [xml]($ownXml.Replace('ID="Own-1"', 'ID="Own-2"'))
Write-PowerControlChangeLog -OldDocument $oldDoc -NewDocument $newDoc -File 'Own.xml'
$changeLog = @(Get-Content $changeLogPath -Raw | ConvertFrom-Json)
Assert 'Change log: an exchanged ID is logged as removed + added' (@($changeLog | Where-Object { $_.File -eq 'Own.xml' -and $_.Change -eq 'removed' -and $_.ID -eq 'Own-1' }).Count -eq 1 -and @($changeLog | Where-Object { $_.File -eq 'Own.xml' -and $_.Change -eq 'added' -and $_.ID -eq 'Own-2' }).Count -eq 1) "entries=$($changeLog.Count)"
# "Show diff" and "Restore version" (main.xml actions) on the change log row of the replaced subscribed element
$changedEntry = @(Get-Content $changeLogPath -Raw | ConvertFrom-Json) | Where-Object { $_.Change -eq 'changed' -and $_.ID -eq 'Sub-1' } | Select-Object -First 1
$changeRow = [pscustomobject]@{ Time = ([datetime]$changedEntry.Time).ToString('yyyy-MM-dd HH:mm:ss'); User = $changedEntry.User; Machine = $changedEntry.Machine; File = $changedEntry.File; Element = $changedEntry.Label; Change = $changedEntry.Change; ID = $changedEntry.ID }
$diffRun = Invoke-HeadlessAction -Id 'ChangeDiff-3d4e5f60718293a4b5c6d7e8f9a0b1c3' -SelectedEntries @($changeRow)
Assert 'History: "Show diff" lists the removed and added script lines of the change' ($diffRun.Done -and $diffRun.Errors.Count -eq 0 -and @($diffRun.Output | Where-Object { $_.Status -eq 'removed' -and $_.Text -like "*'new'*" }).Count -eq 1 -and @($diffRun.Output | Where-Object { $_.Status -eq 'added' -and $_.Text -like "*'new v2'*" }).Count -eq 1) ("rows=$($diffRun.Output.Count) errors=" + ($diffRun.Errors -join ' | '))
$restoreRun = Invoke-HeadlessAction -Id 'RestoreVersion-5f60718293a4b5c6d7e8f9a0b1c2d3e5' -SelectedEntries @($changeRow)
$subscribedNow = Get-Content $subscribedPath -Raw
Assert 'History: "Restore version" writes the previous version back into the engine file' ($restoreRun.Done -and $restoreRun.Errors.Count -eq 0 -and $subscribedNow -match "'new'" -and $subscribedNow -notmatch "'new v2'" -and $restoreRun.Output[0].Result -like 'restored version*') ("result=$($restoreRun.Output[0].Result) errors=" + ($restoreRun.Errors -join ' | '))
$syncRows = @(Sync-PowerControlBundles -Sources @('https://github.com/this-owner-does-not-exist-123/nope'))
Assert 'Bundle sync: an unreachable GitHub source is reported as a row, not thrown' ($syncRows.Count -eq 1 -and $syncRows[0].Result -like 'error*')
$Global:PowerControl.General.CurrentPath = $savedGeneral.CurrentPath; $Global:PowerControl.General.enginePath = $savedGeneral.enginePath
$Global:PowerControl.General.JsonFilePath = $savedGeneral.JsonFilePath; $Global:PowerControl.General.SettingsPath = $savedGeneral.SettingsPath
$Global:PowerControl.JsonCache = $savedCache; $Global:PowerControl.Settings = $savedSettings
Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue

# ---- report ----------------------------------------------------------------------------------
$results | ForEach-Object { $_ }
$fails = @($results | Where-Object { $_ -like 'FAIL*' }).Count
"`n$(@($results | Where-Object { $_ -like 'PASS*' }).Count) passed, $fails failed"
exit $fails
