# PowerControl - 10-UI.Xaml.ps1
# XAML generators: context menus, menu bar, tree views, Lucide icons, navigation definition
# Dot-sourced by PowerControl.ps1 (shares its script scope); do not run on its own.

function New-XamlElement {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('ContextMenu', 'MenuBar', 'TreeView')]
        [string]$ElementType,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$ElementProperties
    )

    begin {
        $xaml = [System.Text.StringBuilder]::new()
    }

    process {       
        switch ($ElementType) {
            'ContextMenu' {
              [void]$xaml.AppendLine(@"
        <ContextMenu Name="$($ElementProperties.Name)" x:Key="$($ElementProperties.Name)">
"@)           
              Add-XamlContextMenu -StringBuilder $xaml -ElementProperties $ElementProperties
              
              [void]$xaml.AppendLine("        </ContextMenu>")
            }
            
            'MenuBar' {
              [void]$xaml.AppendLine(@"
        <Menu Name="$($ElementProperties.Name)" Background="Transparent" Padding="4,0,0,0" VerticalAlignment="Top">
"@)

              Add-XamlMenuBar -StringBuilder $xaml -ElementProperties $ElementProperties

              [void]$xaml.AppendLine("        </Menu>")
            }
            
            'TreeView' {
                [void]$xaml.AppendLine(@"
        <TreeView Name="$($ElementProperties.Name)" Grid.Row="1" BorderThickness="0" Background="Transparent" Margin="0,0,0,4" Visibility="$(if ($ElementProperties.Visibility) { $ElementProperties.Visibility } else { 'Visible' })"
                  ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ContextMenu="{StaticResource TreeViewMenu}">
                  <TreeView.Resources>
                      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="Transparent" />
                      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="Black" />
                      <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="Transparent" />
                      <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="Black" />
                  </TreeView.Resources>
"@)
          
          Add-XamlTreeView -StringBuilder $xaml -ElementProperties $ElementProperties

               
                [void]$xaml.AppendLine("        </TreeView>")
            }
        }
    }

    end {
        $xaml.ToString()
    }
}


function Get-PowerControlIconCachePath { [System.IO.Path]::Combine($Global:PowerControl.General.CurrentPath, 'temp', 'icon-cache.json') }

function Import-PowerControlIconCache {
    <#
      The SVG -> XAML conversions are kept in temp\icon-cache.json between starts. Every key carries the file's
      last write ticks, so an edited icon simply misses the cache. Saves a few hundred ms at start-up (190 icons).
    #>
    $script:SvgIconCache = @{}
    $script:SvgIconCacheDirty = $false
    $path = Get-PowerControlIconCachePath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        # only entries of the current format (v2 = size independent canvas markup); older files are simply rebuilt
        if ($stored -is [hashtable]) { foreach ($key in $stored.Keys) { if ($key -like 'v2|*') { $script:SvgIconCache[$key] = [string]$stored[$key] } } }
    }
    catch { Write-DebugLog -Message "Icon cache unreadable, rebuilding: $_" -Level 2 -LogFileName 'UI.log' }
}

function Save-PowerControlIconCache {
    <# writes the cache when new icons were converted (after the shell is up and after a navigation refresh) #>
    if (-not $script:SvgIconCacheDirty -or -not $script:SvgIconCache) { return }
    try {
        $path = Get-PowerControlIconCachePath
        $directory = [System.IO.Path]::GetDirectoryName($path)
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        # only entries whose icon file still exists with the recorded ticks, so the cache cannot grow with stale keys
        $live = @{}
        foreach ($entry in $script:SvgIconCache.GetEnumerator()) {
            $parts = $entry.Key.Split('|')   # v2|<path>|<brush key>|<ticks>
            if ($parts.Count -ge 4 -and (Test-Path -LiteralPath $parts[1]) -and "$([System.IO.File]::GetLastWriteTimeUtc($parts[1]).Ticks)" -eq $parts[-1]) { $live[$entry.Key] = $entry.Value }
        }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $live -Compress -Depth 2), [System.Text.UTF8Encoding]::new($false))
        $script:SvgIconCacheDirty = $false
        Write-DebugLog -Message "Icon cache saved ($($live.Count) entries)" -Level 2 -LogFileName 'UI.log'
    }
    catch { Write-DebugLog -Message "Icon cache not saved: $_" -Level 1 -LogFileName 'UI.log' }
}

