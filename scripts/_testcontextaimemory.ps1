# Test-ContextHooks section: Ai-Memory-Check.
#
# Dot-sourced from Test-ContextHooks.ps1 INSIDE its try block, so it runs in
# that scope and uses its harness directly: $Work, $Fire, Check, New-Proj,
# Write-Utf8, Set-ClaudeProjectDir and the counters. Pure relocation - the
# lines below are byte-identical to the ones this file replaced, indentation
# included, so the move can be proved rather than reviewed line by line.
#
# The underscore prefix keeps it out of the runner's Test-*.ps1 glob, so it
# needs no ci.yml bucket entry of its own.

    # =====================================================================
    Write-Host '--- Ai-Memory-Check: a staged rename in git status --porcelain does not crash Get-LatestWorkTimeUtc (5.1 illegal-path regression) ---' -ForegroundColor Cyan
    # Regression: a rename/copy porcelain line is "R  old -> new"; treating the
    # whole "old -> new" text as one literal relative path embeds the arrow's '>'
    # via Join-Path, and Test-Path -LiteralPath then throws on PS 5.1 ('>' is an
    # illegal path character) - crashing Get-LatestWorkTimeUtc and, with it, every
    # unguarded caller (Ai-Memory-Check, Graph-Update-Check) at Stop.
    $amcOrigLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = (Join-Path $Work 'amc-fakelocal')
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    try {
        $renameProj = New-Proj 'RenameRepo'
        & git -C $renameProj init -q -b main 2>$null | Out-Null
        & git -C $renameProj config user.email 't@t' 2>$null | Out-Null
        & git -C $renameProj config user.name 't' 2>$null | Out-Null
        & git -C $renameProj config core.autocrlf false 2>$null | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $renameProj '.ai') -Force | Out-Null
        Write-Utf8 (Join-Path $renameProj 'a.ps1') "function A { 1 }`n"
        & git -C $renameProj add -A 2>$null | Out-Null
        & git -C $renameProj commit -q -m init 2>$null | Out-Null
        & git -C $renameProj mv a.ps1 b.ps1 2>$null | Out-Null

        $renameHookDir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $renameHookDir -Force | Out-Null
        Copy-Item $AiMemoryHook (Join-Path $renameHookDir 'Ai-Memory-Check.ps1')
        Copy-TestRuntimeLibraries -SourceHookLib $HookLib -Destination (Join-Path $Work '_hooklib.ps1')

        $r = Fire -HookPath (Join-Path $renameHookDir 'Ai-Memory-Check.ps1') -Cwd $renameProj -EventName 'Stop' -Exe 'powershell.exe'
        Check '5.1 host: a staged rename never crashes Get-LatestWorkTimeUtc (clean exit, no StrictMode/illegal-path error)' (
            $r.Exit -eq 0 -and $r.Err -eq '') ($r.Out + ' | err=' + $r.Err)
        Check 'the reminder logic still runs (missing .ai/memory.md is still detected and blocks)' (
            $r.Out -match '"decision":"block"' -and $r.Out -match 'memory\.md') $r.Out
        # BYTE-COMPATIBILITY (real emission site 4 of 4): a genuine decision:block,
        # captured on the 5.1 host. 5.1 and pwsh 7 escape and ORDER JSON keys
        # differently, so proving the adapter on both hosts is what makes the
        # "byte-identical" claim meaningful rather than host-specific luck.
        $amcDoc = $null
        try { $amcDoc = $r.Out | ConvertFrom-Json } catch { }
        $amcReason = if ($null -ne $amcDoc -and $null -ne $amcDoc.PSObject.Properties['reason']) { [string]$amcDoc.reason } else { '' }
        $amcAdapted = Invoke-HookResult -Call @{ kind = 'block'; event = 'Stop'; reason = $amcReason; client = 'claude' } -Exe 'powershell.exe'
        Check '5.1 host: Write-HookResult reproduces the real decision:block byte-for-byte' (
            $amcReason -ne '' -and $amcAdapted.Out -ceq $r.Out -and
            $amcAdapted.Result.Shape -eq 'decisionBlock' -and $amcAdapted.Result.Degraded -eq $false) (
            'hook=[' + $r.Out + '] adapter=[' + $amcAdapted.Out + ']')
    }
    finally {
        $env:LOCALAPPDATA = $amcOrigLocalAppData
    }

