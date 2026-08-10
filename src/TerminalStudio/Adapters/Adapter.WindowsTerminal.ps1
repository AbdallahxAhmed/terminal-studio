function Get-TSTerminalSettingsPath {
    <#
    .SYNOPSIS
        Locates the Windows Terminal settings file, or returns an empty string.

    .DESCRIPTION
        The path depends on which channel is installed, which is exactly why this
        project does not want to own this file. It is resolved anyway so that
        doctor can verify the file still parses, and so that the small set of
        genuinely global settings (defaultProfile, window theme, keybindings) can
        be merged later.

        Preview is checked first because it is what this project targets, and when
        both channels are present it is the one the user is looking at.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $localAppData = Get-TSSpecialFolder -Name 'LocalApplicationData'

    $packages = @(
        'Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe'
        'Microsoft.WindowsTerminal_8wekyb3d8bbwe'
    )

    foreach ($package in $packages) {
        $candidate = Join-Path -Path $localAppData -ChildPath "Packages\$package\LocalState\settings.json"

        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    ''
}

function Get-TSTerminalFragmentPath {
    <#
    .SYNOPSIS
        Returns the path for a Windows Terminal JSON fragment extension.

    .DESCRIPTION
        Fragments are the supported way to add colour schemes and profiles without
        touching the user's settings file. Three properties make them the right
        mechanism for almost everything this tool wants to change:

          - additive, so the user's own settings are never rewritten or lost
          - channel-independent, so Stable and Preview both read the same file
          - officially supported, so Windows Terminal will not clobber them on its
            own next write

        Compare with editing settings.json directly, which loses comments, races
        with the application's own writes, and breaks whenever the install channel
        changes.

    .PARAMETER AppName
        The fragment publisher folder name.

    .PARAMETER FragmentName
        File name without extension.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FragmentName
    )

    $localAppData = Get-TSSpecialFolder -Name 'LocalApplicationData'

    Join-Path -Path $localAppData -ChildPath "Microsoft\Windows Terminal\Fragments\$AppName\$FragmentName.json"
}

function Test-TSTerminalSettingsParse {
    <#
    .SYNOPSIS
        Reports whether the Windows Terminal settings file is still valid JSON.

    .DESCRIPTION
        Worth checking because a half-written settings file is a real failure mode
        for any tool that edits it, and because Windows Terminal silently falls
        back to defaults when the file will not parse - which the user experiences
        as their entire configuration vanishing.

        Note the absence of a -Depth argument. The predecessor passed -Depth to
        ConvertFrom-Json, which does not exist on that cmdlet in Windows
        PowerShell 5.1, and the resulting terminating error took out every theme
        function that read the file. Depth defaults are sufficient here; the
        argument was never needed in the first place.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $null = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        $true
    }
    catch {
        $false
    }
}
