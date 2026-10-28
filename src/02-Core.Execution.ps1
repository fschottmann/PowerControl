# PowerControl - 02-Core.Execution.ps1
# script execution in runspaces, XML index, atomic XML save
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

#check PSCredential ans string output
function Invoke-ActionScript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [object]$Hashtable,

        [Parameter(Mandatory = $false)]
        [int]$DebugLevel = $script:DebugLevel,

        [Parameter(Mandatory = $false)]
        [string]$LogsPath = $script:LogsPath,

        [Parameter(Mandatory = $false)]
        [switch]$ReturnOutput = $script:ReturnOutput
    )

    begin {
        $returnVariable = $null
        Write-DebugLog 'Starting Invoke-ActionScript' -Level 1 -LogFileName 'ActionScript.log'
        
        $primitiveTypes = @('Boolean', 'Int32', 'Int64', 'Double', 'Decimal', 'DateTime', 'Guid')
        $excludedProperties = @('RunspaceId', 'PSShowComputerName', 'PSComputerName')

        $objectPattern = [regex]::new('Object|Collection|Array', [System.Text.RegularExpressions.RegexOptions]::Compiled)
    }

    process {
        $actionItems = switch ($Hashtable.GetType().Name) {
            'Hashtable' { $Hashtable.GetEnumerator() }
            'DictionaryEntry' { @($Hashtable) }
            default {
                Write-DebugLog 'Invalid input type. Expected Hashtable or DictionaryEntry.' -Level 1 -LogFileName 'ActionScript.log'
                Write-Error 'Invalid input type. Expected Hashtable or DictionaryEntry.'
                return
            }
        }      
        
        foreach ($HashItem in $actionItems) {
            Write-DebugLog "Processing action: $($HashItem.Value.ID)" -Level 2 -LogFileName 'ActionScript.log'

            # Execute PrevAction scripts
            if ($HashItem.Value.PrevAction) {
                Write-DebugLog "Executing PrevActions for $($HashItem.Value.ID)" -Level 3 -LogFileName 'ActionScript.log'
                $HashItem.Value.PrevAction.GetEnumerator() | 
                    Sort-Object { [int]$_.Value.Priority } -Descending | 
                    ForEach-Object { 
                        Write-DebugLog "Executing PrevAction: $($_.Key)" -Level 4 -LogFileName 'ActionScript.log'
                        Invoke-ActionScript -Hashtable $_ -DebugLevel $DebugLevel -LogsPath $LogsPath -ReturnOutput:$ReturnOutput
                    }
            }
            
            $script:PowerControlID = $HashItem.Value.ID
            
            # Execute main script
            $ScriptBlock = if ($HashItem.Value.ScriptBlock) {
                $hereStringCheck = Test-HereStringValidity -Script $HashItem.Value.ScriptBlock
                if ($hereStringCheck.IsValid) {
                    [ScriptBlock]::Create($HashItem.Value.ScriptBlock)
                } else {
                    Write-DebugLog "Invalid here-string in ScriptBlock for $($HashItem.Value.ID): $($hereStringCheck.ErrorMessage)" -Level 2 -LogFileName 'ActionScript.log'
                    [ScriptBlock]::Create('#Invalid here-string in ScriptBlock')
                }
            } else {
                Write-DebugLog "Empty ScriptBlock for $($HashItem.Value.ID)" -Level 3 -LogFileName 'ActionScript.log'
                [ScriptBlock]::Create('#Empty ScriptBlock')
            }
            
            if ($ScriptBlock.ToString() -match '^#(Invalid)') {
                Write-DebugLog "Skipping execution of invalid ScriptBlock for $($HashItem.Value.ID)" -Level 2 -LogFileName 'ActionScript.log'
            }
            else {
              Write-DebugLog "Executing main script for $($HashItem.Value.ID)" -Level 3 -LogFileName 'ActionScript.log'
              try {
                  $Output = & $ScriptBlock							
                  if ($Output -and $ReturnOutput) {
                      Write-DebugLog "Processing output for $($HashItem.Value.ID)" -Level 4 -LogFileName 'ActionScript.log'
                      
                      <#
                      todo:
                      $returnVariable = switch ($Output.GetType().Name) {
                          'String' { 
                              $Output 
                          }
                          { $primitiveTypes -contains $_ } {
                              $Output
                          }
                          'SecureString' {
                              '[SecureString]'
                          }
                          { $objectPattern.IsMatch($_) } { 
                              if ($null -eq $Output) {
                                  $null
                              }
                              elseif ($Output -is [System.Collections.IEnumerable] -and $Output -isnot [string]) {
                                  # Process collections in batches for better performance
                                  $batch = @()
                                  foreach ($item in $Output) {
                                      if ($null -ne $item) {
                                          $properties = Get-PropertySelection -InputObject $item
                                          $batch += $item | Select-Object -Property $properties
                                      }
                                      
                                      # Process in batches of 1000
                                      if ($batch.Count -ge 1000) {
                                          $batch
                                          $batch = @()
                                      }
                                  }
                                  # Output remaining items
                                  if ($batch.Count -gt 0) {
                                      $batch
                                  }
                              }
                              else {
                                  $properties = Get-PropertySelection -InputObject $Output
                                  $Output | Select-Object -Property $properties
                              }
                          }
                          'PSCredential' { 
                              [PSCustomObject]@{
                                  Username = $Output.Username
                                  Password = '[SecureString]'
                              }
                          }
                          default { 
                              Write-Warning "Unhandled type: $($Output.GetType().Name)"
                              $Output 
                          }
                      }
                      #>
                      
                      $returnVariable = switch ($Output.GetType().Name) {
                          'String' { $Output }
                          { $_ -match 'Object' } { $Output | Select-Object -Property * -ExcludeProperty RunspaceId, PSShowComputerName, PSComputerName }
                          'PSCredential' { [System.Management.Automation.PSCredential]::new($Output.Username, $Output.Password) }
                          default { $Output }
                      }
                      <#$returnVariable = switch ($Output.GetType().Name) {
    'String' { 
        $Output 
    }
    { $_ -in @('Boolean', 'Int32', 'Int64', 'Double', 'Decimal', 'DateTime', 'Guid') } {
        # Handle primitive types directly
        $Output
    }
    { $_ -match 'Object' -or $_ -match 'Collection' -or $_ -match 'Array' } { 
        if ($null -eq $Output) {
            $null # Handle null objects
        }
        elseif ($Output -is [System.Collections.IEnumerable] -and $Output -isnot [string]) {
            # Handle collections/arrays by processing each item
            $Output | ForEach-Object {
                $item = $_
                if ($null -ne $item) {
                    # Get default display properties if they exist
                    $defaultProperties = $item | Get-Member -MemberType Properties |
                        Where-Object { 
                            $_.Definition -notmatch '^System\.' -and 
                            $_.Name -notin @('RunspaceId', 'PSShowComputerName', 'PSComputerName')
                        }

                    # Check for DefaultDisplayPropertySet
                    if ($item.PSObject.TypeNames | Get-TypeData | Select-Object -ExpandProperty DefaultDisplayPropertySet) {
                        $propertiesToSelect = ($item.PSObject.TypeNames | Get-TypeData).DefaultDisplayPropertySet
                        $item | Select-Object -Property $propertiesToSelect
                    }
                    else {
                        $item | Select-Object -Property $defaultProperties.Name
                    }
                }
                else {
                    $null
                }
            }
        }
        else {
            # Single object processing
            $defaultProperties = $Output | Get-Member -MemberType Properties |
                Where-Object { 
                    $_.Definition -notmatch '^System\.' -and 
                    $_.Name -notin @('RunspaceId', 'PSShowComputerName', 'PSComputerName')
                }

            # Check for DefaultDisplayPropertySet
            if ($Output.PSObject.TypeNames | Get-TypeData | Select-Object -ExpandProperty DefaultDisplayPropertySet) {
                $propertiesToSelect = ($Output.PSObject.TypeNames | Get-TypeData).DefaultDisplayPropertySet
                $Output | Select-Object -Property $propertiesToSelect
            }
            else {
                $Output | Select-Object -Property $defaultProperties.Name
            }
        }
    }
    'PSCredential' { 
        [System.Management.Automation.PSCredential]::new($Output.Username, $Output.Password) 
    }
    default { 
        # Handle any unexpected types
        Write-Warning "Unhandled type: $($Output.GetType().Name)"
        $Output 
    }
}#>
<#
$returnVariable = switch ($Output.GetType().Name) {
    'String' { 
        $Output 
    }
    { $_ -match 'Object|FileInfo|DirectoryInfo' } { 
        if ($null -eq $Output) {
            $null
        }
        else {
            # Get the default display properties
            $defaultDisplayProperties = $Output | Format-Table | 
                Get-Member -MemberType NoteProperty | 
                Select-Object -ExpandProperty Name

            # Get all properties excluding unwanted ones
            $allProperties = $Output | Get-Member -MemberType Properties | 
                Where-Object { $_.Name -notin @('RunspaceId', 'PSShowComputerName', 'PSComputerName') } |
                Select-Object -ExpandProperty Name

            # Combine default and additional properties while maintaining order
            $propertiesToSelect = $defaultDisplayProperties + ($allProperties | Where-Object { $_ -notin $defaultDisplayProperties })

            $Output | Select-Object -Property $propertiesToSelect
        }
    }
    'PSCredential' { 
        [System.Management.Automation.PSCredential]::new($Output.Username, $Output.Password) 
    }
    default { 
        $Output 
    }
}#>

                  }
              }
              catch {
                  $errorMessage = @"
Error occurred: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
Script ID: $($HashItem.Value.ID)
Line Number: $($_.InvocationInfo.ScriptLineNumber)
Message: $($_.Exception.Message)
ScriptBlock: $ScriptBlock
For more details, see log files
"@
                  $errorMessage | Out-File -FilePath "$LogsPath\scripts.log" -Append
                  Write-DebugLog "Error in script execution for $($HashItem.Value.ID): Line $($_.InvocationInfo.ScriptLineNumber) - $($_.Exception.Message)" -Level 1 -LogFileName 'ActionScript.log'
                  # surface the failure in the error banner of the main window (queue is shared across runspaces)
                  try { Add-PowerControlNotification -Source "$($HashItem.Value.Label)" -Message "line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" } catch { }
                  if ($DebugLevel -ge 1) {
                      Write-Error $errorMessage
                  }
              }
              finally {
                  Write-DebugLog "Performing garbage collection after $($HashItem.Value.ID)" -Level 4 -LogFileName 'ActionScript.log'
                  [GC]::Collect()
                  [GC]::WaitForPendingFinalizers()
              }
            }
            
            # Execute NextAction scripts
            if ($HashItem.Value.NextAction) {
                Write-DebugLog "Executing NextActions for $($HashItem.Value.ID)" -Level 3 -LogFileName 'ActionScript.log'
                $HashItem.Value.NextAction.GetEnumerator() | 
                    Sort-Object { [int]$_.Value.Priority } -Descending | 
                    ForEach-Object { 
                        Write-DebugLog "Executing NextAction: $($_.Key)" -Level 4 -LogFileName 'ActionScript.log'
                        Invoke-ActionScript -Hashtable $_ -DebugLevel $DebugLevel -LogsPath $LogsPath -ReturnOutput:$ReturnOutput
                    }
            }
        }
    }

    end {
        Write-DebugLog 'Completed Invoke-ActionScript' -Level 1 -LogFileName 'ActionScript.log'
        if ($ReturnOutput) {
            $returnVariable
        }
        Remove-Variable -Name returnVariable -ErrorAction SilentlyContinue
    }
}

