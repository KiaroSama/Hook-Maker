# Cbm-Update-Check - the Codebase Memory index is lagging behind the code.
#
# ROLE: GATE on Stop (spec 038 strict path, below), ADVISORY otherwise
# (global-hook-rules.md SS Hook Roles). Never runs the CBM binary, never writes
# outside its own state files.
#
# STRICT PATH (spec 038, same duty and threshold as Speckit-Check): a change
# request that edited 3+ project files needs an index_repository call AFTER the
# last edit, or a closing `CBM: not refreshed - <reason>` line. index_status
# alone does not clear it - it reports, it does not refresh. Refused once per
# (session, request set); HOOK_ENFORCEMENT=advisory|off lowers it. Unknown or
# partial transcripts and SubagentStop keep the advisory below.
#
# EXPECT THIS HOOK TO BE SILENT ALMOST ALWAYS, and read that as correct
# behaviour rather than a broken hook: CBM runs a background watcher that
# rewrites the project database on incremental changes, so a gap only opens
# when the watcher is stopped, wedged, or was never given this project.
#
# It mirrors Graph-Update-Check step for step with the artifact swapped, so
# the two behave identically for the two graphs: stop_hook_active guard ->
# artifact-exists guard -> per-project cooldown -> newest work vs artifact
# time -> structural-impact wording (the AGENT judges structural impact; the
# hook only reports the gap, because file count is not impact).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')
. (Join-Path $PSScriptRoot '..\_scope.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Stop' }
if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

$gateReceipt = if ($eventName -eq 'Stop' -and (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue)) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Cbm-Update-Check' } else { $null }
try {
# Stand down only on THIS hook's own re-entry; the advisory path below keeps the
# older any-gate guard, since a reminder after another gate's block is noise.
if ($eventName -eq 'Stop' -and (Get-Command Test-StopStandDown -ErrorAction SilentlyContinue) -and (Test-StopStandDown -HookInput $hookInput -HookName 'Cbm-Update-Check')) { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
try { if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 } } catch { exit 0 }

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cacheDir = Get-CbmCacheDir -Config $config -ProjectRoot $cwd
if (-not (Test-CbmInstalled -CacheDir $cacheDir)) { exit 0 }

# No index for this project is Cbm-Read-Check's message to deliver, at the
# START of a session where it is actionable - not this hook's, at the end.
$dbPath = Get-CbmProjectDbPath -ProjectRoot $cwd -CacheDir $cacheDir
$dbItem = $null
try { if (Test-Path -LiteralPath $dbPath -PathType Leaf) { $dbItem = Get-Item -LiteralPath $dbPath -Force } } catch { $dbItem = $null }
if ($null -eq $dbItem) { exit 0 }

if ($eventName -eq 'Stop' -and $script:EvidenceLibReady -and (Get-Command Get-StructuralRefreshFinding -ErrorAction SilentlyContinue)) {
    $maxBytes = 20000000
    if ($config.ContainsKey('MAX_TRANSCRIPT_BYTES')) {
        $parsed = 0; if ([int]::TryParse([string]$config['MAX_TRANSCRIPT_BYTES'], [ref]$parsed) -and $parsed -ge 100000) { $maxBytes = $parsed }
    }
    $evidence = Get-TranscriptToolEvidence -Path ([string](Get-Field $hookInput 'transcript_path')) -MaxBytes $maxBytes
    if ($evidence.Ok -and -not $evidence.Partial) {
        $finding = Get-StructuralRefreshFinding -HookInput $hookInput -Events @($evidence.Events) -RefreshKind 'cbm' -RefreshPattern '^index_repository$' -ExemptLabel 'CBM' -OwnMessagePattern '(?im)^[ 	-]*CBM UPDATE CHECK'
        if ($null -ne $finding) {
            if (-not (Test-NewGateFingerprint -Name 'CbmUpdateCheck' -Cwd $cwd -Fingerprint $finding.Fingerprint)) { exit 0 }
            $blockMessage = @(
                ('CBM UPDATE CHECK: request "' + $finding.FirstPrompt + '" edited ' + [string]$finding.EditCount + ' project files; no index_repository after the last edit.'),
                ('Run index_repository(repo_path=' + ($cwd | ConvertTo-Json -Compress) + ', mode="moderate", persistence=true) now, or end the reply with `CBM: not refreshed - <reason>`.')
            ) -join "`n"
            $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Cbm-Update-Check' -FindingFingerprint $finding.Fingerprint -EventName $eventName -Message $blockMessage -Condition 'required-workflow'
            exit $emit.ExitCode
        }
    }
}

# A Stop hook that re-fires on its own output is the classic hook loop.
$stopActive = Get-Field $hookInput 'stop_hook_active'
if ($null -ne $stopActive -and [bool]$stopActive) { exit 0 }

function Get-IntSetting {
    param([string]$Key, [int]$Default, [int]$Minimum, [int]$Maximum)
    if ($config.ContainsKey($Key)) {
        $parsed = 0
        if ([int]::TryParse([string]$config[$Key], [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) { return $parsed }
    }
    return $Default
}
# STALE_MINUTES is the watcher's expected lag, not a patience setting: below it
# a gap means "the watcher has not caught up yet", above it means "the watcher
# is not doing its job here".
$staleMinutes = Get-IntSetting -Key 'STALE_MINUTES' -Default 10 -Minimum 1 -Maximum 1440
$cooldownMinutes = Get-IntSetting -Key 'COOLDOWN_MINUTES' -Default 60 -Minimum 0 -Maximum 10080

$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$cooldownPath = Join-Path $stateDir ('CbmUpdateCheck-' + $projectKey + '.txt')
$nowUtc = [DateTime]::UtcNow
if ($cooldownMinutes -gt 0 -and (Test-Path -LiteralPath $cooldownPath -PathType Leaf)) {
    try {
        $lastText = ([System.IO.File]::ReadAllText($cooldownPath)).Trim()
        $lastUtc = [DateTime]::MinValue
        if ([DateTime]::TryParse($lastText, [ref]$lastUtc)) {
            if (($nowUtc - $lastUtc.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) { exit 0 }
        }
    }
    catch { }
}

# Newest real code work, from git rather than from mtimes: a checkout, a
# formatter or an editor save touches files without changing the code.
$workUtc = Get-LatestWorkTimeUtc -ProjectRoot $cwd
if ($null -eq $workUtc) { exit 0 }
$dbUtc = $dbItem.LastWriteTimeUtc
if (($workUtc - $dbUtc).TotalMinutes -le $staleMinutes) { exit 0 }

try {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($cooldownPath, $nowUtc.ToString('o'))
}
catch { }

$message = @(
    ('Code newer than index (' +
        $dbUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' vs ' + $workUtc.ToString('yyyy-MM-dd HH:mm:ss') + ').'),
    'Watcher UNVERIFIED: lag/absent.',
    ('Before query: index_status; stale -> index_repository(repo_path=' + ($cwd | ConvertTo-Json -Compress) + ', mode="moderate", persistence=true).'),
    'Structure only; docs/format/generated exempt.'
) -join "`n"

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $message
exit $emit.ExitCode
}
catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