function ConvertFrom-SvgIcon {
    <#
      .SYNOPSIS
      Turns a simple stroke based SVG (Lucide style) into inline XAML.

      .DESCRIPTION
      Supports path, circle, ellipse, rect, line, polyline and polygon. Strokes use the window
      resource PowerControlIconBrush, so icons follow the theme (light/dark). Results are cached.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][double]$Size = 18,
        [Parameter(Mandatory = $false)][string]$Margin = '0',
        [Parameter(Mandatory = $false)][string]$BrushKey = 'PowerControlIconBrush'
    )

    if (-not $script:SvgIconCache) { Import-PowerControlIconCache }
    # the cache holds the size independent canvas markup; the Viewbox with Size/Margin is wrapped around it per
    # call, so the icon picker (size 16) and the shell (size 18) share one entry per icon
    $cacheKey = "v2|$Path|$BrushKey|$([System.IO.File]::GetLastWriteTimeUtc($Path).Ticks)"
    $wrap = "<Viewbox Width=`"$Size`" Height=`"$Size`" Margin=`"$Margin`" VerticalAlignment=`"Center`" Stretch=`"Uniform`">{0}</Viewbox>"
    if ($script:SvgIconCache.ContainsKey($cacheKey)) { return ($wrap -f $script:SvgIconCache[$cacheKey]) }
    $script:SvgIconCacheDirty = $true

    $svg = [System.Xml.XmlDocument]::new()
    $svg.Load($Path)
    $root = $svg.DocumentElement
    $viewBox = @((($root.GetAttribute('viewBox')) -split '[\s,]+') | Where-Object { $_ })
    if ($viewBox.Count -ne 4) { $viewBox = @('0', '0', '24', '24') }
    $strokeWidth = $root.GetAttribute('stroke-width'); if (-not $strokeWidth) { $strokeWidth = '2' }
    $common = "Stroke=`"{DynamicResource $BrushKey}`" StrokeThickness=`"$strokeWidth`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`" StrokeLineJoin=`"Round`" Fill=`"{x:Null}`""

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<Canvas Width=`"$($viewBox[2])`" Height=`"$($viewBox[3])`">")

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($element in $root.SelectNodes('.//*')) {
        switch ($element.LocalName) {
            'path' { [void]$sb.Append("<Path Data=`"$($element.GetAttribute('d'))`" $common/>") }
            'circle' {
                $cx = [double]::Parse($element.GetAttribute('cx'), $inv); $cy = [double]::Parse($element.GetAttribute('cy'), $inv); $r = [double]::Parse($element.GetAttribute('r'), $inv)
                [void]$sb.Append("<Ellipse Canvas.Left=`"$(($cx - $r).ToString($inv))`" Canvas.Top=`"$(($cy - $r).ToString($inv))`" Width=`"$((2 * $r).ToString($inv))`" Height=`"$((2 * $r).ToString($inv))`" $common/>")
            }
            'ellipse' {
                $cx = [double]::Parse($element.GetAttribute('cx'), $inv); $cy = [double]::Parse($element.GetAttribute('cy'), $inv); $rx = [double]::Parse($element.GetAttribute('rx'), $inv); $ry = [double]::Parse($element.GetAttribute('ry'), $inv)
                [void]$sb.Append("<Ellipse Canvas.Left=`"$(($cx - $rx).ToString($inv))`" Canvas.Top=`"$(($cy - $ry).ToString($inv))`" Width=`"$((2 * $rx).ToString($inv))`" Height=`"$((2 * $ry).ToString($inv))`" $common/>")
            }
            'rect' {
                $rx = $element.GetAttribute('rx'); $ry = $element.GetAttribute('ry'); if (-not $rx) { $rx = '0' }; if (-not $ry) { $ry = $rx }
                $x = $element.GetAttribute('x'); $y = $element.GetAttribute('y'); if (-not $x) { $x = '0' }; if (-not $y) { $y = '0' }
                [void]$sb.Append("<Rectangle Canvas.Left=`"$x`" Canvas.Top=`"$y`" Width=`"$($element.GetAttribute('width'))`" Height=`"$($element.GetAttribute('height'))`" RadiusX=`"$rx`" RadiusY=`"$ry`" $common/>")
            }
            'line' { [void]$sb.Append("<Line X1=`"$($element.GetAttribute('x1'))`" Y1=`"$($element.GetAttribute('y1'))`" X2=`"$($element.GetAttribute('x2'))`" Y2=`"$($element.GetAttribute('y2'))`" $common/>") }
            { $_ -in 'polyline', 'polygon' } {
                $points = @(($element.GetAttribute('points') -split '[\s,]+') | Where-Object { $_ })
                if ($points.Count -ge 4) {
                    $data = "M$($points[0]),$($points[1])"
                    for ($i = 2; $i -lt $points.Count - 1; $i += 2) { $data += " L$($points[$i]),$($points[$i + 1])" }
                    if ($element.LocalName -eq 'polygon') { $data += ' Z' }
                    [void]$sb.Append("<Path Data=`"$data`" $common/>")
                }
            }
        }
    }

    [void]$sb.Append('</Canvas>')
    $script:SvgIconCache[$cacheKey] = $sb.ToString()
    $wrap -f $sb.ToString()
}

function New-PowerControlIconXaml {
    <#
      .SYNOPSIS
      XAML for an element icon: inline vector XAML for .svg, an Image for bitmap icons; $null when the file is missing.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)][string]$Icon,
        [Parameter(Mandatory = $false)][double]$Size = 18,
        [Parameter(Mandatory = $false)][string]$Margin = '0'
    )

    if ([string]::IsNullOrWhiteSpace($Icon)) { return $null }
    $iconPath = Join-Path -Path $PowerControl.General.CurrentPath -ChildPath "icons\$Icon"
    if (-not (Test-Path -LiteralPath $iconPath)) { return $null }

    if ([System.IO.Path]::GetExtension($iconPath) -eq '.svg') {
        try { return (ConvertFrom-SvgIcon -Path $iconPath -Size $Size -Margin $Margin) }
        catch {
            Write-DebugLog -Message "SVG icon $Icon could not be converted: $($_.Exception.Message)" -Level 1 -LogFileName 'PowerControl.log'
            return $null
        }
    }

    $iconUri = [System.Uri]::new($iconPath).AbsoluteUri
    "<Image Source=`"$iconUri`" Width=`"$Size`" Height=`"$Size`" Margin=`"$Margin`" VerticalAlignment=`"Center`"/>"
}

function Get-PowerControlShortLabel {
    <# two letter abbreviation of a label: initials of the first words, or the first two characters #>
    param([string]$Label, [int]$Letters = 2)
    $parts = @(($Label -split '\s+') | ForEach-Object { $_ -replace '[^A-Za-z0-9]', '' } | Where-Object { $_ })
    if ($parts.Count -gt 1) { return (($parts | Select-Object -First $Letters | ForEach-Object { $_[0] }) -join '').ToUpper() }
    if ($parts.Count -eq 1) { return $parts[0].Substring(0, [Math]::Min($Letters, $parts[0].Length)).ToUpper() }
    ''
}

function New-PowerControlTreeHeaderXaml {
    <#
      .SYNOPSIS
      Header XAML (StackPanel) of a navigation or action tree item.

      .DESCRIPTION
      Classic reproduces the historical markup per item kind. Fluent always renders
      [icon or abbreviation badge] [label]; the label carries Tag="NavLabel" so the icon rail can hide it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Label,
        [Parameter(Mandatory = $false)][string]$Icon,
        [Parameter(Mandatory = $true)][ValidateSet('Top', 'TopGrouped', 'Child', 'OrphanGrouped', 'Orphan')][string]$Kind
    )

    $escape = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }

    if ($Global:PowerControl.General.Theme -ne 'Classic') {
        $iconXaml = New-PowerControlIconXaml -Icon $Icon -Size 18 -Margin '0'
        if (-not $iconXaml -and $Kind -eq 'TopGrouped') { $iconXaml = New-PowerControlIconXaml -Icon 'lucide\folder.svg' -Size 18 -Margin '0' }
        if (-not $iconXaml) {
            $short = Get-PowerControlShortLabel -Label $Label
            $iconXaml = "<Border Width=`"20`" Height=`"20`" CornerRadius=`"4`" Background=`"{DynamicResource PowerControlBadgeBrush}`"><TextBlock Text=`"$(& $escape $short)`" FontSize=`"9`" FontWeight=`"SemiBold`" HorizontalAlignment=`"Center`" VerticalAlignment=`"Center`"/></Border>"
        }
        $maxLength = if ($Kind -eq 'Child') { 24 } else { 26 }
        $shown = if ($Label.Length -gt $maxLength) { $Label.Substring(0, $maxLength) + '...' } else { $Label }
        # the Border carries the hover highlight (the Fluent TreeViewItem template shows none of its own)
        # and the explicit text brush, so the labels follow the theme in dark mode
        return @"
              <Border CornerRadius="4" Padding="6,3" Margin="-4,0,0,0" ToolTip="$(& $escape $Label)">
                  <Border.Style>
                      <Style TargetType="Border">
                          <Setter Property="Background" Value="Transparent"/>
                          <Style.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource PowerControlTileHoverBrush}"/></Trigger>
                          </Style.Triggers>
                      </Style>
                  </Border.Style>
                  <StackPanel Orientation="Horizontal" Background="Transparent">
                      <Grid Width="20" Height="20" VerticalAlignment="Center">$iconXaml</Grid>
                      <TextBlock Tag="NavLabel" Text="$(& $escape $shown)" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="{DynamicResource PowerControlTextBrush}"/>
                  </StackPanel>
              </Border>
"@
    }

    # ---- Classic -------------------------------------------------------------------------------
    $header = if ($Label.Length -gt 29) { $Label.Substring(0, 29) + '...' } else { $Label }
    $short = Get-PowerControlShortLabel -Label $Label
    switch ($Kind) {
        'Top' {
            $iconXaml = New-PowerControlIconXaml -Icon $Icon -Size 18 -Margin '-5,0,0,0'
            if (-not $iconXaml) { $iconXaml = "<TextBlock Text=`"$short`" FontSize=`"18`" Width=`"35`" Margin=`"-5,0,0,0`" HorizontalAlignment=`"Center`"/>" }
            return "              <StackPanel Orientation=`"Horizontal`" Background=`"Transparent`">`r`n                  <TextBlock Text=`"$(& $escape $header)`" FontSize=`"12`" Width=`"150`" Margin=`"5,0,0,0`"/>`r`n                        $iconXaml`r`n                    </StackPanel>"
        }
        'TopGrouped' {
            $iconXaml = New-PowerControlIconXaml -Icon $Icon -Size 18 -Margin '-5,0,0,0'
            return "              <StackPanel Orientation=`"Horizontal`" Background=`"Transparent`">`r`n                  <TextBlock Text=`"$(& $escape $header)`" FontSize=`"12`" Width=`"150`" Margin=`"5,0,0,0`"/>`r`n                        $iconXaml`r`n                    </StackPanel>"
        }
        'Child' {
            $subLabel = if ($Label.Length -gt 19) { $Label.Substring(0, 19) + '...' } else { $Label }
            $iconXaml = New-PowerControlIconXaml -Icon $Icon -Size 18 -Margin '0,0,17,5'
            if (-not $iconXaml) { $iconXaml = "<TextBlock Text=`"$short`" FontSize=`"18`" Width=`"30`" Margin=`"0,-2,5,5`" HorizontalAlignment=`"Center`"/>" }
            return "                      <StackPanel Orientation=`"Horizontal`" Background=`"Transparent`">`r`n                          $iconXaml`r`n                          <TextBlock Text=`"$(& $escape $subLabel)`" FontSize=`"12`" Width=`"130`" Margin=`"5,0,0,0`"/>`r`n                      </StackPanel>"
        }
        'OrphanGrouped' {
            $iconXaml = New-PowerControlIconXaml -Icon $Icon -Size 18 -Margin '5,2,25,2'
            if (-not $iconXaml) { $iconXaml = "<TextBlock Text=`"$short`" FontSize=`"18`" Width=`"35`" Margin=`"0,-2,5,5`" HorizontalAlignment=`"Center`"/>" }
            return "              <StackPanel Orientation=`"Horizontal`" Background=`"Transparent`">`r`n                            $iconXaml`r`n                            <TextBlock Text=`"$(& $escape $header)`" FontSize=`"12`" Width=`"150`" Margin=`"5,0,0,0`"/>`r`n                    </StackPanel>"
        }
        'Orphan' {
            $iconXaml = New-PowerControlIconXaml -Icon $Icon -Size 18 -Margin '0,2,10,2'
            if (-not $iconXaml) { $iconXaml = "<TextBlock Text=`"$short`" FontSize=`"18`" Width=`"35`" Margin=`"-5,0,0,0`" HorizontalAlignment=`"Center`"/>" }
            return "              <StackPanel Orientation=`"Horizontal`" Background=`"Transparent`">`r`n                            <TextBlock Text=`"$(& $escape $header)`" FontSize=`"12`" Width=`"150`" Margin=`"5,0,0,0`"/>`r`n                        $iconXaml`r`n                    </StackPanel>"
        }
    }
}

function Add-XamlTreeView {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$StringBuilder,

        [Parameter(Mandatory)]
        [PSCustomObject]$ElementProperties
    )

    $foundChildren = [System.Collections.Generic.HashSet[string]]::new()
    $isClassic = $Global:PowerControl.General.Theme -eq 'Classic'

    $items = $PowerControl.JsonCache.PCtrlitems.where($ElementProperties.query)

    if($ElementProperties.groupby) {
        $items = $items | Group-Object -Property $ElementProperties.groupby
    }

    if ($items.Count -gt 0) {
        $items.foreach({
            $item = $_

            $label = if ($ElementProperties.groupby) { [string]$item.Name } else { [string]$item.Label }
            $tag = if ($label.Length -gt 29) { $label.Substring(0, 29) + "..." } else { $label }
            $ItemContainerStyle = if ($ElementProperties.Child_itemContainerStyle) { "ItemContainerStyle=""{DynamicResource $($ElementProperties.Child_itemContainerStyle)}""" } else { "" }
            $ItemStyle = if ($ElementProperties.Child_ItemStyle) { "Style=""{DynamicResource $($ElementProperties.Child_ItemStyle)}""" } else { "" }
            # the negative margin trick only exists in the Classic layout
            $Margin = if ($isClassic -and $ElementProperties.Child_itemContainerStyle) { "Margin=""$($ElementProperties.Child_Margin)""" } else { "" }
            $Uid = if ($item.id) { "$($item.id)" } else { "$($(New-Guid).Guid.Replace('-',''))" }
            $kind = if ($ElementProperties.groupby) { 'TopGrouped' } else { 'Top' }

            [void]$StringBuilder.AppendLine(@"
          <TreeViewItem Tag="$([System.Security.SecurityElement]::Escape($tag))" x:Uid="$Uid" Visibility="$($ElementProperties.ChilditemsVisibility)" $Margin $ItemContainerStyle $ItemStyle>
            <TreeViewItem.Header>
$(New-PowerControlTreeHeaderXaml -Label $label -Icon $item.Icon -Kind $kind)
                </TreeViewItem.Header>
"@)

            if($ElementProperties.sortby) {
                $ChildIds = $($item.group | Sort-Object -Property $ElementProperties.sortby).id
            }
            else {
                $ChildIds = $item.Children -split ',' | Where-Object { $_ }
            }

            $ChildIds.foreach({
                $ChildId = $_.Trim()
                [void]$foundChildren.Add($ChildId)

                $ChildItem = $PowerControl.JsonCache.PCtrlItems.where({ $_.id -eq $ChildId }, 'First')
                if ($ChildItem.Label) {
                    [void]$StringBuilder.AppendLine(@"
              <TreeViewItem Tag="$([System.Security.SecurityElement]::Escape([string]$ChildItem.Label))" x:Uid="$($ChildItem.ID)" $(if ($isClassic) { 'Margin="-5,0,0,0"' }) Visibility="$($ElementProperties.ChilditemsVisibility)">
                  <TreeViewItem.Header>
$(New-PowerControlTreeHeaderXaml -Label ([string]$ChildItem.Label) -Icon $ChildItem.Icon -Kind 'Child')
                  </TreeViewItem.Header>
              </TreeViewItem>
"@)
                }
            })

            [void]$StringBuilder.AppendLine(@"
          </TreeViewItem>
"@)
        })
    }

    <#
      Non-Categorized Items / Orphaned
    #>

    $items = $PowerControl.JsonCache.PCtrlitems.where($ElementProperties.query_orphaned) | Sort-Object -Property {
        if ($null -ne $_.DisplayCondition.SortOrder) { [int]$_.DisplayCondition.SortOrder }
        else { [int]::MaxValue }
    }

    if ($items.Count -gt 0) {
        $items.foreach({
            $item = $_
            $label = [string]$item.Label
            $tag = if ($label.Length -gt 29) { $label.Substring(0, 29) + "..." } else { $label }
            $Margin = if ($isClassic -and $ElementProperties.Child_itemContainerStyle) { " Margin=""$($ElementProperties.Child_Margin)""" } else { "" }
            $kind = if ($ElementProperties.groupby) { 'OrphanGrouped' } else { 'Orphan' }

            [void]$StringBuilder.AppendLine(@"
          <TreeViewItem Tag="$([System.Security.SecurityElement]::Escape($tag))" x:Uid="$($item.ID)" Visibility="$($ElementProperties.ChilditemsVisibility)"$Margin>
            <TreeViewItem.Header>
$(New-PowerControlTreeHeaderXaml -Label $label -Icon $item.Icon -Kind $kind)
                </TreeViewItem.Header>
            </TreeViewItem>
"@)
        })
    }
}


function Add-XamlMenuBar {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$StringBuilder,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$ElementProperties
    )
    
    $foundChildren = [System.Collections.Generic.HashSet[string]]::new()

    $items = $PowerControl.JsonCache.PCtrlitems.where($ElementProperties.query)
    
    if ($items.Count -gt 0) {
        $items.foreach({
            $item = $_
            
            $header = if ($item.Label.Length -gt 29) { $item.Label.Substring(0, 29) + "..." } else { $item.Label }
            $toolTip = if ($item.ToolTip) { " ToolTip=""$([System.Security.SecurityElement]::Escape($item.ToolTip))""" } else { "" }
            $inputGestureText = if ($item.KeyBinding.Key) { " InputGestureText=""$($item.KeyBinding.Modifiers)+$($item.KeyBinding.Key)""" } else { "" }          
            
            [void]$StringBuilder.AppendLine(@"
          <MenuItem Header="$([System.Security.SecurityElement]::Escape($header))"$inputGestureText x:Uid="$($(New-Guid).Guid.Replace('-',''))"$toolTip Visibility="$($ElementProperties.ChilditemsVisibility)">
"@)
            $MenuIds = $item.Children -split ',' | Where-Object { $_ }
            
            $MenuIds.foreach({
                $MenuId = $_
                [void]$foundChildren.Add($MenuId)
                
                $MenuItem = $PowerControl.JsonCache.PCtrlItems.where({ $_.id -eq $MenuId }, 'First')
                
                if ($MenuItem.Label) {
                    New-XamlMenuItem -Item $MenuItem -StringBuilder $StringBuilder -ElementProperties $ElementProperties
                }
            })

          [void]$StringBuilder.AppendLine(@"
          </MenuItem>  
"@)
        })
    }
    
    <#
      Non-Categorized Items / Orphaned
    #>
    
    $items = $PowerControl.JsonCache.PCtrlitems.where($ElementProperties.query_orphaned) | Sort-Object -Property {
        if ($null -ne $_.DisplayCondition.SortOrder) { [int]$_.DisplayCondition.SortOrder }
        else { [int]::MaxValue }
    }
    
    if ($items.Count -gt 0) {
        [void]$StringBuilder.AppendLine(@"
          <MenuItem Header="Other" x:Uid="$($(New-Guid).Guid.Replace('-',''))">
"@)

        $items.foreach({
            New-XamlMenuItem -Item $_ -StringBuilder $StringBuilder -ElementProperties $ElementProperties
        })
        
         [void]$StringBuilder.AppendLine(@"
          </MenuItem>  
"@)
    }
    
}    

function Add-XamlContextMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$StringBuilder,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$ElementProperties
    )

    <#
      Categorized Items / Non-Orphaned
    #>
    
    $items = $PowerControl.JsonCache.PCtrlitems.where($ElementProperties.query) | Group-Object -Property { $_.DisplayCondition.Categorie }
    
    if ($items.Count -gt 0) {
        $items.foreach({
            $group = $_
            
            [void]$StringBuilder.AppendLine(@"
          <MenuItem Header="$([System.Security.SecurityElement]::Escape($group.name))" x:Uid="$($(New-Guid).Guid.Replace('-',''))" Visibility="$($ElementProperties.ChilditemsVisibility)">
"@)
            $groupItems = $group.Group | Sort-Object -Property {
                if ($null -ne $_.DisplayCondition.SortOrder) { [int]$_.DisplayCondition.SortOrder }
                else { [int]::MaxValue }
            }
            
            $groupItems.foreach({
                New-XamlMenuItem -Item $_ -StringBuilder $StringBuilder -ElementProperties $ElementProperties
            })

          [void]$StringBuilder.AppendLine(@"
          </MenuItem>  
"@)
        })
    }
    
    <#
      Non-Categorized Items / Orphaned
    #>
    
    $items = $PowerControl.JsonCache.PCtrlitems.where($ElementProperties.query_orphaned) | Sort-Object -Property {
        if ($null -ne $_.DisplayCondition.SortOrder) { [int]$_.DisplayCondition.SortOrder }
        else { [int]::MaxValue }
    }
    
    if ($items.Count -gt 0) {
        $items.foreach({
            New-XamlMenuItem -Item $_ -StringBuilder $StringBuilder -ElementProperties $ElementProperties
        })
    }
    
}    

function New-XamlMenuItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject]$Item,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$StringBuilder,        
        
        [Parameter(Mandatory)]
        [PSCustomObject]$ElementProperties
    )

    $header = if ($Item.Label.Length -gt 29) { $Item.Label.Substring(0, 29) + "..." } else { $Item.Label }
    $toolTip = if ($Item.ToolTip) { " ToolTip=""$([System.Security.SecurityElement]::Escape($Item.ToolTip))""" } else { "" }
    $inputGestureText = if ($Item.KeyBinding.Key) { " InputGestureText=""$($Item.KeyBinding.Modifiers)+$($Item.KeyBinding.Key)""" } else { "" }

    [void]$StringBuilder.AppendLine(@"
            <MenuItem Header="$([System.Security.SecurityElement]::Escape($header))"$inputGestureText x:Uid="$($Item.ID)"$toolTip Visibility="$($ElementProperties.ChilditemsVisibility)">
"@)

    $iconPath = Join-Path -Path $PowerControl.General.CurrentPath -ChildPath "icons\$($Item.Icon)"
    if ($Item.Icon -and (Test-Path -Path $iconPath)) {
        $iconUri = [Uri]::new($iconPath).AbsoluteUri
        [void]$StringBuilder.AppendLine(@"
                <MenuItem.Icon>$(New-PowerControlIconXaml -Icon $Item.Icon -Size 16 -Margin "0")</MenuItem.Icon>
"@)
    }

    [void]$StringBuilder.AppendLine(@"
            </MenuItem>
"@)
}


function Get-PowerControlNavigationDefinition {
    <#
      .SYNOPSIS
      The definitions of the four context menus, the menu bar and the two tree views.

      .DESCRIPTION
      Used at start-up to build the window XAML and by Update-PowerControlNavigation to rebuild
      the navigation from the engine XML without a restart. The query/query_orphaned script blocks
      run inside Add-XamlMenuBar / Add-XamlTreeView / Add-XamlContextMenu.
    #>
    [CmdletBinding()]
    param()

    [ordered]@{
        StatusDataGridMenu = @{
            Name = 'StatusDataGridMenu'
            ChilditemsVisibility = "Hidden"
            query = {($_.type -eq 'Thread') -and ($null -ne $_.DisplayCondition.Categorie)}
            query_orphaned = {($_.type -eq 'Thread') -and ($null -eq $_.DisplayCondition.Categorie)}
        }
        OutputGridMenu = @{
            Name = 'OutputGridMenu'
            ChilditemsVisibility = "Hidden"
            query = {($_.type -ne 'Thread' -and $_.type -ne 'EditTreeView') -and ($null -ne $_.DisplayCondition.Categorie)}
            query_orphaned = {($_.type -ne 'Thread' -and $_.type -ne 'EditTreeView') -and ($null -eq $_.DisplayCondition.Categorie) -and ($null -ne $_.DisplayCondition.Code)}
        }
        TreeViewMenu = @{
            Name = 'TreeViewMenu'
            ChilditemsVisibility = "Visible"
            query = {($_.type -eq 'EditTreeView') -and ($null -ne $_.DisplayCondition.Categorie)}
            query_orphaned = {($_.type -eq 'EditTreeView') -and ($null -eq $_.DisplayCondition.Categorie)}
        }
        OutputGridHeaderMenu = @{
            Name = 'OutputGridHeaderMenu'
            ChilditemsVisibility = "Visible"
            query = {($_.type -eq 'OutputGridHeaderMenu') -and ($null -ne $_.DisplayCondition.Categorie)}
            query_orphaned = {($_.type -eq 'OutputGridHeaderMenu') -and ($null -eq $_.DisplayCondition.Categorie)}
        }
        MenuBar = @{
            Name = 'MenuBar'
            ChilditemsVisibility = "Visible"
            query =  {($_.type -eq 'MenuBar') -and ($null -ne $_.Children)}
            query_orphaned = {($_.type -eq 'MenuBar') -and (-not $foundChildren.Contains($_.id)) -and ($null -eq $_.Children)}
        }
        NavigationMenuTree = @{
            Name = 'NavigationMenuTree'
            ChilditemsVisibility = 'Visible'
            Visibility = 'Collapsed'   # the rail is shown first; the flyout/pinned state shows the tree
            query = {($_.type -eq 'Menu') -and ($null -ne $_.Children)}
            query_orphaned =  {($_.type -eq 'Menu') -and (-not $foundChildren.Contains($_.id)) -and ($null -eq $_.Children)}
        }
        ActionMenuTree = @{
            Name = 'ActionMenuTree'
            ChilditemsVisibility = 'Hidden'
            query = {($null -ne $_.DisplayCondition.Categorie) -and ($_.type -ne 'Thread' -and $_.type -ne 'EditTreeView')}
            query_orphaned =  {($null -eq $_.DisplayCondition.Categorie) -and ($null -ne $_.DisplayCondition.Code) -and ($_.type -ne 'Thread' -and $_.type -ne 'EditTreeView')}
            groupby = { $_.DisplayCondition.Categorie }
            sortby = @{
                Expression = { 
                    if ($null -ne $_.DisplayCondition.SortOrder) {
                        return [int]$_.DisplayCondition.SortOrder
                    }
                    return [int]::MaxValue
                }
                Ascending = $true
            }
        }
    }
}
