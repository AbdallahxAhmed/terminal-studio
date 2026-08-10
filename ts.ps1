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
        2  doctor found failures, or plan found changes
        3  the command exists but is not implemented in this version

    That distinction is the point. A tool that exits 0 whether or not the machine
    matches its desired state cannot be used in a pipeline, and a tool that exits
    1 for both 'broken' and 'drifted' forces the caller to parse text.

.PARAMETER Command
    doctor, plan, configure, apply, or version.

.PARAMETER Json
    Emit result objects as JSON instead of a rendered report. This is the
    non-interactive contract: machine-readable output is a first-class path here,
    not a flag bolted onto a menu-driven program.

.PARAMETER All
    For plan, also list resources already in the desired state.

.PARAMETER Unicode
    For doctor and configure, use symbol markers. Only worth passing once fonts
    are verified.

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
    ./ts.ps1 configure

.EXAMPLE
    pwsh -STA -File ./ts.ps1 configure -Surface Wpf

.EXAMPLE
    ./ts.ps1 doctor -SkipStartupMeasurement; if ($LASTEXITCODE -eq 2) { 'drift' }
#>

[CmdletBinding()]
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
        # exited 3, because it has not been stored. Persisting desired state
        # needs a writer and a change journal, and neither exists in 0.1.0.
        # Exiting 0 here would tell every caller the settings were saved.
        $edited | ConvertTo-Json -Depth 5

        Write-Warning 'Saving desired state is not implemented in 0.1.0. The choices above were printed, not stored.'
        Write-Warning 'Run: ./ts.ps1 configure -Json > controls.json   to keep the model for later.'
        exit 3
    }

    'apply' {
        # Deliberately not stubbed. An empty apply that exits 0 would be worse than
        # no apply at all: every caller, including a future test, would read success
        # and conclude the machine had converged. Failing loudly with its own exit
        # code is the honest behaviour until the change journal exists, because
        # writing changes without recording them is how the predecessor ended up
        # unable to uninstall what it installed.
        Write-Warning 'apply is not implemented in 0.1.0.'
        Write-Warning 'Run: ./ts.ps1 plan   to see what needs doing, with a command for each item.'
        exit 3
    }
}
