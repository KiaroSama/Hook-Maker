# Test-TestRunGuard.ps1 scenario block: the COORDINATION HANDOFF that
# Test-Completion-Check consumes - the per-run observed record and its
# filename/fields/fingerprint/timestamp contract, direct PowerShell
# test-script recognition (scope D), and the run-identity contract carried
# into both the observed record and the replacement (scope A).
#
# Defines Get-ObservedRecord and ConvertTo-UtcTimeLikeConsumer, used again
# by the later scenario blocks.
#
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- coordination handoff: the observed record Test-Completion-Check reads ---' -ForegroundColor Cyan
    function Get-ObservedRecord {
        param([string]$LocalAppData)
        $files = @(Get-ChildItem -LiteralPath (Join-Path $LocalAppData 'HookMaker\state') -Filter 'TestRunGuard-observed-*.json' -ErrorAction SilentlyContinue)
        if ($files.Count -ne 1) { return $null }
        return [pscustomobject]@{ File = $files[0]; Document = (Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json) }
    }
    # The consumer's own key derivation, so a divergence fails here.
    $expectedKey = & {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Proj.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 10) }
        finally { $sha.Dispose() }
    }

    $hcObs = New-IsolatedHookCopy
    $r = Fire -HookPath $hcObs.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcObs.LocalAppData
    $observed = Get-ObservedRecord $hcObs.LocalAppData
    Check 'a blocked RAW test command writes an observed record' ($null -ne $observed)
    Check 'the observed file name is PER-RUN (includes the key AND the runId the consumer reads)' (
        $observed.File.Name -eq ('TestRunGuard-observed-' + $expectedKey + '-' + (Get-SafeRunId ([string]$observed.Document.runId)) + '.json')) $observed.File.Name
    Check 'the observed record carries observedUtc, fingerprint and guarded' (
        $null -ne $observed.Document.PSObject.Properties['observedUtc'] -and
        $null -ne $observed.Document.PSObject.Properties['fingerprint'] -and
        $null -ne $observed.Document.PSObject.Properties['guarded']) ($observed.Document | ConvertTo-Json -Compress)
    Check 'a blocked raw command is recorded as NOT guarded' ($observed.Document.guarded -eq $false) ([string]$observed.Document.guarded)
    Check 'the fingerprint is non-empty' (-not [string]::IsNullOrWhiteSpace([string]$observed.Document.fingerprint)) ([string]$observed.Document.fingerprint)

    # TIMESTAMP CONTRACT. Replays the consumer's ConvertTo-UtcTime verbatim: an
    # 'o' string arrives from ConvertFrom-Json already Kind=Utc and is returned
    # untouched. Ticks would not parse at all. Drift must be seconds, not the
    # 210 minutes a double offset subtraction produced.
    function ConvertTo-UtcTimeLikeConsumer {
        param($Value)
        if ($null -eq $Value) { return $null }
        $parsed = [DateTime]::MinValue
        if ($Value -is [DateTime]) { $parsed = $Value }
        else {
            $text = [string]$Value
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            if (-not [DateTime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $null }
        }
        if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { return $parsed }
        if ($parsed.Kind -eq [System.DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
        return [DateTime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
    }
    $observedTime = ConvertTo-UtcTimeLikeConsumer $observed.Document.observedUtc
    Check 'the consumer can parse observedUtc at all (ticks could not)' ($null -ne $observedTime)
    $driftMinutes = [Math]::Abs(([DateTime]::UtcNow - $observedTime).TotalMinutes)
    Check 'the timestamp round-trips with no timezone drift (< 2 minutes, not 210)' ($driftMinutes -lt 2) ([string]$driftMinutes)

    $hcObsGuarded = New-IsolatedHookCopy
    $r = Fire -HookPath $hcObsGuarded.Script -Cwd $Proj -EventName 'PreToolUse' `
        -Command 'pwsh -File .\scripts\Run-Tests-Guarded.ps1 -FilePath pytest -ArgumentsJson ''["-q"]''' -LocalAppData $hcObsGuarded.LocalAppData
    $observedGuarded = Get-ObservedRecord $hcObsGuarded.LocalAppData
    Check 'an ALREADY-GUARDED command still writes an observed record' ($null -ne $observedGuarded)
    Check 'it is recorded as guarded=true' ($observedGuarded.Document.guarded -eq $true) ([string]$observedGuarded.Document.guarded)
    Check 'writing the observed record stays silent (it is a handoff, not a finding)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $hcObsNone = New-IsolatedHookCopy
    $null = Fire -HookPath $hcObsNone.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'git status' -LocalAppData $hcObsNone.LocalAppData
    Check 'an unrelated command writes NO observed record' ($null -eq (Get-ObservedRecord $hcObsNone.LocalAppData))

    # The fingerprint must equal what the consumer computes for the same state,
    # or condition 5 silently never matches.
    $gitProj = Join-Path $Work 'GitProject'
    New-Item -ItemType Directory -Path $gitProj -Force | Out-Null
    & git -C $gitProj init -q -b main
    & git -C $gitProj config user.email 't@t'
    & git -C $gitProj config user.name 't'
    Write-Utf8 (Join-Path $gitProj 'a.txt') 'a'
    & git -C $gitProj add -A
    & git -C $gitProj commit -q -m 'init'
    $hcFp = New-IsolatedHookCopy
    $null = Fire -HookPath $hcFp.Script -Cwd $gitProj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcFp.LocalAppData
    $observedFp = Get-ObservedRecord $hcFp.LocalAppData
    . (Join-Path $HooksRoot '_hooklib.ps1')
    $consumerFingerprint = [string](Get-RepoStateFingerprint -ProjectRoot $gitProj)
    Check 'in a git repo the fingerprint equals Get-RepoStateFingerprint, as the consumer computes it' (
        $null -ne $observedFp -and [string]$observedFp.Document.fingerprint -eq $consumerFingerprint) (
        ([string]$observedFp.Document.fingerprint) + ' vs ' + $consumerFingerprint)

    # =====================================================================
    Write-Host '--- direct PowerShell test-script execution is recognised (scope D) ---' -ForegroundColor Cyan
    $hcD = New-IsolatedHookCopy
    foreach ($cmd in @('.\scripts\Test-Wizard.ps1', './scripts/Run-Tests.ps1', 'C:\repo\scripts\Test-RulesCheck.ps1 -KeepArtifacts', '& ".\scripts\Test-RulesCheck.ps1"')) {
        $r = Fire -HookPath $hcD.Script -Cwd $Proj -EventName 'PreToolUse' -Command $cmd -LocalAppData $hcD.LocalAppData
        $repl = Get-Replacement (Get-Message $r.Out)
        Check ('direct form is guarded: ' + $cmd) ((Get-Message $r.Out) -match 'TEST RUN GUARD' -and $repl -match 'Run-Tests-Guarded') $r.Out
    }
    $r = Fire -HookPath $hcD.Script -Cwd $Proj -EventName 'PreToolUse' -Command '.\scripts\Test-Wizard.ps1 -KeepArtifacts' -LocalAppData $hcD.LocalAppData
    $repl = Get-Replacement (Get-Message $r.Out)
    Check 'the direct-script replacement runs it via pwsh -File with the original args intact' (
        $repl -match '-FilePath "pwsh"' -and $repl -match 'Test-Wizard\.ps1' -and $repl -match 'KeepArtifacts') $repl
    foreach ($cmd in @('generate-test-fixtures.ps1', 'contest.ps1', '.\testdata\seed.ps1', 'pwsh -Command "Test-Thing"', 'echo test')) {
        $r = Fire -HookPath $hcD.Script -Cwd $Proj -EventName 'PreToolUse' -Command $cmd -LocalAppData $hcD.LocalAppData
        Check ('a non-test path stays silent: ' + $cmd) ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    }

    # =====================================================================
    Write-Host '--- run-identity contract is carried into the observed record + replacement (scope A) ---' -ForegroundColor Cyan
    $hcId = New-IsolatedHookCopy
    $r = Fire -HookPath $hcId.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcId.LocalAppData
    $obsId = Get-ObservedRecord $hcId.LocalAppData
    Check 'the observed record is schema 2 with a runId, a command fingerprint, and runIdControlled' (
        $null -ne $obsId -and $obsId.Document.schema -eq 2 -and
        -not [string]::IsNullOrWhiteSpace([string]$obsId.Document.runId) -and
        -not [string]::IsNullOrWhiteSpace([string]$obsId.Document.commandFingerprint) -and
        $obsId.Document.runIdControlled -eq $true) ($obsId.Document | ConvertTo-Json -Compress)
    $replId = Get-Replacement (Get-Message $r.Out)
    Check 'the replacement injects -RunId and -ProjectFingerprint as data' ($replId -match '-RunId ' -and $replId -match '-ProjectFingerprint ') $replId
    Check 'the injected runId equals the observed runId' ($replId -match ('-RunId ' + [regex]::Escape([string]$obsId.Document.runId))) $replId
    # A guarded replacement PRESERVES the injected runId instead of minting a
    # fresh one that could never match the runner's result.
    $injRun = [string]$obsId.Document.runId
    $injFp = [string]$obsId.Document.projectFingerprint
    $null = Fire -HookPath $hcId.Script -Cwd $Proj -EventName 'PreToolUse' `
        -Command ('pwsh -File .\scripts\Run-Tests-Guarded.ps1 -FilePath pytest -ArgumentsJson ''["-q"]'' -RunId ' + $injRun + ' -ProjectFingerprint ' + $injFp) -LocalAppData $hcId.LocalAppData
    $obsId2 = Get-ObservedRecord $hcId.LocalAppData
    Check 'a guarded replacement preserves the injected runId (does not mint a fresh one)' (
        $null -ne $obsId2 -and $obsId2.Document.runId -eq $injRun -and $obsId2.Document.guarded -eq $true) ([string]$obsId2.Document.runId)

    # PostToolUse rejects a result whose identity does not match the observation.
    $hcMis = New-IsolatedHookCopy
    $null = Fire -HookPath $hcMis.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcMis.LocalAppData
    $null = New-ResultDocument -LocalAppData $hcMis.LocalAppData -ProjectRoot $Proj -Fields @{ overall = 'ok'; runId = 'a-totally-different-run' }
    $r = Fire -HookPath $hcMis.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcMis.LocalAppData
    Check 'PostToolUse rejects a result from a DIFFERENT run as not-evidence' ((Get-Message $r.Out) -match 'DIFFERENT run') $r.Out


    # =====================================================================
    # MENTIONING the guarded runner is not RUNNING it.
    #
    # Test-SegmentIsGuarded used to scan every token, so `grep ...
    # Run-Tests-Guarded.ps1` - which only READS the file - was recorded as an
    # observed guarded run. No run happened, so no result document could ever
    # appear, and Test-Completion-Check then blocked with "a test command was
    # observed ... but no guarded result document exists for it" - a state
    # nothing could clear except an unrelated real test run. Hit for real while
    # closing out this project.
    Write-Host '--- mentioning the guarded runner is not running it ---' -ForegroundColor Cyan
    foreach ($mention in @(
            'grep -n "projectFingerprint" scripts/Run-Tests-Guarded.ps1',
            'grep -rn "Run-Tests-Guarded.ps1" hooks/',
            'Get-Content scripts\Run-Tests-Guarded.ps1')) {
        $hcMention = New-IsolatedHookCopy
        $r = Fire -HookPath $hcMention.Script -Cwd $Proj -EventName 'PreToolUse' -Command $mention -LocalAppData $hcMention.LocalAppData
        Check ('a command that only mentions the runner stays silent: ' + $mention) ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
        Check ('...and writes NO observed record, so nothing waits for a result: ' + $mention) (
            $null -eq (Get-ObservedRecord $hcMention.LocalAppData))
        $rPost = Fire -HookPath $hcMention.Script -Cwd $Proj -EventName 'PostToolUse' -Command $mention -LocalAppData $hcMention.LocalAppData
        Check ('...and PostToolUse does not demand a result document for it: ' + $mention) (
            $rPost.Exit -eq 0 -and (Get-Message $rPost.Out) -notmatch 'no guarded result document') $rPost.Out
    }
    # The real invocations must still register, including the -f abbreviation and
    # running the runner directly - narrowing recognition must not lose them.
    foreach ($invocation in @(
            'pwsh -NoProfile -File scripts\Run-Tests-Guarded.ps1 -FilePath pwsh -ArgumentsJson ''["-File","x.ps1"]''',
            'pwsh -NoProfile -f scripts\Run-Tests-Guarded.ps1 -FilePath pwsh -ArgumentsJson ''["-File","x.ps1"]''',
            '.\scripts\Run-Tests-Guarded.ps1 -FilePath pwsh -ArgumentsJson ''["-File","x.ps1"]''')) {
        $hcInv = New-IsolatedHookCopy
        $r = Fire -HookPath $hcInv.Script -Cwd $Proj -EventName 'PreToolUse' -Command $invocation -LocalAppData $hcInv.LocalAppData
        Check ('a real guarded invocation is still recognised (silent, never re-wrapped): ' + $invocation) (
            $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    }

    # =====================================================================
    # An identity token the hook could not literally READ must not be claimed
    # as a controlled identity.
    #
    # The command arrives as text, before any shell expansion, so a hand-written
    # guarded run using `-RunId "$RUNID"` hands the hook the four characters
    # '$RUNID'. Recording that as this run's identity made observation and result
    # unpairable for ever - the runner receives the expanded GUID - and the
    # completion gate then blocked with "the only guarded result on record is for
    # a DIFFERENT run". Hit repeatedly while closing this project out.
    Write-Host '--- an unexpanded shell variable is not a run identity ---' -ForegroundColor Cyan
    $hcVar = New-IsolatedHookCopy
    $varCommand = 'pwsh -NoProfile -File .\scripts\Run-Tests-Guarded.ps1 -FilePath pwsh ' +
        '-ArgumentsJson ''["-File",".\scripts\Run-Tests.ps1"]'' -RunId "$RUNID" -ProjectFingerprint "$FP" -TimeoutSeconds 900'
    # PreToolUse: that is where an already-guarded command's observed record is
    # written (the identity has to exist before the run, not after it).
    $rVar = Fire -HookPath $hcVar.Script -Cwd $Proj -EventName 'PreToolUse' -Command $varCommand -LocalAppData $hcVar.LocalAppData
    $obsVar = Get-ObservedRecord $hcVar.LocalAppData
    Check 'a guarded run whose -RunId is an unexpanded variable is recorded UNCONTROLLED' (
        $null -ne $obsVar -and $obsVar.Document.runIdControlled -ne $true) (
        $(if ($null -eq $obsVar) { '<no observed record>' } else { $obsVar.Document | ConvertTo-Json -Compress }))
    Check 'and the literal token is never stored as the runId' (
        $null -ne $obsVar -and ([string]$obsVar.Document.runId) -notmatch '\$') (
        $(if ($null -eq $obsVar) { '<no observed record>' } else { [string]$obsVar.Document.runId }))
    Check 'the unexpanded projectFingerprint is not stored either' (
        $null -ne $obsVar -and ([string]$obsVar.Document.projectFingerprint) -notmatch '\$') (
        $(if ($null -eq $obsVar) { '<no observed record>' } else { [string]$obsVar.Document.projectFingerprint }))

    # =====================================================================
    # The project key must survive a NON-CANONICAL cwd.
    #
    # The producer (this hook) hashed the raw lowercased cwd while the consumer
    # (Test-Completion-Check) hashes Normalize-Path'd cwd, so they agreed only
    # when the incoming cwd happened to already be canonical. A trailing
    # separator, a '.' segment or a '..' round trip each produced a DIFFERENT
    # key: the observed records landed under a name the completion gate never
    # reads, and no number of test runs could close it. Reported from real use.
    #
    # The assertion above could not catch this - it passes a canonical $Proj, the
    # one spelling where both derivations agree.
    Write-Host '--- coordination: the project key is canonical, whatever the cwd spelling ---' -ForegroundColor Cyan
    $canonicalKey = & {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $canon = ([System.IO.Path]::GetFullPath($Proj)).TrimEnd([char[]]@(
                    [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
            return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 10)
        }
        finally { $sha.Dispose() }
    }
    foreach ($spelling in @(
            @{ Name = 'a trailing separator'; Cwd = ($Proj + '\') },
            @{ Name = 'a dot segment'; Cwd = (Join-Path $Proj '.') },
            @{ Name = 'an upper-cased path'; Cwd = $Proj.ToUpperInvariant() })) {
        $hcSpell = New-IsolatedHookCopy
        $null = Fire -HookPath $hcSpell.Script -Cwd ([string]$spelling.Cwd) -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcSpell.LocalAppData
        $spellObserved = Get-ObservedRecord $hcSpell.LocalAppData
        Check ('the observed record is keyed canonically despite ' + [string]$spelling.Name) (
            $null -ne $spellObserved -and
            $spellObserved.File.Name.StartsWith('TestRunGuard-observed-' + $canonicalKey + '-', [System.StringComparison]::Ordinal)) (
            $(if ($null -ne $spellObserved) { $spellObserved.File.Name + ' expected key ' + $canonicalKey } else { 'no observed record' }))
    }
