# Smoke test for the cross-project sync engine.
# Self-contained: builds throwaway fixtures under the temp directory, drives the
# engine through stdin exactly like a real hook, asserts behavior, cleans up.
# Guards the collection edge cases that caused past crashes (single vs many
# extensions, empty vs populated sources) plus the core review/ack lifecycle.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-Engine.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$Engine = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'
if (-not (Test-Path -LiteralPath $Engine -PathType Leaf)) {
    Write-Host "Engine not found at: $Engine" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-test'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Project {
    param([string]$Name)
    $root = Join-Path $Work $Name
    New-Item -ItemType Directory -Path (Join-Path $root '.ai') -Force | Out-Null
    return $root
}

function New-Endpoint {
    param([string]$Name, [string]$Root)
    return [ordered]@{ name = $Name; root = $Root; directory = '.ai'; aliases = @() }
}

function New-Route {
    param([string]$Id, $Source, $Destination)
    return [ordered]@{ id = $Id; enabled = $true; source = $Source; destination = $Destination }
}

function Write-Config {
    param([string]$Path, $Routes, $Extensions)
    $cfg = [ordered]@{
        version  = 2
        defaults = [ordered]@{
            events            = @('SessionStart', 'UserPromptSubmit')
            initialSyncMode   = 'review'
            maxFileBytes      = 2097152
            includeExtensions = $Extensions
            excludePatterns   = @('.cross-project-sync/*', '*/.cross-project-sync/*')
        }
        profiles = @(
            [ordered]@{ id = 'grp'; name = 'Test group'; enabled = $true; routes = $Routes }
        )
    }
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

# Deliver the hook payload through a real stdin file handle rather than a
# PowerShell pipe: piping a string from a Windows PowerShell 5.1 parent into a
# child process yields empty stdin, and a real host (Claude/Codex) hands the
# hook a genuine stdin stream anyway. This keeps the test host-independent.
function Fire {
    param([string]$Cwd, [string]$Config, [string]$Exe = 'pwsh', [string]$EventName = 'SessionStart', [string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { $SessionId = [guid]::NewGuid().ToString() }
    $payload = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName; source = 'startup' } | ConvertTo-Json -Compress

    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))

    if ($Exe -eq 'pwsh') {
        $file = (Get-Process -Id $PID).Path
        $argLine = '-NoLogo -NoProfile -File "' + $Engine + '" -ConfigPath "' + $Config + '"'
    }
    else {
        $file = 'powershell.exe'
        $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Engine + '" -ConfigPath "' + $Config + '"'
    }
    $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -Wait -NoNewWindow -PassThru
    $out = if (Test-Path -LiteralPath $outFile) { [System.IO.File]::ReadAllText($outFile) } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out.Trim() }
}

