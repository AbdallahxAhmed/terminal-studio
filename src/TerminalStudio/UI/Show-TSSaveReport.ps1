function Show-TSSaveReport {
    <#
    .SYNOPSIS
        Renders the outcome of configure -Save for a human.

    .DESCRIPTION
        A fourth renderer over the same result shape, for the reason the other
        three are separate: the vocabulary is the entire difference. 'Applied but
        overridden' means nothing about a value written into a file under version
        control, and the sentence that matters most after a save - that the machine
        has not changed yet, and apply is what changes it - has nowhere to live in
        apply's footer.

        Skip here almost always means a control this build declines to write rather
        than an error, so it is explained rather than merely counted.

        Delete this file and Set-TSControl still works.

    .PARAMETER Result
        Result objects from Set-TSControl.

    .PARAMETER JournalPath
        Journal location, named in the footer because these edits are reversible
        and that is where the record of them is.

    .PARAMETER BackupRoot
        Where the pre-edit copy of each document was kept.

    .PARAMETER Unicode
        Use symbol markers instead of words.

    .PARAMETER WhatIf
        Render as a dry run. Changes the heading only; deciding what to do is not a
        renderer's job.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Result,

        [string] $JournalPath = '',

        [string] $BackupRoot = '',

        [switch] $Unicode,

        [switch] $WhatIf
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
        # Built from code points so this file stays pure ASCII on disk, matching the
        # other renderers.
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
                Pass = 'SAVED'
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

        $heading = if ($WhatIf) { 'Terminal Studio configure  (dry run, desired state unchanged)' } else { 'Terminal Studio configure' }

        Write-Host ''
        Write-Host "  $heading" -ForegroundColor Cyan
        Write-Host ('  ' + ('-' * $heading.Length)) -ForegroundColor Cyan

        foreach ($item in $collected) {
            $status = [string] $item.Status
            $marker = $markers[$status]
            $color = $colors[$status]

            if (-not $marker) { $marker = $status }
            if (-not $color) { $color = 'Gray' }

            Write-Host ('  {0,-7} ' -f $marker) -ForegroundColor $color -NoNewline
            Write-Host $item.Name -NoNewline
            Write-Host "  ($($item.Actual))" -ForegroundColor DarkGray

            if ($item.Expected) {
                Write-Host "          $($item.Expected)" -ForegroundColor DarkGray
            }

            if ($status -ne 'Pass' -and $item.Remediation) {
                Write-Host "          -> $($item.Remediation)" -ForegroundColor DarkCyan
            }
        }

        $saved = @($collected | Where-Object { $_.Status -eq 'Pass' }).Count
        $failed = @($collected | Where-Object { $_.Status -eq 'Fail' }).Count
        $skipped = @($collected | Where-Object { $_.Status -eq 'Skip' }).Count

        Write-Host ''
        Write-Host "  $saved saved, $failed refused, $skipped not written" -ForegroundColor Cyan

        if ($skipped -gt 0) {
            Write-Host '  Skipped controls are ones this build will not write, not errors. Each says why above.' -ForegroundColor DarkGray
        }

        if ($failed -gt 0) {
            Write-Host '  Refused edits changed nothing. The document is exactly as it was.' -ForegroundColor DarkGray
        }

        # The single most important line in this report. Desired state is not the
        # machine, and a user who reads 'saved' and closes the terminal will
        # otherwise wonder tomorrow why nothing looks different.
        if (-not $WhatIf -and $saved -gt 0) {
            Write-Host ''
            Write-Host '  Desired state changed. The machine has not: run apply to converge it.' -ForegroundColor Yellow
            Write-Host '    ./ts.ps1 apply -WhatIf' -ForegroundColor Gray
            Write-Host '    ./ts.ps1 apply' -ForegroundColor Gray
        }

        if (-not $WhatIf -and $saved -gt 0 -and $JournalPath) {
            Write-Host ''
            Write-Host "  journal  $JournalPath" -ForegroundColor DarkGray
        }

        if (-not $WhatIf -and $saved -gt 0 -and $BackupRoot) {
            Write-Host "  backups  $BackupRoot" -ForegroundColor DarkGray
        }

        Write-Host ''
    }
}