function Invoke-ActionScriptThreading {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [object]$Hashtable,
        [Parameter(Mandatory = $true)]
        [object]$HistoryItem
    )

    Write-DebugLog -Message "Starting Invoke-ActionScriptThreading" -Level 1 -LogFileName 'PowerControl.log'
    Write-DebugLog -Message "ActionID: $($HistoryItem.ID)" -Level 2 -LogFileName 'PowerControl.log'
    
    <#
      todo: $PowerControlItem.Thread.Runspace is sometimes empty this should be avoided
      check for ActionID:
    #>
    $PowerControlItem = @($PowerControl.History).Where({($_.ID -ceq $HistoryItem.id) -and ($_.Timestamp -eq $HistoryItem.timestamp) }, 'First')[0]
    Write-DebugLog -Message "Initialized PowerControlThreads for ActionID: $($HistoryItem.ID)" -Level 2 -LogFileName 'PowerControl.log'

    # a finished previous run of the same entry (Rerun, Repeat) is released here; waiting for the ThreadWatcher
    # (every 3.75 s) would let the references be overwritten and the old runspace linger until the GC finds it
    if ($null -ne $PowerControlItem -and $null -ne $PowerControlItem.Thread.PowerShell -and $PowerControlItem.Thread.PowerShell.InvocationStateInfo.State -ne 'Running') {
        try { $PowerControlItem.Thread.PowerShell.Dispose() } catch { }
        try { if ($null -ne $PowerControlItem.Thread.Runspace) { $PowerControlItem.Thread.Runspace.Dispose() } } catch { }
        $PowerControlItem.Thread.PowerShell = $null; $PowerControlItem.Thread.Runspace = $null; $PowerControlItem.Thread.Handle = $null
        Write-DebugLog -Message "Released the previous runspace of $($HistoryItem.ID) before the new run" -Level 3 -LogFileName 'PowerControl.log'
    }

    # CreateDefault2: only the core engine commands are loaded up front, every other module comes in on demand
    # (autoloading). Runspaces open faster and stay smaller than with CreateDefault, which imports everything.
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    Write-DebugLog -Message "Created initial session state" -Level 3 -LogFileName 'PowerControl.log'
		
    $variables = @(
        @{Name = "Hashtable"; Value = $Hashtable},
        @{Name = "PowerControl"; Value = $Global:PowerControl},
        @{Name = "OutputGrid"; Value = $OutputGrid}, # possible to remove, check engine
        @{Name = "PowerControl_HistoryItem"; Value = $PowerControlItem},
        @{Name = "DebugLevel"; Value = $script:DebugLevel},
        @{Name = "LogsPath"; Value = $script:LogsPath}
    )

    foreach ($var in $variables) {
        $initialSessionState.Variables.Add(
            (New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $var.Name, $var.Value, $null)
        )
        Write-DebugLog -Message "Added $($var.Name) to initial session state" -Level 6 -LogFileName 'PowerControl.log'
    }
    
    <#
        todo: function test is it Thread or not
        
        Thread: New-PCtrlButton, Initialize-ScriptEnvironment, Get-ActionSequence
        TreeviewEdit: Get-ElementByIdFromIndex
    #>
    $functions = @('Invoke-ActionScript', 'Write-DebugLog', 'Test-HereStringValidity', 'Stop-PowerControlThreads', 'Get-PropertySelection', 'Get-ElementByIdFromIndex','Get-ActionSequence','Invoke-ActionScriptThreading','Test-STAApartmentState',
                   'Save-PowerControlXml', 'Update-JsonIndex', 'Get-PowerControlGridData', 'Invoke-PowerControlExternal',
                   'Get-PowerControlSettings', 'Save-PowerControlSettings', 'Set-PowerControlTheme', 'Get-PowerControlEffectiveTheme', 'Add-PowerControlNotification',
                   'Invoke-PowerControlUICommand', 'Find-PowerControlInterpreter', 'Import-PowerControlBundle', 'Sync-PowerControlBundles', 'Write-PowerControlChangeLog')
    # icon helpers of the shell (Draw GUI icon picker renders the Lucide icons inline); absent in headless mode
    # the cache helpers must travel along: without them every conversion threw inside the runspace (195 icons,
    # ~400 ms per exception, the element editor took 80 s to open and showed no icons)
    foreach ($iconHelper in 'Get-PowerControlIconCachePath', 'Import-PowerControlIconCache', 'ConvertFrom-SvgIcon', 'New-PowerControlIconXaml') {
        if (Get-Command $iconHelper -CommandType Function -ErrorAction SilentlyContinue) { $functions += $iconHelper }
    }

    foreach ($func in $functions) {
        $definition = Get-Content Function:$func -ErrorAction Stop
        $initialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $func, $definition))
        Write-DebugLog -Message "Added $func function to initial session state" -Level 6 -LogFileName 'PowerControl.log'
    }

    $PowerControlItem.Thread.Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host, $initialSessionState)
    $PowerControlItem.Thread.Runspace.ApartmentState = (Test-STAApartmentState -ActionSequence $Hashtable) ? "STA" : "MTA"
    $PowerControlItem.Thread.Runspace.ThreadOptions = "Default"
    $PowerControlItem.Thread.Runspace.Open()
    Write-DebugLog -Message "Created and opened runspace for ActionID: $($HistoryItem.ID)" -Level 2 -LogFileName 'PowerControl.log'
		
    $Code = {
        $PowerControlItem = @($PowerControl.History).Where({($_.ID -ceq $PowerControl_HistoryItem.id) -and ($_.timestamp -eq $PowerControl_HistoryItem.timestamp) }, 'First')[0]
        
        $script:ReturnOutput = $true        
        $Script:PowerControlItem_Output = @()
        $Script:SelectedEntries = $PowerControlItem.SelectedEntries

        $TEMP_Output = Invoke-ActionScript -Hashtable $Hashtable 6>&1

        if($PowerControlItem_Output.count -lt 1) {
            $PowerControlItem_Output = $TEMP_Output
        }

        $PowerControlItem.Output = $Script:PowerControlItem_Output.where({$null -ne $_})
        $PowerControlItem.ExcludeProperty = $Script:PowerControlItem_ExcludeProperty.where({$null -ne $_})
        $PowerControlItem.DisplayProperty = $Script:PowerControlItem_DisplayProperty.where({$null -ne $_})
        
        $script:ReturnOutput = $false
    }

    $PowerControlItem.Thread.PowerShell = [PowerShell]::Create().AddScript($Code)
    Write-DebugLog -Message "Created PowerShell instance and added script for ActionID: $($HistoryItem.ID)" -Level 2 -LogFileName 'PowerControl.log'

    $PowerControlItem.Thread.PowerShell.Runspace = $PowerControlItem.Thread.Runspace
    $PowerControlItem.Thread.Handle = $PowerControlItem.Thread.PowerShell.BeginInvoke()    
    Write-DebugLog -Message "Started asynchronous execution for ActionID: $($HistoryItem.ID)" -Level 2 -LogFileName 'PowerControl.log'

    Write-DebugLog -Message "Completed Invoke-ActionScriptThreading" -Level 1 -LogFileName 'PowerControl.log'
}