try {
    # --- Fixtures: A <-> B mesh, plus an unrelated project X ---------------
    $A = New-Project 'ProjA'
    $B = New-Project 'ProjB'
    $X = New-Project 'ProjX'
    Set-Content -LiteralPath (Join-Path $A '.ai\LESSON.md') "# Lesson`nvalidate signatures" -Encoding utf8

    $routesAB = @(
        (New-Route 'a-to-b' (New-Endpoint 'A' $A) (New-Endpoint 'B' $B)),
        (New-Route 'b-to-a' (New-Endpoint 'B' $B) (New-Endpoint 'A' $A))
    )

    # --- Scenario 1: single-element includeExtensions must not crash -------
    $cfg1 = Join-Path $Work 'cfg-single.json'
    Write-Config -Path $cfg1 -Routes $routesAB -Extensions @('.md')
    $r1 = Fire -Cwd $B -Config $cfg1
    Check 'single-extension config: exit 0 (no crash)' ($r1.Exit -eq 0)
    Check 'single-extension config: review emitted' ($r1.Out -match 'REVIEW REQUIRED')
    $valid = $false
    try { $null = $r1.Out | ConvertFrom-Json; $valid = $true } catch { $valid = $false }
    Check 'output is valid JSON hook payload' $valid

    # --- Scenario 2: many extensions still work (fresh state) --------------
    $cfg2 = Join-Path $Work 'cfg-many.json'
    Write-Config -Path $cfg2 -Routes $routesAB -Extensions @('.md', '.txt', '.json', '.ps1')
    $r2 = Fire -Cwd $B -Config $cfg2
    Check 'many-extension config: review emitted' ($r2.Out -match 'REVIEW REQUIRED')

    # --- Scenario 3: staged package on disk (from scenario 1) --------------
    $inboxRoot = Join-Path $B '.ai\.cross-project-sync\inbox'
    $staged = @(Get-ChildItem -LiteralPath $inboxRoot -Recurse -File -ErrorAction SilentlyContinue)
    Check 'manifest.json staged' (@($staged | Where-Object Name -eq 'manifest.json').Count -ge 1)
    Check 'source LESSON.md staged' (@($staged | Where-Object Name -eq 'LESSON.md').Count -ge 1)

    # --- Scenario 4: same session is silent --------------------------------
    $null = Fire -Cwd $B -Config $cfg1 -SessionId 'fixed'          # first notify in this session
    $rSame = Fire -Cwd $B -Config $cfg1 -SessionId 'fixed'         # same session again
    Check 'same session: second fire is silent' ([string]::IsNullOrWhiteSpace($rSame.Out))

    # --- Scenario 5: acknowledge clears the pending review -----------------
    $currentHost = (Get-Process -Id $PID).Path
    $ack = & $currentHost -NoLogo -NoProfile -File $Engine -Acknowledge -ProjectRoot $B -Profile 'grp' -Route 'a-to-b' -ConfigPath $cfg1 2>&1
    Check 'acknowledge: succeeds' ($LASTEXITCODE -eq 0 -and (($ack | Out-String) -match 'acknowledged'))
    $stagedAfter = @(Get-ChildItem -LiteralPath $inboxRoot -Recurse -File -ErrorAction SilentlyContinue)
    Check 'acknowledge: inbox cleaned' ($stagedAfter.Count -eq 0)
    $rAfterAck = Fire -Cwd $B -Config $cfg1
    Check 'after acknowledge: silent (no changes)' ([string]::IsNullOrWhiteSpace($rAfterAck.Out))

    # --- Scenario 6: a real change is re-detected --------------------------
    Add-Content -LiteralPath (Join-Path $A '.ai\LESSON.md') 'rotate tokens quarterly'
    Set-Content -LiteralPath (Join-Path $A '.ai\COMMANDS.md') 'npm test' -Encoding utf8
    $r6 = Fire -Cwd $B -Config $cfg1 -EventName 'UserPromptSubmit'
    Check 'change re-detected after ack' ($r6.Out -match 'REVIEW REQUIRED')
    $manifest = Get-ChildItem -LiteralPath $inboxRoot -Recurse -Filter 'manifest.json' | Select-Object -First 1
    $m = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
    Check 'manifest lists added COMMANDS.md' (@($m.added) -contains 'COMMANDS.md')
    Check 'manifest lists modified LESSON.md' (@($m.modified) -contains 'LESSON.md')

    # --- Scenario 7: unrelated project is ignored --------------------------
    Set-Content -LiteralPath (Join-Path $X '.ai\NOTE.md') 'X is in no route' -Encoding utf8
    $rX = Fire -Cwd $X -Config $cfg1
    Check 'unrelated project: no output' ([string]::IsNullOrWhiteSpace($rX.Out))
    Check 'unrelated project: no sync state created' (-not (Test-Path -LiteralPath (Join-Path $X '.ai\.cross-project-sync')))

    # --- Scenario 8: empty source is a silent baseline, no empty package ---
    $C0 = New-Project 'EmptySource'
    $D0 = New-Project 'Dest'
    $cfgEmpty = Join-Path $Work 'cfg-empty.json'
    Write-Config -Path $cfgEmpty -Routes @((New-Route 'c-to-d' (New-Endpoint 'C' $C0) (New-Endpoint 'D' $D0))) -Extensions @('.md')
    $rEmpty = Fire -Cwd $D0 -Config $cfgEmpty
    Check 'empty source: silent (no empty review package)' ([string]::IsNullOrWhiteSpace($rEmpty.Out))
    Check 'empty source: no inbox package created' (-not (Test-Path -LiteralPath (Join-Path $D0 '.ai\.cross-project-sync\inbox')))

    # --- Scenario 9: engine runs under Windows PowerShell 5.1 --------------
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $r9 = Fire -Cwd $B -Config $cfg2 -Exe 'powershell.exe'
        Check 'runs under powershell.exe (5.1)' ($r9.Exit -eq 0 -and $r9.Out -match 'REVIEW REQUIRED')
    }
    else {
        Write-Host '[SKIP] powershell.exe not available' -ForegroundColor Yellow
    }

    # --- Scenario 10: corrupted/partial state file must not crash (B3) -----
    # A state file that is present but wrong-shaped (e.g. "{}" from a partial
    # write) used to pass the old "$null -eq $state" check unharmed and then
    # crash on the first $state.pending read under StrictMode 2.0, dropping
    # any review messages already queued for earlier contexts in the loop.
    $CorruptSrc = New-Project 'CorruptSrc'
    $CorruptDest = New-Project 'CorruptDest'
    Set-Content -LiteralPath (Join-Path $CorruptSrc '.ai\NOTE.md') 'partial-state regression fixture' -Encoding utf8
    $cfgCorrupt = Join-Path $Work 'cfg-corrupt.json'
    Write-Config -Path $cfgCorrupt -Routes @((New-Route 'corrupt-route' (New-Endpoint 'Src' $CorruptSrc) (New-Endpoint 'Dest' $CorruptDest))) -Extensions @('.md')

    $rSeed = Fire -Cwd $CorruptDest -Config $cfgCorrupt
    Check 'corrupt-state fixture: seed run emits review' ($rSeed.Out -match 'REVIEW REQUIRED')
    $stateFile = Get-ChildItem -LiteralPath (Join-Path $CorruptDest '.ai\.cross-project-sync\state') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    Check 'corrupt-state fixture: state file exists' ($null -ne $stateFile)
    Set-Content -LiteralPath $stateFile.FullName -Value '{}' -Encoding utf8

    $rCorrupt = Fire -Cwd $CorruptDest -Config $cfgCorrupt
    Check 'corrupt state ({}): exit 0 (no StrictMode crash)' ($rCorrupt.Exit -eq 0) $rCorrupt.Out
    Check 'corrupt state ({}): still re-detects as fresh' ($rCorrupt.Out -match 'REVIEW REQUIRED') $rCorrupt.Out
    $stateAfter = Get-Content -LiteralPath $stateFile.FullName -Raw | ConvertFrom-Json
    Check 'corrupt state ({}): state file rebuilt with pending' ($null -ne $stateAfter.pending)

    # --- Scenario 11: {"pending":null} missing top-level fields (HM-01 class 1) ---
    # A state file that has SOME shape (a "pending" key literally present as
    # null) passes ANY "$state -eq $null OR missing 'pending' property" guard
    # unharmed, because the property genuinely exists. It then crashes on the
    # first untouched top-level read ($state.lastAppliedQuickFingerprint)
    # under Set-StrictMode 2.0 - a strictly narrower guard than a full
    # per-field normalizer can never catch this shape.
    $PartialTopSrc = New-Project 'PartialTopSrc'
    $PartialTopDest = New-Project 'PartialTopDest'
    Set-Content -LiteralPath (Join-Path $PartialTopSrc '.ai\NOTE.md') 'partial top-level state fixture' -Encoding utf8
    $cfgPartialTop = Join-Path $Work 'cfg-partial-top.json'
    Write-Config -Path $cfgPartialTop -Routes @((New-Route 'partial-top-route' (New-Endpoint 'Src' $PartialTopSrc) (New-Endpoint 'Dest' $PartialTopDest))) -Extensions @('.md')

    $rPartialTopSeed = Fire -Cwd $PartialTopDest -Config $cfgPartialTop
    Check 'partial-top fixture: seed run emits review' ($rPartialTopSeed.Out -match 'REVIEW REQUIRED')
    $partialTopStateFile = Get-ChildItem -LiteralPath (Join-Path $PartialTopDest '.ai\.cross-project-sync\state') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    Check 'partial-top fixture: state file exists' ($null -ne $partialTopStateFile)
    Set-Content -LiteralPath $partialTopStateFile.FullName -Value '{"pending": null}' -Encoding utf8

    $rPartialTop = Fire -Cwd $PartialTopDest -Config $cfgPartialTop
    Check 'partial top-level state ({"pending":null}): exit 0 (no StrictMode crash)' ($rPartialTop.Exit -eq 0) $rPartialTop.Out
    Check 'partial top-level state: still re-detects as needing review' ($rPartialTop.Out -match 'REVIEW REQUIRED') $rPartialTop.Out

    # --- Scenario 12: {} reaching -Acknowledge directly (HM-01 class 2) -----
    # The per-context loop guard never runs for -Acknowledge: it used to read
    # $state.pending directly with no shape guard at all. An empty-object
    # state has no 'pending' property whatsoever, so the raw dot-access
    # crashed under StrictMode 2.0 before "no pending review" could even be
    # printed - a distinct, worse bug than the loop-side one, since it had NO
    # guard rather than a narrow one.
    $AckEmptySrc = New-Project 'AckEmptySrc'
    $AckEmptyDest = New-Project 'AckEmptyDest'
    $cfgAckEmpty = Join-Path $Work 'cfg-ack-empty.json'
    Write-Config -Path $cfgAckEmpty -Routes @((New-Route 'ack-empty-route' (New-Endpoint 'Src' $AckEmptySrc) (New-Endpoint 'Dest' $AckEmptyDest))) -Extensions @('.md')

    $null = Fire -Cwd $AckEmptyDest -Config $cfgAckEmpty
    $ackEmptyStateFile = Get-ChildItem -LiteralPath (Join-Path $AckEmptyDest '.ai\.cross-project-sync\state') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    Check 'ack-empty fixture: state file exists' ($null -ne $ackEmptyStateFile)
    Set-Content -LiteralPath $ackEmptyStateFile.FullName -Value '{}' -Encoding utf8

    $ackEmpty = & $currentHost -NoLogo -NoProfile -File $Engine -Acknowledge -ProjectRoot $AckEmptyDest -Profile 'grp' -Route 'ack-empty-route' -ConfigPath $cfgAckEmpty 2>&1
    Check 'ack on {} state: exit 0 (no StrictMode crash)' ($LASTEXITCODE -eq 0) ($ackEmpty | Out-String)
    Check 'ack on {} state: reports no pending review' (($ackEmpty | Out-String) -match 'No pending review exists')

    # --- Scenario 13: pending object missing a nested field (HM-01 class 3) ---
    # A real pending package is seeded (files genuinely staged on disk), then
    # ONE nested field is deleted from the state file's pending object. The
    # normalizer must repair only that field and PRESERVE every other pending
    # field (packageRoot/manifestPath/filesRoot/...) - never discard the whole
    # package and silently drop an already-staged review.
    $PartialPendingSrc = New-Project 'PartialPendingSrc'
    $PartialPendingDest = New-Project 'PartialPendingDest'
    Set-Content -LiteralPath (Join-Path $PartialPendingSrc '.ai\NOTE.md') 'partial pending fixture' -Encoding utf8
    $cfgPartialPending = Join-Path $Work 'cfg-partial-pending.json'
    Write-Config -Path $cfgPartialPending -Routes @((New-Route 'partial-pending-route' (New-Endpoint 'Src' $PartialPendingSrc) (New-Endpoint 'Dest' $PartialPendingDest))) -Extensions @('.md')

    $rPartialPendingSeed = Fire -Cwd $PartialPendingDest -Config $cfgPartialPending
    Check 'partial-pending fixture: seed run emits review' ($rPartialPendingSeed.Out -match 'REVIEW REQUIRED')
    $partialPendingStateFile = Get-ChildItem -LiteralPath (Join-Path $PartialPendingDest '.ai\.cross-project-sync\state') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    Check 'partial-pending fixture: state file exists' ($null -ne $partialPendingStateFile)
    $seededPendingState = Get-Content -LiteralPath $partialPendingStateFile.FullName -Raw | ConvertFrom-Json
    $originalPackageRoot = [string]$seededPendingState.pending.packageRoot
    Check 'partial-pending fixture: seeded pending has a packageRoot' (-not [string]::IsNullOrWhiteSpace($originalPackageRoot))

    # Delete just sourceQuickFingerprint from the nested pending object; every other field (incl. sourceContentFingerprint) stays.
    $seededPendingState.pending.PSObject.Properties.Remove('sourceQuickFingerprint')
    ($seededPendingState | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $partialPendingStateFile.FullName -Encoding utf8

    $rPartialPending = Fire -Cwd $PartialPendingDest -Config $cfgPartialPending -SessionId 'partial-pending-session'
    Check 'pending missing sourceQuickFingerprint: exit 0 (no StrictMode crash)' ($rPartialPending.Exit -eq 0) $rPartialPending.Out
    Check 'pending missing sourceQuickFingerprint: review re-notified' ($rPartialPending.Out -match 'REVIEW REQUIRED') $rPartialPending.Out
    $stateAfterPartialPending = Get-Content -LiteralPath $partialPendingStateFile.FullName -Raw | ConvertFrom-Json
    Check 'pending missing sourceQuickFingerprint: original packageRoot preserved (not rebuilt)' ([string]$stateAfterPartialPending.pending.packageRoot -eq $originalPackageRoot) ([string]$stateAfterPartialPending.pending.packageRoot)
    Check 'pending missing sourceQuickFingerprint: field repaired (non-null)' ($null -ne $stateAfterPartialPending.pending.sourceQuickFingerprint)

    # --- Scenario 14: leaner top-level schema, pending fully intact (HM-01 class 4) ---
    # Simulates a state written by an older/leaner schema: several top-level
    # fields the current script always writes (version, lastNotifiedSessionId,
    # lastNotifiedAtUtc, lastAppliedFiles, routeId) are entirely ABSENT, while
    # the nested 'pending' object is completely intact. The still-valid
    # pending must be preserved byte-for-byte (same packageRoot) purely
    # because unrelated sibling fields are missing, not corrupted.
    $OlderSchemaSrc = New-Project 'OlderSchemaSrc'
    $OlderSchemaDest = New-Project 'OlderSchemaDest'
    Set-Content -LiteralPath (Join-Path $OlderSchemaSrc '.ai\NOTE.md') 'older schema fixture' -Encoding utf8
    $cfgOlderSchema = Join-Path $Work 'cfg-older-schema.json'
    Write-Config -Path $cfgOlderSchema -Routes @((New-Route 'older-schema-route' (New-Endpoint 'Src' $OlderSchemaSrc) (New-Endpoint 'Dest' $OlderSchemaDest))) -Extensions @('.md')

    $rOlderSchemaSeed = Fire -Cwd $OlderSchemaDest -Config $cfgOlderSchema
    Check 'older-schema fixture: seed run emits review' ($rOlderSchemaSeed.Out -match 'REVIEW REQUIRED')
    $olderSchemaStateFile = Get-ChildItem -LiteralPath (Join-Path $OlderSchemaDest '.ai\.cross-project-sync\state') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    Check 'older-schema fixture: state file exists' ($null -ne $olderSchemaStateFile)
    $olderSeededState = Get-Content -LiteralPath $olderSchemaStateFile.FullName -Raw | ConvertFrom-Json
    $olderOriginalPackageRoot = [string]$olderSeededState.pending.packageRoot

    $olderSeededState.PSObject.Properties.Remove('version')
    $olderSeededState.PSObject.Properties.Remove('routeId')
    $olderSeededState.PSObject.Properties.Remove('lastAppliedFiles')
    $olderSeededState.PSObject.Properties.Remove('lastNotifiedSessionId')
    $olderSeededState.PSObject.Properties.Remove('lastNotifiedAtUtc')
    ($olderSeededState | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $olderSchemaStateFile.FullName -Encoding utf8

    $rOlderSchema = Fire -Cwd $OlderSchemaDest -Config $cfgOlderSchema -SessionId 'older-schema-session'
    Check 'leaner top-level schema: exit 0 (no StrictMode crash)' ($rOlderSchema.Exit -eq 0) $rOlderSchema.Out
    Check 'leaner top-level schema: review re-notified for new session' ($rOlderSchema.Out -match 'REVIEW REQUIRED') $rOlderSchema.Out
    $stateAfterOlderSchema = Get-Content -LiteralPath $olderSchemaStateFile.FullName -Raw | ConvertFrom-Json
    Check 'leaner top-level schema: pending packageRoot preserved byte-for-byte' ([string]$stateAfterOlderSchema.pending.packageRoot -eq $olderOriginalPackageRoot) ([string]$stateAfterOlderSchema.pending.packageRoot)
    Check 'leaner top-level schema: routeId repaired (non-empty)' (-not [string]::IsNullOrWhiteSpace([string]$stateAfterOlderSchema.routeId))

    # --- Scenario 15: lastAppliedFiles serialized as an empty OBJECT ---
    # Seen in three real state files: `"lastAppliedFiles": {}` instead of an
    # array. Get-SafeArrayField wraps it into one property-less element and
    # the applied-files map crashed on `.path` under StrictMode - on EVERY
    # prompt, as a non-blocking hook error the user saw each time. The record
    # is skipped as "nothing applied", so the run re-stages and rewrites a
    # well-formed state.
    $EmptyObjSrc = New-Project 'EmptyObjSrc'
    $EmptyObjDest = New-Project 'EmptyObjDest'
    Set-Content -LiteralPath (Join-Path $EmptyObjSrc '.ai\NOTE.md') 'empty-object fixture' -Encoding utf8
    $cfgEmptyObj = Join-Path $Work 'cfg-empty-obj.json'
    Write-Config -Path $cfgEmptyObj -Routes @((New-Route 'empty-obj-route' (New-Endpoint 'Src' $EmptyObjSrc) (New-Endpoint 'Dest' $EmptyObjDest))) -Extensions @('.md')
    $rEmptyObjSeed = Fire -Cwd $EmptyObjDest -Config $cfgEmptyObj
    Check 'empty-object fixture: seed run emits review' ($rEmptyObjSeed.Out -match 'REVIEW REQUIRED')
    $emptyObjStateFile = Get-ChildItem -LiteralPath (Join-Path $EmptyObjDest '.ai\.cross-project-sync\state') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    Check 'empty-object fixture: state file exists' ($null -ne $emptyObjStateFile)
    $emptyObjText = Get-Content -LiteralPath $emptyObjStateFile.FullName -Raw
    $emptyObjText = [regex]::Replace($emptyObjText, '"lastAppliedFiles"\s*:\s*\[[^\]]*\]', '"lastAppliedFiles": {}')
    Check 'empty-object fixture: the malformed field was actually written' ($emptyObjText -match '"lastAppliedFiles": \{\}')
    [System.IO.File]::WriteAllText($emptyObjStateFile.FullName, $emptyObjText, (New-Object System.Text.UTF8Encoding $false))
    $rEmptyObj = Fire -Cwd $EmptyObjDest -Config $cfgEmptyObj -SessionId 'empty-obj-session'
    Check 'lastAppliedFiles as an empty object: exit 0 (no StrictMode crash on .path)' ($rEmptyObj.Exit -eq 0) $rEmptyObj.Out
    Check 'lastAppliedFiles as an empty object: the run still reports the review' ($rEmptyObj.Out -match 'REVIEW REQUIRED') $rEmptyObj.Out
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
$resultColor = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ('Result: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed') -ForegroundColor $resultColor
exit $script:Fail
