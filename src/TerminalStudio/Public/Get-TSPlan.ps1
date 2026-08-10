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

        Returns objects and prints nothing. Show-TSPlan renders them.

    .PARAMETER DesiredStatePath
        Path to the desired-state document. Defaults to the copy in this repository.

    .OUTPUTS
        TerminalStudio.Result objects. Status Pass means already in desired state,
        Fail means a change is required, Skip means this build cannot verify it.

    .EXAMPLE
        Get-TSPlan | Where-Object Status -eq 'Fail'

        Show only the resources that would change.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $DesiredStatePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\desired-state\machine.json')
    )

    $state = Get-TSDesiredState -Path $DesiredStatePath
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($resource in @($state.resources)) {
        switch ([string] $resource.kind) {
            'winget.package' {
                $installed = Test-TSWingetPackage -Id $resource.id
                $status = if ($installed) { 'Pass' } else { 'Fail' }
                $actual = if ($installed) { 'installed' } else { 'absent' }
                $action = if ($installed) { '' } else { "winget install --id $($resource.id) --exact" }

                $items.Add((New-TSResult -Name "package/$($resource.id)" -Status $status -Expected 'installed' -Actual $actual -Remediation $action))
            }

            'font' {
                $installed = Test-TSFontInstalled -FamilyName $resource.family
                $status = if ($installed) { 'Pass' } else { 'Fail' }
                $actual = if ($installed) { 'registered' } else { 'absent' }
                $action = if ($installed) { '' } else { "install font, scope $(Get-TSFontScope)" }

                $items.Add((New-TSResult -Name "font/$($resource.family)" -Status $status -Expected 'registered' -Actual $actual -Remediation $action))
            }

            'psmodule' {
                $module = Get-TSModuleInstalled -Name $resource.name
                $wanted = [string] $resource.version

                if (-not $module.Installed) {
                    $items.Add((New-TSResult -Name "psmodule/$($resource.name)" -Status 'Fail' -Expected $wanted -Actual 'absent' -Remediation "Install-PSResource -Name $($resource.name) -Scope CurrentUser"))
                }
                elseif ($wanted -and $module.Version -ne $wanted) {
                    # Reported as drift, not as a pass. A pinned version that does not
                    # match is the difference between reproducible and roughly similar.
                    $items.Add((New-TSResult -Name "psmodule/$($resource.name)" -Status 'Fail' -Expected $wanted -Actual $module.Version -Remediation "Install-PSResource -Name $($resource.name) -Version $wanted -Scope CurrentUser"))
                }
                else {
                    $items.Add((New-TSResult -Name "psmodule/$($resource.name)" -Status 'Pass' -Expected $wanted -Actual $module.Version))
                }
            }

            'terminal.fragment' {
                $target = Get-TSTerminalFragmentPath -AppName $resource.appName -FragmentName $resource.name
                $present = Test-TSPath -Path $target
                $status = if ($present) { 'Pass' } else { 'Fail' }
                $actual = if ($present) { $target } else { 'absent' }
                $action = if ($present) { '' } else { "write fragment to $target" }

                $items.Add((New-TSResult -Name "fragment/$($resource.name)" -Status $status -Expected $target -Actual $actual -Remediation $action))
            }

            default {
                $items.Add((New-TSResult -Name "$($resource.kind)/unsupported" -Status 'Skip' -Expected 'a resource kind this build can evaluate' -Actual 'not modelled in 0.1.0' -Remediation 'This resource was NOT verified. Do not read the rest of the plan as complete coverage.'))
            }
        }
    }

    $changes = @($items | Where-Object { $_.Status -eq 'Fail' }).Count
    Write-TSLog -Message "plan evaluated $($items.Count) resource(s), $changes would change."

    $items
}
