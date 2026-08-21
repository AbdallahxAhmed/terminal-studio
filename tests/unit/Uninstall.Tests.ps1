#Requires -Version 7.4

<#
    Unit suite for uninstall.

    These tests apply first and then undo, rather than hand-writing journal
    records. A test that fabricates its own journal proves only that uninstall can
    read the format the test believes in, which is the one thing that was never in
    doubt - and it would keep passing after a change to the record shape that
    broke the real pair. Running apply for real is what turns the two halves into
    a contract with a red light attached.

    Everything lives under TestDrive.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/TerminalStudio/TerminalStudio.psd1'

    Import-Module -Name $script:manifestPath -Force

    # omp.theme, because its destination comes from the document rather than from
    # the machine. The other kinds run the same convergence and undo code with a
    # different path resolver.
    function New-TSUndoFixture {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [Parameter(Mandatory)] [string] $SourceContent,
            [Parameter(Mandatory)] [string] $Destination
        )

        $sourceRelative = 'omp/test.omp.json'
        $sourceFull = Join-Path -Path $Root -ChildPath $sourceRelative

        New-Item -ItemType Directory -Path (Split-Path -Path $sourceFull -Parent) -Force | Out-Null
        Set-Content -LiteralPath $sourceFull -Value $SourceContent -Encoding utf8 -NoNewline

        $statePath = Join-Path -Path $Root -ChildPath 'machine.json'

        $document = [ordered] @{
            schemaVersion = 1
            resources     = @(
                [ordered] @{
                    kind        = 'omp.theme'
                    name        = 'test'
                    source      = $sourceRelative
                    destination = $Destination
                }
            )
        } | ConvertTo-Json -Depth 6

        Set-Content -LiteralPath $statePath -Value $document -Encoding utf8

        [pscustomobject] @{
            StatePath   = $statePath
            PayloadRoot = $Root
            Destination = $Destination
            JournalPath = (Join-Path -Path $Root -ChildPath 'journal.jsonl')
            BackupRoot  = (Join-Path -Path $Root -ChildPath 'backups')
        }
    }

    function Invoke-TSFixtureApply {
        param([Parameter(Mandatory)] [object] $Fixture)

        @(Invoke-TSApply -DesiredStatePath $Fixture.StatePath -PayloadRoot $Fixture.PayloadRoot -JournalPath $Fixture.JournalPath -BackupRoot $Fixture.BackupRoot)
    }

    function Invoke-TSFixtureUndo {
        param(
            [Parameter(Mandatory)] [object] $Fixture,
            [switch] $All,
            [switch] $DryRun
        )

        @(Invoke-TSUninstall -JournalPath $Fixture.JournalPath -BackupRoot $Fixture.BackupRoot -All:$All -WhatIf:$DryRun)
    }
}

