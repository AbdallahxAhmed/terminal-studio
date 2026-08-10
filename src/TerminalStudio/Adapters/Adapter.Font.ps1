function Get-TSFontScope {
    <#
    .SYNOPSIS
        Reports whether fonts can be installed for the current user without admin rights.

    .DESCRIPTION
        Per-user font installation arrived in Windows 10 1809 (build 17763). Below
        that, registering a font requires administrator rights, which changes the
        entire shape of the bootstrap - elevation, a UAC prompt, and a machine-wide
        change that is harder to reverse.

        This is a capability question, not a preference, which is why it is
        answered from the OS build rather than configured.

    .OUTPUTS
        'CurrentUser' or 'Machine'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ((Get-TSOSBuild) -ge 17763) {
        return 'CurrentUser'
    }

    'Machine'
}

function Test-TSFontInstalled {
    <#
    .SYNOPSIS
        Reports whether a font family appears registered, per-user or machine-wide.

    .DESCRIPTION
        Both hives are checked because a font may have been installed for the
        current user by this tool or machine-wide by someone else, and either one
        means the glyphs will render.

    .PARAMETER FamilyName
        Family name to look for, for example 'CaskaydiaCove Nerd Font Mono'.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FamilyName
    )

    $keys = @(
        'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )

    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) {
            continue
        }

        $entries = (Get-ItemProperty -LiteralPath $key).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' }

        foreach ($entry in $entries) {
            # Registered value names carry style and format suffixes, such as
            # 'CaskaydiaCove NF Mono (TrueType)', so an equality check would report
            # a missing font that is in fact installed. Contains is the honest test.
            if ($entry.Name -like "*$FamilyName*") {
                return $true
            }
        }
    }

    $false
}
