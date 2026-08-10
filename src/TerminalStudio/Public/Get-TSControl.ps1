function Get-TSControl {
    <#
    .SYNOPSIS
        Returns the editable controls with their current values from desired state.

    .DESCRIPTION
        The configurator's model. Both surfaces - the terminal form and the WPF
        window - render whatever this returns, and neither hardcodes a control.
        Adding a checkbox is an edit to Data/controls.json, not a code change in
        two places that must be kept in step.

        This is the WinUtil lesson rather than the WinUtil implementation. That
        project's checkboxes are generated from JSON definitions too; what is
        borrowed is the layering, not the window.

        Reads and returns. It does not write desired state and it does not touch
        Windows, which is what keeps the UI from becoming a second source of
        truth competing with machine.json.

        Values for appearance controls are resolved indirectly: the control names
        a path inside whichever fragment machine.json currently points at. Change
        the colour scheme and every appearance control follows it, instead of
        silently continuing to report values from a file no longer in use.

    .PARAMETER DesiredStatePath
        Path to the desired-state document. Defaults to the copy in this repository.

    .PARAMETER ControlDefinitionPath
        Path to the control definition. Defaults to the copy shipped in the module.

    .OUTPUTS
        TerminalStudio.Control objects. Bound is $false when the control's target
        path does not exist, which is a different condition from a value of $false.

    .EXAMPLE
        Get-TSControl | Where-Object Type -eq 'checkbox'

    .EXAMPLE
        Get-TSControl | Group-Object Group
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $DesiredStatePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\desired-state\machine.json'),

        [string] $ControlDefinitionPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\Data\controls.json')
    )

    if (-not (Test-TSPath -Path $ControlDefinitionPath)) {
        throw "Control definition not found: $ControlDefinitionPath"
    }

    try {
        $definition = Get-TSFileText -Path $ControlDefinitionPath | ConvertFrom-Json
    }
    catch {
        throw "Control definition is not valid JSON ($ControlDefinitionPath): $($_.Exception.Message)"
    }

    if ($definition.schemaVersion -ne 1) {
        throw "Unsupported control definition schemaVersion '$($definition.schemaVersion)'. This build understands version 1 only."
    }

    $state = Get-TSDesiredState -Path $DesiredStatePath

    # Relative 'source' values in machine.json are repository-relative.
    $repoRoot = Split-Path -Path (Split-Path -Path $DesiredStatePath -Parent) -Parent

    # Side documents are looked up by the resource that points at them, never by
    # a hardcoded filename. That indirection is the reason the appearance
    # controls keep working after the colour scheme changes.
    $documents = @{}

    foreach ($resource in @($state.resources)) {
        $resourceNames = @($resource.PSObject.Properties.Name)

        if ($resourceNames -notcontains 'source') {
            continue
        }

        $key = switch ([string] $resource.kind) {
            'terminal.fragment' { 'fragment' }
            'omp.theme' { 'omp' }
            default { '' }
        }

        if (-not $key) {
            continue
        }

        $file = Join-Path -Path $repoRoot -ChildPath ([string] $resource.source)

        if (-not (Test-TSPath -Path $file)) {
            # Recorded, not thrown. A dangling source makes some controls unbound;
            # it should not stop the rest of the form from rendering.
            Write-TSLog -Message "Control source '$key' points at a missing file: $file"
            $documents[$key] = $null
            continue
        }

        try {
            $documents[$key] = Get-TSFileText -Path $file | ConvertFrom-Json
        }
        catch {
            Write-TSLog -Message "Control source '$key' is not valid JSON: $file"
            $documents[$key] = $null
        }
    }

    $controls = [System.Collections.Generic.List[object]]::new()

    foreach ($group in @($definition.groups)) {
        foreach ($control in @($group.controls)) {
            $target = $control.target
            $targetNames = @($target.PSObject.Properties.Name)
            $source = [string] $target.source

            $mode = 'value'
            if ($targetNames -contains 'mode') {
                $mode = [string] $target.mode
            }

            $value = $null
            $bound = $false

            if ($source -eq 'machine') {
                $kind = [string] $target.kind
                $matching = @($state.resources | Where-Object { [string] $_.kind -eq $kind })

                if ($targetNames -contains 'match') {
                    $property = [string] $target.match.property
                    $wanted = [string] $target.match.value

                    $matching = @($matching | Where-Object {
                            $candidate = @($_.PSObject.Properties.Name)
                            ($candidate -contains $property) -and ([string] $_.$property -eq $wanted)
                        })
                }

                if ($mode -eq 'presence') {
                    $value = ($matching.Count -gt 0)
                    $bound = $true
                }
                elseif ($matching.Count -gt 0) {
                    $property = [string] $target.property
                    $available = @($matching[0].PSObject.Properties.Name)

                    if ($available -contains $property) {
                        $value = $matching[0].$property
                        $bound = $true
                    }
                }
            }
            else {
                $document = $null

                if ($documents.ContainsKey($source)) {
                    $document = $documents[$source]
                }

                if ($null -ne $document) {
                    $resolved = Resolve-TSJsonPath -InputObject $document -Path ([string] $target.path)

                    if ($mode -eq 'presence') {
                        $value = $resolved.Found
                        $bound = $true
                    }
                    elseif ($resolved.Found) {
                        $value = $resolved.Value
                        $bound = $true
                    }
                }
            }

            $controlNames = @($control.PSObject.Properties.Name)

            $cost = 0
            if ($controlNames -contains 'costMs') {
                $cost = [int] $control.costMs
            }

            $options = @()
            if ($controlNames -contains 'options') {
                $options = @($control.options | ForEach-Object {
                        [pscustomobject] @{
                            Value = $_.value
                            Label = [string] $_.label
                        }
                    })
            }

            $controls.Add([pscustomobject] @{
                    PSTypeName = 'TerminalStudio.Control'
                    Id         = [string] $control.id
                    GroupId    = [string] $group.id
                    Group      = [string] $group.label
                    Label      = [string] $control.label
                    Type       = [string] $control.type
                    Value      = $value
                    Bound      = $bound
                    Options    = $options
                    CostMs     = $cost
                    Help       = [string] $control.help
                    Source     = $source
                })
        }
    }

    $unbound = @($controls | Where-Object { -not $_.Bound }).Count
    Write-TSLog -Message "Loaded $($controls.Count) control(s), $unbound unbound."

    $controls
}
