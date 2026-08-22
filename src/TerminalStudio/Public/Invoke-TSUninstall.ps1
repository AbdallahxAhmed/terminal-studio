function Invoke-TSUninstall {
    <#
    .SYNOPSIS
        Undoes what apply did, by replaying the change journal backwards.

    .DESCRIPTION
        The journal has existed since 0.2.0 for exactly this. Every line records
        one file write with the hash before it, the hash after it, and where the
        displaced copy was kept, which makes removal a replay rather than a second
        implementation of the same knowledge.

        That distinction is the whole design. The predecessor project implemented
        each deployment once and each removal again separately, and the two sets
        drifted apart immediately: an uninstall that knows its file list by heart
        is wrong the moment apply learns a new resource kind. This function knows
        nothing about resource kinds. It reads what happened.

        REVERSE ORDER

        Records are replayed newest first. If one destination was written twice,
        undoing the later write and then the earlier one leaves the original file
        in place; the other order leaves the intermediate version.

        THE HASH GATE

        Every file is hashed before it is touched and compared against the hash
        apply recorded after writing it. They differ when the user has edited the
        file since, and in that case nothing is done to it and the report says so.
        Restoring a backup over an edit made by hand would destroy work this tool
        was never given permission to destroy, and 'uninstall ate my profile' is a
        far worse outcome than 'uninstall left one file behind and told me which'.

        A backup is verified against its recorded hash before it is restored, for
        the same reason: a backup that is not what the journal says it is has
        stopped being evidence of anything.

        WHAT IT DOES NOT DO

        Packages, fonts and modules were never installed by apply, so there is
        nothing here to remove and nothing is claimed. Directories that apply
        created are left in place: an empty Fragments folder is harmless, while
        deciding whether a directory is 'ours' to delete is a guess that ends in
        someone else's files.

        Undo actions are themselves journalled, with action 'restore' or 'remove'
        and the id of the run they undid. Only 'create', 'replace' and 'edit'
        records are ever replayed, so uninstall cannot invert its own work. The
        hash gate would catch that anyway; both exist because the cost is one
        comparison.

    .PARAMETER RunId
        Undo one specific run. The default is the most recent run in the journal.

    .PARAMETER All
        Undo every recorded run, newest change first.

    .PARAMETER JournalPath
        Journal to replay. Defaults to the per-user application data directory.

    .PARAMETER BackupRoot
        Where to look for a displaced copy when the path recorded in the journal no
        longer resolves, after a profile move or a restore onto another machine.
        The recorded path is always tried first.

    .OUTPUTS
        TerminalStudio.Result objects. Pass means the file is back as it was, Skip
        means deliberately untouched and why, Fail means an undo was attempted and
        could not be completed.

    .EXAMPLE
        Invoke-TSUninstall -WhatIf

        Everything the last apply would give back, without giving any of it back.

    .EXAMPLE
        Invoke-TSUninstall -All

        Undo every run the journal remembers.

    .EXAMPLE
        Invoke-TSUninstall | Where-Object Status -ne 'Pass'

        Everything that still needs a human.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Latest')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Run')]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(ParameterSetName = 'All')]
        [switch] $All,

        [string] $JournalPath,

        [string] $BackupRoot
    )

    $localAppData = Get-TSSpecialFolder -Name 'LocalApplicationData'

    if (-not $JournalPath) {
        $JournalPath = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\journal.jsonl'
    }

    if (-not $BackupRoot) {
        $BackupRoot = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\backups'
    }

    $undoRunId = [guid]::NewGuid().ToString()
    $results = [System.Collections.Generic.List[object]]::new()

    $lines = @(Get-TSFileLine -Path $JournalPath)
    $forward = [System.Collections.Generic.List[object]]::new()
    $unreadable = 0

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
        }
        catch {
            # One unreadable line must not cost the user the rest of their
            # history. The count is reported, so a damaged journal is visible
            # instead of quietly shortening the undo.
            $unreadable++
            continue
        }

        $fields = @($record.PSObject.Properties.Name)

        if ($fields -notcontains 'action' -or $fields -notcontains 'destination' -or $fields -notcontains 'runId') {
            $unreadable++
            continue
        }

        # Only forward actions are replayed. 'restore' and 'remove' are what this
        # function writes, and replaying those would undo an undo.
        if (@('create', 'replace', 'edit') -notcontains [string] $record.action) {
            continue
        }

        $forward.Add($record)
    }

    if ($unreadable -gt 0) {
        $results.Add((New-TSResult -Name 'Change journal' -Status 'Warn' -Expected 'every line readable' -Actual "$unreadable line(s) could not be read and were ignored" -Remediation "Inspect $JournalPath. Nothing an unreadable record described was undone, so those files are still in place."))
    }

    if ($forward.Count -eq 0) {
        # Pass, not Fail. Nothing to undo means the machine is already in the state
        # uninstall exists to produce, and an exit code that called that a failure
        # would be unusable in a script that runs uninstall unconditionally.
        $results.Add((New-TSResult -Name 'Change journal' -Status 'Pass' -Expected 'nothing left applied' -Actual "no recorded changes at $JournalPath"))
        return $results
    }

    $runIds = [System.Collections.Generic.List[string]]::new()

    foreach ($record in $forward) {
        $id = [string] $record.runId

        if (-not $runIds.Contains($id)) {
            $runIds.Add($id)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Run') {
        if (-not $runIds.Contains($RunId)) {
            $known = (@($runIds) | Select-Object -Last 5) -join ', '
            $results.Add((New-TSResult -Name 'Change journal' -Status 'Fail' -Expected "a run recorded in $JournalPath" -Actual "no run with id $RunId" -Remediation "Most recent run ids: $known"))
            return $results
        }

        $selected = @($RunId)
    }
    elseif ($All) {
        $selected = @($runIds)
    }
    else {
        $selected = @($runIds[$runIds.Count - 1])
    }

    $targeted = @($forward | Where-Object { $selected -contains [string] $_.runId })

    if ($targeted.Count -gt 1) {
        [array]::Reverse($targeted)
    }

    Write-TSLog -Message "uninstall run $undoRunId replaying $($targeted.Count) record(s) from $($selected.Count) apply run(s)." -RunId $undoRunId -Data @{
        command = 'uninstall'
        phase   = 'start'
        whatIf  = [bool] $WhatIfPreference
        journal = $JournalPath
        runs    = $selected.Count
        records = $targeted.Count
    }

    foreach ($record in $targeted) {
        $fields = @($record.PSObject.Properties.Name)

        $destination = [string] $record.destination
        $kind = if ($fields -contains 'kind') { [string] $record.kind } else { 'file' }
        $label = if (($fields -contains 'name') -and $record.name) { [string] $record.name } else { $destination }
        $recorded = if ($fields -contains 'newSha256') { [string] $record.newSha256 } else { '' }
        $previous = if ($fields -contains 'previousSha256') { [string] $record.previousSha256 } else { '' }
        $backup = if ($fields -contains 'backup') { [string] $record.backup } else { '' }

        $current = Get-TSFileHashValue -Path $destination

        if (-not $current) {
            $results.Add((New-TSResult -Name "Undo: $label" -Status 'Skip' -Expected 'file removed or restored' -Actual 'already gone; nothing to undo'))
            continue
        }

        if ($recorded -and $current -ne $recorded.ToUpperInvariant()) {
            $hint = if ($backup) { "The version apply displaced is at $backup." } else { 'apply created this file, so there is no earlier version to put back.' }
            $results.Add((New-TSResult -Name "Undo: $label" -Status 'Skip' -Expected 'the file apply wrote' -Actual 'changed since apply wrote it; left alone' -Remediation "Refusing to overwrite your own edit at $destination. $hint"))
            continue
        }

        $verb = if ($previous) { 'restore' } else { 'remove' }

        if (-not $PSCmdlet.ShouldProcess($destination, "$verb $kind")) {
            $results.Add((New-TSResult -Name "Undo: $label" -Status 'Skip' -Expected $destination -Actual "would $verb" -Remediation 'Nothing was changed. Run uninstall without -WhatIf to undo this.'))
            continue
        }

        $source = ''
        $after = ''

        if ($verb -eq 'remove') {
            $null = Remove-TSFile -Path $destination -Confirm:$false
            $after = Get-TSFileHashValue -Path $destination

            if ($after) {
                $results.Add((New-TSResult -Name "Undo: $label" -Status 'Fail' -Expected 'file removed' -Actual "still present at $destination" -Remediation 'Delete it by hand, or find out which process is holding it open.'))
                continue
            }
        }
        else {
            if ($backup -and (Test-TSPath -Path $backup)) {
                $source = $backup
            }
            elseif ($backup) {
                # Journalled paths are absolute, so they stop resolving after a
                # profile move or a restore onto another machine. The backup
                # directory is the one piece of that path still known to be right.
                $candidate = Join-Path -Path $BackupRoot -ChildPath (Split-Path -Path $backup -Leaf)

                if (Test-TSPath -Path $candidate) {
                    $source = $candidate
                }
            }

            if (-not $source) {
                $missing = if ($backup) { "the recorded backup is missing: $backup" } else { 'the journal records no backup for this change' }
                $results.Add((New-TSResult -Name "Undo: $label" -Status 'Fail' -Expected "the copy taken before apply wrote $destination" -Actual $missing -Remediation "Look under $BackupRoot for a file whose name ends in the same leaf, and copy it back by hand. Nothing was changed."))
                continue
            }

            $sourceHash = Get-TSFileHashValue -Path $source

            if ($sourceHash -ne $previous.ToUpperInvariant()) {
                # ${destination}, not $destination, because the colon that follows
                # it is how PowerShell writes a scope qualifier - $env:PATH - so
                # the parser reads the name as unterminated and the file does not
                # compile. One unparseable file fails the whole module import, so
                # this typo took every command in the tool down with it. Any
                # interpolated variable immediately followed by ':' needs braces.
                $results.Add((New-TSResult -Name "Undo: $label" -Status 'Fail' -Expected "backup sha256 $($previous.ToUpperInvariant())" -Actual "backup sha256 $sourceHash" -Remediation "Refusing to restore $source over ${destination}: it is not the file apply displaced. Compare them by hand before copying either way."))
                continue
            }

            Copy-TSFile -Source $source -Destination $destination
            $after = Get-TSFileHashValue -Path $destination

            if ($after -ne $previous.ToUpperInvariant()) {
                $results.Add((New-TSResult -Name "Undo: $label" -Status 'Fail' -Expected "restored sha256 $($previous.ToUpperInvariant())" -Actual "sha256 after restore $after" -Remediation "The copy did not land as expected. $source still holds the original; do not run uninstall again until you know why."))
                continue
            }
        }

        # Written after the change succeeded, never before, for the same reason
        # apply does it in that order: a record of something that did not happen is
        # worse than a missing record, because the next reader believes it.
        $undo = [ordered] @{
            timestamp      = (Get-Date).ToUniversalTime().ToString('o')
            runId          = $undoRunId
            action         = $verb
            kind           = $kind
            name           = $label
            source         = $source
            destination    = $destination
            previousSha256 = $current
            newSha256      = $after
            backup         = ''
            undoOf         = [string] $record.runId
        }

        Add-TSFileLine -Path $JournalPath -Line ($undo | ConvertTo-Json -Depth 3 -Compress)

        Write-TSLog -Message "uninstall $verb $destination" -RunId $undoRunId -Data @{
            command     = 'uninstall'
            action      = $verb
            kind        = $kind
            destination = $destination
            undoOf      = [string] $record.runId
        }

        $actual = if ($verb -eq 'restore') { "restored from $source" } else { "removed $destination" }

        $results.Add((New-TSResult -Name "Undo: $label" -Status 'Pass' -Expected $destination -Actual $actual))
    }

    $undone = @($results | Where-Object { $_.Status -eq 'Pass' -and $_.Actual -notmatch '^no recorded' }).Count

    Write-TSLog -Message "uninstall run $undoRunId finished; $undone change(s) undone." -RunId $undoRunId -Data @{
        command = 'uninstall'
        phase   = 'end'
        undone  = $undone
    }

    $results
}
