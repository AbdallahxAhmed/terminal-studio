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

        This table is the fast path, not the only path. Family-level enumeration and
        the registry both report the abbreviation and nothing else, so without these
        aliases neither could answer a question phrased in verbose names. Typeface
        inspection in Get-TSFontState can find the verbose name directly, which is
        what keeps a family missing from this table findable rather than lost - but
        it is slow, so this stays in front of it.

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

function Test-TSFontNameMatch {
    <#
    .SYNOPSIS
        Decides whether a registered font name refers to one of the given families.

    .DESCRIPTION
        This is the rule that got the font check wrong twice, so it lives here as a
        pure function rather than inline in registry enumeration - a predicate buried
        inside a loop over the live registry cannot be tested, and the two defects it
        carried were both trivially demonstrable given a name and an expectation.

        Registered names for a single family follow at least three conventions, all
        three of which were observed on one machine at the same time:

            CaskaydiaCove NFM Regular (TrueType)          spaced, abbreviated
            CaskaydiaCoveNerdFontMono-Regular (TrueType)  PostScript, hyphenated
            CaskaydiaCove Nerd Font Mono                  the plain family name

        So the style word is space-separated in one form and hyphen-separated in
        another, and the family part is spaced in one and not in the other. Three
        rules, therefore:

            equality          - the name is the family, nothing appended
            space boundary    - the family, then a style word
            hyphen boundary   - the family with spaces removed, then a style word

        The space-boundary rule is not merely defensive. A Win32 font family holds at
        most four styles - regular, bold, italic, bold italic - so a family with more
        weights is split, and the extra weights become families in their own right.
        Probing a glyph typeface for its Win32 family name returns exactly that:

            Win32FamilyNames -> CaskaydiaCove NFM ExtraLight

        Which is why the registry is full of style-suffixed entries, and why matching
        the family alone would find only a quarter of the faces.

        Each rule still requires a boundary. That is what stops any of them accepting
        'CaskaydiaCove NFP Regular' when asked about NFM: prefix matching without one
        would quietly conflate three distinct families that differ by a single
        letter.

    .PARAMETER RegisteredName
        A name as it appears in the font registry, with or without the format suffix.

    .PARAMETER Alias
        Candidate family names, normally from Get-TSFontNameAlias.

    .OUTPUTS
        True if the registered name is a face of one of the candidate families.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RegisteredName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Alias
    )

    # 'CaskaydiaCove NFM Regular (TrueType)' -> 'CaskaydiaCove NFM Regular'.
    # The suffix describes the file format and is present for OpenType files too.
    $bare = (([string] $RegisteredName) -replace '\s*\((TrueType|OpenType)\)\s*$', '').Trim()

    # 'CaskaydiaCoveNerdFontMono-Regular' -> 'CaskaydiaCoveNerdFontMono'
    $head = (($bare -replace '\s', '') -split '-', 2)[0]

    foreach ($candidate in $Alias) {
        # Escaped, because a family name is data, not a pattern. A font called
        # 'Foo [Bold]' would otherwise be read as a character class and match
        # nothing - the same category of bug as the one this function exists to fix.
        $pattern = [System.Management.Automation.WildcardPattern]::Escape($candidate)

        if ($bare -eq $candidate) {
            return $true
        }

        if ($bare -like "$pattern *") {
            return $true
        }

        if ($head -eq ($candidate -replace '\s', '')) {
            return $true
        }
    }

    $false
}

