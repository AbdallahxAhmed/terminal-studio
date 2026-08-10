function Test-TSPath {
    <#
    .SYNOPSIS
        Reports whether a path exists.

    .DESCRIPTION
        Trivial by design. The value is not the logic, it is the seam: because
        every existence check in the codebase funnels through one function, a unit
        test can simulate any filesystem shape with a single mock.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Test-Path -LiteralPath $Path
}

function Get-TSFileText {
    <#
    .SYNOPSIS
        Reads a whole file as a single string.

    .DESCRIPTION
        -Raw is deliberate: callers parse JSON, and feeding a line array to a JSON
        parser works by accident rather than by contract.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Get-Content -LiteralPath $Path -Raw -Encoding utf8
}

function Get-TSSpecialFolder {
    <#
    .SYNOPSIS
        Resolves a Windows special folder to its real current path.

    .DESCRIPTION
        Never build these paths by joining onto the user profile directory.
        OneDrive Known Folder Move relocates Documents, and PowerShell follows it,
        so a hand-built path points somewhere the shell is not actually looking.
        That mismatch is exactly how a profile script gets deployed to a location
        that never loads.

        Asking Windows where the folder is means doctor can compare the answer
        against the naive location and report the redirection instead of tripping
        over it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LocalApplicationData', 'ApplicationData', 'MyDocuments', 'UserProfile')]
        [string] $Name
    )

    [Environment]::GetFolderPath($Name)
}
