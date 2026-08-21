function Test-TSPath {
    <#
    .SYNOPSIS
        Reports whether a path exists.

    .DESCRIPTION
        Trivial by design. The value is not the logic, it is the seam: because
        every existence check in the codebase funnels through one function, a unit
        test can simulate any filesystem shape with a single mock.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Test-Path -LiteralPath $Path
}

function Get-TSFileText {
    <#
    .SYNOPSIS
        Reads a whole file as a single string.

    .DESCRIPTION
        -Raw is deliberate: callers parse JSON, and feeding a line array to a JSON
        parser works by accident rather than by contract.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Get-Content -LiteralPath $Path -Raw -Encoding utf8
}

function Get-TSFileLine {
    <#
    .SYNOPSIS
        Reads a file as an array of lines. A missing file returns nothing.

    .DESCRIPTION
        The counterpart to Add-TSFileLine, and separate from Get-TSFileText
        because the journal is JSONL: the unit the caller wants is a line, and
        splitting a raw string by hand means picking a newline convention and
        being wrong about one of them.

        A missing file is an empty array, not an error. An absent journal means
        nothing has ever been applied on this machine, which is an ordinary thing
        for uninstall to find and report rather than a failure to raise.

    .PARAMETER Path
        File to read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    @(Get-Content -LiteralPath $Path -Encoding utf8)
}

function Get-TSSpecialFolder {
    <#
    .SYNOPSIS
        Resolves a Windows special folder to its real current path.

    .DESCRIPTION
        Never build these paths by joining onto the user profile directory.
        OneDrive Known Folder Move relocates Documents, and PowerShell follows it,
        so a hand-built path points somewhere the shell is not actually looking.
        That mismatch is exactly how a profile script gets deployed to a location
        that never loads.

        Asking Windows where the folder is means doctor can compare the answer
        against the naive location and report the redirection instead of tripping
        over it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LocalApplicationData', 'ApplicationData', 'MyDocuments', 'UserProfile')]
        [string] $Name
    )

    [Environment]::GetFolderPath($Name)
}

function Expand-TSPath {
    <#
    .SYNOPSIS
        Resolves the path forms that appear in desired state to a real path.

    .DESCRIPTION
        The desired-state document contains both Windows environment syntax
        (%LOCALAPPDATA%\Microsoft\Windows Terminal\Backgrounds) and shell syntax
        (~/.poshthemes/andalus.omp.json), because each was written in the idiom of
        the tool that consumes it. Normalising them is environment contact, which
        is why it lives here rather than in a helper.

        The tilde is expanded through Get-TSSpecialFolder rather than through
        Resolve-Path. Resolve-Path resolves ~ against the PowerShell provider's
        current location, which is not necessarily the user profile, and fails
        outright when the target does not exist yet - which is the normal case for
        a path apply is about to create.

        Relative segments are collapsed last, and only for a path that is already
        rooted. This is not cosmetic vanity: paths built from $PSScriptRoot carry
        a trail of '..\..\..' into every message the user reads, and a failure
        message is the one place a path has to be legible, because it is the only
        output a user is expected to act on. The rooted test matters because
        GetFullPath resolves a relative path against the .NET process working
        directory, which is not PowerShell's current location and diverges from it
        the moment anyone runs Set-Location. Quietly resolving against the wrong
        base would be a worse answer than declining to normalise.

    .PARAMETER Path
        A path possibly containing %VARIABLE% references or a leading tilde.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)

    if ($expanded -eq '~') {
        $expanded = Get-TSSpecialFolder -Name 'UserProfile'
    }
    elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $relative = $expanded.Substring(2)
        $expanded = Join-Path -Path (Get-TSSpecialFolder -Name 'UserProfile') -ChildPath $relative
    }

    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }

    try {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        # Normalisation is a readability improvement, never a precondition. A path
        # this cannot tidy is still a path the caller asked for, and swallowing the
        # caller's input here to raise a cosmetic error would be a poor trade.
        return $expanded
    }
}

function Get-TSLogPath {
    <#
    .SYNOPSIS
        Returns the structured log path the environment asks for, or an empty string.

    .DESCRIPTION
        Logging to a file is opt-in through TS_LOG_PATH, and this is the only
        place that variable is read. Write-TSLog lives in Private/, where reaching
        for the environment directly would be the same category of shortcut as
        reaching for Add-Content: it works, and it costs the seam that lets a test
        exercise the logger with no machine underneath it.

        An unset or blank variable is an empty string rather than $null, so the
        caller's test is 'if (-not $path)' and never a null check that a strict
        mode session will fail differently.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $value = [Environment]::GetEnvironmentVariable('TS_LOG_PATH')

    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }

    Expand-TSPath -Path $value.Trim()
}

