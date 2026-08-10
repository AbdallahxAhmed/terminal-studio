@{
    # Run every default rule, then make deliberate, documented exceptions.
    IncludeDefaultRules = $true

    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Write-Host is legitimate in this codebase, but ONLY inside src/TerminalStudio/UI.
        # A blanket analyzer rule cannot express "only in that folder", so the real constraint
        # is enforced mechanically by tests/unit/Architecture.Tests.ps1, which fails if
        # Write-Host appears anywhere outside UI/. That is a stronger guarantee than this rule.
        'PSAvoidUsingWriteHost'
    )

    Rules = @{
        # Non-approved verbs were a real defect class in the predecessor project
        # (Do-*, Filter-*, Apply-*, Refresh-*). Keep this loud.
        PSUseApprovedVerbs = @{
            Enable = $true
        }

        # A declared-but-never-read parameter is not cosmetic. The predecessor shipped a
        # -DryRun switch on four functions that did nothing, so the flag silently lied.
        PSReviewUnusedParameter = @{
            Enable = $true
        }

        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace = @{
            Enable          = $true
            CheckInnerBrace = $true
            CheckOpenBrace  = $true
            CheckOpenParen  = $true
            CheckOperator   = $true
            CheckSeparator  = $true
        }

        PSAlignAssignmentStatement = @{
            Enable = $false
        }
    }
}
