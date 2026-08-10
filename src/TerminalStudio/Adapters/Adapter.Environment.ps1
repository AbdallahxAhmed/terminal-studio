function Get-TSOSBuild {
    <#
    .SYNOPSIS
        Returns the Windows build number.

    .DESCRIPTION
        Build number rather than marketing version, because the capabilities this
        tool depends on are gated on builds. Per-user font installation, for
        example, starts at 17763.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    [Environment]::OSVersion.Version.Build
}

function Get-TSPsInfo {
    <#
    .SYNOPSIS
        Returns the running PowerShell edition and version.

    .DESCRIPTION
        The predecessor never checked this. It targeted PowerShell 7 but was
        routinely launched with powershell.exe, and the mismatch surfaced as an
        unrelated-looking parameter error deep inside a feature rather than as a
        clear refusal at the entry point.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject] @{
        Edition = $PSVersionTable.PSEdition
        Version = $PSVersionTable.PSVersion
    }
}

function Get-TSProfilePath {
    <#
    .SYNOPSIS
        Returns the path of the current user's profile script for this host.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $PROFILE.CurrentUserCurrentHost
}

function Test-TSDocumentsRedirected {
    <#
    .SYNOPSIS
        Reports whether the Documents folder has been redirected, typically by OneDrive.

    .DESCRIPTION
        OneDrive Known Folder Move relocates Documents, and PowerShell follows it.
        Any code that builds the profile path by joining 'Documents' onto the user
        profile directory then writes to a folder the shell will never read, and
        the symptom is a profile that appears installed and never runs.

        Comparing the resolved path against the naive one turns that silent
        failure into a reportable fact.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $resolved = Get-TSSpecialFolder -Name 'MyDocuments'
    $naive = Join-Path -Path (Get-TSSpecialFolder -Name 'UserProfile') -ChildPath 'Documents'

    $resolved.TrimEnd('\') -ne $naive.TrimEnd('\')
}

function Get-TSModuleInstalled {
    <#
    .SYNOPSIS
        Reports whether a module is available, and at which version.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $found = Get-Module -ListAvailable -Name $Name |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    [pscustomobject] @{
        Installed = [bool] $found
        Version   = if ($found) { $found.Version.ToString() } else { '' }
    }
}

function Measure-TSShellStartup {
    <#
    .SYNOPSIS
        Measures cold start of a new PowerShell 7 shell, profile included.

    .DESCRIPTION
        A tool whose product is the feel of a terminal has to measure the thing it
        is selling. A prompt engine plus an icon module plus a directory jumper is
        comfortably over a second of cold start if nobody is watching, and nobody
        watches unless it is a number in a report.

        The profile is deliberately NOT skipped - profile cost is the entire point
        of the measurement.

    .PARAMETER Iterations
        How many launches to time. Defaults to 3.

    .OUTPUTS
        Median milliseconds, or -1 if PowerShell 7 is not present.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [ValidateRange(1, 25)]
        [int] $Iterations = 3
    )

    $pwsh = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $pwsh) {
        return -1
    }

    $samples = [System.Collections.Generic.List[double]]::new()

    for ($i = 0; $i -lt $Iterations; $i++) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        & $pwsh.Source -NoLogo -Command 'exit' | Out-Null
        $watch.Stop()
        $samples.Add($watch.Elapsed.TotalMilliseconds)
    }

    # Median, not mean. One unlucky run that hits a cold file cache should not be
    # allowed to define the number the budget is judged against.
    $sorted = @($samples | Sort-Object)

    [int] [math]::Round($sorted[[int] [math]::Floor($sorted.Count / 2)])
}
