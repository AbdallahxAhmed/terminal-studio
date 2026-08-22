<#
.SYNOPSIS
    Stage 0. Resolves a release, verifies it, unpacks it, then hands off to doctor.

.DESCRIPTION
    This is the only file in the project meant to be executed straight from the
    internet. The executable body is kept short so it can be read before it is
    trusted; the header is long precisely because this is the file that asks for
    that trust.

    It is written to work when pasted as a bare one-liner:

        irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1 | iex

    A pipe into Invoke-Expression passes no arguments, and that single fact drives
    most of what follows:

      - No parameter is mandatory. An earlier version made -Version mandatory, so
        the one-liner stopped and prompted for it mid-paste. A prompt appearing
        with no context, during what the user believed was one command, is a
        defect wearing a safety feature's clothing.
      - Version and hash come from bootstrap/releases.json rather than from the
        user's memory.
      - Environment variables are honoured, because they are the only channel a
        bare pipe leaves open:

            $env:TS_VERSION = 'v0.1.0'; irm <url> | iex

      - Nothing calls exit. Under Invoke-Expression, exit terminates the host
        session, closing the window the user is standing in. Failures throw.

    On trust. The manifest is fetched from main, which looks like the moving-branch
    problem it is not: this script is already being fetched from main, so anyone
    able to rewrite the manifest can rewrite the script reading it. Nothing is
    conceded. What matters survives - the payload is downloaded from an immutable
    release tag and checked against a hash recorded in git history, where altering
    it leaves a commit behind. TLS proves who served the bytes; only the hash says
    what they are.

    The remaining constraints follow from when this runs, which is before anything
    is installed:

      - Windows PowerShell 5.1 must work, because PowerShell 7 may not exist yet.
        tests/compat parses this file with the 5.1 parser rather than trusting a
        careful read.
      - The engine check is a runtime comparison, not #Requires. #Requires is a
        directive for script files, and this file's main mode of execution is a
        string passed to Invoke-Expression. Its behaviour there is not something to
        find out during someone's install.
      - TLS 1.2 is set explicitly. 5.1 inherits a default that can still negotiate
        down on machines behind on updates.
      - -UseBasicParsing everywhere, or Invoke-WebRequest reaches for Internet
        Explorer's DOM engine, which may be absent or disabled.
      - ProgressPreference is silenced. In 5.1 the progress bar can make
        Invoke-WebRequest an order of magnitude slower.
      - All work happens inside a function invoked on the final line, so a transfer
        cut mid-download defines a function and never calls it, rather than
        executing the first half of an installer.

.PARAMETER Version
    Release tag to install, such as v0.1.0. Defaults to the release named 'latest'
    in the manifest. Also read from $env:TS_VERSION.

.PARAMETER Sha256
    Expected SHA-256 of the archive. Overrides the manifest, for verifying against
    a hash you obtained elsewhere.

.PARAMETER InstallRoot
    Where to unpack. Defaults to a per-user location, so no elevation is needed.
    Also read from $env:TS_INSTALL_ROOT.

.PARAMETER SkipHashCheck
    Proceed without integrity verification, and say plainly what was given up.

.PARAMETER NoDoctor
    Install without running doctor afterwards. Also set by $env:TS_NO_DOCTOR.

.EXAMPLE
    irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1))) -Version v0.1.0
#>

