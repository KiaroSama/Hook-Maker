# Historical matched success is not fresh proof or an unfinished run. Uses the
# existing isolated completion harness, artificial ages and real hook entry.
# No process sentinels, clock waits, real state or installation changes.

function Write-SelectionPair {
    param($Copy, [string]$Root, [string]$Id, [string]$Command, [double]$Age = 0,
        [string]$Overall = 'ok', [string]$Reason = '', [object[]]$Leaked = @())
    Write-ObservedRecord -Copy $Copy -Root $Root -RunId $Id -CommandFingerprint $Command -AgeMinutes $Age
    Write-GuardedResult -Copy $Copy -Root $Root -RunId $Id -CommandFingerprint $Command -AgeMinutes $Age -Overall $Overall -TerminateReason $Reason -Leaked $Leaked
}

function Invoke-OriginalRetentionRegression {
    param([switch]$Codex, [string]$HostExe = 'pwsh')
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('OriginalRetention-' + $Codex)
    Write-ObservedRecord -Copy $c -Root $p -RunId bound-old -CommandFingerprint old-command -Fingerprint old-git-state -AgeMinutes 1500
    Write-GuardedResult -Copy $c -Root $p -RunId bound-old -CommandFingerprint old-command -ProjectFingerprint old-git-state -AgeMinutes 1500
    Write-SelectionPair $c $p current-good current-command
    $paths = @((Get-RunStateFile $c $p observed bound-old), (Get-RunStateFile $c $p result bound-old))
    foreach ($path in $paths) { (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8) }
    $hashes = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $r = Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe
    Check 'logical old-state retirement preserves every original file' (@($paths | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0) ($r.Out + $r.Err)
    $unchanged = $true
    for ($i=0; $i -lt $paths.Count; $i++) { if (-not (Test-Path -LiteralPath $paths[$i]) -or (Get-FileHash -LiteralPath $paths[$i] -Algorithm SHA256).Hash -ne $hashes[$i]) { $unchanged = $false } }
    Check 'retained old-state originals remain byte-identical without current proof' ($unchanged -and $r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -eq '') ($r.Out + $r.Err)
}

function Invoke-RepositoryEvidenceSelectionRegression {
    param([switch]$Codex, [string]$HostExe = 'pwsh')
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('RepositoryEvidence-' + $Codex)
    $key = Get-ProjectKey $p
    Write-ObservedRecord -Copy $c -Root $p -RunId legacy-insights -CommandFingerprint insights-command -Fingerprint $key -AgeMinutes 600
    Write-GuardedResult -Copy $c -Root $p -RunId legacy-insights -CommandFingerprint insights-command -ProjectFingerprint ' ' -AgeMinutes 600
    Write-SelectionPair $c $p unrelated-logo logo-command
    $paths = @((Get-RunStateFile $c $p observed legacy-insights), (Get-RunStateFile $c $p result legacy-insights))
    $hashes = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })
    $savedOwner = $env:GIT_TEST_ASSUME_DIFFERENT_OWNER
    $savedConfigCount = $env:GIT_CONFIG_COUNT; $savedConfigKey = $env:GIT_CONFIG_KEY_0; $savedConfigValue = $env:GIT_CONFIG_VALUE_0
    try {
        $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = '1'
        $env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'safe.directory'; $env:GIT_CONFIG_VALUE_0 = ''
        $r = Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe
        $reason = Get-BlockReason $r.Out
        Check 'unavailable Git names exact legacy run, command, timestamp and missing field' (
            $r.Err -eq '' -and $reason -match 'runId=legacy-insights' -and $reason -match 'commandFingerprint=insights-command' -and
            $reason -match 'observedUtc=\d{4}-' -and $reason -match 'failedField=projectFingerprint:missing' -and $reason -match 'state=unavailable') ($r.Out + $r.Err)
        $again = Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe -StopHookActive
        Check 'unchanged unavailable Stop is quiet without manufacturing obligations' ($again.Out -eq '' -and $again.Err -eq '' -and (Get-PendingCount (Get-CompletionStateDoc $c $p)) -eq 0) ($again.Out + $again.Err)
        $auditCopy = New-IsolatedHookCopy
        [void](Copy-Tree (Get-StateDir $c) (Get-StateDir $auditCopy))
        $malformed = Get-RunStateFile $auditCopy $p observed malformed-legacy
        Write-Utf8 $malformed '{broken'
        Write-ObservedRecord -Copy $auditCopy -Root $p -RunId live-old -CommandFingerprint live-command -Fingerprint $key -AgeMinutes 5
        Write-SelectionPair $auditCopy $p live-new live-command
        Write-ActiveMarker -Copy $auditCopy -Root $p -RunId live-old -ProcessId $PID
        Write-SelectionPair $auditCopy $p leak-old leak-command -Age 5 -Leaked @(424242)
        Write-SelectionPair $auditCopy $p leak-new leak-command
        $audit = Join-Path $Work ('audit-' + $Codex + '.json')
        $oldLocal = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $auditCopy.LocalAppData
            $auditWrapper = Join-Path $Work ('audit-wrapper-' + $Codex + '.ps1')
            Write-Utf8 $auditWrapper ("try { & '" + $auditCopy.Script.Replace("'","''") + "' -AuditEvidence -ProjectRoot '" + $p.Replace("'","''") + "' -AuditPath '" + $audit.Replace("'","''") + "' } catch { Write-Output (`$_.Exception.Message + ' ' + `$_.ScriptStackTrace); exit 1 }")
            $output = Invoke-QuietCommand -FilePath $HostExe -ArgumentList @('-NoProfile','-File',$auditWrapper) -TimeoutSeconds 30
            $auditExit = $LASTEXITCODE
        }
        finally { $env:LOCALAPPDATA = $oldLocal }
        $report = Read-JsonFile $audit
        Check 'read-only audit completes with a real report' ($auditExit -eq 0 -and $null -ne $report) ($output -join ' ')
        if ($null -eq $report) { throw ('Read-only audit failed: ' + ($output -join ' ')) }
        Check 'audit hashes malformed originals and records their uncertainty' (@($report.originals | Where-Object { $_.path -eq $malformed -and $_.parseState -eq 'malformed' }).Count -eq 1 -and @($report.observations | Where-Object { $_.failedField -eq 'evidenceDocument:malformed' -and $_.verdict -eq 'UNKNOWN' }).Count -eq 1)
        Check 'audit cannot supersede a live or own-paired leaking original' (@($report.observations | Where-Object { $_.runId -in @('live-old','leak-old') -and $_.verdict -eq 'UNKNOWN' }).Count -eq 2)
        Check 'audit preserves UNKNOWN and never waives the gate' ($auditExit -eq 0 -and $null -ne $report -and (Get-Field $report 'gateWaived') -eq $false -and @($report.observations | Where-Object { $_.runId -eq 'legacy-insights' -and $_.verdict -eq 'UNKNOWN' }).Count -eq 1) ($output -join ' ')
    }
    finally { $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = $savedOwner; $env:GIT_CONFIG_COUNT = $savedConfigCount; $env:GIT_CONFIG_KEY_0 = $savedConfigKey; $env:GIT_CONFIG_VALUE_0 = $savedConfigValue }
    $changed = Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe -StopHookActive
    Check 'readable Git reevaluates legacy obligation rather than discarding path binding' ((Get-BlockReason $changed.Out) -match 'legacy-insights' -and (Get-BlockReason $changed.Out) -match 'state=available') ($changed.Out + $changed.Err)
    Check 'both original receipt and observation remain byte-identical' ((Get-FileHash -LiteralPath $paths[0]).Hash -eq $hashes[0] -and (Get-FileHash -LiteralPath $paths[1]).Hash -eq $hashes[1])
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('RepositoryEvidence-failed-' + $Codex)
    Write-GuardedResult -Copy $c -Root $p -RunId legacy-daily -CommandFingerprint daily-command -ProjectFingerprint ' ' -Overall failed -ExitCode 1 -AgeMinutes 12000
    (Get-Item -LiteralPath (Get-RunStateFile $c $p result legacy-daily)).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-9)
    Write-SelectionPair $c $p unrelated-logo logo-command
    $r = Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe
    Check 'old unidentified failure cannot disappear behind unrelated fresh success' ((Get-BlockReason $r.Out) -match 'runId=legacy-daily' -and (Get-BlockReason $r.Out) -match 'Unrelated green CI') ($r.Out + $r.Err)
    Check 'old whitespace-bound negative original survives retention' (Test-Path -LiteralPath (Get-RunStateFile $c $p result legacy-daily))
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('RepositoryEvidence-malformed-' + $Codex)
    Write-Utf8 (Get-RunStateFile $c $p result malformed-only) '{broken'
    $r = Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe
    Check 'malformed-only original remains an explicit unknown gate' ((Get-BlockReason $r.Out) -match 'failedField=evidenceDocument:malformed' -and $r.Err -eq '') ($r.Out + $r.Err)
}

# Exercise literal selector permutations as well as entry-point file ordering.
# Load the real pure identity functions from the entry AST, never execute its Stop.
& {
    . (Join-Path (Split-Path -Parent $Hook) '_identity.ps1')
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
    . (Join-Path $PSScriptRoot '_testcompletionaudit.ps1')
    Invoke-AuditAssignmentRegression -Codex:$codexShape -HostExe $hostExe
    Invoke-OriginalRetentionRegression -Codex:$codexShape -HostExe $hostExe
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

    Invoke-RepositoryEvidenceSelectionRegression -Codex:$codexShape -HostExe $hostExe

    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-same-command-' + $client)
    Write-ObservedRecord -Copy $c -Root $p -RunId 'orphan' -AgeMinutes 5
    Write-SelectionPair $c $p 'replacement' (Get-TestCommandFp $p)
    $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    Check ($client + ': later own paired success still clears only its same-command orphan') (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
}
