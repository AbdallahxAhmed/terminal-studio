function Test-TSWingetPresent {
    <#
    .SYNOPSIS
        Reports whether the winget client is available.

    .DESCRIPTION
        Checked as a capability rather than assumed. winget ships with App
        Installer, which is absent on fresh images, stripped from some enterprise
        builds, and occasionally broken after an OS upgrade. Since this project
        delegates all package work to winget, its absence is a first-class
        diagnostic rather than an unexpected exception halfway through a run.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $null -ne (Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-TSWingetVersion {
    <#
    .SYNOPSIS
        Returns the winget client version, or an empty string if unavailable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Test-TSWingetPresent)) {
        return ''
    }

    try {
        $raw = & winget --version 2>$null | Select-Object -First 1
        "$raw".Trim()
    }
    catch {
        ''
    }
}

function Test-TSWingetPackage {
    <#
    .SYNOPSIS
        Reports whether an exact winget package id is installed.

    .PARAMETER Id
        The exact winget package identifier, for example 'Git.Git'.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Id
    )

    if (-not (Test-TSWingetPresent)) {
        return $false
    }

    # --exact matters: without it a query for a short id happily matches unrelated
    # packages by substring. --accept-source-agreements matters just as much,
    # because on a clean machine the first winget call otherwise blocks on an
    # interactive prompt that no automated caller can answer - which is precisely
    # the situation this tool runs in.
    $output = & winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String

    # Exit codes here are not dependable across client versions, and winget prints
    # a friendly 'no installed package found' message on the success channel.
    # Matching the id in the output is the signal that has held up.
    $output -match [regex]::Escape($Id)
}
