# GitSyncCheck - tells the agent when the current project is out of sync with
# its git remote (GitHub etc.): uncommitted changes, unpushed/unpulled commits,
# or a branch without an upstream. Silent for in-sync and non-git projects.
#
# Events:
# - SessionStart / UserPromptSubmit: injects the status as additional context.
# - Stop / SubagentStop: asks the agent (once, with a cooldown) to decide
#   whether to push/pull before finishing. Never loops: a stop that was already
#   continued by a hook (stop_hook_active) is left alone.
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minimum minutes between Stop reminders per project (default 30)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) {
    $eventName = 'SessionStart'
}
$isStopEvent = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')

# Never loop: if this stop was already continued by a hook, stay silent.
if ($isStopEvent -and (Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 30
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}

# ---- Stop cooldown state (per project) ----
$statePath = $null
if ($isStopEvent) {
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    $statePath = Join-Path $stateDir ('GitSyncCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
                exit 0
            }
        }
        catch { }
    }
}

# ---- git inspection ----
function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    $output = & git -C $cwd @GitArgs 2>$null
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = @($output) }
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    exit 0
}
$inRepo = Invoke-Git @('rev-parse', '--is-inside-work-tree')
if (-not $inRepo.Ok -or [string]$inRepo.Output[0] -ne 'true') {
    exit 0
}
$remotes = Invoke-Git @('remote')
if (-not $remotes.Ok -or @($remotes.Output | Where-Object { $_ }).Count -eq 0) {
    exit 0
}

$findings = New-Object System.Collections.Generic.List[string]

# Refresh remote refs; when offline, fall back to the last fetched state.
$fetch = Invoke-Git @('fetch', '--quiet')
if (-not $fetch.Ok) {
    [void]$findings.Add('The remote could not be fetched (offline?); comparison uses the last known remote state.')
}

$status = Invoke-Git @('status', '--porcelain')
if ($status.Ok) {
    $dirtyCount = @($status.Output | Where-Object { $_ }).Count
    if ($dirtyCount -gt 0) {
        [void]$findings.Add('There are ' + $dirtyCount + ' uncommitted change(s) in the working tree.')
    }
}

$branch = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
$branchName = ''
if ($branch.Ok) {
    $branchName = [string]$branch.Output[0]
}
$upstream = Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
if ($upstream.Ok) {
    $upstreamName = [string]$upstream.Output[0]
    # Parentheses required: the array comma binds tighter than +, so an
    # unparenthesized concat would split into two separate git arguments.
    $counts = Invoke-Git @('rev-list', '--left-right', '--count', ($upstreamName + '...HEAD'))
    if ($counts.Ok -and $counts.Output.Count -gt 0) {
        $parts = ([string]$counts.Output[0]) -split '\s+'
        if ($parts.Count -ge 2) {
            $behind = [int]$parts[0]
            $ahead = [int]$parts[1]
            if ($behind -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $behind + ' commit(s) BEHIND ' + $upstreamName + ' (pull needed).')
            }
            if ($ahead -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $ahead + ' commit(s) AHEAD of ' + $upstreamName + ' (push needed).')
            }
        }
    }
}
elseif ($branchName -ne '' -and $branchName -ne 'HEAD') {
    [void]$findings.Add('Branch ' + $branchName + ' has no upstream branch configured (never pushed?).')
}

if ($findings.Count -eq 0) {
    exit 0
}

$message = 'GIT SYNC STATUS (' + $cwd + "):`n- " + ($findings.ToArray() -join "`n- ")

if ($isStopEvent) {
    if ($null -ne $statePath) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        [System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))
    }
    $reason = $message + "`nAt your discretion: commit/push/pull now if this task's result should be synced; otherwise finish - this reminder respects a cooldown."
    @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
    exit 0
}

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
