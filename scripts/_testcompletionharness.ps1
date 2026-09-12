# Test-TestCompletionCheck.ps1 shared harness: fixture builders (throwaway
# git repos with and without a git-ignored .ai/, stamped out of a per-run
# template instead of re-running git), the isolated hook copy +
# fake LOCALAPPDATA factory, the writers for every coordination document the
# hook reads (guarded result, observed record, active marker, cleanup
# result), the durable-note helpers, the process-readiness poll, the Fire
# process runner, and the output parsers.
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses
# its $Work / $Hook / $HookLib) - not a standalone suite.

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

# Whole-directory copy through raw .NET calls. Every fixture tree here is plain
# files - no reparse points, no ACL requirements - and Copy-Item's provider
# overhead dominates at these sizes (measured on this repo: the 5-file hook
# package is ~67ms through Copy-Item against ~28ms through this).
function Copy-Tree {
    param([string]$Source, [string]$Destination)
    [void][System.IO.Directory]::CreateDirectory($Destination)
    foreach ($dir in [System.IO.Directory]::GetDirectories($Source, '*', 'AllDirectories')) {
        [void][System.IO.Directory]::CreateDirectory($Destination + $dir.Substring($Source.Length))
    }
    foreach ($file in [System.IO.Directory]::GetFiles($Source, '*', 'AllDirectories')) {
        [System.IO.File]::Copy($file, ($Destination + $file.Substring($Source.Length)), $true)
    }
    return $Destination
}

# ONE template repo per shape, built on first use; each fixture is then a copy of
# it. A real init+config+add+commit is five git subprocesses (~810ms measured
# here) against ~90ms for the copy, and a full run builds ~170 of them.
#
# A copied repo is fully independent: `git init` writes no absolute path into
# .git/config, so each fixture owns its own .git, index, refs, objects and
# working tree exactly as a freshly-initialised one does - nothing mutable is
# shared. What a template DOES equalise is the commit SHA, and with it the
# HEAD+porcelain fingerprint. Nothing depends on two fixtures differing there:
# every 'a different project state' case passes an explicit literal
# -ProjectFingerprint/-Fingerprint, and the run id, command fingerprint and
# state-file key are all derived from the fixture PATH, which stays unique. (The
# fixtures were already content-identical, so two built inside the same second
# already shared a SHA - no test could have relied on that difference.)
$script:RepoTemplates = @{}
function Get-RepoTemplate {
    param([string]$Shape)
    if (-not $script:RepoTemplates.ContainsKey($Shape)) {
        $t = New-Proj ('_template-repo-' + $Shape)
        & git -C $t init -q -b main
        & git -C $t config user.email 't@t'
        & git -C $t config user.name 't'
        Write-Utf8 (Join-Path $t 'readme.txt') 'x'
        # .ai/ git-ignored, so writing a durable note between Stops does NOT move
        # the porcelain-based repo fingerprint. The D1/D2 ledger cases need
        # incident results recorded before the note to stay CURRENT-state across
        # the note write.
        if ($Shape -eq 'ai') { Write-Utf8 (Join-Path $t '.gitignore') ".ai/`n" }
        & git -C $t add -A
        & git -C $t commit -q -m 'init'
        # The 13 sample hooks `git init` leaves behind are most of the files in
        # the tree and no fixture ever runs a git hook. Dropped AFTER the commit,
        # so the committed state is exactly what it was before.
        Remove-Item -LiteralPath (Join-Path $t '.git\hooks') -Recurse -Force -ErrorAction SilentlyContinue
        $script:RepoTemplates[$Shape] = $t
    }
    return $script:RepoTemplates[$Shape]
}

function New-GitRepo {
    param([string]$Name)
    return (Copy-Tree (Get-RepoTemplate 'plain') (Join-Path $Work $Name))
}

# A repo that git-ignores .ai/ - see Get-RepoTemplate for why the D1/D2 ledger
# cases need it.
function New-GitRepoAi {
    param([string]$Name)
    return (Copy-Tree (Get-RepoTemplate 'ai') (Join-Path $Work $Name))
}

