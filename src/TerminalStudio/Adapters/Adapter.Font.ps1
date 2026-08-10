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

function Get-TSFontNameAlias {
    <#
    .SYNOPSIS
        Expands a Nerd Font family name into the names Windows may have stored it under.

    .DESCRIPTION
        Nerd Fonts v3 gives one face two family names, because the naming systems it
        has to satisfy have different length limits. The verbose name goes where long
        names fit; the abbreviated one goes where they do not:

            Nerd Font        -> NF
            Nerd Font Mono   -> NFM
            Nerd Font Propo  -> NFP

        So 'CaskaydiaCove Nerd Font Mono' and 'CaskaydiaCove NFM' are the same font,
        and which one you see depends entirely on which API you asked. Upstream lists
        CascadiaCode among the families affected by this.

        Anything that matches font names by string has to know this, or it will
        confidently report a missing font that is installed and in use.

    .PARAMETER FamilyName
        The family name as written in desired state, for example
        'CaskaydiaCove Nerd Font Mono'.

    .OUTPUTS
        One or more candidate family names, most specific first.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FamilyName
    )

    $aliases = [System.Collections.Generic.List[string]]::new()
    $aliases.Add($FamilyName)

    # Ordered, and longest first: 'Nerd Font Mono' has to be tried before
    # 'Nerd Font', or every Mono face collapses into the proportional alias.
    $abbreviations = [ordered] @{
        'Nerd Font Propo' = 'NFP'
        'Nerd Font Mono'  = 'NFM'
        'Nerd Font'       = 'NF'
    }

    foreach ($long in $abbreviations.Keys) {
        if ($FamilyName -like "*$long*") {
            $aliases.Add(($FamilyName -replace [regex]::Escape($long), $abbreviations[$long]))
            break
        }
    }

    $aliases.ToArray() | Select-Object -Unique
}

