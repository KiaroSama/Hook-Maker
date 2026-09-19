# Test-Utf8EncodingCheck.ps1 scenario block: SESSIONSTART BASELINE and the
# STOP GATE - metadata-only state (no contents), legacy-vs-new distinction,
# blocks for new/changed invalid UTF-8, staged-only and committed-during-task
# detection, the non-git baseline delta, honest partial coverage, the
# per-session block fingerprint, both client output shapes, recursion and
# mutation guarantees, and the red-proof stub control for the Stop block.
#
# Dot-sourced by Test-Utf8EncodingCheck.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- SessionStart: legacy advisory in the Codex OFF-Stop shape; state is metadata-only ---' -ForegroundColor Cyan
    $hcLeg = New-IsolatedHookCopy
    $projLeg = New-GitRepo 'LegacyAdvisory'
    Write-Utf8 (Join-Path $projLeg 'good.txt') "VALIDCONTENTMARKER text that must never reach state`n"
    Write-Bytes (Join-Path $projLeg 'old.txt') (Get-InvalidUtf8Bytes 'LEGACYCONTENTMARKER')
    Add-Commit $projLeg 'legacy seed'
    $r = Fire -HookPath $hcLeg.Script -Cwd $projLeg -EventName 'SessionStart' -LocalAppData $hcLeg.LocalAppData
    Check 'legacy SessionStart exits 0 with no stderr' ($r.Exit -eq 0 -and $r.Err -eq '') $r.Err
    $parsedLeg = $null
    try { $parsedLeg = $r.Out | ConvertFrom-Json } catch { $parsedLeg = $null }
    # THE CODEX x OFF-STOP PAIR. This hook runs on BOTH sides of the boundary,
    # so the pair is asserted in both directions: SessionStart is off Stop and
    # must be additionalContext (below); Stop keeps systemMessage (asserted at
    # the UTF8_ADVISORY_ONLY case). Codex documents systemMessage for Stop/
    # SubagentStop only - having it here was the shipped defect.
    Check 'Codex OFF Stop (SessionStart, no CLAUDE_PROJECT_DIR) gets additionalContext, never systemMessage' (
        $null -ne $parsedLeg -and $null -eq $parsedLeg.PSObject.Properties['systemMessage'] -and
        $null -ne $parsedLeg.PSObject.Properties['hookSpecificOutput'] -and
        [string]$parsedLeg.hookSpecificOutput.hookEventName -eq 'SessionStart' -and
        -not [string]::IsNullOrWhiteSpace([string]$parsedLeg.hookSpecificOutput.additionalContext)) $r.Out
    Check 'pre-existing non-UTF-8 is an ADVISORY naming the file, never a block' (
        (Get-Message $r.Out) -match '- old\.txt - an invalid UTF-8 byte sequence' -and $r.Out -notmatch '"decision"') $r.Out
    $stateFiles = @(Get-ChildItem -LiteralPath (Join-Path $hcLeg.LocalAppData 'HookMaker\state') -Filter 'Utf8EncodingCheck-*.json' -ErrorAction SilentlyContinue)
    Check 'exactly one baseline state file exists under the isolated LOCALAPPDATA' ($stateFiles.Count -eq 1)
    $stateText = [System.IO.File]::ReadAllText($stateFiles[0].FullName)
    Check 'the baseline records relative path + classification metadata' ($stateText -match 'old\.txt' -and $stateText -match 'invalid') $stateText
    Check 'the baseline stores NO file contents (metadata only)' (
        $stateText -notmatch 'LEGACYCONTENTMARKER' -and $stateText -notmatch 'VALIDCONTENTMARKER') $stateText

    Write-Host '--- SessionStart: CLAUDE_PROJECT_DIR is the client signal; the INPUT envelope is not ---' -ForegroundColor Cyan
    # An echoed `hookSpecificOutput` in the INPUT event is NOT a documented client
    # signal and Get-HookClientId does not implement it. Off Stop that costs
    # nothing (both clients take the same shape), which is why the Stop case
    # below is the one that actually pins it.
    $hcCl1 = New-IsolatedHookCopy
    $r = Fire -HookPath $hcCl1.Script -Cwd $projLeg -EventName 'SessionStart' -LocalAppData $hcCl1.LocalAppData -ClaudeInputShape
    $parsedCl = $null
    try { $parsedCl = $r.Out | ConvertFrom-Json } catch { $parsedCl = $null }
    Check 'an INPUT hookSpecificOutput leaves the off-Stop additionalContext shape unchanged' (
        $null -ne $parsedCl -and $null -ne $parsedCl.PSObject.Properties['hookSpecificOutput'] -and
        $null -eq $parsedCl.PSObject.Properties['systemMessage'] -and
        [string]$parsedCl.hookSpecificOutput.hookEventName -eq 'SessionStart' -and
        -not [string]::IsNullOrWhiteSpace([string]$parsedCl.hookSpecificOutput.additionalContext)) $r.Out
    $hcCl2 = New-IsolatedHookCopy
    $r = Fire -HookPath $hcCl2.Script -Cwd $projLeg -EventName 'SessionStart' -LocalAppData $hcCl2.LocalAppData -ClaudeProjectDir $projLeg
    $parsedCl2 = $null
    try { $parsedCl2 = $r.Out | ConvertFrom-Json } catch { $parsedCl2 = $null }
    Check 'CLAUDE_PROJECT_DIR alone also selects the Claude shape' (
        $null -ne $parsedCl2 -and $null -ne $parsedCl2.PSObject.Properties['hookSpecificOutput']) $r.Out

    Write-Host '--- a clean project baseline is silent (but still recorded) ---' -ForegroundColor Cyan
    $hcClean = New-IsolatedHookCopy
    $projClean = New-GitRepo 'CleanBase'
    Write-Utf8 (Join-Path $projClean 'fine.txt') "all good`n"
    Add-Commit $projClean 'clean seed'
    $r = Fire -HookPath $hcClean.Script -Cwd $projClean -EventName 'SessionStart' -LocalAppData $hcClean.LocalAppData
    Check 'a clean, fully covered baseline produces NOTHING' ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ($r.Out + $r.Err)
    Check 'the silent baseline was still written' (@(Get-ChildItem -LiteralPath (Join-Path $hcClean.LocalAppData 'HookMaker\state') -Filter 'Utf8EncodingCheck-*.json' -ErrorAction SilentlyContinue).Count -eq 1)

    # =====================================================================
    Write-Host '--- Stop: unchanged legacy non-UTF-8 never blocks ---' -ForegroundColor Cyan
    $r = Fire -HookPath $hcLeg.Script -Cwd $projLeg -EventName 'Stop' -SessionId 'leg1' -LocalAppData $hcLeg.LocalAppData
    Check 'a committed, UNCHANGED legacy invalid file does not block at Stop (silent)' (
        $r.Exit -eq 0 -and -not (Test-StopBlocks $r.Out) -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Stop: a NEW invalid file blocks; the negative control and the stub prove it ---' -ForegroundColor Cyan
    $hcFresh = New-IsolatedHookCopy
    $projFresh = New-GitRepo 'FreshBlock'
    Write-Utf8 (Join-Path $projFresh 'base.txt') "seed`n"
    Add-Commit $projFresh 'seed'
    Write-Bytes (Join-Path $projFresh 'fresh.txt') (Get-InvalidUtf8Bytes 'FRESHSECRETMARKER')
    $sigBefore = Get-TreeSignature $projFresh
    $r = Fire -HookPath $hcFresh.Script -Cwd $projFresh -EventName 'Stop' -SessionId 's1' -LocalAppData $hcFresh.LocalAppData
    $sigAfter = Get-TreeSignature $projFresh
    Check 'a NEW invalid-UTF-8 file blocks at Stop (decision:block)' (Test-StopBlocks $r.Out) $r.Out
    Check 'the block names the relative path and the classification' ((Get-Message $r.Out) -match 'fresh\.txt - an invalid UTF-8 byte sequence') $r.Out
    Check 'the block reason never contains the file contents' ((Get-Message $r.Out) -notmatch 'FRESHSECRETMARKER') $r.Out
    Check 'the block explains the safe action without offering to rewrite anything' ((Get-Message $r.Out) -match '(?i)never rewrites') $r.Out
    Check 'the whole project tree is byte-for-byte identical after the gate ran (never mutates)' ($sigBefore -eq $sigAfter)

    # NEGATIVE CONTROL (the red half for a brand-new hook): the identical
    # scenario with VALID bytes passes - the block genuinely depends on the
    # invalid bytes, not on the file merely being new.
    $hcFreshCtl = New-IsolatedHookCopy
    $projFreshCtl = New-GitRepo 'FreshControl'
    Write-Utf8 (Join-Path $projFreshCtl 'base.txt') "seed`n"
    Add-Commit $projFreshCtl 'seed'
    Write-Utf8 (Join-Path $projFreshCtl 'fresh.txt') "the same new file, but valid UTF-8`n"
    $r = Fire -HookPath $hcFreshCtl.Script -Cwd $projFreshCtl -EventName 'Stop' -SessionId 's1' -LocalAppData $hcFreshCtl.LocalAppData
    Check 'negative control: the SAME flow with valid bytes does NOT block' (
        $r.Exit -eq 0 -and -not (Test-StopBlocks $r.Out) -and $r.Out -eq '') $r.Out

    # STUB PROOF: run the invalid scenario against an exit-0 stub and show the
    # block assertion FAILS against it - the test is load-bearing, not
    # trivially green.
    $stub = New-StubHook
    $rStub = Fire -HookPath $stub.Script -Cwd $projFresh -EventName 'Stop' -SessionId 'sX' -LocalAppData $stub.LocalAppData
    Check 'stub proof: an exit-0 stub does NOT satisfy the block assertion (test is load-bearing)' (
        -not (Test-StopBlocks $rStub.Out) -and $rStub.Out -eq '') $rStub.Out

    # =====================================================================
    Write-Host '--- Stop fingerprint: unchanged state re-blocks once per session, changed state at once ---' -ForegroundColor Cyan
    $r = Fire -HookPath $hcFresh.Script -Cwd $projFresh -EventName 'Stop' -SessionId 's1' -LocalAppData $hcFresh.LocalAppData
    Check 'the SAME unchanged violation in the SAME session does not re-block' (-not (Test-StopBlocks $r.Out)) $r.Out
    # The repeat used to be a short "unchanged, still unresolved" advisory. On
    # Claude Code a Stop additionalContext re-invokes the model, so that
    # advisory re-invoked the agent on EVERY Stop while the file stayed unfixed
    # - a loop. The block already said it once this session; the repeat is
    # silent, and a NEW session is blocked again.
    Check 'the repeat is SILENT - a Stop advisory re-invokes the model, so repeating it would loop' ($r.Out -eq '') $r.Out
    $r = Fire -HookPath $hcFresh.Script -Cwd $projFresh -EventName 'Stop' -SessionId 's2' -LocalAppData $hcFresh.LocalAppData
    Check 'a NEW session with the same unresolved violation is blocked again' (Test-StopBlocks $r.Out) $r.Out
    Write-Bytes (Join-Path $projFresh 'fresh2.txt') (Get-InvalidUtf8Bytes 'SECONDMARKER')
    $r = Fire -HookPath $hcFresh.Script -Cwd $projFresh -EventName 'Stop' -SessionId 's1' -LocalAppData $hcFresh.LocalAppData
    Check 'CHANGED state (a second invalid file) re-evaluates and blocks immediately' (
        (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'fresh2\.txt') $r.Out

    # =====================================================================
    Write-Host '--- Stop: an unverified (oversized) file is reported once per session, never on every Stop ---' -ForegroundColor Cyan
    # Unverified files that stay unverified used to be reported on every Stop.
    # On Claude Code that is a model re-invocation per Stop - a loop with
    # nothing new to act on. Once per session per unchanged set.
    $hcUnk = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILE_KB=1`n"
    $projUnk = New-GitRepo 'UnknownOnce'
    Write-Utf8 (Join-Path $projUnk 'base.txt') "seed`n"
    Add-Commit $projUnk 'seed'
    Write-Utf8 (Join-Path $projUnk 'big.txt') (('a' * 3000) + "`n")
    $r = Fire -HookPath $hcUnk.Script -Cwd $projUnk -EventName 'Stop' -SessionId 'u1' -LocalAppData $hcUnk.LocalAppData
    Check 'an oversized new text file yields the NOT-verified advisory (not a block, not silence)' (-not (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'could NOT be verified') $r.Out
    $r = Fire -HookPath $hcUnk.Script -Cwd $projUnk -EventName 'Stop' -SessionId 'u1' -LocalAppData $hcUnk.LocalAppData
    Check 'the same unverified set in the same session is silent on the next Stop' ($r.Out -eq '') $r.Out
    $r = Fire -HookPath $hcUnk.Script -Cwd $projUnk -EventName 'Stop' -SessionId 'u2' -LocalAppData $hcUnk.LocalAppData
    Check 'a NEW session is told about the unverified file again' ((Get-Message $r.Out) -match 'could NOT be verified') $r.Out

    # =====================================================================
    Write-Host '--- Stop: valid->invalid modification blocks; the fix clears immediately ---' -ForegroundColor Cyan
    $hcMod = New-IsolatedHookCopy
    $projMod = New-GitRepo 'ModBlock'
    Write-Utf8 (Join-Path $projMod 'mod.txt') "starts perfectly valid`n"
    Add-Commit $projMod 'valid seed'
    Write-Bytes (Join-Path $projMod 'mod.txt') (Get-InvalidUtf8Bytes 'MODMARKER')
    $r = Fire -HookPath $hcMod.Script -Cwd $projMod -EventName 'Stop' -SessionId 'm1' -LocalAppData $hcMod.LocalAppData
    Check 'a valid file MODIFIED to invalid UTF-8 blocks' ((Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'mod\.txt') $r.Out
    Write-Utf8 (Join-Path $projMod 'mod.txt') "fixed back to valid UTF-8`n"
    $r = Fire -HookPath $hcMod.Script -Cwd $projMod -EventName 'Stop' -SessionId 'm1' -LocalAppData $hcMod.LocalAppData
    Check 'fixing the file back to valid UTF-8 clears the gate immediately (same session)' (
        $r.Exit -eq 0 -and -not (Test-StopBlocks $r.Out) -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Stop: staged-only invalid content is still seen ---' -ForegroundColor Cyan
    $hcStg = New-IsolatedHookCopy
    $projStg = New-GitRepo 'StagedOnly'
    Write-Utf8 (Join-Path $projStg 's.txt') "valid original`n"
    Add-Commit $projStg 'seed'
    Write-Bytes (Join-Path $projStg 's.txt') (Get-InvalidUtf8Bytes 'STAGEDMARKER')
    & git -C $projStg add s.txt 2>$null | Out-Null
    Write-Utf8 (Join-Path $projStg 's.txt') "worktree reverted to valid - only the INDEX holds the bad bytes`n"
    $r = Fire -HookPath $hcStg.Script -Cwd $projStg -EventName 'Stop' -SessionId 'g1' -LocalAppData $hcStg.LocalAppData
    Check 'invalid bytes living only in the git INDEX (staged, worktree reverted) still block' (
        (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 's\.txt \(staged content\)') $r.Out
    Check 'the staged-content block never leaks the staged bytes' ((Get-Message $r.Out) -notmatch 'STAGEDMARKER') $r.Out

    # =====================================================================
    Write-Host '--- Stop: a deleted file is handled without a crash or a block ---' -ForegroundColor Cyan
    $hcDel = New-IsolatedHookCopy
    $projDel = New-GitRepo 'Deleted'
    Write-Utf8 (Join-Path $projDel 'gone.txt') "will be deleted`n"
    Add-Commit $projDel 'seed'
    Remove-Item -LiteralPath (Join-Path $projDel 'gone.txt') -Force
    $r = Fire -HookPath $hcDel.Script -Cwd $projDel -EventName 'Stop' -SessionId 'd1' -LocalAppData $hcDel.LocalAppData
    Check 'a deleted file produces no crash and no block' (
        $r.Exit -eq 0 -and $r.Err -eq '' -and -not (Test-StopBlocks $r.Out)) ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- Stop: a file committed DURING the task is caught via the baseline HEAD ---' -ForegroundColor Cyan
    $hcCmt = New-IsolatedHookCopy
    $projCmt = New-GitRepo 'Committed'
    Write-Utf8 (Join-Path $projCmt 'base.txt') "seed`n"
    Add-Commit $projCmt 'seed'
    $r = Fire -HookPath $hcCmt.Script -Cwd $projCmt -EventName 'SessionStart' -SessionId 'c1' -LocalAppData $hcCmt.LocalAppData
    Check 'the clean pre-task baseline is silent' ($r.Out -eq '') $r.Out
    Write-Bytes (Join-Path $projCmt 'cm.txt') (Get-InvalidUtf8Bytes 'COMMITMARKER')
    Add-Commit $projCmt 'commit the bad file during the task'
    Check 'fixture sanity: the tree is clean after the mid-task commit' (@(& git -C $projCmt status --porcelain).Count -eq 0)
    $r = Fire -HookPath $hcCmt.Script -Cwd $projCmt -EventName 'Stop' -SessionId 'c1' -LocalAppData $hcCmt.LocalAppData
    Check 'an invalid file committed during the task (clean tree) still blocks via the baseline delta' (
        (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'cm\.txt') $r.Out

    # =====================================================================
    Write-Host '--- Stop: non-git projects use the baseline delta; no baseline means no guess ---' -ForegroundColor Cyan
    $hcNg = New-IsolatedHookCopy
    $projNg = New-Proj 'NoGitDelta'
    Write-Utf8 (Join-Path $projNg 'a.txt') "existing valid file`n"
    $null = Fire -HookPath $hcNg.Script -Cwd $projNg -EventName 'SessionStart' -SessionId 'n1' -LocalAppData $hcNg.LocalAppData
    Write-Bytes (Join-Path $projNg 'b.txt') (Get-InvalidUtf8Bytes 'NOGITMARKER')
    $r = Fire -HookPath $hcNg.Script -Cwd $projNg -EventName 'Stop' -SessionId 'n1' -LocalAppData $hcNg.LocalAppData
    Check 'non-git: a NEW invalid file is caught through the size/mtime baseline delta' (
        (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'b\.txt') $r.Out
    $hcNg2 = New-IsolatedHookCopy
    $projNg2 = New-Proj 'NoGitNoBase'
    Write-Bytes (Join-Path $projNg2 'orphan.txt') (Get-InvalidUtf8Bytes 'ORPHANMARKER')
    $r = Fire -HookPath $hcNg2.Script -Cwd $projNg2 -EventName 'Stop' -SessionId 'n2' -LocalAppData $hcNg2.LocalAppData
    Check 'non-git WITHOUT a baseline: nothing is determinable, so nothing is guessed (silent)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Stop: hitting the changed-file ceiling is explicit PARTIAL, never an all-clear ---' -ForegroundColor Cyan
    $hcCap = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILES=1`n"
    $projCap = New-GitRepo 'CapPartial'
    Write-Utf8 (Join-Path $projCap 'base.txt') "seed`n"
    Add-Commit $projCap 'seed'
    Write-Utf8 (Join-Path $projCap 'aa.txt') "first changed file, valid`n"
    Write-Bytes (Join-Path $projCap 'zz-bad.txt') (Get-InvalidUtf8Bytes 'BEYONDCAPMARKER')
    $r = Fire -HookPath $hcCap.Script -Cwd $projCap -EventName 'Stop' -SessionId 'p1' -LocalAppData $hcCap.LocalAppData -ClaudeProjectDir $projCap
    $msgCap = Get-Message $r.Out
    Check 'the capped check reports PARTIAL and refuses to call it an all-clear' (
        -not (Test-StopBlocks $r.Out) -and $msgCap -match '(?i)PARTIAL' -and $msgCap -match '(?i)NOT an all-clear' -and $msgCap -match 'UTF8_MAX_FILES') $r.Out
    $parsedCap = $null
    try { $parsedCap = $r.Out | ConvertFrom-Json } catch { $parsedCap = $null }
    Check 'the Stop advisory uses the Claude shape when CLAUDE_PROJECT_DIR is set' (
        $null -ne $parsedCap -and $null -ne $parsedCap.PSObject.Properties['systemMessage'] -and
        $null -eq $parsedCap.PSObject.Properties['hookSpecificOutput']) $r.Out

    # =====================================================================
    Write-Host '--- Stop: SubagentStop behaves like Stop; guards and foreign events are silent ---' -ForegroundColor Cyan
    $hcSub = New-IsolatedHookCopy
    $projSub = New-GitRepo 'SubStop'
    Write-Utf8 (Join-Path $projSub 'base.txt') "seed`n"
    Add-Commit $projSub 'seed'
    Write-Bytes (Join-Path $projSub 'sub.txt') (Get-InvalidUtf8Bytes 'SUBMARKER')
    $r = Fire -HookPath $hcSub.Script -Cwd $projSub -EventName 'SubagentStop' -SessionId 'u1' -LocalAppData $hcSub.LocalAppData
    Check 'SubagentStop blocks exactly like Stop' ((Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'sub\.txt') $r.Out
    $r = Fire -HookPath $hcSub.Script -Cwd $projSub -EventName 'Stop' -SessionId 'u2' -LocalAppData $hcSub.LocalAppData -StopHookActive
    # stop_hook_active means "a Stop gate blocked and the agent is coming
    # back" - NOT "YOU blocked". Thirteen gates share the one flag, so a gate
    # standing down on it alone went silent for somebody else's block, and
    # the next Stop ran with the secret-leak, UTF-8 and CI gates all muted.
    # Each gate now stands down only on its OWN re-entry, proven by a marker
    # it writes itself immediately before it blocks.
    Check 'stop_hook_active ALONE does not mute live findings (another gate blocked, not this one)' ($r.Exit -eq 0 -and $r.Out -ne '') $r.Out
    $r = Fire -HookPath $hcSub.Script -Cwd $projSub -EventName 'PreToolUse' -SessionId 'u3' -LocalAppData $hcSub.LocalAppData
    Check 'an event this hook does not own is silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- config: advisory-only mode and malformed .env fall SAFE, never wider ---' -ForegroundColor Cyan
    $hcAdv = New-IsolatedHookCopy -EnvContent "UTF8_ADVISORY_ONLY=true`n"
    $projAdv = New-GitRepo 'AdvisoryOnly'
    Write-Utf8 (Join-Path $projAdv 'base.txt') "seed`n"
    Add-Commit $projAdv 'seed'
    Write-Bytes (Join-Path $projAdv 'adv.txt') (Get-InvalidUtf8Bytes 'ADVMARKER')
    $r = Fire -HookPath $hcAdv.Script -Cwd $projAdv -EventName 'Stop' -SessionId 'a1' -LocalAppData $hcAdv.LocalAppData
    Check 'UTF8_ADVISORY_ONLY=true reports the finding without decision:block' (
        -not (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'adv\.txt' -and (Get-Message $r.Out) -match '(?i)reported, not blocked') $r.Out
    $parsedAdv = $null
    try { $parsedAdv = $r.Out | ConvertFrom-Json } catch { $parsedAdv = $null }
    Check 'the OTHER half of the pair: Codex ON Stop keeps systemMessage' (
        $null -ne $parsedAdv -and $null -ne $parsedAdv.PSObject.Properties['systemMessage'] -and
        $null -eq $parsedAdv.PSObject.Properties['hookSpecificOutput']) $r.Out
    # Stop is the only event where the two shapes differ, so it is the only place
    # a bogus client signal is observable: an INPUT hookSpecificOutput with no
    # CLAUDE_PROJECT_DIR must stay Codex, i.e. systemMessage.
    $hcAdv2 = New-IsolatedHookCopy -EnvContent "UTF8_ADVISORY_ONLY=true`n"
    $r = Fire -HookPath $hcAdv2.Script -Cwd $projAdv -EventName 'Stop' -SessionId 'a2' -LocalAppData $hcAdv2.LocalAppData -ClaudeInputShape
    $parsedAdv2 = $null
    try { $parsedAdv2 = $r.Out | ConvertFrom-Json } catch { $parsedAdv2 = $null }
    Check 'an INPUT hookSpecificOutput does NOT make it Claude on Stop (still systemMessage)' (
        $null -ne $parsedAdv2 -and $null -ne $parsedAdv2.PSObject.Properties['systemMessage'] -and
        $null -eq $parsedAdv2.PSObject.Properties['hookSpecificOutput'] -and
        ([string]$parsedAdv2.systemMessage) -match 'adv\.txt') $r.Out
    $hcBadEnv = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILES=nope`nUTF8_ADVISORY_ONLY=maybe`n"
    $projBadEnv = New-GitRepo 'BadEnv'
    Write-Utf8 (Join-Path $projBadEnv 'base.txt') "seed`n"
    Add-Commit $projBadEnv 'seed'
    Write-Bytes (Join-Path $projBadEnv 'bad.txt') (Get-InvalidUtf8Bytes 'BADENVMARKER')
    $r = Fire -HookPath $hcBadEnv.Script -Cwd $projBadEnv -EventName 'Stop' -SessionId 'b1' -LocalAppData $hcBadEnv.LocalAppData
    Check 'a malformed .env never crashes the gate' ($r.Exit -eq 0 -and $r.Err -eq '') $r.Err
    Check 'the invalid integer is reported and the default used; the bad flag falls to advisory-only (non-widening)' (
        -not (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'UTF8_MAX_FILES is not an integer' -and
        (Get-Message $r.Out) -match '(?i)falling back to advisory-only') $r.Out

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 host: the Stop gate works unchanged ---' -ForegroundColor Cyan
    $hc51 = New-IsolatedHookCopy
    $proj51 = New-GitRepo 'Host51Stop'
    Write-Utf8 (Join-Path $proj51 'base.txt') "seed`n"
    Add-Commit $proj51 'seed'
    Write-Bytes (Join-Path $proj51 'h51.txt') (Get-InvalidUtf8Bytes 'HOST51MARKER')
    $r = Fire -HookPath $hc51.Script -Cwd $proj51 -EventName 'Stop' -SessionId 'h1' -LocalAppData $hc51.LocalAppData -Exe 'powershell'
    Check '5.1 host: a new invalid file still blocks at Stop' (
        (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'h51\.txt') ($r.Out + $r.Err)
