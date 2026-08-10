function Show-TSPlan {
    <#
    .SYNOPSIS
        Renders a plan for a human.

    .DESCRIPTION
        Shows what would change, and by default hides what already matches. A plan
        that lists forty converged resources alongside two real changes buries the
        answer the user came for.

        Markers borrow diff vocabulary deliberately, because it is a notation people
        already read every day:

          +  would change
          =  already in desired state
          ?  could not be verified by this build

        The unverified count is printed as its own line rather than folded into a
        total. Rolling it in would let '18 of 20 in desired state' quietly mean
        'and two we never looked at'.

    .PARAMETER Plan
        Result objects from Get-TSPlan.

    .PARAMETER All
        Also list resources that already match.

    .EXAMPLE
        Get-TSPlan | Show-TSPlan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Plan,

        [switch] $All
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Plan) {
            $collected.Add($item)
        }
    }

    end {
        $changes = @($collected | Where-Object { $_.Status -eq 'Fail' })
        $unverified = @($collected | Where-Object { $_.Status -eq 'Skip' })
        $converged = @($collected | Where-Object { $_.Status -eq 'Pass' })

        Write-Host ''
        Write-Host '  Terminal Studio plan' -ForegroundColor Cyan
        Write-Host '  --------------------' -ForegroundColor Cyan

        foreach ($item in $changes) {
            Write-Host '  + ' -ForegroundColor Yellow -NoNewline
            Write-Host $item.Name -NoNewline
            Write-Host "  $($item.Actual) -> $($item.Expected)" -ForegroundColor DarkGray

            if ($item.Remediation) {
                Write-Host "      $($item.Remediation)" -ForegroundColor DarkCyan
            }
        }

        foreach ($item in $unverified) {
            Write-Host '  ? ' -ForegroundColor Magenta -NoNewline
            Write-Host $item.Name -NoNewline
            Write-Host "  $($item.Actual)" -ForegroundColor DarkGray
        }

        if ($All) {
            foreach ($item in $converged) {
                Write-Host '  = ' -ForegroundColor DarkGray -NoNewline
                Write-Host $item.Name -ForegroundColor DarkGray
            }
        }

        if ($changes.Count -eq 0 -and $unverified.Count -eq 0) {
            Write-Host '  Nothing to do. This machine matches the desired state.' -ForegroundColor Green
        }

        Write-Host ''
        Write-Host "  $($changes.Count) would change, $($converged.Count) already in desired state" -ForegroundColor Cyan

        if ($unverified.Count -gt 0) {
            Write-Host "  $($unverified.Count) could not be verified by this build" -ForegroundColor Magenta
        }

        if (-not $All -and $converged.Count -gt 0) {
            Write-Host '  Pass -All to list resources that already match.' -ForegroundColor DarkGray
        }

        # Stated plainly rather than implied by the absence of an apply command.
        # A plan that looks actionable but is not needs to say so where it is read.
        if ($changes.Count -gt 0) {
            Write-Host '  apply is not implemented in 0.1.0. Use the commands above, or wait for it.' -ForegroundColor DarkGray
        }

        Write-Host ''
    }
}
