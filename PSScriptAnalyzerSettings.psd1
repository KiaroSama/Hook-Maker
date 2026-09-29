@{
    # Zero tolerance: every finding that survives the exclusions fails CI.
    # Measured baseline on 2026-09-29 (main @ 53c9c71): 2,127 warnings, 0 errors,
    # 2,116 of them in the ten excluded rules below. Each exclusion is a
    # deliberate project convention, not a suppression of convenience.
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        'PSAvoidUsingWriteHost'                        # console tool: the wizard and every suite talk to a host (1,212)
        'PSAvoidUsingEmptyCatchBlock'                  # hooks fail open by design; each catch is reviewed in place (360)
        'PSUseShouldProcessForStateChangingFunctions'  # private helpers, never exported cmdlets (244)
        'PSUseSingularNouns'                           # names follow the domain (Get-InstallFindings, ...) (139)
        'PSReviewUnusedParameter'                      # dot-sourced modules bind parameters in the caller's scope (75)
        'PSUseDeclaredVarsMoreThanAssignments'         # 12 of 13 proven false positives (dot-sourcing) on 2026-09-09 (48)
        'PSAvoidAssignmentToAutomaticVariable'         # -Profile is a public installer parameter; $event locals are harmless (18)
        'PSUseApprovedVerbs'                           # private helpers (Normalize-Path, Ensure-Property) (15)
        'PSAvoidOverwritingBuiltInCmdlets'             # Write-Log is not a cmdlet (analyser profile noise); Get-Process is a deliberate test mock (7)
        'PSUseSupportsShouldProcess'                   # test helpers mimic -WhatIf/-Confirm for the code under test (2)
    )
}
