from pathlib import Path
import re

def get(p): return Path(p).read_text(encoding='utf-8-sig')
def put(p, s): Path(p).write_text(s, encoding='utf-8', newline='\r\n')
def sub(p, a, b):
    s = get(p)
    assert a in s, (p, a[:80])
    put(p, s.replace(a, b))

sub('hooks/_taskidentity.ps1', "    if ($event -notin @('UserPromptSubmit', 'Stop')) { return }", """    if ($event -notin @('UserPromptSubmit', 'Stop')) { return }
    if ($event -eq 'Stop') {
        $scope = Get-TaskScope $HookInput
        if ($null -eq $scope -or -not [IO.File]::Exists($scope.Path)) { return }
    }""")
sub('hooks/_hooklib.ps1', "        [AllowEmptyString()][string]$Message = ''\n    )\n    # The TEXT", "        [AllowEmptyString()][string]$Message = '',\n        [AllowEmptyString()][string]$FindingFingerprint = ''\n    )\n    # The TEXT")
sub('hooks/_hooklib.ps1', "    $finding = ''\n    if (-not [string]::IsNullOrWhiteSpace($text)) { $finding = Get-ShortHash ($HookName + '|' + $text) }", """    # Prefer the detector's semantic evidence identity. Equal message text is
    # not equal evidence: another edit can change bytes behind one dirty path.
    $finding = $FindingFingerprint
    if ([string]::IsNullOrWhiteSpace($finding)) { $finding = Get-ShortHash ($HookName + '|' + $text) }""")
for hook, var in [('Git-Sync-Check', '$fingerprint'), ('Feature-Request-Check', '$fingerprint'), ('Docs-Freshness-Check', '$impactFingerprint'), ('Large-File-Check', '$fingerprint')]:
    p = f'hooks/{hook}/{hook}.ps1'
    s = get(p)
    old = "Write-StopBlockResult -HookInput $hookInput -HookName '" + hook + "'"
    assert old in s
    put(p, s.replace(old, old + ' -FindingFingerprint ' + var))
p = 'hooks/Ci-Status-Check/Ci-Status-Check.ps1'
s = get(p).replace("    Save-State -Outcome $Outcome\n    # Record", """    Save-State -Outcome $Outcome
    $evidence = Get-Variable -Name snapshot -ValueOnly -ErrorAction SilentlyContinue
    $evidenceKey = $script:sha + '|' + $Outcome
    if ($null -ne $evidence) { $evidenceKey += '|' + [string](Get-Field $evidence 'Fingerprint') }
    # Record""")
s = s.replace('-EventName $script:eventName -Reason $Reason', '-EventName $script:eventName -Reason $Reason -FindingFingerprint (Get-ShortHash $evidenceKey)')
put(p, s)
p = 'scripts/_testlib.ps1'
s = get(p) + '''
# Copy the shared runtime payload chosen by the real production planner, rather
# than fabricating a runtime containing only _hooklib.ps1. The sibling hook
# scripts keep their repository-relative dot-source path in these fixtures.
function Copy-TestRuntimeLibraries {
    param([Parameter(Mandatory = $true)][string]$SourceHookLib, [Parameter(Mandatory = $true)][string]$Destination)
    $tool = Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($SourceHookLib)))
    $target = Split-Path -Parent $Destination
    . (Join-Path $tool 'scripts\\_installruntimepayload.ps1')
    function New-PlanArtifact {
        param([string]$RelativePath, [string]$Kind, [string]$SourcePath)
        return [pscustomobject]@{ RelativePath = $RelativePath; SourcePath = $SourcePath }
    }
    function Add-Artifact {
        param($Artifact)
        Copy-Item -LiteralPath $Artifact.SourcePath -Destination (Join-Path $target ([IO.Path]::GetFileName($Artifact.RelativePath))) -Force -ErrorAction Stop
    }
    Add-SharedRuntimeLibraryArtifacts -ToolRoot $tool -FriendlyName 'TestRuntime'
}
'''
put(p, s)
for f in ['Test-DocsFreshnessCheck.ps1', 'Test-LargeFileCheck.ps1', 'Test-TestTempCleanup.ps1', 'Test-ContextHooks.ps1', 'Test-RulesCheck.ps1', 'Test-CiStatusCheck.ps1', 'Test-FeatureRequestCheck.ps1', '_testcontextskills.ps1', '_testcontextaimemory.ps1', '_testcontextlargefile.ps1', '_testutf8harness.ps1', '_testcompletionharness.ps1', '_testcompletiondeepdebug.ps1']:
    p = 'scripts/' + f
    lines = get(p).splitlines()
    for i, line in enumerate(lines):
        if 'Copy-Item ' in line and (' $HookLib ' in line or "'..\\_hooklib.ps1'" in line or "'_hooklib.ps1') (Join-Path $Work" in line):
            line = line.replace('Copy-Item ', 'Copy-TestRuntimeLibraries -SourceHookLib ', 1)
            line = line.replace(" (Join-Path $Work '_hooklib.ps1')", " -Destination (Join-Path $Work '_hooklib.ps1')")
            lines[i] = line.replace(' -Force', '')
    put(p, '\n'.join(lines) + '\n')