function Get-PropertySelection {
    param([object]$InputObject)
    
    # Early return for null objects
    if ($null -eq $InputObject) { return $null }

    # Get properties once and cache
    $defaultProperties = $InputObject.PSObject.Properties |
        Where-Object { 
            $_.MemberType -eq 'Property' -and 
            $_.Name -notin $excludedProperties -and
            $_.TypeNameOfValue -notmatch '^System\.'
        }

    # Check for DefaultDisplayPropertySet once
    $typeData = $InputObject.PSObject.TypeNames | Get-TypeData | Select-Object -First 1
    if ($typeData.DefaultDisplayPropertySet) {
        return $typeData.DefaultDisplayPropertySet
    }

    # Process properties efficiently
    $properties = [System.Collections.ArrayList]::new()
    foreach ($prop in $defaultProperties) {
        if ($InputObject.$($prop.Name) -is [System.Security.SecureString]) {
            $properties.Add(@{
                Name = $prop.Name
                Expression = { '[SecureString]' }
            }) | Out-Null
        }
        else {
            $properties.Add($prop.Name) | Out-Null
        }
    }
    return $properties
}

#test function
function Test-XMLSignature {
    [CmdletBinding(DefaultParameterSetName='File')]
    Param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Data')]
        [ValidateNotNull()]
        [Xml]$XMLData,

        [Parameter(Mandatory = $true, ParameterSetName = 'File')]
        [ValidateNotNullOrEmpty()]
        [String]$XMLFile,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [String]$SerialNumber,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [String]$CertPath,

        [Parameter(Mandatory = $false)]
        [int]$DebugLevel = $script:DebugLevel,

        [Parameter(Mandatory = $false)]
        [string]$LogsPath = $script:LogsPath,

        [Parameter(Mandatory = $false)]
        [switch]$DisableExternalEntityProcessing
    )
    
    begin {
        Write-DebugLog 'Starting Test-XMLSignature' -Level 1 -LogFileName 'XMLSignature.log'

        try {
            # Use a secure XML reader settings
            $xmlReaderSettings = New-Object System.Xml.XmlReaderSettings
            $xmlReaderSettings.XmlResolver = $null # Prevent external entity resolution
            $xmlReaderSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit # Disable DTD processing

            if ($DisableExternalEntityProcessing) {
                $xmlReaderSettings.ProhibitDtd = $true # Additional protection against XXE
            }

            if ($PSCmdlet.ParameterSetName -eq 'File') {
                Write-DebugLog "Loading XML from file: $XMLFile" -Level 2 -LogFileName 'XMLSignature.log'
                if (Test-Path $XMLFile -ErrorAction Stop) {
                    # Use XmlReader with secure settings
                    $xmlReader = [System.Xml.XmlReader]::Create($XMLFile, $xmlReaderSettings)
                    $XMLData = New-Object System.Xml.XmlDocument
                    $XMLData.PreserveWhitespace = $true
                    $XMLData.Load($xmlReader)
                    $xmlReader.Close()
                    Write-DebugLog 'XML file loaded successfully' -Level 2 -LogFileName 'XMLSignature.log'
                }
                else {
                    throw "XML file not found: $XMLFile"
                }
            } else {
                # Re-parse the provided XML with secure settings
                $xmlStringReader = New-Object System.IO.StringReader($XMLData.OuterXml)
                $xmlReader = [System.Xml.XmlReader]::Create($xmlStringReader, $xmlReaderSettings)
                $secureXMLData = New-Object System.Xml.XmlDocument
                $secureXMLData.PreserveWhitespace = $true
                $secureXMLData.Load($xmlReader)
                $xmlReader.Close()
                $XMLData = $secureXMLData
            }

            Write-DebugLog 'Adding System.Security assembly' -Level 2 -LogFileName 'XMLSignature.log'
            Add-Type -AssemblyName System.Security -ErrorAction Stop

            $signedXml = New-Object System.Security.Cryptography.Xml.SignedXml($XMLData)
            $XMLSignature = $XMLData.GetElementsByTagName('Signature')
            Write-DebugLog "XML Signature elements found: $($XMLSignature.Count)" -Level 2 -LogFileName 'XMLSignature.log'

            Write-DebugLog 'Retrieving trusted public key' -Level 2 -LogFileName 'XMLSignature.log'
            if ([string]::IsNullOrEmpty($CertPath)) {
                $certStore = 'Cert:\LocalMachine\TrustedPublisher'
                Write-DebugLog "Using certificate store: $certStore" -Level 3 -LogFileName 'XMLSignature.log'
                $TrustedPublicKey = @(Get-ChildItem -Path $certStore).Where({$_.SerialNumber -eq $SerialNumber}, 'First')[0].PublicKey.Key
            }
            elseif (Test-Path $CertPath -PathType Leaf) {
                Write-DebugLog "Using certificate file: $CertPath" -Level 3 -LogFileName 'XMLSignature.log'
                # Validate certificate before using
                $cert = Get-PfxCertificate -FilePath $CertPath -ErrorAction Stop
                if (-not (Test-Certificate -Cert $cert -AllowUntrustedRoot)) {
                    throw "The certificate is not trusted or has expired."
                }
                $TrustedPublicKey = $cert.PublicKey.Key
            }
            else {
                $certStore = "Cert:$CertPath"
                Write-DebugLog "Using certificate store: $certStore" -Level 3 -LogFileName 'XMLSignature.log'
                $TrustedPublicKey = @(Get-ChildItem -Path $certStore).Where({$_.SerialNumber -eq $SerialNumber}, 'First')[0].PublicKey.Key
            }

            if ($null -eq $TrustedPublicKey) {
                throw 'Cannot find the specified public key. Please provide a valid file or a valid SerialNumber.'
            }
            Write-DebugLog 'Trusted public key retrieved successfully' -Level 2 -LogFileName 'XMLSignature.log'
        }
        catch {
            Write-DebugLog "Error in begin block: $_" -Level 1 -LogFileName 'XMLSignature.log'
            Write-Error -Message "Error in begin block: $_"
            return $false
        }
    }
    
    process {
        try {
            Write-DebugLog 'Starting signature verification process' -Level 2 -LogFileName 'XMLSignature.log'
            if ($null -ne $XMLSignature -and $null -ne $TrustedPublicKey) {
                $signedXml.LoadXml([System.Xml.XmlElement]($XMLSignature[0]))
                Write-DebugLog 'XML Signature loaded into SignedXml object' -Level 3 -LogFileName 'XMLSignature.log'
                
                # Verify the signature before checking it
                if (-not $signedXml.SignatureMethod) {
                    throw "Invalid signature: SignatureMethod is missing."
                }
                
                # Check for weak signature algorithms
                $weakAlgorithms = @('http://www.w3.org/2000/09/xmldsig#rsa-sha1', 'http://www.w3.org/2000/09/xmldsig#dsa-sha1')
                if ($signedXml.SignatureMethod -in $weakAlgorithms) {
                    Write-Warning "Weak signature algorithm detected: $($signedXml.SignatureMethod)"
                }
                
                $ReturnValue = $signedXml.CheckSignature($TrustedPublicKey)
                Write-DebugLog "Signature verification result: $ReturnValue" -Level 2 -LogFileName 'XMLSignature.log'
                
                # Additional checks after signature verification
                if ($ReturnValue) {
                  Write-DebugLog "Signature verified. Performing additional security checks." -Level 2 -LogFileName 'XMLSignature.log'
                  
                  # Check 1: Verify that the signature covers all important parts of the document
                  $signedInfo = $signedXml.SignedInfo
                  if ($signedInfo.References.Count -eq 0) {
                      Write-Warning "Security risk: The signature does not reference any parts of the document."
                      $ReturnValue = $false
                  }

                  # Check 2: Verify the signing time is within an acceptable range
                  $signingTime = $signedXml.GetIdElement("SigningTime")
                  if ($signingTime) {
                      $signingDateTime = [DateTime]::Parse($signingTime.InnerText)
                      $timeWindow = [TimeSpan]::FromDays(30)  # Adjust as needed
                      if (($signingDateTime -lt (Get-Date).Subtract($timeWindow)) -or ($signingDateTime -gt (Get-Date).Add($timeWindow))) {
                          Write-Warning "Security risk: Signing time is outside the acceptable range."
                          $ReturnValue = $false
                      }
                  } else {
                      Write-Warning "Security note: No signing time found in the signature."
                  }

                  # Check 3: Verify the certificate used for signing
                  $signingCert = $signedXml.GetKeyInfo().GetEnumerator() | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] } | Select-Object -First 1
                  if ($signingCert) {
                      if (-not (Test-Certificate -Cert $signingCert -AllowUntrustedRoot)) {
                          Write-Warning "Security risk: The signing certificate is not trusted or has expired."
                          $ReturnValue = $false
                      }
                      
                      # Check certificate revocation status
                      $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                      $chain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EntireChain
                      $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
                      $chain.ChainPolicy.UrlRetrievalTimeout = New-TimeSpan -Seconds 30
                      $chainIsValid = $chain.Build($signingCert)
                      
                      if (-not $chainIsValid) {
                          Write-Warning "Security risk: Certificate chain validation failed."
                          foreach ($status in $chain.ChainStatus) {
                              Write-Warning "Chain status: $($status.StatusInformation)"
                          }
                          $ReturnValue = $false
                      }
                  } else {
                      Write-Warning "Security risk: No signing certificate found in the signature."
                      $ReturnValue = $false
                  }

                  # Check 4: Verify that all expected elements are present and signed
                  $expectedElements = @('ImportantElement1', 'ImportantElement2')  # Adjust based on your XML structure
                  foreach ($elementName in $expectedElements) {
                      $element = $XMLData.GetElementsByTagName($elementName)
                      if ($element.Count -eq 0) {
                          Write-Warning "Security risk: Expected element '$elementName' is missing from the XML."
                          $ReturnValue = $false
                      } elseif (-not ($signedInfo.References | Where-Object { $_.Uri -eq "#$elementName" })) {
                          Write-Warning "Security risk: Expected element '$elementName' is not covered by the signature."
                          $ReturnValue = $false
                      }
                  }

                  # Check 5: Verify the signature algorithm
                  $signatureMethod = $signedXml.SignedInfo.SignatureMethod
                  $weakAlgorithms = @('http://www.w3.org/2000/09/xmldsig#rsa-sha1', 'http://www.w3.org/2000/09/xmldsig#dsa-sha1')
                  if ($signatureMethod -in $weakAlgorithms) {
                      Write-Warning "Security risk: Weak signature algorithm detected: $signatureMethod"
                      $ReturnValue = $false
                  }

                  if ($ReturnValue) {
                      Write-DebugLog "All additional security checks passed." -Level 2 -LogFileName 'XMLSignature.log'
                  } else {
                      Write-DebugLog "One or more additional security checks failed." -Level 2 -LogFileName 'XMLSignature.log'
                  }
                } else {
                    Write-DebugLog "Signature verification failed. Skipping additional checks." -Level 2 -LogFileName 'XMLSignature.log'
                }
            }
            else {
                throw 'XML Signature or Trusted Public Key is null.'
            }
        }
        catch {
            Write-DebugLog "Error in process block: $_" -Level 1 -LogFileName 'XMLSignature.log'
            Write-Error -Message "Error in process block: $_"
            return $false
        }
    }

    end {
        Write-DebugLog "Completed Test-XMLSignature. Returning result: $ReturnValue" -Level 1 -LogFileName 'XMLSignature.log'
        return $ReturnValue 
    }
}

