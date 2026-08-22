function Show-TSMainWindow {
    <#
    .SYNOPSIS
        Renders the full Terminal Studio interactive dashboard as a desktop window.

    .DESCRIPTION
        Chris Titus WinUtil-style desktop dashboard for Terminal Studio.
        Provides visual interactive management across all capabilities:
          - Configure & Tweaks: categorized cards for appearance, prompt, packages, and modules
          - Backup & Restore: one-click Apply with automatic backups, and one-click rollback
          - Doctor Diagnostics: visual health checks with badges (PASS, WARN, FAIL) and fixes
          - Journal & Backups: view historical change records and displaced files
          - Live Output Console: real-time feedback during operations

    .PARAMETER DesiredStatePath
        Path to the desired-state document.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [string] $DesiredStatePath
    )

    if (-not $IsWindows) {
        Write-Host '  The GUI dashboard requires Windows.'
        return
    }

    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apartment -ne [System.Threading.ApartmentState]::STA) {
        Write-Warning 'Show-TSMainWindow requires an STA thread. Relaunching in STA mode...'
        $entryScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\ts.ps1'
        & pwsh -STA -NoLogo -NoProfile -File $entryScript gui
        return
    }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    }
    catch {
        Write-Host "  WPF is not available on this system: $($_.Exception.Message)"
        return
    }

    $commonArgs = @{}
    if ($DesiredStatePath) {
        $commonArgs['DesiredStatePath'] = $DesiredStatePath
    }

    # Visual Theme Palette (Andalus Dark Modern)
    $brushes = New-Object System.Windows.Media.BrushConverter
    $bgDark      = $brushes.ConvertFromString('#FF0B1220')
    $bgCard      = $brushes.ConvertFromString('#FF141C2E')
    $bgCardAlt   = $brushes.ConvertFromString('#FF1A2338')
    $bgConsole   = $brushes.ConvertFromString('#FF060A12')
    $borderDark  = $brushes.ConvertFromString('#FF2A364F')
    $textLight   = $brushes.ConvertFromString('#FFEDE0C8')
    $textMuted   = $brushes.ConvertFromString('#FF8A93A8')
    $accentGold  = $brushes.ConvertFromString('#FFD4A537')
    $accentBlue  = $brushes.ConvertFromString('#FF2563EB')
    $accentGreen = $brushes.ConvertFromString('#FF16A34A')
    $accentRed   = $brushes.ConvertFromString('#FFDC2626')
    $accentWarn  = $brushes.ConvertFromString('#FFD97706')

    # Main Window
    $window = New-Object System.Windows.Window
    $window.Title = 'Terminal Studio - Dashboard'
    $window.Width = 980
    $window.Height = 750
    $window.MinWidth = 850
    $window.MinHeight = 650
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $window.Background = $bgDark
    $window.Foreground = $textLight
    $window.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'

    # Root DockPanel
    $root = New-Object System.Windows.Controls.DockPanel
    $root.Margin = New-Object System.Windows.Thickness 16

    # =========================================================================
    # HEADER SECTION
    # =========================================================================
    $headerPanel = New-Object System.Windows.Controls.DockPanel
    $headerPanel.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14
    [System.Windows.Controls.DockPanel]::SetDock($headerPanel, [System.Windows.Controls.Dock]::Top)

    $titleStack = New-Object System.Windows.Controls.StackPanel
    $titleStack.Orientation = [System.Windows.Controls.Orientation]::Vertical

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = 'TERMINAL STUDIO'
    $titleBlock.FontSize = 20
    $titleBlock.FontWeight = [System.Windows.FontWeights]::Bold
    $titleBlock.Foreground = $accentGold
    $null = $titleStack.Children.Add($titleBlock)

    $subtitleBlock = New-Object System.Windows.Controls.TextBlock
    $subtitleBlock.Text = 'Reproducible, Versioned, Reversible Windows Terminal Environment'
    $subtitleBlock.FontSize = 12
    $subtitleBlock.Foreground = $textMuted
    $null = $titleStack.Children.Add($subtitleBlock)

    $null = $headerPanel.Children.Add($titleStack)

    $badgeStack = New-Object System.Windows.Controls.StackPanel
    $badgeStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $badgeStack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

    $versionBadge = New-Object System.Windows.Controls.Border
    $versionBadge.Background = $bgCardAlt
    $versionBadge.BorderBrush = $borderDark
    $versionBadge.BorderThickness = New-Object System.Windows.Thickness 1
    $versionBadge.CornerRadius = New-Object System.Windows.CornerRadius 6
    $versionBadge.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
    $versionBadge.Margin = New-Object System.Windows.Thickness 6, 0, 0, 0

    $versionText = New-Object System.Windows.Controls.TextBlock
    $versionText.Text = 'v0.3.0'
    $versionText.FontSize = 11
    $versionText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $versionText.Foreground = $accentGold
    $versionBadge.Child = $versionText
    $null = $badgeStack.Children.Add($versionBadge)

    $null = $headerPanel.Children.Add($badgeStack)
    $null = $root.Children.Add($headerPanel)

    # =========================================================================
    # STATUS BAR / FOOTER
    # =========================================================================
    $statusBar = New-Object System.Windows.Controls.DockPanel
    $statusBar.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    [System.Windows.Controls.DockPanel]::SetDock($statusBar, [System.Windows.Controls.Dock]::Bottom)

    $statusLeft = New-Object System.Windows.Controls.TextBlock
    $statusLeft.Text = 'Ready'
    $statusLeft.FontSize = 11
    $statusLeft.Foreground = $textMuted
    $null = $statusBar.Children.Add($statusLeft)

    $statusRight = New-Object System.Windows.Controls.TextBlock
    $statusRight.Text = 'PowerShell 7 (STA) | Hash-Guaranteed Backups'
    $statusRight.FontSize = 11
    $statusRight.Foreground = $textMuted
    $statusRight.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $null = $statusBar.Children.Add($statusRight)

    $null = $root.Children.Add($statusBar)

    # =========================================================================
    # LIVE ACTION CONSOLE (BOTTOM EXPANDABLE CARD)
    # =========================================================================
    $consoleBorder = New-Object System.Windows.Controls.Border
    $consoleBorder.Background = $bgConsole
    $consoleBorder.BorderBrush = $borderDark
    $consoleBorder.BorderThickness = New-Object System.Windows.Thickness 1
    $consoleBorder.CornerRadius = New-Object System.Windows.CornerRadius 6
    $consoleBorder.Height = 150
    $consoleBorder.Margin = New-Object System.Windows.Thickness 0, 10, 0, 0
    [System.Windows.Controls.DockPanel]::SetDock($consoleBorder, [System.Windows.Controls.Dock]::Bottom)

    $consoleDock = New-Object System.Windows.Controls.DockPanel

    $consoleHeader = New-Object System.Windows.Controls.DockPanel
    $consoleHeader.Background = $bgCardAlt
    $consoleHeader.Padding = New-Object System.Windows.Thickness 8, 4, 8, 4
    [System.Windows.Controls.DockPanel]::SetDock($consoleHeader, [System.Windows.Controls.Dock]::Top)

    $consoleTitle = New-Object System.Windows.Controls.TextBlock
    $consoleTitle.Text = '⚡ Action Output Console'
    $consoleTitle.FontSize = 11
    $consoleTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
    $consoleTitle.Foreground = $accentGold
    $null = $consoleHeader.Children.Add($consoleTitle)

    $clearBtn = New-Object System.Windows.Controls.Button
    $clearBtn.Content = 'Clear'
    $clearBtn.FontSize = 10
    $clearBtn.Padding = New-Object System.Windows.Thickness 8, 1, 8, 1
    $clearBtn.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $null = $consoleHeader.Children.Add($clearBtn)

    $null = $consoleDock.Children.Add($consoleHeader)

    $consoleScroll = New-Object System.Windows.Controls.ScrollViewer
    $consoleScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

    $consoleText = New-Object System.Windows.Controls.TextBox
    $consoleText.IsReadOnly = $true
    $consoleText.Background = $bgConsole
    $consoleText.Foreground = $textLight
    $consoleText.BorderThickness = New-Object System.Windows.Thickness 0
    $consoleText.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas, Cascadia Mono, Courier New'
    $consoleText.FontSize = 11
    $consoleText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $consoleText.Margin = New-Object System.Windows.Thickness 8, 6, 8, 6
    $consoleText.Text = "Terminal Studio Dashboard ready.`nSelect a tab and execute actions with real-time feedback.`n"
    $consoleScroll.Content = $consoleText

    $null = $consoleDock.Children.Add($consoleScroll)
    $consoleBorder.Child = $consoleDock

    $null = $root.Children.Add($consoleBorder)

    # Helper scriptblock to log output to the console
    $logOutput = {
        param([string] $msg)
        $timestamp = (Get-Date).ToString('HH:mm:ss')
        $consoleText.AppendText("[$timestamp] $msg`n")
        $consoleScroll.ScrollToEnd()
    }

    $null = $clearBtn.Add_Click({
        $consoleText.Text = ''
    })

    # =========================================================================
    # MAIN TAB CONTROL
    # =========================================================================
    $tabControl = New-Object System.Windows.Controls.TabControl
    $tabControl.Background = $bgDark
    $tabControl.BorderBrush = $borderDark
    $tabControl.BorderThickness = New-Object System.Windows.Thickness 1

    # -------------------------------------------------------------------------
    # TAB 1: 🎛️ CONFIGURE & TWEAKS
    # -------------------------------------------------------------------------
    $tabTweaks = New-Object System.Windows.Controls.TabItem
    $tabTweaks.Header = '  🎛️ Configure & Tweaks  '
    $tabTweaks.FontSize = 13

    $tweaksDock = New-Object System.Windows.Controls.DockPanel
    $tweaksDock.Margin = New-Object System.Windows.Thickness 10

    # Top Tweaks Action Bar (Presets & Save)
    $tweaksActionBar = New-Object System.Windows.Controls.DockPanel
    $tweaksActionBar.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    [System.Windows.Controls.DockPanel]::SetDock($tweaksActionBar, [System.Windows.Controls.Dock]::Top)

    $presetStack = New-Object System.Windows.Controls.StackPanel
    $presetStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    $btnRecommended = New-Object System.Windows.Controls.Button
    $btnRecommended.Content = '⭐ Select Recommended'
    $btnRecommended.Padding = New-Object System.Windows.Thickness 10, 5, 10, 5
    $btnRecommended.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $null = $presetStack.Children.Add($btnRecommended)

    $btnFast = New-Object System.Windows.Controls.Button
    $btnFast.Content = '⚡ Minimal / Fast Startup'
    $btnFast.Padding = New-Object System.Windows.Thickness 10, 5, 10, 5
    $btnFast.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $null = $presetStack.Children.Add($btnFast)

    $btnSelectAll = New-Object System.Windows.Controls.Button
    $btnSelectAll.Content = 'Select All'
    $btnSelectAll.Padding = New-Object System.Windows.Thickness 10, 5, 10, 5
    $null = $presetStack.Children.Add($btnSelectAll)

    $null = $tweaksActionBar.Children.Add($presetStack)

    $saveStack = New-Object System.Windows.Controls.StackPanel
    $saveStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $saveStack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

    $btnSaveOnly = New-Object System.Windows.Controls.Button
    $btnSaveOnly.Content = '💾 Save Configuration'
    $btnSaveOnly.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5
    $btnSaveOnly.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $btnSaveOnly.Background = $accentBlue
    $btnSaveOnly.Foreground = [System.Windows.Media.Brushes]::White
    $null = $saveStack.Children.Add($btnSaveOnly)

    $btnSaveApply = New-Object System.Windows.Controls.Button
    $btnSaveApply.Content = '⚡ Save & Apply Now'
    $btnSaveApply.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5
    $btnSaveApply.Background = $accentGreen
    $btnSaveApply.Foreground = [System.Windows.Media.Brushes]::White
    $btnSaveApply.FontWeight = [System.Windows.FontWeights]::Bold
    $null = $saveStack.Children.Add($btnSaveApply)

    $null = $tweaksActionBar.Children.Add($saveStack)
    $null = $tweaksDock.Children.Add($tweaksActionBar)

    # Scrollable Controls Stack
    $tweaksScroll = New-Object System.Windows.Controls.ScrollViewer
    $tweaksScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

    $tweaksStack = New-Object System.Windows.Controls.StackPanel
    $tweaksScroll.Content = $tweaksStack

    # Load Controls
    $controls = @(Get-TSControl @commonArgs)
    $controlBindings = [System.Collections.Generic.List[object]]::new()
    $lastGroup = ''

    foreach ($item in $controls) {
        if ($item.Group -ne $lastGroup) {
            $grpHeader = New-Object System.Windows.Controls.TextBlock
            $grpHeader.Text = [string] $item.Group
            $grpHeader.Foreground = $accentGold
            $grpHeader.FontSize = 14
            $grpHeader.FontWeight = [System.Windows.FontWeights]::SemiBold
            $grpHeader.Margin = New-Object System.Windows.Thickness 0, 12, 0, 6
            $null = $tweaksStack.Children.Add($grpHeader)
            $lastGroup = $item.Group
        }

        $rowCard = New-Object System.Windows.Controls.Border
        $rowCard.Background = $bgCard
        $rowCard.BorderBrush = $borderDark
        $rowCard.BorderThickness = New-Object System.Windows.Thickness 1
        $rowCard.Padding = New-Object System.Windows.Thickness 10, 7, 10, 7
        $rowCard.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
        $rowCard.CornerRadius = New-Object System.Windows.CornerRadius 5

        $cell = New-Object System.Windows.Controls.StackPanel
        $rowCard.Child = $cell

        $caption = [string] $item.Label
        if ($item.CostMs -gt 0) {
            $caption = "$caption  ($($item.CostMs) ms startup)"
        }

        if ($item.Type -eq 'checkbox') {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $caption
            $cb.Foreground = $textLight
            $cb.FontSize = 12
            $cb.IsChecked = [bool] $item.Value
            $null = $cell.Children.Add($cb)
            $element = $cb
        }
        else {
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = $caption
            $lbl.Foreground = $textLight
            $lbl.FontSize = 12
            $lbl.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
            $null = $cell.Children.Add($lbl)

            $cmb = New-Object System.Windows.Controls.ComboBox
            $cmb.FontSize = 12
            $cmb.Height = 26
            $selected = -1
            $position = 0

            foreach ($opt in @($item.Options)) {
                $null = $cmb.Items.Add([string] $opt.Label)
                if ([string] $opt.Value -eq [string] $item.Value) {
                    $selected = $position
                }
                $position++
            }

            $cmb.SelectedIndex = $selected
            $null = $cell.Children.Add($cmb)
            $element = $cmb
        }

        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = [string] $item.Help
        $hint.Foreground = $textMuted
        $hint.FontSize = 10.5
        $hint.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $hint.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
        $null = $cell.Children.Add($hint)

        if (-not $item.Bound) {
            $element.IsEnabled = $false
            $hint.Text = 'Not bound: targets missing desired state. ' + $hint.Text
        }

        $controlBindings.Add([pscustomobject] @{ Item = $item; Element = $element })
        $null = $tweaksStack.Children.Add($rowCard)
    }

    # Preset handlers
    $null = $btnRecommended.Add_Click({
        foreach ($b in $controlBindings) {
            if ($b.Item.Type -eq 'checkbox' -and $b.Element.IsEnabled) {
                $b.Element.IsChecked = ($b.Item.Id -ne 'modPoshGit')
            }
        }
        & $logOutput 'Applied preset: Recommended Settings.'
    })

    $null = $btnFast.Add_Click({
        foreach ($b in $controlBindings) {
            if ($b.Item.Type -eq 'checkbox' -and $b.Element.IsEnabled) {
                if ($b.Item.CostMs -gt 200) {
                    $b.Element.IsChecked = $false
                }
            }
        }
        & $logOutput 'Applied preset: Minimal / Fast Startup (disabled heavy profile modules).'
    })

    $null = $btnSelectAll.Add_Click({
        foreach ($b in $controlBindings) {
            if ($b.Item.Type -eq 'checkbox' -and $b.Element.IsEnabled) {
                $b.Element.IsChecked = $true
            }
        }
        & $logOutput 'Selected all available checkboxes.'
    })

    # Save logic
    $saveCurrentConfig = {
        $changedList = [System.Collections.Generic.List[object]]::new()
        foreach ($b in $controlBindings) {
            if (-not $b.Item.Bound) { continue }
            if ($b.Item.Type -eq 'checkbox') {
                $val = [bool] $b.Element.IsChecked
                if ($val -ne [bool] $b.Item.Value) {
                    $b.Item.Value = $val
                    $changedList.Add($b.Item)
                }
            }
            else {
                $idx = [int] $b.Element.SelectedIndex
                $opts = @($b.Item.Options)
                if ($idx -ge 0 -and $idx -lt $opts.Count) {
                    if ([string] $opts[$idx].Value -ne [string] $b.Item.Value) {
                        $b.Item.Value = $opts[$idx].Value
                        $changedList.Add($b.Item)
                    }
                }
            }
        }

        if ($changedList.Count -eq 0) {
            & $logOutput 'No changes to save.'
            return $false
        }

        & $logOutput "Saving $($changedList.Count) configuration item(s)..."
        foreach ($c in $changedList) {
            Set-TSControl -Control $c @commonArgs | Out-Null
            & $logOutput "  -> Updated $($c.Label) to $($c.Value)"
        }
        & $logOutput "Successfully saved $($changedList.Count) setting(s) to desired state."
        return $true
    }

    $null = $btnSaveOnly.Add_Click({
        & $saveCurrentConfig | Out-Null
    })

    $null = $btnSaveApply.Add_Click({
        & $saveCurrentConfig | Out-Null
        & $logOutput 'Running Apply now...'
        $results = @(Invoke-TSApply @commonArgs)
        foreach ($r in $results) {
            & $logOutput "[$($r.Status)] $($r.Name): $($r.Actual)"
        }
        & $logOutput 'Apply complete!'
    })

    $null = $tweaksDock.Children.Add($tweaksScroll)
    $tabTweaks.Content = $tweaksDock
    $null = $tabControl.Items.Add($tabTweaks)

    # -------------------------------------------------------------------------
    # TAB 2: 🔄 BACKUP, APPLY & RESTORE
    # -------------------------------------------------------------------------
    $tabOperations = New-Object System.Windows.Controls.TabItem
    $tabOperations.Header = '  🔄 Backup, Apply & Restore  '
    $tabOperations.FontSize = 13

    $opsDock = New-Object System.Windows.Controls.DockPanel
    $opsDock.Margin = New-Object System.Windows.Thickness 14

    $opsScroll = New-Object System.Windows.Controls.ScrollViewer
    $opsScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

    $opsStack = New-Object System.Windows.Controls.StackPanel
    $opsScroll.Content = $opsStack

    # Info banner
    $infoCard = New-Object System.Windows.Controls.Border
    $infoCard.Background = $bgCard
    $infoCard.BorderBrush = $borderDark
    $infoCard.BorderThickness = New-Object System.Windows.Thickness 1
    $infoCard.CornerRadius = New-Object System.Windows.CornerRadius 6
    $infoCard.Padding = New-Object System.Windows.Thickness 14
    $infoCard.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14

    $infoText = New-Object System.Windows.Controls.TextBlock
    $infoText.Text = "Terminal Studio guarantees safety: every file replaced by Apply is automatically backed up with timestamps, and every action is recorded in an append-only change journal. Uninstall replays the journal backwards to cleanly restore your original environment."
    $infoText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $infoText.Foreground = $textLight
    $infoText.FontSize = 12
    $infoCard.Child = $infoText
    $null = $opsStack.Children.Add($infoCard)

    # Apply Section
    $applyHeader = New-Object System.Windows.Controls.TextBlock
    $applyHeader.Text = 'Apply Desired State'
    $applyHeader.FontSize = 14
    $applyHeader.FontWeight = [System.Windows.FontWeights]::SemiBold
    $applyHeader.Foreground = $accentGold
    $applyHeader.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
    $null = $opsStack.Children.Add($applyHeader)

    $applyCard = New-Object System.Windows.Controls.Border
    $applyCard.Background = $bgCard
    $applyCard.BorderBrush = $borderDark
    $applyCard.BorderThickness = New-Object System.Windows.Thickness 1
    $applyCard.CornerRadius = New-Object System.Windows.CornerRadius 6
    $applyCard.Padding = New-Object System.Windows.Thickness 12
    $applyCard.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14

    $applyCardStack = New-Object System.Windows.Controls.StackPanel

    $applyDesc = New-Object System.Windows.Controls.TextBlock
    $applyDesc.Text = "Converges managed files (Windows Terminal fragment, prompt theme, shell profile) toward desired state. Creates automatic backups before overwriting."
    $applyDesc.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $applyDesc.Foreground = $textMuted
    $applyDesc.FontSize = 11.5
    $applyDesc.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    $null = $applyCardStack.Children.Add($applyDesc)

    $applyBtnStack = New-Object System.Windows.Controls.StackPanel
    $applyBtnStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    $btnApply = New-Object System.Windows.Controls.Button
    $btnApply.Content = '🚀 Apply Desired State'
    $btnApply.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6
    $btnApply.Background = $accentGreen
    $btnApply.Foreground = [System.Windows.Media.Brushes]::White
    $btnApply.FontWeight = [System.Windows.FontWeights]::Bold
    $btnApply.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
    $null = $applyBtnStack.Children.Add($btnApply)

    $btnApplyWhatIf = New-Object System.Windows.Controls.Button
    $btnApplyWhatIf.Content = '🔍 Preview Apply (-WhatIf)'
    $btnApplyWhatIf.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6
    $null = $applyBtnStack.Children.Add($btnApplyWhatIf)

    $null = $applyCardStack.Children.Add($applyBtnStack)
    $applyCard.Child = $applyCardStack
    $null = $opsStack.Children.Add($applyCard)

    # Restore / Rollback Section
    $restoreHeader = New-Object System.Windows.Controls.TextBlock
    $restoreHeader.Text = 'Restore & Rollback (Uninstall)'
    $restoreHeader.FontSize = 14
    $restoreHeader.FontWeight = [System.Windows.FontWeights]::SemiBold
    $restoreHeader.Foreground = $accentGold
    $restoreHeader.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
    $null = $opsStack.Children.Add($restoreHeader)

    $restoreCard = New-Object System.Windows.Controls.Border
    $restoreCard.Background = $bgCard
    $restoreCard.BorderBrush = $borderDark
    $restoreCard.BorderThickness = New-Object System.Windows.Thickness 1
    $restoreCard.CornerRadius = New-Object System.Windows.CornerRadius 6
    $restoreCard.Padding = New-Object System.Windows.Thickness 12
    $restoreCard.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14

    $restoreCardStack = New-Object System.Windows.Controls.StackPanel

    $restoreDesc = New-Object System.Windows.Controls.TextBlock
    $restoreDesc.Text = "Replays the change journal backwards (newest record first) and restores backed-up files. Refuses to touch files that were edited manually after apply."
    $restoreDesc.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $restoreDesc.Foreground = $textMuted
    $restoreDesc.FontSize = 11.5
    $restoreDesc.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    $null = $restoreCardStack.Children.Add($restoreDesc)

    $restoreBtnStack = New-Object System.Windows.Controls.StackPanel
    $restoreBtnStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    $btnRestore = New-Object System.Windows.Controls.Button
    $btnRestore.Content = '⏪ One-Click Restore / Rollback'
    $btnRestore.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6
    $btnRestore.Background = $accentRed
    $btnRestore.Foreground = [System.Windows.Media.Brushes]::White
    $btnRestore.FontWeight = [System.Windows.FontWeights]::Bold
    $btnRestore.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
    $null = $restoreBtnStack.Children.Add($btnRestore)

    $btnRestoreWhatIf = New-Object System.Windows.Controls.Button
    $btnRestoreWhatIf.Content = '🔎 Preview Rollback (-WhatIf)'
    $btnRestoreWhatIf.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6
    $null = $restoreBtnStack.Children.Add($btnRestoreWhatIf)

    $null = $restoreCardStack.Children.Add($restoreBtnStack)
    $restoreCard.Child = $restoreCardStack
    $null = $opsStack.Children.Add($restoreCard)

    # Action event bindings
    $null = $btnApply.Add_Click({
        & $logOutput 'Starting Apply...'
        $results = @(Invoke-TSApply @commonArgs)
        foreach ($r in $results) {
            & $logOutput "[$($r.Status)] $($r.Name): $($r.Actual)"
        }
        & $logOutput 'Apply execution finished.'
    })

    $null = $btnApplyWhatIf.Add_Click({
        & $logOutput 'Running Apply dry-run (-WhatIf)...'
        $results = @(Invoke-TSApply @commonArgs -WhatIf)
        foreach ($r in $results) {
            & $logOutput "[$($r.Status)] $($r.Name): $($r.Actual)"
        }
        & $logOutput 'Dry-run finished. Nothing was modified.'
    })

    $null = $btnRestore.Add_Click({
        & $logOutput 'Starting Rollback / Restore (replaying change journal)...'
        $results = @(Invoke-TSUninstall @commonArgs)
        foreach ($r in $results) {
            & $logOutput "[$($r.Status)] $($r.Name): $($r.Actual)"
        }
        & $logOutput 'Rollback finished.'
    })

    $null = $btnRestoreWhatIf.Add_Click({
        & $logOutput 'Previewing Rollback (-WhatIf)...'
        $results = @(Invoke-TSUninstall @commonArgs -WhatIf)
        foreach ($r in $results) {
            & $logOutput "[$($r.Status)] $($r.Name): $($r.Actual)"
        }
        & $logOutput 'Rollback preview complete. Nothing was changed.'
    })

    $null = $opsDock.Children.Add($opsScroll)
    $tabOperations.Content = $opsDock
    $null = $tabControl.Items.Add($tabOperations)

    # -------------------------------------------------------------------------
    # TAB 3: 🩺 DOCTOR & DIAGNOSTICS
    # -------------------------------------------------------------------------
    $tabDoctor = New-Object System.Windows.Controls.TabItem
    $tabDoctor.Header = '  🩺 Doctor & Diagnostics  '
    $tabDoctor.FontSize = 13

    $doctorDock = New-Object System.Windows.Controls.DockPanel
    $doctorDock.Margin = New-Object System.Windows.Thickness 10

    $doctorTop = New-Object System.Windows.Controls.DockPanel
    $doctorTop.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    [System.Windows.Controls.DockPanel]::SetDock($doctorTop, [System.Windows.Controls.Dock]::Top)

    $btnRunDoctor = New-Object System.Windows.Controls.Button
    $btnRunDoctor.Content = '🩺 Run Diagnostic Check'
    $btnRunDoctor.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6
    $btnRunDoctor.Background = $accentGold
    $btnRunDoctor.Foreground = [System.Windows.Media.Brushes]::Black
    $btnRunDoctor.FontWeight = [System.Windows.FontWeights]::Bold
    $null = $doctorTop.Children.Add($btnRunDoctor)

    $doctorSummary = New-Object System.Windows.Controls.TextBlock
    $doctorSummary.Text = 'Click Run Diagnostic Check to inspect system health.'
    $doctorSummary.Foreground = $textMuted
    $doctorSummary.FontSize = 12
    $doctorSummary.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $doctorSummary.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $null = $doctorTop.Children.Add($doctorSummary)

    $null = $doctorDock.Children.Add($doctorTop)

    $doctorScroll = New-Object System.Windows.Controls.ScrollViewer
    $doctorScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

    $doctorStack = New-Object System.Windows.Controls.StackPanel
    $doctorScroll.Content = $doctorStack

    $null = $btnRunDoctor.Add_Click({
        & $logOutput 'Running Doctor diagnostics...'
        $doctorStack.Children.Clear()

        $results = @(Invoke-TSDoctor @commonArgs)
        $passCount = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
        $warnCount = @($results | Where-Object { $_.Status -eq 'Warn' }).Count
        $failCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
        $skipCount = @($results | Where-Object { $_.Status -eq 'Skip' }).Count

        $doctorSummary.Text = "$passCount Passed | $warnCount Warnings | $failCount Failed | $skipCount Skipped"
        & $logOutput "Doctor report: $passCount Passed, $warnCount Warnings, $failCount Failed."

        foreach ($r in $results) {
            $badgeBg = switch ($r.Status) {
                'Pass' { $accentGreen }
                'Warn' { $accentWarn }
                'Fail' { $accentRed }
                default { $borderDark }
            }

            $card = New-Object System.Windows.Controls.Border
            $card.Background = $bgCard
            $card.BorderBrush = $borderDark
            $card.BorderThickness = New-Object System.Windows.Thickness 1
            $card.CornerRadius = New-Object System.Windows.CornerRadius 5
            $card.Padding = New-Object System.Windows.Thickness 10, 6, 10, 6
            $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4

            $cStack = New-Object System.Windows.Controls.StackPanel

            $hDock = New-Object System.Windows.Controls.DockPanel

            $badge = New-Object System.Windows.Controls.Border
            $badge.Background = $badgeBg
            $badge.CornerRadius = New-Object System.Windows.CornerRadius 4
            $badge.Padding = New-Object System.Windows.Thickness 6, 2, 6, 2
            $badge.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
            [System.Windows.Controls.DockPanel]::SetDock($badge, [System.Windows.Controls.Dock]::Left)

            $bText = New-Object System.Windows.Controls.TextBlock
            $bText.Text = [string] $r.Status
            $bText.FontSize = 10
            $bText.FontWeight = [System.Windows.FontWeights]::Bold
            $bText.Foreground = [System.Windows.Media.Brushes]::White
            $badge.Child = $bText
            $null = $hDock.Children.Add($badge)

            $nameText = New-Object System.Windows.Controls.TextBlock
            $nameText.Text = [string] $r.Name
            $nameText.FontWeight = [System.Windows.FontWeights]::SemiBold
            $nameText.Foreground = $textLight
            $nameText.FontSize = 12
            $null = $hDock.Children.Add($nameText)

            $null = $cStack.Children.Add($hDock)

            $actText = New-Object System.Windows.Controls.TextBlock
            $actText.Text = [string] $r.Actual
            $actText.Foreground = $textMuted
            $actText.FontSize = 11
            $actText.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
            $null = $cStack.Children.Add($actText)

            if ($r.Remediation) {
                $remText = New-Object System.Windows.Controls.TextBlock
                $remText.Text = "-> Fix: $($r.Remediation)"
                $remText.Foreground = $accentGold
                $remText.FontSize = 10.5
                $remText.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $remText.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
                $null = $cStack.Children.Add($remText)
            }

            $card.Child = $cStack
            $null = $doctorStack.Children.Add($card)
        }
    })

    $null = $doctorDock.Children.Add($doctorScroll)
    $tabDoctor.Content = $doctorDock
    $null = $tabControl.Items.Add($tabDoctor)

    # -------------------------------------------------------------------------
    # TAB 4: 📜 CHANGE JOURNAL & BACKUPS
    # -------------------------------------------------------------------------
    $tabJournal = New-Object System.Windows.Controls.TabItem
    $tabJournal.Header = '  📜 Journal & Backups  '
    $tabJournal.FontSize = 13

    $jDock = New-Object System.Windows.Controls.DockPanel
    $jDock.Margin = New-Object System.Windows.Thickness 10

    $jTop = New-Object System.Windows.Controls.DockPanel
    $jTop.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    [System.Windows.Controls.DockPanel]::SetDock($jTop, [System.Windows.Controls.Dock]::Top)

    $btnRefreshJournal = New-Object System.Windows.Controls.Button
    $btnRefreshJournal.Content = '🔄 Refresh History'
    $btnRefreshJournal.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5
    $null = $jTop.Children.Add($btnRefreshJournal)

    $btnOpenBackups = New-Object System.Windows.Controls.Button
    $btnOpenBackups.Content = '📁 Open Backups Folder'
    $btnOpenBackups.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5
    $btnOpenBackups.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $null = $jTop.Children.Add($btnOpenBackups)

    $null = $jDock.Children.Add($jTop)

    $jScroll = New-Object System.Windows.Controls.ScrollViewer
    $jScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

    $jStack = New-Object System.Windows.Controls.StackPanel
    $jScroll.Content = $jStack

    $localApp = [Environment]::GetFolderPath('LocalApplicationData')
    $journalFile = Join-Path -Path $localApp -ChildPath 'TerminalStudio\journal.jsonl'
    $backupFolder = Join-Path -Path $localApp -ChildPath 'TerminalStudio\backups'

    $loadJournalEntries = {
        $jStack.Children.Clear()
        if (-not (Test-Path -LiteralPath $journalFile)) {
            $emptyBlock = New-Object System.Windows.Controls.TextBlock
            $emptyBlock.Text = "No journal records found yet. Running Apply will record change entries here."
            $emptyBlock.Foreground = $textMuted
            $emptyBlock.FontSize = 12
            $null = $jStack.Children.Add($emptyBlock)
            return
        }

        $lines = @(Get-Content -LiteralPath $journalFile | Where-Object { $_.Trim() })
        & $logOutput "Loaded $($lines.Count) historical change record(s) from journal."

        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try {
                $entry = $lines[$i] | ConvertFrom-Json
                $card = New-Object System.Windows.Controls.Border
                $card.Background = $bgCard
                $card.BorderBrush = $borderDark
                $card.BorderThickness = New-Object System.Windows.Thickness 1
                $card.CornerRadius = New-Object System.Windows.CornerRadius 5
                $card.Padding = New-Object System.Windows.Thickness 10, 6, 10, 6
                $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4

                $s = New-Object System.Windows.Controls.StackPanel

                $top = New-Object System.Windows.Controls.DockPanel

                $actionBadge = New-Object System.Windows.Controls.Border
                $actionBadge.Background = $accentBlue
                $actionBadge.CornerRadius = New-Object System.Windows.CornerRadius 3
                $actionBadge.Padding = New-Object System.Windows.Thickness 5, 1, 5, 1
                $actionBadge.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
                [System.Windows.Controls.DockPanel]::SetDock($actionBadge, [System.Windows.Controls.Dock]::Left)

                $aTxt = New-Object System.Windows.Controls.TextBlock
                $aTxt.Text = [string] $entry.action
                $aTxt.FontSize = 10
                $aTxt.Foreground = [System.Windows.Media.Brushes]::White
                $actionBadge.Child = $aTxt
                $null = $top.Children.Add($actionBadge)

                $kTxt = New-Object System.Windows.Controls.TextBlock
                $kTxt.Text = "$($entry.name) ($($entry.kind))"
                $kTxt.FontWeight = [System.Windows.FontWeights]::SemiBold
                $kTxt.Foreground = $textLight
                $kTxt.FontSize = 11.5
                $null = $top.Children.Add($kTxt)

                $timeTxt = New-Object System.Windows.Controls.TextBlock
                $timeTxt.Text = [string] $entry.timestamp
                $timeTxt.Foreground = $textMuted
                $timeTxt.FontSize = 10.5
                $timeTxt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
                $null = $top.Children.Add($timeTxt)

                $null = $s.Children.Add($top)

                $destTxt = New-Object System.Windows.Controls.TextBlock
                $destTxt.Text = "Destination: $($entry.destination)"
                $destTxt.Foreground = $textMuted
                $destTxt.FontSize = 10.5
                $destTxt.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
                $null = $s.Children.Add($destTxt)

                if ($entry.backup) {
                    $bTxt = New-Object System.Windows.Controls.TextBlock
                    $bTxt.Text = "Backup: $($entry.backup)"
                    $bTxt.Foreground = $accentGold
                    $bTxt.FontSize = 10.5
                    $null = $s.Children.Add($bTxt)
                }

                $card.Child = $s
                $null = $jStack.Children.Add($card)
            }
            catch {}
        }
    }

    $null = $btnRefreshJournal.Add_Click({
        & $loadJournalEntries
    })

    $null = $btnOpenBackups.Add_Click({
        if (Test-Path -LiteralPath $backupFolder) {
            Start-Process explorer.exe -ArgumentList "`"$backupFolder`""
        }
        else {
            & $logOutput "Backup folder has not been created yet (no displaced files have been backed up)."
        }
    })

    $null = $jDock.Children.Add($jScroll)
    $tabJournal.Content = $jDock
    $null = $tabControl.Items.Add($tabJournal)

    # Initial journal load
    & $loadJournalEntries

    $null = $root.Children.Add($tabControl)
    $window.Content = $root

    # Show Window
    $null = $window.ShowDialog()
}