# The completion hook's own project-keyed state document (resolvedIncidents /
# pendingNotes ledger), or $null when it has not been written yet.
function Get-CompletionStateDoc {
    param([object]$Copy, [string]$Root)
    $path = Join-Path (Get-StateDir $Copy) ('TestCompletionCheck-' + (Get-ProjectKey $Root) + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}
# Element counts tolerant of the empty-array-as-'' / single-element-as-scalar JSON
# quirk. Resolved entries are non-empty strings; pending entries are objects with
# a non-empty key.
function Get-ResolvedCount {
    param($Doc)
    if ($null -eq $Doc -or $null -eq $Doc.PSObject.Properties['resolvedIncidents']) { return 0 }
    return @(@($Doc.resolvedIncidents) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
}
function Get-PendingCount {
    param($Doc)
    if ($null -eq $Doc -or $null -eq $Doc.PSObject.Properties['pendingNotes']) { return 0 }
    return @(@($Doc.pendingNotes) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['key'] -and -not [string]::IsNullOrWhiteSpace([string]$_.key) }).Count
}

# The hook package plus an EMPTY fake LOCALAPPDATA, built once per run. Both the
# template and every copy sit directly under $Work, so the single _hooklib.ps1
# one level up serves all of them - the hook dot-sources '..\_hooklib.ps1'. That
# file was already written to this one shared path on every call; it is
# read-only input no case mutates, so writing it once drops ~173 redundant 71 KB
# copies and shares nothing that was not already shared.
$script:HookCopyTemplate = ''
function Get-HookCopyTemplate {
    if ($script:HookCopyTemplate -eq '') {
        $t = New-Proj '_template-hookcopy'
        # The whole hook PACKAGE - the installer stages every .ps1 beside the entry
        # point, so a single-file copy would exercise a runtime that cannot exist.
        foreach ($pkgFile in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -File -Filter '*.ps1')) {
            Copy-Item $pkgFile.FullName (Join-Path $t $pkgFile.Name) -Force
        }
        New-Item -ItemType Directory -Path (Join-Path $t '_fakelocal\HookMaker\state') -Force | Out-Null
        Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
        $script:HookCopyTemplate = $t
    }
    return $script:HookCopyTemplate
}

# Isolated hook copy + fake LOCALAPPDATA per case, so coordination state files
# never collide between cases or with the real machine. Still one private
# directory and one private, EMPTY fake LOCALAPPDATA per call - byte-for-byte
# the layout the per-call build produced. The copies are deliberately never
# pooled: cases such as D3 count every TestRunGuard-*.json in their own state
# directory, and a shared one would let another case's files answer that.
function New-IsolatedHookCopy {
    param([hashtable]$EnvOverrides = @{})
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [void](Copy-Tree (Get-HookCopyTemplate) $dir)
    if ($EnvOverrides.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
        Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    }
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Completion-Check.ps1'); LocalAppData = (Join-Path $dir '_fakelocal') }
}

function Get-StateDir { param($Copy) return (Join-Path $Copy.LocalAppData 'HookMaker\state') }

# The hook keys every coordination file on Get-ShortHash(lowercased cwd) -
# recomputed here from the hook's own library so the test can never drift from
# the implementation's key derivation.
. $HookLib
function Get-ProjectKey { param([string]$Root) return (Get-ShortHash $Root.ToLowerInvariant()) }

# Same fingerprint the hook computes for the current repo state.
function Get-Fingerprint { param([string]$Root) return (Get-RepoStateFingerprint -ProjectRoot $Root) }

# Deterministic run identity per project root, so a result and an observed record
# for the same root MATCH the hook's identity gate by construction (schema 2).
function Get-TestRunId { param([string]$Root) return ('run-' + (Get-ProjectKey $Root)) }
function Get-TestCommandFp {
    param([string]$Root)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('cmd|' + $Root.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 32) }
    finally { $sha.Dispose() }
}

# Filename-safe runId - must match Run-Tests-Guarded.ps1/Test-Run-Guard.ps1's
# Get-SafeRunId. Every coordination file is now PER-RUN:
# TestRunGuard-<kind>-<key>-<safeRunId>.json.
function Get-SafeRunId { param([string]$Id) $s = ([string]$Id).ToLowerInvariant() -replace '[^a-z0-9]', ''; if ($s -eq '') { $s = Get-ShortHash ([string]$Id) }; return $s }
function Get-RunStateFile {
    param([object]$Copy, [string]$Root, [string]$Kind, [string]$RunId = '')
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    return (Join-Path (Get-StateDir $Copy) ('TestRunGuard-' + $Kind + '-' + (Get-ProjectKey $Root) + '-' + (Get-SafeRunId $RunId) + '.json'))
}

