#Requires -Version 5.1

<#
.SYNOPSIS
    Builds a Terminal Studio release archive, its SHA-256, and its release notes.

.DESCRIPTION
    Produces exactly the artifact bootstrap/get.ps1 expects to download:

        TerminalStudio-<Version>.zip

    with ts.ps1 at the archive root, plus the hash and a notes file beside it.
    Prints the gh command that publishes all of it, with the repository named
    and the tag pinned to the commit the archive was built from.

    Run it from a clean checkout. It will refuse otherwise, because an archive
    built from uncommitted changes cannot be rebuilt from the tag that names it.

    The archive is assembled entry by entry rather than with Compress-Archive, so
    that entry timestamps can be fixed and file order made ordinal. Two builds
    from the same commit on the same runtime therefore produce the same bytes and
    the same hash, which is what makes the hash in bootstrap/releases.json
    something a stranger can check rather than something they have to trust.

.PARAMETER Version
    Release tag, for example v0.3.0. Must match ModuleVersion in the manifest.

.PARAMETER OutputDirectory
    Where to write the archive. Defaults to ./artifacts at the repository root.

.PARAMETER Force
    Overwrite an existing archive for this version, and re-record it in
    releases.json if it is already listed.

.PARAMETER AllowDirty
    Build even though the working tree has uncommitted changes, or though it
    could not be determined. The artifact may not be reproducible from its tag.

.PARAMETER UpdateManifest
    Record this release in bootstrap/releases.json and set it as latest. Run this
    AFTER publishing: it downloads the published asset, hashes it, and refuses to
    write the entry unless those bytes match the archive built here.

.PARAMETER Note
    The one-line description that goes in releases.json. Required with
    -UpdateManifest, because that file is read by people deciding whether to
    install and a generated sentence would tell them nothing.

.PARAMETER SkipPublishedCheck
    Record the entry without downloading the published asset first. Only for a
    network that cannot reach github.com; it removes the guarantee that the
    recorded hash describes what is actually being served.

.EXAMPLE
    ./tools/New-TSRelease.ps1 -Version v0.3.0

.EXAMPLE
    ./tools/New-TSRelease.ps1 -Version v0.3.0 -UpdateManifest -Note 'uninstall, configure -Save, and the structured log.'

    Run after gh release create. Verifies the published bytes, then records them.
#>

# A build script rather than a cmdlet. It writes into its own output directory and
# into one file it is explicitly asked to update, and a -WhatIf that still produced
# an archive would be a promise it could not keep, so the state-changing-verb rule
# is suppressed here rather than answered with a gate that does not gate anything.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Build script; its writes are its purpose and are confined to the output directory and an explicitly requested manifest update.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $OutputDirectory,

    [switch] $Force,

    [switch] $AllowDirty,

    [switch] $UpdateManifest,

    [string] $Note = '',

    [switch] $SkipPublishedCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
    Reads HEAD out of .git rather than shelling out.

    The git process was the unreliable part: exit codes, stderr redirection,
    PATH resolution and $PSNativeCommandUseErrorActionPreference all sit between
    the question and the answer, and any of them can turn a working repository
    into a silent null. The files are plain text and are the same on every
    platform and every git version.
#>
function Get-TSHeadCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $gitDir = Join-Path -Path $Root -ChildPath '.git'

    if (-not (Test-Path -LiteralPath $gitDir)) {
        return $null
    }

    # Worktrees and submodules use a .git file that points at the real directory.
    if (Test-Path -LiteralPath $gitDir -PathType Leaf) {
        $pointer = Get-Content -LiteralPath $gitDir -TotalCount 1

        if (-not $pointer -or ([string]$pointer) -notmatch '^gitdir:\s*(.+)$') {
            return $null
        }

        $gitDir = $Matches[1].Trim()

        if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
            $gitDir = Join-Path -Path $Root -ChildPath $gitDir
        }
    }

    $headPath = Join-Path -Path $gitDir -ChildPath 'HEAD'

    if (-not (Test-Path -LiteralPath $headPath)) {
        return $null
    }

    $head = Get-Content -LiteralPath $headPath -TotalCount 1

    if (-not $head) {
        return $null
    }

    $head = ([string]$head).Trim()

    # Detached HEAD stores the commit directly.
    if ($head -match '^[0-9a-fA-F]{40}$') {
        return $head.ToLowerInvariant()
    }

    if ($head -notmatch '^ref:\s*(.+)$') {
        return $null
    }

    $ref = $Matches[1].Trim()
    $loose = Join-Path -Path $gitDir -ChildPath $ref

    if (Test-Path -LiteralPath $loose) {
        $value = Get-Content -LiteralPath $loose -TotalCount 1

        if ($value) {
            return ([string]$value).Trim().ToLowerInvariant()
        }
    }

    # A freshly cloned repository keeps its refs packed until something writes one.
    $packed = Join-Path -Path $gitDir -ChildPath 'packed-refs'

    if (Test-Path -LiteralPath $packed) {
        $pattern = '^([0-9a-fA-F]{40})\s+' + [regex]::Escape($ref) + '$'

        foreach ($line in (Get-Content -LiteralPath $packed)) {
            if ($line -match $pattern) {
                return $Matches[1].ToLowerInvariant()
            }
        }
    }

    return $null
}

