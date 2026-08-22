#Requires -Version 7.4

<#
    Unit suite for the surgical JSON edit behind configure -Save.

    The assertions compare whole documents as text, never parsed values.
    Comparing parsed values would pass for an implementation that reparsed and
    reserialised the file, reformatting every line and dropping every comment -
    which is exactly the outcome Edit-TSJsonText exists to prevent. So the
    fixtures carry comments and deliberately uneven indentation, and the tests
    demand them back untouched.

    Edit-TSJsonText and Compare-TSJsonDocument are private, so those cases run
    inside the module scope. They are pure string and object functions, so nothing
    in those blocks needs a filesystem.

    Every JSON fixture here is a single-quoted string or a single-quoted
    here-string. That is not a style choice. PowerShell has no backslash escape in
    a double-quoted string, so "\"a\"" terminates at the first backslash-quote and
    the rest of the line is parsed as code - which failed this entire file during
    discovery once already.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/TerminalStudio/TerminalStudio.psd1'

    Import-Module -Name $script:manifestPath -Force

    # A repository-shaped fixture: machine.json under desired-state/, pointing at a
    # fragment by a repository-relative source, because that indirection is how
    # Set-TSControl finds the document to edit.
    function New-TSControlFixture {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [Parameter(Mandatory)] [string] $FragmentText
        )

        $stateDirectory = Join-Path -Path $Root -ChildPath 'desired-state'
        $fragmentDirectory = Join-Path -Path $stateDirectory -ChildPath 'fragments'
        New-Item -ItemType Directory -Path $fragmentDirectory -Force | Out-Null

        $fragmentPath = Join-Path -Path $fragmentDirectory -ChildPath 'test.json'
        [System.IO.File]::WriteAllText($fragmentPath, $FragmentText, [System.Text.UTF8Encoding]::new($false))

        $statePath = Join-Path -Path $stateDirectory -ChildPath 'machine.json'

        $document = [ordered] @{
            schemaVersion = 1
            resources     = @(
                [ordered] @{
                    kind    = 'terminal.fragment'
                    name    = 'test'
                    appName = 'TerminalStudioTest'
                    source  = 'desired-state/fragments/test.json'
                }
                [ordered] @{
                    kind = 'winget.package'
                    id   = 'Git.Git'
                }
            )
        } | ConvertTo-Json -Depth 6

        Set-Content -LiteralPath $statePath -Value $document -Encoding utf8

        $controlPath = Join-Path -Path $Root -ChildPath 'controls.json'

        $controls = [ordered] @{
            schemaVersion = 1
            groups        = @(
                [ordered] @{
                    id       = 'appearance'
                    label    = 'Appearance'
                    controls = @(
                        [ordered] @{
                            id     = 'acrylic'
                            label  = 'Acrylic background'
                            type   = 'checkbox'
                            help   = ''
                            target = [ordered] @{
                                source = 'fragment'
                                path   = 'profiles.0.useAcrylic'
                                mode   = 'value'
                            }
                        }
                        [ordered] @{
                            id     = 'font-face'
                            label  = 'Font'
                            type   = 'dropdown'
                            help   = ''
                            target = [ordered] @{
                                source = 'fragment'
                                path   = 'profiles.0.font.face'
                                mode   = 'value'
                            }
                        }
                        [ordered] @{
                            id     = 'fragment-name'
                            label  = 'Fragment name'
                            type   = 'dropdown'
                            help   = ''
                            target = [ordered] @{
                                source   = 'machine'
                                kind     = 'terminal.fragment'
                                property = 'name'
                                mode     = 'value'
                            }
                        }
                        [ordered] @{
                            id     = 'git'
                            label  = 'Install Git'
                            type   = 'checkbox'
                            help   = ''
                            target = [ordered] @{
                                source = 'machine'
                                kind   = 'winget.package'
                                match  = [ordered] @{ property = 'id'; value = 'Git.Git' }
                                mode   = 'presence'
                            }
                        }
                    )
                }
            )
        } | ConvertTo-Json -Depth 8

        Set-Content -LiteralPath $controlPath -Value $controls -Encoding utf8

        [pscustomobject] @{
            StatePath    = $statePath
            ControlPath  = $controlPath
            FragmentPath = $fragmentPath
            JournalPath  = (Join-Path -Path $Root -ChildPath 'journal.jsonl')
            BackupRoot   = (Join-Path -Path $Root -ChildPath 'backups')
        }
    }
}

AfterAll {
    Remove-Module -Name 'TerminalStudio' -Force -ErrorAction SilentlyContinue
}

