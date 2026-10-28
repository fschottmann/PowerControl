<#
  tools\Get-ActionTimeline.ps1 - shows the PrevAction/NextAction workflow of an element outside PowerControl.

  Reads engine\*.xml directly (no running shell needed) and prints the chain the way the engine executes it:
  all PrevActions (highest Priority first), the element's own script, all NextActions (highest Priority first),
  recursively. The same resolver logic as Get-ActionSequence / "display action timeline" in main.xml.

  Examples
    pwsh -NoProfile -File .\tools\Get-ActionTimeline.ps1 -Element 'Settings...'
    pwsh -NoProfile -File .\tools\Get-ActionTimeline.ps1 -Element 'Edit element' -Markdown > workflow.md
    pwsh -NoProfile -File .\tools\Get-ActionTimeline.ps1 -Element 'OpenSSH-0001' -Engine D:\other\engine -PassThru | Format-Table
#>
[CmdletBinding()]
param(
    # label (case insensitive) or ID of the element to start from
    [Parameter(Mandatory)][string]$Element,
    # engine folder; default: ..\engine next to this script
    [string]$Engine = (Join-Path (Split-Path -Parent $PSScriptRoot) 'engine'),
    # Markdown list instead of the indented text tree
    [switch]$Markdown,
    # return the step objects instead of printing
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Engine -PathType Container)) { throw "Engine folder not found: $Engine" }

# ---- index: ID -> element ---------------------------------------------------------------------------------
$index = @{}
foreach ($file in Get-ChildItem -LiteralPath $Engine -Filter '*.xml' -File) {
    try { $doc = [xml](Get-Content -LiteralPath $file.FullName -Raw) } catch { Write-Warning "$($file.Name): $($_.Exception.Message)"; continue }
    foreach ($node in $doc.SelectNodes('//PCtrl')) {
        $id = $node.GetAttribute('ID')
        if (-not $id) { continue }
        if ($index.ContainsKey($id)) { Write-Warning "Duplicate ID $id ($($index[$id].File) and $($file.Name))" }
        $script = $node.SelectSingleNode('Script')
        $index[$id] = [pscustomobject]@{
            ID        = $id
            Label     = ($node.GetAttribute('Label') -replace '_', '')   # access key underscores are display only
            Type      = $node.GetAttribute('type')
            File      = $file.Name
            Apartment = $(if ($node.GetAttribute('ApartmentState') -eq 'STA') { 'STA' } else { 'MTA' })
            HasScript = ($null -ne $script -and -not [string]::IsNullOrWhiteSpace($script.InnerText))
            Prev      = @($node.SelectNodes('PrevAction') | ForEach-Object { [pscustomobject]@{ ID = $_.GetAttribute('ID'); Priority = [int]('0' + $_.GetAttribute('Priority')) } })
            Next      = @($node.SelectNodes('NextAction') | ForEach-Object { [pscustomobject]@{ ID = $_.GetAttribute('ID'); Priority = [int]('0' + $_.GetAttribute('Priority')) } })
        }
    }
}
if ($index.Count -eq 0) { throw "No PCtrl elements found in $Engine" }

# ---- start element: ID first, then label ------------------------------------------------------------------
$start = if ($index.ContainsKey($Element)) { $index[$Element] } else {
    $byLabel = @($index.Values | Where-Object { ($_.Label -replace '_', '') -eq ($Element -replace '_', '') })
    if ($byLabel.Count -eq 0) { throw "No element with ID or label '$Element' in $Engine" }
    if ($byLabel.Count -gt 1) { Write-Warning "Label '$Element' is used $($byLabel.Count) times, taking $($byLabel[0].ID) ($($byLabel[0].File))" }
    $byLabel[0]
}

