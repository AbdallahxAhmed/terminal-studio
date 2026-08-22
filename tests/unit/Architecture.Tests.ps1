#Requires -Version 7.4

<#
    Architecture suite.

    Every rule here corresponds to a defect in the predecessor, not to a style
    preference. Conventions that are only written down get violated; conventions
    with a failing build attached do not.

    These checks walk the abstract syntax tree rather than pattern-matching text.
    That is not gold-plating. Several files in this module explain, in comments,
    exactly which cmdlets they are forbidden from calling and why. A regex denylist
    would fail on the documentation while the code was perfectly correct - and the
    natural response to a test that cries wolf is to delete the comments, which
    means the enforcement mechanism would have destroyed the explanation. Asking
    the parser what is actually invoked lets both coexist.
#>

# Computed at the top level deliberately. Pester 5 expands -ForEach during
# discovery, which happens before any BeforeAll body executes, so a file list built
# inside BeforeAll would yield zero test cases - a green build asserting nothing.
# That is a silent failure, the category this project exists to remove.
$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$moduleRoot = Join-Path -Path $repoRoot -ChildPath 'src/TerminalStudio'

$publicFiles = @(Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'Public') -Filter '*.ps1' -File)
$privateFiles = @(Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'Private') -Filter '*.ps1' -File)
$adapterFiles = @(Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'Adapters') -Filter '*.ps1' -File)
$uiFiles = @(Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'UI') -Filter '*.ps1' -File)

$nonUiFiles = @($publicFiles + $privateFiles + $adapterFiles)
$logicFiles = @($publicFiles + $privateFiles)

BeforeAll {
    # The same values again, for the other half of the lifecycle.
    #
    # The comment above is correct that -ForEach needs these during discovery. It
    # is also not sufficient: discovery state is not the state test bodies execute
    # in, so an It that called the helper below raised CommandNotFoundException and
    # an It that read $uiFiles saw $null. Both phases need this, so both phases
    # build it. Recomputing four directory listings is cheaper than either half of
    # the suite silently not running.
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:moduleRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/TerminalStudio'

    $script:publicFiles = @(Get-ChildItem -Path (Join-Path -Path $script:moduleRoot -ChildPath 'Public') -Filter '*.ps1' -File)
    $script:privateFiles = @(Get-ChildItem -Path (Join-Path -Path $script:moduleRoot -ChildPath 'Private') -Filter '*.ps1' -File)
    $script:adapterFiles = @(Get-ChildItem -Path (Join-Path -Path $script:moduleRoot -ChildPath 'Adapters') -Filter '*.ps1' -File)
    $script:uiFiles = @(Get-ChildItem -Path (Join-Path -Path $script:moduleRoot -ChildPath 'UI') -Filter '*.ps1' -File)

    function Get-TSInvokedCommandName {
        <#
            Returns the names of commands actually invoked in a file. Comments, strings,
            and documentation are not commands, which is the entire point.
        #>
        param(
            [Parameter(Mandatory)]
            [string] $Path
        )

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)

        if (@($errors).Count -gt 0) {
            throw "Parse errors in $Path"
        }

        $commands = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)

        @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }
}

Describe 'every module file parses' {
    It '<_.Name> has no parse errors' -ForEach ($nonUiFiles + $uiFiles) {
        { Get-TSInvokedCommandName -Path $_.FullName } | Should -Not -Throw
    }
}

Describe 'presentation is confined to the UI folder' {
    # The predecessor called its UI layer from inside feature code. The consequence
    # was not ugliness, it was that -NonInteractive became unimplementable: a
    # feature invoked with that switch still opened a menu, because the menu was
    # part of the feature. Confining printing to one folder is what makes a
    # non-interactive path possible at all.

    It '<_.Name> does not call Write-Host' -ForEach $nonUiFiles {
        $invoked = @(Get-TSInvokedCommandName -Path $_.FullName)
        ($invoked -contains 'Write-Host') | Should -BeFalse -Because 'only files under UI/ may write to the host'
    }

    It '<_.Name> does not call a renderer' -ForEach $nonUiFiles {
        # Direction matters as much as location. Renderers consume results; logic
        # must never reach for a renderer, or the seam is decorative.
        $invoked = @(Get-TSInvokedCommandName -Path $_.FullName)
        @($invoked | Where-Object { $_ -like 'Show-*' }) | Should -BeNullOrEmpty
    }

    It 'the UI folder actually contains renderers' {
        # Guards against the rules above passing trivially because the folder is empty.
        $script:uiFiles.Count | Should -BeGreaterThan 0
    }
}

