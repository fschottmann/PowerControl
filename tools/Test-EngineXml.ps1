<#
  .SYNOPSIS
  Validates the engine XML files of PowerControl without starting the application.

  .DESCRIPTION
  Checks every engine\*.xml (or the files given with -Path):
    - well-formed XML, root <Engine>, every PCtrl has an ID and a type
    - duplicate IDs across all files
    - every <Script> and <DisplayCondition> CDATA block parses as PowerShell
    - PrevAction / NextAction / Children references point to existing IDs
    - references to the old configuration model (warning)
  Exit code is the number of errors, so the script can run in a pre-commit hook or a pipeline.

  .EXAMPLE
  pwsh -NoProfile -File .\tools\Test-EngineXml.ps1
  pwsh -NoProfile -File .\tools\Test-EngineXml.ps1 -Path .\engine\main.xml -Strict

  .EXAMPLE
  pwsh -NoProfile -File .\tools\Test-EngineXml.ps1 -Path ".\engine\main.xml,.\engine\ExportData.xml"
  (several files: one quoted, comma separated string, because "pwsh -File" does not understand PowerShell arrays)
#>
[CmdletBinding()]
param(
    # one or more files; a single comma separated string is accepted too (see examples)
    [Parameter(Mandatory = $false, Position = 0)][string[]]$Path,
    [Parameter(Mandatory = $false)][string]$EngineFolder = (Join-Path (Split-Path $PSScriptRoot -Parent) 'engine'),
    # treat legacy-model references as errors instead of warnings
    [Parameter(Mandatory = $false)][switch]$Strict,
    # return the findings as objects instead of printing a table (used by "Check engine" in the application)
    [Parameter(Mandatory = $false)][switch]$PassThru
)

$ErrorActionPreference = 'Stop'
# "pwsh -File" hands "a.xml, b.xml" over as one string, so split on commas as well
$files = if ($Path) { $Path -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { Get-Item $_ } } else { Get-ChildItem -Path (Join-Path $EngineFolder '*.xml') }
$allFiles = Get-ChildItem -Path (Join-Path $EngineFolder '*.xml')

$findings = [System.Collections.Generic.List[pscustomobject]]::new()
function Add-Finding([string]$Severity, [string]$File, [string]$Element, [string]$Message) {
    $findings.Add([pscustomobject]@{ Severity = $Severity; File = $File; Element = $Element; Message = $Message })
}

# all IDs of the whole engine folder (references may point into other files)
$allIds = [System.Collections.Generic.Dictionary[string, string]]::new()
foreach ($file in $allFiles) {
    try {
        [xml]$doc = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($node in $doc.SelectNodes('//PCtrl')) {
            if ([string]::IsNullOrEmpty($node.ID)) { continue }
            if ($allIds.ContainsKey($node.ID)) { Add-Finding 'Error' $file.Name $node.Label "duplicate ID $($node.ID) (also in $($allIds[$node.ID]))" }
            else { $allIds[$node.ID] = $file.Name }
        }
    }
    catch { Add-Finding 'Error' $file.Name '' "not well-formed: $($_.Exception.Message)" }
}

$legacyPattern = 'global:INIConfig|ShowResultSelectedEntries|\$ShowResult\b|Configuration_XML|Set-XMLSignature'
$blocks = 0
foreach ($file in $files) {
    try { [xml]$doc = Get-Content -LiteralPath $file.FullName -Raw } catch { continue }
    if ($doc.DocumentElement.Name -ne 'Engine') { Add-Finding 'Error' $file.Name '' "root element is <$($doc.DocumentElement.Name)>, expected <Engine>" }

    foreach ($node in $doc.SelectNodes('//PCtrl')) {
        $label = if ($node.Label) { $node.Label } else { '(no label)' }
        if ([string]::IsNullOrEmpty($node.ID)) { Add-Finding 'Error' $file.Name $label 'PCtrl without ID' }
        if ([string]::IsNullOrEmpty($node.type)) { Add-Finding 'Error' $file.Name $label 'PCtrl without type' }

        foreach ($kind in 'Script', 'DisplayCondition') {
            $code = $node.$kind.'#cdata-section'
            if ([string]::IsNullOrWhiteSpace($code)) { continue }
            $blocks++
            $tokens = $null; $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
            foreach ($parseError in $errors) {
                Add-Finding 'Error' $file.Name $label "$kind line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
            }
            if ($code -match $legacyPattern) {
                Add-Finding ($(if ($Strict) { 'Error' } else { 'Warning' })) $file.Name $label "$kind references the old configuration model ($($Matches[0]))"
            }
        }

        foreach ($reference in $node.SelectNodes('PrevAction|NextAction')) {
            if (-not $allIds.ContainsKey([string]$reference.ID)) { Add-Finding 'Error' $file.Name $label "$($reference.LocalName) -> $($reference.ID) does not exist" }
            if ($reference.Priority -and -not ($reference.Priority -as [int])) { Add-Finding 'Warning' $file.Name $label "$($reference.LocalName) $($reference.ID) has a non-numeric Priority '$($reference.Priority)'" }
        }
        foreach ($child in ([string]$node.Children).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) {
            if (-not $allIds.ContainsKey($child)) { Add-Finding 'Error' $file.Name $label "Children -> $child does not exist" }
        }
        if ($node.Icon) {
            $iconPath = Join-Path (Split-Path $EngineFolder -Parent) "icons\$($node.Icon)"
            if (-not (Test-Path -LiteralPath $iconPath)) { Add-Finding 'Info' $file.Name $label "icon not found: $($node.Icon)" }
        }
    }
}

$errorCount = @($findings | Where-Object Severity -eq 'Error').Count
$warningCount = @($findings | Where-Object Severity -eq 'Warning').Count
if ($PassThru) { return ($findings | Sort-Object Severity, File, Element) }

$findings | Sort-Object Severity, File, Element | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
Write-Host ("{0} file(s), {1} code block(s) parsed: {2} error(s), {3} warning(s), {4} info" -f @($files).Count, $blocks, $errorCount, $warningCount, @($findings | Where-Object Severity -eq 'Info').Count)
exit $errorCount