AfterAll {
    Remove-Module -Name 'TerminalStudio' -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-TSUninstall' {

    BeforeEach {
        $script:root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null

        $script:destination = Join-Path -Path $script:root -ChildPath 'deployed/andalus.omp.json'
    }

    It 'removes a file that apply created' {
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null
        Test-Path -LiteralPath $script:destination | Should -BeTrue

        $results = Invoke-TSFixtureUndo -Fixture $fixture

        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Pass'
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }

    It 'puts back the exact file that apply displaced' {
        # The reason the backup exists at all. Asserted on content rather than on
        # existence, because a restore that produces a file of the right length in
        # the right place is not a restore.
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-from-the-repo' -Destination $script:destination

        New-Item -ItemType Directory -Path (Split-Path -Path $script:destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:destination -Value 'the-file-the-user-already-had' -Encoding utf8 -NoNewline

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null
        Get-Content -LiteralPath $script:destination -Raw | Should -Be 'theme-from-the-repo'

        $results = Invoke-TSFixtureUndo -Fixture $fixture

        $results[0].Status | Should -Be 'Pass'
        Get-Content -LiteralPath $script:destination -Raw | Should -Be 'the-file-the-user-already-had'
    }

    It 'refuses to touch a file the user has edited since apply wrote it' {
        # The single most important property in this command. An uninstall that
        # restores a backup over work the user did afterwards has destroyed
        # something it was never given permission to destroy, and no report can
        # make up for it.
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null
        Set-Content -LiteralPath $script:destination -Value 'i-tweaked-this-myself' -Encoding utf8 -NoNewline

        $results = Invoke-TSFixtureUndo -Fixture $fixture

        $results[0].Status | Should -Be 'Skip'
        $results[0].Remediation | Should -Not -BeNullOrEmpty
        Get-Content -LiteralPath $script:destination -Raw | Should -Be 'i-tweaked-this-myself'
    }

    It 'changes nothing under -WhatIf' {
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null
        $before = @(Get-Content -LiteralPath $fixture.JournalPath).Count

        $results = Invoke-TSFixtureUndo -Fixture $fixture -DryRun

        $results[0].Status | Should -Be 'Skip'
        $results[0].Actual | Should -Match 'would remove'

        Test-Path -LiteralPath $script:destination | Should -BeTrue
        @(Get-Content -LiteralPath $fixture.JournalPath).Count | Should -Be $before
    }

    It 'records the undo in the journal without making it undoable' {
        # Undo records are journalled so the history stays complete, and are
        # deliberately not replayable: only create, replace and edit are forward
        # actions. Otherwise a second uninstall would put the file back.
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null
        Invoke-TSFixtureUndo -Fixture $fixture | Out-Null

        $lines = @(Get-Content -LiteralPath $fixture.JournalPath)
        $lines.Count | Should -Be 2

        $record = $lines[1] | ConvertFrom-Json
        $record.action | Should -Be 'remove'
        $record.destination | Should -Be $script:destination
        $record.undoOf | Should -Not -BeNullOrEmpty

        $second = Invoke-TSFixtureUndo -Fixture $fixture
        $second[0].Status | Should -Be 'Skip'
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }

    It 'reports an empty journal as nothing to do rather than as a failure' {
        # Exit code 0 for this case is what lets a script run uninstall
        # unconditionally. Nothing applied is the state uninstall exists to produce.
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        $results = Invoke-TSFixtureUndo -Fixture $fixture

        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Pass'
        $results[0].Actual | Should -Match 'no recorded changes'
    }

    It 'ignores a line it cannot parse and says how many' {
        # A journal is appended to by a process that can be killed mid-write. One
        # torn line must not cost the user the rest of their history.
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null
        Add-Content -LiteralPath $fixture.JournalPath -Value '{ "action": "create", "destin' -Encoding utf8

        $results = Invoke-TSFixtureUndo -Fixture $fixture

        @($results | Where-Object { $_.Status -eq 'Warn' }).Count | Should -Be 1
        @($results | Where-Object { $_.Status -eq 'Pass' }).Count | Should -Be 1
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }

    It 'undoes one named run and fails clearly on an unknown one' {
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-v1' -Destination $script:destination

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null
        $runId = (@(Get-Content -LiteralPath $fixture.JournalPath)[0] | ConvertFrom-Json).runId

        $missing = @(Invoke-TSUninstall -JournalPath $fixture.JournalPath -BackupRoot $fixture.BackupRoot -RunId 'not-a-run')
        $missing[0].Status | Should -Be 'Fail'
        Test-Path -LiteralPath $script:destination | Should -BeTrue

        $named = @(Invoke-TSUninstall -JournalPath $fixture.JournalPath -BackupRoot $fixture.BackupRoot -RunId $runId)
        $named[0].Status | Should -Be 'Pass'
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }

    It 'finds a backup that has moved, by leaf name under the backup root' {
        # Journalled paths are absolute, so they stop resolving after a profile move
        # or a restore onto another machine. The backup directory is the one part of
        # that path still known to be right.
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-from-the-repo' -Destination $script:destination

        New-Item -ItemType Directory -Path (Split-Path -Path $script:destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:destination -Value 'the-file-the-user-already-had' -Encoding utf8 -NoNewline

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null

        $backup = @(Get-ChildItem -Path $fixture.BackupRoot -File)[0]
        $moved = Join-Path -Path $script:root -ChildPath 'relocated'
        New-Item -ItemType Directory -Path $moved -Force | Out-Null
        Move-Item -LiteralPath $backup.FullName -Destination (Join-Path -Path $moved -ChildPath $backup.Name)

        $results = @(Invoke-TSUninstall -JournalPath $fixture.JournalPath -BackupRoot $moved)

        $results[0].Status | Should -Be 'Pass'
        Get-Content -LiteralPath $script:destination -Raw | Should -Be 'the-file-the-user-already-had'
    }

    It 'refuses to restore a backup that is not the file apply displaced' {
        # A backup that does not hash to what the journal recorded has stopped being
        # evidence of anything, and restoring it would be a guess wearing the
        # costume of a safety feature.
        $fixture = New-TSUndoFixture -Root $script:root -SourceContent 'theme-from-the-repo' -Destination $script:destination

        New-Item -ItemType Directory -Path (Split-Path -Path $script:destination -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:destination -Value 'the-file-the-user-already-had' -Encoding utf8 -NoNewline

        Invoke-TSFixtureApply -Fixture $fixture | Out-Null

        $backup = @(Get-ChildItem -Path $fixture.BackupRoot -File)[0]
        Set-Content -LiteralPath $backup.FullName -Value 'something-else-entirely' -Encoding utf8 -NoNewline

        $results = Invoke-TSFixtureUndo -Fixture $fixture

        $results[0].Status | Should -Be 'Fail'
        Get-Content -LiteralPath $script:destination -Raw | Should -Be 'theme-from-the-repo'
    }
}
