# Test-CiStatusCheck.ps1 scenario block: the -ReportExternalBlocker exception
# path - classification/reason validation, evidence-gated recording, client-
# aware non-blocking Stop notices (Claude additionalContext / Codex
# systemMessage), fingerprint-based recheck/invalidation (rerun, reorder,
# turned-green, different failure, gh unavailable), and repo/SHA/TTL scoping.
#
# Dot-sourced by Test-CiStatusCheck.ps1 into the caller's scope (uses its
# harness, gh shim, and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- CiStatusCheck: -ReportExternalBlocker exception (issue 3, re-verified) ---' -ForegroundColor Cyan

    $ext1 = New-GitRepo 'ext1'
    $extSha1 = Get-HeadSha $ext1

    $r = FireExternalBlocker -Cwd $ext1 -Classification 'test-failure-not-really-external' -Reason 'ci is red, ci is red, ci is red'
    Check 'unknown classification is rejected (no bypass via free text)' ($r.Exit -eq 1 -and $r.Err -match 'requires -Classification') $r.Err
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason ''
    Check 'empty reason is rejected (bounded minimum-evidence rule)' ($r.Exit -eq 1 -and $r.Err -match 'requires -Reason') $r.Err
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'too short'
    Check 'a too-short reason is rejected (below the minimum-evidence length)' ($r.Exit -eq 1 -and $r.Err -match 'requires -Reason') $r.Err
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'other-external' -Reason 'weird one-off issue'
    Check '"other-external" requires a stronger (longer) reason than the named categories' ($r.Exit -eq 1 -and $r.Err -match 'stronger justification') $r.Err
    $r = FireExternalBlocker -Cwd $plainDir -Classification 'github-outage' -Reason 'github.com is down according to the status page'
    Check 'cannot record an exception outside a resolvable pushed GitHub commit' ($r.Exit -eq 1 -and $r.Err -match 'not a resolvable, pushed commit') $r.Err

    # No CI access at all -> recording is refused (never blind/unverified).
    Set-Mock -AuthExit 1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'cannot record without querying CI (gh unauthenticated)' ($r.Exit -eq 1 -and $r.Err -match 'could not query GitHub Actions') $r.Err

    # CI already green for this exact commit -> nothing to excuse.
    Set-Mock -RunJson '[{"databaseId":79,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $extSha1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'cannot record when CI for this commit is already green' ($r.Exit -eq 1 -and $r.Err -match 'already fully green') $r.Err

    # Normal failure still blocks BEFORE any exception is recorded, and a
    # genuine COMPLETED failure can never be excused as external - not even
    # with a nominally "valid" classification.
    Set-Mock -RunJson '[{"databaseId":80,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop'
    Check 'failed CI still blocks completion before any exception exists' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'other-external' -Reason 'the build step failed so lets just call it external instead'
    Check 'a genuine completed failure cannot be reported as external, regardless of classification' ($r.Exit -eq 1 -and $r.Err -match 'genuine COMPLETED failure') $r.Err

    # An infra-consistent state (cancelled - not a completed code/test
    # failure) IS eligible, and recording captures that exact state.
    Set-Mock -RunJson '[{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"}]' -ExpectedSha $extSha1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'recording an evidenced external blocker succeeds for an infra-consistent CI state' ($r.Exit -eq 0 -and $r.Out -match 'EXTERNAL CI blocker' -and $r.Out -match 'does NOT mark CI verified') $r.Out
    # Item 5: completion allowed, but Stop surfaces a NON-BLOCKING "CI not green"
    # notice. The shape is client-aware (verified against the current official
    # docs): Claude Stop supports model-visible hookSpecificOutput.additionalContext;
    # Codex Stop supports only the common systemMessage field.
    $r = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop' -Client 'claude'
    Check 'Claude: active exception authorizes completion with a NON-BLOCKING context (not decision:block)' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'additionalContext') $r.Out
    Check 'Claude: Stop uses the model-visible hookSpecificOutput/additionalContext shape' ($r.Out -match '"hookSpecificOutput"' -and $r.Out -match '"hookEventName":"Stop"' -and $r.Out -notmatch '"systemMessage"') $r.Out
    Check 'Claude: the completion context explicitly says CI is NOT verified green' ($r.Out -match 'CI NOT VERIFIED GREEN' -and $r.Out -match 'external' ) $r.Out
    Check 'Claude: the context names repo, short sha, classification and sanitized reason' ($r.Out -match 'testowner/testrepo-ext1' -and $r.Out -match ($extSha1.Substring(0, 7)) -and $r.Out -match 'github-outage' -and $r.Out -match 'status page reports a full outage') $r.Out
    Check 'Claude: the context denies success and instructs not to claim CI passed' ($r.Out -match 'not a successful CI run' -and $r.Out -match 'do not claim CI passed') $r.Out

    # Codex: same message text, but through the officially supported common
    # systemMessage field - no hookSpecificOutput/additionalContext (undocumented
    # for Codex Stop) and never decision:block (which in Codex Stop would FORCE
    # continuation instead of allowing completion).
    $rCodex = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop' -Client 'codex'
    Check 'Codex: Stop uses the supported systemMessage shape (no hookSpecificOutput/additionalContext)' ($rCodex.Out -match '"systemMessage"' -and $rCodex.Out -notmatch 'additionalContext' -and $rCodex.Out -notmatch 'hookSpecificOutput') $rCodex.Out
    Check 'Codex: the notice is non-blocking (no decision:block)' ($rCodex.Out -notmatch '"decision":"block"') $rCodex.Out
    Check 'Codex: the notice explicitly says CI is NOT verified green' ($rCodex.Out -match 'CI NOT VERIFIED GREEN' -and $rCodex.Out -match 'not a successful CI run') $rCodex.Out
    Check 'Codex: the notice names repo, short sha, classification and sanitized reason' ($rCodex.Out -match 'testowner/testrepo-ext1' -and $rCodex.Out -match ($extSha1.Substring(0, 7)) -and $rCodex.Out -match 'github-outage' -and $rCodex.Out -match 'status page reports a full outage') $rCodex.Out
    Check 'both client shapes carry the identical notice text' (
        ($r.Out -replace '.*CI NOT VERIFIED GREEN', 'CI NOT VERIFIED GREEN' -replace '"\}\}$', '') -match 'external CI blocker' -and
        ($rCodex.Out -replace '.*CI NOT VERIFIED GREEN', 'CI NOT VERIFIED GREEN' -replace '"\}$', '') -match 'external CI blocker'
    ) ($r.Out + ' || ' + $rCodex.Out)
    Check 'neither client output exposes secret-like data (no tokens/paths/logs)' (
        $r.Out -notmatch '(?i)(ghp_|gho_|password|secret=|Bearer )' -and $rCodex.Out -notmatch '(?i)(ghp_|gho_|password|secret=|Bearer )'
    ) ($r.Out + ' || ' + $rCodex.Out)

    # Throttled re-check, same observed fingerprint -> still allowed (refreshed, not retired) + still non-blocking notice.
    $recheckHook = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_RECHECK_MINUTES = '0' }
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'recheck with the identical CI fingerprint keeps completion allowed with the notice' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN') $r.Out

    # Item 4: same run id/status/conclusion but a CHANGED attempt/updatedAt
    # (a rerun) produces a different fingerprint -> the old exception is
    # invalidated and the (still-infra) state blocks normally.
    Set-Mock -RunJson '[{"databaseId":81,"attempt":2,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T12:30:00Z"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'a rerun (changed attempt/updatedAt, same id/status/conclusion) invalidates the old exception' ($r.Out -match '"decision":"block"') $r.Out

    # Re-record, then recheck with the SAME runs in a DIFFERENT order -> the
    # normalized/sorted fingerprint is unchanged, so the exception is kept.
    Set-Mock -RunJson '[{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"},{"databaseId":70,"attempt":1,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"}]' -ExpectedSha $extSha1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'records an exception over a two-run snapshot' ($r.Exit -eq 0) $r.Err
    Set-Mock -RunJson '[{"databaseId":70,"attempt":1,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"},{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'reordered but identical snapshot keeps the exception (order-independent fingerprint)' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN') $r.Out

    # Throttled re-check, CI turned GREEN -> exception retired, verified normally
    # (NO external wording).
    Set-Mock -RunJson '[{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"},{"databaseId":70,"attempt":1,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"success"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'CI turning green on recheck retires the exception and verifies normally (no external wording)' ($r.Out -notmatch 'CI NOT VERIFIED GREEN' -and [string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)
    $r2 = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop'
    Check 'the commit now stays verified on a normal follow-up check too' ([string]::IsNullOrWhiteSpace([string]$r2.Out)) ([string]$r2.Out)

    # Throttled re-check, CI changed to a DIFFERENT failure -> exception
    # invalidated, blocks normally (also covers "pending cannot reuse a
    # stale exception": any different fingerprint invalidates it the same way).
    $ext1b = New-GitRepo 'ext1b'
    $extSha1bb = Get-HeadSha $ext1b
    Set-Mock -RunJson '[{"databaseId":90,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $extSha1bb
    $recheckHookB = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_RECHECK_MINUTES = '0' }
    $r = FireExternalBlocker -Cwd $ext1b -Classification 'runner-unavailable' -Reason 'no hosted runner picked up the job for over an hour'
    Check 'records an exception for ext1b under an infra-consistent state' ($r.Exit -eq 0) $r.Err
    Set-Mock -RunJson '[{"databaseId":91,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha1bb
    $r = Fire -HookPath $recheckHookB -Cwd $ext1b -EventName 'Stop'
    Check 'CI changing to a genuine failure on recheck invalidates the exception and blocks normally' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # Throttled re-check that cannot query gh at all -> keep tolerating the
    # existing, already-evidenced exception (never invent a new one).
    $ext1c = New-GitRepo 'ext1c'
    $extSha1c = Get-HeadSha $ext1c
    Set-Mock -RunJson '[{"databaseId":92,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $extSha1c
    $recheckHookC = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_RECHECK_MINUTES = '0' }
    $r = FireExternalBlocker -Cwd $ext1c -Classification 'external-service-outage' -Reason 'the external status-check service used by CI is down'
    Check 'records an exception for ext1c' ($r.Exit -eq 0) $r.Err
    Set-Mock -AuthExit 1
    $r = Fire -HookPath $recheckHookC -Cwd $ext1c -EventName 'Stop'
    Check 'a recheck that cannot query gh keeps tolerating the existing exception (with the notice)' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN') $r.Out

    # A NEW pushed commit invalidates the old exception (also proves a wrong SHA cannot reuse it).
    Set-Mock -RunJson '[{"databaseId":81,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $extSha1
    Set-Content (Join-Path $ext1 'file.txt') 'v2'
    & git -C $ext1 add .
    & git -C $ext1 commit -q -m c2
    $extSha1d = Get-HeadSha $ext1
    & git -C $ext1 update-ref refs/remotes/origin/main $extSha1d
    Set-Mock -RunJson '[{"databaseId":82,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha1d
    $r = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop'
    Check 'a new pushed commit resets the state - the old exception does not carry over' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # Wrong repository cannot reuse an exception recorded for a different
    # resolved repository slug.
    $ext2 = New-GitRepo 'ext2'
    $extSha2 = Get-HeadSha $ext2
    Set-Mock -RunJson '[{"databaseId":83,"name":"CI","workflowName":"CI","status":"completed","conclusion":"action_required"}]' -ExpectedSha $extSha2
    $r = FireExternalBlocker -Cwd $ext2 -Classification 'runner-unavailable' -Reason 'no hosted runner available for this org'
    Check 'records an exception for ext2''s own repository' ($r.Exit -eq 0) $r.Err
    & git -C $ext2 remote set-url origin 'https://github.com/testowner/testrepo-ext2-renamed.git'
    Set-Mock -RunJson '[{"databaseId":84,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha2
    $r = Fire -HookPath $CiHook -Cwd $ext2 -EventName 'Stop'
    Check 'a different resolved repository cannot reuse a prior exception' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # Expired/stale exception is rejected: TTL=0 means the very next check
    # already treats it as expired and falls back to normal (blocking) evaluation.
    $ext3 = New-GitRepo 'ext3'
    $extSha3 = Get-HeadSha $ext3
    Set-Mock -RunJson '[{"databaseId":85,"name":"CI","workflowName":"CI","status":"completed","conclusion":"timed_out"}]' -ExpectedSha $extSha3
    $r = FireExternalBlocker -Cwd $ext3 -Classification 'permission-failure' -Reason 'org disabled Actions for this repo temporarily'
    Check 'records an exception for ext3' ($r.Exit -eq 0) $r.Err
    $shortTtlHook = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_TTL_MINUTES = '0' }
    Set-Mock -RunJson '[{"databaseId":86,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha3
    $r = Fire -HookPath $shortTtlHook -Cwd $ext3 -EventName 'Stop'
    Check 'expired exception is rejected - falls back to normal (blocking) evaluation' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # stop_hook_active means ANY gate blocked, not this one - so with a live
    # exception on file the notice must STILL be emitted. Recursion is
    # prevented by this gate's own marker, not by the shared flag.
    $ext4 = New-GitRepo 'ext4'
    $extSha4 = Get-HeadSha $ext4
    Set-Mock -RunJson '[{"databaseId":87,"name":"CI","workflowName":"CI","status":"completed","conclusion":"stale"}]' -ExpectedSha $extSha4
    $r = FireExternalBlocker -Cwd $ext4 -Classification 'manual-approval-required' -Reason 'awaiting a required environment approval the agent cannot grant'
    Check 'records an exception for ext4' ($r.Exit -eq 0) $r.Err
    $r = Fire -HookPath $CiHook -Cwd $ext4 -EventName 'Stop' -Extra @{ stop_hook_active = $true }
    Check 'stop_hook_active ALONE does not short-circuit the exception notice (another gate blocked, not this one)' ($r.Out -ne '') $r.Out
