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
# ---------------------------------------------------------------------------------------------
# engine\main.xml : Convert-XAMLtoWindow
# ---------------------------------------------------------------------------------------------
function script:Convert-XAMLtoWindow {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
                [ValidateNotNullOrEmpty()]
                [string] $XAML
            )

            process {
                try {
                    Add-Type -AssemblyName PresentationFramework
                    $reader = [XML.XMLReader]::Create([IO.StringReader]$XAML)
                    $result = [Windows.Markup.XAMLReader]::Load($reader)
                }
                catch {
                    Write-Error "Failed to parse XAML: $_"
                    return
                }
                finally {
                    $reader.Close()
                }

                $reader = [XML.XMLReader]::Create([IO.StringReader]$XAML)
                try {
                    while ($reader.Read()) {
                        $name = $reader.GetAttribute('Name') ?? $reader.GetAttribute('x:Name')
                        if ($name) {
                            $element = $result.FindName($name)
                            if ($element) {
                                $result.PSObject.Properties.Add([PSNoteProperty]::new($name, $element))
                            }
                        }
                    }
                }
                catch {
                    Write-Error "Error processing XAML elements: $_"
                }
                finally {
                    $reader.Close()
                }

                $result
            }
        }

# ---------------------------------------------------------------------------------------------
# engine\main.xml : Show-WPFWindow
# ---------------------------------------------------------------------------------------------
function script:Show-WPFWindow {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [ValidateNotNull()]
                [Windows.Window]$Window
            )

            # registered dialogs are closed by the main window on shutdown, otherwise this runspace could never end
            # direct assignment on purpose: inside an if-expression an (empty) list would be enumerated and become $null
            $openDialogs = $null
            if ($null -ne $PowerControl -and $null -ne $PowerControl.UI) { $openDialogs = $PowerControl.UI.OpenDialogs }
            try {
                if ($null -ne $openDialogs) { [void]$openDialogs.Add($Window) }
                if (Get-Command Write-DebugLog -ErrorAction SilentlyContinue) { Write-DebugLog -Message "Show-WPFWindow: '$($Window.Title)' registered: $($null -ne $openDialogs) (open dialogs: $(if ($null -ne $openDialogs) { $openDialogs.Count } else { 'n/a' }))" -Level 2 -LogFileName 'UI.log' }
                $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
                $dispatcherFrame = [System.Windows.Threading.DispatcherFrame]::new()
                $dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Normal, [Action]{
                    $Window.ShowDialog()
                    $dispatcherFrame.Continue = $false
                })
                [System.Windows.Threading.Dispatcher]::PushFrame($dispatcherFrame)
            }
            catch {
                Write-Error "Error showing WPF window: $_"
            }
            finally {
                if ($null -ne $openDialogs) { $openDialogs.Remove($Window) }
            }
        }

# ---------------------------------------------------------------------------------------------
# engine\main.xml : Draw GUI
# ---------------------------------------------------------------------------------------------
$script:DrawGUIID = $script:PowerControlID

