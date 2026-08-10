#Requires -Version 5.1

<#
.SYNOPSIS
    Builds a Terminal Studio release archive, its SHA-256, and its release notes.

.DESCRIPTION
    Produces exactly the artifact bootstrap/get.ps1 expects to download:

        TerminalStudio-<Version>.zip

    with ts.ps1 at the archive root, plus the hash and a notes file beside it.
    Prints the gh command that publishes all of it.

    Run it from a clean checkout. It will refuse otherwise, because an archive
    built from uncommitted changes cannot be rebuilt from the tag that names it.

.PARAMETER Version
    Release tag, for example v0.1.0. Must match ModuleVersion in the manifest.

.PARAMETER OutputDirectory
    Where to write the archive. Defaults to ./artifacts at the repository root.

.PARAMETER Force
    Overwrite an existing archive for this version.

.PARAMETER AllowDirty
    Build even though the working tree has uncommitted changes. The resulting
    artifact will not be reproducible from its tag.

.EXAMPLE
    ./tools/New-TSRelease.ps1 -Version v0.1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $OutputDirectory,

    [switch] $Force,

    [switch] $AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path -Path $repoRoot -ChildPath 'artifacts'
}

# A tag is a claim that the artifact can be rebuilt from it. Uncommitted
# changes make that claim false, and nothing downstream would ever notice.
$git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue

if ($git -and -not $AllowDirty) {
    $status = $null
    $isCheckout = $false

    Push-Location -LiteralPath $repoRoot
    try {
        $status = & $git.Path 'status' '--porcelain' 2>$null
        $isCheckout = ($LASTEXITCODE -eq 0)
    }
    catch {
        $isCheckout = $false
    }
    finally {
        Pop-Location
    }

    if ($isCheckout -and $status) {
        throw "Working tree at $repoRoot has uncommitted changes, so this archive could not be rebuilt from tag $Version. Commit first, build from a fresh clone, or pass -AllowDirty to accept an unreproducible release."
    }
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

    # get.ps1 tells the user to run <target>/ts.ps1. Assert the layout that
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
$install = "& ([scriptblock]::Create((irm $raw))) -Version $Version -Sha256 $hash"

# Notes go in a file rather than into --notes on the command line. Fenced
# markdown inside a quoted PowerShell argument means literal backticks inside
# a double-quoted string, and backtick is the escape character, so the command
# cannot survive being copied. --notes-file removes the problem instead of
# escaping around it.
$fence = '```'

$notes = @"
## Install

${fence}powershell
$install
${fence}

Requires PowerShell 7 to run. The bootstrap itself is Windows PowerShell 5.1
compatible, so it works before pwsh is installed.

The piped ``irm ... | iex`` form will not work here: it passes no arguments, and
-Version is mandatory, so the shell would stop and prompt mid-line. Read the
script first if you like - fetching it on its own prints it without running it.

## Verify

SHA-256 of $asset

${fence}
$hash
${fence}

${fence}powershell
(Get-FileHash .\$asset -Algorithm SHA256).Hash
${fence}

The hash is not decoration. TLS proves who served the bytes, not what the bytes
are. Passing -Sha256 is what makes this an install of a reviewed artifact rather
than an install of whatever the host returned.
"@

$notesPath = Join-Path -Path $OutputDirectory -ChildPath "TerminalStudio-$Version.notes.md"

# Not Set-Content -Encoding UTF8: that means no BOM on 7 and a BOM on 5.1, and a
# BOM would render as a stray character at the top of the published page.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($notesPath, $notes, $utf8NoBom)

Write-Host ''
Write-Host "  archive  $archive  ($sizeKb KB)"
Write-Host "  sha256   $hash"
Write-Host "  hashfile $hashPath"
Write-Host "  notes    $notesPath"
Write-Host ''
Write-Host '  Publish it:'
Write-Host ''
Write-Host "    gh release create $Version `"$archive`" --title $Version --notes-file `"$notesPath`""
Write-Host ''
Write-Host '  Then this is the install line, hash already filled in:'
Write-Host ''
Write-Host "    $install"
Write-Host ''
