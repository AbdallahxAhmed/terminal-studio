function Get-TSFragmentEffect {
    <#
    .SYNOPSIS
        Reports whether a Windows Terminal fragment's profile values can actually take effect.

    .DESCRIPTION
        Windows Terminal composes each profile from three layers in order: its own
        defaults, then installed fragments, then the user's settings.json. The last
        layer that mentions a property wins.

        So a fragment setting colorScheme, font and opacity, deployed onto a machine
        whose settings.json already sets those three on the same profile, changes
        nothing whatsoever. Every check that looks for the fragment file passes. The
        terminal looks exactly as it did before. That gap between 'the check is
        green' and 'the thing the user asked for happened' is the failure this
        function exists to close.

        Only properties the fragment actually sets are compared. A profile that
        overrides tabTitle does not shadow a fragment that only sets colours, and a
        warning that fires when nothing is wrong is one people learn to skip past.

        Three outcomes, not two:

          Pass  the fragment's properties are unopposed and will render
          Warn  settings.json sets the same properties and wins
          Skip  the settings file is absent or unreadable, so this is unknown

        The Skip branch is load-bearing. Get-TSTerminalProfileOverride returns an
        empty array both when a profile overrides nothing and when the file could
        not be read, and reporting the second as the first would be a green check
        that never looked at anything.

        Colour schemes defined by a fragment are not examined. A scheme with the
        same name in settings.json would also win, but the far more common shadowing
        is per-profile and modelling half the problem while claiming the whole is
        worse than stating the boundary.

    .PARAMETER FragmentSourcePath
        The fragment document to read the intended properties from.

    .PARAMETER Label
        Name for the returned result.

    .OUTPUTS
        TerminalStudio.Result
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FragmentSourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Label
    )

    $expected = 'fragment values reach the profile'

    $settingsPath = Get-TSTerminalSettingsPath

    if (-not $settingsPath) {
        return New-TSResult -Name $Label -Status 'Skip' -Expected $expected -Actual 'no Windows Terminal settings file found' -Remediation 'Whether the fragment takes effect could not be determined. This is unverified, not healthy.'
    }

    if (-not (Test-TSTerminalSettingsParse -Path $settingsPath)) {
        return New-TSResult -Name $Label -Status 'Skip' -Expected $expected -Actual 'settings file will not parse' -Remediation 'Fix the settings file first. Until it parses, nothing can be said about which layer wins.'
    }

    if (-not (Test-TSPath -Path $FragmentSourcePath)) {
        return New-TSResult -Name $Label -Status 'Skip' -Expected $expected -Actual "fragment source not readable: $FragmentSourcePath" -Remediation 'The intended properties could not be read, so nothing can be compared.'
    }

    try {
        $fragment = Get-TSFileText -Path $FragmentSourcePath | ConvertFrom-Json
    }
    catch {
        return New-TSResult -Name $Label -Status 'Skip' -Expected $expected -Actual 'fragment source is not valid JSON' -Remediation 'Windows Terminal discards fragments it cannot parse without reporting an error. Fix the fragment.'
    }

    if (@($fragment.PSObject.Properties.Name) -notcontains 'profiles') {
        return New-TSResult -Name $Label -Status 'Pass' -Expected $expected -Actual 'fragment sets no profile properties'
    }

    $shadowed = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($fragment.profiles)) {
        $names = @($entry.PSObject.Properties.Name)

        # 'updates' names the profile being extended rather than being a property
        # applied to it, so it is the key and not part of the payload.
        if ($names -notcontains 'updates') {
            continue
        }

        $guid = [string] $entry.updates
        $intended = @($names | Where-Object { $_ -ne 'updates' })
        $overridden = @(Get-TSTerminalProfileOverride -SettingsPath $settingsPath -Guid $guid)

        foreach ($property in $intended) {
            if ($overridden -contains $property) {
                $shadowed.Add($property)
            }
        }
    }

    if ($shadowed.Count -eq 0) {
        return New-TSResult -Name $Label -Status 'Pass' -Expected $expected -Actual 'no competing values in settings.json'
    }

    $list = (@($shadowed | Sort-Object -Unique) -join ', ')

    New-TSResult -Name $Label -Status 'Warn' -Expected $expected -Actual "settings.json overrides and wins: $list" -Remediation 'Open Settings, select the profile, and use the reset arrow on each of those to clear the local override. Until then the fragment is installed and has no visible effect.'
}
