function Write-TSLog {
    <#
    .SYNOPSIS
        Emits a diagnostic record to PowerShell's streams, and to a JSONL file when
        one has been asked for.

    .DESCRIPTION
        Until 0.3.0 this function could only write to the Verbose, Information and
        Warning streams. The reason was not oversight: writing a file is operating
        system contact, code in Private/ is not permitted to make it, and the
        tempting shortcut - make logging the one exception to that rule - is how
        the rule dies.

        The sink now exists as the rule intended. Get-TSLogPath and Add-TSFileLine
        are adapter functions, so this file still touches nothing, and a test can
        exercise the whole logger by mocking two functions with no machine
        underneath it.

        Three properties are deliberate.

        The streams are always written and the file only when asked. A tool that
        starts writing to disk because it was run is a tool that surprises people;
        TS_LOG_PATH or an explicit -LogPath is the request.

        A logging failure is swallowed, and reported once as a warning. Somewhere
        a log path is unwritable, and a logger that can abort the apply it is
        describing is worse than no logger. Note that the failure is announced
        rather than hidden: silent logging is indistinguishable from logging that
        works right up to the moment someone needs it.

        RunId is a parameter rather than module state. Every record from one apply
        or one uninstall carries the same value, which is what makes a log of
        several runs separable afterwards, and passing it explicitly means there is
        no ambient variable to be stale, shared, or wrong after an exception.

    .PARAMETER Message
        The text to emit.

    .PARAMETER Level
        Which stream to emit on. Defaults to Verbose so that normal runs stay quiet.

    .PARAMETER RunId
        Correlation id shared by every record from one run.

    .PARAMETER Data
        Extra fields to record. Keys that would collide with a reserved field are
        ignored rather than allowed to overwrite it, because a log whose own
        timestamp can be shadowed by caller data is not evidence of anything.

    .PARAMETER LogPath
        Write the JSONL record here, overriding TS_LOG_PATH.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [ValidateSet('Verbose', 'Info', 'Warning')]
        [string] $Level = 'Verbose',

        [string] $RunId = '',

        [hashtable] $Data = @{},

        [string] $LogPath = ''
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

    $path = $LogPath

    if (-not $path) {
        $path = Get-TSLogPath
    }

    if (-not $path) {
        return
    }

    $record = [ordered] @{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        runId     = $RunId
        level     = $Level
        message   = $Message
    }

    foreach ($key in @($Data.Keys)) {
        if ($record.Contains($key)) {
            continue
        }

        $record[$key] = $Data[$key]
    }

    try {
        # -Compress for the same reason the journal uses it: one record on one
        # line is the entire contract of a JSONL file, and it is what lets a reader
        # tail the file or read a single run out of it without parsing the history.
        Add-TSFileLine -Path $path -Line ($record | ConvertTo-Json -Depth 4 -Compress)
    }
    catch {
        Write-Warning "Terminal Studio could not write its log to $path - $($_.Exception.Message)"
    }
}
