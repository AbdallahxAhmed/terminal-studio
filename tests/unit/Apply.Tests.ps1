#Requires -Version 7.4

<#
    Unit suite for apply.

    apply is the only command in this project that changes the machine, so the
    tests are about its safety properties rather than its happy path. Copying a
    file is not the interesting part. Copying it exactly once, keeping whatever it
    displaced, writing down what happened, and doing none of that during a dry run
    are the properties that justify running it at all.

    Every path here lives under TestDrive. A test suite that converged the machine
    running it would be a rather memorable way to learn this lesson.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/TerminalStudio/TerminalStudio.psd1'
    $script:entryScriptPath = Join-Path -Path $script:repoRoot -ChildPath 'ts.ps1'

    Import-Module -Name $script:manifestPath -Force

    # Builds a self-contained payload: one source file, one desired-state document
    # describing where it should end up, and nothing outside TestDrive.
    #
    # omp.theme is used throughout because its destination comes from the document.
    # The fragment, asset, and profile kinds run the same convergence code with a
    # different path resolver, and pointing those at a real machine to prove a
    # shared code path works would be a poor trade.
    function New-TSTestPayload {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [Parameter(Mandatory)] [string] $SourceContent,
            [Parameter(Mandatory)] [string] $Destination,
            [string] $Sha256 = ''
        )

        $sourceRelative = 'omp/test.omp.json'
        $sourceFull = Join-Path -Path $Root -ChildPath $sourceRelative

        New-Item -ItemType Directory -Path (Split-Path -Path $sourceFull -Parent) -Force | Out-Null

        if ($SourceContent -ne '__ABSENT__') {
            Set-Content -LiteralPath $sourceFull -Value $SourceContent -Encoding utf8 -NoNewline
        }

        $resource = [ordered] @{
            kind        = 'omp.theme'
            name        = 'test'
            source      = $sourceRelative
            destination = $Destination
        }

        if ($Sha256) {
            $resource['sha256'] = $Sha256
        }

        $statePath = Join-Path -Path $Root -ChildPath 'machine.json'
        $document = [ordered] @{
            schemaVersion = 1
            resources     = @($resource)
        } | ConvertTo-Json -Depth 6

        Set-Content -LiteralPath $statePath -Value $document -Encoding utf8

        [pscustomobject] @{
            StatePath   = $statePath
            PayloadRoot = $Root
            Source      = $sourceFull
            Destination = $Destination
            JournalPath = (Join-Path -Path $Root -ChildPath 'journal.jsonl')
            BackupRoot  = (Join-Path -Path $Root -ChildPath 'backups')
        }
    }
}

