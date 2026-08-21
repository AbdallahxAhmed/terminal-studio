function New-TSResult {
    <#
    .SYNOPSIS
        Creates the one result shape used by every doctor check and every plan item.

    .DESCRIPTION
        A single shape is the point. Because every check returns the same object,
        renderers, JSON output, and exit-code logic are each written once instead
        of once per feature.

        Remediation is a first-class field rather than an afterthought. A check
        that reports a failure without saying what to do about it has moved the
        problem from the machine to the user's memory.

    .PARAMETER Name
        Human-readable name of the check or resource.

    .PARAMETER Status
        Pass, Fail, Warn, or Skip. Skip means "not applicable on this machine",
        which is different from a pass and must not be reported as one.

    .PARAMETER Expected
        What the desired state requires.

    .PARAMETER Actual
        What was observed.

    .PARAMETER Remediation
        The concrete next action when Status is Fail or Warn.

    .OUTPUTS
        TerminalStudio.Result
    #>
    # New- is on the analyzer's list of verbs that change system state, and the
    # rule that comes with it asks for a -WhatIf gate. This function allocates an
    # object and touches nothing, so a gate here would misdescribe it - and it
    # would be self-defeating, because the code paths that implement -WhatIf call
    # this function to report the change they did not make. Suppressed at the one
    # function rather than added to ExcludeRules, where it would stop protecting
    # the functions that do write.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs a result object in memory; there is no state to gate.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Fail', 'Warn', 'Skip')]
        [string] $Status,

        [string] $Expected = '',

        [string] $Actual = '',

        [string] $Remediation = ''
    )

    [pscustomobject] @{
        PSTypeName  = 'TerminalStudio.Result'
        Name        = $Name
        Status      = $Status
        Expected    = $Expected
        Actual      = $Actual
        Remediation = $Remediation
    }
}
