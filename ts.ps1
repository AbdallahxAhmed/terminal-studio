#Requires -Version 7.4

<#
.SYNOPSIS
    Terminal Studio command line entry point.

.DESCRIPTION
    A thin argument parser over the module. It contains no logic worth testing,
    which is the intent: everything decidable lives in functions that can be
    called without a terminal.

    Exit codes follow the convention terraform established for detailed exit
    codes, because scripts and CI already know how to read it:

        0  success, nothing would change
        1  unexpected error
        2  doctor found failures, plan found changes, or apply, configure -Save
           or uninstall left work undone
        3  reserved: the command exists but is not implemented in this version

    That distinction is the point. A tool that exits 0 whether or not the machine
    matches its desired state cannot be used in a pipeline, and a tool that exits
    1 for both 'broken' and 'drifted' forces the caller to parse text.

    Nothing returns 3 any more. configure used to, because it could not save; the
    code is kept documented rather than recycled, so a script that tests for it
    keeps its original meaning instead of quietly acquiring a new one.

    apply returns 2 for anything left undone, including resources it deliberately
    delegates such as packages and fonts. The alternative - exiting 0 while the
    report immediately above lists four missing packages - would put the exit code
    and the output in direct contradiction, and the exit code is the half a script
    can actually read.

    uninstall returns 2 on the same principle, and its most common reason for
    doing so is a success rather than a failure: a file that changed after apply
    wrote it is left exactly as the user left it, which is work outstanding by
    design.

.PARAMETER Command
    doctor, plan, configure, apply, uninstall, or version.

.PARAMETER Json
    Emit result objects as JSON instead of a rendered report. This is the
    non-interactive contract: machine-readable output is a first-class path here,
    not a flag bolted onto a menu-driven program.

.PARAMETER Save
    For configure, write the edited values back into desired state. Without it,
    configure shows the choices and changes nothing. Each control is written by a
    verified single-value edit, so comments and formatting in the document
    survive; controls that cannot be saved that way are reported and skipped
    rather than approximated.

.PARAMETER All
    For plan, also list resources already in the desired state. For uninstall,
    reverse every run the journal remembers rather than only the most recent.

.PARAMETER RunId
    For uninstall, reverse one specific run. Run ids appear in the journal and in
    the structured log.

.PARAMETER Unicode
    For doctor, apply, and configure, use symbol markers. Only worth passing once
    fonts are verified.

.PARAMETER SkipStartupMeasurement
    Skip the shell startup benchmark, which is the slowest check.

.PARAMETER Surface
    For configure, which renderer to use. Tui draws a form in the terminal and
    works everywhere. Wpf opens a window and needs a desktop and an STA thread.
    Both render the same control definition; neither knows what a control means.

.PARAMETER ReadOnly
    For configure, draw the form and read no input. Useful unattended, and the
    reason CI can exercise the renderer without a console waiting on Read-Host.

.PARAMETER DesiredStatePath
    Override the desired-state document.

.EXAMPLE
    ./ts.ps1 doctor

.EXAMPLE
    ./ts.ps1 plan -Json

.EXAMPLE
    ./ts.ps1 apply -WhatIf

    Every change apply would make, with nothing written.

.EXAMPLE
    ./ts.ps1 apply

.EXAMPLE
    ./ts.ps1 uninstall -WhatIf

    Everything the last apply would give back, with nothing changed.

.EXAMPLE
    ./ts.ps1 uninstall -All

.EXAMPLE
    ./ts.ps1 configure -Save

.EXAMPLE
    pwsh -STA -File ./ts.ps1 configure -Surface Wpf

