function Get-TSDesiredState {
    <#
    .SYNOPSIS
        Loads and validates the desired-state document.

    .DESCRIPTION
        Reads the document through the filesystem adapter rather than reading the
        file directly, because code in Private/ is not permitted to touch the
        operating system and tests/unit/Architecture.Tests.ps1 enforces that by
        inspecting the parsed syntax tree of every file.

        JSON, not YAML, for the tool's own state. Parsing is then native and the
        tool can read its own configuration without first installing a YAML
        parser - a real bootstrap concern, since this code runs on machines that
        have just been handed a fresh PowerShell. Package definitions live
        separately in winget.dsc.yaml and are passed to winget verbatim, never
        parsed here.

        The schemaVersion gate exists so that a future incompatible change fails
        loudly on an old build instead of being silently half-understood.

    .PARAMETER Path
        Path to the desired-state JSON document.

    .OUTPUTS
        The parsed desired-state document.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-TSPath -Path $Path)) {
        throw "Desired-state file not found: $Path"
    }

    $raw = Get-TSFileText -Path $Path

    try {
        $state = $raw | ConvertFrom-Json
    }
    catch {
        throw "Desired-state file is not valid JSON ($Path): $($_.Exception.Message)"
    }

    $present = @($state.PSObject.Properties.Name)

    foreach ($required in @('schemaVersion', 'resources')) {
        if ($present -notcontains $required) {
            throw "Desired-state file is missing required property '$required': $Path"
        }
    }

    if ($state.schemaVersion -ne 1) {
        throw "Unsupported desired-state schemaVersion '$($state.schemaVersion)'. This build understands version 1 only."
    }

    Write-TSLog -Message "Loaded desired state from $Path with $(@($state.resources).Count) resource(s)."

    $state
}
