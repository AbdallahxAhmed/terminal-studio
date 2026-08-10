#Requires -Version 7.4

<#
    Unit suite for the module surface and the diagnostic contract.

    These tests are cheap and they run on a machine with almost none of the target
    software installed, which is intentional. They assert the shape of the answers,
    not the answers themselves. A CI runner with no Windows Terminal and no fonts is
    a perfectly good place to verify that a failing check still explains itself.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/TerminalStudio/TerminalStudio.psd1'

    Import-Module -Name $script:manifestPath -Force
}

AfterAll {
    Remove-Module -Name 'TerminalStudio' -Force -ErrorAction SilentlyContinue
}

Describe 'module surface' {

    It 'imports from its manifest' {
        Get-Module -Name 'TerminalStudio' | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the commands it claims' {
        @(Get-Command -Module 'TerminalStudio' | ForEach-Object { $_.Name } | Sort-Object) |
            Should -Be @('Get-TSControl', 'Get-TSPlan', 'Invoke-TSDoctor')
    }

    It 'keeps renderers out of the public surface' {
        # The module returns data. Presentation is the caller's business, which is
        # what lets the CLI, -Json, and any future TUI be peers rather than one being
        # bolted onto another.
        Get-Command -Module 'TerminalStudio' -Name 'Show-*' -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'ships no apply command at all' {
        # Asserted, because the tempting alternative is worse than nothing. An empty
        # Invoke-TSApply that returns successfully would tell every caller - including
        # a future test - that the machine had converged, when nothing had happened.
        # Absent and documented beats present and dishonest.
        Get-Command -Module 'TerminalStudio' -Name 'Invoke-TSApply' -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

Describe 'font name resolution' {

    # 0.1.0 reported CaskaydiaCove Nerd Font Mono as missing on a machine where it
    # was installed and selected in Windows Terminal. Nothing here tested name
    # matching, so the defect survived a rewrite of the function that contained it.

    It 'offers the abbreviated Nerd Font alias for a verbose family name' {
        InModuleScope 'TerminalStudio' {
            $aliases = @(Get-TSFontNameAlias -FamilyName 'CaskaydiaCove Nerd Font Mono')

            $aliases | Should -Contain 'CaskaydiaCove Nerd Font Mono'
            $aliases | Should -Contain 'CaskaydiaCove NFM'
        }
    }

    It 'abbreviates Mono before the proportional form' {
        # The ordering trap. 'Nerd Font Mono' contains 'Nerd Font', so matching the
        # shorter pattern first turns every Mono face into 'CaskaydiaCove NF Mono' -
        # a name no font has ever been registered under.
        InModuleScope 'TerminalStudio' {
            @(Get-TSFontNameAlias -FamilyName 'JetBrainsMono Nerd Font Mono') |
                Should -Contain 'JetBrainsMono NFM'
        }
    }

    It 'leaves a family name with no Nerd Font marker alone' {
        InModuleScope 'TerminalStudio' {
            @(Get-TSFontNameAlias -FamilyName 'PxPlus IBM VGA8') |
                Should -Be @('PxPlus IBM VGA8')
        }
    }

    It 'answers with one of three states and always explains itself' {
        # Shape only. Which fonts exist is a property of the runner, not of this
        # code, and asserting a particular answer would only re-encode the runner.
        InModuleScope 'TerminalStudio' {
            $state = Get-TSFontState -FamilyName 'CaskaydiaCove Nerd Font Mono'

            $state.State | Should -BeIn @('Installed', 'Missing', 'Unknown')
            $state.Detail | Should -Not -BeNullOrEmpty
        }
    }

    It 'does not throw for a font nobody has' {
        InModuleScope 'TerminalStudio' {
            { Get-TSFontState -FamilyName 'Definitely Not A Real Font 9000' } | Should -Not -Throw
        }
    }
}

Describe 'Invoke-TSDoctor' {

    BeforeAll {
        $script:results = @(Invoke-TSDoctor -SkipStartupMeasurement)
    }

    It 'returns at least one check' {
        $script:results.Count | Should -BeGreaterThan 0
    }

    It 'gives every check a name, a status, and an expectation' {
        foreach ($result in $script:results) {
            $result.Name | Should -Not -BeNullOrEmpty
            $result.Status | Should -Not -BeNullOrEmpty
            $result.Expected | Should -Not -BeNullOrEmpty
        }
    }

    It 'uses only the four defined statuses' {
        foreach ($result in $script:results) {
            $result.Status | Should -BeIn @('Pass', 'Fail', 'Warn', 'Skip')
        }
    }

    It 'attaches a remediation to every failure' {
        # The rule that makes a diagnostic worth running. A check that reports a
        # problem without a next step has only moved the problem into the user's head,
        # and this is the assertion that stops the twentieth check from forgetting.
        foreach ($result in ($script:results | Where-Object { $_.Status -eq 'Fail' })) {
            $result.Remediation |
                Should -Not -BeNullOrEmpty -Because "the check '$($result.Name)' reports a failure and must say what to do about it"
        }
    }

    It 'says what it could not verify, rather than calling it broken' {
        # Warn and Skip both mean "unverified". Fail means "wrong". A check that
        # cannot look must not claim the second, which is precisely the mistake the
        # font check made in 0.1.0.
        foreach ($result in ($script:results | Where-Object { $_.Status -in @('Warn', 'Skip') })) {
            $result.Actual |
                Should -Not -BeNullOrEmpty -Because "the check '$($result.Name)' is unverified and must say what it saw"
        }
    }

    It 'honours the skip switch instead of silently ignoring it' {
        # The predecessor carried a -DryRun parameter on several functions that did
        # nothing, because the real behaviour flowed through a global. A switch that
        # is accepted and ignored is worse than one that does not exist.
        $startup = @($script:results | Where-Object { $_.Name -eq 'Shell startup' })

        $startup.Count | Should -Be 1
        $startup[0].Status | Should -Be 'Skip'
    }

    It 'reports a broken desired-state path as a failure rather than throwing' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'does-not-exist.json'
        $results = @(Invoke-TSDoctor -SkipStartupMeasurement -DesiredStatePath $missing)

        $desiredState = @($results | Where-Object { $_.Name -eq 'Desired state' })
        $desiredState[0].Status | Should -Be 'Fail'
        $desiredState[0].Remediation | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-TSPlan' {

    It 'evaluates the desired state shipped in this repository' {
        @(Get-TSPlan).Count | Should -BeGreaterThan 0
    }

    It 'reports an unmodelled resource kind instead of dropping it' {
        # The most important test in this file. Silently skipping a resource the tool
        # does not understand would let plan describe a converged machine while part
        # of the desired state was never examined - a lie by omission, and one the
        # user has no way to detect.
        $path = Join-Path -Path $TestDrive -ChildPath 'unknown-kind.json'
        $document = @{
            schemaVersion = 1
            resources     = @(@{ kind = 'not.a.real.kind' })
        } | ConvertTo-Json -Depth 5

        Set-Content -LiteralPath $path -Value $document -Encoding utf8

        $plan = @(Get-TSPlan -DesiredStatePath $path)

        $plan.Count | Should -Be 1
        $plan[0].Status | Should -Be 'Skip'
        $plan[0].Actual | Should -Match 'not modelled'
    }

    It 'refuses a document with an unknown schema version' {
        # Better to stop than to guess at a shape that changed. Version gating is what
        # makes it safe to evolve this document later.
        $path = Join-Path -Path $TestDrive -ChildPath 'future-schema.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 99, "resources": [] }' -Encoding utf8

        { Get-TSPlan -DesiredStatePath $path } | Should -Throw
    }

    It 'refuses a document missing required properties' {
        $path = Join-Path -Path $TestDrive -ChildPath 'incomplete.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1 }' -Encoding utf8

        { Get-TSPlan -DesiredStatePath $path } | Should -Throw
    }
}