#check strange missing or duplicate objects
function Update-JsonIndex {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$JsonFilePath,
        [Parameter(Mandatory = $true)][string]$xmlFolderPath
    )

    Write-DebugLog -Message "Starting Update-JsonIndex function" -Level 1 -LogFileName 'PowerControl.log'

    # Load existing JSON data or create new structure. The schema number forces a full rebuild when the
    # per-item fields change (HasScript / Toolbar were added with schema 2).
    $indexSchema = 3
    $jsonData = $null
    if (Test-Path $JsonFilePath) {
        Write-DebugLog -Message "Loading existing JSON data from $JsonFilePath" -Level 2 -LogFileName 'PowerControl.log'
        $jsonData = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        if ([int]$jsonData.schema -ne $indexSchema) {
            Write-DebugLog -Message "Index schema $($jsonData.schema) is outdated (expected $indexSchema), rebuilding the index" -Level 1 -LogFileName 'PowerControl.log'
            $jsonData = $null
        }
    }
    if ($null -eq $jsonData) {
        Write-DebugLog -Message "Creating new JSON data structure" -Level 2 -LogFileName 'PowerControl.log'
        $jsonData = [pscustomobject]@{ schema = $indexSchema; PCtrlItems = @(); files = @() }
    }

    # Get current XML files
    Write-DebugLog -Message "Getting XML files from $xmlFolderPath" -Level 2 -LogFileName 'PowerControl.log'
    $currentXmlFiles = [System.IO.Directory]::GetFiles($xmlFolderPath, "*.xml")

    # Check for deleted files
    Write-DebugLog -Message "Checking for deleted files" -Level 2 -LogFileName 'PowerControl.log'
    $currentXmlFileNames = $currentXmlFiles | Split-Path -Leaf
    $deletedFiles = $jsonData.files.where({ $_.name -notin $currentXmlFileNames })

    foreach ($deletedFile in $deletedFiles) {
        Write-DebugLog -Message "Removing entries for deleted file: $($deletedFile.name)" -Level 3 -LogFileName 'PowerControl.log'
        $jsonData.PCtrlItems = @($jsonData.PCtrlItems.where({ $_.file -ne $deletedFile.name }))
        $jsonData.files = @($jsonData.files.where({ $_.name -ne $deletedFile.name }))
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    foreach ($xmlFilePath in $currentXmlFiles) {
        $xmlFileName = [System.IO.Path]::GetFileName($xmlFilePath)
        Write-DebugLog -Message "Processing XML file: $xmlFilePath" -Level 2 -LogFileName 'PowerControl.log'
        
        # Calculate SHA256 hash of the XML file
        $xmlContent = [System.IO.File]::ReadAllBytes($xmlFilePath)
        $hash = [BitConverter]::ToString($sha256.ComputeHash($xmlContent)) -replace "-"

        # Check if file exists in JSON and if hash has changed
        $existingFile = $jsonData.files.where({ $_.name -eq $xmlFileName }, 'First')[0]
        if ($null -eq $existingFile -or $existingFile.sha256 -ne $hash) {
            Write-DebugLog -Message "Processing updated or new file: $xmlFileName" -Level 3 -LogFileName 'PowerControl.log'
            
            # Remove existing entries for this file
            Write-DebugLog -Message "Removing existing entries for file: $xmlFileName" -Level 4 -LogFileName 'PowerControl.log'
            $jsonData.PCtrlItems = @($jsonData.PCtrlItems.where({ $_.file -ne $xmlFileName }))
            $jsonData.files = @($jsonData.files.where({ $_.name -ne $xmlFileName }))

            # Load XML content
            Write-DebugLog -Message "Loading XML content from file: $xmlFilePath" -Level 4 -LogFileName 'PowerControl.log'
            $xmlData = [xml][System.IO.File]::ReadAllText($xmlFilePath)

            # Process each element type
            @("PCtrl").foreach({
                $elementType = $_
                Write-DebugLog -Message "Processing element type: $elementType" -Level 4 -LogFileName 'PowerControl.log'
                $xmlData.SelectNodes("//$elementType").foreach({
                    $element = $_
                    $id = $element.ID
                    if ($id) {
                        Write-DebugLog -Message "Processing $elementType with ID: $id" -Level 6 -LogFileName 'PowerControl.log'
                        $item = @{
                            id = $id
                            type = $element.type
                            file = $xmlFileName
                        }
                        
                        switch ($elementType) {
                            "PCtrl" {
                                # SelectSingleNode: with duplicated child nodes (two <DisplayCondition>) the property
                                # access would return arrays and break the index; the first node wins, the rest is logged
                                $scriptNode = $element.SelectSingleNode('Script')
                                $keyBindingNode = $element.SelectSingleNode('KeyBinding')
                                $displayConditionNode = $element.SelectSingleNode('DisplayCondition')
                                foreach ($childName in 'Script', 'KeyBinding', 'DisplayCondition') {
                                    if ($element.SelectNodes($childName).Count -gt 1) {
                                        Write-DebugLog -Message "Element $id in $xmlFileName has $($element.SelectNodes($childName).Count) <$childName> nodes, only the first one is used" -Level 1 -LogFileName 'PowerControl.log'
                                    }
                                }
                                # GetAttribute() returns "" for a missing attribute; the navigation decides between
                                # "categorised" and "orphan" with $null checks, so a missing attribute must stay $null
                                $attribute = { param($node, $name) if ($null -ne $node -and $node.HasAttribute($name)) { $node.GetAttribute($name) } else { $null } }
                                $conditionCode = $null
                                if ($null -ne $displayConditionNode) {
                                    $cdata = $displayConditionNode.ChildNodes | Where-Object { $_.NodeType -in 'CDATA', 'Text' } | Select-Object -First 1
                                    if ($null -ne $cdata -and -not [string]::IsNullOrWhiteSpace($cdata.Value)) { $conditionCode = $cdata.Value.Trim() -replace "`n", $null }
                                }
                                $item += @{
                                    Label = $element.Label
                                    icon = $element.Icon
                                    ToolTip = $element.ToolTip
                                    DisplayResults = $element.DisplayResults
                                    Children = $element.Children
                                    ApartmentState = $element.ApartmentState
                                    # a node without script is a pure container (group in the navigation): not clickable, not in the palette
                                    HasScript = [bool]($null -ne $scriptNode -and -not [string]::IsNullOrWhiteSpace($scriptNode.InnerText))
                                    # Toolbar="Jobs": Thread actions that get a button in the jobs bar
                                    Toolbar = $element.Toolbar
                                    KeyBinding = @{
                                        Key = & $attribute $keyBindingNode 'Key'
                                        Modifiers = & $attribute $keyBindingNode 'Modifiers'
                                    }
                                    DisplayCondition = @{
                                        Code = $conditionCode
                                        Categorie = & $attribute $displayConditionNode 'Categorie'
                                        SortOrder = & $attribute $displayConditionNode 'SortOrder'
                                    }
                                }
                                $jsonData.PCtrlItems += $item
                            }
                        }
                    }
                })
            })            
            # Add file information to JSON data structure
            Write-DebugLog -Message "Adding file information to JSON data structure" -Level 4 -LogFileName 'PowerControl.log'
            
            $seconds = Get-Date($($(Get-Item $xmlFilePath).LastWriteTime)) -uFormat "%s"
            $milliseconds = [math]::Round([int]$seconds * 1000)
            
            $jsonData.files += @{
                name = $xmlFileName
                path = $xmlFilePath
                sha256 = $hash
                certificate = $null
                lastwrite = $milliseconds
            }
        }
    }

    # duplicate IDs across all engine files: the lookup would silently take the first one
    $duplicateIds = @($jsonData.PCtrlItems | Group-Object -Property id | Where-Object { $_.Count -gt 1 })
    foreach ($duplicate in $duplicateIds) {
        $files = @($duplicate.Group | ForEach-Object { $_.file }) -join ', '
        Write-DebugLog -Message "Duplicate element ID $($duplicate.Name) in $files" -Level 1 -LogFileName 'PowerControl.log'
        if (Get-Command Add-PowerControlNotification -ErrorAction SilentlyContinue) { Add-PowerControlNotification -Source 'Engine' -Message "Doppelte ID $($duplicate.Name) in $files" -Severity Warning }
    }

    # Save the updated JSON data
    Write-DebugLog -Message "Saving updated JSON data to $JsonFilePath" -Level 2 -LogFileName 'PowerControl.log'
    $jsonData | ConvertTo-Json -Depth 10 | Set-Content -Path $JsonFilePath

    Write-DebugLog -Message "Update-JsonIndex function completed" -Level 1 -LogFileName 'PowerControl.log'
}

