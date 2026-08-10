#Requires -Version 7.4

Set-StrictMode -Version Latest

# Load order matters. Private and Adapters define the helpers that Public
# functions call at runtime. UI is loaded before Public only so that ts.ps1 can
# reach the renderers; nothing in Public is permitted to call them
# (docs/architecture.md, rule 2).
$loadOrder = @('Private', 'Adapters', 'UI', 'Public')

foreach ($folder in $loadOrder) {
    $dir = Join-Path -Path $PSScriptRoot -ChildPath $folder

    if (-not (Test-Path -LiteralPath $dir)) {
        continue
    }

    $files = Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object -Property Name

    foreach ($file in $files) {
        . $file.FullName
    }
}

# The exported surface is derived from the folder rather than hand-listed here,
# so the files on disk and the exports cannot silently drift apart. The manifest
# still declares the same names explicitly, which means a mismatch surfaces as a
# failed import rather than as a mystery at call time.
$publicDir = Join-Path -Path $PSScriptRoot -ChildPath 'Public'

if (Test-Path -LiteralPath $publicDir) {
    $publicNames = @(
        Get-ChildItem -LiteralPath $publicDir -Filter '*.ps1' -File |
            ForEach-Object { $_.BaseName }
    )

    if ($publicNames.Count -gt 0) {
        Export-ModuleMember -Function $publicNames
    }
}
