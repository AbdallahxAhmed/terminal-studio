#Requires -Modules Pester

<#
    Binding tests for the configurator definition.

    The hazard a shared definition introduces is drift between the definition
    and the documents it points at. Rename a key in the fragment and nothing
    breaks loudly: Get-TSControl reports the control unbound, both surfaces draw
    it disabled, and the two agree with each other while being wrong together.
    Agreement between renderers is not correctness, so it has to be checked
    against the documents themselves.

    File lists and control lists are built at top level because Pester 5 expands
    -ForEach during discovery, before any BeforeAll has run.
#>

$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$definitionPath = Join-Path -Path $repoRoot -ChildPath 'src\TerminalStudio\Data\controls.json'
$machinePath = Join-Path -Path $repoRoot -ChildPath 'desired-state\machine.json'
$modulePath = Join-Path -Path $repoRoot -ChildPath 'src\TerminalStudio\TerminalStudio.psd1'

$definition = Get-Content -LiteralPath $definitionPath -Raw -Encoding utf8 | ConvertFrom-Json
$machine = Get-Content -LiteralPath $machinePath -Raw -Encoding utf8 | ConvertFrom-Json

$machineKinds = @($machine.resources | ForEach-Object { [string] $_.kind } | Sort-Object -Unique)

# The shapes both renderers implement. Adding a type here without teaching both
# surfaces to draw it is the failure this list exists to prevent.
$renderableTypes = @('checkbox', 'dropdown')

function Get-TSTestSourceDocument {
    param(
        [object] $Machine,
        [string] $RepoRoot,
        [string] $Kind
    )

    $resource = @($Machine.resources | Where-Object { [string] $_.kind -eq $Kind }) | Select-Object -First 1

    if ($null -eq $resource) {
        return $null
    }

    $names = @($resource.PSObject.Properties.Name)

    if ($names -notcontains 'source') {
        return $null
    }

    $path = Join-Path -Path $RepoRoot -ChildPath ([string] $resource.source)

    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Test-TSTestJsonPath {
    <#
        Deliberately a second implementation of the traversal in
        Resolve-TSJsonPath. Walking the tree with the function under test would
        make this suite pass in precisely the case where that function is wrong.
    #>
    param(
        [object] $Document,
        [string] $Path
    )

    $current = $Document

    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) {
            return $false
        }

        if ($segment -match '^\d+$') {
            $items = @($current)

            if ([int] $segment -ge $items.Count) {
                return $false
            }

            $current = $items[[int] $segment]
            continue
        }

        $names = @($current.PSObject.Properties.Name)

        if ($names -notcontains $segment) {
            return $false
        }

        $current = $current.$segment
    }

    $true
}

$sourceDocuments = @{
    fragment = Get-TSTestSourceDocument -Machine $machine -RepoRoot $repoRoot -Kind 'terminal.fragment'
    omp      = Get-TSTestSourceDocument -Machine $machine -RepoRoot $repoRoot -Kind 'omp.theme'
}

$controls = @(
    foreach ($group in @($definition.groups)) {
        foreach ($control in @($group.controls)) {
            [pscustomobject] @{
                Name    = "$($group.id)/$($control.id)"
                Id      = [string] $control.id
                Control = $control
            }
        }
    }
)

$canImportModule = $PSVersionTable.PSVersion.Major -ge 7

Describe 'Control definition' {

    It 'declares a schema version this build understands' {
        $definition.schemaVersion | Should -Be 1
    }

    It 'defines at least one group' {
        @($definition.groups).Count | Should -BeGreaterThan 0
    }

    It 'gives every control a unique id' {
        $ids = @($controls | ForEach-Object { $_.Id })
        $unique = @($ids | Sort-Object -Unique)

        # Duplicate ids would make the two surfaces disagree about which control
        # a saved value belongs to, silently.
        $ids.Count | Should -Be $unique.Count
    }

    It 'resolves both indirect source documents' {
        # If these are null the appearance and prompt controls are all unbound,
        # which would otherwise show up only as a form full of disabled rows.
        $sourceDocuments['fragment'] | Should -Not -BeNullOrEmpty
        $sourceDocuments['omp'] | Should -Not -BeNullOrEmpty
    }
}

Describe 'Control <_.Name>' -ForEach $controls {

    It 'has a label, a help string and a target' {
        [string] $_.Control.label | Should -Not -BeNullOrEmpty
        [string] $_.Control.help | Should -Not -BeNullOrEmpty
        $_.Control.target | Should -Not -BeNullOrEmpty
    }

    It 'has a type both surfaces can render' {
        $renderableTypes | Should -Contain ([string] $_.Control.type)
    }

    It 'offers real options when it is a dropdown' {
        if ([string] $_.Control.type -ne 'dropdown') {
            Set-ItResult -Skipped -Because 'not a dropdown'
            return
        }

        $options = @($_.Control.options)
        $options.Count | Should -BeGreaterThan 1

        foreach ($option in $options) {
            [string] $option.label | Should -Not -BeNullOrEmpty
        }
    }

    It 'targets a source the model builder understands' {
        @('machine', 'fragment', 'omp') | Should -Contain ([string] $_.Control.target.source)
    }

    It 'binds to something that exists' {
        $target = $_.Control.target
        $source = [string] $target.source

        if ($source -eq 'machine') {
            # A control may legitimately point at an absent resource - that is
            # what an unchecked presence checkbox means. What it may never do is
            # name a resource kind desired state has never heard of.
            $machineKinds | Should -Contain ([string] $target.kind)
            return
        }

        $document = $sourceDocuments[$source]
        $document | Should -Not -BeNullOrEmpty

        $mode = 'value'
        $names = @($target.PSObject.Properties.Name)

        if ($names -contains 'mode') {
            $mode = [string] $target.mode
        }

        if ($mode -eq 'presence') {
            Set-ItResult -Skipped -Because 'a presence control is meaningful whether or not the key is there'
            return
        }

        Test-TSTestJsonPath -Document $document -Path ([string] $target.path) |
            Should -BeTrue -Because "$($_.Name) binds to $($target.path), which is missing from the $source document"
    }
}

Describe 'Get-TSControl' -Skip:(-not $canImportModule) {

    BeforeAll {
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    }

    AfterAll {
        Remove-Module -Name TerminalStudio -Force -ErrorAction SilentlyContinue
    }

    It 'returns one object per defined control' {
        @(Get-TSControl).Count | Should -Be $controls.Count
    }

    It 'binds every control in this repository' {
        # Green here means the definition and the checked-in desired state agree.
        # It is the check that would have caught a renamed fragment key.
        $unbound = @(Get-TSControl | Where-Object { -not $_.Bound } | ForEach-Object { $_.Id })
        $unbound -join ', ' | Should -BeNullOrEmpty
    }

    It 'reads the colour scheme currently selected in desired state' {
        $scheme = @(Get-TSControl | Where-Object { $_.Id -eq 'scheme' })[0]
        $scheme.Value | Should -Be 'andalus'
    }

    It 'prints nothing' {
        # The model is data. If this ever writes to the host, the WPF surface and
        # any future JSON output would both inherit stray console noise.
        $output = Get-TSControl 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }
        @($output).Count | Should -Be 0
    }
}