function Get-TSFontState {
    <#
    .SYNOPSIS
        Reports whether a font family is installed, and says how it knows.

    .DESCRIPTION
        Three oracles, cheapest first. The ordering is the design, not an accident.

        1. Family enumeration, via PresentationCore over the machine and per-user
           font directories. Fast, but it reports name ID 1 only - the
           GDI-compatible name, 'CaskaydiaCove NFM'. Measured rather than assumed:
           an earlier version of this file claimed it returned the verbose
           typographic name, and a probe on a real machine showed three families,
           all abbreviated.

        2. The font registry. The same namespace, kept because it fails differently.
           Enumeration reads names out of the font; the registry stores whatever the
           installer chose to write. Those diverge in practice - one machine held 48
           registry values resolving to 3 families, because an installer named its
           entries after filenames.

           Both of the above can only match through Get-TSFontNameAlias, since
           neither will ever say 'Nerd Font Mono'.

        3. Typeface inspection. One level below the family, GlyphTypeface.FamilyNames
           carries both names at once:

               CaskaydiaCove NFM / CaskaydiaCove Nerd Font Mono

           This is the only interface reachable from here that states the verbose
           name, so it is the only one that can identify a font without being told
           its abbreviation in advance. It also opens every font file it touches,
           which is why it runs last and only when the cheap paths came up empty.

           The trade is deliberate. The expensive answer is paid for precisely when
           the alternative is reporting a failure, and a slow correct answer beats a
           fast wrong one. This check has already shipped the fast wrong one.

        Returns three states rather than two. 'Unknown' exists because the original
        boolean had no way to distinguish 'this font is absent' from 'I could not
        find out', and reported both as absent. A false failure is not a safe
        default: it sends someone to fix something that is not broken, and spends the
        credibility of every other check to do it.

    .PARAMETER FamilyName
        Family name to look for, for example 'CaskaydiaCove Nerd Font Mono'.

    .OUTPUTS
        A record with State ('Installed', 'Missing' or 'Unknown'), the MatchedName
        actually found, the Method that found it, the places Searched, and a
        human-readable Detail.
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
    $method = 'None'
    $searched = [System.Collections.Generic.List[string]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()

    $directories = @(
        (Join-Path -Path $env:WINDIR -ChildPath 'Fonts')
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\Windows\Fonts')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $enumerationAvailable = $false

    try {
        Add-Type -AssemblyName 'PresentationCore' -ErrorAction Stop
        $enumerationAvailable = $true
    }
    catch {
        # Expected off Windows, and on Windows installations without the desktop
        # runtime. Not a failure of the machine, so it must not read as one.
        $reasons.Add("font enumeration unavailable ($($_.Exception.Message))")
    }

    if ($directories.Count -eq 0) {
        $reasons.Add('no font directory was readable')
    }

    # ------------------------------------------------ 1. family enumeration ---
    if ($enumerationAvailable -and $directories.Count -gt 0) {
        $searched.Add('font enumeration')

        try {
            foreach ($directory in $directories) {
                foreach ($family in [System.Windows.Media.Fonts]::GetFontFamilies($directory + '\')) {
                    $candidates = [System.Collections.Generic.List[string]]::new()

                    foreach ($name in $family.FamilyNames.Values) {
                        $candidates.Add([string] $name)
                    }

                    # Source is 'file:///C:/Windows/Fonts/#CaskaydiaCove NFM' when
                    # enumerated from a directory, so the family name is the fragment.
                    if ($family.Source) {
                        $candidates.Add((([string] $family.Source) -split '#')[-1])
                    }

                    foreach ($candidate in $candidates) {
                        if ($aliases -contains $candidate.Trim()) {
                            $matchedName = $candidate.Trim()
                            $method = 'Enumeration'
                            break
                        }
                    }

                    if ($matchedName) { break }
                }

                if ($matchedName) { break }
            }
        }
        catch {
            $reasons.Add("font enumeration failed ($($_.Exception.Message))")
        }
    }

    # ------------------------------------------------------ 2. font registry ---
    if (-not $matchedName) {
        $keys = @(
            'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        )

        $registryRan = $false

        foreach ($key in $keys) {
            if (-not (Test-Path -LiteralPath $key)) {
                continue
            }

            $registryRan = $true

            $entries = (Get-ItemProperty -LiteralPath $key).PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' }

            foreach ($entry in $entries) {
                if (Test-TSFontNameMatch -RegisteredName ([string] $entry.Name) -Alias $aliases) {
                    $matchedName = [string] $entry.Name
                    $method = 'Registry'
                    break
                }
            }

            if ($matchedName) { break }
        }

        if ($registryRan) {
            $searched.Add('the font registry')
        }
        else {
            $reasons.Add('no font registry key was readable')
        }
    }

    # -------------------------------------------------- 3. typeface inspection ---
    if (-not $matchedName -and $enumerationAvailable -and $directories.Count -gt 0) {
        $searched.Add('typeface inspection')

        try {
            foreach ($directory in $directories) {
                foreach ($family in [System.Windows.Media.Fonts]::GetFontFamilies($directory + '\')) {
                    foreach ($typeface in $family.GetTypefaces()) {
                        $glyphTypeface = $null

                        # Fails for fonts that cannot be opened - damaged files, or
                        # faces the current user cannot read. One unreadable font is
                        # not an answer about a different font, so skip and continue.
                        if (-not $typeface.TryGetGlyphTypeface([ref] $glyphTypeface)) {
                            continue
                        }

                        foreach ($name in $glyphTypeface.FamilyNames.Values) {
                            if ($aliases -contains ([string] $name).Trim()) {
                                $matchedName = ([string] $name).Trim()
                                $method = 'Typeface'
                                break
                            }
                        }

                        if ($matchedName) { break }
                    }

                    if ($matchedName) { break }
                }

                if ($matchedName) { break }
            }
        }
        catch {
            $reasons.Add("typeface inspection failed ($($_.Exception.Message))")
        }
    }

    # ------------------------------------------------------------- conclusion ---
    if ($matchedName) {
        $label = switch ($method) {
            'Enumeration' { 'font enumeration' }
            'Registry' { 'the font registry' }
            'Typeface' { 'typeface inspection' }
            default { 'an unnamed source' }
        }

        $detail = if ($matchedName -eq $FamilyName) {
            "installed, found by $label"
        }
        else {
            # Worth surfacing rather than hiding. The name Windows holds is often not
            # the name in desired state, and someone checking this against the Fonts
            # control panel needs to know which string to look for.
            "installed as '$matchedName', found by $label"
        }

        return [pscustomobject] @{
            PSTypeName  = 'TerminalStudio.FontState'
            Family      = $FamilyName
            State       = 'Installed'
            MatchedName = $matchedName
            Method      = $method
            Searched    = $searched.ToArray()
            Detail      = $detail
        }
    }

    if ($searched.Count -gt 0) {
        return [pscustomobject] @{
            PSTypeName  = 'TerminalStudio.FontState'
            Family      = $FamilyName
            State       = 'Missing'
            MatchedName = $null
            Method      = 'None'
            Searched    = $searched.ToArray()
            Detail      = "not found by $($searched -join ' or '), under any of: $($aliases -join ', ')"
        }
    }

    [pscustomobject] @{
        PSTypeName  = 'TerminalStudio.FontState'
        Family      = $FamilyName
        State       = 'Unknown'
        MatchedName = $null
        Method      = 'None'
        Searched    = @()
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