.EXAMPLE
    ./ts.ps1 doctor -SkipStartupMeasurement; if ($LASTEXITCODE -eq 2) { 'drift' }
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('gui', 'doctor', 'plan', 'configure', 'apply', 'uninstall', 'version')]
    [string] $Command = 'gui',

    [switch] $Json,

    [switch] $Save,

    [switch] $All,

    [string] $RunId,

    [switch] $Unicode,

    [switch] $SkipStartupMeasurement,

    [ValidateSet('Tui', 'Wpf')]
    [string] $Surface = 'Tui',

    [switch] $ReadOnly,

    [string] $DesiredStatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'src\TerminalStudio\TerminalStudio.psd1'
Import-Module -Name $modulePath -Force

# Renderers are dot-sourced here rather than exported from the module. The
# module's public surface is data only, and presentation is this script's problem.
# That is what makes '-Json' and a rendered report equal-status clients of the same
# function, instead of one being grafted onto the other after the fact.
#
# Note the consequence, which cost this project a wrongly-headed report: because
# these are dot-sourced they run in this scope and see this scope's preference
# variables, while the module functions above do not. The two halves of an apply
# run therefore do not agree about -WhatIf unless it is passed explicitly.
$uiDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'src\TerminalStudio\UI'
foreach ($file in Get-ChildItem -Path $uiDirectory -Filter '*.ps1' -File) {
    . $file.FullName
}

$common = @{}
if ($DesiredStatePath) {
    $common['DesiredStatePath'] = $DesiredStatePath
}

# Both are resolved with the identical call the filesystem adapter makes, so the
# paths printed in a footer cannot drift away from where the files actually went.
# Re-deriving them from $env:LOCALAPPDATA would be the same answer almost always,
# and 'almost always' is not a property worth having in the line that tells
# someone where their backups are.
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$journalPath = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\journal.jsonl'
$backupRoot = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\backups'