$slug = 'AbdallahxAhmed/terminal-studio'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent

if ($UpdateManifest -and -not $Note) {
    throw 'Pass -Note with -UpdateManifest. The note goes into bootstrap/releases.json, which is read by people deciding whether to install this; a sentence generated from the version number would tell them nothing they cannot already see.'
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path -Path $repoRoot -ChildPath 'artifacts'
}

$commit = Get-TSHeadCommit -Root $repoRoot

# Three states, not two. Conflating "clean" with "could not tell" is how the
# previous version of this guard came to be permanently skipped without saying so.
$treeState = 'unknown'
$probeError = 'no probe ran'

# Select-Object -First 1 because two git.exe on PATH makes .Path an array, and
# invoking an array throws - which is a confusing way to learn about your PATH.
$git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $git) {
    $probeError = 'git was not found on PATH'
}
else {
    Push-Location -LiteralPath $repoRoot
    try {
        $dirty = & $git.Path 'status' '--porcelain'

        if ($LASTEXITCODE -eq 0) {
            $treeState = if ($dirty) { 'dirty' } else { 'clean' }
        }
        else {
            $probeError = "git status exited with $LASTEXITCODE"
        }
    }
    catch {
        $probeError = $_.Exception.Message
    }
    finally {
        Pop-Location
    }
}

# A tag is a claim that the artifact can be rebuilt from it. Uncommitted
# changes make that claim false, and nothing downstream would ever notice.
if ($treeState -eq 'dirty' -and -not $AllowDirty) {
    throw "Working tree at $repoRoot has uncommitted changes, so this archive could not be rebuilt from tag $Version. Commit first, build from a fresh clone, or pass -AllowDirty to accept an unreproducible release."
}