function Save-PowerControlXml {
    <#
      .SYNOPSIS
      Saves an engine XML document atomically.

      .DESCRIPTION
      Writes the document to a temporary file in the same folder and then moves it over the
      target in one step. The target is therefore never half written, and a scanner that holds
      the target file open (endpoint protection) only delays the final rename, which is retried.
      Any remaining failure is thrown, so it ends up in logs\scripts.log via the runspace error
      stream instead of disappearing silently.

      .PARAMETER RefreshIndex
      Rebuilds temp\index.json afterwards and reloads $PowerControl.JsonCache so later lookups
      (e.g. a second edit in the same session) see the new content.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$XmlDocument,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][int]$MaxRetries = 6,
        [Parameter(Mandatory = $false)][switch]$RefreshIndex
    )

    $targetPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($targetPath)
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $tempPath = [System.IO.Path]::Combine($directory, [System.IO.Path]::GetFileName($targetPath) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')

    # engine files: keep the previous version in memory for the change log (who changed which element when)
    $previousDocument = $null
    $enginePath = [string]$PowerControl.General.enginePath
    if ($enginePath -and $directory.TrimEnd('\') -ieq ([System.IO.Path]::GetFullPath($enginePath)).TrimEnd('\') -and (Test-Path -LiteralPath $targetPath)) {
        try { $previousDocument = [System.Xml.XmlDocument]::new(); $previousDocument.PreserveWhitespace = $true; $previousDocument.Load($targetPath) } catch { $previousDocument = $null }
    }

    Write-DebugLog -Message "Saving XML to $targetPath (via $([System.IO.Path]::GetFileName($tempPath)))" -Level 2 -LogFileName 'PowerControl.log'

    $attempt = 0
    while ($true) {
        try {
            $XmlDocument.Save($tempPath)
            [System.IO.File]::Move($tempPath, $targetPath, $true)
            break
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            $attempt++
            Write-DebugLog -Message "Save attempt $attempt for $targetPath failed: $($_.Exception.Message)" -Level 1 -LogFileName 'PowerControl.log'
            if ($attempt -ge $MaxRetries) {
                if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
                throw "Could not save '$targetPath' after $MaxRetries attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (150 * $attempt)
        }
    }

    Write-DebugLog -Message "Saved $targetPath" -Level 1 -LogFileName 'PowerControl.log'
    if ($null -ne $previousDocument) { Write-PowerControlChangeLog -OldDocument $previousDocument -NewDocument $XmlDocument -File ([System.IO.Path]::GetFileName($targetPath)) }

    if ($RefreshIndex) {
        Update-JsonIndex -JsonFilePath $PowerControl.General.JsonFilePath -xmlFolderPath $PowerControl.General.enginePath
        $PowerControl.JsonCache = [System.IO.File]::ReadAllText($PowerControl.General.JsonFilePath) | ConvertFrom-Json
        # the UI timer rebuilds menu bar, trees and context menus on its next tick
        $PowerControl.WatcherState.NavigationDirty = $true
        Write-DebugLog -Message "JSON index refreshed after saving $([System.IO.Path]::GetFileName($targetPath)), navigation refresh requested" -Level 2 -LogFileName 'PowerControl.log'
    }
}

function Write-PowerControlChangeLog {
    <#
      .SYNOPSIS
      Appends the element level differences between two versions of an engine file to ini\changes.json.
      Entries: Time, User, Machine, File, ID, Label, Change (added / removed / changed). Read by the
      "Recently changed" menu entry. The file keeps the last 2000 entries.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$OldDocument,
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$NewDocument,
        [Parameter(Mandatory = $true)][string]$File
    )
    try {
        $normalize = { param($node) ($node.OuterXml -replace '\s+', ' ').Trim() }
        $old = @{}; foreach ($node in @($OldDocument.SelectNodes('//PCtrl[@ID]'))) { $old[$node.GetAttribute('ID')] = $node }
        $new = @{}; foreach ($node in @($NewDocument.SelectNodes('//PCtrl[@ID]'))) { $new[$node.GetAttribute('ID')] = $node }
        $now = (Get-Date).ToString('s')
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($id in $new.Keys) {
            if (-not $old.ContainsKey($id)) { $entries.Add([pscustomobject]@{ Time = $now; User = $env:USERNAME; Machine = $env:COMPUTERNAME; File = $File; ID = $id; Label = $new[$id].GetAttribute('Label'); Change = 'added' }) }
            elseif ((& $normalize $old[$id]) -ne (& $normalize $new[$id])) { $entries.Add([pscustomobject]@{ Time = $now; User = $env:USERNAME; Machine = $env:COMPUTERNAME; File = $File; ID = $id; Label = $new[$id].GetAttribute('Label'); Change = 'changed' }) }
        }
        foreach ($id in $old.Keys) {
            if (-not $new.ContainsKey($id)) { $entries.Add([pscustomobject]@{ Time = $now; User = $env:USERNAME; Machine = $env:COMPUTERNAME; File = $File; ID = $id; Label = $old[$id].GetAttribute('Label'); Change = 'removed' }) }
        }
        if ($entries.Count -eq 0) { return }

        # previous version of changed/removed elements -> ini\history\<ID>\<stamp>.xml (last 20 per element), for "Show diff" and "Restore version"
        $historyRoot = [System.IO.Path]::Combine($PowerControl.General.CurrentPath, 'ini', 'history')
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        foreach ($entry in $entries) {
            if ($entry.Change -eq 'added') { continue }
            try {
                $folder = [System.IO.Path]::Combine($historyRoot, ($entry.ID -replace '[^A-Za-z0-9_.-]', '_'))
                if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($folder, "$stamp.xml"), $old[$entry.ID].OuterXml, [System.Text.UTF8Encoding]::new($false))
                $versions = @(Get-ChildItem -LiteralPath $folder -Filter '*.xml' -File | Sort-Object Name)
                if ($versions.Count -gt 20) { $versions[0..($versions.Count - 21)] | Remove-Item -Force -ErrorAction SilentlyContinue }
            }
            catch { Write-DebugLog -Message "History snapshot for $($entry.ID) failed: $_" -Level 1 -LogFileName 'PowerControl.log' }
        }

        $logPath = [System.IO.Path]::Combine($PowerControl.General.CurrentPath, 'ini', 'changes.json')
        $existing = @()
        if (Test-Path -LiteralPath $logPath) { try { $existing = @(Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json) } catch { $existing = @() } }
        $all = @($existing) + @($entries)
        if ($all.Count -gt 2000) { $all = $all[($all.Count - 2000)..($all.Count - 1)] }
        $directory = [System.IO.Path]::GetDirectoryName($logPath)
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json -InputObject @($all) -Depth 3), [System.Text.UTF8Encoding]::new($false))
        Write-DebugLog -Message "Change log: $($entries.Count) entry(ies) for $File" -Level 2 -LogFileName 'PowerControl.log'
    }
    catch { Write-DebugLog -Message "Change log failed: $_" -Level 1 -LogFileName 'PowerControl.log' }
}

