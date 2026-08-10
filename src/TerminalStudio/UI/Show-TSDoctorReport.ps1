function Show-TSDoctorReport {
    <#
    .SYNOPSIS
        Renders doctor results for a human.

    .DESCRIPTION
        This folder is the only place in the module permitted to write to the host,
        and tests/unit/Architecture.Tests.ps1 enforces that. The reason is
        practical rather than aesthetic: the predecessor project called its UI
        layer from inside its feature code, which made -NonInteractive impossible
        to implement and made every feature untestable without a terminal.

        Renderers are pure consumers. Delete this file and Invoke-TSDoctor still
        works, which is the test of whether the seam is real.

        ASCII markers are the default. This tool installs the very Nerd Font that
        prettier glyphs would require, so on a first run that font is by definition
        not present yet. Drawing boxes at someone while telling them their font is
        missing is a poor first impression.

    .PARAMETER Result
        Result objects from Invoke-TSDoctor.

    .PARAMETER Unicode
        Use symbol markers. Only pass this once fonts are verified.

    .EXAMPLE
        Invoke-TSDoctor | Show-TSDoctorReport
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Result,

        [switch] $Unicode
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Result) {
            $collected.Add($item)
        }
    }

    end {
        # Built from code points on purpose, so this source file stays pure ASCII.
        # A file containing literal box-drawing characters is one mis-detected
        # encoding away from rendering as mojibake, and it may be read by the 5.1
        # parser during compatibility tests.
        if ($Unicode) {
            $markers = @{
                Pass = [string][char] 0x2714
                Fail = [string][char] 0x2716
                Warn = [string][char] 0x25B2
                Skip = [string][char] 0x00B7
            }
        }
        else {
            $markers = @{
                Pass = 'PASS'
                Fail = 'FAIL'
                Warn = 'WARN'
                Skip = 'SKIP'
            }
        }

        $colors = @{
            Pass = 'Green'
            Fail = 'Red'
            Warn = 'Yellow'
            Skip = 'DarkGray'
        }

        Write-Host ''
        Write-Host '  Terminal Studio doctor' -ForegroundColor Cyan
        Write-Host '  ----------------------' -ForegroundColor Cyan

        foreach ($item in $collected) {
            $status = [string] $item.Status
            $marker = $markers[$status]
            $color = $colors[$status]

            if (-not $marker) { $marker = $status }
            if (-not $color) { $color = 'Gray' }

            Write-Host ('  {0,-6} ' -f $marker) -ForegroundColor $color -NoNewline
            Write-Host $item.Name -NoNewline
            Write-Host "  ($($item.Actual))" -ForegroundColor DarkGray

            # Remediation is shown only where it is actionable. Printing advice next
            # to a passing check trains people to stop reading the output.
            if ($status -ne 'Pass' -and $item.Remediation) {
                Write-Host "         -> $($item.Remediation)" -ForegroundColor DarkCyan
            }
        }

        $failed = @($collected | Where-Object { $_.Status -eq 'Fail' }).Count
        $warned = @($collected | Where-Object { $_.Status -eq 'Warn' }).Count
        $skipped = @($collected | Where-Object { $_.Status -eq 'Skip' }).Count
        $passed = @($collected | Where-Object { $_.Status -eq 'Pass' }).Count

        Write-Host ''
        Write-Host "  $passed passed, $failed failed, $warned warnings, $skipped not checked" -ForegroundColor Cyan

        # Said out loud rather than buried, because a skipped check is not a healthy
        # one and the summary line above could easily be read as if it were.
        if ($skipped -gt 0) {
            Write-Host '  Skipped checks were not verified. Do not read this as a clean bill of health.' -ForegroundColor DarkGray
        }

        Write-Host ''
    }
}