switch ($Command) {
    'gui' {
        if (-not $IsWindows) {
            Write-Host 'The GUI dashboard requires Windows. Use "doctor" or "configure" in the terminal instead.'
            exit 1
        }

        $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
        if ($apartment -ne [System.Threading.ApartmentState]::STA) {
            $pwsh = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            $pwshPath = if ($pwsh) { $pwsh.Path } else { 'pwsh.exe' }
            & $pwshPath -STA -NoLogo -NoProfile -File $PSCommandPath gui
            exit $LASTEXITCODE
        }

        Show-TSMainWindow @common
        exit 0
    }

    'version' {
        $module = Get-Module -Name 'TerminalStudio'
        Write-Output ("TerminalStudio {0}" -f $module.Version)
        exit 0
    }

    'doctor' {
        $results = @(Invoke-TSDoctor @common -SkipStartupMeasurement:$SkipStartupMeasurement)

        if ($Json) {
            # ConvertTo-Json does accept -Depth on every supported engine. Its
            # counterpart ConvertFrom-Json does not, on 5.1 - which is the exact
            # asymmetry that took the predecessor's theme editor down.
            $results | ConvertTo-Json -Depth 4
        }
        else {
            Show-TSDoctorReport -Result $results -Unicode:$Unicode
        }

        if (@($results | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) {
            exit 2
        }

        exit 0
    }

    'plan' {
        $plan = @(Get-TSPlan @common)

        if ($Json) {
            $plan | ConvertTo-Json -Depth 4
        }
        else {
            Show-TSPlan -Plan $plan -All:$All
        }

        if (@($plan | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) {
            exit 2
        }

        exit 0
    }

    'configure' {
        $controls = @(Get-TSControl @common)

        if ($Json) {
            # The model, not a rendering of it. Anything that can read JSON is a
            # client of the configurator on equal terms with the two surfaces.
            $controls | ConvertTo-Json -Depth 5
            exit 0
        }

        if ($Surface -eq 'Wpf') {
            $edited = @($controls | Show-TSControlWindow)
        }
        else {
            $edited = @($controls | Show-TSControlForm -Interactive:(-not $ReadOnly) -Unicode:$Unicode)
        }

        if ($edited.Count -eq 0) {
            exit 0
        }

        if (-not $Save) {
            # Printed, so a decision the user just made is not thrown away, and
            # not written, because -Save is the difference between showing a choice
            # and editing a file that is under version control. This used to exit 3
            # for lack of a writer; there is one now, and it is opt-in.
            $edited | ConvertTo-Json -Depth 5

            Write-Warning 'Nothing was saved. Run the same command with -Save to write these choices into desired state.'
            exit 0
        }

        # One correlation id for the whole batch, so uninstall can reverse a
        # configure session as a unit rather than one control at a time.
        $saveRunId = [guid]::NewGuid().ToString()
        $saved = [System.Collections.Generic.List[object]]::new()

        foreach ($control in $edited) {
            $names = @($control.PSObject.Properties.Name)

            # Defensive under StrictMode: a surface that returns something other
            # than the control model should not take the whole command down.
            if ($names -notcontains 'Id' -or $names -notcontains 'Value') {
                continue
            }

            $saved.Add((Set-TSControl @common -Id $control.Id -Value $control.Value -RunId $saveRunId -WhatIf:$WhatIfPreference))
        }

        $results = @($saved)

        Show-TSSaveReport -Result $results -JournalPath $journalPath -BackupRoot $backupRoot -Unicode:$Unicode -WhatIf:$WhatIfPreference

        if (@($results | Where-Object { $_.Status -in @('Fail', 'Skip') }).Count -gt 0) {
            exit 2
        }

        exit 0
    }

    'apply' {
        # -WhatIf is passed explicitly, and it has to be.
        #
        # An earlier version of this line did not pass it, on the stated reasoning
        # that SupportsShouldProcess on this script had already set
        # $WhatIfPreference for the whole call stack. That reasoning is wrong.
        # Preference variables resolve through the scope chain, and a function
        # exported from a module has its chain rooted in the module's own session
        # state rather than in its caller's. $WhatIfPreference set here is simply
        # not visible inside Invoke-TSApply.
        #
        # The renderer below is dot-sourced into this scope, so it did see the
        # preference. The observable result was a report headed 'dry run, nothing
        # written' printed directly above a list of files that had just been
        # written, including a replaced shell profile. A dry run that writes is the
        # worst defect this project can ship, because every other safety property
        # here is something the user is invited to verify with -WhatIf first.
        #
        # The general rule, which applies to $ErrorActionPreference and
        # $VerbosePreference identically: never infer a preference across a module
        # boundary. Pass it.
        $results = @(Invoke-TSApply @common -WhatIf:$WhatIfPreference)

        if ($Json) {
            $results | ConvertTo-Json -Depth 4
        }
        else {
            Show-TSApplyReport -Result $results -JournalPath $journalPath -BackupRoot $backupRoot -Unicode:$Unicode -WhatIf:$WhatIfPreference
        }

        $outstanding = @($results | Where-Object { $_.Status -in @('Fail', 'Skip') }).Count

        if ($outstanding -gt 0) {
            exit 2
        }

        exit 0
    }

    'uninstall' {
        # Deliberately no @common. uninstall reverses what apply recorded doing,
        # and a desired-state document that has changed since - or gone missing -
        # must not be able to influence that. The journal is the input.
        $undo = @{ WhatIf = [bool] $WhatIfPreference }

        if ($RunId) {
            $undo['RunId'] = $RunId
        }
        elseif ($All) {
            $undo['All'] = $true
        }

        $results = @(Invoke-TSUninstall @undo)

        if ($Json) {
            $results | ConvertTo-Json -Depth 4
        }
        else {
            Show-TSUninstallReport -Result $results -JournalPath $journalPath -BackupRoot $backupRoot -Unicode:$Unicode -WhatIf:$WhatIfPreference
        }

        $outstanding = @($results | Where-Object { $_.Status -in @('Fail', 'Skip') }).Count

        if ($outstanding -gt 0) {
            exit 2
        }

        exit 0
    }
}
