function Show-TSControlForm {
    <#
    .SYNOPSIS
        Renders the configurator as a form in the terminal.

    .DESCRIPTION
        One of two surfaces over the same model. This one knows that a control
        can be a checkbox or a dropdown; it does not know that acrylic, opacity
        or Terminal-Icons exist. Everything specific arrives from
        Data/controls.json by way of Get-TSControl, which is what allows a second
        surface to exist without duplicating any of this.

        Read-only by default. -Interactive turns on editing, and nothing is
        interactive without it, so a CI job can render the form to prove it draws
        without a console waiting forever on input.

        Editing uses Read-Host rather than RawUI.ReadKey. Raw key handling gives
        a nicer form and throws outright in hosts that have no interactive
        keyboard buffer - the ISE, remoting sessions, redirected stdin. A
        numbered menu is plainer and works everywhere.

        Toggling a control changes the object in memory and returns it. It does
        not write desired state. apply does not exist yet, and a configurator
        that edits the source of truth for an engine that cannot act on it would
        be a half-connected loop pretending to be a whole one.

    .PARAMETER Control
        TerminalStudio.Control objects from Get-TSControl.

    .PARAMETER Unicode
        Use box and check characters instead of ASCII. Off by default: the
        default Windows console codepage still mangles them, and a form that
        renders as mojibake is worse than a plain one.

    .PARAMETER Interactive
        Allow editing. Without it the form is drawn and nothing is read.

    .OUTPUTS
        With -Interactive and a save, the edited control objects. Otherwise none.

    .EXAMPLE
        Get-TSControl | Show-TSControlForm

    .EXAMPLE
        Get-TSControl | Show-TSControlForm -Interactive -Unicode
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Control,

        [switch] $Unicode,

        [switch] $Interactive
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

        $checkedMark = '[x]'
        $emptyMark = '[ ]'
        $unboundMark = '[?]'
        $rule = '-'
        $open = '<'
        $close = '>'

        if ($Unicode) {
            $checkedMark = '[' + [string][char] 0x2714 + ']'
            $unboundMark = '[' + [string][char] 0x003F + ']'
            $rule = [string][char] 0x2500
            $open = [string][char] 0x276E
            $close = [string][char] 0x276F
        }

        function Get-TSControlDisplay {
            param(
                [object] $Item,
                [string] $Checked,
                [string] $Empty,
                [string] $Missing,
                [string] $OpenChar,
                [string] $CloseChar
            )

            if (-not $Item.Bound) {
                return $Missing
            }

            if ($Item.Type -eq 'checkbox') {
                if ([bool] $Item.Value) {
                    return $Checked
                }

                return $Empty
            }

            return "$OpenChar $($Item.Value) $CloseChar"
        }

        function Write-TSControlForm {
            param(
                [object[]] $Items,
                [string] $Checked,
                [string] $Empty,
                [string] $Missing,
                [string] $OpenChar,
                [string] $CloseChar,
                [string] $Rule
            )

            Write-Host ''
            Write-Host '  Terminal Studio - configure'
            Write-Host "  $($Rule * 58)"

            $lastGroup = ''
            $number = 0

            foreach ($item in $Items) {
                $number++

                if ($item.Group -ne $lastGroup) {
                    Write-Host ''
                    Write-Host "  $($item.Group)"
                    $lastGroup = $item.Group
                }

                $display = Get-TSControlDisplay -Item $item -Checked $Checked -Empty $Empty -Missing $Missing -OpenChar $OpenChar -CloseChar $CloseChar
                $index = ([string] $number).PadLeft(2)
                $cost = ''

                if ($item.CostMs -gt 0) {
                    $cost = "  ($($item.CostMs) ms)"
                }

                $line = "   {0}. {1}  {2}{3}" -f $index, $display.PadRight(10), $item.Label, $cost
                Write-Host $line

                if (-not $item.Bound) {
                    # Stated, never silently drawn as an unchecked box. An unbound
                    # control means the definition and desired state disagree,
                    # which is a defect in the configuration, not a setting.
                    Write-Host "        not bound - target missing from desired state"
                }
            }

            $modules = @($Items | Where-Object { $_.CostMs -gt 0 -and $_.Type -eq 'checkbox' -and $_.Bound -and [bool] $_.Value })
            $total = 0

            foreach ($module in $modules) {
                $total += [int] $module.CostMs
            }

            Write-Host ''
            Write-Host "  $($Rule * 58)"
            Write-Host "  measured startup cost of selected modules: $total ms"
        }

        Write-TSControlForm -Items $items -Checked $checkedMark -Empty $emptyMark -Missing $unboundMark -OpenChar $open -CloseChar $close -Rule $rule

        if (-not $Interactive) {
            Write-Host ''
            return
        }

        $changed = [System.Collections.Generic.List[string]]::new()

        while ($true) {
            Write-Host ''
            Write-Host '  number = change    h<number> = help    s = save    q = quit'
            $answer = (Read-Host -Prompt '  >').Trim()

            if ($answer -eq 'q') {
                Write-Host '  Discarded.'
                return
            }

            if ($answer -eq 's') {
                Write-Host "  $($changed.Count) control(s) changed. Returned as objects; desired state on disk is untouched."
                return $items
            }

            if ($answer -match '^h\s*(\d+)$') {
                $target = [int] $Matches[1]

                if ($target -lt 1 -or $target -gt $items.Count) {
                    Write-Host '  No such control.'
                    continue
                }

                Write-Host ''
                Write-Host "  $($items[$target - 1].Label)"
                Write-Host "  $($items[$target - 1].Help)"
                continue
            }

            if ($answer -notmatch '^\d+$') {
                Write-Host '  Not understood.'
                continue
            }

            $selected = [int] $answer

            if ($selected -lt 1 -or $selected -gt $items.Count) {
                Write-Host '  No such control.'
                continue
            }

            $item = $items[$selected - 1]

            if (-not $item.Bound) {
                Write-Host '  That control is not bound to anything in desired state and cannot be changed here.'
                continue
            }

            if ($item.Type -eq 'checkbox') {
                $item.Value = -not [bool] $item.Value
            }
            else {
                $options = @($item.Options)

                if ($options.Count -eq 0) {
                    Write-Host '  That dropdown has no options.'
                    continue
                }

                $position = -1

                for ($i = 0; $i -lt $options.Count; $i++) {
                    if ([string] $options[$i].Value -eq [string] $item.Value) {
                        $position = $i
                        break
                    }
                }

                $next = ($position + 1) % $options.Count
                $item.Value = $options[$next].Value
                Write-Host "  $($item.Label): $($options[$next].Label)"
            }

            if (-not $changed.Contains([string] $item.Id)) {
                $changed.Add([string] $item.Id)
            }

            Write-TSControlForm -Items $items -Checked $checkedMark -Empty $emptyMark -Missing $unboundMark -OpenChar $open -CloseChar $close -Rule $rule
        }
    }
}
