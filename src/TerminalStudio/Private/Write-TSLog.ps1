function Write-TSLog {
    <#
    .SYNOPSIS
        Emits a diagnostic record to PowerShell's own streams.

    .DESCRIPTION
        Deliberately limited in 0.1.0.

        Structured JSONL with a per-run correlation id is the target design
        (docs/architecture.md, Observability), but writing a file is operating
        system contact, and code in Private/ is not permitted to make it.

        The tempting shortcut is to make logging "the one exception" to that rule.
        That is how the rule dies. So this writes to the Verbose, Information, and
        Warning streams, which are capturable, redirectable, and assertable in
        tests, and the JSONL sink will arrive later as an adapter rather than as an
        exception.

    .PARAMETER Message
        The text to emit.

    .PARAMETER Level
        Which stream to emit on. Defaults to Verbose so that normal runs stay quiet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [ValidateSet('Verbose', 'Info', 'Warning')]
        [string] $Level = 'Verbose'
    )

    switch ($Level) {
        'Warning' {
            Write-Warning -Message $Message
        }
        'Info' {
            Write-Information -MessageData $Message -Tags 'TerminalStudio'
        }
        default {
            Write-Verbose -Message $Message
        }
    }
}
