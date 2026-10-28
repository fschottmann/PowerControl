# PowerControl - 01-Core.Engine.ps1
# logging, index lookup, action sequence resolution, here-string check
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

#notopti
function Write-DebugLog {
    [CmdletBinding()]
    param(
        [string]$Message,
        [int]$Level,
        [int]$DebugLevel = $script:DebugLevel,
        [string]$LogsPath = $script:LogsPath,
        [string]$LogFileName = 'Debug.log',
        [int]$MaxRetries = 5,
        [int]$InitialBackoffMs = 10
    )

    if ($DebugLevel -ge $Level) {
        $logMessage = '{0:yyyy-MM-dd HH:mm:ss.fff} - {1}' -f [DateTime]::Now, $Message
        $fullPath = [System.IO.Path]::Combine($LogsPath, $LogFileName)

        # A named mutex serialises writers across runspaces and processes without leaving
        # lock files behind. An orphaned mutex is released by the OS when its owner dies,
        # so a crashed process can no longer stall every later log call.
        # (string hash codes are randomised per process in .NET, so derive the name from the path itself)
        $mutexName = 'Local\PowerControlLog_' + ($fullPath.ToLowerInvariant() -replace '[\\/:]', '_')
        $mutex = $null
        $acquired = $false

        try {
            $mutex = [System.Threading.Mutex]::new($false, $mutexName)
            try {
                $acquired = $mutex.WaitOne(250)
            }
            catch [System.Threading.AbandonedMutexException] {
                # previous owner died while holding it; we now own it
                $acquired = $true
            }

            $retryCount = 0
            while ($true) {
                try {
                    $stream = [System.IO.FileStream]::new($fullPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                    try {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$logMessage`r`n")
                        $stream.Write($bytes, 0, $bytes.Length)
                    }
                    finally {
                        $stream.Dispose()
                    }
                    break
                }
                catch {
                    $retryCount++
                    if ($retryCount -ge $MaxRetries) {
                        Write-Warning "Failed to write to log file after $MaxRetries attempts: $_"
                        break
                    }
                    Start-Sleep -Milliseconds ([Math]::Min($InitialBackoffMs * $retryCount, 100))
                }
            }
        }
        finally {
            if ($null -ne $mutex) {
                if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
                $mutex.Dispose()
            }
        }

        Write-Verbose $logMessage
    }
}

function Get-ElementByIdFromIndex {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$id
    )

    Write-DebugLog -Message "Starting Get-ElementByIdFromIndex function" -Level 1 -LogFileName 'ActionScript.log'

    # Find the entry with the specified ID
    Write-DebugLog -Message "Searching for entry with ID: $id in PCtrlItems" -Level 2 -LogFileName 'ActionScript.log'
    
    $entry = $PowerControl.JsonCache.PCtrlItems.where({$_.id -eq $id}, 'First')[0]
    
    if ($null -eq $entry) {
        Write-DebugLog -Message "ID not found in the index" -Level 1 -LogFileName 'ActionScript.log'
        Write-Warning "ID not found in the index."
        return $null
    }

    # Get the relevant XML file path
    Write-DebugLog -Message "Getting XML file path for entry" -Level 2 -LogFileName 'ActionScript.log'
    $xmlFilePath = $PowerControl.JsonCache.files.where({$_.name -eq $entry.file}, 'First')[0].path
    Write-DebugLog -Message "XML file path: $xmlFilePath" -Level 3 -LogFileName 'ActionScript.log'

    # Load the XML file and select the element via XPath. Unlike the former regex approach this
    # does not depend on attribute order or on the exact casing of the type attribute value.
    Write-DebugLog -Message "Loading XML file and selecting element via XPath" -Level 2 -LogFileName 'ActionScript.log'
    try {
        $xmlDoc = [System.Xml.XmlDocument]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.Load($xmlFilePath)
    }
    catch {
        Write-DebugLog -Message "Failed to load XML file '$xmlFilePath': $($_.Exception.Message)" -Level 1 -LogFileName 'ActionScript.log'
        Write-Warning "Failed to load XML file '$xmlFilePath': $($_.Exception.Message)"
        return $null
    }

    $escapedId = $id.Replace("'", "&apos;")
    $node = $xmlDoc.SelectSingleNode("//PCtrl[@ID='$escapedId']")

    if ($null -ne $node) {
        Write-DebugLog -Message "Element found successfully" -Level 1 -LogFileName 'ActionScript.log'
        return [xml]$node.OuterXml
    } else {
        Write-DebugLog -Message "Element not found in XML file" -Level 1 -LogFileName 'ActionScript.log'
        return $null
    }
}

function Test-STAApartmentState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$ActionSequence
    )

    $stack = New-Object System.Collections.Stack
    $stack.Push($ActionSequence)

    while ($stack.Count -gt 0) {
        $currentNode = $stack.Pop()

        foreach ($item in $currentNode.GetEnumerator()) {
            if ($item.Value -is [hashtable]) {
                if ($item.Value.ContainsKey('ApartmentState') -and $item.Value.ApartmentState -eq 'STA') {
                    return $true
                }
                if ($item.Value.ContainsKey('PrevAction')) {
                    $stack.Push($item.Value.PrevAction)
                }
                if ($item.Value.ContainsKey('NextAction')) {
                    $stack.Push($item.Value.NextAction)
                }
                $stack.Push($item.Value)
            }
        }
    }

    return $false
}

