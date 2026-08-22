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

    Stage 0 now has a second execution mode - a string piped into Invoke-Expression
    - and several assertions below exist because that mode breaks things which are
    perfectly safe in a script file.

    Where an assertion is about what get.ps1 does, it is asked of the parser rather
    than of the file's text. Two of the checks here were once written as text
    matches and were red for months against a correct file, because get.ps1's header
    explains the constraints it is under and therefore contains the words those
    checks were banning. A test that fails on its subject's documentation offers two
    repairs, and the cheaper one is deleting the documentation.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:bootstrapPath = Join-Path -Path $script:repoRoot -ChildPath 'bootstrap/get.ps1'
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'bootstrap/releases.json'
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
        # trained on 7.x.
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

    It 'guards the engine at runtime instead of with a #Requires directive' {
        # #Requires is a directive for script files. Stage 0's primary execution mode
        # is now a string handed to Invoke-Expression, where whether the directive is
        # honoured, ignored, or fatal is not something to discover during someone's
        # install. A numeric comparison behaves identically in both modes.
        #
        # Asked of the parser. The text-matching version of this assertion failed on
        # the two sentences in get.ps1's header that explain why there is no
        # #Requires directive, which is a test whose only cheap repair is deleting
        # the reasoning it was meant to protect. ScriptRequirements is the presence
        # of a directive; the word is just a word.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:bootstrapPath, [ref] $tokens, [ref] $errors)

        $script:text | Should -Match '\$PSVersionTable\.PSVersion\.Major'
        $ast.ScriptRequirements | Should -BeNullOrEmpty
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

    It 'never calls exit' {
        # Under Invoke-Expression, exit terminates the host session rather than the
        # script - it closes the window the user is standing in, mid-install, with no
        # explanation. Every failure path has to throw.
        $script:text | Should -Not -Match '(?m)^\s*exit\b'
    }

    It 'has no mandatory parameter' {
        # A pipe into Invoke-Expression passes no arguments, so a mandatory parameter
        # does not protect anything - it stops and prompts in the middle of a paste,
        # which reads as a hang.
        #
        # Targets the attribute rather than the word, because -Match is
        # case-insensitive and the file's own header discusses mandatory parameters
        # in prose. A test that fails on its own explanation gets deleted.
        $script:text | Should -Not -Match '\[Parameter\([^)]*Mandatory'
    }

    It 'accepts input through the environment, the only channel a bare pipe leaves' {
        $script:text | Should -Match 'TS_VERSION'
    }

    It 'refuses unverified downloads unless the user opts out explicitly' {
        # TLS authenticates the server, not the bytes. Without a hash there is no
        # artifact integrity, so the absence of one has to be a hard stop rather
        # than a warning nobody reads.
        $script:text | Should -Match 'Get-FileHash'
        $script:text | Should -Match 'SkipHashCheck'
    }

    It 'downloads the payload from a release tag, never from a branch' {
        # This is what the old 'must have a mandatory -Version' assertion was really
        # protecting. A mandatory parameter was only ever a proxy for it; the property
        # itself is that the archive URL is built from a tag, and that is now checked
        # directly.
        $script:text | Should -Match 'releases/download/\$Version'
        $script:text | Should -Not -Match 'refs/heads/'
    }

    It 'references main only to read the manifest, never to fetch code or payload' {
        # The blanket ban on 'main' had to go, because resolving a version and a hash
        # requires reading something that moves. Narrowed to the actual intent: a main
        # reference is acceptable for the manifest and for nothing else.
        #
        # Fetching that manifest from main concedes nothing, because get.ps1 is itself
        # fetched from main - anyone able to rewrite one can rewrite the other.
        #
        # Comments are excluded, and that exclusion is the whole point rather than a
        # convenience. The install one-liner fetches get.ps1 from main by design, so
        # the header documenting it contains that URL three times. Reading the file as
        # lines counted all three as violations, so this assertion was red for a file
        # that was right, which is the same as having no assertion at all. The rule is
        # about what the script fetches, so it is asked of the tokens the script is
        # made of.
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:bootstrapPath, [ref] $tokens, [ref] $errors)

        $offenders = @(
            $tokens |
                Where-Object { $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment } |
                Where-Object { $_.Text -match '/main/' -and $_.Text -notmatch 'releases\.json' } |
                ForEach-Object { $_.Text }
        )

        @($offenders).Count | Should -Be 0 -Because "these tokens reach into main for something other than the manifest: $($offenders -join ' | ')"
    }

    It 'sets TLS 1.2 explicitly and avoids the Internet Explorer parser' {
        # Both are 5.1-specific hazards: the inherited protocol default can still
        # negotiate down on machines behind on updates, and Invoke-WebRequest wants
        # the IE DOM engine unless told otherwise, which may be absent or disabled.
        $script:text | Should -Match 'Tls12'
        $script:text | Should -Match '-UseBasicParsing'
    }
}

Describe 'bootstrap/releases.json' {

    # The manifest is what makes the one-liner possible, so it is also what breaks
    # it. These run on 5.1 because that is the engine that will parse it in anger.

    BeforeAll {
        $script:manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
    }

    It 'is valid JSON on the 5.1 parser' {
        $script:manifest | Should -Not -BeNullOrEmpty
    }

    It 'names a latest release that actually exists in the list' {
        # The one failure mode an explicit pointer introduces. Without this, promoting
        # a release by editing one field and forgetting the other produces a one-liner
        # that fails for everyone, immediately, with a message about a missing tag.
        $versions = @($script:manifest.releases | ForEach-Object { [string] $_.version })

        $script:manifest.latest | Should -Not -BeNullOrEmpty
        $versions | Should -Contain $script:manifest.latest
    }

    It 'records a usable hash for every release' {
        foreach ($release in @($script:manifest.releases)) {
            $release.sha256 |
                Should -Match '^[0-9A-Fa-f]{64}$' -Because "release $($release.version) must carry a full SHA-256, or the bootstrap will refuse to install it"
        }
    }

    It 'uses tag-shaped version strings' {
        foreach ($release in @($script:manifest.releases)) {
            $release.version | Should -Match '^v\d+\.\d+\.\d+$'
        }
    }
}
