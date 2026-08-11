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

function Get-TSTerminalProfileOverride {
    <#
    .SYNOPSIS
        Returns the property names a user's settings.json sets directly on one profile.

    .DESCRIPTION
        Windows Terminal composes a profile from three layers, in order: its own
        defaults, then installed fragments, then the user's settings.json. The last
        layer to mention a property wins.

        The consequence is the reason this function exists. Deploying a fragment
        that sets colorScheme and font onto a machine whose settings.json already
        sets colorScheme and font changes nothing at all, and every check that
        looks for the fragment file will report success while the terminal looks
        exactly as it did before. Checking that a file is present is not the same
        as checking that it has an effect, and only the second one is what the user
        asked for.

        Identity properties are excluded because they do not participate in
        appearance layering in a way anyone cares about: a profile has to say which
        profile it is. Everything else is returned, and it is the caller's job to
        intersect this list with the properties a specific fragment actually sets.
        Returning a verdict here instead would flag a profile that merely overrides
        tabTitle as conflicting with a colour fragment, and a warning that fires
        when nothing is wrong is a warning people learn to skip.

        Failure is silent by design and returns an empty array. This is read by
        diagnostics; an unreadable settings file is already reported by
        Test-TSTerminalSettingsParse, and reporting it twice from two checks makes
        one problem look like two.

    .PARAMETER SettingsPath
        Path to the Windows Terminal settings.json.

    .PARAMETER Guid
        Profile GUID, in braces, as it appears in the file.

    .OUTPUTS
        String array of property names. Empty when the profile is not found.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SettingsPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Guid
    )

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return @()
    }

    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        return @()
    }

    # Navigated one property at a time. Under Set-StrictMode -Version Latest,
    # reading a property that does not exist is a terminating error rather than
    # $null, and a settings file with no profiles block is unusual but legal.
    if (@($settings.PSObject.Properties.Name) -notcontains 'profiles') {
        return @()
    }

    $profiles = $settings.profiles

    if (@($profiles.PSObject.Properties.Name) -notcontains 'list') {
        return @()
    }

    $identity = @(
        'guid'
        'name'
        'source'
        'hidden'
        'commandline'
        'startingDirectory'
    )

    $match = @($profiles.list | Where-Object { [string] $_.guid -eq $Guid })

    if ($match.Count -eq 0) {
        return @()
    }

    @($match[0].PSObject.Properties.Name | Where-Object { $identity -notcontains $_ })
}