function Get-TSFileHashValue {
    <#
    .SYNOPSIS
        Returns the SHA-256 of a file, or an empty string when it does not exist.

    .DESCRIPTION
        The empty string for a missing file is the important part of this contract,
        not a convenience. apply decides whether to write by comparing the hash of
        the source against the hash of the destination, and 'this file is not there'
        is a legitimate answer to that comparison - it simply never equals a real
        hash, so the copy happens.

        That is what makes apply idempotent by construction. There is no 'already
        applied' flag to get out of sync with reality, and no first-run special
        case: the second run computes two identical hashes and does nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-TSDirectory {
    <#
    .SYNOPSIS
        Creates a directory if it is absent. Returns whether it created one.

    .DESCRIPTION
        Returns a boolean rather than the directory object because the only thing
        callers need to know is whether this counted as a change, which is what
        goes in the journal.

    .PARAMETER Path
        Directory to ensure exists.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (Test-Path -LiteralPath $Path) {
        return $false
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
        $null = New-Item -ItemType Directory -Path $Path -Force
        return $true
    }

    $false
}

function Backup-TSFile {
    <#
    .SYNOPSIS
        Copies a file to a timestamped name under a backup directory.

    .DESCRIPTION
        Returns the backup path, or an empty string when there was nothing to back
        up. Callers put that path in the journal and in the report, because a
        backup nobody can find is not a backup.

        The predecessor project wrote timestamped backups next to the original
        file and never removed or referenced them again, so they accumulated in
        the user's Documents folder indefinitely and none of them were ever used to
        restore anything. Collecting them under one directory named in the output
        is the difference between a safety net and litter.

    .PARAMETER Path
        File to back up. A missing file is not an error.

    .PARAMETER BackupRoot
        Directory to place the copy in. Created if absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $BackupRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $null = New-TSDirectory -Path $BackupRoot -Confirm:$false

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $leaf = Split-Path -Path $Path -Leaf
    $destination = Join-Path -Path $BackupRoot -ChildPath "$stamp-$leaf"

    Copy-Item -LiteralPath $Path -Destination $destination -Force

    $destination
}

function Copy-TSFile {
    <#
    .SYNOPSIS
        Places a file at a destination without ever leaving it half written.

    .DESCRIPTION
        Copies to a sibling temporary name and moves that into place. The move is
        the point: on the same volume it replaces the destination entry rather than
        rewriting its contents, so a reader sees either the old file or the new one
        and never a truncated one.

        This matters specifically for Windows Terminal fragments. Terminal does not
        report a parse error for a fragment it cannot read - it discards it. A copy
        interrupted halfway would therefore present to the user as 'apply said it
        worked and nothing changed', which is the hardest possible failure to
        diagnose from the outside.

        The temporary file is a sibling rather than one in TEMP so that the move
        stays within one volume. A cross-volume move is a copy-and-delete, which
        gives back exactly the torn-write window this avoids.

    .PARAMETER Source
        File to copy.

    .PARAMETER Destination
        Where it should end up. Parent directories are created.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination
    )

    $parent = Split-Path -Path $Destination -Parent

    if ($parent) {
        $null = New-TSDirectory -Path $parent -Confirm:$false
    }

    $staged = "$Destination.tsnew"

    Copy-Item -LiteralPath $Source -Destination $staged -Force
    Move-Item -LiteralPath $staged -Destination $Destination -Force
}

function Set-TSFileText {
    <#
    .SYNOPSIS
        Writes text to a file without ever leaving it half written.

    .DESCRIPTION
        The same staged-then-moved sequence as Copy-TSFile, for callers holding
        new content in memory rather than in a file. configure -Save is the caller
        that needs it: what it writes is the document it just read with a single
        value spliced into it, and there is no source file to copy from.

        UTF-8 with no byte order mark, and whatever newlines the caller put in the
        string. Both matter for a document a human also edits. Set-Content's utf8
        writes a BOM on Windows PowerShell, and while this module only runs on 7.4,
        the files it writes are read by tools that are not PowerShell at all.
        Rewriting line endings would turn a one-value change into a diff that
        touches every line, which is the fastest way to lose a user's trust in a
        tool that edits their files.

    .PARAMETER Path
        File to write. Parent directories are created.

    .PARAMETER Text
        Exact content to write.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file')) {
        return
    }

    $parent = Split-Path -Path $Path -Parent

    if ($parent) {
        $null = New-TSDirectory -Path $parent -Confirm:$false
    }

    $staged = "$Path.tsnew"
    $encoding = [System.Text.UTF8Encoding]::new($false)

    [System.IO.File]::WriteAllText($staged, $Text, $encoding)
    Move-Item -LiteralPath $staged -Destination $Path -Force
}

function Remove-TSFile {
    <#
    .SYNOPSIS
        Deletes a file. Reports whether there was one to delete.

    .DESCRIPTION
        Returns a boolean for the same reason New-TSDirectory does: the caller is
        writing a journal entry, and the only fact it needs is whether this counted
        as a change.

        A missing file is not an error. uninstall reaches this function while
        undoing a create, and a file the user has already deleted by hand is
        precisely the state uninstall was trying to produce.

    .PARAMETER Path
        File to delete.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Delete file')) {
        Remove-Item -LiteralPath $Path -Force
        return $true
    }

    $false
}

function Add-TSFileLine {
    <#
    .SYNOPSIS
        Appends one line to a file, creating it and its parent if needed.

    .DESCRIPTION
        The journal is append-only and one JSON object per line. Append is the
        whole contract: a journal that is rewritten can lose the record of the
        change currently being made, which is the one record that matters if the
        process dies mid-apply.

    .PARAMETER Path
        File to append to.

    .PARAMETER Line
        Text to append.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Line
    )

    $parent = Split-Path -Path $Path -Parent

    if ($parent) {
        $null = New-TSDirectory -Path $parent -Confirm:$false
    }

    Add-Content -LiteralPath $Path -Value $Line -Encoding utf8
}
