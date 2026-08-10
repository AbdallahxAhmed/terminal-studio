function Resolve-TSJsonPath {
    <#
    .SYNOPSIS
        Reads a value out of parsed JSON using a dotted path.

    .DESCRIPTION
        Supports object properties and numeric array indices, so the path
        'profiles.0.font.face' addresses the first profile's font face.

        Returns a result object rather than the bare value. A control bound to a
        path that does not exist is a different condition from a control whose
        value is legitimately $false or $null, and the two must not be confused:
        collapsing them would render an unbound checkbox as an unchecked one,
        which is a lie the user cannot see. Found is how the caller tells them
        apart.

        No filesystem access here. The caller has already read and parsed the
        document through the adapter, which is what keeps this function testable
        without a machine underneath it.

    .PARAMETER InputObject
        Parsed JSON.

    .PARAMETER Path
        Dotted path, for example 'profiles.0.useAcrylic'.

    .OUTPUTS
        An object with Found (bool) and Value.

    .EXAMPLE
        Resolve-TSJsonPath -InputObject $fragment -Path 'profiles.0.opacity'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $current = $InputObject

    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) {
            return [pscustomobject] @{ Found = $false; Value = $null }
        }

        if ($segment -match '^\d+$') {
            $items = @($current)
            $index = [int] $segment

            if ($index -ge $items.Count) {
                return [pscustomobject] @{ Found = $false; Value = $null }
            }

            $current = $items[$index]
            continue
        }

        # Checked rather than assumed. Set-StrictMode -Version Latest turns a
        # missing property into a terminating error, so probing for absence has
        # to be done by name lookup instead of by reading and comparing to null.
        $names = @($current.PSObject.Properties.Name)

        if ($names -notcontains $segment) {
            return [pscustomobject] @{ Found = $false; Value = $null }
        }

        $current = $current.$segment
    }

    [pscustomobject] @{ Found = $true; Value = $current }
}
