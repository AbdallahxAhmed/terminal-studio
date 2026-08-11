function Show-TSApplyReport {
    <#
    .SYNOPSIS
        Renders apply results for a human.

    .DESCRIPTION
        A distinct renderer from Show-TSDoctorReport, despite consuming the same
        result shape, because the vocabulary differs where it matters. In a
        diagnostic, Pass is a statement about the machine. In a convergence run it
        is a statement about an action that was taken, and printing PASS next to a
        file that was just overwritten invites exactly the wrong reading.

        Delete this file and Invoke-TSApply still works. That is the test of
        whether the seam is real rather than decorative.

    .PARAMETER Result
        Result objects from Invoke-TSApply.

    .PARAMETER JournalPath
        Journal location, named in the footer so it can be found.

    .PARAMETER BackupRoot
        Backup directory, named for the same reason.

    .PARAMETER Unicode
        Use symbol markers instead of words.

    .PARAMETER WhatIf
        Render as a dry run. Changes the heading only; deciding what to do is not
        a renderer's job.
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
        # Built from code points so this file stays pure ASCII on disk. It may be
        # read by the 5.1 parser during compatibility tests, and a literal glyph is
        # one mis-detected encoding away from mojibake.
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
                Pass = 'DONE'
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

        $heading = if ($WhatIf) { 'Terminal Studio apply  (dry run, nothing written)' } else { 'Terminal Studio apply' }

        Write-Host ''
        Write-Host "  $heading" -ForegroundColor Cyan
        Write-Host ('  ' + ('-' * $heading.Length)) -ForegroundColor Cyan

        foreach ($item in $collected) {
            $status = [string] $item.Status
            $marker = $markers[$status]
            $color = $colors[$status]

            if (-not $marker) { $marker = $status }
            if (-not $color) { $color = 'Gray' }

            Write-Host ('  {0,-6} ' -f $marker) -ForegroundColor $color -NoNewline
            Write-Host $item.Name -NoNewline
            Write-Host "  ($($item.Actual))" -ForegroundColor DarkGray

            if ($status -ne 'Pass' -and $item.Remediation) {
                Write-Host "         -> $($item.Remediation)" -ForegroundColor DarkCyan
            }
        }

        $done = @($collected | Where-Object { $_.Status -eq 'Pass' }).Count
        $failed = @($collected | Where-Object { $_.Status -eq 'Fail' }).Count
        $warned = @($collected | Where-Object { $_.Status -eq 'Warn' }).Count
        $skipped = @($collected | Where-Object { $_.Status -eq 'Skip' }).Count

        Write-Host ''
        Write-Host "  $done in desired state, $failed failed, $warned applied but overridden, $skipped left to you" -ForegroundColor Cyan

        # Warn has a specific meaning here and it is the least intuitive one: the
        # write succeeded and will still not be visible. Saying it plainly costs one
        # line and saves the user concluding the tool is broken.
        if ($warned -gt 0) {
            Write-Host '  Warnings above were written successfully but are being overridden by your own settings.' -ForegroundColor DarkGray
        }

        if ($skipped -gt 0) {
            Write-Host '  Skipped items were not attempted. apply does not install packages, fonts, or modules.' -ForegroundColor DarkGray
        }

        if (-not $WhatIf -and $JournalPath) {
            Write-Host ''
            Write-Host "  journal  $JournalPath" -ForegroundColor DarkGray
        }

        if (-not $WhatIf -and $BackupRoot) {
            Write-Host "  backups  $BackupRoot" -ForegroundColor DarkGray
        }

        Write-Host ''
    }
}
