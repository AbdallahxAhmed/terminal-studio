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
        2  doctor found failures, plan found changes, or apply left work undone
        3  the command exists but is not implemented in this version

    That distinction is the point. A tool that exits 0 whether or not the machine
    matches its desired state cannot be used in a pipeline, and a tool that exits
    1 for both 'broken' and 'drifted' forces the caller to parse text.

    apply returns 2 for anything left undone, including resources it deliberately
    delegates such as packages and fonts. The alternative - exiting 0 while the
    report immediately above lists four missing packages - would put the exit code
    and the output in direct contradiction, and the exit code is the half a script
    can actually read.

.PARAMETER Command
    doctor, plan, configure, apply, or version.

.PARAMETER Json
    Emit result objects as JSON instead of a rendered report. This is the
    non-interactive contract: machine-readable output is a first-class path here,
    not a flag bolted onto a menu-driven program.

.PARAMETER All
    For plan, also list resources already in the desired state.

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
    pwsh -STA -File ./ts.ps1 configure -Surface Wpf

.EXAMPLE
    ./ts.ps1 doctor -SkipStartupMeasurement; if ($LASTEXITCODE -eq 2) { 'drift' }
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor', 'plan', 'configure', 'apply', 'version')]
    [string] $Command = 'doctor',

    [switch] $Json,

    [switch] $All,

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
$uiDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'src\TerminalStudio\UI'
foreach ($file in Get-ChildItem -Path $uiDirectory -Filter '*.ps1' -File) {
    . $file.FullName
}

$common = @{}
if ($DesiredStatePath) {
    $common['DesiredStatePath'] = $DesiredStatePath
}

switch ($Command) {
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

        # Printed, so a decision the user just made is not thrown away, then
        # exited 3, because it has not been stored. Persisting desired state needs
        # a writer for the desired-state document itself, which is a different
        # thing from the file writer apply uses: it means round-tripping JSON the
        # user hand-edits, and losing their comments and ordering is not an
        # acceptable cost. Exiting 0 here would tell every caller it was saved.
        $edited | ConvertTo-Json -Depth 5

        Write-Warning 'Saving desired state is not implemented. The choices above were printed, not stored.'
        Write-Warning 'Run: ./ts.ps1 configure -Json > controls.json   to keep the model for later.'
        exit 3
    }

    'apply' {
        # Resolved with the identical call the filesystem adapter makes, so the
        # paths printed in the footer cannot drift away from where the files
        # actually went. Re-deriving them from $env:LOCALAPPDATA would be the same
        # answer almost always, and 'almost always' is not a property worth having
        # in the line that tells someone where their backups are.
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
        $journalPath = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\journal.jsonl'
        $backupRoot = Join-Path -Path $localAppData -ChildPath 'TerminalStudio\backups'

        # No -WhatIf argument is passed. SupportsShouldProcess on this script means
        # PowerShell has already set $WhatIfPreference for the whole call stack, and
        # the check happens at the write itself rather than being re-decided by each
        # layer on the way down.
        $results = @(Invoke-TSApply @common)

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
}
