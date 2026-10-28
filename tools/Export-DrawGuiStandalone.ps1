<#
  .SYNOPSIS
  Generates tools\Test-DrawGUI.ps1 from the "Draw GUI" action in engine\main.xml.

  .DESCRIPTION
  tools\Test-DrawGUI.ps1 is the standalone playground for designing dialogs with the hashtable based
  GUI builder. It used to be a hand-maintained copy that drifted away from main.xml. This tool
  extracts the three actions the builder consists of (Convert-XAMLtoWindow, Show-WPFWindow,
  Draw GUI) from main.xml, adds minimal stand-ins for the engine environment and appends the
  example dialog. Edit main.xml, then re-run this script.

  .EXAMPLE
  pwsh -NoProfile -File .\tools\Export-DrawGuiStandalone.ps1
#>
[CmdletBinding()]
param(
    [string]$EnginePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'engine\main.xml'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Test-DrawGUI.ps1')
)

$ErrorActionPreference = 'Stop'

$xml = [System.Xml.XmlDocument]::new()
$xml.PreserveWhitespace = $true
$xml.Load($EnginePath)

function Get-ActionScript([string]$Id) {
    $node = $xml.SelectSingleNode("//PCtrl[@ID='$Id']")
    if ($null -eq $node) { throw "Action $Id not found in $EnginePath" }
    $node.Script.'#cdata-section'
}

$convertXaml = Get-ActionScript 'ConvertXamltowindow-f63b567e0235'
$showWindow  = Get-ActionScript 'ShowWpfwindow-46d45a0025184690a1'
$drawGui     = Get-ActionScript 'DrawGUI-e7670e8344194a828558f726'

$header = @'
<#
  tools\Test-DrawGUI.ps1 - standalone playground for the PowerControl dialog builder (Show-PCtrlGUI).

  GENERATED FILE. Source of truth is the "Draw GUI" action in engine\main.xml.
  Re-create this file with:  pwsh -NoProfile -File .\tools\Export-DrawGuiStandalone.ps1

  Run it directly to see the example dialog at the bottom; the collected values are printed afterwards.
  Verbose output (-Verbose) shows the builder's debug log lines.
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Windows.Forms, System.Security

# ---------------------------------------------------------------------------------------------
# Minimal stand-ins for the engine environment the builder expects at runtime
# ---------------------------------------------------------------------------------------------
$Global:PowerControl = [pscustomobject]@{
    # Theme: 'Light' / 'Dark' render the dialog with the WPF Fluent theme, 'Classic' keeps the default look
    General   = [pscustomobject]@{ CurrentPath = $PSScriptRoot; Version = 'standalone'; Theme = 'Light' }
    JsonCache = [pscustomobject]@{ PCtrlItems = @(); files = @() }
}
$script:PowerControlID = 'DrawGUI-standalone'
$script:SelectedEntries = $null
$Script:PowerControlItem_Output = @()
$Script:PowerControlItem_DisplayProperty = @()
$Script:PowerControlItem_ExcludeProperty = @()

function Write-DebugLog {
    param([string]$Message, [int]$Level = 1, [string]$LogFileName = '')
    if ($Level -le 1 -and $Message -match 'error|exception|not found|failed') { Write-Warning $Message }
    else { Write-Verbose "[$Level] $Message" }
}

'@

$example = @'

# ---------------------------------------------------------------------------------------------
# Example: edit the hashtable below and run the file. Every element type the builder knows is
# documented in the <description> of the "Draw GUI" action in engine\main.xml.
# ---------------------------------------------------------------------------------------------
$GUItable = @{
    'window' = @{
        'title' = 'add a new Host'
        'description' = 'Use the fields below to describe the Host.'
    }
    'dialog' = @{
        0 = @{
            'Label' = 'Label'
            'TextBox' = @{
                'Name' = 'Label'
                'focus' = $true
                'check' = { $sender.Text.Length -gt 0 }
            }
        }
        1 = @{
            'Label' = 'Hostname'
            'TextBox' = @{
                'Name' = 'Hostname'
            }
        }
        2 = @{
            'Label' = 'Protocol'
            'ComboBox' = @{
                'Name' = 'Protocol'
                'Text' = 'SSH2'
                'Elements' = @('SSH2', 'RDP')
            }
        }
        3 = @{
            'Label' = 'Category'
            'ComboBox' = @{
                'Name' = 'HW_Kategorie_PC'
                'Text' = 'None'
                'Elements' = @('None', 'Physisch', 'Virtualisiert')
            }
        }
        4 = @{
            'Label' = 'Icon'
            'OpenFile' = @{
                'Name' = 'Icon'
                'Filter' = 'Icons (*.ico;*.png)|*.ico;*.png'
                'InitialDirectory' = (Join-Path $PSScriptRoot 'icons')
            }
        }
        5 = @{
            'CheckBox' = @{
                'Name' = 'Favorite'
                'Text' = 'add to favorites'
                'IsChecked' = $true
            }
        }
        6 = @{
            'Label' = 'Comments'
            'TextBox' = @{
                'Name' = 'Comments'
                'MultiLine' = $true
            }
        }
    }
    'actionButtons' = @{
        0 = @{
            'Label' = '_Save'
            'Name' = 'Save'
            'isDefault' = $true
        }
    }
    'OnResult' = {
        # runs only when every 'check' passed and the dialog was confirmed
        Write-Host 'Dialog confirmed. Collected values:' -ForegroundColor Green
        $script:GUIResults.GetEnumerator() | Sort-Object Key | ForEach-Object {
            $value = if ($_.Value -is [System.Windows.Controls.ComboBoxItem]) { $_.Value.Content } else { $_.Value }
            Write-Host ("  {0,-18} {1}" -f $_.Key, $value)
        }
    }
}

Show-PCtrlGUI -GUItable $GUItable
'@

$content = $header +
    "# ---------------------------------------------------------------------------------------------`r`n# engine\main.xml : Convert-XAMLtoWindow`r`n# ---------------------------------------------------------------------------------------------`r`n" + $convertXaml.Trim() + "`r`n`r`n" +
    "# ---------------------------------------------------------------------------------------------`r`n# engine\main.xml : Show-WPFWindow`r`n# ---------------------------------------------------------------------------------------------`r`n" + $showWindow.Trim() + "`r`n`r`n" +
    "# ---------------------------------------------------------------------------------------------`r`n# engine\main.xml : Draw GUI`r`n# ---------------------------------------------------------------------------------------------`r`n" + $drawGui.Trim() + "`r`n" +
    $example

# functions in the engine are declared with the script: prefix, which is fine at script level
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error "Line $($_.Extent.StartLineNumber): $($_.Message)" }
    throw 'Generated script does not parse, tools\Test-DrawGUI.ps1 was not written.'
}

[System.IO.File]::WriteAllText($OutputPath, $content, [System.Text.UTF8Encoding]::new($true))
Write-Host "Written $OutputPath ($((($content -split "`n").Count)) lines) from $EnginePath"
