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

    .PARAMETER DesiredStatePath
        Path to the desired-state document. Defaults to the copy in this repository.

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
        $results.Add((New-TSResult -Name 'Shell profile' -Status 'Warn' -Expected 'present' -Actual "missing: $profilePath" -Remediation 'Not yet deployed. This becomes a Fail once apply exists.'))
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
            switch ([string] $resource.kind) {
                'font' {
                    if (Test-TSFontInstalled -FamilyName $resource.family) {
                        $results.Add((New-TSResult -Name "Font: $($resource.family)" -Status 'Pass' -Expected 'installed' -Actual 'installed'))
                    }
                    else {
                        $results.Add((New-TSResult -Name "Font: $($resource.family)" -Status 'Fail' -Expected 'installed' -Actual 'not registered' -Remediation "Install the font, scope $(Get-TSFontScope). Glyphs in prompts and icons will render as boxes until then."))
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

                    if (Test-TSPath -Path $fragment) {
                        $results.Add((New-TSResult -Name "Terminal fragment: $($resource.name)" -Status 'Pass' -Expected 'installed' -Actual $fragment))
                    }
                    else {
                        $results.Add((New-TSResult -Name "Terminal fragment: $($resource.name)" -Status 'Fail' -Expected 'installed' -Actual "missing: $fragment" -Remediation 'Not yet deployed. This is what apply will write.'))
                    }
                }

                default {
                    # Deliberately reported rather than ignored. See Get-TSPlan.
                    $results.Add((New-TSResult -Name "Resource kind: $($resource.kind)" -Status 'Skip' -Expected 'a kind this build understands' -Actual 'not modelled in 0.1.0' -Remediation 'No check exists yet. Treat as unverified rather than healthy.'))
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
