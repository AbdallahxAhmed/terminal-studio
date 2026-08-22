#Requires -Version 7.4

<#
    Unit suite for the structured log.

    Written through apply rather than by calling Write-TSLog directly. The claim
    worth testing is not that a function can append a line to a file; it is that
    every record from one run carries the same id as the journal entries from that
    run, because that is the only property that makes a log of several runs
    separable afterwards. Calling the logger directly would prove the format and
    leave the wiring untested.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/TerminalStudio/TerminalStudio.psd1'

    Import-Module -Name $script:manifestPath -Force

    function New-TSLogFixture {
        param([Parameter(Mandatory)] [string] $Root)

        $sourceRelative = 'omp/test.omp.json'
        $sourceFull = Join-Path -Path $Root -ChildPath $sourceRelative

        New-Item -ItemType Directory -Path (Split-Path -Path $sourceFull -Parent) -Force | Out-Null
        Set-Content -LiteralPath $sourceFull -Value 'theme-v1' -Encoding utf8 -NoNewline

        $destination = Join-Path -Path $Root -ChildPath 'deployed/andalus.omp.json'
        $statePath = Join-Path -Path $Root -ChildPath 'machine.json'

        $document = [ordered] @{
            schemaVersion = 1
            resources     = @(
                [ordered] @{
                    kind        = 'omp.theme'
                    name        = 'test'
                    source      = $sourceRelative
                    destination = $destination
                }
            )
        } | ConvertTo-Json -Depth 6

        Set-Content -LiteralPath $statePath -Value $document -Encoding utf8

        [pscustomobject] @{
            StatePath   = $statePath
            PayloadRoot = $Root
            Destination = $destination
            JournalPath = (Join-Path -Path $Root -ChildPath 'journal.jsonl')
            BackupRoot  = (Join-Path -Path $Root -ChildPath 'backups')
            LogPath     = (Join-Path -Path $Root -ChildPath 'logs/ts.jsonl')
        }
    }
}

AfterAll {
    Remove-Module -Name 'TerminalStudio' -Force -ErrorAction SilentlyContinue
}

Describe 'the TS_LOG_PATH sink' {

    BeforeEach {
        $script:root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null

        $script:fixture = New-TSLogFixture -Root $script:root
    }

    AfterEach {
        $env:TS_LOG_PATH = $null
    }

    It 'writes nothing at all unless it is asked to' {
        # A tool that starts writing to disk because it was run is a tool that
        # surprises people. The sink is opt-in, and this is the assertion that keeps
        # it that way.
        $env:TS_LOG_PATH = $null

        Invoke-TSApply -DesiredStatePath $script:fixture.StatePath -PayloadRoot $script:fixture.PayloadRoot -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot | Out-Null

        Test-Path -LiteralPath $script:fixture.LogPath | Should -BeFalse
    }

    It 'writes one JSON object per line, sharing the run id with the journal' {
        $env:TS_LOG_PATH = $script:fixture.LogPath

        Invoke-TSApply -DesiredStatePath $script:fixture.StatePath -PayloadRoot $script:fixture.PayloadRoot -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot | Out-Null

        Test-Path -LiteralPath $script:fixture.LogPath | Should -BeTrue

        $allRecords = @(Get-Content -LiteralPath $script:fixture.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
        $allRecords.Count | Should -BeGreaterThan 1

        foreach ($record in $allRecords) {
            $record.timestamp | Should -Not -BeNullOrEmpty
            $record.level | Should -Not -BeNullOrEmpty
            $record.message | Should -Not -BeNullOrEmpty
        }

        # Filter to records that belong to a run. Get-TSDesiredState writes a
        # log record before the run id exists, and that is correct - the concern
        # here is that the records that DO carry a run id all share the same one.
        $records = @($allRecords | Where-Object { $_.runId })
        $records.Count | Should -BeGreaterThan 0

        foreach ($record in $records) {
            $record.runId | Should -Not -BeNullOrEmpty
        }

        # The whole point of the correlation id: the log and the journal describe the
        # same run and can be joined on it.
        $journalRunId = (@(Get-Content -LiteralPath $script:fixture.JournalPath)[0] | ConvertFrom-Json).runId
        @($records | Where-Object { $_.runId -eq $journalRunId }).Count | Should -Be $records.Count
    }

    It 'keeps the run going when the log cannot be written' {
        # Somewhere a log path is unwritable, and a logger that can abort the apply
        # it is describing is worse than no logger at all. Here the log's parent is a
        # file, so creating the directory for it cannot succeed.
        $blocker = Join-Path -Path $script:root -ChildPath 'blocked'
        Set-Content -LiteralPath $blocker -Value 'not a directory' -Encoding utf8

        $env:TS_LOG_PATH = Join-Path -Path $blocker -ChildPath 'nested/ts.jsonl'

        $results = $null
        $caughtException = $null
        try { $results = @(Invoke-TSApply -DesiredStatePath $script:fixture.StatePath -PayloadRoot $script:fixture.PayloadRoot -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot -WarningAction SilentlyContinue) }
        catch { $caughtException = $_ }
        $caughtException | Should -BeNullOrEmpty

        $results[0].Status | Should -Be 'Pass'
        Test-Path -LiteralPath $script:fixture.Destination | Should -BeTrue
    }

    It 'separates two runs by id' {
        # Two applies into the same log file have to remain distinguishable, or the
        # id is decoration.
        $env:TS_LOG_PATH = $script:fixture.LogPath

        $arguments = @{
            DesiredStatePath = $script:fixture.StatePath
            PayloadRoot      = $script:fixture.PayloadRoot
            JournalPath      = $script:fixture.JournalPath
            BackupRoot       = $script:fixture.BackupRoot
        }

        Invoke-TSApply @arguments | Out-Null
        Invoke-TSApply @arguments | Out-Null

        $records = @(Get-Content -LiteralPath $script:fixture.LogPath | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.runId })
        @($records.runId | Sort-Object -Unique).Count | Should -Be 2
    }
}
