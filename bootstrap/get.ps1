#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 0. Downloads a pinned Terminal Studio release, verifies it, and unpacks it.

.DESCRIPTION
    This is the only file in the project intended to be executed straight from the
    internet, and it is deliberately short enough to read in full beforehand.
    Fifty lines is auditable. Four hundred is theatre.

    Every constraint below follows from when this file runs, which is before
    anything at all is installed:

      - Windows PowerShell 5.1 only, because PowerShell 7 may not exist yet. No
        syntax introduced after 5.1 appears here, and tests/compat proves that by
        parsing this file with the 5.1 parser rather than trusting code review.
      - TLS 1.2 is set explicitly. 5.1 inherits a default that can still negotiate
        down on machines that are behind on updates.
      - -UseBasicParsing on every web call, because Invoke-WebRequest otherwise
        reaches for Internet Explorer's DOM engine, which may be absent or blocked.
      - All work lives inside a function invoked on the final line. If the download
        is truncated mid-transfer, what arrives defines a function and never calls
        it, instead of executing the first half of an installer. That is the
        cheapest genuinely useful mitigation available when a URL is piped into an
        interpreter.
      - -Version is mandatory. There is no default, because any default would have
        to name a branch, and a moving reference is the difference between
        installing a reviewed artifact and installing whatever was pushed most
        recently by anyone.

.PARAMETER Version
    Release tag to install, for example v0.1.0.

.PARAMETER Sha256
    Expected SHA-256 of the release archive. Without it this script refuses to
    continue unless -SkipHashCheck is passed. TLS authenticates the server, not the
    bytes it served; only a hash does that.

.PARAMETER InstallRoot
    Where to unpack. Defaults to a per-user location, so no elevation is needed.

.PARAMETER SkipHashCheck
    Proceed without integrity verification, and print a warning that says plainly
    what was given up.

.EXAMPLE
    ./get.ps1 -Version v0.1.0 -Sha256 ABC123...
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $Sha256,

    [string] $InstallRoot = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'TerminalStudio'),

    [switch] $SkipHashCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-TSStageZero {
    [CmdletBinding()]
    param(
        [string] $Version,
        [string] $Sha256,
        [string] $InstallRoot,
        [switch] $SkipHashCheck
    )

    $owner = 'AbdallahxAhmed'
    $repository = 'terminal-studio'
    $asset = "TerminalStudio-$Version.zip"
    $uri = "https://github.com/$owner/$repository/releases/download/$Version/$asset"

    # Checked before the download rather than after, so the refusal costs nothing
    # and cannot be rationalised away once the bytes are already on disk.
    if (-not $Sha256 -and -not $SkipHashCheck) {
        throw 'No -Sha256 was supplied. Pass the published release hash, or pass -SkipHashCheck to accept unverified bytes as a deliberate choice.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $staging = Join-Path -Path $env:TEMP -ChildPath ('terminal-studio-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $staging -ItemType Directory -Force
    $archive = Join-Path -Path $staging -ChildPath $asset

    Write-Host "Terminal Studio $Version"
    Write-Host "  source $uri"

    Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing

    if ($Sha256) {
        $actual = (Get-FileHash -Path $archive -Algorithm SHA256).Hash

        if ($actual -ne $Sha256.Trim().ToUpperInvariant()) {
            Remove-Item -Path $staging -Recurse -Force
            throw "Hash mismatch. Expected $Sha256 but the download was $actual. Nothing was installed."
        }

        Write-Host '  integrity verified'
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
    Remove-Item -Path $staging -Recurse -Force

    Write-Host "  installed to $target"

    # Stage 1 runs under PowerShell 7. Saying so here, with the command that fixes
    # it, is better than letting the user find out through a parse error thrown from
    # somewhere inside the module.
    $pwsh = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue
    $entry = Join-Path -Path $target -ChildPath 'ts.ps1'

    Write-Host ''

    if ($pwsh) {
        Write-Host 'Next:'
        Write-Host "  pwsh -NoLogo -File $entry doctor"
    }
    else {
        Write-Warning 'PowerShell 7 was not found, and Terminal Studio requires it.'
        Write-Host '  winget install --id Microsoft.PowerShell --exact'
        Write-Host "  then: pwsh -NoLogo -File $entry doctor"
    }
}

# Nothing above this line performs any work; it only declares. See the truncation
# note in the header. Because the sole invocation is the last statement in the
# file, a partial download cannot produce a partial install.
Invoke-TSStageZero -Version $Version -Sha256 $Sha256 -InstallRoot $InstallRoot -SkipHashCheck:$SkipHashCheck
