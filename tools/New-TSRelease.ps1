#Requires -Version 5.1

<#
.SYNOPSIS
    Builds a Terminal Studio release archive and its SHA-256.

.DESCRIPTION
    Produces exactly the artifact bootstrap/get.ps1 expects to download:

        TerminalStudio-<Version>.zip

    with ts.ps1 at the archive root, and writes the hash alongside it. Run this,
    create the GitHub release for the same tag, attach both, and paste the
    install line it prints into the release notes.

.PARAMETER Version
    Release tag, for example v0.1.0. Must match ModuleVersion in the manifest.

.PARAMETER OutputDirectory
    Where to write the archive. Defaults to ./artifacts at the repository root.

.PARAMETER Force
    Overwrite an existing archive for this version.

.EXAMPLE
    ./tools/New-TSRelease.ps1 -Version v0.1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $OutputDirectory,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path -Path $repoRoot -ChildPath 'artifacts'
}

# What ships. Everything else is scaffolding for producing it.
$payload = @(
    'ts.ps1'
    'src'
    'desired-state'
    'bootstrap'
    'docs'
    'README.md'
    'LICENSE'
    'CHANGELOG.md'
)

$missing = @($payload | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_)) })

if ($missing) {
    throw "Payload items missing from $repoRoot`: $($missing -join ', ')"
}

# The tag and the manifest have to agree. If they do not, the artifact lies
# about its own version to everyone who installs it.
$manifestPath = Join-Path -Path $repoRoot -ChildPath 'src/TerminalStudio/TerminalStudio.psd1'
$manifest = Import-PowerShellDataFile -Path $manifestPath
$expected = $Version.TrimStart('v')

if ($manifest.ModuleVersion -ne $expected) {
    throw "Version mismatch. Tag is $Version so the manifest must read $expected, but ModuleVersion is $($manifest.ModuleVersion). Update $manifestPath or pass the matching tag."
}

$asset = "TerminalStudio-$Version.zip"
$archive = Join-Path -Path $OutputDirectory -ChildPath $asset

if ((Test-Path -LiteralPath $archive) -and -not $Force) {
    throw "$archive already exists. Pass -Force to overwrite, or bump the version."
}

$null = New-Item -Path $OutputDirectory -ItemType Directory -Force

$staging = Join-Path -Path $env:TEMP -ChildPath ('ts-release-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -Path $staging -ItemType Directory -Force

try {
    foreach ($item in $payload) {
        $source = Join-Path -Path $repoRoot -ChildPath $item

        if (Test-Path -LiteralPath $source -PathType Container) {
            Copy-Item -LiteralPath $source -Destination $staging -Recurse -Force
        }
        else {
            Copy-Item -LiteralPath $source -Destination $staging -Force
        }
    }

    # get.ps1 tells the user to run <target>\ts.ps1. Assert the layout that
    # promise depends on, here, rather than discovering it is wrong later.
    if (-not (Test-Path -LiteralPath (Join-Path $staging 'ts.ps1'))) {
        throw 'ts.ps1 is not at the archive root. bootstrap/get.ps1 depends on that path.'
    }

    if (Test-Path -LiteralPath $archive) {
        Remove-Item -LiteralPath $archive -Force
    }

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archive -CompressionLevel Optimal
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
$hashPath = "$archive.sha256"
Set-Content -LiteralPath $hashPath -Value "$hash  $asset" -Encoding ASCII

$sizeKb = [math]::Round((Get-Item -LiteralPath $archive).Length / 1KB)

$raw = 'https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1'

Write-Host ''
Write-Host "  archive  $archive  ($sizeKb KB)"
Write-Host "  sha256   $hash"
Write-Host "  written  $hashPath"
Write-Host ''
Write-Host '  Next: create the release, attach the archive, and publish this line:'
Write-Host ''
Write-Host "    & ([scriptblock]::Create((irm $raw))) -Version $Version -Sha256 $hash"
Write-Host ''
