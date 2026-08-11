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

        SAFETY PROPERTIES

          - Nothing is written when the source and destination already match, so
            running apply repeatedly is indistinguishable from running it once.
          - Every replaced file is copied to a backup directory first, and the
            backup path appears in both the report and the journal.
          - Every change appends one JSON line to an append-only journal, which is
            what will make uninstall a replay rather than a second guess.
          - -WhatIf reports every intended change without making any of them.

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

    $results = [System.Collections.Generic.List[object]]::new()

    $shared = @{
        BackupRoot  = $BackupRoot
        JournalPath = $JournalPath
        RunId       = $runId
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

                $results.Add((Sync-TSManagedFile -Name "Prompt theme: $($resource.name)" -Kind $kind -Source $source -Destination $destination @shared))
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

            default {
                $results.Add((New-TSResult -Name "Resource kind: $kind" -Status 'Skip' -Expected 'a kind apply can converge' -Actual 'not modelled' -Remediation 'Nothing was written for this resource. Do not read the rest of this report as complete coverage.'))
            }
        }
    }

    $changed = @($results | Where-Object { $_.Status -eq 'Pass' -and $_.Actual -notmatch '^already' }).Count
    Write-TSLog -Message "apply run $runId touched $changed file(s) across $(@($state.resources).Count) resource(s)."

    $results
}
