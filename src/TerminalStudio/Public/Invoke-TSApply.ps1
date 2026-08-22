function Invoke-TSApply {
    <#
    .SYNOPSIS
        Converges this machine's managed files toward desired state.

    .DESCRIPTION
        apply is the Set operation. It is deliberately the last verb implemented,
        because everything that makes it safe had to exist first: a Test operation
        to decide what needs doing (plan), somewhere to put displaced files
        (Backup-TSFile), a record of what was done (the journal), and a way to see
        the whole thing without doing it (-WhatIf).

        WHAT IT MANAGES

        Four resource kinds, all of which are a file arriving at a known path:
        terminal.fragment, omp.theme, terminal.asset and shell.profile.

        WHAT IT DELEGATES, AND WHY THAT IS NOT A GAP

        winget.package, font and psmodule are checked and reported with the exact
        command that would satisfy them, and are not executed. Packages need a
        process launcher, fonts need a download whose declared sha256 is still
        blank in desired state, and modules need a gallery client. None of those
        has an adapter, none has a test, and none can be rolled back by replaying
        a journal of file writes.

        Running them anyway would make apply's report claim more than apply can
        actually undo, which is precisely the failure the change journal exists to
        prevent. A command that is honest about its edges is more useful than one
        that is quietly broader than its guarantees.

        terminal.global is different again. It is not waiting for an adapter; it
        is refused. See ADR-0006.

        SAFETY PROPERTIES

          - Nothing is written when the source and destination already match, so
            running apply repeatedly is indistinguishable from running it once.
          - Every replaced file is copied to a backup directory first, and the
            backup path appears in both the report and the journal.
          - Every change appends one JSON line to an append-only journal, which is
            what makes uninstall a replay of recorded events rather than a second
            guess at what happened. See Invoke-TSUninstall.
          - -WhatIf reports every intended change without making any of them.

        WATCHING A RUN AFTER THE FACT

        Set the TS_LOG_PATH environment variable to a file and each run appends
        JSONL records to it, starting with one written before any resource is
        touched. Every record carries the same run id as the journal lines from
        that run, so the two can be joined. Unset, nothing is written anywhere and
        no directory is created.

        A NOTE FOR CALLERS ABOUT -WhatIf

        Pass it. Do not set $WhatIfPreference in your own scope and expect this
        function to observe it. This function is exported from a module, so its
        scope chain is rooted in the module's session state rather than in yours,
        and preference variables do not cross that boundary. The entry script
        learned this the expensive way: it printed a report headed 'dry run,
        nothing written' over a shell profile it had just replaced.

    .PARAMETER DesiredStatePath
        Path to the desired-state document.

    .PARAMETER PayloadRoot
        Root that resource source paths are relative to. Defaults to the
        repository or installed payload this module was loaded from.

    .PARAMETER JournalPath
        Append-only JSONL journal. Defaults to the per-user application data
        directory.

    .PARAMETER BackupRoot
        Where displaced files are kept.

    .OUTPUTS
        TerminalStudio.Result objects. Pass means the machine now matches, Skip
        means nothing was done and why, Fail means a change was attempted or
        required and could not be completed.

    .EXAMPLE
        Invoke-TSApply -WhatIf

        Show every change without making one.

    .EXAMPLE
        Invoke-TSApply | Where-Object Status -ne 'Pass'

        Everything that still needs a human.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string] $DesiredStatePath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\desired-state\machine.json'),

        [string] $PayloadRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..'),

        [string] $JournalPath,

        [string] $BackupRoot
    )

    # Both defaults are built by walking up from $PSScriptRoot, which leaves a
    # literal '..\..\..' in the middle of every path derived from them. That is
    # invisible until a resource fails and the user is asked to act on a path with
    # three parent references buried in it. Collapse them once, here, rather than
    # in each message.
    $DesiredStatePath = Expand-TSPath -Path $DesiredStatePath
    $PayloadRoot = Expand-TSPath -Path $PayloadRoot

    # Deliberately not wrapped in a try. An unreadable desired-state document is a
    # reason to refuse to act, not a result to report: doctor may carry on with a
    # partial picture because it only reads, but apply writing a subset of a
    # document it could not fully parse is how a machine ends up in a state
    # nothing describes.
    $state = Get-TSDesiredState -Path $DesiredStatePath

    $localAppData = Get-TSSpecialFolder -Name 'LocalApplicationData'

    if (-not $JournalPath) {
        $JournalPath = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\journal.jsonl'
    }

    if (-not $BackupRoot) {
        $BackupRoot = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\backups'
    }

    # One id shared by every change in this run. Without it a journal is a pile of
    # edits; with it, the set of files touched together can be identified and
    # reversed together.
    $runId = [guid]::NewGuid().ToString()

    # Written before anything is touched, and deliberately not merged into the
    # closing record. A run that throws halfway through leaves no closing record at
    # all, and 'no evidence the run happened' is the least useful thing a log can
    # say about the run someone is investigating.
    Write-TSLog -Message "apply starting against $DesiredStatePath" -RunId $runId -Data @{
        command      = 'apply'
        phase        = 'start'
        whatIf       = [bool] $WhatIfPreference
        resources    = @($state.resources).Count
        desiredState = $DesiredStatePath
        journal      = $JournalPath
    }

    $results = [System.Collections.Generic.List[object]]::new()

    # WhatIf travels in the splat rather than being left to scope inheritance.
    # Sync-TSManagedFile lives in the same module, so it would in fact inherit
    # $WhatIfPreference from this scope - but the defect that made this file worth
    # revisiting was precisely a boundary where that assumption silently stopped
    # holding. Making it a parameter means there is no boundary left to reason
    # about: every call site that copies this splat gets the behaviour, and a call
    # site that forgets it is a visible omission rather than an invisible one.
    $shared = @{
        BackupRoot  = $BackupRoot
        JournalPath = $JournalPath
        RunId       = $runId
        WhatIf      = [bool] $WhatIfPreference
    }

    foreach ($resource in @($state.resources)) {
        $kind = [string] $resource.kind
        $names = @($resource.PSObject.Properties.Name)

        switch ($kind) {

            'terminal.fragment' {
                if ($names -notcontains 'source') {
                    $results.Add((New-TSResult -Name "Fragment: $($resource.name)" -Status 'Fail' -Expected 'a source file' -Actual 'resource declares no source' -Remediation 'Add a source property to this resource in desired state.'))
                    break
                }

                $source = Join-Path -Path $PayloadRoot -ChildPath $resource.source
                $destination = Get-TSTerminalFragmentPath -AppName $resource.appName -FragmentName $resource.name

                $results.Add((Sync-TSManagedFile -Name "Fragment: $($resource.name)" -Kind $kind -Source $source -Destination $destination @shared))

                # Asked here, not left to the next doctor run. A fragment can be
                # deployed perfectly and still change nothing on screen, and the
                # moment right after apply reports success is exactly when a user
                # would otherwise conclude the tool does not work.
                $results.Add((Get-TSFragmentEffect -FragmentSourcePath $source -Label "Fragment effect: $($resource.name)"))
            }

            'omp.theme' {
                if ($names -notcontains 'source' -or $names -notcontains 'destination') {
                    $results.Add((New-TSResult -Name "Prompt theme: $($resource.name)" -Status 'Fail' -Expected 'a source and a destination' -Actual 'resource is incomplete' -Remediation 'Add the missing property to this resource in desired state.'))
                    break
                }

                $source = Join-Path -Path $PayloadRoot -ChildPath $resource.source
                $destination = Expand-TSPath -Path $resource.destination
                $declared = if ($names -contains 'sha256') { [string] $resource.sha256 } else { '' }

                $results.Add((Sync-TSManagedFile -Name "Prompt theme: $($resource.name)" -Kind $kind -Source $source -Destination $destination -ExpectedSha256 $declared @shared))
            }

            'terminal.asset' {
                if ($names -notcontains 'source' -or $names -notcontains 'destination') {
                    $results.Add((New-TSResult -Name "Asset: $($resource.name)" -Status 'Fail' -Expected 'a source and a destination' -Actual 'resource is incomplete' -Remediation 'Add the missing property to this resource in desired state.'))
                    break
                }

                $source = Join-Path -Path $PayloadRoot -ChildPath $resource.source
                $destination = Expand-TSPath -Path $resource.destination
                $declared = if ($names -contains 'sha256') { [string] $resource.sha256 } else { '' }

                $results.Add((Sync-TSManagedFile -Name "Asset: $($resource.name)" -Kind $kind -Source $source -Destination $destination -ExpectedSha256 $declared @shared))
            }

            'shell.profile' {
                if ($names -notcontains 'source') {
                    $results.Add((New-TSResult -Name 'Shell profile' -Status 'Fail' -Expected 'a source file' -Actual 'resource declares no source' -Remediation 'Add a source property to this resource in desired state.'))
                    break
                }

                $target = if ($names -contains 'target') { [string] $resource.target } else { 'CurrentUserCurrentHost' }

                if ($target -ne 'CurrentUserCurrentHost') {
                    $results.Add((New-TSResult -Name 'Shell profile' -Status 'Skip' -Expected $target -Actual 'only CurrentUserCurrentHost is implemented' -Remediation 'This profile scope is not modelled. Nothing was written.'))
                    break
                }

                $source = Join-Path -Path $PayloadRoot -ChildPath $resource.source
                $destination = Get-TSProfilePath

                $results.Add((Sync-TSManagedFile -Name 'Shell profile' -Kind $kind -Source $source -Destination $destination @shared))
            }

            'winget.package' {
                if (Test-TSWingetPackage -Id $resource.id) {
                    $results.Add((New-TSResult -Name "Package: $($resource.id)" -Status 'Pass' -Expected 'installed' -Actual 'already installed; packages are not managed by apply'))
                }
                else {
                    $results.Add((New-TSResult -Name "Package: $($resource.id)" -Status 'Skip' -Expected 'installed' -Actual 'absent; apply does not install packages' -Remediation "winget install --id $($resource.id) --exact"))
                }
            }

            'font' {
                $font = Get-TSFontState -FamilyName $resource.family

                if ($font.State -eq 'Installed') {
                    $results.Add((New-TSResult -Name "Font: $($resource.family)" -Status 'Pass' -Expected 'installed' -Actual "$($font.Detail); fonts are not managed by apply"))
                }
                else {
                    $results.Add((New-TSResult -Name "Font: $($resource.family)" -Status 'Skip' -Expected 'installed' -Actual "$($font.Detail); apply does not install fonts" -Remediation "Install manually, scope $(Get-TSFontScope). apply will not download a font whose declared sha256 is blank."))
                }
            }

            'psmodule' {
                $module = Get-TSModuleInstalled -Name $resource.name

                if ($module.Installed) {
                    $results.Add((New-TSResult -Name "Module: $($resource.name)" -Status 'Pass' -Expected 'available' -Actual "$($module.Version); modules are not managed by apply"))
                }
                else {
                    $results.Add((New-TSResult -Name "Module: $($resource.name)" -Status 'Skip' -Expected 'available' -Actual 'absent; apply does not install modules' -Remediation "Install-PSResource -Name $($resource.name) -Scope CurrentUser"))
                }
            }

            'terminal.global' {
                # Its own branch, not the default one, because the two mean
                # different things and the report has to distinguish them. 'not
                # modelled' promises that support is coming; this is a decision.
                #
                # settings.json belongs to the user. Windows Terminal rewrites the
                # whole file whenever anything is changed in its settings UI, and a
                # second writer would eventually clobber an edit made by hand with
                # no way to say which edit was lost. Fragments exist so that a tool
                # never has to touch that file, and this project uses them.
                $results.Add((New-TSResult -Name 'Terminal global settings' -Status 'Skip' -Expected 'declared intent, applied by hand' -Actual 'apply does not write settings.json, by decision' -Remediation 'Set these in Windows Terminal Settings yourself. docs/adr/0006-apply-converges-files-only.md records why this one is refused rather than deferred.'))
            }

            default {
                $results.Add((New-TSResult -Name "Resource kind: $kind" -Status 'Skip' -Expected 'a kind apply can converge' -Actual 'not modelled' -Remediation 'Nothing was written for this resource. Do not read the rest of this report as complete coverage.'))
            }
        }
    }

    $changed = @($results | Where-Object { $_.Status -eq 'Pass' -and $_.Actual -notmatch '^already' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Fail' }).Count

    Write-TSLog -Message "apply run $runId touched $changed file(s) across $(@($state.resources).Count) resource(s)." -RunId $runId -Data @{
        command   = 'apply'
        phase     = 'end'
        whatIf    = [bool] $WhatIfPreference
        changed   = $changed
        failed    = $failed
        resources = @($state.resources).Count
        results   = $results.Count
        journal   = $JournalPath
    }

    $results
}