Describe 'the operating system is reached only through adapters' {
    # Adapters exist so that the rest of the module can be reasoned about, and
    # eventually tested, without a real Windows machine underneath it. That property
    # survives only if nothing bypasses them.

    It '<_.Name> does not touch the OS directly' -ForEach $logicFiles {
        $forbidden = @(
            'Get-ItemProperty'
            'Set-ItemProperty'
            'Remove-ItemProperty'
            'Get-Content'
            'Set-Content'
            'Get-AppxPackage'
            'Start-Process'
            'winget'
        )

        $invoked = @(Get-TSInvokedCommandName -Path $_.FullName)

        foreach ($name in $forbidden) {
            ($invoked -contains $name) | Should -BeFalse -Because "$name is adapter territory; call an adapter function instead"
        }
    }
}

Describe 'public commands are named the way PowerShell expects' {
    # The predecessor shipped Do-WslList, Filter-NonDockerDistros, Apply-CRLTuning,
    # and Refresh-Path. None of those verbs are approved, which means discovery,
    # tab completion, and every convention a PowerShell user already knows stop
    # helping them.

    It '<_.BaseName> is a single Verb-Noun pair' -ForEach $publicFiles {
        @($_.BaseName -split '-').Count | Should -Be 2
    }

    It '<_.BaseName> uses an approved verb' -ForEach $publicFiles {
        $verb = ($_.BaseName -split '-')[0]
        @(Get-Verb -Verb $verb).Count | Should -BeGreaterThan 0
    }

    It '<_.BaseName> declares CmdletBinding' -ForEach $publicFiles {
        # Without it there is no -Verbose, no -ErrorAction, and no common parameter
        # behaviour, so the function only looks like a cmdlet.
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Match '\[CmdletBinding\('
    }

    It '<_.BaseName> defines a function matching its filename' -ForEach $publicFiles {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref] $tokens, [ref] $errors)
        $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

        @($functions | ForEach-Object { $_.Name }) | Should -Contain $_.BaseName
    }
}

Describe 'no global mutable state' {
    # The predecessor kept a global settings object and threaded behaviour through
    # it, including whether the run was a dry run. Any function could change it,
    # nothing declared a dependency on it, and reading one function told you nothing
    # about what it would do.

    It '<_.Name> declares no global variables' -ForEach ($nonUiFiles + $uiFiles) {
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Not -Match '\$Global:'
    }
}

Describe 'the manifest and the Public folder agree' {
    It 'exports exactly the functions that exist in Public' {
        # Drift here is quiet and expensive: a file added without a manifest entry is
        # simply invisible to callers, and a manifest entry with no file breaks import.
        $manifest = Import-PowerShellDataFile -Path (Join-Path -Path $script:moduleRoot -ChildPath 'TerminalStudio.psd1')

        $declared = @($manifest.FunctionsToExport | Sort-Object)
        $actual = @($script:publicFiles | ForEach-Object { $_.BaseName } | Sort-Object)

        $declared | Should -Be $actual
    }

    It 'does not export a wildcard' {
        # FunctionsToExport = '*' costs real import time and turns the public surface
        # into an accident of file layout.
        $manifest = Import-PowerShellDataFile -Path (Join-Path -Path $script:moduleRoot -ChildPath 'TerminalStudio.psd1')
        @($manifest.FunctionsToExport) | Should -Not -Contain '*'
    }
}
