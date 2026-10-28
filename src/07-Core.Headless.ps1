# PowerControl - 07-Core.Headless.ps1
# -Run / -Headless: run one element without the window (scheduled tasks, shortcuts, scripts) and write its rows
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

function Resolve-PowerControlElementId {
    <# ID, exact label (without the menu underscore) or a label fragment of a runnable element #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)
    $items = @($Global:PowerControl.JsonCache.PCtrlItems)
    $hit = $items | Where-Object { $_.id -ceq $Name } | Select-Object -First 1
    if (-not $hit) { $hit = $items | Where-Object { $_.HasScript -and ((([string]$_.Label) -replace '_', '') -eq $Name) } | Select-Object -First 1 }
    if (-not $hit) { $hit = $items | Where-Object { $_.HasScript -and ((([string]$_.Label) -replace '_', '') -like "*$Name*") } | Select-Object -First 1 }
    if ($hit) { [string]$hit.id } else { $null }
}

function Invoke-PowerControlHeadless {
    <#
      .SYNOPSIS
      Runs one menu or action without the window and returns its rows (or writes them to -OutFile).

      .DESCRIPTION
      Same path as the window uses (Initialize-ScriptEnvironment, Get-ActionSequence, Invoke-ActionScriptThreading)
      but without shell, watchers or dispatcher. Dialog based elements (Draw GUI) still open their window.
      -OutFile: .json, .csv (semicolon, UTF-8 BOM), .xml (CliXML) or any other extension (text table).
      Exit code: 0 = ok, 1 = the element reported errors, 2 = not found / timeout.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $false)][string]$OutFile,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 600
    )

    Update-JsonIndex -JsonFilePath $Global:PowerControl.General.JsonFilePath -xmlFolderPath $Global:PowerControl.General.enginePath
    $Global:PowerControl.JsonCache = [System.IO.File]::ReadAllText($Global:PowerControl.General.JsonFilePath) | ConvertFrom-Json
    $Global:PowerControl.Settings = Get-PowerControlSettings

    $id = Resolve-PowerControlElementId -Name $Run
    if (-not $id) {
        Write-Warning "PowerControl: element '$Run' not found (ID or label). Try: -Run 'List all PCtrl Elements'"
        $script:HeadlessExitCode = 2
        return
    }
    $label = ($Global:PowerControl.JsonCache.PCtrlItems | Where-Object { $_.id -ceq $id } | Select-Object -First 1).Label
    Write-DebugLog -Message "Headless run: $label [$id] -> $(if ($OutFile) { $OutFile } else { 'pipeline' })" -Level 1 -LogFileName 'UI.log'

    $item = Initialize-ScriptEnvironment -ID $id
    Get-ActionSequence -ID $id | Invoke-ActionScriptThreading -HistoryItem $item
    $done = Wait-PowerControlHandle -HistoryItem $item -TimeoutMs ($TimeoutSeconds * 1000)
    $errors = @()
    if ($item.Thread.PowerShell) { $errors = @($item.Thread.PowerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) }
    $rows = @($item.Output | Where-Object { $null -ne $_ })
    Stop-PowerControlThreads -HistoryItem $item

    foreach ($message in $errors) { Write-Warning "${label}: $message" }
    if (-not $done) { Write-Warning "PowerControl: '$label' did not finish within $TimeoutSeconds s"; $script:HeadlessExitCode = 2; return }
    $script:HeadlessExitCode = if ($errors.Count -gt 0) { 1 } else { 0 }
    Write-DebugLog -Message "Headless run finished: $($rows.Count) row(s), $($errors.Count) error(s)" -Level 1 -LogFileName 'UI.log'

    if (-not $OutFile) { return $rows }
    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutFile))
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    switch ([System.IO.Path]::GetExtension($OutFile).ToLowerInvariant()) {
        '.json' { ConvertTo-Json -InputObject $rows -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding utf8 }
        '.csv'  { $rows | Export-Csv -LiteralPath $OutFile -Delimiter ';' -NoTypeInformation -Encoding utf8BOM }
        '.xml'  { $rows | Export-Clixml -LiteralPath $OutFile -Depth 4 }
        default { $rows | Format-Table -Property * -AutoSize -Wrap | Out-File -LiteralPath $OutFile -Width 4096 -Encoding utf8 }
    }
    "$($rows.Count) row(s) written to $OutFile"
}