function Import-PowerControlBundle {
    <#
      .SYNOPSIS
      Merges the PCtrl elements of a bundle (an engine XML written by "Export elements..." or any engine file)
      into an engine file. Used by the Import dialog and by the bundle subscriptions.

      .PARAMETER Replace
      Existing IDs are replaced (the old copy is removed from its file); without it they are skipped.

      .PARAMETER ReplaceOnlyIn
      With -Replace: only elements that currently live in this engine file are replaced, elements of
      other files (the user's own) are skipped. Subscriptions use their own target file here.

      .OUTPUTS
      One row per element: Label, ID, Result, File.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][string]$TargetName = 'Imported.xml',
        [Parameter(Mandatory = $false)][switch]$Replace,
        [Parameter(Mandatory = $false)][string]$ReplaceOnlyIn
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Bundle not found: $Path" }
    if (-not $TargetName) { $TargetName = 'Imported.xml' }
    if (-not $TargetName.EndsWith('.xml')) { $TargetName += '.xml' }
    $targetPath = Join-Path $PowerControl.General.enginePath $TargetName
    $rows = [System.Collections.Generic.List[object]]::new()

    $bundle = [System.Xml.XmlDocument]::new(); $bundle.PreserveWhitespace = $true; $bundle.Load($Path)
    $elements = @($bundle.SelectNodes('//PCtrl[@ID]'))
    if ($elements.Count -eq 0) { throw "The bundle contains no PCtrl elements: $Path" }

    $target = [System.Xml.XmlDocument]::new(); $target.PreserveWhitespace = $true
    if (Test-Path -LiteralPath $targetPath) { $target.Load($targetPath) }
    else { [void]$target.AppendChild($target.CreateXmlDeclaration('1.0', 'utf-8', $null)); [void]$target.AppendChild($target.CreateElement('Engine')) }
    $touched = @{}
    $known = @{}
    foreach ($item in $PowerControl.JsonCache.PCtrlItems) { $known[[string]$item.id] = [string]$item.file }
    $imported = 0

    foreach ($element in $elements) {
        $id = $element.GetAttribute('ID')
        $label = $element.GetAttribute('Label')
        $result = 'imported'
        if ($known.ContainsKey($id)) {
            $protected = $ReplaceOnlyIn -and ($known[$id] -ne $ReplaceOnlyIn)
            if (-not $Replace -or $protected) {
                $rows.Add([pscustomobject]@{ Label = $label; ID = $id; Result = $(if ($protected) { "skipped (own element in $($known[$id]))" } else { 'skipped (ID exists)' }); File = $known[$id] })
                continue
            }
            $oldPath = Join-Path $PowerControl.General.enginePath $known[$id]
            $oldDoc = if ($oldPath -eq $targetPath) { $target } elseif ($touched.ContainsKey($oldPath)) { $touched[$oldPath] } else { $d = [System.Xml.XmlDocument]::new(); $d.PreserveWhitespace = $true; $d.Load($oldPath); $touched[$oldPath] = $d; $d }
            $oldNode = $oldDoc.SelectSingleNode("//PCtrl[@ID='$($id.Replace("'", '&apos;'))']")
            $changes = @()
            if ($null -ne $oldNode) {
                foreach ($attribute in $element.Attributes) { if ($oldNode.GetAttribute($attribute.Name) -ne $attribute.Value) { $changes += $attribute.Name } }
                foreach ($childName in 'Script', 'DisplayCondition', 'KeyBinding', 'PrevAction', 'NextAction', 'description') {
                    $oldText = (@($oldNode.SelectNodes($childName) | ForEach-Object { $_.OuterXml }) -join '') -replace '\s+', ' '
                    $newText = (@($element.SelectNodes($childName) | ForEach-Object { $_.OuterXml }) -join '') -replace '\s+', ' '
                    if ($oldText -ne $newText) { $changes += $childName }
                }
                if ($changes.Count -eq 0) {
                    $rows.Add([pscustomobject]@{ Label = $label; ID = $id; Result = 'unchanged'; File = $known[$id] })
                    continue
                }
                [void]$oldNode.ParentNode.RemoveChild($oldNode)
            }
            $result = "replaced (was in $($known[$id]); changed: $($changes -join ', '))"
        }
        [void]$target.DocumentElement.AppendChild($target.CreateWhitespace("`n  "))
        [void]$target.DocumentElement.AppendChild($target.ImportNode($element, $true))
        $imported++
        $rows.Add([pscustomobject]@{ Label = $label; ID = $id; Result = $result; File = $TargetName })
    }
    [void]$target.DocumentElement.AppendChild($target.CreateWhitespace("`n"))

    foreach ($path in $touched.Keys) { Save-PowerControlXml -XmlDocument $touched[$path] -Path $path }
    if ($imported -gt 0 -or (Test-Path -LiteralPath $targetPath)) { Save-PowerControlXml -XmlDocument $target -Path $targetPath -RefreshIndex:($imported -gt 0 -or $touched.Count -gt 0) }
    else { $rows.Add([pscustomobject]@{ Label = '(bundle)'; ID = ''; Result = 'nothing imported, target file not created'; File = $TargetName }) }

    $allIds = @($PowerControl.JsonCache.PCtrlItems.id) + @($elements | ForEach-Object { $_.GetAttribute('ID') })
    foreach ($element in $elements) {
        foreach ($ref in @($element.SelectNodes('PrevAction/@ID | NextAction/@ID'))) {
            if ($allIds -notcontains $ref.Value) { $rows.Add([pscustomobject]@{ Label = $element.GetAttribute('Label'); ID = $element.GetAttribute('ID'); Result = "warning: reference $($ref.Value) is missing"; File = $TargetName }) }
        }
    }
    $rows.ToArray()
}