function Write-GuardedResult {
    param(
        [object]$Copy, [string]$Root, [string]$Overall = 'ok', [int]$ExitCode = 0,
        [string]$TerminateReason = '', [string]$TerminateDetail = '', [object[]]$Leaked = @(),
        [double]$AgeMinutes = 0,
        # Override the identity to simulate a DIFFERENT run/command/state.
        [string]$RunId = '', [string]$CommandFingerprint = '', [string]$ProjectFingerprint = ''
    )
    $ended = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes).ToString('o')
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    if ($CommandFingerprint -eq '') { $CommandFingerprint = Get-TestCommandFp $Root }
    if ($ProjectFingerprint -eq '') { $ProjectFingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{
        schema = 2; overall = $Overall; fileName = 'pwsh'; argumentCount = 3
        workingDirectory = $Root; exitCode = $ExitCode
        runId = $RunId; projectFingerprint = $ProjectFingerprint; commandFingerprint = $CommandFingerprint
        terminated = ($Overall -eq 'terminated'); terminateReason = $TerminateReason
        terminateDetail = $TerminateDetail; elapsedSeconds = 12.5; noProgressSeconds = 0
        heartbeats = 2; peakMemoryMB = 40; cpuSeconds = 3; peakTreeSize = 2
        leakedProcessIds = @($Leaked); lastProgress = 'Passed: 10  Failed: 0'
        stdoutBytes = 100; stderrBytes = 0; workerBudget = 4
        startedUtc = $ended; endedUtc = $ended
    }
    # PER-RUN filename, keyed by this result's own runId - two runs in one project
    # write distinct files instead of overwriting each other.
    $path = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'result' -RunId $RunId
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 6)
}

function Write-ObservedRecord {
    param(
        [object]$Copy, [string]$Root, [bool]$Guarded = $true, [string]$Fingerprint = '',
        [double]$AgeMinutes = 0, [bool]$RunIdControlled = $true, [string]$RunId = '',
        [string]$CommandFingerprint = ''
    )
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    if ($CommandFingerprint -eq '') { $CommandFingerprint = Get-TestCommandFp $Root }
    # observedUtc is anchored a full 60s below the result's start. Both this
    # helper and Write-GuardedResult call the git-based Get-Fingerprint, whose
    # duration under parallel git contention is unbounded-in-seconds; a tight
    # margin let observedUtc drift PAST a result written moments earlier, so the
    # hook's startedUtc>=observedUtc gate flakily rejected a genuinely-matching
    # run. 60s dwarfs any git delay yet is negligible against the 180-minute
    # evidence window, and the identity-mismatch tests use minute-scale gaps, so
    # this never masks a real "different run".
    $observedUtc = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes).AddSeconds(-60).ToString('o')
    if ($Fingerprint -eq '') { $Fingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{
        schema = 2; observedUtc = $observedUtc; fingerprint = $Fingerprint; projectFingerprint = $Fingerprint
        runId = $RunId; runIdControlled = $RunIdControlled
        commandFingerprint = $CommandFingerprint; guarded = $Guarded
    }
    $path = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'observed' -RunId $RunId
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 4)
}