Describe 'Edit-TSJsonText' {

    It 'replaces one scalar and returns every other character unchanged' {
        InModuleScope 'TerminalStudio' {
            $text = @'
{
  // a comment a reparse would delete
  "profiles": [
    {
        "useAcrylic": true,
        "opacity": 85
    }
  ]
}
'@

            $edited = Edit-TSJsonText -Text $text -Path 'profiles.0.opacity' -Value 70

            $edited | Should -Be ($text -replace '85', '70')
            $edited | Should -Match '// a comment a reparse would delete'
        }
    }

    It 'writes booleans as JSON literals rather than as PowerShell text' {
        # $false.ToString() is 'False', which is a JSON parse error. This is the
        # single most likely way a naive implementation corrupts the document.
        InModuleScope 'TerminalStudio' {
            $text = '{ "profiles": [ { "useAcrylic": true } ] }'

            $edited = Edit-TSJsonText -Text $text -Path 'profiles.0.useAcrylic' -Value $false

            $edited | Should -Be '{ "profiles": [ { "useAcrylic": false } ] }'
            { $edited | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It 'is not fooled by a brace or a quote inside a string value' {
        # The only part of JSON where a structural character is not structural. A
        # scanner that misses this walks off the end of the object and edits the
        # wrong member, or none.
        InModuleScope 'TerminalStudio' {
            $text = '{ "a": "{ not an object \" still a string", "b": 1 }'

            $edited = Edit-TSJsonText -Text $text -Path 'b' -Value 2

            $edited | Should -Be '{ "a": "{ not an object \" still a string", "b": 2 }'
        }
    }

    It 'addresses array elements by index' {
        InModuleScope 'TerminalStudio' {
            $text = '{ "list": [ "first", "second", "third" ] }'

            $edited = Edit-TSJsonText -Text $text -Path 'list.1' -Value 'replaced'

            $edited | Should -Be '{ "list": [ "first", "replaced", "third" ] }'
        }
    }

    It 'refuses to replace an object or an array' {
        # Where a splice stops being provably local. Refusing is the feature.
        InModuleScope 'TerminalStudio' {
            $text = '{ "font": { "face": "CaskaydiaCove Nerd Font Mono" } }'

            { Edit-TSJsonText -Text $text -Path 'font' -Value 'anything' } | Should -Throw -ExpectedMessage '*scalars only*'
        }
    }

    It 'throws for a path that is not in the document' {
        InModuleScope 'TerminalStudio' {
            { Edit-TSJsonText -Text '{ "a": 1 }' -Path 'b' -Value 2 } | Should -Throw -ExpectedMessage '*No value found*'
        }
    }
}

Describe 'Compare-TSJsonDocument' {

    It 'returns the single path that changed' {
        InModuleScope 'TerminalStudio' {
            $before = '{ "a": 1, "nested": { "b": true } }' | ConvertFrom-Json
            $after = '{ "a": 1, "nested": { "b": false } }' | ConvertFrom-Json

            @(Compare-TSJsonDocument -Reference $before -Difference $after) | Should -Be @('nested.b')
        }
    }

    It 'returns nothing when only formatting differs' {
        # The proof that a whitespace-preserving splice is not mistaken for a change.
        InModuleScope 'TerminalStudio' {
            $before = '{ "a": 1 }' | ConvertFrom-Json
            $after = "{`n    `"a`":   1`n}" | ConvertFrom-Json

            @(Compare-TSJsonDocument -Reference $before -Difference $after).Count | Should -Be 0
        }
    }

    It 'catches a member that appeared or disappeared' {
        InModuleScope 'TerminalStudio' {
            $before = '{ "a": 1 }' | ConvertFrom-Json
            $after = '{ "a": 1, "b": 2 }' | ConvertFrom-Json

            @(Compare-TSJsonDocument -Reference $before -Difference $after) | Should -Be @('b')
            @(Compare-TSJsonDocument -Reference $after -Difference $before) | Should -Be @('b')
        }
    }
}

Describe 'Set-TSControl' {

    BeforeEach {
        $script:root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null

        # Comments and ragged indentation on purpose: this is what has to survive.
        $script:fragmentText = @'
{
    // Terminal Studio fragment - hand maintained, comments included
    "profiles": [
        {
            "updates": "",
            "useAcrylic": true,
                "opacity": 85,
            "font": {
                "face": "CaskaydiaCove Nerd Font Mono",
                "size": 12
            }
        }
    ]
}
'@

        $script:fixture = New-TSControlFixture -Root $script:root -FragmentText $script:fragmentText
    }

    It 'changes one value and leaves the document otherwise byte identical' {
        $result = Set-TSControl -Id 'acrylic' -Value $false -DesiredStatePath $script:fixture.StatePath -ControlDefinitionPath $script:fixture.ControlPath -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot

        $result.Status | Should -Be 'Pass'

        $after = [System.IO.File]::ReadAllText($script:fixture.FragmentPath)
        $after | Should -Be ($script:fragmentText -replace '"useAcrylic": true', '"useAcrylic": false')
        $after | Should -Match 'hand maintained, comments included'
    }

    It 'writes a string value into a nested path' {
        $result = Set-TSControl -Id 'font-face' -Value 'PxPlus IBM VGA8' -DesiredStatePath $script:fixture.StatePath -ControlDefinitionPath $script:fixture.ControlPath -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot

        $result.Status | Should -Be 'Pass'

        $after = [System.IO.File]::ReadAllText($script:fixture.FragmentPath)
        $after | Should -Be ($script:fragmentText -replace 'CaskaydiaCove Nerd Font Mono', 'PxPlus IBM VGA8')
    }

    It 'edits machine.json for a control that targets a resource property' {
        $result = Set-TSControl -Id 'fragment-name' -Value 'renamed' -DesiredStatePath $script:fixture.StatePath -ControlDefinitionPath $script:fixture.ControlPath -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot

        $result.Status | Should -Be 'Pass'

        $state = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $state.resources[0].name | Should -Be 'renamed'
    }

    It 'writes nothing the second time' {
        $arguments = @{
            DesiredStatePath      = $script:fixture.StatePath
            ControlDefinitionPath = $script:fixture.ControlPath
            JournalPath           = $script:fixture.JournalPath
            BackupRoot            = $script:fixture.BackupRoot
        }

        Set-TSControl -Id 'acrylic' -Value $false @arguments | Out-Null
        $second = Set-TSControl -Id 'acrylic' -Value $false @arguments

        $second.Status | Should -Be 'Pass'
        $second.Actual | Should -Match 'already set'
        @(Get-Content -LiteralPath $script:fixture.JournalPath).Count | Should -Be 1
    }

    It 'changes nothing under -WhatIf' {
        $result = Set-TSControl -Id 'acrylic' -Value $false -DesiredStatePath $script:fixture.StatePath -ControlDefinitionPath $script:fixture.ControlPath -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot -WhatIf

        $result.Status | Should -Be 'Skip'
        $result.Actual | Should -Match 'would set'

        [System.IO.File]::ReadAllText($script:fixture.FragmentPath) | Should -Be $script:fragmentText
        Test-Path -LiteralPath $script:fixture.JournalPath | Should -BeFalse
    }

    It 'declines a presence control instead of guessing at it' {
        $result = Set-TSControl -Id 'git' -Value $false -DesiredStatePath $script:fixture.StatePath -ControlDefinitionPath $script:fixture.ControlPath -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot

        $result.Status | Should -Be 'Skip'
        $result.Remediation | Should -Not -BeNullOrEmpty

        $state = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        @($state.resources).Count | Should -Be 2
    }

    It 'reports an unknown control id rather than throwing' {
        $result = Set-TSControl -Id 'no-such-control' -Value 1 -DesiredStatePath $script:fixture.StatePath -ControlDefinitionPath $script:fixture.ControlPath -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot

        $result.Status | Should -Be 'Fail'
    }

    It 'journals the edit so uninstall can reverse it' {
        # The seam between two features written weeks apart: configure writes 'edit'
        # records and uninstall replays them. Nothing else would notice if the shape
        # of that record drifted.
        Set-TSControl -Id 'acrylic' -Value $false -DesiredStatePath $script:fixture.StatePath -ControlDefinitionPath $script:fixture.ControlPath -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot | Out-Null

        $record = (@(Get-Content -LiteralPath $script:fixture.JournalPath)[0] | ConvertFrom-Json)
        $record.action | Should -Be 'edit'
        $record.path | Should -Be 'profiles.0.useAcrylic'
        $record.backup | Should -Not -BeNullOrEmpty

        $undone = @(Invoke-TSUninstall -JournalPath $script:fixture.JournalPath -BackupRoot $script:fixture.BackupRoot)

        $undone[0].Status | Should -Be 'Pass'
        [System.IO.File]::ReadAllText($script:fixture.FragmentPath) | Should -Be $script:fragmentText
    }
}
