#Requires -Version 5.1

<#
.SYNOPSIS
    Test entry point. Chooses which suites can run on the current engine.

.DESCRIPTION
    This file is deliberately written to 5.1 rules, because CI invokes it under
    both powershell.exe and pwsh.exe. That matrix is the entire point: the module
    requires PowerShell 7.4, but the bootstrap must survive a machine where only
    Windows PowerShell exists. Testing exclusively on 7.x is how the predecessor
    shipped a 5.1-only crash.

    Suite selection:

      tests/compat  runs on every engine. It asserts that stage 0 parses and stays
                    inside the 5.1 language. Running it under powershell.exe is
                    what makes it a real proof rather than a regex opinion.

      tests/unit    runs only on Core, because it imports a module declaring
                    #Requires -Version 7.4. Attempting it under Desktop would fail
                    for the wrong reason and teach the team to ignore red builds.

    Framework selection:

      The Pester requirement is a range - 5.5.0 or later, below 6.0.0 - and not a
      floor. A floor is what let a machine install the newest Pester and run this
      suite against a major version these tests were never written for. That does
      not present as an incompatibility error. It presents as most of the suite
      failing in ways indistinguishable from product defects, because the
      framework stopped sharing state between its discovery and run phases in the
      way the tests assume. A harness that may silently change under the tests
      cannot answer the only question a red build is for.

      The version that satisfies the range is then imported with -RequiredVersion,
      so the version that was checked is the version that runs.

.PARAMETER OutputPath
    NUnit results file for CI to upload.

.PARAMETER Verbosity
    Pester output verbosity.

.EXAMPLE
    ./tests/Invoke-Tests.ps1
#>

[CmdletBinding()]
param(
    [string] $OutputPath = 'testresults.xml',

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Verbosity = 'Detailed'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$minimumPester = [version] '5.5.0'
$exclusivePesterCeiling = [version] '6.0.0'

$available = Get-Module -ListAvailable -Name 'Pester' |
    Where-Object { $_.Version -ge $minimumPester -and $_.Version -lt $exclusivePesterCeiling } |
    Sort-Object -Property Version -Descending |
    Select-Object -First 1

if (-not $available) {
    $installed = @(Get-Module -ListAvailable -Name 'Pester' | ForEach-Object { $_.Version.ToString() })
    $found = if ($installed.Count -gt 0) { $installed -join ', ' } else { 'none' }

    throw "Pester $minimumPester or later, below $exclusivePesterCeiling, is required. Installed: $found. Install-Module -Name Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -SkipPublisherCheck -Force"
}

Import-Module -Name 'Pester' -RequiredVersion $available.Version -Force

# Printed, not implied. The first thing a failure report needs is what produced
# it, and a report that omits the framework version cannot be triaged from it.
Write-Host "Pester $($available.Version) on PowerShell $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"

$suites = @(Join-Path -Path $PSScriptRoot -ChildPath 'compat')

if ($PSVersionTable.PSEdition -eq 'Core') {
    $suites += (Join-Path -Path $PSScriptRoot -ChildPath 'unit')
}
else {
    Write-Host "Engine is $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion). Running compatibility suites only."
    Write-Host 'The unit suite imports a module that requires PowerShell 7.4, so it is skipped by design rather than by accident.'
}

$paths = @($suites | Where-Object { Test-Path -LiteralPath $_ })

if ($paths.Count -eq 0) {
    throw "No test directories were found under $PSScriptRoot."
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = $paths
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = $Verbosity
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = $OutputPath

Invoke-Pester -Configuration $configuration
