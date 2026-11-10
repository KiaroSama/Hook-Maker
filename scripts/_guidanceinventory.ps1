# Fixed output-construction inventory reviewed against 0ab5b09. Character counts,
# not tokens. Charge short fragments, command arguments and new guidance in full.
function Get-HookGuidanceInventory {
    param([Parameter(Mandatory = $true)][string]$HooksRoot)
    $members = @('$lines.Add','$notes.Add','$dd.Add','$reasonLines.Add','$findings.Add','$incomplete.Add','$configWarnings.Add','$unknownNotes.Add','$reportLines.Add','$partial.Add','$causes.Add','$parts.Add','$critical.Add','$coverageErrors.Add','$Result.Partial.Add','$ddLines.Add','$closeLines.Add','$blockLines.Add','$Partial.Add','$advisoryExtra.Add','$all.Add','$errors.Add','$blockingExtra.Add','$entryLines.Add','$conflictLines.Add','$script:ConfigIssues.Add','$script:configWarnings.Add','$messages.Add','[Console]::Error.WriteLine','[Console]::Out.WriteLine')
    $commands = @('Write-Finding','Write-Block','Write-Error','Write-Host','Write-Advisory','Write-HookResult','Write-StopBlockResult','Write-ContextIfNew','Register-PendingNote')
    $variables = @('$note','$message','$reason','$chainNote','$incompleteHints','$operationalInstruction','$lead','$script:BadgeGuidance','$parts','$ddNote','$scopeNote','$findings','$script:SkillRoutingLines','$script:ResearchReminder','$script:SpecKitRouting','$haveGraphNote','$lifecycleNote','$advice','$manualAdvice','$utf8Note','$degradedParts','$markdownNote','$noteLines','$shNote','$blockMessage','$script:SkillsRequirement','$blockingExtra','$timingRegressionLines','$deferMessage','$markdownSetupLine','$bullet1','$script:ImportGuidance','$script:ReplyLanguageLine','$notice','$errMsg','$coverageNote','$answer.Problems','$script:BlindWaitSafeSleep','$refreshLine','$header','$filesClause','$lines','$ponytailRef','$workerNote','$script:RulesRequirement','$requirement','$headline','$script:SkillsRequiredLine','$agentRoots','$script:DependencyDecisionLine','$reasonWhy','$adviceLine','$script:RulesRequiredLine','$researchRoute','$what','$researchNote','$partialNote','$requiredLine','$visibleMsg','$findingPrefix','$limitReason','$workflowProblems','$ddReason','$script:pendingNotes[$key]','$script:retiredNotes[$key]','$contracts.Partial','$stateNote','$destinationWording','$issues','$billingReason','$script:CiWorkloadReason','$script:DocsCarryoverReason','$reject','$detail')
    $returns = @('Resolve-FailedRunVerdict','Get-ResearchWorkflowReminder','Get-VisibleInvocationFinding','Get-GuardedBindingFinding','Get-SkillClosingDecision','New-ReviewMessage','Get-AgentInstructionLines','Get-StopFinalizationClause','Get-GitWorkflowReminder','Test-CiClearedFailure','Get-ReviewReason','Get-RunnerStopReplacement','Get-OpenPullRequestLine','Get-BlindWaitFinding','Get-RunnerLeftRunningText','Get-UnknownNoteDiagnostic','Get-MatchReason','Get-RunnerStopFinding','Get-IncidentReasonFromDoc','Get-ActiveMarkerState','Get-LanguageChoiceReminder','Get-ClassLabel','Get-AcknowledgementCommand','Get-OperationMcpReminder','Get-LiveProjectRunner','Invoke-GenerationCollection','Get-CheckSummary')
    # Parsers, fingerprints, state serialization and executable argv are not prose.
    # These exclusions are source-reviewed identities, never length/text heuristics.
    $excluded = @(
        '_hooklib.ps1|ConvertFrom-CbmTomlServer', '_hooklib.ps1|Get-CbmCliAdvice',
        '_scope.ps1|Get-WorkflowTopTriggers', '_scope.ps1|Test-WorkflowSelfHosted',
        '_stoplib.ps1|Get-LastAssistantTextFromJsonl',
        'Ci-Status-Check/_ciclosure.ps1|Get-CiClosureInventory',
        'Ci-Status-Check/_ciliteral.ps1|Read-CiLiteralSteps',
        'Ci-Status-Check/_ciworkload.ps1|Get-CiRunSnapshot',
        'Ci-Status-Check/_docsquery.ps1|Invoke-DocsGitQuery|assign:$lines',
        'Ci-Status-Check/_docssnippets.ps1|Get-DocsProtectedProjection',
        'Ci-Status-Check/_pathsfilter.ps1|Get-WorkflowPushFilter',
        'Dependency-Version-Check/Dependency-Version-Check.ps1|Save-CachedState',
        'Docs-Freshness-Check/Docs-Freshness-Check.ps1|Get-ChangedEntries',
        'Docs-Freshness-Check/Docs-Freshness-Check.ps1|Get-ImpactFingerprint',
        'Git-Sync-Check/Git-Sync-Check.ps1|Get-LocalBranchList',
        'Github-Baseline-Check/Github-Baseline-Check.ps1|Test-HasValidationCommand',
        'Github-Baseline-Check/Github-Baseline-Check.ps1|Test-HasWorkflowTrigger',
        'Secrets-Check/_patternfile.ps1|Invoke-GitGrepWithValue',
        'Secrets-Check/Secrets-Check.ps1|Get-OutgoingCommits|assign:$parts',
        'Skills-Check/_skilldiscovery.ps1|Get-SkillSourceStamp',
        'Skills-Check/_skillindex.ps1|Build-SkillIndex',
        'Skills-Check/_skillstop.ps1|Save-SkillSessionRecord',
        'Test-Plan-Check/Test-Plan-Check.ps1|Get-PowerShellRiskLines',
        'Test-Run-Guard/_commandanalysis.ps1|New-GuardedInvocation',
        'Test-Run-Guard/_datablocks.ps1|Get-ReceivingSegmentTokens'
    )
    $groups = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $HooksRoot -File -Filter '*.ps1' -Recurse | Where-Object { $_.FullName -notmatch '[/\\]ZZZ-[^/\\]+[/\\]' })) {
        $relative = $file.FullName.Substring($HooksRoot.TrimEnd('\','/').Length + 1).Replace('\','/')
        $text = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if (@($errors).Count) { throw ('Guidance parse failure: ' + $relative) }
        foreach ($node in $ast.FindAll({param($n)
            $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)) {
            if ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -eq 'BareWord') { continue }
            $chain = New-Object 'Collections.Generic.List[string]'
            $ancestor = $node.Parent; $sink = ''; $function = ''
            while ($null -ne $ancestor) {
                if ($ancestor -is [Management.Automation.Language.FunctionDefinitionAst]) { $function = $ancestor.Name; break }
                if ($ancestor -is [Management.Automation.Language.ThrowStatementAst] -and $sink -eq '') { $sink = 'throw' }
                if ($ancestor -is [Management.Automation.Language.ReturnStatementAst] -and $sink -eq '') { $sink = 'return' }
                if ($ancestor -is [Management.Automation.Language.CommandAst]) { [void]$chain.Add('command:' + $ancestor.GetCommandName()) }
                elseif ($ancestor -is [Management.Automation.Language.InvokeMemberExpressionAst]) { [void]$chain.Add('member:' + $ancestor.Expression.Extent.Text + '.' + $ancestor.Member.Extent.Text) }
                elseif ($ancestor -is [Management.Automation.Language.AssignmentStatementAst]) { [void]$chain.Add('assign:' + $ancestor.Left.Extent.Text) }
                $ancestor = $ancestor.Parent
            }
            if ($sink -eq 'throw') { continue }
            $include = $sink -eq 'return' -and $function -in $returns
            if ($chain.Count -eq 1) {
                if ($chain[0].StartsWith('member:') -and $chain[0].Substring(7) -in $members) { $include = $true }
                if ($chain[0].StartsWith('assign:') -and $chain[0].Substring(7) -in $variables) { $include = $true }
            }
            foreach ($part in $chain) {
                if ($part.StartsWith('command:') -and $part.Substring(8) -in $commands) { $include = $true; break }
            }
            if (-not $include) { continue }
            $scope = $relative + '|' + $function
            $construction = $chain -join '|'
            if ($scope -in $excluded -or ($scope + '|' + $construction) -in $excluded) { continue }
            $key = $scope + '|' + $sink + '|' + $construction
            if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ Path = $relative; Function = $function; Sink = $sink; Chain = $construction; Characters = 0; Values = @() } }
            $groups[$key].Characters += $node.Value.Length
            $groups[$key].Values += ,$node.Value
        }
    }
    return @($groups.Keys | Sort-Object | ForEach-Object { $groups[$_] })
}