function Get-TSFontState {
    <#
    .SYNOPSIS
        Reports whether a font family is installed, and says how it knows.

    .DESCRIPTION
        Two oracles, asked in order of authority.

        DirectWrite first. It is the font system Windows Terminal, VS Code and every
        other modern client actually resolve through, and it exposes typographic
        family names - the long ones users type into settings.json. Both the machine
        font directory and the per-user one are enumerated, because a font installed
        without admin rights lives only in the latter.

        The font registry second, as a fallback. It is worth asking because it is
        cheap and always available, but it is a different namespace: it stores GDI
        names, which for Nerd Fonts are the abbreviated ones, with a style word and a
        format suffix attached. 'CaskaydiaCove NFM Regular (TrueType)' and
        'CaskaydiaCove Nerd Font Mono' are the same font.

        Returns three states rather than two. 'Unknown' exists because the previous
        boolean had no way to distinguish 'this font is absent' from 'I could not
        find out', and reported both as absent. A false failure is not a safe
        default: it sends someone to fix something that is not broken, and spends
        the credibility of every other check to do it.

    .PARAMETER FamilyName
        Family name to look for, for example 'CaskaydiaCove Nerd Font Mono'.

    .OUTPUTS
        A record with State ('Installed', 'Missing' or 'Unknown'), the MatchedName
        actually found, the Method that found it, and a human-readable Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FamilyName
    )

    $aliases = @(Get-TSFontNameAlias -FamilyName $FamilyName)

    $matchedName = $null
    $method = $null
    $directWriteRan = $false
    $registryRan = $false
    $reasons = [System.Collections.Generic.List[string]]::new()

    # ------------------------------------------------------------ DirectWrite ---
    try {
        Add-Type -AssemblyName 'PresentationCore' -ErrorAction Stop

        $directories = @(
            (Join-Path -Path $env:WINDIR -ChildPath 'Fonts')
            (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\Windows\Fonts')
        )

        foreach ($directory in $directories) {
            if (-not (Test-Path -LiteralPath $directory)) {
                continue
            }

            $directWriteRan = $true

            foreach ($family in [System.Windows.Media.Fonts]::GetFontFamilies($directory + '\')) {
                $candidates = [System.Collections.Generic.List[string]]::new()

                foreach ($name in $family.FamilyNames.Values) {
                    $candidates.Add([string] $name)
                }

                # Source is 'file:///C:/Windows/Fonts/#Family Name' when enumerated.
                if ($family.Source) {
                    $candidates.Add((([string] $family.Source) -split '#')[-1])
                }

                foreach ($candidate in $candidates) {
                    if ($aliases -contains $candidate.Trim()) {
                        $matchedName = $candidate.Trim()
                        $method = 'DirectWrite'
                        break
                    }
                }

                if ($matchedName) { break }
            }

            if ($matchedName) { break }
        }
    }
    catch {
        $reasons.Add("DirectWrite enumeration unavailable ($($_.Exception.Message))")
    }

    # --------------------------------------------------------------- registry ---
    if (-not $matchedName) {
        $keys = @(
            'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        )

        foreach ($key in $keys) {
            if (-not (Test-Path -LiteralPath $key)) {
                continue
            }

            $registryRan = $true

            $entries = (Get-ItemProperty -LiteralPath $key).PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' }

            foreach ($entry in $entries) {
                # 'CaskaydiaCove NFM Regular (TrueType)' -> 'CaskaydiaCove NFM Regular'
                $bare = ([string] $entry.Name) -replace '\s*\((TrueType|OpenType)\)\s*$', ''
                $bare = $bare.Trim()

                foreach ($alias in $aliases) {
                    # Exact, or the alias followed by a style word such as Regular or Bold.
                    if ($bare -eq $alias -or $bare -like "$alias *") {
                        $matchedName = [string] $entry.Name
                        $method = 'Registry'
                        break
                    }
                }

                if ($matchedName) { break }
            }

            if ($matchedName) { break }
        }

        if (-not $registryRan) {
            $reasons.Add('no font registry key was readable')
        }
    }

    # ------------------------------------------------------------- conclusion ---
    if ($matchedName) {
        $detail = if ($matchedName -eq $FamilyName) {
            "installed (via $method)"
        }
        else {
            # Worth surfacing rather than hiding. Someone comparing this against the
            # Fonts control panel will see the abbreviated name and needs to know why.
            "installed as '$matchedName' (via $method)"
        }

        return [pscustomobject] @{
            PSTypeName  = 'TerminalStudio.FontState'
            Family      = $FamilyName
            State       = 'Installed'
            MatchedName = $matchedName
            Method      = $method
            Detail      = $detail
        }
    }

    if ($directWriteRan -or $registryRan) {
        $searched = @()
        if ($directWriteRan) { $searched += 'DirectWrite' }
        if ($registryRan) { $searched += 'font registry' }

        return [pscustomobject] @{
            PSTypeName  = 'TerminalStudio.FontState'
            Family      = $FamilyName
            State       = 'Missing'
            MatchedName = $null
            Method      = ($searched -join ' and ')
            Detail      = "not found in $($searched -join ' or '), under any of: $($aliases -join ', ')"
        }
    }

    [pscustomobject] @{
        PSTypeName  = 'TerminalStudio.FontState'
        Family      = $FamilyName
        State       = 'Unknown'
        MatchedName = $null
        Method      = 'none'
        Detail      = "could not enumerate installed fonts: $($reasons -join '; ')"
    }
}

function Test-TSFontInstalled {
    <#
    .SYNOPSIS
        Reports whether a font family is installed.

    .DESCRIPTION
        A boolean view of Get-TSFontState, kept for callers that only need yes or no.
        Note that it collapses 'Unknown' into false, which is exactly the conflation
        that produced a false failure in 0.1.0 - so prefer Get-TSFontState anywhere
        the answer is shown to a human.

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

    (Get-TSFontState -FamilyName $FamilyName).State -eq 'Installed'
}