# ---- walk in execution order ------------------------------------------------------------------------------
$steps = [System.Collections.Generic.List[object]]::new()
$order = 0
function Add-Step {
    param([string]$ID, [string]$Role, [int]$Priority, [int]$Depth, [string]$Owner, [System.Collections.Generic.HashSet[string]]$Path)
    $node = $index[$ID]
    if (-not $Path.Add($ID)) {
        $steps.Add([pscustomobject]@{ Order = ++$script:order; Depth = $Depth; Role = $Role; Priority = $Priority; Label = "$ID (cycle, skipped)"; ID = $ID; Type = ''; File = ''; Apartment = ''; HasScript = $false; Owner = $Owner })
        return
    }
    if ($null -eq $node) {
        $steps.Add([pscustomobject]@{ Order = ++$script:order; Depth = $Depth; Role = $Role; Priority = $Priority; Label = "$ID (missing in engine)"; ID = $ID; Type = ''; File = ''; Apartment = ''; HasScript = $false; Owner = $Owner })
        [void]$Path.Remove($ID); return
    }
    foreach ($prev in ($node.Prev | Sort-Object Priority -Descending)) { Add-Step -ID $prev.ID -Role 'PrevAction' -Priority $prev.Priority -Depth ($Depth + 1) -Owner $node.Label -Path $Path }
    $steps.Add([pscustomobject]@{ Order = ++$script:order; Depth = $Depth; Role = $Role; Priority = $Priority; Label = $node.Label; ID = $node.ID; Type = $node.Type; File = $node.File; Apartment = $node.Apartment; HasScript = $node.HasScript; Owner = $Owner })
    foreach ($next in ($node.Next | Sort-Object Priority -Descending)) { Add-Step -ID $next.ID -Role 'NextAction' -Priority $next.Priority -Depth ($Depth + 1) -Owner $node.Label -Path $Path }
    [void]$Path.Remove($ID)
}
Add-Step -ID $start.ID -Role 'Element' -Priority 0 -Depth 0 -Owner '' -Path ([System.Collections.Generic.HashSet[string]]::new())

if ($PassThru) { return $steps }

# ---- output -----------------------------------------------------------------------------------------------
$sta = ($steps | Where-Object { $_.Apartment -eq 'STA' }).Count -gt 0
if ($Markdown) {
    "# Workflow: $($start.Label) ($($start.ID), $($start.File))"
    ""
    "Runs as one job in one runspace ($(if ($sta) { 'STA, because a member needs it' } else { 'MTA' })). Steps in execution order:"
    ""
    foreach ($s in $steps) {
        $prefix = '  ' * $s.Depth
        $role = switch ($s.Role) { 'Element' { 'element' } 'PrevAction' { "PrevAction, priority $($s.Priority)" } 'NextAction' { "NextAction, priority $($s.Priority)" } }
        $note = @(); if (-not $s.HasScript -and $s.File) { $note += 'no script of its own' }; if ($s.Apartment -eq 'STA') { $note += 'STA' }
        "$prefix- **$($s.Order). $($s.Label)** ($role$(if ($s.File) { "; $($s.Type) in $($s.File)" }))$(if ($note) { ' · ' + ($note -join ', ') })"
    }
}
else {
    "Workflow of '$($start.Label)' [$($start.ID)] in $($start.File) - $($steps.Count) step(s), $(if ($sta) { 'STA' } else { 'MTA' })"
    ""
    foreach ($s in $steps) {
        $prefix = '    ' * $s.Depth
        $role = switch ($s.Role) { 'Element' { '' } 'PrevAction' { "[Prev $($s.Priority)] " } 'NextAction' { "[Next $($s.Priority)] " } }
        $flags = @(); if (-not $s.HasScript -and $s.File) { $flags += 'no script' }; if ($s.Apartment -eq 'STA') { $flags += 'STA' }
        "{0,3}. {1}{2}{3}{4}" -f $s.Order, $prefix, $role, $s.Label, $(if ($flags) { "  (" + ($flags -join ', ') + ")" } else { '' })
    }
}