AfterAll {
    Remove-Module -Name 'TerminalStudio' -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-TSApply' {

    BeforeEach {
        $script:root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null

        $script:destination = Join-Path -Path $script:root -ChildPath 'deployed/andalus.omp.json'
    }

    It 'creates a file that is not there yet' {
        $payload = New-TSTestPayload -Root $script:root -SourceContent '{ "blocks": [] }' -Destination $script:destination

        $results = @(Invoke-TSApply -DesiredStatePath $payload.StatePath -PayloadRoot $payload.PayloadRoot -JournalPath $payload.JournalPath -BackupRoot $payload.BackupRoot)

        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Pass'
        Test-Path -LiteralPath $script:destination | Should -BeTrue
        Get-Content -LiteralPath $script:destination -Raw | Should -Be '{ "blocks": [] }'
    }

    It 'writes nothing at all on a second run' {
        # The property that makes this safe to put in a profile, a scheduled task, or
        # anyone's muscle memory. Asserted against the journal rather than the file,
        # because a second write producing byte-identical output would still be a
        # write, and would still have taken a backup of the file it replaced with
        # itself.
        $payload = New-TSTestPayload -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        $arguments = @{
            DesiredStatePath = $payload.StatePath
            PayloadRoot      = $payload.PayloadRoot
            JournalPath      = $payload.JournalPath
            BackupRoot       = $payload.BackupRoot
        }

        $first = @(Invoke-TSApply @arguments)
        $second = @(Invoke-TSApply @arguments)

        $first[0].Status | Should -Be 'Pass'
        $second[0].Status | Should -Be 'Pass'
        $second[0].Actual | Should -Match 'already'

        @(Get-Content -LiteralPath $payload.JournalPath).Count | Should -Be 1
        Test-Path -LiteralPath $payload.BackupRoot | Should -BeFalse
    }

    It 'keeps a copy of whatever it replaces' {
        $payload = New-TSTestPayload -Root $script:root -SourceContent 'theme-new' -Destination $script:destination

        New-Item -ItemType Directory -Path (Split-Path -Path $script:destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:destination -Value 'theme-the-user-hand-edited' -Encoding utf8 -NoNewline

        $results = @(Invoke-TSApply -DesiredStatePath $payload.StatePath -PayloadRoot $payload.PayloadRoot -JournalPath $payload.JournalPath -BackupRoot $payload.BackupRoot)

        $results[0].Status | Should -Be 'Pass'
        $results[0].Actual | Should -Match 'previous version'

        $backups = @(Get-ChildItem -Path $payload.BackupRoot -File)
        $backups.Count | Should -Be 1
        Get-Content -LiteralPath $backups[0].FullName -Raw | Should -Be 'theme-the-user-hand-edited'
    }

    It 'records each change as one line of parseable JSON' {
        # The journal is what will make uninstall a replay rather than a second
        # guess, so its shape is a contract and not a log format.
        $payload = New-TSTestPayload -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        Invoke-TSApply -DesiredStatePath $payload.StatePath -PayloadRoot $payload.PayloadRoot -JournalPath $payload.JournalPath -BackupRoot $payload.BackupRoot | Out-Null

        $lines = @(Get-Content -LiteralPath $payload.JournalPath)
        $lines.Count | Should -Be 1

        $record = $lines[0] | ConvertFrom-Json

        $record.action | Should -Be 'create'
        $record.kind | Should -Be 'omp.theme'
        $record.destination | Should -Be $script:destination
        $record.newSha256 | Should -Not -BeNullOrEmpty
        $record.runId | Should -Not -BeNullOrEmpty
        $record.timestamp | Should -Not -BeNullOrEmpty
    }

    It 'changes nothing under -WhatIf' {
        # SupportsShouldProcess is only worth declaring if the check happens at the
        # write. A -WhatIf that each layer has to remember to honour is one that some
        # layer eventually will not.
        $payload = New-TSTestPayload -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        $results = @(Invoke-TSApply -DesiredStatePath $payload.StatePath -PayloadRoot $payload.PayloadRoot -JournalPath $payload.JournalPath -BackupRoot $payload.BackupRoot -WhatIf)

        $results[0].Status | Should -Be 'Skip'
        $results[0].Actual | Should -Match 'would create'

        Test-Path -LiteralPath $script:destination | Should -BeFalse
        Test-Path -LiteralPath $payload.JournalPath | Should -BeFalse
    }

    It 'reports a missing source as a failure rather than throwing' {
        # One broken resource must not abandon the rest of the run. The backdrop
        # image is exactly this case on a real machine: declared in desired state,
        # not committed to the repository because it is a binary, and absent until
        # someone puts it there.
        $payload = New-TSTestPayload -Root $script:root -SourceContent '__ABSENT__' -Destination $script:destination

        $results = $null
        { $results = @(Invoke-TSApply -DesiredStatePath $payload.StatePath -PayloadRoot $payload.PayloadRoot -JournalPath $payload.JournalPath -BackupRoot $payload.BackupRoot) } |
            Should -Not -Throw

        $results[0].Status | Should -Be 'Fail'
        $results[0].Remediation | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }

    It 'refuses to deploy a file whose hash contradicts the declared one' {
        # A declared sha256 is a statement that this exact file is intended. When the
        # bytes disagree, the disagreement is the finding - copying it anyway would
        # make the declaration decorative.
        $payload = New-TSTestPayload -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination -Sha256 ('A' * 64)

        $results = @(Invoke-TSApply -DesiredStatePath $payload.StatePath -PayloadRoot $payload.PayloadRoot -JournalPath $payload.JournalPath -BackupRoot $payload.BackupRoot)

        $results[0].Status | Should -Be 'Fail'
        $results[0].Actual | Should -Match 'does not match'
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }

    It 'refuses to act on a desired-state document it cannot parse' {
        # doctor degrades and carries on, because reading a partial picture is still
        # useful. apply must not: writing the half of a document it managed to
        # understand is how a machine ends up in a state nothing describes.
        $path = Join-Path -Path $script:root -ChildPath 'broken.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 99, "resources": [] }' -Encoding utf8

        { Invoke-TSApply -DesiredStatePath $path } | Should -Throw
    }
}

Describe 'the wiring between the entry script and apply' {

    <#
        Every test in the Describe above passed while 'ts.ps1 apply -WhatIf'
        created two files and replaced a shell profile on a real machine.

        Nothing was wrong with Invoke-TSApply. The entry script did not pass
        -WhatIf to it, on the belief that SupportsShouldProcess on the script had
        already set $WhatIfPreference for everything it called. That belief is
        wrong across a module boundary, and the renderers - which are dot-sourced
        into the script's own scope and therefore did see the preference - printed
        'dry run, nothing written' over the list of files that had just been
        written.

        The lesson is not about -WhatIf. It is that a suite which tests each unit
        in isolation tests none of the joins between them, and the join is where a
        false assumption about the platform can live indefinitely without ever
        failing a test.
    #>

    It 'passes -WhatIf explicitly, because the preference does not cross into the module' {
        # Parsed, not pattern-matched. ts.ps1 now carries a long comment explaining
        # why -WhatIf is passed explicitly, so a text search for '-WhatIf' finds the
        # explanation whether or not the call site still does it - a check that
        # passes for a reason unrelated to the thing it is checking. The AST sees
        # command invocations and does not see comments at all.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:entryScriptPath, [ref] $tokens, [ref] $errors)

        @($errors).Count | Should -Be 0

        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Invoke-TSApply'
                }, $true))

        $calls.Count | Should -BeGreaterThan 0

        foreach ($call in $calls) {
            $parameters = @(
                $call.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName }
            )

            $parameters | Should -Contain 'WhatIf'
        }
    }

    It 'does not honour a caller-scope $WhatIfPreference, which is why the argument is required' {
        # A characterisation test. It asserts the platform behaviour that caused the
        # defect rather than behaviour this project wants, so that the explicit
        # argument above can never be deleted as redundant without something going
        # red first.
        #
        # If a future PowerShell makes preference variables cross module boundaries,
        # this test fails. That is the correct outcome: the workaround would then be
        # unnecessary and the comments explaining it would be wrong.
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $destination = Join-Path -Path $root -ChildPath 'deployed/andalus.omp.json'
        $payload = New-TSTestPayload -Root $root -SourceContent 'theme-v1' -Destination $destination

        $WhatIfPreference = $true

        $results = @(Invoke-TSApply -DesiredStatePath $payload.StatePath -PayloadRoot $payload.PayloadRoot -JournalPath $payload.JournalPath -BackupRoot $payload.BackupRoot)

        $results[0].Status | Should -Be 'Pass'
        Test-Path -LiteralPath $destination | Should -BeTrue
    }
}
