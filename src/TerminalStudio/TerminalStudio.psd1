@{
    RootModule        = 'TerminalStudio.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f3b1c2d4-5e6a-4b8c-9d0e-1a2b3c4d5e6f'
    Author            = 'Abdallah Ahmed'
    Copyright         = '(c) 2026 Abdallah Ahmed. MIT licensed.'
    Description       = 'Desired-state engine for a reproducible, versioned, reversible Windows terminal environment.'

    # A hard floor, not an aspiration. Stage 0 (bootstrap/get.ps1) targets
    # Windows PowerShell 5.1 and is responsible for making 7.4 exist before this
    # module is ever imported. See docs/architecture.md.
    PowerShellVersion = '7.4'

    # Explicit exports only. A folder of dot-sourced scripts leaks every helper it
    # defines; a manifest makes the public surface a deliberate decision.
    #
    # Invoke-TSApply is deliberately absent. apply is not implemented, and
    # exporting a stub that looks implemented is worse than exporting nothing.
    FunctionsToExport = @(
        'Invoke-TSDoctor'
        'Get-TSPlan'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Windows', 'Terminal', 'WindowsTerminal', 'DesiredState', 'Configuration')
            LicenseUri   = 'https://github.com/AbdallahxAhmed/terminal-studio/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/AbdallahxAhmed/terminal-studio'
            ReleaseNotes = 'Pre-alpha. Read-only commands only: doctor and plan. No apply yet.'
        }
    }
}
