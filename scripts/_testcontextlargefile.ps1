# Test-ContextHooks section: Large-File-Check.
#
# Dot-sourced from Test-ContextHooks.ps1 INSIDE its try block, so it runs in
# that scope and uses its harness directly: $Work, $Fire, Check, New-Proj,
# Write-Utf8, Set-ClaudeProjectDir and the counters. Pure relocation - the
# lines below are byte-identical to the ones this file replaced, indentation
# included, so the move can be proved rather than reviewed line by line.
#
# The underscore prefix keeps it out of the runner's Test-*.ps1 glob, so it
# needs no ci.yml bucket entry of its own.

    # Hook state (the cooldown timestamp AND the SessionStart baseline) is
    # redirected under $Work for the WHOLE section, so neither the pre-task fire
    # below nor the Stop fires leave residue in the real LOCALAPPDATA. It used to
    # be set only around the Stop block, from when SessionStart wrote no state.
    $lfOrigLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = (Join-Path $Work 'lf-fakelocal')
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

    # =====================================================================
    Write-Host '--- Large-File-Check: pre-task hard-ceiling wording ---' -ForegroundColor Cyan
    $lfProj = New-Proj 'LargeFilePlain'
    $r = Fire -HookPath $LargeFileHook -Cwd $lfProj
    # These three replace the assertions on the wording the 800-line hard-ceiling
    # rule retired ("REVIEW SIGNAL, not an architectural law", "wrappers,
    # forwarding files, arbitrary fragments...", "appending is correct when ...").
    Check 'pre-task note states the ceiling is HARD and enforced at write time' ($r.Out -match 'HARD CEILING per source file, enforced when you write') $r.Out
    Check 'pre-task note explicitly forbids a wrapper/forwarding file/fragment that ducks the number' (
        $r.Out -match 'never a thin wrapper, forwarding file, or fragment created to duck the number') $r.Out
    Check 'pre-task note closes a near-ceiling file to new code instead of allowing an append' ($r.Out -match 'is CLOSED to new code') $r.Out

    # =====================================================================
    Write-Host '--- Large-File-Check: Stop report is a client-aware, non-blocking advisory (never decision:block) ---' -ForegroundColor Cyan
    # A file that was already oversized is the AI's call, so that Stop report is an
    # advisory, never a decision:block (on Codex a Stop block coerces a new
    # prompt). No SessionStart baseline is taken below, so the one Stop gate -
    # files this task pushed past the ceiling - cannot fire here either. Each
    # client shape uses its OWN project so the per-project cooldown never
    # suppresses the second fire.
    try {
        $lfHookLowThreshold = Join-Path $Work ('lfhookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $lfHookLowThreshold -Force | Out-Null
        Copy-Item $LargeFileHook (Join-Path $lfHookLowThreshold 'Large-File-Check.ps1')
        Copy-TestRuntimeLibraries -SourceHookLib (Join-Path (Split-Path -Parent $LargeFileHook) '..\_hooklib.ps1') -Destination (Join-Path $Work '_hooklib.ps1')
        Write-Utf8 (Join-Path $lfHookLowThreshold '.env') "LINE_THRESHOLD=50`r`n"
        $lfHook = Join-Path $lfHookLowThreshold 'Large-File-Check.ps1'
        # 60 lines against a threshold of 50 (the smallest LINE_THRESHOLD the hook
        # honours - values below its documented 50..100000 floor fall back to 800).
        $bigContent = (1..60 | ForEach-Object { 'line ' + $_ }) -join "`n"

        # --- Claude route: hookSpecificOutput.additionalContext, never a block ---
        Set-ClaudeProjectDir $Work
        $lfClaudeProj = New-Proj 'LargeFileOversizedClaude'
        Write-Utf8 (Join-Path $lfClaudeProj 'big.ps1') $bigContent
        $r = Fire -HookPath $lfHook -Cwd $lfClaudeProj -EventName 'Stop'
        $lfClaudeDoc = $null
        try { $lfClaudeDoc = $r.Out | ConvertFrom-Json } catch { $lfClaudeDoc = $null }
        $lfClaudeMsg = if ($null -ne $lfClaudeDoc -and $null -ne $lfClaudeDoc.PSObject.Properties['systemMessage']) { [string]$lfClaudeDoc.systemMessage } else { '' }
        Check 'Stop on CLAUDE emits systemMessage (no model continuation), never decision:block' (
            $null -ne $lfClaudeDoc -and $null -ne $lfClaudeDoc.PSObject.Properties['systemMessage'] -and
            $r.Out -notmatch 'hookSpecificOutput' -and $r.Out -notmatch '"decision"') $r.Out
        Check 'an oversized file is still detected and reported' ($lfClaudeMsg -match 'LARGE FILE CHECK' -and $lfClaudeMsg -match 'big\.ps1') $lfClaudeMsg
        Check 'the reason says a pre-existing oversized file is advisory and blocks nothing' ($lfClaudeMsg -match 'this is advisory and nothing here blocks') $lfClaudeMsg
        Check 'the reason states the ceiling binds what you WRITE, not what already exists' ($lfClaudeMsg -match 'the ceiling binds what you WRITE' -and $lfClaudeMsg -match 'the gate fires only on a file this task itself pushed past it') $lfClaudeMsg
        Check 'the reason forbids thin wrappers/pass-through/arbitrary fragments here too' ($lfClaudeMsg -match 'never create a thin wrapper, pass-through module or arbitrary fragment') $lfClaudeMsg
        Check 'the reason forbids starting an unrelated refactor merely because a file is large' ($lfClaudeMsg -match 'never start a refactor unrelated to the current task') $lfClaudeMsg
        Check 'a pre-existing oversized file is told to stop growing, not to be split on the spot' ($lfClaudeMsg -match 'stop growing' -and $lfClaudeMsg -match 'extract from the file rather than adding to it') $lfClaudeMsg
        # BYTE-COMPATIBILITY (real emission site 2 of 4): Large-File-Check's own
        # Write-Advisory Claude branch, fed the message it actually produced.
        # Run on the 5.1 host: hookSpecificOutput has TWO keys and .NET Core
        # randomises plain-@{} key order per process, so a cross-process byte
        # comparison is only meaningful where hashing is deterministic. A fresh
        # project keeps the hook's per-project cooldown from suppressing the fire.
        $lfClaudeProj51 = New-Proj 'LargeFileOversizedClaude51'
        Write-Utf8 (Join-Path $lfClaudeProj51 'big.ps1') $bigContent
        $lfR51 = Fire -HookPath $lfHook -Cwd $lfClaudeProj51 -EventName 'Stop' -Exe 'powershell.exe'
        $lfClaudeDoc51 = $null
        try { $lfClaudeDoc51 = $lfR51.Out | ConvertFrom-Json } catch { }
        $lfClaudeMsg51 = if ($null -ne $lfClaudeDoc51 -and $null -ne $lfClaudeDoc51.PSObject.Properties['systemMessage']) { [string]$lfClaudeDoc51.systemMessage } else { '' }
        $lfClaudeAdapted = Invoke-HookResult -Call @{ kind = 'advisory'; event = 'Stop'; message = $lfClaudeMsg51; client = 'claude' } -Exe 'powershell.exe'
        Check '5.1 host: Write-HookResult reproduces the real CLAUDE Stop advisory byte-for-byte' (
            $lfClaudeMsg51 -ne '' -and $lfClaudeAdapted.Out -ceq $lfR51.Out -and
            $lfClaudeAdapted.Result.Shape -eq 'claudeSystemMessage' -and $lfClaudeAdapted.Result.Emitted -eq $true) (
            'hook=[' + $lfR51.Out + '] adapter=[' + $lfClaudeAdapted.Out + ']')

        # --- Codex route: systemMessage, never a block (a block would loop Codex) ---
        Set-ClaudeProjectDir ''
        $lfCodexProj = New-Proj 'LargeFileOversizedCodex'
        Write-Utf8 (Join-Path $lfCodexProj 'big.ps1') $bigContent
        $rx = Fire -HookPath $lfHook -Cwd $lfCodexProj -EventName 'Stop'
        $lfCodexDoc = $null
        try { $lfCodexDoc = $rx.Out | ConvertFrom-Json } catch { $lfCodexDoc = $null }
        $lfCodexMsg = if ($null -ne $lfCodexDoc -and $null -ne $lfCodexDoc.PSObject.Properties['systemMessage']) { [string]$lfCodexDoc.systemMessage } else { '' }
        Check 'Stop on CODEX emits systemMessage (not hookSpecificOutput, not decision:block)' (
            $null -ne $lfCodexDoc -and $null -ne $lfCodexDoc.PSObject.Properties['systemMessage'] -and
            $null -eq $lfCodexDoc.PSObject.Properties['hookSpecificOutput'] -and $rx.Out -notmatch '"decision"') $rx.Out
        Check 'the CODEX advisory still carries the oversized-file report' ($lfCodexMsg -match 'LARGE FILE CHECK' -and $lfCodexMsg -match 'big\.ps1') $lfCodexMsg
        # BYTE-COMPATIBILITY (real emission site 3 of 4): the same hook's Codex
        # branch - the one shape a Codex client actually understands at Stop.
        $lfCodexAdapted = Invoke-HookResult -Call @{ kind = 'advisory'; event = 'Stop'; message = $lfCodexMsg; client = 'codex' }
        Check 'Write-HookResult reproduces the real CODEX Stop systemMessage byte-for-byte' (
            $rx.Out -ne '' -and $lfCodexAdapted.Out -ceq $rx.Out -and
            $lfCodexAdapted.Result.Shape -eq 'codexSystemMessage' -and $lfCodexAdapted.Result.Emitted -eq $true) (
            'hook=[' + $rx.Out + '] adapter=[' + $lfCodexAdapted.Out + ']')
    }
    finally {
        Set-ClaudeProjectDir $OrigClaudeProjectDir
        $env:LOCALAPPDATA = $lfOrigLocalAppData
    }

