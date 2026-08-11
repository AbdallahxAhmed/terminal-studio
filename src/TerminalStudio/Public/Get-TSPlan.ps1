function Get-TSPlan {
    <#
    .SYNOPSIS
        Compares desired state against this machine and returns the difference.

    .DESCRIPTION
        plan is the Test operation applied across every resource in the
        desired-state document. It has no side effects, which is the whole point:
        you can see what apply would do before letting it do anything.

        Unmodelled resource kinds are reported rather than skipped quietly. This
        matters more than it looks. A plan that silently omits what it did not
        understand will report a converged machine while part of the desired state
        was never examined at all - the tool would be lying by omission, and the
        user would have no way to know.

        Status carries a promise about apply, and the two must not disagree:

          Pass  already in desired state; apply will not touch it
          Fail  apply will change this
          Warn  genuinely drifted, but apply does not manage it
          Skip  this build cannot evaluate it at all

        The Warn row exists because of terminal.global. Those values live in the
        user's own settings.json, which apply deliberately does not write, so
        reporting them as Fail would promise a change that never comes - and a dry
        run that overstates what will happen stops being worth running.

        Returns objects and prints nothing. Show-TSPlan renders them.

    .PARAMETER DesiredStatePath
        Path to the desired-state document. Defaults to the copy in this repository.

    .PARAMETER PayloadRoot
        Root that resource source paths are relative to.

    .OUTPUTS
        TerminalStudio.Result objects.

    .EXAMPLE
        Get-TSPlan | Where-Object Status -eq 'Fail'

        Show only the resources apply would change.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $DesiredStatePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\desired-state\machine.json'),

        [string] $PayloadRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..')
    )

    $state = Get-TSDesiredState -Path $DesiredStatePath
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($resource in @($state.resources)) {
        $kind = [string] $resource.kind
        $names = @($resource.PSObject.Properties.Name)

        # The four file kinds are one operation with four destinations, so they are
        # evaluated once. Handled ahead of the switch because PowerShell cannot give
        # a single branch several labels, and a comparison copied four times is a
        # comparison that will eventually exist in four slightly different versions.
        if ($kind -in @('terminal.fragment', 'terminal.asset', 'omp.theme', 'shell.profile')) {
            $label = ''
            $destination = ''

            switch ($kind) {
                'terminal.fragment' {
                    $label = "fragment/$($resource.name)"
                    $destination = Get-TSTerminalFragmentPath -AppName $resource.appName -FragmentName $resource.name
                }
                'terminal.asset' {
                    $label = "asset/$($resource.name)"
                    if ($names -contains 'destination') { $destination = Expand-TSPath -Path $resource.destination }
                }
                'omp.theme' {
                    $label = "omp/$($resource.name)"
                    if ($names -contains 'destination') { $destination = Expand-TSPath -Path $resource.destination }
                }
                'shell.profile' {
                    $label = 'profile/CurrentUserCurrentHost'
                    $destination = Get-TSProfilePath
                }
            }

            if (-not $destination -or $names -notcontains 'source') {
                $items.Add((New-TSResult -Name $label -Status 'Skip' -Expected 'a source and a destination' -Actual 'resource is incomplete' -Remediation 'This resource was NOT evaluated. Complete it in desired state.'))
                continue
            }

            $source = Join-Path -Path $PayloadRoot -ChildPath $resource.source

            if (-not (Test-TSPath -Path $source)) {
                $items.Add((New-TSResult -Name $label -Status 'Fail' -Expected $destination -Actual "managed copy absent from payload: $source" -Remediation 'apply will report this as a failure. Put the file in place first; binary assets are not committed.'))
                continue
            }

            $sourceHash = Get-TSFileHashValue -Path $source
            $deployedHash = Get-TSFileHashValue -Path $destination

            if (-not $deployedHash) {
                $items.Add((New-TSResult -Name $label -Status 'Fail' -Expected $destination -Actual 'absent' -Remediation "create $destination"))
            }
            elseif ($sourceHash -eq $deployedHash) {
                $items.Add((New-TSResult -Name $label -Status 'Pass' -Expected $destination -Actual 'matches'))
            }
            else {
                $items.Add((New-TSResult -Name $label -Status 'Fail' -Expected $destination -Actual 'differs from the managed copy' -Remediation "replace $destination, keeping a backup of the current file"))
            }

            continue
        }

        switch ($kind) {
            'winget.package' {
                $installed = Test-TSWingetPackage -Id $resource.id
                $status = if ($installed) { 'Pass' } else { 'Warn' }
                $actual = if ($installed) { 'installed' } else { 'absent' }
                $action = if ($installed) { '' } else { "apply does not install packages. Run: winget install --id $($resource.id) --exact" }

                $items.Add((New-TSResult -Name "package/$($resource.id)" -Status $status -Expected 'installed' -Actual $actual -Remediation $action))
            }

            'font' {
                $installed = Test-TSFontInstalled -FamilyName $resource.family
                $status = if ($installed) { 'Pass' } else { 'Warn' }
                $actual = if ($installed) { 'registered' } else { 'absent' }
                $action = if ($installed) { '' } else { "apply does not install fonts. Install manually, scope $(Get-TSFontScope)" }

                $items.Add((New-TSResult -Name "font/$($resource.family)" -Status $status -Expected 'registered' -Actual $actual -Remediation $action))
            }

            'psmodule' {
                $module = Get-TSModuleInstalled -Name $resource.name
                $wanted = [string] $resource.version

                if (-not $module.Installed) {
                    $items.Add((New-TSResult -Name "psmodule/$($resource.name)" -Status 'Warn' -Expected $wanted -Actual 'absent' -Remediation "apply does not install modules. Run: Install-PSResource -Name $($resource.name) -Scope CurrentUser"))
                }
                elseif ($wanted -and $module.Version -ne $wanted) {
                    # Reported as drift, not as a pass. A pinned version that does not
                    # match is the difference between reproducible and roughly similar.
                    $items.Add((New-TSResult -Name "psmodule/$($resource.name)" -Status 'Warn' -Expected $wanted -Actual $module.Version -Remediation "Install-PSResource -Name $($resource.name) -Version $wanted -Scope CurrentUser"))
                }
                else {
                    $items.Add((New-TSResult -Name "psmodule/$($resource.name)" -Status 'Pass' -Expected $wanted -Actual $module.Version))
                }
            }

            'terminal.global' {
                $settingsPath = Get-TSTerminalSettingsPath

                if (-not $settingsPath -or -not (Test-TSTerminalSettingsParse -Path $settingsPath)) {
                    $items.Add((New-TSResult -Name 'terminal/global' -Status 'Skip' -Expected 'defaultProfile and theme as declared' -Actual 'settings file absent or unreadable' -Remediation 'This resource was NOT evaluated.'))
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
                        $items.Add((New-TSResult -Name 'terminal/global' -Status 'Pass' -Expected 'declared values' -Actual 'settings.json agrees'))
                    }
                    else {
                        $items.Add((New-TSResult -Name 'terminal/global' -Status 'Warn' -Expected 'declared values' -Actual (@($mismatch) -join '; ') -Remediation 'Drifted, but apply does not write settings.json. Change it in Windows Terminal settings or drop it from desired state.'))
                    }
                }
            }

            default {
                $items.Add((New-TSResult -Name "$kind/unsupported" -Status 'Skip' -Expected 'a resource kind this build can evaluate' -Actual 'not modelled in this build' -Remediation 'This resource was NOT verified. Do not read the rest of the plan as complete coverage.'))
            }
        }
    }

    $changes = @($items | Where-Object { $_.Status -eq 'Fail' }).Count
    Write-TSLog -Message "plan evaluated $($items.Count) resource(s), $changes would change."

    $items
}