#check prev and next
function Get-ActionSequence {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string[]]$ID,

        # IDs already on the current resolution path. Protects against PrevAction/NextAction
        # cycles in the XML which previously ended in infinite recursion.
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.HashSet[string]]$Visited = [System.Collections.Generic.HashSet[string]]::new()
    )

    begin {
        Write-DebugLog "Starting Get-ActionSequence for IDs: $($ID -join ', ')" -Level 1 -LogFileName 'ActionSequence.log'
    }

    process {
        $hashtable = @{}

        Write-DebugLog "Processing elements based on PCtrlItems" -Level 2 -LogFileName 'ActionSequence.log'

        foreach ($elementId in $ID) {
            if (-not $Visited.Add($elementId)) {
                Write-DebugLog "Cycle detected: ID $elementId is already part of the action sequence, skipping" -Level 1 -LogFileName 'ActionSequence.log'
                Write-Warning "Action sequence cycle detected at ID '$elementId'. Check PrevAction/NextAction references in the engine XML."
                continue
            }

            $XMLElement = Get-ElementByIdFromIndex -id $elementId
            
            if ($null -eq $XMLElement) {
                Write-DebugLog "No element found for ID: $elementId" -Level 1 -LogFileName 'ActionSequence.log'
                continue
            }

            $docElement = $XMLElement.DocumentElement
            Write-DebugLog "Processing XMLElement with ID: $($docElement.ID)" -Level 2 -LogFileName 'ActionSequence.log'

            $hashtable[$docElement.ID] = @{
                'ID' = $docElement.ID
                'Label' = $docElement.Label
                'ApartmentState' = $docElement.ApartmentState
                'PrevAction' = @{}
                'NextAction' = @{}
                'ScriptBlock' = $docElement.Script.'#cdata-section'
            }

            # Process PrevAction
            $prevActionNodes = $docElement.SelectNodes('PrevAction')
            if ($prevActionNodes.count -gt 0) {
                Write-DebugLog "Processing PrevActions for ID: $($docElement.ID)" -Level 3 -LogFileName 'ActionSequence.log'
                foreach ($node in $prevActionNodes) {
                    $hashtable[$docElement.ID]['PrevAction'][$node.ID] = @{
                        'ID' = $node.ID
                        'Priority' = [int]$node.Priority
                    }
                }

                Write-DebugLog "Recursively processing PrevActions: $($prevActionNodes.id -join ', ')" -Level 3 -LogFileName 'ActionSequence.log'
                $recursivePrev = Get-ActionSequence -ID $prevActionNodes.id -Visited $Visited
                foreach ($item in $recursivePrev.Keys) {
                    foreach ($key in $recursivePrev[$item].keys) {
                        $hashtable[$docElement.ID]['PrevAction'][$item][$key] = $recursivePrev[$item][$key] 
                    }
                }
            }

            # Process NextAction
            $nextActionNodes = $docElement.SelectNodes('NextAction')
            if ($nextActionNodes.count -gt 0) {
                Write-DebugLog "Processing NextActions for ID: $($docElement.ID)" -Level 3 -LogFileName 'ActionSequence.log'
                foreach ($node in $nextActionNodes) {
                    $hashtable[$docElement.ID]['NextAction'][$node.ID] = @{
                        'ID' = $node.ID
                        'Priority' = [int]$node.Priority
                    }
                }

                Write-DebugLog "Recursively processing NextActions: $($nextActionNodes.id -join ', ')" -Level 3 -LogFileName 'ActionSequence.log'
                $recursiveNext = Get-ActionSequence -ID $nextActionNodes.id -Visited $Visited
                foreach ($item in $recursiveNext.Keys) {
                    foreach ($key in $recursiveNext[$item].keys) {
                        $hashtable[$docElement.ID]['NextAction'][$item][$key] = $recursiveNext[$item][$key] 
                    }
                }
            }
        }
    }

    end {
        Write-DebugLog "Completed Get-ActionSequence. Returning hashtable with $($hashtable.Count) items." -Level 1 -LogFileName 'ActionSequence.log'
        return $hashtable
    }
}

function Test-HereStringValidity {
    <#
      .SYNOPSIS
      Validates an action script before it is turned into a ScriptBlock.

      .DESCRIPTION
      Uses the real PowerShell parser instead of a line-based heuristic. The former regex
      treated every '@"' or "@'" inside a line (e.g. in strings or comments) as a here-string
      opener and then silently skipped perfectly valid scripts. The parser reports indented
      here-string terminators, unclosed here-strings and every other syntax error exactly.
    #>
    param([string]$Script)

    if ([string]::IsNullOrWhiteSpace($Script)) {
        return @{ IsValid = $true; ErrorMessage = $null }
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)

    if ($errors.Count -gt 0) {
        $messages = $errors | ForEach-Object {
            "Line $($_.Extent.StartLineNumber), Col $($_.Extent.StartColumnNumber): $($_.Message)"
        }
        return @{
            IsValid = $false
            ErrorMessage = ($messages -join '; ')
        }
    }

    return @{
        IsValid = $true
        ErrorMessage = $null
    }
}

