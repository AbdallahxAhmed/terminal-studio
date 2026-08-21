@{
    RootModule        = 'TerminalStudio.psm1'
    ModuleVersion     = '0.3.0'
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
    # Invoke-TSApply was withheld until 0.2.0, and the conditions for adding it
    # were specific rather than a matter of confidence: a backup path, an
    # append-only journal, hash-based idempotence, and -WhatIf. A Set operation
    # with none of those is a command that can change a machine and cannot say
    # what it changed, which is the defect that motivated this project.
    #
    # Invoke-TSUninstall arrives in 0.3.0 and completes that argument. Until it
    # existed the journal was a record nobody read, and 'reversible' was a claim
    # about a file format rather than about a command a user could run. It is
    # deliberately a replay of that journal rather than a second list of the files
    # apply writes, because two lists of the same thing drift.
    #
    # Set-TSControl arrives with it and is what lets configure stop exiting 3. It
    # writes desired state, not the machine, and it refuses any edit it cannot
    # prove touched exactly one value.
    #
    # apply still does not install packages, fonts, or modules. That boundary is
    # documented in the function itself and reported in its output, rather than
    # left for a user to discover.
    FunctionsToExport = @(
        'Get-TSControl'
        'Get-TSPlan'
        'Invoke-TSApply'
        'Invoke-TSDoctor'
        'Invoke-TSUninstall'
        'Set-TSControl'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Windows', 'Terminal', 'WindowsTerminal', 'DesiredState', 'Configuration')
            LicenseUri   = 'https://github.com/AbdallahxAhmed/terminal-studio/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/AbdallahxAhmed/terminal-studio'
            ReleaseNotes = 'Adds uninstall, which reverses an apply by replaying the change journal backwards and refuses to touch any file that changed since apply wrote it. Adds configure -Save, which edits one value in desired state and proves the edit was local. Adds an opt-in JSONL log with a per-run correlation id. apply still does not install packages, fonts, or modules.'
        }
    }
}
