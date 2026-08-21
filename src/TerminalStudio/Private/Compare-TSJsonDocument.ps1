function Compare-TSJsonDocument {
    <#
    .SYNOPSIS
        Returns the dotted paths whose values differ between two parsed JSON documents.

    .DESCRIPTION
        The proof obligation for a surgical edit. Edit-TSJsonText splices text
        rather than serialising an object, which is what preserves the file - and
        it also means the result is unverified until something parses it back and
        compares it to what went in. Set-TSControl refuses to write unless this
        returns exactly the one path it intended to change.

        Leaves are compared as strings on purpose. JSON has a single number type
        and PowerShell has several, so a value read back as a double must not
        register as a change from the decimal that was written. Both sides go
        through the same conversion, so the comparison stays honest about real
        differences while ignoring the type the parser happened to choose.

        A missing path counts as a difference in either direction, which is how a
        splice that accidentally deleted or invented a member gets caught.

    .PARAMETER Reference
        The document as it was.

    .PARAMETER Difference
        The document as it would become.

    .OUTPUTS
        Sorted, unique dotted paths. An empty result means the two documents carry
        the same values.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Reference,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Difference
    )

    $maps = @{}

    foreach ($side in @('reference', 'difference')) {
        $document = if ($side -eq 'reference') { $Reference } else { $Difference }

        # Ordinal, because JSON keys are case sensitive and PowerShell's default
        # hashtable is not: two members differing only in case would otherwise
        # collapse into one and hide a difference.
        $flat = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        $queue = [System.Collections.Generic.Queue[hashtable]]::new()
        $queue.Enqueue(@{ Path = ''; Value = $document })

        while ($queue.Count -gt 0) {
            $item = $queue.Dequeue()
            $value = $item.Value
            $prefix = [string] $item.Path

            if ($value -is [System.Management.Automation.PSCustomObject]) {
                foreach ($property in $value.PSObject.Properties) {
                    $key = if ($prefix) { "$prefix.$($property.Name)" } else { [string] $property.Name }
                    $queue.Enqueue(@{ Path = $key; Value = $property.Value })
                }

                continue
            }

            if ($value -is [System.Collections.IList]) {
                for ($position = 0; $position -lt $value.Count; $position++) {
                    $key = if ($prefix) { "$prefix.$position" } else { [string] $position }
                    $queue.Enqueue(@{ Path = $key; Value = $value[$position] })
                }

                continue
            }

            $flat[$prefix] = if ($null -eq $value) { '<null>' } else { [string] $value }
        }

        $maps[$side] = $flat
    }

    $left = $maps['reference']
    $right = $maps['difference']
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($left.Keys)) {
        if (-not $right.ContainsKey($key)) {
            $paths.Add($key)
            continue
        }

        if ($left[$key] -cne $right[$key]) {
            $paths.Add($key)
        }
    }

    foreach ($key in @($right.Keys)) {
        if (-not $left.ContainsKey($key)) {
            $paths.Add($key)
        }
    }

    @($paths | Sort-Object -Unique)
}
