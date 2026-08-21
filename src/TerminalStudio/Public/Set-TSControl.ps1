function Set-TSControl {
    <#
    .SYNOPSIS
        Writes one control's value back into desired state.

    .DESCRIPTION
        The other half of Get-TSControl, and the reason configure no longer has to
        exit 3. It takes a control id rather than a control object, because the
        objects Get-TSControl returns deliberately carry no target: the UI should
        not be able to invent a write location, and the definition in
        Data/controls.json stays the single place a control's address is stated.

        WHAT IT WRITES, AND WHERE

        Desired state, never the machine. configure changes what the machine
        should look like; apply is what makes the machine match. Keeping those
        separate is what makes the change reviewable in git before it is real, and
        it is why saving a control does not need Windows Terminal to be closed.

        HOW THE EDIT IS PROVED

        Edit-TSJsonText splices one value into the document text, so comments,
        formatting and key order survive. Then the result is parsed and compared
        against the original value by value, and the write is abandoned unless
        exactly one leaf changed and it is the leaf that was asked for. A splice
        that cannot be verified is not applied - the file is left as it was.

        WHAT IT REFUSES

        Presence controls: the checkbox that means 'this package should be in
        desired state' implies inserting or deleting a JSON member, which is where
        a textual splice stops being provably local. Those are reported as skipped
        with the reason, not silently ignored and not half attempted.

        SAFETY

        The document is backed up before it is written and the change is recorded
        in the journal as 'edit', which uninstall already replays. -WhatIf reports
        the intended write without making it.

    .PARAMETER Id
        Control id, as listed by Get-TSControl.

    .PARAMETER Value
        New value. Written as a JSON literal, so a boolean becomes true or false
        and a number stays a number.

    .PARAMETER DesiredStatePath
        Path to the desired-state document.

    .PARAMETER ControlDefinitionPath
        Path to the control definition.

    .PARAMETER RunId
        Correlation id to journal this edit under. Pass one id for a batch of
        controls saved together, so uninstall can reverse them as a unit.

    .PARAMETER JournalPath
        Append-only JSONL journal. Defaults to the per-user application data
        directory.

    .PARAMETER BackupRoot
        Where the displaced copy is kept.

    .OUTPUTS
        A TerminalStudio.Result. Pass means desired state now says this, Skip means
        nothing was written and why, Fail means the edit was refused or could not be
        verified.

    .EXAMPLE
        Set-TSControl -Id 'acrylic' -Value $false -WhatIf

    .EXAMPLE
        Set-TSControl -Id 'font-size' -Value 13
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Value,

        [string] $DesiredStatePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\desired-state\machine.json'),

        [string] $ControlDefinitionPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\Data\controls.json'),

        [string] $RunId = '',

        [string] $JournalPath,

        [string] $BackupRoot
    )

    $DesiredStatePath = Expand-TSPath -Path $DesiredStatePath
    $ControlDefinitionPath = Expand-TSPath -Path $ControlDefinitionPath
    $rendered = ConvertTo-Json -InputObject $Value -Compress

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

    $control = $null

    foreach ($group in @($definition.groups)) {
        foreach ($candidate in @($group.controls)) {
            if ([string] $candidate.id -eq $Id) {
                $control = $candidate
                break
            }
        }

        if ($control) {
            break
        }
    }

    if (-not $control) {
        return New-TSResult -Name "Control: $Id" -Status 'Fail' -Expected 'a control defined in controls.json' -Actual 'no control with that id' -Remediation 'Run Get-TSControl to list the ids this build knows about.'
    }

    $label = [string] $control.label
    $target = $control.target
    $targetNames = @($target.PSObject.Properties.Name)
    $source = [string] $target.source
    $mode = if ($targetNames -contains 'mode') { [string] $target.mode } else { 'value' }

    if ($mode -ne 'value') {
        return New-TSResult -Name "Control: $label" -Status 'Skip' -Expected "$Id = $rendered" -Actual "$mode controls are not written by this build" -Remediation 'Saving this control means adding or removing a JSON member, and a textual splice cannot prove that edit was local the way a scalar replacement can. Edit desired state by hand; plan and doctor will pick it up.'
    }

    $state = Get-TSDesiredState -Path $DesiredStatePath

    # Relative source values in machine.json are repository-relative, the same
    # assumption Get-TSControl makes when it reads them.
    $repoRoot = Split-Path -Path (Split-Path -Path $DesiredStatePath -Parent) -Parent
    $resources = @($state.resources)
    $file = ''
    $jsonPath = ''

    if ($source -eq 'machine') {
        $kind = [string] $target.kind
        $position = -1

        for ($candidate = 0; $candidate -lt $resources.Count; $candidate++) {
            if ([string] $resources[$candidate].kind -ne $kind) {
                continue
            }

            if ($targetNames -contains 'match') {
                $property = [string] $target.match.property
                $wanted = [string] $target.match.value
                $available = @($resources[$candidate].PSObject.Properties.Name)

                if ($available -notcontains $property -or [string] $resources[$candidate].$property -ne $wanted) {
                    continue
                }
            }

            $position = $candidate
            break
        }

        if ($position -lt 0) {
            return New-TSResult -Name "Control: $label" -Status 'Fail' -Expected "a resource of kind $kind in desired state" -Actual 'no matching resource' -Remediation "Nothing was written. Add the resource to $DesiredStatePath first."
        }

        $file = $DesiredStatePath
        $jsonPath = "resources.$position.$([string] $target.property)"
    }
    else {
        $kind = switch ($source) {
            'fragment' {
                'terminal.fragment'
            }
            'omp' {
                'omp.theme'
            }
            default {
                ''
            }
        }

        if (-not $kind) {
            return New-TSResult -Name "Control: $label" -Status 'Fail' -Expected 'a control source this build can write' -Actual "source '$source' is not one of machine, fragment, omp" -Remediation 'Nothing was written.'
        }

        $owner = @($resources | Where-Object { [string] $_.kind -eq $kind })

        if ($owner.Count -eq 0 -or @($owner[0].PSObject.Properties.Name) -notcontains 'source') {
            return New-TSResult -Name "Control: $label" -Status 'Fail' -Expected "a $kind resource with a source file" -Actual 'desired state does not point at a document for this control' -Remediation "Nothing was written. Check the $kind resource in $DesiredStatePath."
        }

        # Resolved through the resource that owns the document, never by filename,
        # so switching the fragment in desired state moves these edits with it.
        $file = Join-Path -Path $repoRoot -ChildPath ([string] $owner[0].source)
        $jsonPath = [string] $target.path
    }

    if (-not (Test-TSPath -Path $file)) {
        return New-TSResult -Name "Control: $label" -Status 'Fail' -Expected "the document at $file" -Actual 'file not found' -Remediation 'Nothing was written.'
    }

    $original = Get-TSFileText -Path $file

    try {
        $edited = Edit-TSJsonText -Text $original -Path $jsonPath -Value $Value
    }
    catch {
        return New-TSResult -Name "Control: $label" -Status 'Fail' -Expected "$jsonPath = $rendered" -Actual $_.Exception.Message -Remediation "Nothing was written to $file."
    }

    if ($edited -eq $original) {
        return New-TSResult -Name "Control: $label" -Status 'Pass' -Expected "$jsonPath = $rendered" -Actual 'already set; nothing written'
    }

    try {
        $reparsed = $edited | ConvertFrom-Json
    }
    catch {
        return New-TSResult -Name "Control: $label" -Status 'Fail' -Expected 'a document that still parses' -Actual "the edit produced invalid JSON: $($_.Exception.Message)" -Remediation "Nothing was written to $file. This is a bug in Edit-TSJsonText; please report the control id and the path."
    }

    $before = $original | ConvertFrom-Json
    $changed = @(Compare-TSJsonDocument -Reference $before -Difference $reparsed)

    if ($changed.Count -ne 1 -or $changed[0] -ne $jsonPath) {
        $detail = if ($changed.Count -eq 0) { 'the edit changed no value' } else { "the edit touched: $($changed -join ', ')" }
        return New-TSResult -Name "Control: $label" -Status 'Fail' -Expected "exactly one value changed: $jsonPath" -Actual $detail -Remediation "Nothing was written to $file. An edit that cannot be shown to be local is not applied."
    }

    $localAppData = Get-TSSpecialFolder -Name 'LocalApplicationData'

    if (-not $JournalPath) {
        $JournalPath = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\journal.jsonl'
    }

    if (-not $BackupRoot) {
        $BackupRoot = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\backups'
    }

    if (-not $PSCmdlet.ShouldProcess($file, "set $jsonPath to $rendered")) {
        return New-TSResult -Name "Control: $label" -Status 'Skip' -Expected "$jsonPath = $rendered" -Actual 'would set' -Remediation 'Nothing was written. Run configure -Save without -WhatIf to keep this change.'
    }

    if (-not $RunId) {
        $RunId = [guid]::NewGuid().ToString()
    }

    $previousHash = Get-TSFileHashValue -Path $file
    $backup = Backup-TSFile -Path $file -BackupRoot $BackupRoot

    Set-TSFileText -Path $file -Text $edited -Confirm:$false

    $newHash = Get-TSFileHashValue -Path $file

    # Same field set as an apply record, plus the path that changed. uninstall
    # replays 'edit' with the generic restore-from-backup branch, so this record
    # has to be shaped like the others rather than be a special case there.
    $record = [ordered] @{
        timestamp      = (Get-Date).ToUniversalTime().ToString('o')
        runId          = $RunId
        action         = 'edit'
        kind           = 'desired-state'
        name           = $label
        source         = ''
        destination    = $file
        previousSha256 = $previousHash
        newSha256      = $newHash
        backup         = $backup
        path           = $jsonPath
    }

    Add-TSFileLine -Path $JournalPath -Line ($record | ConvertTo-Json -Depth 3 -Compress)

    Write-TSLog -Message "configure set $jsonPath in $file" -RunId $RunId -Data @{
        command     = 'configure'
        control     = $Id
        path        = $jsonPath
        destination = $file
    }

    New-TSResult -Name "Control: $label" -Status 'Pass' -Expected "$jsonPath = $rendered" -Actual "written to $(Split-Path -Path $file -Leaf)" -Remediation 'Run apply to converge the machine onto this change.'
}