function script:Add-WPFElement {
    param (
        [System.Text.StringBuilder]$xamlBuilder,
        [hashtable]$element,
        [int]$depth = 0,
        [int]$row = 0,
        [int]$column = 1
    )
    
    $indent = "    " * $depth
    
    $controlName = ''
    
    Write-DebugLog -Message "Processing element: $($element.Keys | Where-Object { $_ -ne 'Label' } | Select-Object -First 1)" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
    
    switch ($element.Keys | Where-Object { $_ -ne 'Label' } | Select-Object -First 1) {
        'GroupBox' {
            Write-DebugLog -Message "Adding GroupBox: $($element.GroupBox.Header)" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
            
            $xamlBuilder.Append("`n$indent<GroupBox Header=`"$($element.GroupBox.Header)`" Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            $xamlBuilder.Append("`n$indent    <StackPanel>") | Out-Null

            foreach ($nestedElement in $element.GroupBox.Elements) {
                if ($nestedElement.Label) {
                    $xamlBuilder.Append("`n$indent        <TextBlock Text=`"$($nestedElement.Label)`" Margin=`"5,5,5,0`"/>") | Out-Null
                }
                Add-WPFElement -xamlBuilder $xamlBuilder -element $nestedElement -depth ($depth + 2)
            }

            $xamlBuilder.Append("`n$indent    </StackPanel>") | Out-Null
            $xamlBuilder.Append("`n$indent</GroupBox>") | Out-Null
        }
        
        'TextBox' {
            $controlName = "$($element.TextBox.Name)_$script:controlCounter"
            $script:controlCounter++

            # Multi-line boxes used to sit inside a ScrollViewer that carried no Grid.Row/Grid.Column, so the
            # wrapper landed in row 0 / column 0 and covered the first label. The TextBox scrolls on its own now.
            $xamlBuilder.Append("`n$indent<TextBox Name=`"$controlName`" ") | Out-Null
            if ($element.TextBox.IsEnabled -eq $false) {
                $xamlBuilder.Append('IsEnabled="false" ') | Out-Null
            }
            # read-only (unlike disabled) keeps the text selectable, e.g. to copy an element ID
            if ($element.TextBox.IsReadOnly -eq $true) {
                $xamlBuilder.Append('IsReadOnly="True" ') | Out-Null
            }
            if ($element.TextBox.Width) {
                $xamlBuilder.Append("Width=`"$($element.TextBox.Width)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Width=`"Auto`" ") | Out-Null
            }
            
            if ($element.TextBox.Height) {
                $xamlBuilder.Append("Height=`"$($element.TextBox.Height)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Height=`"Auto`" ") | Out-Null
            }
            if ($element.TextBox.MultiLine -eq $true) {
                $xamlBuilder.Append('AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" MaxHeight="300" ') | Out-Null
                if (-not $element.TextBox.Height) { $xamlBuilder.Append('MinHeight="90" ') | Out-Null }
                if (-not $element.TextBox.Width) { $xamlBuilder.Append('MinWidth="320" ') | Out-Null }
                $xamlBuilder.Append('FontFamily="Consolas" ') | Out-Null
            }
            if ($element.TextBox.ToolTip) {
                $xamlBuilder.Append("ToolTip=`"$($element.TextBox.ToolTip.Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;'))`" ") | Out-Null
            }
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            $xamlBuilder.Append("</TextBox>") | Out-Null

            Write-DebugLog -Message "Adding TextBox: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'TextBlock' {
            $controlName = "$($element.TextBlock.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<TextBlock Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Text=`"$($element.TextBlock.Text)`" ") | Out-Null
            if ($element.TextBlock.FontSize) {
                $xamlBuilder.Append("FontSize=`"$($element.TextBlock.FontSize)`" ") | Out-Null
            }
            if ($element.TextBlock.FontWeight) {
                $xamlBuilder.Append("FontWeight=`"$($element.TextBlock.FontWeight)`" ") | Out-Null
            }
            if ($element.TextBlock.Foreground) {
                $xamlBuilder.Append("Foreground=`"$($element.TextBlock.Foreground)`" ") | Out-Null
            }
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added TextBlock: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'CodeEditor' { 
            if(Test-Path $($Global:PowerControl.General.CurrentPath  + '\dll\ICSharpCode.AvalonEdit.dll')) {
                $controlName = "$($element.CodeEditor.Name)_$script:controlCounter"
                $script:controlCounter++
               
                # the editor may take about half of the working area, so the fields below it stay on screen
                $editorMaxHeight = if ($script:DrawGuiMaxEditorHeight -gt 0) { $script:DrawGuiMaxEditorHeight } else { 800 }
                $xamlBuilder.Append("`n$indent<ScrollViewer VerticalScrollBarVisibility=`"Auto`" HorizontalScrollBarVisibility=`"Auto`" MaxHeight=`"$editorMaxHeight`" MaxWidth=`"2000`" Grid.Row=`"$row`" Grid.Column=`"$column`">") | Out-Null
                $xamlBuilder.Append("`n$indent<avalon:TextEditor Name=`"$controlName`" ") | Out-Null
                if ($element.CodeEditor.Syntax) {
                    $xamlBuilder.Append("SyntaxHighlighting=`"$($element.CodeEditor.Syntax)`" ") | Out-Null
                }
                else {
                    $xamlBuilder.Append("SyntaxHighlighting=`"PowerShell`" ") | Out-Null
                }
                
                $xamlBuilder.Append("ShowLineNumbers=`"True`" ") | Out-Null
                if ($element.CodeEditor.ToolTip) {
                    $xamlBuilder.Append("ToolTip=`"$($element.CodeEditor.ToolTip.Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;'))`" ") | Out-Null
                }

                if ($element.CodeEditor.MinWidth) {
                    $xamlBuilder.Append("MinWidth=`"$($element.CodeEditor.MinWidth)`" ") | Out-Null
                }
                else {
                    $xamlBuilder.Append("MinWidth=`"500`" ") | Out-Null
                }
                
                if ($element.CodeEditor.MinHeight) {
                    $xamlBuilder.Append("MinHeight=`"$($element.CodeEditor.MinHeight)`" ") | Out-Null
                }
                else {
                    $xamlBuilder.Append("MinHeight=`"250`" ") | Out-Null
                }
                
                $xamlBuilder.Append("HorizontalScrollBarVisibility=`"Auto`" ") | Out-Null
                $xamlBuilder.Append("VerticalScrollBarVisibility=`"Auto`" ") | Out-Null
                $xamlBuilder.Append("FontFamily=`"Consolas`" ") | Out-Null
                $xamlBuilder.Append("FontSize=`"14`" ") | Out-Null
                # AvalonEdit has no Fluent template: colors come from the dialog resources set in Show-WPFWindow (light / dark)
                $xamlBuilder.Append("Background=`"{DynamicResource PowerControlEditorBackgroundBrush}`" Foreground=`"{DynamicResource PowerControlEditorForegroundBrush}`" LineNumbersForeground=`"{DynamicResource PowerControlEditorForegroundBrush}`" ") | Out-Null
                #$xamlBuilder.Append("PreviewMouseWheel=`"TextEditor_PreviewMouseWheel`" ") | Out-Null
                $xamlBuilder.Append("/>") | Out-Null
                $xamlBuilder.Append("`n$indent</ScrollViewer>") | Out-Null
                Write-DebugLog -Message "Added CodeEditor: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
            }
        }
        
        'PasswordBox' {
            $controlName = "$($element.PasswordBox.Name)_$script:controlCounter"
            $script:controlCounter++
            $passwordToolTip = if ($element.PasswordBox.ToolTip) { "ToolTip=`"$($element.PasswordBox.ToolTip.Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;'))`" " } else { '' }
            $xamlBuilder.Append("`n$indent<PasswordBox Name=`"$controlName`" ${passwordToolTip}Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added PasswordBox: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'CheckBox' {
            $controlName = "$($element.CheckBox.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<CheckBox Name=`"$controlName`" Content=`"$($element.CheckBox.Text)`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" ") | Out-Null
            if ($element.CheckBox.IsChecked -eq $true) {
                $xamlBuilder.Append('IsChecked="True" ') | Out-Null
            }
            if ($element.CheckBox.ToolTip) {
                $xamlBuilder.Append("ToolTip=`"$($element.CheckBox.ToolTip.Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;'))`" ") | Out-Null
            }
            $xamlBuilder.Append('Margin="5"/>') | Out-Null
            
            Write-DebugLog -Message "Added CheckBox: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'ComboBox' {
            $controlName = "$($element.ComboBox.Name)_$script:controlCounter"
            $script:controlCounter++
            # IconPreview: every entry is an icon path relative to icons\ and is shown with the rendered icon;
            # the value travels in the item's Tag (Get-ControlValues hands it back as .Content like a plain entry).
            # A preview box right of the ComboBox follows the typed or selected value (Add-ComboBoxIconPreview).
            $iconPreview = $element.ComboBox.IconPreview -eq $true -and (Get-Command New-PowerControlIconXaml -ErrorAction SilentlyContinue)
            if ($iconPreview) {
                $xamlBuilder.Append("`n$indent<DockPanel LastChildFill=`"True`" Grid.Row=`"$row`" Grid.Column=`"$column`"><Border Name=`"${controlName}_Preview`" DockPanel.Dock=`"Left`" Width=`"28`" Height=`"28`" Margin=`"5,0,0,0`" VerticalAlignment=`"Center`" ToolTip=`"Preview of the selected icon`"/>") | Out-Null
            }
            $xamlBuilder.Append("`n$indent<ComboBox Name=`"$controlName`" ") | Out-Null
            if ($element.ComboBox.IsEditable -eq $true) {
                $xamlBuilder.Append('IsEditable="True" ') | Out-Null
            }
            if ($element.ComboBox.Width) {
                $xamlBuilder.Append("Width=`"$($element.ComboBox.Width)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Width=`"Auto`" ") | Out-Null
            }
            
            if ($element.ComboBox.Height) {
                $xamlBuilder.Append("Height=`"$($element.ComboBox.Height)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Height=`"Auto`" ") | Out-Null
            }
            if ($element.ComboBox.HorizontalAlignment) {
                $xamlBuilder.Append("HorizontalAlignment=`"$($element.ComboBox.HorizontalAlignment)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("HorizontalAlignment=`"Stretch`" ") | Out-Null
            }
            if ($element.ComboBox.ToolTip) {
                $xamlBuilder.Append("ToolTip=`"$($element.ComboBox.ToolTip.Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;'))`" ") | Out-Null
            }
            if ($iconPreview) { $xamlBuilder.Append("TextSearch.TextPath=`"Tag`" MaxDropDownHeight=`"420`" ") | Out-Null }
            $comboText = $element.ComboBox.Text ? $element.ComboBox.Text.Replace('<', '&lt;').Replace('>', '&gt;') : ($element.ComboBox.Elements | Select-Object -First 1)
            if ($iconPreview) { $xamlBuilder.Append("Text=`"$comboText`" Margin=`"5`">") | Out-Null }
            else { $xamlBuilder.Append("Text=`"$comboText`" Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null }

            foreach ($comboElement in $element.ComboBox.Elements) {
                $selected = if ($element.ComboBox.Text -and $element.ComboBox.Text -eq $comboElement) { ' IsSelected="True"' } else { '' }
                $escaped = $comboElement.Replace('<','&lt;').Replace('>','&gt;')
                if ($iconPreview) {
                    $iconXaml = New-PowerControlIconXaml -Icon $comboElement -Size 16 -Margin '0'
                    $xamlBuilder.Append("`n$indent    <ComboBoxItem Tag=`"$escaped`"$selected><StackPanel Orientation=`"Horizontal`"><Grid Width=`"18`" Height=`"18`" VerticalAlignment=`"Center`">$iconXaml</Grid><TextBlock Text=`"$escaped`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"/></StackPanel></ComboBoxItem>") | Out-Null
                }
                else {
                    $xamlBuilder.Append("`n$indent    <ComboBoxItem$selected>$escaped</ComboBoxItem>") | Out-Null
                }
            }
            
            $xamlBuilder.Append("`n$indent</ComboBox>") | Out-Null
            if ($iconPreview) { $xamlBuilder.Append("`n$indent</DockPanel>") | Out-Null }

            Write-DebugLog -Message "Added ComboBox: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'RadioButton' {
            $controlName = "$($element.RadioButton.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<RadioButton Name=`"$controlName`" Content=`"$($element.RadioButton.Text)`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added RadioButton: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'Slider' {
            $controlName = "$($element.Slider.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<Slider Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Minimum=`"$($element.Slider.Minimum)`" Maximum=`"$($element.Slider.Maximum)`" ") | Out-Null
            $xamlBuilder.Append("Value=`"$($element.Slider.Value)`" ") | Out-Null
            if ($element.Slider.Width) {
                $xamlBuilder.Append("Width=`"$($element.Slider.Width)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Width=`"Auto`" ") | Out-Null
            }
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added Slider: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'DatePicker' {
            $controlName = "$($element.DatePicker.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<DatePicker Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added DatePicker: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'ListBox' {
            $controlName = "$($element.ListBox.Name)_$script:controlCounter"
            $script:controlCounter++
            
            $selectionMode = if ($element.ListBox.SelectionMode) {
                $element.ListBox.SelectionMode
            } else {
                "Extended"
            }

            $xamlBuilder.Append("`n$indent<ListBox Name=`"$controlName`" ") | Out-Null
            if ($element.ListBox.ToolTip) {
                $xamlBuilder.Append("ToolTip=`"$($element.ListBox.ToolTip.Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;'))`" ") | Out-Null
            }
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`" SelectionMode=`"$selectionMode`">") | Out-Null
            foreach ($item in $element.ListBox.Items) {
                $xamlBuilder.Append("`n$indent    <ListBoxItem>$item</ListBoxItem>") | Out-Null
            }
            $xamlBuilder.Append("`n$indent</ListBox>") | Out-Null

            Write-DebugLog -Message "Added ListBox: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'ProgressBar' {
            $controlName = "$($element.ProgressBar.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<ProgressBar Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Minimum=`"$($element.ProgressBar.Minimum)`" Maximum=`"$($element.ProgressBar.Maximum)`" ") | Out-Null
            $xamlBuilder.Append("Value=`"$($element.ProgressBar.Value)`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added ProgressBar: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'Image' {
            $controlName = "$($element.Image.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<Image Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Source=`"$($element.Image.Source)`" ") | Out-Null
            $xamlBuilder.Append("Width=`"$($element.Image.Width)`" Height=`"$($element.Image.Height)`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added Image: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'Button' {
            $controlName = "$($element.Button.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<Button Name=`"$controlName`" Content=`"$($element.Button.Content)`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added Button: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'TabControl' {
            $controlName = "$($element.TabControl.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<TabControl Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            foreach ($tab in $element.TabControl.Tabs) {
                $xamlBuilder.Append("`n$indent    <TabItem Header=`"$($tab.Header)`">") | Out-Null
                $xamlBuilder.Append("`n$indent        <StackPanel>") | Out-Null
                foreach ($tabElement in $tab.Elements) {
                    Add-WPFElement -xamlBuilder $xamlBuilder -element $tabElement -depth ($depth + 3)
                }
                $xamlBuilder.Append("`n$indent        </StackPanel>") | Out-Null
                $xamlBuilder.Append("`n$indent    </TabItem>") | Out-Null
            }
            $xamlBuilder.Append("`n$indent</TabControl>") | Out-Null
            
            Write-DebugLog -Message "Added TabControl: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'StackPanel' {
            $controlName = "$($element.StackPanel.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<StackPanel Name=`"$controlName`" ") | Out-Null
            
            # Add Orientation if specified
            if ($element.StackPanel.Orientation) {
                $xamlBuilder.Append("Orientation=`"$($element.StackPanel.Orientation)`" ") | Out-Null
            }
            
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            
            foreach ($stackPanelElement in $element.StackPanel.Elements) {
                Add-WPFElement -xamlBuilder $xamlBuilder -element $stackPanelElement -depth ($depth + 1)
            }
            
            $xamlBuilder.Append("`n$indent</StackPanel>") | Out-Null
            
            Write-DebugLog -Message "Added StackPanel: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'Expander' {
            $controlName = "$($element.Expander.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<Expander Name=`"$controlName`" Header=`"$($element.Expander.Header)`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            $xamlBuilder.Append("`n$indent    <StackPanel>") | Out-Null
            foreach ($expanderElement in $element.Expander.Elements) {
                Add-WPFElement -xamlBuilder $xamlBuilder -element $expanderElement -depth ($depth + 2)
            }
            $xamlBuilder.Append("`n$indent    </StackPanel>") | Out-Null
            $xamlBuilder.Append("`n$indent</Expander>") | Out-Null
            
            Write-DebugLog -Message "Added Expander: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'TreeView' {
            $controlName = "$($element.TreeView.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<TreeView Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            foreach ($item in $element.TreeView.Items) {
                $xamlBuilder.Append("`n$indent    <TreeViewItem Header=`"$($item.Header)`">") | Out-Null
                if ($item.Items) {
                    foreach ($subItem in $item.Items) {
                        $xamlBuilder.Append("`n$indent        <TreeViewItem Header=`"$subItem`"/>") | Out-Null
                    }
                }
                $xamlBuilder.Append("`n$indent    </TreeViewItem>") | Out-Null
            }
            $xamlBuilder.Append("`n$indent</TreeView>") | Out-Null
            
            Write-DebugLog -Message "Added TreeView: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'DataGrid' {
            $controlName = "$($element.DataGrid.Name)_$script:controlCounter"
            $script:controlCounter++
            # Filter: a text box above the grid narrows the entries of every ComboBoxColumn (Add-DataGridColumnsAndRows)
            if ($element.DataGrid.Filter -eq $true) {
                $xamlBuilder.Append("`n$indent<StackPanel Grid.Row=`"$row`" Grid.Column=`"$column`"><TextBlock Text=`"Filter the choice lists (part of the name, applies when a cell is opened next)`" Opacity=`"0.7`" FontSize=`"11`" Margin=`"5,2,5,0`"/><TextBox Name=`"${controlName}_Filter`" Margin=`"5,2,5,0`" ToolTip=`"Narrows the entries of the choice columns of this table`"/>") | Out-Null
            }
            $xamlBuilder.Append("`n$indent<DataGrid Name=`"$controlName`" AutoGenerateColumns=`"False`" ") | Out-Null
                        
            if ($element.DataGrid.Width) {
                $xamlBuilder.Append("Width=`"$($element.DataGrid.Width)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Width=`"Auto`" ") | Out-Null
            }
            
            if ($element.DataGrid.Height) {
                $xamlBuilder.Append("Height=`"$($element.DataGrid.Height)`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Height=`"Auto`" ") | Out-Null
            }
            
            if ($element.DataGrid.CanUserSortColumns -eq $false) {
                $xamlBuilder.Append("CanUserSortColumns=`"False`" ") | Out-Null
            }
            if ($element.DataGrid.CanUserReorderColumns -eq $false) {
                $xamlBuilder.Append("CanUserReorderColumns=`"False`" ") | Out-Null
            }
            if ($element.DataGrid.CanUserResizeColumns -eq $false) {
                $xamlBuilder.Append("CanUserResizeColumns=`"False`" ") | Out-Null
            }
            if ($element.DataGrid.IsReadOnly -eq $true) {
                $xamlBuilder.Append("IsReadOnly=`"True`" ") | Out-Null
            }
            if ($element.DataGrid.SelectionMode) {
                $xamlBuilder.Append("SelectionMode=`"$($element.DataGrid.SelectionMode)`" ") | Out-Null
            }
            if ($element.DataGrid.SelectionUnit) {
                $xamlBuilder.Append("SelectionUnit=`"$($element.DataGrid.SelectionUnit)`" ") | Out-Null
            }
            if ($element.DataGrid.AlternatingRowBackground) {
                $xamlBuilder.Append("AlternatingRowBackground=`"$($element.DataGrid.AlternatingRowBackground)`" ") | Out-Null
            }
            
            if ($element.DataGrid.AddRows) {
                $xamlBuilder.Append("CanUserAddRows=`"False`" ") | Out-Null
            }
            
            $xamlBuilder.Append("HorizontalAlignment=`"Stretch`" VerticalAlignment=`"Stretch`" ") | Out-Null
            if ($element.DataGrid.Filter -eq $true) { $xamlBuilder.Append("Margin=`"5`"/>`n$indent</StackPanel>") | Out-Null }
            else { $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null }

            Write-DebugLog -Message "Added DataGrid: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'RichTextBox' {
            $controlName = "$($element.RichTextBox.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<RichTextBox Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            $xamlBuilder.Append("`n$indent    <FlowDocument>") | Out-Null
            $xamlBuilder.Append("`n$indent        <Paragraph>") | Out-Null
            $xamlBuilder.Append("`n$indent            <Run>$($element.RichTextBox.Text)</Run>") | Out-Null
            $xamlBuilder.Append("`n$indent        </Paragraph>") | Out-Null
            $xamlBuilder.Append("`n$indent    </FlowDocument>") | Out-Null
            $xamlBuilder.Append("`n$indent</RichTextBox>") | Out-Null
            
            Write-DebugLog -Message "Added RichTextBox: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'ToggleButton' {
            $controlName = "$($element.ToggleButton.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<ToggleButton Name=`"$controlName`" Content=`"$($element.ToggleButton.Content)`" ") | Out-Null
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added ToggleButton: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'ScrollViewer' {
            $controlName = "$($element.ScrollViewer.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<ScrollViewer Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("VerticalScrollBarVisibility=`"Auto`" HorizontalScrollBarVisibility=`"Auto`" ") | Out-Null
            if ($element.ScrollViewer.Width) {
                $xamlBuilder.Append("Width=`"$($element.ScrollViewer.Width)`" ") | Out-Null
            }
            if ($element.ScrollViewer.Height) {
                $xamlBuilder.Append("Height=`"$($element.ScrollViewer.Height)`" ") | Out-Null
            }
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            $xamlBuilder.Append("`n$indent    <StackPanel>") | Out-Null
            foreach ($scrollElement in $element.ScrollViewer.Elements) {
                Add-WPFElement -xamlBuilder $xamlBuilder -element $scrollElement -depth ($depth + 2)
            }
            $xamlBuilder.Append("`n$indent    </StackPanel>") | Out-Null
            $xamlBuilder.Append("`n$indent</ScrollViewer>") | Out-Null
            
            Write-DebugLog -Message "Added ScrollViewer: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'Border' {
            $controlName = "$($element.Border.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<Border Name=`"$controlName`" ") | Out-Null
            $xamlBuilder.Append("BorderBrush=`"$($element.Border.BorderBrush)`" BorderThickness=`"$($element.Border.BorderThickness)`" ") | Out-Null
            if ($element.Border.Background) {
                $xamlBuilder.Append("Background=`"$($element.Border.Background)`" ") | Out-Null
            }
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`">") | Out-Null
            
            # Check if there's only one element and it's a TextBlock
            if ($element.Border.Elements.Count -eq 1 -and $element.Border.Elements[0].ContainsKey('TextBlock')) {
                $textBlock = $element.Border.Elements[0].TextBlock
                $xamlBuilder.Append("`n$indent    <TextBlock Name=`"$($textBlock.Name)`" Text=`"$($textBlock.Text)`"/>") | Out-Null
            } else {
                $xamlBuilder.Append("`n$indent    <StackPanel>") | Out-Null
                foreach ($borderElement in $element.Border.Elements) {
                    Add-WPFElement -xamlBuilder $xamlBuilder -element $borderElement -depth ($depth + 2)
                }
                $xamlBuilder.Append("`n$indent    </StackPanel>") | Out-Null
            }
            
            $xamlBuilder.Append("`n$indent</Border>") | Out-Null
            
            Write-DebugLog -Message "Added Border: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }

        'Separator' {
            $controlName = "$($element.Separator.Name)_$script:controlCounter"
            $script:controlCounter++
            $xamlBuilder.Append("`n$indent<Separator Name=`"$controlName`" ") | Out-Null
            if ($element.Separator.Orientation -eq 'Vertical') {
                $xamlBuilder.Append("Width=`"1`" ") | Out-Null
            } else {
                $xamlBuilder.Append("Height=`"1`" ") | Out-Null
            }
            $xamlBuilder.Append("Grid.Row=`"$row`" Grid.Column=`"$column`" Margin=`"5`"/>") | Out-Null
            
            Write-DebugLog -Message "Added Separator: $controlName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
        
        'OpenFile' {
              $controlName = "$($element.OpenFile.Name)_$script:controlCounter"
              $buttonName = "OpenFile_$($element.OpenFile.Name)_$script:controlCounter"
              $script:controlCounter++
              
              $xamlBuilder.Append("`n$indent<Grid Grid.Row=`"$row`" Grid.Column=`"$column`">") | Out-Null
              $xamlBuilder.Append("`n$indent    <Grid.ColumnDefinitions>") | Out-Null
              $xamlBuilder.Append("`n$indent        <ColumnDefinition Width=`"*`"/>") | Out-Null
              $xamlBuilder.Append("`n$indent        <ColumnDefinition Width=`"Auto`"/>") | Out-Null
              $xamlBuilder.Append("`n$indent    </Grid.ColumnDefinitions>") | Out-Null
              $xamlBuilder.Append("`n$indent    <TextBox x:Name=`"$controlName`" Grid.Column=`"0`" Margin=`"5,5,0,5`"/>") | Out-Null
              $browseSize = if ((-not $PowerControl.General.Theme) -or ($PowerControl.General.Theme -eq 'Classic')) { 'Width="25"' } else { 'MinWidth="40" Padding="8,0"' }
              $xamlBuilder.Append("`n$indent    <Button x:Name=`"$buttonName`" Content=`"...`" Grid.Column=`"1`" $browseSize Margin=`"0,5,5,5`"/>") | Out-Null
              $xamlBuilder.Append("`n$indent</Grid>") | Out-Null
              
              Write-DebugLog -Message "Added OpenFile: TextBox = $controlName, Button = $buttonName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
          }
    }
    if ($controlName.Length -gt 0) {
        $script:WPFCollector += [PSCustomObject]@{
            'Label' = $element.Label
            'WPFElement' = $element.Keys | Where-Object { $_ -ne 'Label' } | Select-Object -First 1
            'WPFName' = $controlName
            'Properties' = $($element.GetEnumerator() | Where-Object { $_.Key -notin @('Label') }).value.GetEnumerator() | Where-Object { $_.Key -notin @('Name') }
        }
    }
    Write-DebugLog -Message "Finished processing element" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
}

function script:Get-ControlValues {
    param ([System.Windows.DependencyObject]$Container)

    Write-DebugLog -Message "Starting Get-ControlValues function" -Level 1 -LogFileName $($script:DrawGUIID + '.log')

    $results = @{}

    foreach($element in $script:WPFCollector){
        switch ($element.WPFElement) {
            "TextBox" { $results[$element.WPFName] = $container.$($element.WPFName).Text }
            "CodeEditor" { $results[$element.WPFName] = $container.$($element.WPFName).Text }
            "OpenFile" { $results[$element.WPFName] = $container.$($element.WPFName).Text }
            "PasswordBox" { $results[$element.WPFName] = $container.$($element.WPFName).SecurePassword }
            "CheckBox" { $results[$element.WPFName] = $container.$($element.WPFName).IsChecked }
            "ComboBox" {
                # an editable ComboBox with free text has no SelectedItem; hand the text back in the
                # same shape (.Content) so consumers like "New element" keep working
                $combo = $container.$($element.WPFName)
                $results[$element.WPFName] = if ($null -ne $combo.SelectedItem -and $combo.SelectedItem -is [System.Windows.Controls.ComboBoxItem] -and $null -ne $combo.SelectedItem.Tag) {
                    # IconPreview entries: the value is the Tag, the Content is the icon + text panel
                    [PSCustomObject]@{ Content = [string]$combo.SelectedItem.Tag }
                } elseif ($null -ne $combo.SelectedItem) {
                    $combo.SelectedItem
                } elseif ($combo.IsEditable -and -not [string]::IsNullOrEmpty($combo.Text)) {
                    [PSCustomObject]@{ Content = $combo.Text }
                } else {
                    $null
                }
            }
            "DatePicker" { $results[$element.WPFName] = $container.$($element.WPFName).SelectedDate }
            "Slider" { $results[$element.WPFName] = $container.$($element.WPFName).Value }
            "ListBox" { $results[$element.WPFName] = $container.$($element.WPFName).SelectedItems }
            "RadioButton" { if ($container.$($element.WPFName).IsChecked) { $results[$element.WPFName] = $container.$($element.WPFName).Content } }
            "DataGrid" { $results[$element.WPFName] = $container.$($element.WPFName).ItemsSource }
            "RichTextBox" { 
                $textRange = New-Object System.Windows.Documents.TextRange(
                    $container.$($element.WPFName).Document.ContentStart, 
                    $container.$($element.WPFName).Document.ContentEnd
                )
                $results[$element.WPFName] = $textRange.Text 
            }
            "ToggleButton" { $results[$element.WPFName] = $container.$($element.WPFName).IsChecked }
            "ItemsListBox" { 
                $results[$element.WPFName] = @{
                    AllItems = $container.$($element.WPFName).ItemsSource
                    SelectedItems = $container.$($element.WPFName).SelectedItems
                }
            }
        }
    }

    Write-DebugLog -Message "Finished Get-ControlValues function" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
    return $results
}

function script:Add-DataGridColumnsAndRows {
    param ($DataGrid, $Element)

    Write-DebugLog -Message "Starting Add-DataGridColumnsAndRows function" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
    
    $script:dataCollection = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $control = $DataGrid.FindName($Element.WPFName)
    
    $Columns = $($Element.Properties | Where-Object { $_.Key -eq 'columns' }).Value
    $Rows = $($Element.Properties | Where-Object { $_.Key -eq 'Rows' }).Value
    $comboSources = @{}   # resource key -> full entry list of a ComboBoxColumn (for the Filter box)
    
    if ($Columns.count -gt  0) {
        $Columns.foreach{
            $items = $_
            $column = switch ($items.Type) {
                'TextColumn' { 
                    $col = New-Object System.Windows.Controls.DataGridTextColumn
                    $col.Binding = New-Object System.Windows.Data.Binding($items.Binding)
                    $col
                }
                'CheckBoxColumn' { 
                    $col = New-Object System.Windows.Controls.DataGridCheckBoxColumn
                    $col.Binding = New-Object System.Windows.Data.Binding($items.Binding)
                    $col
                }
                'ComboBoxColumn' {
                    # The Fluent theme (.NET 10) has no usable template for DataGridComboBoxColumn: its dropdown opened
                    # as an empty white box (Workflow tab of the element editor). A template column with an ordinary
                    # ComboBox renders in both themes; the entries live in a DataGrid resource (DynamicResource).
                    $resourceKey = "ComboItems_$($items.Binding -replace '[^A-Za-z0-9_]', '')_$([guid]::NewGuid().ToString('N').Substring(0, 6))"
                    $control.Resources[$resourceKey] = [string[]]@($items.Items | ForEach-Object { [string]$_ })
                    $comboSources[$resourceKey] = [string[]]@($items.Items | ForEach-Object { [string]$_ })
                    $templateXaml = @"
<DataGridTemplateColumn xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <DataGridTemplateColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding $($items.Binding)}" Margin="4,2" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
  <DataGridTemplateColumn.CellEditingTemplate><DataTemplate><ComboBox ItemsSource="{DynamicResource $resourceKey}" IsEditable="True" Text="{Binding $($items.Binding), UpdateSourceTrigger=PropertyChanged}" IsTextSearchEnabled="True" MaxDropDownHeight="360"/></DataTemplate></DataGridTemplateColumn.CellEditingTemplate>
</DataGridTemplateColumn>
"@
                    [Windows.Markup.XamlReader]::Parse($templateXaml)
                 }
                default { 
                    $col = New-Object System.Windows.Controls.DataGridTextColumn
                    $col.Binding = New-Object System.Windows.Data.Binding($items.Binding)
                    $col
                 }
            }

            $column.Header = $items.Header

            if ($items.Width) {
                $column.Width = if ($items.Width -eq 'Auto') { [System.Windows.Controls.DataGridLength]::Auto } else { New-Object System.Windows.Controls.DataGridLength($items.Width) }
            }
            if ($items.IsReadOnly -eq $true) { $column.IsReadOnly = $true }
            if ($items.CanUserSort -eq $false) { $column.CanUserSort = $false }

            $control.Columns.Add($column)
            Write-DebugLog -Message "Added column: $($items.Header)" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
    }

    # DataGrid option Filter: the text box above the grid narrows every ComboBoxColumn list (DynamicResource swap)
    $filterBox = $DataGrid.FindName("$($Element.WPFName)_Filter")
    if ($null -ne $filterBox -and $comboSources.Count -gt 0) {
        $filterBox.Tag = @{ Grid = $control; Sources = $comboSources }
        $filterBox.Add_TextChanged({
            param($sender, $e)
            $state = $sender.Tag
            $needle = ([string]$sender.Text).Trim()
            foreach ($key in @($state.Sources.Keys)) {
                $all = $state.Sources[$key]
                $state.Grid.Resources[$key] = [string[]]@($(if ($needle) { $all | Where-Object { $_ -like "*$needle*" } } else { $all }))
            }
        })
    }
    
    if ($Rows.count -gt  0) {
        
        if($rows[0].GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
            $Rows.foreach{
                $Row = $_
                $customObject = [PSCustomObject]@{}
    
                $properties = @{}
                foreach ($key in $Row.Keys) {
                    $properties[$key] = $Row[$key]
                }
    
                $customObject = [PSCustomObject]$properties
                $script:dataCollection.Add($customObject)
            }
        }
        else {
            $script:dataCollection += $Rows
        }
        
        $control.ItemsSource = $script:dataCollection
        Write-DebugLog -Message "Added $($Rows.Count) rows to DataGrid" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    }
    
    if ($($Element.Properties | Where-Object { $_.Key -eq 'AddRows' }).Value) {
        Write-DebugLog -Message "Adding AddRows event to Button" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
      
        $newRow = @{}
        foreach ($property in $columns.Binding) {
            $newRow[$property] = ""
        }
        <#foreach ($property in $script:dataCollection[0].PSObject.Properties.Name) {
            $newRow[$property] = ""
        }
        #>
        if($script:dataCollection.count -gt 0) {
            $script:dataCollection += $([PSCustomObject]$newRow)
        }
        else {
            $script:dataCollection.Add($([PSCustomObject]$newRow))
        }

        $control.ItemsSource = $script:dataCollection
        $control.Items.Refresh()

        $control.add_PreviewKeyUp([System.Management.Automation.ScriptBlock]::Create('
            param($sender, $e)
            
            if ($e.Key -eq "Delete") {
                $currentRow = $sender.SelectedItem
                if ($currentRow -ne $null -and $script:dataCollection.Count -gt 1) {
                    if ($script:dataCollection -isnot [System.Collections.ArrayList]) {
                        $script:dataCollection = [System.Collections.ArrayList]::new($script:dataCollection)
                    }
                    
                    $currentIndex = $script:dataCollection.IndexOf($currentRow)
                    if ($currentIndex -ge 0) {
                        [void]$script:dataCollection.RemoveAt($currentIndex)
                        $sender.ItemsSource = $null
                        $sender.ItemsSource = $script:dataCollection
                        $sender.Items.Refresh()
                        $e.Handled = $true
                    }
                }
            }
            elseif ($e.Key -eq "Tab" -or $e.Key -eq "Return") {
                $lastRowIndex = $script:dataCollection.Count - 1
                $currentRow = $sender.CurrentItem
                $currentIndex = $sender.Items.IndexOf($currentRow)
                
                if ($currentIndex -eq $lastRowIndex) {
                    $hasContent = $false
                    foreach ($property in $currentRow.PSObject.Properties) {
                        if (![string]::IsNullOrWhiteSpace($property.Value)) {
                            $hasContent = $true
                            break
                        }
                    }
                    
                    if ($hasContent) {
                        $newRow = [PSCustomObject]@{}
                        foreach ($property in $script:dataCollection[0].PSObject.Properties.Name) {
                            $newRow | Add-Member -MemberType NoteProperty -Name $property -Value ""
                        }                
                        $script:dataCollection += $newRow
                        $sender.ItemsSource = $script:dataCollection
                        $sender.Items.Refresh()
                    }
                }
            }
'))

        $control.add_SelectionChanged([System.Management.Automation.ScriptBlock]::Create('
            param($sender, $e)

                $lastRowIndex = $script:dataCollection.Count - 1
                $currentRow = $sender.CurrentItem
                $currentIndex = $sender.Items.IndexOf($currentRow)
                
                if ($currentIndex -eq $lastRowIndex) {
                    $hasContent = $false
                    foreach ($property in $currentRow.PSObject.Properties) {
                        if (![string]::IsNullOrWhiteSpace($property.Value)) {
                            $hasContent = $true
                            break
                        }
                    }
                    
                    if ($hasContent) {
                        $newRow = [PSCustomObject]@{}
                        foreach ($property in $script:dataCollection[0].PSObject.Properties.Name) {
                            $newRow | Add-Member -MemberType NoteProperty -Name $property -Value ""
                        }                
                        $script:dataCollection += $newRow
                        $sender.ItemsSource = $script:dataCollection
                        $sender.Items.Refresh()
                    }
                }

'))
  
    }
    

    Write-DebugLog -Message "Finished Add-DataGridColumnsAndRows function" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
}

function script:ConvertTo-NormalizedGuiResults {
    param ([Parameter(Mandatory=$true)][hashtable]$GuiResults)

    Write-DebugLog -Message "Starting ConvertTo-NormalizedGuiResults function" -Level 1 -LogFileName $($script:DrawGUIID + '.log')

    $normalizedResults = @{}

    foreach ($key in $GuiResults.Keys) {
        $baseName = $key -replace '_\d+$', ''
        
        if ($normalizedResults.ContainsKey($baseName)) {
            if ($normalizedResults[$baseName] -isnot [System.Collections.ArrayList]) {
                $normalizedResults[$baseName] = [System.Collections.ArrayList]@($normalizedResults[$baseName])
            }
            $null = $normalizedResults[$baseName].Add($GuiResults[$key])
            Write-DebugLog -Message "Added value to existing key: $baseName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        } else {
            $normalizedResults[$baseName] = $GuiResults[$key]
            Write-DebugLog -Message "Added new key-value pair: $baseName" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        }
    }

    Write-DebugLog -Message "Finished ConvertTo-NormalizedGuiResults function" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
    return $normalizedResults
}

function script:Invoke-GUIElementProcessing {
    param (
        [Parameter(Mandatory=$true)]$Elements,
        [System.Windows.Controls.ContentControl]$ParentControl
    )

    Write-DebugLog -Message "Starting GUI Element Processing" -Level 1 -LogFileName $($script:DrawGUIID + '.log')

    foreach($element in $script:WPFCollector){
        Write-DebugLog -Message "Processing Name: $($element.WPFName) element: $($element.WPFElement)" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
                
        switch ($element.WPFElement) {
            'OpenFile' { 
                Write-DebugLog -Message "Invoking OpenFile Processing" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
                Invoke-OpenFileProcessing $element $ParentControl
            }
            {'TextBox','CheckBox','ComboBox','CodeEditor' -contains $_} {
                Write-DebugLog -Message "Invoking Common Control Processing for $($element.WPFElement)" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
                Invoke-CommonControlProcessing $element $ParentControl
                if ($element.WPFElement -eq 'ComboBox') { Add-ComboBoxIconPreview -Element $element -Window $ParentControl }
            }
            
            'ListBox' {
                Write-DebugLog -Message "Invoking Common Control Processing for $($element.WPFElement)" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
                Invoke-ListBoxProcessing $element $ParentControl
            }
            
            'DataGrid' {
                Write-DebugLog -Message "Invoking Common Control Processing for $($element.WPFElement)" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
                Add-DataGridColumnsAndRows -DataGrid $ParentControl -Element $element
            }
        }
    }
    #
    Write-DebugLog -Message "Finished GUI Element Processing" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
}


function script:Test-DrawGuiEditorDark {
    <# $true when the script editor should use the dark palette: dark theme and setting CodeEditorColors not 'Light' #>
    param([string]$EffectiveTheme)
    if ($EffectiveTheme -ne 'Dark') { return $false }
    $colors = ''
    try { if ($null -ne $PowerControl.Settings) { $colors = [string]$PowerControl.Settings['CodeEditorColors'] } } catch { }
    return ($colors -ne 'Light')
}

function script:Set-DrawGuiDarkHighlighting {
    <#
      AvalonEdit's built-in PowerShell colors (dark blue, dark red, ...) are unreadable on a dark background.
      A private copy of the highlighting definition is loaded from the AvalonEdit resources and every color is
      lifted to a lightness of about 70 %; the shared definition (used by light dialogs) stays untouched.
    #>
    param($Editor)
    try {
        $name = if ($Editor.SyntaxHighlighting) { $Editor.SyntaxHighlighting.Name } else { 'PowerShell' }
        $assembly = [ICSharpCode.AvalonEdit.TextEditor].Assembly
        $resource = @($assembly.GetManifestResourceNames() | Where-Object { $_ -eq "ICSharpCode.AvalonEdit.Highlighting.Resources.$name.xshd" })
        if ($resource.Count -eq 0) { return }
        $stream = $assembly.GetManifestResourceStream([string]$resource[0])
        $reader = [System.Xml.XmlReader]::Create([System.IO.Stream]$stream)
        $definition = [ICSharpCode.AvalonEdit.Highlighting.Xshd.HighlightingLoader]::Load([System.Xml.XmlReader]$reader, [ICSharpCode.AvalonEdit.Highlighting.IHighlightingDefinitionReferenceResolver][ICSharpCode.AvalonEdit.Highlighting.HighlightingManager]::Instance)
        $reader.Dispose(); $stream.Dispose()
        foreach ($color in $definition.NamedHighlightingColors) {
            if ($null -eq $color.Foreground) { continue }
            $c = $color.Foreground.GetBrush($null).Color
            $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
            $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b)); $l = ($max + $min) / 2
            if ($l -ge 0.62) { continue }
            $d = $max - $min
            $s = if ($d -eq 0) { 0 } else { $d / (1 - [Math]::Abs(2 * $l - 1)) }
            $h = if ($d -eq 0) { 0 } elseif ($max -eq $r) { 60 * ((($g - $b) / $d) % 6) } elseif ($max -eq $g) { 60 * ((($b - $r) / $d) + 2) } else { 60 * ((($r - $g) / $d) + 4) }
            if ($h -lt 0) { $h += 360 }
            $l = 0.72
            $chroma = (1 - [Math]::Abs(2 * $l - 1)) * $s; $x = $chroma * (1 - [Math]::Abs(($h / 60) % 2 - 1)); $m = $l - $chroma / 2
            $rgb = switch ([int][Math]::Floor($h / 60)) { 0 { @($chroma, $x, 0) } 1 { @($x, $chroma, 0) } 2 { @(0, $chroma, $x) } 3 { @(0, $x, $chroma) } 4 { @($x, 0, $chroma) } default { @($chroma, 0, $x) } }
            $color.Foreground = [ICSharpCode.AvalonEdit.Highlighting.SimpleHighlightingBrush]::new([System.Windows.Media.Color]::FromRgb([byte](($rgb[0] + $m) * 255), [byte](($rgb[1] + $m) * 255), [byte](($rgb[2] + $m) * 255)))
        }
        $Editor.SyntaxHighlighting = $definition
    }
    catch { Write-DebugLog -Message "Dark highlighting not applied: $_" -Level 2 -LogFileName $($script:DrawGUIID + '.log') }
}

function script:Invoke-CommonControlProcessing {
    param($element, $Window)

    Write-DebugLog -Message "Invoke-CommonControlProcessing" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
    
    $control = $Window.FindName($element.WPFName)

    if ($control) {
        switch -Wildcard ($element.Properties.key) {
            'Text' {
                # a CheckBox carries its 'Text' as Content (set in the XAML); assigning .Text there threw
                # "property 'Text' cannot be found" and closed the whole dialog from the Loaded handler
                if ($null -ne $control.PSObject.Properties['Text']) {
                    $control.Text = $($element.Properties | Where-Object { $_.Key -eq 'Text' }).Value
                }
            }
            'IsChecked' {
                if ($null -ne $control.PSObject.Properties['IsChecked']) {
                    $control.IsChecked = $($element.Properties | Where-Object { $_.Key -eq 'IsChecked' }).Value
                }
            }
            'Events' {
                # $element is the WPFCollector entry (PSCustomObject), the dialog definition lives in .Properties
                $events = $($element.Properties | Where-Object { $_.Key -eq 'Events' }).Value
                foreach ($eventName in $events.Keys) {
                    $eventScript = [System.Management.Automation.ScriptBlock]::Create($events[$eventName])
                    $control."add_$eventName"($eventScript)
                }
            }
            'Check' {
                Add-CheckHandler $control $($element.Properties | Where-Object { $_.Key -eq 'check' }).Value
            }
        }
        
        if($element.WPFElement -eq 'CodeEditor') {
            if ($script:DrawGuiEditorDark) { Set-DrawGuiDarkHighlighting -Editor $control }
            $control.add_PreviewMouseWheel({
                param($sender, $e)

                # Find the parent ScrollViewer
                $scrollViewer = $sender.Parent
                while ($scrollViewer -and -not ($scrollViewer -is [System.Windows.Controls.ScrollViewer])) {
                    $scrollViewer = $scrollViewer.Parent
                }

                # Forward the scroll event to the parent ScrollViewer
                if ($scrollViewer) {
                    $scrollViewer.ScrollToVerticalOffset($scrollViewer.VerticalOffset - $e.Delta)
                    $e.Handled = $true
                }
            })
            
            $control.add_PreviewKeyDown({
                param($sender, $e)
                                
                # Find the parent ScrollViewer
                $scrollViewer = $sender.Parent
                while ($scrollViewer -and -not ($scrollViewer -is [System.Windows.Controls.ScrollViewer])) {
                    $scrollViewer = $scrollViewer.Parent
                }

                # Forward Page Up and Page Down events
                if ($scrollViewer) {
                    switch ($e.Key.ToString()) {
                        "PageUp" {  # Page Up
                            $scrollViewer.ScrollToVerticalOffset($scrollViewer.VerticalOffset - $scrollViewer.ViewportHeight)
                            $e.Handled = $true
                        }
                        "Next" {  # Page Down
                            $scrollViewer.ScrollToVerticalOffset($scrollViewer.VerticalOffset + $scrollViewer.ViewportHeight)
                            $e.Handled = $true
                        }
                    }
                }
            })
        }
    } else {
        Write-DebugLog -Message "Control '$($element.WPFName)' not found" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    }
}


function script:Invoke-ListBoxProcessing {
    param($element, $Window)

    Write-DebugLog -Message "Invoke-ListBoxProcessing" -Level 3 -LogFileName $($script:DrawGUIID + '.log')

    
    $control = $Window.FindName($element.WPFName)

    if ($control) {
        switch -Wildcard ($element.Properties.key) {
            'Text' {
                $control.SelectedItems.Clear()
                
                $($element.Properties | Where-Object { $_.Key -eq 'Text' }).Value | ForEach-Object {
                    $SelectedItems = $_
                    $index = $null

                    $items = $($element.Properties | Where-Object { $_.Key -eq 'Items' }).Value
                    $index = $items.IndexOf($($items | Where-Object { $_ -match [regex]::Escape($SelectedItems.Trim()) } | Select-Object -First 1))
                    
                    if($index -ge 0) {
                        $control.SelectedItems.Add($control.Items[$index])
                    }
                }
            }
            'Events' {
                $events = $($element.Properties | Where-Object { $_.Key -eq 'Events' }).Value
                foreach ($eventName in $events.Keys) {
                    $eventScript = [System.Management.Automation.ScriptBlock]::Create($events[$eventName])
                    $control."add_$eventName"($eventScript)
                }
            }
            'Check' {
                Add-CheckHandler $control $($element.Properties | Where-Object { $_.Key -eq 'check' }).Value
            }
        }
        
    } else {
        Write-DebugLog -Message "Control '$($element.WPFName)' not found" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    }
}

function script:Invoke-OpenFileProcessing {
    param ($element, $Window)

    Write-DebugLog -Message "Starting OpenFile Processing" -Level 2 -LogFileName $($script:DrawGUIID + '.log')

    $textBox = $Window.FindName($($element.WPFName))
    $button = $Window.FindName("OpenFile_$($element.WPFName)")

    $openFileElement = [PSCustomObject]@{
        Filter = $($element.Properties | Where-Object { $_.Key -eq 'Filter' }).Value ?? "All types (*.*)|*.*"
        InitialDirectory = $($element.Properties | Where-Object { $_.Key -eq 'InitialDirectory' }).Value ?? $env:USERPROFILE
    }
    
    Write-DebugLog -Message "Adding Click event to Button" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
    $button.add_Click([System.Management.Automation.ScriptBlock]::Create('
    param($sender, $e)
    
    $FileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $FileDialog.Multiselect = $false
    $FileDialog.Filter = "' + $openFileElement.Filter + '"
    $FileDialog.InitialDirectory = "' + $openFileElement.InitialDirectory + '"
    
    $result = $FileDialog.ShowDialog()

    if ($result -eq "OK") {
        $textBox = $DrawGuiWindow.FindName($sender.Name.replace("OpenFile_",$null))
        
        $textBox.Text = $FileDialog.FileName
        #Write-Host "File selected: $($FileDialog.FileName)"
    }
'))

    if ($element.Properties.key -contains 'Text') {
        $textBox.text = $($element.Properties | Where-Object { $_.Key -eq 'Text' }).Value
    }

    if ($element.Properties.key -contains 'check') {
        Write-DebugLog -Message "Adding Check Handler to TextBox" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
        Add-CheckHandler $textBox $($element.Properties | Where-Object { $_.Key -eq 'check' }).Value
    }
    
    Write-DebugLog -Message "Finished OpenFile Processing" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
}

function script:Add-ComboBoxIconPreview {
    <# IconPreview ComboBox: the preview Border next to it shows the icon of the typed or selected value #>
    param ($Element, $Window)
    $combo = $Window.FindName($Element.WPFName)
    $preview = $Window.FindName("$($Element.WPFName)_Preview")
    if ($null -eq $combo -or $null -eq $preview) { return }
    $combo.Tag = $preview
    $render = {
        param($sender, $e)
        try {
            $target = $sender.Tag
            if ($null -eq $target) { return }
            $xaml = New-PowerControlIconXaml -Icon ([string]$sender.Text).Trim() -Size 20 -Margin '0'
            $target.Child = if ($xaml) { [Windows.Markup.XamlReader]::Parse("<Grid xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" xmlns:x=`"http://schemas.microsoft.com/winfx/2006/xaml`">$xaml</Grid>") } else { $null }
        }
        catch { Write-DebugLog -Message "Icon preview failed: $_" -Level 2 -LogFileName $($script:DrawGUIID + '.log') }
    }
    $combo.Add_SelectionChanged($render)
    $combo.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler]$render)
    & $render $combo $null
}

function script:Add-CheckHandler {
    param ($control, $checkScript)

    Write-DebugLog -Message "Adding check handler to control: $($control.Name)" -Level 2 -LogFileName $($script:DrawGUIID + '.log')

    $control.add_LostFocus([System.Management.Automation.ScriptBlock]::Create('
        param($sender, $e)
        try {
            if ($null -eq $sender) { throw "Sender is null" }
            $result = Invoke-Command -ScriptBlock {' + $checkScript + '} -ArgumentList $sender, $e
            $sender.BorderBrush = if ($result -eq $true) { "#FFABADB3" } else { "#FFF92200" }
            
            Write-DebugLog -Message "Check result for $($sender.Name): $result" -Level 3 -LogFileName $($script:DrawGUIID + ".log")
        } catch {
            Write-DebugLog -Message "Error in check script for $($sender.Name): $_" -Level 1 -LogFileName $($script:DrawGUIID + ".log")
            Write-DebugLog -Message "Stack Trace: $($_.ScriptStackTrace)" -Level 1 -LogFileName $($script:DrawGUIID + ".log")
            $sender.BorderBrush = "#FFF92200"
        }
'))
}

function script:Test-FieldChecks {
    param ($DrawGuiWindow)

    Write-DebugLog -Message "Starting field checks" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    #$failedChecks = 0

    foreach($element in $script:WPFCollector){
        if ($element.Properties.key -contains 'check') {
            $control = $DrawGuiWindow.FindName($element.WPFName)

            if ($null -ne $control) {
                try {
                    $result = Invoke-Command -ScriptBlock ([ScriptBlock]::Create('param($sender, $e);' + $($element.Properties | Where-Object { $_.Key -eq 'check' }).Value)) -ArgumentList $control
                    $control.BorderBrush = if ($result -eq $true) { "#FFABADB3" } else { "#FFF92200"; $script:failedChecks += $element.WPFName }
                    Write-DebugLog -Message "Check result for $($control.Name): $result" -Level 3 -LogFileName $($script:DrawGUIID + '.log')
                } catch {
                    Write-DebugLog -Message "Error in check script for $($control.Name): $_" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
                    Write-DebugLog -Message "Stack Trace: $($_.ScriptStackTrace)" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
                    $control.BorderBrush = "#FFF92200"
                    $script:failedChecks += $element.WPFName
                }
            }
        }
    }   

    Write-DebugLog -Message "Field checks completed. Failed checks: $($script:failedChecks.count)" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
}

function script:Show-PCtrlGUI {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [System.Collections.Hashtable]
        $GUItable
    )

    Write-DebugLog -Message "Starting Show-PCtrlGUI function" -Level 1 -LogFileName $($script:DrawGUIID + '.log')

    $xamlBuilder = [System.Text.StringBuilder]::new()

    $windowTitle = $GUItable['window']['title'] ? $GUItable['window']['title'].Replace('<','&lt;').Replace('>','&gt;') : 'PCtrlWindow'
    $xamlBuilder.AppendFormat("<Window Title=`"{0}`" SizeToContent=`"WidthAndHeight`" WindowStartupLocation=`"CenterScreen`" Topmost=`"True`" ", $windowTitle) | Out-Null
    # the dialog must fit into the working area (taskbar excluded): with the full screen height as limit a long
    # script pushed the button row behind the taskbar and "Save" could not be reached
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $script:DrawGuiMaxEditorHeight = [int][Math]::Max(250, [Math]::Min(800, $workArea.Height * 0.55))
    # decided once per dialog: dark editor palette (theme Dark, setting CodeEditorColors not 'Light')
    $themeForEditor = if ($PowerControl.General.ThemeMode) { $PowerControl.General.ThemeMode } else { $PowerControl.General.Theme }
    if ($themeForEditor -eq 'System' -and (Get-Command Get-PowerControlEffectiveTheme -ErrorAction SilentlyContinue)) { $themeForEditor = Get-PowerControlEffectiveTheme -Theme 'System' }
    $script:DrawGuiEditorDark = Test-DrawGuiEditorDark -EffectiveTheme ([string]$themeForEditor)
    $xamlBuilder.AppendFormat("MaxHeight=`"{0}`" MaxWidth=`"{1}`" ", [int]($workArea.Height - 24), [int]($workArea.Width - 24)) | Out-Null

    $isClassicTheme = (-not $PowerControl.General.Theme) -or ($PowerControl.General.Theme -eq 'Classic')
    $minWidth = ($GUItable['window']['MinWidth'] -gt 0) ? $GUItable['window']['MinWidth'] : $(if ($isClassicTheme) { 300 } else { 440 })
    $xamlBuilder.AppendFormat("MinWidth=`"{0}`" ", $minWidth) | Out-Null
    # Fluent buttons need 32 px; the classic 20 px clip their text
    $buttonSize = if ($isClassicTheme) { 'MinWidth="45" Height="20"' } else { 'MinWidth="90" MinHeight="32" Padding="12,4"' }

    if ($GUItable['window']['Width'] -gt 0) {
        $xamlBuilder.AppendFormat("Width=`"{0}`"", $GUItable['window']['Width']) | Out-Null
    }
    
    if(Test-Path $($Global:PowerControl.General.CurrentPath  + '\dll\ICSharpCode.AvalonEdit.dll')) {
        Add-Type -Path $($Global:PowerControl.General.CurrentPath  + '\dll\ICSharpCode.AvalonEdit.dll')
    }
    else {
        Write-DebugLog -Message "Avalon DLL not found: $($Global:PowerControl.General.CurrentPath  + '\dll\ICSharpCode.AvalonEdit.dll')" -Level 2 -LogFileName 'DrawGUI-e7670e8344194a828558f726.log'
    }
    
    $xamlBuilder.Append(' xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"') | Out-Null
    $xamlBuilder.Append(' xmlns:avalon="http://icsharpcode.net/sharpdevelop/avalonedit"') | Out-Null
    $xamlBuilder.Append(' xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">') | Out-Null
    $xamlBuilder.Append("`n <ScrollViewer VerticalScrollBarVisibility=`"Auto`" HorizontalScrollBarVisibility=`"Auto`">") | Out-Null
    $xamlBuilder.Append("`n <Grid Margin=`"5`">") | Out-Null

    $description = $GUItable['window']['description'] ? $GUItable['window']['description'].Replace('<','&lt;').Replace('>','&gt;') : ''
    if($description.Trim().Length -gt 0){
        $xamlBuilder.AppendFormat("`n    <TextBlock Margin=`"5`">{0}</TextBlock>", $description) | Out-Null
        $xamlBuilder.Append("`n    <StackPanel Margin=`"0,5,0,0`">") | Out-Null
        
        $gridName = $GUItable['window']['GridName'] ? $GUItable['window']['GridName'] : 'PCtrlGrid'
        $xamlBuilder.AppendFormat("`n        <Grid Name=`"{0}`" Margin=`"0,15,0,0`" VerticalAlignment=`"Top`">", $gridName) | Out-Null
    }
    else {
        $xamlBuilder.Append("`n    <StackPanel Margin=`"0,0,0,0`">") | Out-Null
        
        $gridName = $GUItable['window']['GridName'] ? $GUItable['window']['GridName'] : 'PCtrlGrid'
        $xamlBuilder.AppendFormat("`n        <Grid Name=`"{0}`" Margin=`"0,0,0,0`" VerticalAlignment=`"Top`">", $gridName) | Out-Null
    }

    $xamlBuilder.Append(@"
`n<Grid.ColumnDefinitions>
      <ColumnDefinition Width=`"auto`"/>
      <ColumnDefinition Width=`"*`"/>
  </Grid.ColumnDefinitions>
  <Grid.RowDefinitions>
"@) | Out-Null

    $rowDefinitions = (0..($GUItable['dialog'].Count-1)).ForEach({ "`n              <RowDefinition Height=`"Auto`"/>" })
    $xamlBuilder.Append($rowDefinitions -join '') | Out-Null
    $xamlBuilder.Append("`n          </Grid.RowDefinitions>") | Out-Null

    $script:controlCounter = 0
    $script:WPFCollector = @()
    
    $counter = 0
    
    Write-DebugLog -Message "Processing dialog items" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    foreach ($item in $GUItable['dialog'].GetEnumerator() | Sort-Object @{e={$_.key -as [int]}}) {
        if ($item.value['Label']) {
            $xamlBuilder.AppendFormat("`n    <TextBlock Grid.Column=`"0`" Margin=`"5,5,12,5`" HorizontalAlignment=`"Left`" VerticalAlignment=`"Center`" Grid.Row=`"{0}`">{1}</TextBlock> ", $counter, [System.Security.SecurityElement]::Escape([string]$item.value['Label'])) | Out-Null
        }
        
        Add-WPFElement -xamlBuilder $xamlBuilder -element $item.value -row $counter -column 1
        
        $counter++
    }

    $xamlBuilder.Append("`n       </Grid>") | Out-Null
    $xamlBuilder.Append("`n       <UniformGrid Columns=`"2`" Grid.Row=`"1`">") | Out-Null

    Write-DebugLog -Message "Processing action buttons" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    if ($GUItable['actionButtons']) {
        foreach ($button in $GUItable['actionButtons'].GetEnumerator() | Sort-Object @{e={$_.key -as [int]}}) {
            $xamlBuilder.AppendFormat("`n           <Button Name=`"{0}`"", $button.value['Name']) | Out-Null
            if ($button.value['isDefault']) {
                $xamlBuilder.Append(' IsDefault="True"') | Out-Null
            }
            $xamlBuilder.AppendFormat(" $buttonSize Margin=`"5`">{0}</Button> ", $button.value['Label'].Replace('<','&lt;').Replace('>','&gt;')) | Out-Null
        }
    }
    else {
        $xamlBuilder.Append("`n           <Button Name=`"ButtonOk`" IsDefault=`"True`" $buttonSize Margin=`"5`">Ok</Button> ") | Out-Null
    }

    $xamlBuilder.Append(@"
`n</UniformGrid>
  </StackPanel>
 </Grid>
 </ScrollViewer>
</Window>
"@) | Out-Null

    $xaml = $xamlBuilder.ToString()

    Write-DebugLog -Message "XAML generated" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    Write-DebugLog -Message $xaml -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        
    Write-DebugLog -Message "Creating window" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    $DrawGuiWindow = Convert-XAMLtoWindow -XAML $xaml 
    Write-DebugLog -Message "Window created" -Level 2 -LogFileName $($script:DrawGUIID + '.log')

    # dialogs follow the main window's theme setting (Light / Dark / System)
    $dialogTheme = if ($PowerControl.General.ThemeMode) { $PowerControl.General.ThemeMode } else { $PowerControl.General.Theme }
    if ($dialogTheme -and $dialogTheme -ne 'Classic') {
        try { $DrawGuiWindow.ThemeMode = [System.Windows.ThemeMode]::($dialogTheme) } catch { }
    }
    # inline Lucide icons (icon picker) stroke with this brush; the dialog has no access to the main window's resources
    $effectiveTheme = $dialogTheme
    if ($effectiveTheme -eq 'System' -and (Get-Command Get-PowerControlEffectiveTheme -ErrorAction SilentlyContinue)) { $effectiveTheme = Get-PowerControlEffectiveTheme -Theme 'System' }
    $DrawGuiWindow.Resources['PowerControlIconBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($effectiveTheme -eq 'Dark') { '#FFE6E6E6' } else { '#FF1F1F1F' })))
    # code editor (AvalonEdit) colors; the control has no Fluent template and would stay white in the dark theme.
    # Setting CodeEditorColors = 'Light' keeps the white editor (with the standard syntax colors) in the dark theme.
    $editorDark = Test-DrawGuiEditorDark -EffectiveTheme $effectiveTheme
    $DrawGuiWindow.Resources['PowerControlEditorBackgroundBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($editorDark) { '#FF1E1E1E' } else { '#FFFFFFFF' })))
    $DrawGuiWindow.Resources['PowerControlEditorForegroundBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($editorDark) { '#FFE6E6E6' } else { '#FF1F1F1F' })))

    $DrawGuiWindow.add_Loaded({
        try {
            Write-DebugLog -Message "Window Loaded event triggered" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
            # bring the dialog in front of the main window and give it the keyboard focus (opened from another runspace)
            [void]$DrawGuiWindow.Activate()
            if ($null -ne $WPFCollector) {
                Write-DebugLog -Message "Starting to process GUI elements" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
                Invoke-GUIElementProcessing -Elements $WPFCollector -ParentControl $DrawGuiWindow
                Write-DebugLog -Message "Finished processing GUI elements" -Level 2 -LogFileName $($script:DrawGUIID + '.log')

                foreach($element in $script:WPFCollector){
                    if ($element.Properties.key -contains 'focus') {
                        $control = $DrawGuiWindow.FindName($element.WPFName)
    
                        if ($null -ne $control) {    
                            $control.Focus()
                            if($null -ne $control.GetType().GetMethod("SelectAll")){
                                $control.SelectAll()
                            }
                            Write-DebugLog -Message "Focus set on $($control.Name)" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
                        }
                    }
                }

            } else {
                Write-DebugLog -Message "Invalid or null 'dialog' structure in GUItable. GUI elements may not be processed correctly." -Level 2 -LogFileName $($script:DrawGUIID + '.log')
            }
            
            $getDialog = $DrawGuiWindow.FindName($GUItable['window']['GridName'] ?? 'PCtrlGrid')

            $getDialog.Children.Where({ $_.Name.Length -gt 0 }).ForEach({
                $_.add_KeyDown({
                    if ($_.Key -eq 'Escape'){$DrawGuiWindow.DialogResult = $false}elseif ($_.Key -eq 'Enter'){$DrawGuiWindow.DialogResult = $true}
                })
            })
        }
        catch {
            Write-DebugLog -Message "An error occurred while processing GUI elements: $_" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
            Write-DebugLog -Message "Stack Trace: $($_.ScriptStackTrace)" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
            $DrawGuiWindow.Close()
        }
    })
    
    Write-DebugLog -Message "Setting up FieldChecks" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
    $FieldChecks = {
        Write-DebugLog -Message "Running FieldChecks" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        $script:failedChecks = @()
        Test-FieldChecks -DrawGuiWindow $DrawGuiWindow

        Write-DebugLog -Message "Failed checks: $($script:failedChecks.count)" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        if ($script:failedChecks.count -eq 0) {
            $DrawGuiWindow.DialogResult = $true
        }
        else {
            $errorMessage = "The following fields do not conform:`n`n"
            foreach ($failedCheck in $script:failedChecks) {
                $errorMessage += "- $failedCheck`n"
            }

            [System.Windows.MessageBox]::Show($errorMessage, "Validation Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    }
  
    if($null -ne $GUItable['actionButtons']) {  
        $GUItable['actionButtons'].Values.ForEach({
            if(($null -ne $_.Code) -and ($_.Code -is [System.Management.Automation.ScriptBlock])) {
                if($_.Code -like '*$DrawGuiWindow*') {
                    $DrawGuiWindow.$($_.Name).add_Click($_.Code) 
                }
                else {
                    if($null -ne $GUItable['OnResult']) {
                        $DrawGuiWindow.$($_.Name).add_Click([System.Management.Automation.ScriptBlock]::Create($([string]$FieldChecks) + ';' + $([string]$_.Code)))
                    }
                    else {
                        $DrawGuiWindow.$($_.Name).add_Click([System.Management.Automation.ScriptBlock]::Create('$DrawGuiWindow.DialogResult = $false ; ' + $_.Code))
                    }
                }
            }
            else {
                $DrawGuiWindow.$($_.Name).add_Click([System.Management.Automation.ScriptBlock]::Create($FieldChecks))
            }
        })
    }
    else {
        $DrawGuiWindow.ButtonOk.add_Click([System.Management.Automation.ScriptBlock]::Create($FieldChecks))
    } 

    Write-DebugLog -Message "Showing WPF Window" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        
    Show-WPFWindow -Window $DrawGuiWindow | Out-Null

    $script:GUIResults = @{}
    
    if ($DrawGuiWindow.DialogResult -eq $true) {
        Write-DebugLog -Message "Dialog result is true, processing results" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
        $mainGrid = $DrawGuiWindow.FindName($GUItable['window']['GridName'] ?? 'PCtrlGrid')

        if ($null -ne $mainGrid) {
            $rawResults = Get-ControlValues -Container $DrawGuiWindow
            $script:GUIResults = ConvertTo-NormalizedGuiResults -GuiResults $rawResults
        }

        if ($script:PowerControlDryRun) {
            # "Dry run": the dialog values become rows, OnResult (the real work) is skipped
            Write-DebugLog -Message "Dry run: OnResult skipped, $($script:GUIResults.Count) value(s) reported" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
            foreach ($key in @($script:GUIResults.Keys | Sort-Object)) {
                $value = $script:GUIResults[$key]
                $text = if ($value -is [System.Security.SecureString]) { '********' } elseif ($null -ne $value -and $null -ne $value.Content) { [string]$value.Content } elseif ($value -is [array]) { ($value | ForEach-Object { [string]$_ }) -join ', ' } else { [string]$value }
                $Script:PowerControlItem_Output += [PSCustomObject]@{ Dialog = [string]$GUItable['window']['title']; Field = $key; Value = $text; Type = $(if ($null -ne $value) { $value.GetType().Name } else { '' }) }
            }
        }
        elseif ($GUItable['OnResult'] -is [System.Management.Automation.ScriptBlock]) {
            Write-DebugLog -Message "Executing OnResult script block" -Level 2 -LogFileName $($script:DrawGUIID + '.log')
            & $GUItable['OnResult']
            #Invoke-Command $GUItable['OnResult'] -NoNewScope
        }
    }

    Write-DebugLog -Message "Show-PCtrlGUI function script:completed" -Level 1 -LogFileName $($script:DrawGUIID + '.log')
}

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