function Write-ActiveMarker {
    param([object]$Copy, [string]$Root, [int]$ProcessId,
        [string]$StartUtc = '', [string]$ExePath = '', [string]$ProjectFingerprint = '', [string]$RunId = '')
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    # Schema-2 marker with owner identity. Defaults reflect the LIVE process at
    # $ProcessId (so a marker written for the current test process validates).
    if ($StartUtc -eq '') {
        try { $StartUtc = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { $StartUtc = '' }
    }
    if ($ExePath -eq '') {
        try { $ExePath = [string](Get-Process -Id $ProcessId -ErrorAction Stop).Path } catch { $ExePath = '' }
    }
    if ($ProjectFingerprint -eq '') { $ProjectFingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{
        schema = 2; runId = $RunId; ownerPid = $ProcessId
        ownerProcessStartUtc = $StartUtc; ownerExecutablePath = $ExePath
        projectFingerprint = $ProjectFingerprint; markerCreatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $path = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'active' -RunId $RunId
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 4)
}

function Remove-CoordinationFile {
    param([object]$Copy, [string]$Root, [string]$Kind)
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-StateDir $Copy) -Filter ('TestRunGuard-' + $Kind + '-' + (Get-ProjectKey $Root) + '-*.json') -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
}

# Marks Test-Temp-Cleanup as INSTALLED for the project (the same detection
# Cloudflare-Deploy uses) without installing anything real.
function New-CleanupMarker {
    param([string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -Force | Out-Null
}
function Write-CleanupResult {
    param([object]$Copy, [string]$Root, [string]$Category = 'clean', [string]$Fingerprint = '')
    if ($Fingerprint -eq '') { $Fingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{ sessionId = 't'; fingerprint = $Fingerprint; category = $Category; timestampUtc = [DateTime]::UtcNow.ToString('o') }
    Write-Utf8 (Join-Path (Get-StateDir $Copy) ('TestTempCleanup-result-' + (Get-ProjectKey $Root) + '.json')) ($doc | ConvertTo-Json -Depth 4)
}

function Add-AiNote {
    param([string]$Root, [string]$Text, [string]$File = 'TESTING_NOTES.md')
    $dir = Join-Path $Root '.ai'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir $File
    $existing = if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::ReadAllText($path) } else { '' }
    Write-Utf8 $path ($existing + $Text + "`n")
}

# The hook now tells the agent to tag its durable note with a line
# `Test incident: <key>`; a note without that exact tag no longer resolves the
# incident. These helpers mirror a real agent: extract the tag from the block the
# hook just emitted, then write a note carrying it plus real content.
function Get-IncidentTagLine {
    param([string]$Reason)
    if ($Reason -match 'Test incident:\s*([0-9a-zA-Z-]+)') { return ('Test incident: ' + $Matches[1]) }
    return ''
}
# Writes a durable note carrying the incident tag found in $Reason plus $Body.
function Add-TaggedNote {
    param([string]$Root, [string]$Reason, [string]$Body, [string]$File = 'TESTING_NOTES.md')
    Add-AiNote -Root $Root -Text ((Get-IncidentTagLine $Reason) + "`n" + $Body) -File $File
}

# Polls until a just-spawned process is fully queryable (StartTime and Path
# readable) so an active-marker written for it records the SAME identity the hook
# will later read. Removes the real-process start-up race that intermittently made
# a genuinely-live sentinel read as stale.
function Wait-ProcessReady {
    param([int]$ProcessId, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction Stop
            $st = $proc.StartTime
            $path = $proc.Path
            if ($null -ne $st -and -not [string]::IsNullOrWhiteSpace([string]$path)) { return $true }
        }
        catch { }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Fire {
    param(
        [object]$Copy, [string]$Cwd, [string]$EventName = 'Stop', [string]$SessionId = 'sess1',
        [switch]$StopHookActive, [switch]$Codex, [string]$Exe = 'pwsh',
        # E-05: optional Stop-input fields the ::deep-debug detection consumes -
        # a transcript_path (Claude Code sends one at Stop) and/or a prompt field.
        [string]$TranscriptPath = '', [string]$Prompt = ''
    )
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    if ($TranscriptPath -ne '') { $obj['transcript_path'] = $TranscriptPath }
    if ($Prompt -ne '') { $obj['prompt'] = $Prompt }
    # The client signal is CLAUDE_PROJECT_DIR in the child ENVIRONMENT (set
    # below), never a field in the event input - `hookSpecificOutput` is an
    # OUTPUT field and appears in no event payload.
    $payload = $obj | ConvertTo-Json -Depth 5
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    Write-Utf8 $inFile $payload
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $Copy.Script + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Copy.Script + '"' }
    $startArgs = @{
        FilePath               = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait                   = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        # -Environment MERGES with the inherited environment, so an ambient
        # CLAUDE_PROJECT_DIR from this very runner would otherwise leak into a
        # "Codex" case. Clear it explicitly rather than omitting the key.
        $childEnv = @{ PATH = $env:PATH; LOCALAPPDATA = $Copy.LocalAppData }
        $childEnv['CLAUDE_PROJECT_DIR'] = if ($Codex) { '' } else { $Cwd }
        $startArgs.Environment = $childEnv
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Parses the hook's stdout as ONE JSON document; $null when it is not valid.
function ConvertFrom-HookOutput {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}
function Get-BlockReason {
    param([string]$Text)
    $doc = ConvertFrom-HookOutput $Text
    if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['reason']) { return '' }
    return [string]$doc.reason
}
