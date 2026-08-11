function Invoke-TSDoctor {
    <#
    .SYNOPSIS
        Runs read-only capability and drift checks against this machine.

    .DESCRIPTION
        doctor is implemented before plan and before apply, deliberately:

          - It is harmless. It changes nothing, so it can be pointed at a real
            machine on day one.
          - It is half of apply. Every desired-state resource needs a Test
            operation, and these checks are those tests.
          - It answers the questions that actually cause pain: wrong PowerShell
            edition, missing winget, redirected Documents, missing fonts, a
            settings file that no longer parses, a shell that got slow.

        Returns result objects and prints nothing. Rendering is
        Show-TSDoctorReport's job (docs/architecture.md, rule 2), which is exactly
        what allows this function to be asserted in a test with no terminal
        attached.

        Every check reports Expected, Actual, and a remediation. A diagnostic that
        says something is wrong without saying what to do has only moved the
        problem into the user's head.

        A check that cannot run reports Warn or Skip, never Fail. Those are
        different claims: one says the machine is wrong, the other says the check
        could not look. Conflating them spends the credibility of every other
        result in the report.

        Managed files are compared by content hash, not by existence. Existence is
        the easier question and the wrong one - a fragment deployed before its
        source was last edited exists, is stale, and passes an existence test
        while the machine no longer matches what the repository says it should be.
        The comparison here is the same one apply uses to decide whether to write,
        which is what keeps the two from disagreeing.

    .PARAMETER DesiredStatePath
        Path to the desired-state document. Defaults to the copy in this repository.

    .PARAMETER PayloadRoot
        Root that resource source paths are relative to.

    .PARAMETER StartupBudgetMs
        Cold-start budget for a new shell, in milliseconds.

    .PARAMETER SkipStartupMeasurement
        Skip the startup measurement. It launches real shells and is by far the
        slowest check, so CI usually wants it off.

    .OUTPUTS
        TerminalStudio.Result objects.

    .EXAMPLE
        Invoke-TSDoctor | Where-Object Status -eq 'Fail'

        Show only what is actually broken.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $DesiredStatePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\desired-state\machine.json'),

        [string] $PayloadRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..'),

        [ValidateRange(100, 60000)]
        [int] $StartupBudgetMs = 1000,

        [switch] $SkipStartupMeasurement
    )

    $results = [System.Collections.Generic.List[object]]::new()

    # ------------------------------------------------------------- engine ---
    $engine = Get-TSPsInfo
    $engineActual = "$($engine.Edition) $($engine.Version)"

    if ($engine.Edition -eq 'Core' -and [version] $engine.Version -ge [version] '7.4') {
        $results.Add((New-TSResult -Name 'PowerShell engine' -Status 'Pass' -Expected 'Core 7.4 or later' -Actual $engineActual))
    }
    else {
        $results.Add((New-TSResult -Name 'PowerShell engine' -Status 'Fail' -Expected 'Core 7.4 or later' -Actual $engineActual -Remediation 'Relaunch with pwsh. If absent: winget install --id Microsoft.PowerShell --exact'))
    }

    # ---------------------------------------------------------- OS capability ---
    $build = Get-TSOSBuild

    if ($build -ge 17763) {
        $results.Add((New-TSResult -Name 'Per-user font support' -Status 'Pass' -Expected 'build 17763 or later' -Actual "build $build"))
    }
    else {
        $results.Add((New-TSResult -Name 'Per-user font support' -Status 'Warn' -Expected 'build 17763 or later' -Actual "build $build" -Remediation 'Fonts will need administrator rights to install machine-wide on this build.'))
    }

    # --------------------------------------------------------------- winget ---
    if (Test-TSWingetPresent) {
        $results.Add((New-TSResult -Name 'winget client' -Status 'Pass' -Expected 'present' -Actual (Get-TSWingetVersion)))
    }
    else {
        $results.Add((New-TSResult -Name 'winget client' -Status 'Fail' -Expected 'present' -Actual 'not found' -Remediation 'Install App Installer from the Microsoft Store. All package work is delegated to winget.'))
    }

    # ------------------------------------------------------------- Documents ---
    if (Test-TSDocumentsRedirected) {
        $results.Add((New-TSResult -Name 'Documents folder' -Status 'Warn' -Expected 'not redirected' -Actual (Get-TSSpecialFolder -Name 'MyDocuments') -Remediation 'Documents is redirected, most likely by OneDrive. This is supported, but never hand-build the profile path from the user profile directory.'))
    }
    else {
        $results.Add((New-TSResult -Name 'Documents folder' -Status 'Pass' -Expected 'not redirected' -Actual (Get-TSSpecialFolder -Name 'MyDocuments')))
    }

    # --------------------------------------------------------------- profile ---
    $profilePath = Get-TSProfilePath

    if (Test-TSPath -Path $profilePath) {
        $results.Add((New-TSResult -Name 'Shell profile' -Status 'Pass' -Expected 'present' -Actual $profilePath))
    }
    else {
        $results.Add((New-TSResult -Name 'Shell profile' -Status 'Fail' -Expected 'present' -Actual "missing: $profilePath" -Remediation 'Run: ts.ps1 apply'))
    }

    # ----------------------------------------------- Windows Terminal settings ---
    $settingsPath = Get-TSTerminalSettingsPath

    if (-not $settingsPath) {
        $results.Add((New-TSResult -Name 'Windows Terminal settings' -Status 'Fail' -Expected 'installed and readable' -Actual 'no settings file found for either channel' -Remediation 'winget install --id Microsoft.WindowsTerminal --exact'))
    }
    elseif (Test-TSTerminalSettingsParse -Path $settingsPath) {
        $results.Add((New-TSResult -Name 'Windows Terminal settings' -Status 'Pass' -Expected 'valid JSON' -Actual $settingsPath))
    }
    else {
        $results.Add((New-TSResult -Name 'Windows Terminal settings' -Status 'Fail' -Expected 'valid JSON' -Actual "will not parse: $settingsPath" -Remediation 'Windows Terminal silently falls back to defaults when this file is invalid. Restore it from a backup or let the application regenerate it.'))
    }

    # ---------------------------------------------- desired-state driven checks ---
    $state = $null

    try {
        $state = Get-TSDesiredState -Path $DesiredStatePath
    }
    catch {
        $results.Add((New-TSResult -Name 'Desired state' -Status 'Fail' -Expected "readable document at $DesiredStatePath" -Actual $_.Exception.Message -Remediation 'Fix or restore desired-state/machine.json. Checks that depend on it were skipped.'))
    }

    if ($state) {
        $results.Add((New-TSResult -Name 'Desired state' -Status 'Pass' -Expected 'schemaVersion 1' -Actual "$(@($state.resources).Count) resource(s) from $DesiredStatePath"))

        foreach ($resource in @($state.resources)) {
            $kind = [string] $resource.kind
            $names = @($resource.PSObject.Properties.Name)

            # Three kinds differ only in where the file lands, so they are checked
            # once rather than three times. Handled before the switch because
            # PowerShell has no way to give one branch several labels, and copying
            # the comparison into three branches is how two of them eventually stop
            # matching the third.
            if ($kind -in @('terminal.asset', 'omp.theme', 'shell.profile')) {
                $label = ''
                $destination = ''

                switch ($kind) {
                    'terminal.asset' {
                        $label = "Asset: $($resource.name)"
                        if ($names -contains 'destination') { $destination = Expand-TSPath -Path $resource.destination }
                    }
                    'omp.theme' {
                        $label = "Prompt theme: $($resource.name)"
                        if ($names -contains 'destination') { $destination = Expand-TSPath -Path $resource.destination }
                    }
                    'shell.profile' {
                        $label = 'Shell profile content'
                        $destination = Get-TSProfilePath
                    }
                }

                if (-not $destination) {
                    $results.Add((New-TSResult -Name $label -Status 'Fail' -Expected 'a destination' -Actual 'resource declares no destination' -Remediation 'Add a destination property to this resource in desired state.'))
                }
                elseif ($names -notcontains 'source') {
                    $results.Add((New-TSResult -Name $label -Status 'Fail' -Expected 'a source file' -Actual 'resource declares no source' -Remediation 'Add a source property to this resource in desired state.'))
                }
                else {
                    $source = Join-Path -Path $PayloadRoot -ChildPath $resource.source

                    if (-not (Test-TSPath -Path $source)) {
                        $results.Add((New-TSResult -Name $label -Status 'Fail' -Expected $destination -Actual "the managed copy is not in the payload: $source" -Remediation 'This resource cannot be applied until that file exists. Binary assets are not committed to the repository and have to be placed by hand.'))
                    }
                    else {
                        $sourceHash = Get-TSFileHashValue -Path $source
                        $deployedHash = Get-TSFileHashValue -Path $destination

                        if (-not $deployedHash) {
                            $results.Add((New-TSResult -Name $label -Status 'Fail' -Expected $destination -Actual 'not deployed' -Remediation 'Run: ts.ps1 apply'))
                        }
                        elseif ($sourceHash -eq $deployedHash) {
                            $results.Add((New-TSResult -Name $label -Status 'Pass' -Expected $destination -Actual 'matches the managed copy'))
                        }
                        else {
                            # Drift, which an existence check cannot see at all.
                            $results.Add((New-TSResult -Name $label -Status 'Fail' -Expected $destination -Actual 'deployed, but the contents differ from the managed copy' -Remediation 'Run: ts.ps1 apply   The current file is backed up before it is replaced.'))
                        }
                    }
                }

                continue
            }

            switch ($kind) {
                'font' {
                    $font = Get-TSFontState -FamilyName $resource.family

                    switch ([string] $font.State) {
                        'Installed' {
                            # Detail carries the name it was found under. When that differs
                            # from the requested family - 'CaskaydiaCove NFM Regular' for
                            # 'CaskaydiaCove Nerd Font Mono' - saying so is the difference
                            # between a result and a claim.
                            $results.Add((New-TSResult -Name "Font: $($resource.family)" -Status 'Pass' -Expected 'installed' -Actual $font.Detail))
                        }

                        'Missing' {
                            $results.Add((New-TSResult -Name "Font: $($resource.family)" -Status 'Fail' -Expected 'installed' -Actual $font.Detail -Remediation "Install the font, scope $(Get-TSFontScope). Glyphs in prompts and icons will render as boxes until then."))
                        }

                        default {
                            $results.Add((New-TSResult -Name "Font: $($resource.family)" -Status 'Warn' -Expected 'installed' -Actual $font.Detail -Remediation 'Neither font system could be enumerated, so this is unverified rather than broken. Check the font dropdown in Windows Terminal settings before installing anything.'))
                        }
                    }
                }

                'winget.package' {
                    if (Test-TSWingetPackage -Id $resource.id) {
                        $results.Add((New-TSResult -Name "Package: $($resource.id)" -Status 'Pass' -Expected 'installed' -Actual 'installed'))
                    }
                    else {
                        $results.Add((New-TSResult -Name "Package: $($resource.id)" -Status 'Fail' -Expected 'installed' -Actual 'not installed' -Remediation "winget install --id $($resource.id) --exact"))
                    }
                }

                'psmodule' {
                    $module = Get-TSModuleInstalled -Name $resource.name

                    if ($module.Installed) {
                        $results.Add((New-TSResult -Name "Module: $($resource.name)" -Status 'Pass' -Expected 'available' -Actual $module.Version))
                    }
                    else {
                        $results.Add((New-TSResult -Name "Module: $($resource.name)" -Status 'Fail' -Expected 'available' -Actual 'not installed' -Remediation "Install-PSResource -Name $($resource.name) -Scope CurrentUser"))
                    }
                }

                'terminal.fragment' {
                    $fragment = Get-TSTerminalFragmentPath -AppName $resource.appName -FragmentName $resource.name
                    $source = if ($names -contains 'source') { Join-Path -Path $PayloadRoot -ChildPath $resource.source } else { '' }

                    if (-not (Test-TSPath -Path $fragment)) {
                        $results.Add((New-TSResult -Name "Terminal fragment: $($resource.name)" -Status 'Fail' -Expected 'installed' -Actual "missing: $fragment" -Remediation 'Run: ts.ps1 apply'))
                    }
                    elseif ($source -and (Test-TSPath -Path $source) -and (Get-TSFileHashValue -Path $source) -ne (Get-TSFileHashValue -Path $fragment)) {
                        $results.Add((New-TSResult -Name "Terminal fragment: $($resource.name)" -Status 'Fail' -Expected 'matches the managed copy' -Actual 'deployed, but out of date' -Remediation 'Run: ts.ps1 apply   The current file is backed up before it is replaced.'))
                    }
                    else {
                        $results.Add((New-TSResult -Name "Terminal fragment: $($resource.name)" -Status 'Pass' -Expected 'installed' -Actual $fragment))
                    }

                    # A separate question from whether the file is there, and the one
                    # the user actually cares about. Windows Terminal applies user
                    # settings after fragments, so a correctly deployed fragment can
                    # be entirely invisible.
                    if ($source) {
                        $results.Add((Get-TSFragmentEffect -FragmentSourcePath $source -Label "Fragment effect: $($resource.name)"))
                    }
                }

                'terminal.global' {
                    if (-not $settingsPath) {
                        $results.Add((New-TSResult -Name 'Terminal global settings' -Status 'Skip' -Expected 'defaultProfile and theme as declared' -Actual 'no settings file found' -Remediation 'Unverified rather than healthy.'))
                    }
                    elseif (-not (Test-TSTerminalSettingsParse -Path $settingsPath)) {
                        $results.Add((New-TSResult -Name 'Terminal global settings' -Status 'Skip' -Expected 'defaultProfile and theme as declared' -Actual 'settings file will not parse' -Remediation 'Already reported above. Fix that first.'))
                    }
                    else {
                        $settings = Get-TSFileText -Path $settingsPath | ConvertFrom-Json
                        $settingsNames = @($settings.PSObject.Properties.Name)
                        $mismatch = [System.Collections.Generic.List[string]]::new()

                        foreach ($property in @('defaultProfile', 'theme')) {
                            if ($names -notcontains $property) { continue }

                            $wanted = [string] $resource.$property
                            $observed = if ($settingsNames -contains $property) { [string] $settings.$property } else { '(unset)' }

                            if ($observed -ne $wanted) {
                                $mismatch.Add("$property is $observed, desired $wanted")
                            }
                        }

                        if ($mismatch.Count -eq 0) {
                            $results.Add((New-TSResult -Name 'Terminal global settings' -Status 'Pass' -Expected 'defaultProfile and theme as declared' -Actual 'settings.json agrees'))
                        }
                        else {
                            # Deliberately not offered as something apply will fix. apply
                            # does not write settings.json, and a remediation naming a
                            # command that will not do the job is worse than none.
                            $results.Add((New-TSResult -Name 'Terminal global settings' -Status 'Warn' -Expected 'defaultProfile and theme as declared' -Actual (@($mismatch) -join '; ') -Remediation 'These live in your own settings.json, which apply does not modify. Change them in Windows Terminal settings, or drop them from desired state.'))
                        }
                    }
                }

                default {
                    # Deliberately reported rather than ignored. See Get-TSPlan.
                    $results.Add((New-TSResult -Name "Resource kind: $kind" -Status 'Skip' -Expected 'a kind this build understands' -Actual 'not modelled in this build' -Remediation 'No check exists yet. Treat as unverified rather than healthy.'))
                }
            }
        }
    }

    # -------------------------------------------------------------- startup ---
    if ($SkipStartupMeasurement) {
        $results.Add((New-TSResult -Name 'Shell startup' -Status 'Skip' -Expected "under $StartupBudgetMs ms" -Actual 'measurement skipped'))
    }
    else {
        $elapsed = Measure-TSShellStartup

        if ($elapsed -lt 0) {
            $results.Add((New-TSResult -Name 'Shell startup' -Status 'Skip' -Expected "under $StartupBudgetMs ms" -Actual 'pwsh not found, cannot measure'))
        }
        elseif ($elapsed -le $StartupBudgetMs) {
            $results.Add((New-TSResult -Name 'Shell startup' -Status 'Pass' -Expected "under $StartupBudgetMs ms" -Actual "$elapsed ms"))
        }
        else {
            $results.Add((New-TSResult -Name 'Shell startup' -Status 'Warn' -Expected "under $StartupBudgetMs ms" -Actual "$elapsed ms" -Remediation 'Profile cold start is over budget. Usual suspects are prompt initialisation and icon modules loaded eagerly.'))
        }
    }

    Write-TSLog -Message "doctor completed $($results.Count) check(s)."

    $results
}
