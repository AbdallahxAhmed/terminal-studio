#Requires -Version 5.1

<#
    Compatibility suite for stage 0.

    This is the suite that exists because of a specific defect. The predecessor
    called ConvertFrom-Json with -Depth 32. That parameter does not exist on that
    cmdlet in Windows PowerShell 5.1, so the call threw a terminating error, and
    because every theme function read the settings file first, the entire appearance
    editor was dead on any 5.1 host. It shipped, and it was eventually found by a
    person reading a log file by hand.

    The lesson was never 'be more careful'. The lesson was that nothing in the
    project could have caught it, because nothing ever ran on 5.1. This file runs on
    5.1 in CI, which is the actual fix.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:bootstrapPath = Join-Path -Path $script:repoRoot -ChildPath 'bootstrap/get.ps1'
    $script:text = Get-Content -LiteralPath $script:bootstrapPath -Raw
}

Describe 'bootstrap/get.ps1' {

    It 'is present where the documentation says it is' {
        Test-Path -LiteralPath $script:bootstrapPath | Should -BeTrue
    }

    It 'parses without errors on the engine running this test' {
        # Under powershell.exe this is a genuine 5.1 parser check rather than a
        # regex approximation of one. A parse error is the failure mode that no
        # amount of reading catches reliably, because the file looks fine to eyes
        # trained on 7.x. It is also the open question left over from the old
        # codebase, where an inline if-expression used as an argument may or may not
        # have parsed on 5.1 - a question a test answers and an argument does not.
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:bootstrapPath, [ref] $tokens, [ref] $errors)

        @($errors).Count | Should -Be 0
    }

    It 'never passes -Depth to ConvertFrom-Json' {
        # The regression test, named after the bug. Cheap to run, and it closes the
        # exact hole that reached production.
        $script:text | Should -Not -Match 'ConvertFrom-Json[^\r\n|]*-Depth'
    }

    It 'declares the minimum engine it supports' {
        # Stage 0 must announce 5.1 rather than inheriting whatever it happens to be
        # launched with, so the contract is visible in the file itself.
        $script:text | Should -Match '#Requires\s+-Version\s+5\.1'
    }

    It 'avoids <Name>, which does not exist in 5.1' -ForEach @(
        @{ Name = 'null-coalescing'; Pattern = '\?\?' }
        @{ Name = 'null-conditional member access'; Pattern = '\?\.' }
        @{ Name = 'pipeline chain operators'; Pattern = '\|\|' }
        @{ Name = 'the parallel foreach switch'; Pattern = '-Parallel\b' }
        @{ Name = 'the PSStyle automatic variable'; Pattern = '\$PSStyle' }
        @{ Name = 'the clean block'; Pattern = '(?m)^\s*clean\s*\{' }
    ) {
        $script:text | Should -Not -Match $Pattern
    }

    It 'does all of its work inside a function invoked on the last statement' {
        # The truncation guard. A connection cut mid-transfer yields a file that
        # defines a function and never calls it, instead of executing the first half
        # of an installer. It is the cheapest meaningful mitigation for piping a URL
        # into an interpreter, and it only holds if the invocation stays last, which
        # is why it is asserted rather than commented.
        $lines = @($script:text -split "`r?`n") |
            Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }

        $lines[-1].Trim() | Should -BeLike 'Invoke-TSStageZero*'
    }

    It 'refuses unverified downloads unless the user opts out explicitly' {
        # TLS authenticates the server, not the bytes. Without a hash there is no
        # artifact integrity, so the absence of one has to be a hard stop rather
        # than a warning nobody reads.
        $script:text | Should -Match 'Get-FileHash'
        $script:text | Should -Match 'SkipHashCheck'
    }

    It 'pins to a release tag rather than a moving branch' {
        # The single largest real risk in a remote-execution install line is not the
        # pipe, it is pointing at a branch. A tag is reviewable; a branch is whatever
        # someone pushed most recently.
        $script:text | Should -Match 'Mandatory'
        $script:text | Should -Not -Match 'refs/heads/'
        $script:text | Should -Not -Match '/(main|master)/'
    }

    It 'sets TLS 1.2 explicitly and avoids the Internet Explorer parser' {
        # Both are 5.1-specific hazards: the inherited protocol default can still
        # negotiate down on machines behind on updates, and Invoke-WebRequest wants
        # the IE DOM engine unless told otherwise, which may be absent or disabled.
        $script:text | Should -Match 'Tls12'
        $script:text | Should -Match '-UseBasicParsing'
    }
}
