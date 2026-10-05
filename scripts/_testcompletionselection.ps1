# Historical matched success is not fresh proof or an unfinished run. Uses the
# existing isolated completion harness, artificial ages and real hook entry.
# No process sentinels, clock waits, real state or installation changes.

function Write-SelectionPair {
    param($Copy, [string]$Root, [string]$Id, [string]$Command, [double]$Age = 0,
        [string]$Overall = 'ok', [string]$Reason = '', [object[]]$Leaked = @())
    Write-ObservedRecord -Copy $Copy -Root $Root -RunId $Id -CommandFingerprint $Command -AgeMinutes $Age
    Write-GuardedResult -Copy $Copy -Root $Root -RunId $Id -CommandFingerprint $Command -AgeMinutes $Age -Overall $Overall -TerminateReason $Reason -Leaked $Leaked
}

# Exercise literal selector permutations as well as entry-point file ordering.
# Load the real pure identity functions from the entry AST, never execute its Stop.
& {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Hook, [ref]$null, [ref]$null)
    foreach ($name in @('ConvertTo-UtcTime', 'Test-ResultMatchesObserved')) {
        $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    . (Join-Path (Split-Path -Parent $Hook) '_evidence.ps1')
    . (Join-Path (Split-Path -Parent $Hook) '_runclassify.ps1')
    $script:evidenceMinutes = 180
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'Selection-literal-order'
    $stateFingerprint = Get-Fingerprint $p
    $pairs = @()
    foreach ($id in @('old', 'fresh')) {
        $age = if ($id -eq 'old') { 600 } else { 0 }
        Write-SelectionPair $c $p $id ($id + '-command') -Age $age
        $obs = Get-Content -LiteralPath (Get-RunStateFile $c $p 'observed' $id) -Raw -Encoding UTF8 | ConvertFrom-Json
        $path = Get-RunStateFile $c $p 'result' $id
        $entry = [pscustomobject]@{ Path = $path; Doc = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
        $pairs += [pscustomobject]@{ Observed = $obs; ResultEntry = $entry; HasObserved = $true; Matches = $true }
    }
    foreach ($order in @(@(0, 1), @(1, 0))) {
        $chosen = Select-RepresentativeRun -Runs @($pairs[$order[0]], $pairs[$order[1]])
        Check ('literal selector order ' + ($order -join ',') + ' selects fresh proof') (
            $chosen.Rep.Class -eq 'clean' -and $chosen.Rep.Run.ResultEntry.Doc.runId -eq 'fresh')
    }
}

Write-Host '--- historical success versus fresh proof ---' -ForegroundColor Cyan
foreach ($codexShape in @($false, $true)) {
    $client = if ($codexShape) { 'Codex' } else { 'Claude' }
    $hostExe = if ($codexShape) { 'pwsh' } else { 'powershell.exe' }
    foreach ($reverse in @($false, $true)) {
        $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-' + $client + '-' + $reverse)
        # Reverse filenames AND creation order, so enumeration cannot decide which
        # receipt wins. Ages place both inside the 24h retention horizon.
        $oldId = if ($reverse) { 'z-old' } else { 'a-old' }
        $newId = if ($reverse) { 'a-new' } else { 'z-new' }
        if ($reverse) { Write-SelectionPair $c $p $newId 'fresh-command' }
        Write-SelectionPair $c $p $oldId 'historical-command' -Age 600
        if (-not $reverse) { Write-SelectionPair $c $p $newId 'fresh-command' }
        $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
        Check ($client + ': old paired success cannot defeat fresh different-command success (reverse=' + $reverse + ')') (
            $r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') $r.Out
    }
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-old-only-' + $client)
    Write-SelectionPair $c $p 'only-old' 'old-only' -Age 600
    $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    Check ($client + ': historical success alone remains STALE, never fresh proof') (
        $r.Exit -eq 0 -and $r.Out -match '"decision"\s*:\s*"block"' -and (Get-BlockReason $r.Out) -match 'STALE') $r.Out

    foreach ($bad in @('missing', 'mismatch', 'identity', 'old-identity', 'failed', 'old-failed', 'wallTimeout', 'idleTimeout', 'terminated', 'leak', 'old-leak')) {
        $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-' + $client + '-' + $bad)
        Write-SelectionPair $c $p 'fresh-good' 'good-command'
        $age = if ($bad -like 'old-*') { 600 } else { 5 }
        Write-ObservedRecord -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -AgeMinutes $age
        switch ($bad) {
            'missing' { }
            'mismatch' { Write-GuardedResult -Copy $c -Root $p -RunId 'wrong-run' -CommandFingerprint 'different-unsafe-command' -AgeMinutes $age }
            { $_ -in @('identity', 'old-identity') } {
                Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -ProjectFingerprint ' ' -AgeMinutes $age
            }
            { $_ -in @('failed', 'old-failed') } { Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -Overall 'failed' -ExitCode 1 -AgeMinutes $age }
            { $_ -in @('leak', 'old-leak') } { Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -Leaked @(424242) -AgeMinutes $age }
            default { Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -Overall 'terminated' -ExitCode 124 -TerminateReason $bad -AgeMinutes $age }
        }
        $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
        Check ($client + ': fresh success never hides ' + $bad + ' of another command') (
            $r.Exit -eq 0 -and $r.Out -match '"decision"\s*:\s*"block"' -and $r.Err -eq '') $r.Out
    }

    # One-to-one assignment: same-time uncontrolled observations cannot both
    # consume one result. Existing supersede requires a STRICTLY later observation.
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-one-to-one-' + $client)
    Write-ObservedRecord -Copy $c -Root $p -RunId 'one' -RunIdControlled $false
    $onePath = Get-RunStateFile -Copy $c -Root $p -Kind 'observed' -RunId 'one'
    $twoPath = Get-RunStateFile -Copy $c -Root $p -Kind 'observed' -RunId 'two'
    $doc = Get-Content -LiteralPath $onePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $doc.runId = 'two'
    Write-Utf8 $twoPath ($doc | ConvertTo-Json -Depth 6)
    Write-GuardedResult -Copy $c -Root $p -RunId 'one'
    $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    Check ($client + ': one success still cannot satisfy two concurrent observations') (
        $r.Exit -eq 0 -and $r.Out -match '"decision"\s*:\s*"block"') $r.Out

    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-bound-pre-post-' + $client)
    $guardDir = Join-Path $Work ('actual-guard-' + $client)
    [void][IO.Directory]::CreateDirectory($guardDir)
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $HooksRoot 'Test-Run-Guard') -Filter '*.ps1' -File)) { [IO.File]::Copy($file.FullName, (Join-Path $guardDir $file.Name), $true) }
    $guard = Join-Path $guardDir 'Test-Run-Guard.ps1'
    $id = 'actualbound' + $client.ToLowerInvariant()
    $runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Run-Tests-Guarded.ps1'
    $command = "& '" + $runner.Replace("'","''") + "' -FilePath cmd.exe -ArgumentsJson '[`"/c`",`"exit`",`"0`"]' -WorkingDirectory '" + $p.Replace("'","''") + "' -RunId " + $id + ' -ProjectFingerprint ' + (Get-Fingerprint $p) + ' -TimeoutSeconds 20 -IdleTimeoutSeconds 10 -HeartbeatSeconds 1 -MaxWorkers 1 -Quiet'
    $pre = Fire -Copy $c -Cwd $p -EventName PreToolUse -Command $command -Codex:$codexShape -Exe $hostExe -HookPath $guard
    $wrapper = Join-Path $Work ('bound-' + $client + '.ps1')
    Write-Utf8 $wrapper ($command + "`nexit `$LASTEXITCODE`n")
    $savedLocal = $env:LOCALAPPDATA; $savedState = $env:HOOKMAKER_STATE_DIR
    try {
        $env:LOCALAPPDATA = $c.LocalAppData; $env:HOOKMAKER_STATE_DIR = Get-StateDir $c
        $null = Invoke-QuietCommand -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$wrapper) -TimeoutSeconds 30
        $boundExit = $LASTEXITCODE
    }
    finally { $env:LOCALAPPDATA=$savedLocal; $env:HOOKMAKER_STATE_DIR=$savedState }
    $post = Fire -Copy $c -Cwd $p -EventName PostToolUse -Command $command -Codex:$codexShape -Exe $hostExe -HookPath $guard
    $stop = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    $obsPath = Get-RunStateFile $c $p 'observed' $id
    $resultPath = Get-RunStateFile $c $p 'result' $id
    $obs = Read-JsonFile $obsPath; $result = Read-JsonFile $resultPath
    Check ($client + ': actual harmless Pre/runner/Post/Stop is correctly bound') ($pre.Exit -eq 0 -and $pre.Out -eq '' -and $pre.Err -eq '' -and $boundExit -eq 0 -and $post.Exit -eq 0 -and $post.Out -eq '' -and $post.Err -eq '' -and $stop.Out -eq '' -and $stop.Err -eq '' -and $null -ne $obs -and $null -ne $result -and $obs.runId -eq $result.runId -and $obs.commandFingerprint -eq $result.commandFingerprint -and $obs.projectFingerprint -eq $result.projectFingerprint) ($pre.Out + $post.Out + $stop.Out)

    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-same-command-' + $client)
    Write-ObservedRecord -Copy $c -Root $p -RunId 'orphan' -AgeMinutes 5
    Write-SelectionPair $c $p 'replacement' (Get-TestCommandFp $p)
    $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    Check ($client + ': later own paired success still clears only its same-command orphan') (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
}