if ($treeState -eq 'unknown') {
    Write-Warning "Could not determine whether the working tree is clean ($probeError). The clean-tree check did not run, so this archive may contain changes that exist nowhere in history."
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

# Present on .NET Framework and .NET alike, but not always pre-loaded. Failures
# are reported rather than swallowed, because the build cannot continue without it
# and a missing assembly is worth naming.
foreach ($assembly in @('System.IO.Compression', 'System.IO.Compression.FileSystem')) {
    try {
        Add-Type -AssemblyName $assembly -ErrorAction Stop
    }
    catch {
        Write-Verbose "Add-Type for $assembly was not needed or not possible: $($_.Exception.Message)"
    }
}

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

    <#
        Assembled by hand instead of with Compress-Archive, for two reasons that
        both come down to the hash being checkable.

        Entry timestamps are fixed. A zip records each file's modification time,
        and a fresh clone stamps every file with the moment it was checked out, so
        two builds of the same commit differed in every entry header and therefore
        in the archive hash. Nobody could reproduce a release to verify it.

        Entry order is ordinal rather than whatever the filesystem enumerated,
        because the order of entries is part of the file too.

        What this does not promise: bit-identical output across different
        PowerShell or .NET versions, since the deflate implementation is theirs
        and can change. The hash is therefore still the authority, and this only
        makes it possible for someone else to arrive at the same one.
    #>
    $entryStamp = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

    $paths = [string[]] @(Get-ChildItem -LiteralPath $staging -Recurse -File | ForEach-Object { $_.FullName })
    [Array]::Sort($paths, [System.StringComparer]::Ordinal)

    $zip = [System.IO.Compression.ZipFile]::Open($archive, 'Create')

    try {
        foreach ($path in $paths) {
            # Forward slashes: the zip specification says so, and Windows Terminal
            # is not the only thing that will read this archive.
            $relative = $path.Substring($staging.Length + 1).Replace('\', '/')

            $entry = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                $path,
                $relative,
                [System.IO.Compression.CompressionLevel]::Optimal)

            $entry.LastWriteTime = $entryStamp
        }
    }
    finally {
        $zip.Dispose()
    }
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
$hashPath = "$archive.sha256"
Set-Content -LiteralPath $hashPath -Value "$hash  $asset" -Encoding ASCII

$sizeKb = [math]::Round((Get-Item -LiteralPath $archive).Length / 1KB)

$raw = "https://raw.githubusercontent.com/$slug/main/bootstrap/get.ps1"
$install = "& ([scriptblock]::Create((irm $raw))) -Version $Version -Sha256 $hash"
$assetUrl = "https://github.com/$slug/releases/download/$Version/$asset"

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

If this release was published by the release workflow, its provenance is
attested and can be checked against this repository:

${fence}powershell
gh attestation verify .\$asset --repo $slug
${fence}
"@

if ($commit) {
    $notes += @"


## Provenance

Built from commit $commit, which is what this tag points at. Rebuild it with
tools/New-TSRelease.ps1 from that commit: archive entry timestamps are fixed and
entry order is ordinal, so the same sources on the same PowerShell and .NET
version produce the same bytes and the same hash. A different runtime can still
compress differently, so the hash above remains the authority rather than the
recipe.
"@
}

$notesPath = Join-Path -Path $OutputDirectory -ChildPath "TerminalStudio-$Version.notes.md"

# Not Set-Content -Encoding UTF8: that means no BOM on 7 and a BOM on 5.1, and a
# BOM would render as a stray character at the top of the published page.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($notesPath, $notes, $utf8NoBom)

# --repo because gh otherwise infers the repository from the current directory's
# git remote, and every other path here is absolute, so the command reads as if
# location does not matter. --target because gh otherwise tags whatever the
# default branch happens to point at when it runs, which need not be the tree
# this archive was built from.
$command = "gh release create $Version `"$archive`" --repo $slug"

if ($commit) {
    $command += " --target $commit"
}

$command += " --title $Version --notes-file `"$notesPath`""

if ($UpdateManifest) {
    if (-not $commit) {
        throw "Refusing to record $Version in releases.json without a commit. tagCommit is the only field that ties the published asset back to a reviewable tree, and an entry without it cannot be checked by anyone."
    }

    $releasesPath = Join-Path -Path $repoRoot -ChildPath 'bootstrap/releases.json'

    if (-not (Test-Path -LiteralPath $releasesPath)) {
        throw "Release manifest not found: $releasesPath"
    }

    $document = Get-Content -LiteralPath $releasesPath -Raw | ConvertFrom-Json
    $documentFields = @($document.PSObject.Properties.Name)

    if ($documentFields -notcontains 'releases' -or $documentFields -notcontains 'latest') {
        throw "$releasesPath does not have the shape this script understands: it needs a 'releases' array and a 'latest' field."
    }

    $already = @($document.releases | Where-Object { [string] $_.version -eq $Version })

    if ($already.Count -gt 0 -and -not $Force) {
        throw "$Version is already recorded in $releasesPath. Pass -Force to replace that entry."
    }

    <#
        The published bytes are hashed, not the local ones.

        This file exists so that a stranger can verify a download, and the only
        way this entry can be wrong in a way that matters is if it describes a
        file nobody is being served. Downloading first also enforces the rule the
        manifest states about itself - that a release is recorded after it is
        published - which was previously a comment that nothing checked.
    #>
    if ($SkipPublishedCheck) {
        Write-Warning "Recording $Version without downloading $assetUrl. The hash below has not been checked against anything GitHub is serving."
    }
    else {
        $probe = Join-Path -Path $env:TEMP -ChildPath ('ts-verify-' + [Guid]::NewGuid().ToString('N') + '.zip')

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $assetUrl -OutFile $probe -UseBasicParsing
            $publishedHash = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
        }
        catch {
            throw "Could not download $assetUrl ($($_.Exception.Message)). Publish the release first - this is deliberately the step that fails when the manifest is about to describe something that does not exist yet."
        }
        finally {
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }

        if ($publishedHash -ne $hash) {
            throw "The published asset does not match the archive built here. Published $publishedHash, local $hash. Do not record this: either the upload is of a different build, or the archive was rebuilt after publishing."
        }
    }

    $entry = [pscustomobject] @{
        version   = $Version
        asset     = $asset
        sha256    = $hash
        tagCommit = $commit
        published = (Get-Date -Format 'yyyy-MM-dd')
        notes     = $Note
    }

    $document.releases = @(@($document.releases | Where-Object { [string] $_.version -ne $Version }) + $entry)
    $document.latest = $Version

    # Written without a BOM: get.ps1 fetches this file raw and parses it on 5.1,
    # where a leading byte order mark is a parse error rather than whitespace.
    $json = ConvertTo-Json -InputObject $document -Depth 10
    [System.IO.File]::WriteAllText($releasesPath, ($json + "`n"), $utf8NoBom)
}

Write-Host ''
Write-Host "  archive  $archive  ($sizeKb KB)"
Write-Host "  sha256   $hash"
Write-Host "  hashfile $hashPath"
Write-Host "  notes    $notesPath"
Write-Host "  tree     $treeState"

if ($commit) {
    Write-Host "  commit   $commit"
}
else {
    Write-Warning "Could not read HEAD from $repoRoot/.git, so the tag will point at whatever the default branch holds when you publish. Verify that is the tree this archive was built from."
}

if ($UpdateManifest) {
    Write-Host ''
    Write-Host "  recorded $Version in bootstrap/releases.json and set it as latest"
    Write-Host ''
    Write-Host '  Commit and push it, or the install one-liner keeps serving the previous release:'
    Write-Host ''
    Write-Host '    git add bootstrap/releases.json'
    Write-Host "    git commit -m `"Record $Version in the release manifest`""
    Write-Host '    git push'
    Write-Host ''
}
else {
    Write-Host ''
    Write-Host '  Publish it, from any directory:'
    Write-Host ''
    Write-Host "    $command"
    Write-Host ''
    Write-Host '  Then record it, which verifies the published bytes before writing:'
    Write-Host ''
    Write-Host "    ./tools/New-TSRelease.ps1 -Version $Version -Force -UpdateManifest -Note '<what changed>'"
    Write-Host ''
    Write-Host '  Then this is the install line, hash already filled in:'
    Write-Host ''
    Write-Host "    $install"
    Write-Host ''
}
