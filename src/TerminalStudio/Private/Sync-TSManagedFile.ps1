function Sync-TSManagedFile {
    <#
    .SYNOPSIS
        Converges one managed file toward its source of truth, and records it.

    .DESCRIPTION
        Four of the resource kinds in desired state - terminal.fragment,
        omp.theme, terminal.asset and shell.profile - differ only in where the
        file lands. Modelling them as one operation is deliberate: the predecessor
        project implemented each deployment separately, and then implemented each
        removal separately again, and the two sets drifted apart immediately.

        Idempotence is structural. The decision to write is a comparison between
        the hash of the source and the hash of the destination, so a second run
        computes two equal hashes and does nothing at all - no write, no backup,
        no journal entry. There is deliberately no 'already applied' marker
        anywhere, because a marker is a second copy of the truth and is free to
        disagree with what is actually on disk.

        Order within a change matters and is not arbitrary: back up first, then
        write. If the process dies between the two, the backup exists and the
        original is still in place. The reverse order has a window where neither
        is true.

        The journal entry is written after the copy succeeds, not before. A record
        of a change that did not happen is worse than a missing record, because
        uninstall replays the journal and would try to restore a file over one
        that was never modified.

    .PARAMETER Name
        Display name for the result.

    .PARAMETER Kind
        Resource kind, recorded in the journal.

    .PARAMETER Source
        File to deploy, already resolved to an absolute path.

    .PARAMETER Destination
        Where it belongs, already expanded.

    .PARAMETER BackupRoot
        Directory to keep displaced copies in.

    .PARAMETER JournalPath
        Append-only JSONL journal.

    .PARAMETER RunId
        Correlation id shared by every change in one apply.

    .PARAMETER ExpectedSha256
        Optional declared hash of the source. When present it is enforced.

    .OUTPUTS
        TerminalStudio.Result
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Kind,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $BackupRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $JournalPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [string] $ExpectedSha256 = ''
    )

    if (-not (Test-TSPath -Path $Source)) {
        # Not an exception. One missing source should report itself and let the
        # other resources converge, because a half-applied machine that says which
        # half is more useful than an aborted run that says nothing.
        return New-TSResult -Name $Name -Status 'Fail' -Expected $Destination -Actual "source file is missing: $Source" -Remediation 'The file this resource deploys is not in the payload. Binary assets are not committed to the repository and have to be placed by hand.'
    }

    $sourceHash = Get-TSFileHashValue -Path $Source

    if ($ExpectedSha256) {
        # Enforced only when declared. A blank hash on a file that travelled with
        # the payload is not a hole in the same sense as a blank hash on something
        # downloaded over the network, because the archive was already verified as
        # a whole before any of this ran.
        if ($sourceHash -ne $ExpectedSha256.ToUpperInvariant()) {
            return New-TSResult -Name $Name -Status 'Fail' -Expected "source sha256 $($ExpectedSha256.ToUpperInvariant())" -Actual "source sha256 $sourceHash" -Remediation 'Refusing to deploy a file that does not match its declared hash. Either the file or the declaration is wrong; do not guess which.'
        }
    }

    $destinationHash = Get-TSFileHashValue -Path $Destination

    if ($sourceHash -eq $destinationHash) {
        return New-TSResult -Name $Name -Status 'Pass' -Expected $Destination -Actual 'already matches, nothing written'
    }

    $verb = if ($destinationHash) { 'replace' } else { 'create' }

    if (-not $PSCmdlet.ShouldProcess($Destination, "$verb $Kind")) {
        # Reported rather than dropped. An empty -WhatIf report is impossible to
        # tell apart from a converged machine.
        return New-TSResult -Name $Name -Status 'Skip' -Expected $Destination -Actual "would $verb" -Remediation 'Nothing was written. Run apply without -WhatIf to make this change.'
    }

    $backup = Backup-TSFile -Path $Destination -BackupRoot $BackupRoot

    Copy-TSFile -Source $Source -Destination $Destination

    $record = [ordered] @{
        timestamp      = (Get-Date).ToUniversalTime().ToString('o')
        runId          = $RunId
        action         = $verb
        kind           = $Kind
        name           = $Name
        source         = $Source
        destination    = $Destination
        previousSha256 = $destinationHash
        newSha256      = $sourceHash
        backup         = $backup
    }

    # -Compress keeps one record on one line, which is the entire contract of a
    # JSONL file: it can be appended to safely and read back a line at a time
    # without parsing the whole history.
    Add-TSFileLine -Path $JournalPath -Line ($record | ConvertTo-Json -Depth 3 -Compress)

    $actual = if ($backup) { "replaced; previous version kept at $backup" } else { "created $Destination" }

    New-TSResult -Name $Name -Status 'Pass' -Expected $Destination -Actual $actual
}
