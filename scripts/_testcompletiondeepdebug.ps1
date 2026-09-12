# Test-TestCompletionCheck.ps1 scenario block: E-05 ::deep-debug activation
# (prose never triggers, the standalone token does), the COMPLETE advisory
# and its honest not-verifiable list, marker-only activation, the no-evidence
# BLOCKED verdict, once-per-session anti-loop, stale evidence never reading
# COMPLETE, the Codex shape for both verdicts, E-13 static safety, and the
# retire-guarded historical red-proof against the pre-fix HEAD copy.
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses
# its harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- E-05: ::deep-debug activation - prose never triggers, the standalone token does ---' -ForegroundColor Cyan
    # Activation signal 2: a transcript_path in the hook's OWN stdin whose
    # bounded tail carries the standalone token. Prose "deep debug" must not.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdProse'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $proseTranscript = Join-Path $Work 'transcript-prose.jsonl'
    Write-Utf8 $proseTranscript ('{"type":"user","message":{"role":"user","content":"let us deep debug the parser and deep-debug more"}}' + "`n")
    $r = Fire -Copy $c -Cwd $p -TranscriptPath $proseTranscript
    Check 'prose "deep debug" in the transcript does NOT activate the gate (clean run stays silent)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'prose left no deep-debug marker behind' (
        -not (Test-Path -LiteralPath (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json'))))
    # The standalone token activates: clean fresh evidence -> DEEP DEBUG: COMPLETE.
    $ddTranscript = Join-Path $Work 'transcript-dd.jsonl'
    Write-Utf8 $ddTranscript ('{"type":"user","message":{"role":"user","content":"::deep-debug the parser"}}' + "`n")
    $r = Fire -Copy $c -Cwd $p -TranscriptPath $ddTranscript
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'standalone ::deep-debug + clean fresh evidence -> non-blocking COMPLETE advisory (Claude shape)' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        [string]$doc.hookSpecificOutput.additionalContext -match '(?m)^DEEP DEBUG: COMPLETE$') $r.Out
    $ddCtx = [string]$doc.hookSpecificOutput.additionalContext
    Check 'COMPLETE names the verified test-evidence scope' ($ddCtx -match 'Test-evidence scope verified' -and $ddCtx -match 'fresh clean result') $ddCtx
    Check 'COMPLETE honestly lists what this hook CANNOT verify (goal/integration/review/Ponytail/UTF-8/CI)' (
        $ddCtx -match 'NOT verifiable by this hook' -and $ddCtx -match '/goal' -and $ddCtx -match 'Ponytail' -and
        $ddCtx -match 'Utf8-Encoding-Check' -and $ddCtx -match 'exact-final-SHA CI') $ddCtx
    Check 'free-form done text is named as never-proof' ($ddCtx -match '"done" text is never proof') $ddCtx
    Check 'the session-bound marker was written (schema-versioned)' (
        (Test-Path -LiteralPath (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json'))))
    # Anti-loop: same session + unchanged state -> the COMPLETE advisory does not repeat.
    $r = Fire -Copy $c -Cwd $p -TranscriptPath $ddTranscript
    Check 'anti-loop: unchanged COMPLETE state is silent on the next Stop of the same session' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- E-05: marker-only activation, no-evidence BLOCKED, once per session ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdNoEvidence'
    # Activation signal 3: a marker from an earlier Stop of the SAME session.
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 2; activationSource = 'explicit-user-command'; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'deep-debug active with NO guarded evidence -> blocks' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the block carries the exact DEEP DEBUG: BLOCKED (reason) line' ($reason -match '(?m)^DEEP DEBUG: BLOCKED \(') $reason
    Check 'the block names the missing evidence and the guarded-runner recovery' (
        $reason -match 'NO guarded test evidence' -and $reason -match 'Run-Tests-Guarded\.ps1') $reason
    # Once per session: the unchanged no-evidence state does not re-block.
    $r = Fire -Copy $c -Cwd $p
    Check 'anti-loop: the unchanged no-evidence BLOCKED state emits once per session' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # Changed state re-evaluates immediately: fresh clean evidence -> COMPLETE.
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'changed state (fresh clean evidence) upgrades to the COMPLETE advisory immediately' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        [string]$doc.hookSpecificOutput.additionalContext -match '(?m)^DEEP DEBUG: COMPLETE$') $r.Out
    # A marker from a DIFFERENT session remains evidence, but never activates.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdStaleMarker'
    $staleMarkerPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')
    Write-Utf8 $staleMarkerPath ((@{ schema = 2; activationSource = 'explicit-user-command'; sessionId = 'some-other-session'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    $r = Fire -Copy $c -Cwd $p
    Check 'a different-session marker never activates the gate (no output)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'the stale marker is preserved as evidence' (Test-Path -LiteralPath $staleMarkerPath)

    # =====================================================================
    Write-Host '--- E-05: existing blocks carry the BLOCKED line only under deep-debug ---' -ForegroundColor Cyan
    # Normal behavior unchanged: the SAME terminated-run scenario as the original
    # suite section, WITHOUT deep-debug - no DEEP DEBUG line anywhere.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'DdOffTerminated'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'non-deep-debug: the terminated block still fires exactly as before' ($reason -match 'wallTimeout') $reason
    Check 'non-deep-debug: NO DEEP DEBUG verdict line is present' ($reason -notmatch 'DEEP DEBUG') $reason
    # Under deep-debug the same block gains the BLOCKED verdict with a concise reason.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdOnTerminated'
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 2; activationSource = 'explicit-user-command'; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'deep-debug: the terminated block carries DEEP DEBUG: BLOCKED (concise reason)' (
        $reason -match 'wallTimeout' -and $reason -match '(?m)^DEEP DEBUG: BLOCKED \(.+\)') $reason
    Check 'the BLOCKED reason is concise (derived from the finding, not the whole message)' (
        ([regex]::Match($reason, 'DEEP DEBUG: BLOCKED \(([^)]+)\)').Groups[1].Value.Length) -le 170) $reason

    # =====================================================================
    Write-Host '--- E-05: stale/unproven evidence under deep-debug never reads COMPLETE ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdStaleResult'
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 2; activationSource = 'explicit-user-command'; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 200   # stale: > default 180 evidence window
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a stale ok result under deep-debug -> BLOCKED, never COMPLETE' (
        $r.Out -match '"decision":"block"' -and $reason -match 'STALE or not a clean current-state result' -and
        $reason -match '(?m)^DEEP DEBUG: BLOCKED \(' -and $reason -notmatch 'DEEP DEBUG: COMPLETE') $reason
    $r = Fire -Copy $c -Cwd $p
    Check 'anti-loop: the unchanged stale-evidence BLOCKED state emits once per session' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- E-05: Codex shape for the deep-debug outputs ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdCodex'
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 2; activationSource = 'explicit-user-command'; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p -Codex
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'Codex COMPLETE advisory uses systemMessage, never decision:block' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        $null -eq $doc.PSObject.Properties['hookSpecificOutput'] -and
        [string]$doc.systemMessage -match '(?m)^DEEP DEBUG: COMPLETE$') $r.Out

    # =====================================================================
    Write-Host '--- E-13: static safety - the hook never executes commands, codewords, or skills ---' -ForegroundColor Cyan
    # The whole hook package: reading only the entry point would silently narrow
    # these source-text assertions the moment the hook grew a companion module.
    $tccText = (@(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -File -Filter '*.ps1' | Sort-Object Name |
            ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n")
    Check 'source has no execution primitive in statement position (Start-Process/Invoke-Expression/iex)' (
        $tccText -notmatch '(?im)^\s*(Start-Process|Invoke-Expression|iex)\b') $tccText.Substring(0, 200)
    Check 'source never applies the call operator to data (no "& $var" execution path)' ($tccText -notmatch '&\s+\$') $tccText.Substring(0, 200)
    Check 'source references /goal and ::deep-debug only as text, never in statement position' (
        $tccText -match '::deep-debug' -and $tccText -notmatch '(?im)^\s*/(goal|ponytail)' -and $tccText -notmatch '(?im)^\s*::deep-debug') $tccText.Substring(0, 200)
    Check 'the transcript tail is only MATCHED, never persisted (no transcript text in any state write)' (
        $tccText -notmatch 'WriteAllText\([^)]*tailText' -and $tccText -notmatch 'transcriptText\s*=') $tccText.Substring(0, 200)

    # =====================================================================
    Write-Host '--- E-13 RED-PROOF: the pre-fix hook emits no DEEP DEBUG verdict (HEAD copy, retire-guarded) ---' -ForegroundColor Cyan
    # Reconstructed via read-only `git show HEAD:` (never a tree mutation). FIX
    # MARKER retire guard: once the dd gate is committed HEAD contains
    # 'DEEP DEBUG:' and this historical proof retires (byte/extent equality is
    # never used - git show emits LF while working files are CRLF).
    $tccRepoRoot = Split-Path -Parent $PSScriptRoot
    $tccPreText = ((& git -C $tccRepoRoot show 'HEAD:hooks/Test-Completion-Check/Test-Completion-Check.ps1') -join "`n")
    if ($tccPreText -match 'DEEP DEBUG:') {
        Write-Host 'HEAD already contains the deep-debug gate; historical red-proof retired.' -ForegroundColor DarkGray
    }
    else {
        $tccPreDir = Join-Path $Work '_prefix-tcc'
        New-Item -ItemType Directory -Path $tccPreDir -Force | Out-Null
        $tccPreHook = Join-Path $tccPreDir 'Test-Completion-Check.ps1'
        [System.IO.File]::WriteAllText($tccPreHook, $tccPreText, (New-Object System.Text.UTF8Encoding $false))
        Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
        $tccPreLocal = Join-Path $tccPreDir '_fakelocal-prefix'
        New-Item -ItemType Directory -Path (Join-Path $tccPreLocal 'HookMaker\state') -Force | Out-Null
        $preCopy = [pscustomobject]@{ Script = $tccPreHook; LocalAppData = $tccPreLocal }
        $pRed = New-GitRepoAi 'DdRed'
        Write-Utf8 (Join-Path (Get-StateDir $preCopy) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $pRed) + '.json')) (
            (@{ schema = 2; activationSource = 'explicit-user-command'; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
        Write-GuardedResult -Copy $preCopy -Root $pRed -Overall 'ok'
        $ddRedTranscript = Join-Path $Work 'transcript-dd-red.jsonl'
        Write-Utf8 $ddRedTranscript ('{"type":"user","message":{"role":"user","content":"::deep-debug the parser"}}' + "`n")
        $rRed = Fire -Copy $preCopy -Cwd $pRed -TranscriptPath $ddRedTranscript
        Check 'RED-PROOF: the PRE-FIX hook emits NO DEEP DEBUG verdict for an active deep-debug session' (
            $rRed.Exit -eq 0 -and $rRed.Out -notmatch 'DEEP DEBUG') $rRed.Out
    }

