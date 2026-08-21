function Show-TSUninstallReport {
    <#
    .SYNOPSIS
        Renders uninstall results for a human.

    .DESCRIPTION
        A third renderer over the same result shape, for the same reason apply got
        its own: the vocabulary is what differs. Pass here means a file was put
        back or taken away, and Skip carries the meaning that matters most in this
        command - a file was deliberately not touched, because it is no longer the
        file apply wrote.

        Printing that as a failure would be wrong. It is the safety property
        working, and the report has to make it read that way, or the next thing the
        user does is look for a --force.

        Delete this file and Invoke-TSUninstall still works.

    .PARAMETER Result
        Result objects from Invoke-TSUninstall.

    .PARAMETER JournalPath
        Journal location, named in the footer so it can be found.

    .PARAMETER BackupRoot
        Backup directory, named because a restore reads from it and a skipped file
        may still need one by hand.

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
        # other renderers: it may be read by the 5.1 parser during compatibility
        # tests, and a literal glyph is one mis-detected encoding away from
        # mojibake.
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

        $heading = if ($WhatIf) { 'Terminal Studio uninstall  (dry run, nothing changed)' } else { 'Terminal Studio uninstall' }

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
        Write-Host "  $done undone, $failed failed, $warned journal warning(s), $skipped left alone" -ForegroundColor Cyan

        # The least intuitive status in this command, and the one most likely to be
        # misread as a bug, so it is spelled out rather than left to the per-item
        # remediation lines.
        if ($skipped -gt 0) {
            Write-Host '  Skipped files were not touched: already gone, or no longer the file apply wrote.' -ForegroundColor DarkGray
        }

        if ($failed -gt 0) {
            Write-Host '  Failed items were left exactly as they were. Nothing was half restored.' -ForegroundColor DarkGray
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
