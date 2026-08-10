function Show-TSControlWindow {
    <#
    .SYNOPSIS
        Renders the configurator as a desktop window.

    .DESCRIPTION
        The second surface over the model returned by Get-TSControl. It contains
        no list of settings. Every checkbox and dropdown in the window is built
        from the control objects it is handed, which is the entire reason two
        surfaces can exist without becoming two things to maintain: adding a knob
        is an edit to Data/controls.json and both surfaces gain it.

        Controls are constructed as objects rather than generated as a XAML
        string. WinUtil, which this borrows its layering from, generates XAML -
        that is a reasonable choice when a designer is editing the markup. Here
        the markup would be machine-written and never read, so a string buys
        nothing and costs escaping: a label containing an ampersand silently
        produces invalid XAML, and XamlReader reports it as a parse error at a
        line number in a document no human has seen.

        The window is painted with the Andalus palette but it is not genuinely
        frosted. Acrylic in WPF needs DWM interop, and drawing a flat window
        while calling it frosted would repeat exactly the requested-versus-
        effective confusion that doctor exists to expose.

        Like the terminal surface, this returns edited objects and writes
        nothing to disk.

    .PARAMETER Control
        TerminalStudio.Control objects from Get-TSControl.

    .OUTPUTS
        The edited control objects if Save was pressed, otherwise none.

    .EXAMPLE
        Get-TSControl | Show-TSControlWindow
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Control
    )

    begin {
        $items = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Control) {
            $items.Add($item)
        }
    }

    end {
        if ($items.Count -eq 0) {
            Write-Host 'No controls to display.'
            return
        }

        if (-not $IsWindows) {
            Write-Host '  The window surface requires Windows. Use -Surface Tui instead.'
            return
        }

        # PowerShell 7 starts its main thread MTA. WPF requires STA and the
        # failure is an opaque InvalidOperationException several calls deep, so
        # it is worth catching here and answering with the fix.
        $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        if ($apartment -ne [System.Threading.ApartmentState]::STA) {
            Write-Host '  The window surface needs a single-threaded apartment.'
            Write-Host '  PowerShell 7 starts MTA by default. Relaunch as:'
            Write-Host '      pwsh -STA -File .\ts.ps1 configure -Surface Wpf'
            Write-Host '  Or use the terminal surface, which has no such requirement:'
            Write-Host '      pwsh -File .\ts.ps1 configure'
            return
        }

        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            Add-Type -AssemblyName PresentationCore -ErrorAction Stop
            Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        }
        catch {
            Write-Host "  WPF is not available on this system: $($_.Exception.Message)"
            Write-Host '  Use the terminal surface instead: pwsh -File .\ts.ps1 configure'
            return
        }

        $brushes = New-Object System.Windows.Media.BrushConverter
        $background = $brushes.ConvertFromString('#FF0B1220')
        $panel = $brushes.ConvertFromString('#FF141C2E')
        $foreground = $brushes.ConvertFromString('#FFEDE0C8')
        $accent = $brushes.ConvertFromString('#FFD4A537')
        $muted = $brushes.ConvertFromString('#FF8A93A8')

        $window = New-Object System.Windows.Window
        $window.Title = 'Terminal Studio - configure'
        $window.Width = 720
        $window.Height = 660
        $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
        $window.Background = $background
        $window.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'

        # DockPanel rather than Grid: setting a Grid row to star height means
        # constructing a GridLength, and the string coercion that appears to work
        # for it is a converter that silently accepts nonsense. Dock has no such
        # ambiguity - the last child fills whatever is left.
        $root = New-Object System.Windows.Controls.DockPanel
        $root.Margin = New-Object System.Windows.Thickness 14

        $footer = New-Object System.Windows.Controls.StackPanel
        $footer.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $footer.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $footer.Margin = New-Object System.Windows.Thickness 0, 12, 0, 0
        [System.Windows.Controls.DockPanel]::SetDock($footer, [System.Windows.Controls.Dock]::Bottom)

        $summary = New-Object System.Windows.Controls.TextBlock
        $summary.Foreground = $muted
        $summary.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
        $summary.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $summary.Text = 'Changes are returned to the shell as objects. Nothing on disk is modified: apply does not exist yet.'
        [System.Windows.Controls.DockPanel]::SetDock($summary, [System.Windows.Controls.Dock]::Bottom)

        $scroller = New-Object System.Windows.Controls.ScrollViewer
        $scroller.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

        $stack = New-Object System.Windows.Controls.StackPanel
        $scroller.Content = $stack

        $bindings = [System.Collections.Generic.List[object]]::new()
        $lastGroup = ''

        foreach ($item in $items) {
            if ($item.Group -ne $lastGroup) {
                $header = New-Object System.Windows.Controls.TextBlock
                $header.Text = [string] $item.Group
                $header.Foreground = $accent
                $header.FontSize = 15
                $header.FontWeight = [System.Windows.FontWeights]::SemiBold
                $header.Margin = New-Object System.Windows.Thickness 0, 16, 0, 6
                $null = $stack.Children.Add($header)
                $lastGroup = $item.Group
            }

            $row = New-Object System.Windows.Controls.Border
            $row.Background = $panel
            $row.Padding = New-Object System.Windows.Thickness 10, 8, 10, 8
            $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
            $row.CornerRadius = New-Object System.Windows.CornerRadius 4

            $cell = New-Object System.Windows.Controls.StackPanel
            $row.Child = $cell

            $caption = [string] $item.Label

            if ($item.CostMs -gt 0) {
                $caption = "$caption  ($($item.CostMs) ms startup)"
            }

            if ($item.Type -eq 'checkbox') {
                $element = New-Object System.Windows.Controls.CheckBox
                $element.Content = $caption
                $element.Foreground = $foreground
                $element.IsChecked = [bool] $item.Value
                $null = $cell.Children.Add($element)
            }
            else {
                $label = New-Object System.Windows.Controls.TextBlock
                $label.Text = $caption
                $label.Foreground = $foreground
                $label.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
                $null = $cell.Children.Add($label)

                $element = New-Object System.Windows.Controls.ComboBox
                $selected = -1
                $position = 0

                foreach ($option in @($item.Options)) {
                    $null = $element.Items.Add([string] $option.Label)

                    if ([string] $option.Value -eq [string] $item.Value) {
                        $selected = $position
                    }

                    $position++
                }

                $element.SelectedIndex = $selected
                $null = $cell.Children.Add($element)
            }

            $hint = New-Object System.Windows.Controls.TextBlock
            $hint.Text = [string] $item.Help
            $hint.Foreground = $muted
            $hint.FontSize = 11
            $hint.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $hint.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
            $null = $cell.Children.Add($hint)

            if (-not $item.Bound) {
                # Disabled and labelled, never drawn as a cleared checkbox. An
                # unbound control means the definition and desired state
                # disagree, and that is a defect to surface, not a value.
                $element.IsEnabled = $false
                $hint.Text = 'Not bound: this control targets something absent from desired state. ' + $hint.Text
            }

            $bindings.Add([pscustomobject] @{ Item = $item; Element = $element })
            $null = $stack.Children.Add($row)
        }

        $result = @{ Saved = $false }

        $save = New-Object System.Windows.Controls.Button
        $save.Content = 'Save'
        $save.Width = 90
        $save.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        $save.Padding = New-Object System.Windows.Thickness 6

        $cancel = New-Object System.Windows.Controls.Button
        $cancel.Content = 'Cancel'
        $cancel.Width = 90
        $cancel.Padding = New-Object System.Windows.Thickness 6

        # The handlers mutate a hashtable rather than assigning to a captured
        # variable. A scriptblock closes over the scope, so reassignment inside
        # the handler would create a local and the result would be lost.
        $null = $save.Add_Click({ $result.Saved = $true; $window.Close() })
        $null = $cancel.Add_Click({ $window.Close() })

        $null = $footer.Children.Add($cancel)
        $null = $footer.Children.Add($save)

        $null = $root.Children.Add($footer)
        $null = $root.Children.Add($summary)
        $null = $root.Children.Add($scroller)

        $window.Content = $root
        $null = $window.ShowDialog()

        if (-not $result.Saved) {
            Write-Host '  Discarded.'
            return
        }

        $changed = 0

        foreach ($binding in $bindings) {
            if (-not $binding.Item.Bound) {
                continue
            }

            if ($binding.Item.Type -eq 'checkbox') {
                $value = [bool] $binding.Element.IsChecked

                if ($value -ne [bool] $binding.Item.Value) {
                    $binding.Item.Value = $value
                    $changed++
                }

                continue
            }

            $index = [int] $binding.Element.SelectedIndex
            $options = @($binding.Item.Options)

            if ($index -lt 0 -or $index -ge $options.Count) {
                continue
            }

            if ([string] $options[$index].Value -ne [string] $binding.Item.Value) {
                $binding.Item.Value = $options[$index].Value
                $changed++
            }
        }

        Write-Host "  $changed control(s) changed. Returned as objects; desired state on disk is untouched."
        $items
    }
}
