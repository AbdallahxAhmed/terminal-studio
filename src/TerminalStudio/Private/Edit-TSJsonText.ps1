function Edit-TSJsonText {
    <#
    .SYNOPSIS
        Replaces one scalar value in a JSON document, leaving every other byte alone.

    .DESCRIPTION
        ConvertFrom-Json followed by ConvertTo-Json is the obvious way to change a
        value in a JSON file, and it is the wrong one for a file a human
        maintains. It discards comments, reformats lines it was not asked about,
        normalises numbers, and rewrites line endings, so a one-value change
        arrives in review as a diff over the entire document. The fragment and
        theme files here are read by people and reviewed in pull requests, so the
        edit has to be surgical.

        This scans the text, finds the span of the single value at the requested
        path, and splices a new literal over exactly those characters. Whitespace,
        key order, comments and anything else a parser would discard survive
        because they are never visited.

        Scalars only. Replacing an object or an array is refused rather than
        attempted: that is the point where a splice stops being provably local,
        and the caller has a documented way to decline.

        System.Text.Json's Utf8JsonReader would have done the scanning, but it is
        a ref struct and PowerShell cannot instantiate one at all, so the scanner
        is written out below. It tracks quoting and escapes, which is the only
        part of JSON where a brace or a bracket is not structural.

    .PARAMETER Text
        The document.

    .PARAMETER Path
        Dotted path to the value, in the form Resolve-TSJsonPath already accepts,
        so one path string in the control definition serves both reading and
        writing. Numeric segments index arrays.

    .PARAMETER Value
        The replacement, serialised with ConvertTo-Json so that strings are quoted
        and escaped and booleans become JSON literals rather than PowerShell's
        'True'.

    .OUTPUTS
        The edited document, as a string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    $stack = [System.Collections.Generic.List[hashtable]]::new()
    $start = -1
    $end = -1
    $expectKey = $false
    $index = 0
    $length = $Text.Length

    while ($index -lt $length) {
        $character = $Text[$index]

        if ([char]::IsWhiteSpace($character)) {
            $index++
            continue
        }

        if ($character -eq ':') {
            $expectKey = $false
            $index++
            continue
        }

        if ($character -eq ',') {
            if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Type -eq 'obj') {
                $expectKey = $true
            }

            $index++
            continue
        }

        # The path of whatever is about to be read. Each frame contributes the key
        # or the array index it is currently positioned on, so this is the address
        # of the current value rather than of its container.
        $segments = foreach ($frame in $stack) {
            if ($frame.Type -eq 'arr') {
                [string] $frame.Index
            }
            else {
                [string] $frame.Key
            }
        }

        $currentPath = @($segments) -join '.'

        if ($character -eq '{' -or $character -eq '[') {
            if ($currentPath -eq $Path) {
                throw "The value at '$Path' is a JSON object or array. Edit-TSJsonText replaces scalars only."
            }

            $type = if ($character -eq '{') { 'obj' } else { 'arr' }
            $stack.Add(@{ Type = $type; Key = ''; Index = 0 })
            $expectKey = ($type -eq 'obj')
            $index++
            continue
        }

        if ($character -eq '}' -or $character -eq ']') {
            if ($stack.Count -gt 0) {
                $stack.RemoveAt($stack.Count - 1)
            }

            # The container that just closed was itself an element of its parent, so
            # an enclosing array has to advance.
            if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Type -eq 'arr') {
                $stack[$stack.Count - 1].Index++
            }

            $expectKey = $false
            $index++
            continue
        }

        if ($character -eq '"') {
            $tokenStart = $index
            $index++

            while ($index -lt $length) {
                if ($Text[$index] -eq '\') {
                    # Skip the escape and whatever it escapes, so an escaped quote
                    # does not end the string early.
                    $index += 2
                    continue
                }

                if ($Text[$index] -eq '"') {
                    break
                }

                $index++
            }

            $index++
            $tokenEnd = $index
            $raw = $Text.Substring($tokenStart, $tokenEnd - $tokenStart)

            if ($expectKey -and $stack.Count -gt 0 -and $stack[$stack.Count - 1].Type -eq 'obj') {
                # Decoded through the JSON parser rather than by trimming quotes, so
                # that a key containing an escape resolves to the name the reader
                # will see.
                $stack[$stack.Count - 1].Key = [string] ($raw | ConvertFrom-Json)
                $expectKey = $false
                continue
            }

            if ($currentPath -eq $Path -and $start -lt 0) {
                $start = $tokenStart
                $end = $tokenEnd
            }

            if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Type -eq 'arr') {
                $stack[$stack.Count - 1].Index++
            }

            continue
        }

        # A number, true, false or null: everything up to the next delimiter.
        $tokenStart = $index

        while ($index -lt $length) {
            $candidate = $Text[$index]

            if ([char]::IsWhiteSpace($candidate) -or $candidate -eq ',' -or $candidate -eq '}' -or $candidate -eq ']') {
                break
            }

            $index++
        }

        if ($currentPath -eq $Path -and $start -lt 0) {
            $start = $tokenStart
            $end = $index
        }

        if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Type -eq 'arr') {
            $stack[$stack.Count - 1].Index++
        }
    }

    if ($start -lt 0) {
        throw "No value found at '$Path'."
    }

    # -InputObject rather than the pipeline: $null down a pipeline sends nothing at
    # all, which would silently splice an empty string where 'null' belongs.
    $literal = ConvertTo-Json -InputObject $Value -Compress

    $Text.Substring(0, $start) + $literal + $Text.Substring($end)
}