function Sync-PowerControlBundles {
    <#
      .SYNOPSIS
      Fetches the bundle sources of settings.json (local folders, direct .xml URLs, GitHub repositories or
      folders) and merges new or changed bundles into engine\Subscribed.xml.

      .DESCRIPTION
      Sources: "D:\share\bundles", "https://host/file.xml", "https://github.com/owner/repo",
      "https://github.com/owner/repo/tree/main/bundles" (GitHub contents API, public repositories or a
      token in $env:GITHUB_TOKEN). Every bundle is hashed; unchanged bundles are not imported again.
      Elements that already exist in another engine file (the user's own) are never replaced.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string[]]$Sources, [Parameter(Mandatory = $false)][switch]$Force)

    if (-not $Sources) { $Sources = @($PowerControl.Settings.BundleSources) }
    $Sources = @($Sources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($Sources.Count -eq 0) { $rows.Add([pscustomobject]@{ Source = ''; Bundle = ''; Element = ''; Result = 'no sources configured (View > Settings > Bundle sources)' }); return $rows.ToArray() }
    if ($null -eq $PowerControl.Settings.BundleState -or $PowerControl.Settings.BundleState -isnot [hashtable]) { $PowerControl.Settings.BundleState = @{} }
    $state = $PowerControl.Settings.BundleState
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $headers = @{ 'User-Agent' = 'PowerControl' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'PowerControl', 'bundles')
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    foreach ($source in $Sources) {
        $bundles = @()   # @{ Name; Bytes }
        try {
            if (Test-Path -LiteralPath $source -PathType Container) {
                $bundles = @(Get-ChildItem -LiteralPath $source -Filter '*.xml' -File | ForEach-Object { @{ Name = $_.Name; Bytes = [System.IO.File]::ReadAllBytes($_.FullName) } })
            }
            elseif ($source -match '^https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?(?:/tree/([^/]+)(?:/(.*))?)?/?$') {
                $owner, $repo, $branch, $folder = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
                $api = "https://api.github.com/repos/$owner/$repo/contents/$folder"
                if ($branch) { $api += "?ref=$branch" }
                $listing = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 60
                foreach ($entry in @($listing)) {
                    if ($entry.type -eq 'file' -and $entry.name -like '*.xml') {
                        $bundles += @{ Name = $entry.name; Bytes = (Invoke-WebRequest -Uri $entry.download_url -Headers $headers -TimeoutSec 60 -UseBasicParsing).Content }
                    }
                }
            }
            elseif ($source -match '^https?://') {
                $bundles = @(@{ Name = [System.IO.Path]::GetFileName(([uri]$source).AbsolutePath); Bytes = (Invoke-WebRequest -Uri $source -Headers $headers -TimeoutSec 60 -UseBasicParsing).Content })
            }
            else { throw 'neither a folder nor a URL' }
        }
        catch {
            $rows.Add([pscustomobject]@{ Source = $source; Bundle = ''; Element = ''; Result = "error: $($_.Exception.Message)" })
            Write-DebugLog -Message "Bundle source $source failed: $_" -Level 1 -LogFileName 'PowerControl.log'
            continue
        }
        if ($bundles.Count -eq 0) { $rows.Add([pscustomobject]@{ Source = $source; Bundle = ''; Element = ''; Result = 'no .xml bundles found' }); continue }

        foreach ($bundle in $bundles) {
            $bytes = if ($bundle.Bytes -is [string]) { [System.Text.Encoding]::UTF8.GetBytes($bundle.Bytes) } else { [byte[]]$bundle.Bytes }
            $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-'
            $key = "$source|$($bundle.Name)"
            if (-not $Force -and $state[$key] -eq $hash) { $rows.Add([pscustomobject]@{ Source = $source; Bundle = $bundle.Name; Element = ''; Result = 'unchanged since the last fetch' }); continue }
            $tempFile = [System.IO.Path]::Combine($tempDir, [guid]::NewGuid().ToString('N') + '.xml')
            try {
                [System.IO.File]::WriteAllBytes($tempFile, $bytes)
                foreach ($result in @(Import-PowerControlBundle -Path $tempFile -TargetName 'Subscribed.xml' -Replace -ReplaceOnlyIn 'Subscribed.xml')) {
                    $rows.Add([pscustomobject]@{ Source = $source; Bundle = $bundle.Name; Element = $result.Label; Result = $result.Result })
                }
                $state[$key] = $hash
            }
            catch { $rows.Add([pscustomobject]@{ Source = $source; Bundle = $bundle.Name; Element = ''; Result = "error: $($_.Exception.Message)" }) }
            finally { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
    Save-PowerControlSettings
    $changed = @($rows | Where-Object { $_.Result -like 'imported*' -or $_.Result -like 'replaced*' }).Count
    if ($changed -gt 0) { Add-PowerControlNotification -Source 'Bundles' -Message "$changed element(s) taken over from bundle subscriptions (engine\Subscribed.xml)" -Severity Info }
    Write-DebugLog -Message "Bundle sync: $($Sources.Count) source(s), $changed element(s) imported or replaced" -Level 1 -LogFileName 'PowerControl.log'
    $rows.ToArray()
}