p = 'scripts/Test-ContextHooks.ps1'
s = get(p).replace('hook = (@{ hookSpecificOutput = @{ hookEventName = $ev; additionalContext = $text } }', 'hook = (@{ systemMessage = $text }')
put(p, s)
p = 'scripts/_testcontexthooklib.ps1'
s = get(p).replace("' still uses additionalContext, so the clients diverge only on Stop'", "' uses a non-continuing systemMessage, never model context'")
s = s.replace("$hrClaudeStop.Result.Shape -eq 'claudeContext'", "$hrClaudeStop.Result.Shape -eq 'claudeSystemMessage'")
s = s.replace("$hrClaudeStop.Out -match '\"additionalContext\"\\s*:\\s*\"claude-stop\"'", "$hrClaudeStop.Out -match '\"systemMessage\"\\s*:\\s*\"claude-stop\"' -and $hrClaudeStop.Out -notmatch 'hookSpecificOutput|decision'")
put(p, s)
p = 'scripts/_testcontextlargefile.ps1'
s = get(p).replace(".PSObject.Properties['hookSpecificOutput']", ".PSObject.Properties['systemMessage']")
s = s.replace('.hookSpecificOutput.additionalContext', '.systemMessage')
s = s.replace("[string]$lfClaudeDoc.hookSpecificOutput.hookEventName -eq 'Stop'", "$r.Out -notmatch 'hookSpecificOutput'")
s = s.replace("Result.Shape -eq 'claudeContext'", "Result.Shape -eq 'claudeSystemMessage'")
s = s.replace('hookSpecificOutput.additionalContext (event Stop)', 'systemMessage (no model continuation)')
put(p, s)
for p in ['scripts/Test-TestTempCleanup.ps1', 'scripts/Test-LargeFileCheck.ps1', 'scripts/_testutf8events.ps1']:
    s = get(p)
    for name in ['parsedClaude', 'parsedCap']:
        s = s.replace(f"${name}.PSObject.Properties['hookSpecificOutput']", f"${name}.PSObject.Properties['systemMessage']")
        s = s.replace(f"[string]${name}.hookSpecificOutput.hookEventName -eq 'Stop'", f"$null -eq ${name}.PSObject.Properties['hookSpecificOutput']")
        s = s.replace(f'${name}.hookSpecificOutput.additionalContext', f'${name}.systemMessage')
    put(p, s)
p = 'scripts/Test-CiStatusCheck.ps1'
s = get(p).replace("'billing block (Claude) -> model-visible additionalContext, not a block' ($r.Out -match 'additionalContext'", "'billing block (Claude) -> non-continuing systemMessage, not a block' ($r.Out -match 'systemMessage'")
put(p, s)
p = 'scripts/_testcistatuscheckexternal.ps1'
s = get(p).replace("$r.Out -notmatch '\"decision\":\"block\"' -and $r.Out -match 'additionalContext'", "$r.Out -notmatch '\"decision\":\"block\"' -and $r.Out -match 'systemMessage'")
s = s.replace("$r.Out -match '\"hookSpecificOutput\"' -and $r.Out -match '\"hookEventName\":\"Stop\"' -and $r.Out -notmatch '\"systemMessage\"'", "$r.Out -match '\"systemMessage\"' -and $r.Out -notmatch 'hookSpecificOutput|additionalContext|decision'")
s = s.replace('model-visible hookSpecificOutput/additionalContext shape', 'non-continuing user-visible systemMessage shape')
put(p, s)
p = 'scripts/Test-LargeFileCheck.ps1'
s = get(p).replace("$parsedPartC.PSObject.Properties['hookSpecificOutput']", "$parsedPartC.PSObject.Properties['systemMessage']")
s = s.replace('$parsedPartC.hookSpecificOutput.additionalContext', '$parsedPartC.systemMessage')
s = s.replace('CLAUDE uses hookSpecificOutput.additionalContext with the event name', 'CLAUDE uses non-continuing systemMessage')
s = s.replace('CLAUDE uses hookSpecificOutput and is not a block', 'CLAUDE uses non-continuing systemMessage and is not a block')
put(p, s)
p = 'scripts/Test-TestTempCleanup.ps1'
s = get(p).replace("$rClaude.Out -match '\"additionalContext\"'", "$rClaude.Out -match '\"systemMessage\"' -and $rClaude.Out -notmatch 'hookSpecificOutput'")
s = s.replace('Claude advisory uses hookSpecificOutput.additionalContext, not decision:block', 'Claude advisory uses non-continuing systemMessage, not decision:block')
put(p, s)