param(
    [string] $Version,
    [string] $Sha256,
    [string] $InstallRoot,
    [switch] $SkipHashCheck,
    [switch] $NoDoctor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-TSStageZero {
    [CmdletBinding()]
    param(
        [string] $Version,
        [string] $Sha256,
        [string] $InstallRoot,
        [switch] $SkipHashCheck,
        [switch] $NoDoctor
    )

    $owner = 'AbdallahxAhmed'
    $repository = 'terminal-studio'
    $manifestUri = "https://raw.githubusercontent.com/$owner/$repository/main/bootstrap/releases.json"

    # Compared numerically rather than declared with #Requires. See the header.
    $major = [int] $PSVersionTable.PSVersion.Major
    $minor = [int] $PSVersionTable.PSVersion.Minor

    if ($major -lt 5 -or ($major -eq 5 -and $minor -lt 1)) {
        throw "This bootstrap needs Windows PowerShell 5.1 or newer. This host reports $($PSVersionTable.PSVersion)."
    }

    # The only way to reach a bare 'irm | iex' with an option.
    if (-not $Version -and $env:TS_VERSION) { $Version = $env:TS_VERSION }
    if (-not $InstallRoot -and $env:TS_INSTALL_ROOT) { $InstallRoot = $env:TS_INSTALL_ROOT }
    if (-not $InstallRoot) { $InstallRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'TerminalStudio' }

    $runDoctor = -not $NoDoctor
    if ($env:TS_NO_DOCTOR) { $runDoctor = $false }

    # Validated here rather than on the parameter, because a value arriving through
    # the environment never passes parameter validation.
    if ($Version -and ($Version -notmatch '^v\d+\.\d+\.\d+$')) {
        throw "Version must look like v1.2.3. Got '$Version'."
    }

    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host 'Terminal Studio'

    try {
        $cacheBuster = [Guid]::NewGuid().ToString('N')
        $manifestText = (Invoke-WebRequest -Uri "$manifestUri`?v=$cacheBuster" -UseBasicParsing).Content
    }
    catch {
        throw "Could not read the release manifest at $manifestUri. $($_.Exception.Message)"
    }

    $manifest = $manifestText | ConvertFrom-Json
    $manifestNames = @($manifest.PSObject.Properties.Name)

    if ($manifestNames -notcontains 'releases') {
        throw 'The release manifest carries no releases list. Nothing was installed.'
    }

    $releases = @($manifest.releases)

    if ($releases.Count -eq 0) {
        throw 'The release manifest lists no releases yet. Nothing was installed.'
    }

    if (-not $Version) {
        if ($manifestNames -notcontains 'latest' -or -not $manifest.latest) {
            throw 'The manifest names no latest release, so there is nothing to default to. Pass -Version, or set the TS_VERSION environment variable.'
        }

        $Version = [string] $manifest.latest
    }

    $entry = $null

    foreach ($candidate in $releases) {
        if (([string] $candidate.version) -eq $Version) {
            $entry = $candidate
            break
        }
    }

    if (-not $entry) {
        $known = ($releases | ForEach-Object { [string] $_.version }) -join ', '
        throw "The manifest does not list $Version. Recorded releases: $known."
    }

    $entryNames = @($entry.PSObject.Properties.Name)

    $asset = "TerminalStudio-$Version.zip"
    if (($entryNames -contains 'asset') -and $entry.asset) {
        $asset = [string] $entry.asset
    }

    # Three ways to arrive at an expected hash, and one way to have none. Saying
    # which one applied matters: 'verified' against a hash the caller supplied and
    # 'verified' against a hash the project published are different claims.
    $expected = $null
    $hashSource = $null

    if ($Sha256) {
        $expected = $Sha256.Trim().ToUpperInvariant()
        $hashSource = 'the hash you supplied'
    }
    elseif (($entryNames -contains 'sha256') -and $entry.sha256) {
        $expected = ([string] $entry.sha256).Trim().ToUpperInvariant()
        $hashSource = 'the committed manifest'
    }

    # Checked before the download, so the refusal costs nothing and cannot be
    # rationalised away once the bytes are already sitting on disk.
    if (-not $expected -and -not $SkipHashCheck) {
        throw "No hash is recorded for $Version and none was supplied. Pass -Sha256, or -SkipHashCheck to accept unverified bytes as a deliberate choice."
    }

    $uri = "https://github.com/$owner/$repository/releases/download/$Version/$asset"
    $staging = Join-Path -Path $env:TEMP -ChildPath ('terminal-studio-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $staging -ItemType Directory -Force
    $archive = Join-Path -Path $staging -ChildPath $asset

    Write-Host "  version   $Version"
    Write-Host "  source    $uri"

    try {
        Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing
    }
    catch {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw "Could not download $asset. $($_.Exception.Message) The manifest lists $Version, so if the asset is genuinely absent then the release was published without it."
    }

    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash

        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            throw "Hash mismatch for $asset. Expected $expected from $hashSource, got $actual. Nothing was installed."
        }

        Write-Host "  integrity verified against $hashSource"
    }
    else {
        Write-Warning 'Integrity check skipped. You are trusting the network and the host, not the contents.'
    }

    $target = Join-Path -Path $InstallRoot -ChildPath $Version

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }

    $null = New-Item -Path $target -ItemType Directory -Force
    Expand-Archive -LiteralPath $archive -DestinationPath $target -Force
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "  installed  $target"
    Write-Host ''

    $entryScript = Join-Path -Path $target -ChildPath 'ts.ps1'

    # Select-Object -First 1 because Get-Command returns every match on PATH, and a
    # machine with two installations yields an array whose .Path cannot be invoked.
    # That exact mistake made the release builder's clean-tree guard fail open, and
    # it stayed unnoticed because failing open is silent by definition.
    $pwsh = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $pwsh) {
        Write-Warning 'PowerShell 7 was not found, and Terminal Studio needs 7.4 or newer.'
        Write-Host '  winget install --id Microsoft.PowerShell --exact'
        Write-Host ('  then: pwsh -NoLogo -File "' + $entryScript + '" doctor')
        return
    }

    $reported = ''

    try {
        $reported = [string] (& $pwsh.Path -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()')
    }
    catch {
        $reported = ''
    }

    # Prerelease builds report 7.6.0-preview.2, which [Version] will not parse.
    $clean = ($reported.Trim() -replace '-.*$', '')
    $supported = $false

    if ($clean) {
        try {
            $parsed = [Version] $clean
            $supported = ($parsed.Major -gt 7) -or (($parsed.Major -eq 7) -and ($parsed.Minor -ge 4))
        }
        catch {
            $supported = $false
        }
    }

    if (-not $supported) {
        Write-Warning ('The pwsh on PATH reports ' + $clean + ', and Terminal Studio needs 7.4 or newer.')
        Write-Host '  winget install --id Microsoft.PowerShell --exact'
        Write-Host ('  then: pwsh -NoLogo -File "' + $entryScript + '" doctor')
        return
    }

    if (-not $runDoctor) {
        Write-Host 'Next:'
        Write-Host ('  pwsh -NoLogo -File "' + $entryScript + '" doctor')
        return
    }

    Write-Host 'Running doctor. It reads; it changes nothing.'
    Write-Host ''

    & $pwsh.Path -NoLogo -NoProfile -File $entryScript doctor

    Write-Host ''
    Write-Host 'Run it again any time with:'
    Write-Host ('  pwsh -NoLogo -File "' + $entryScript + '" doctor')
}

# Nothing above this line performs work; it only declares. Because the sole
# invocation is the last statement in the file, a partial download cannot produce
# a partial install.
Invoke-TSStageZero -Version $Version -Sha256 $Sha256 -InstallRoot $InstallRoot -SkipHashCheck:$SkipHashCheck -NoDoctor:$NoDoctor
