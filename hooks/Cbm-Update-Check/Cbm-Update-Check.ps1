# Cbm-Update-Check - the Codebase Memory index is lagging behind the code.
#
# ROLE: ADVISORY (global-hook-rules.md SS Hook Roles). Never blocks, never
# runs the CBM binary, never writes outside its own state file.
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

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Stop' }
if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

# A Stop hook that re-fires on its own output is the classic hook loop.
$stopActive = Get-Field $hookInput 'stop_hook_active'
if ($null -ne $stopActive -and [bool]$stopActive) { exit 0 }

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
    ('CBM UPDATE CHECK - code changed after the Codebase Memory index was last written (index: ' +
        $dbUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC, newest work: ' + $workUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC).'),
    'The background watcher normally keeps it fresh, so a gap this size means it is lagging or this project was never registered with it.',
    ('Before relying on any graph answer, call index_status; if it does not reflect the change, run index_repository(repo_path=' + ($cwd | ConvertTo-Json -Compress) + ', mode="moderate", persistence=true).'),
    'Judge by STRUCTURE, not by file count: a changed symbol, export, import, call/inheritance edge or entry point matters; docs, formatting and generated output do not - skip it then.'
) -join "`n"

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $message
exit $emit.ExitCode
