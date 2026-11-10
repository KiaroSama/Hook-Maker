# Test-Completion-Check: config responsibility, extracted from the oversized entry.
# ---- optional .env (invalid -> reported + a NON-WIDENING fallback) ----
$configWarnings = New-Object System.Collections.Generic.List[string]
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

$evidenceMinutes = 180
if ($config.ContainsKey('TEST_COMPLETION_EVIDENCE_MINUTES')) {
    $raw = [string]$config['TEST_COMPLETION_EVIDENCE_MINUTES']
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 10080) {
        $evidenceMinutes = $parsed
    }
    elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_EVIDENCE_MINUTES: integer1..10080 required; default180.')
    }
}

# An invalid value here falls back to ADVISORY (1), not to the blocking default:
# the setting was clearly meant to be changed, and a typo must never make this
# hook block on MORE than it would have. Reported, never silent.
$advisoryOnly = $false
if ($config.ContainsKey('TEST_COMPLETION_ADVISORY_ONLY')) {
    $raw = [string]$config['TEST_COMPLETION_ADVISORY_ONLY']
    if ($raw -eq '1') { $advisoryOnly = $true }
    elseif ($raw -ne '0' -and -not [string]::IsNullOrWhiteSpace($raw)) {
        $advisoryOnly = $true
        [void]$configWarnings.Add('TEST_COMPLETION_ADVISORY_ONLY: 0/1 required; invalid -> advisory(1), never wider blocking.')
    }
}

$alwaysRequireNote = $false
if ($config.ContainsKey('TEST_COMPLETION_ALWAYS_REQUIRE_NOTE')) {
    $raw = [string]$config['TEST_COMPLETION_ALWAYS_REQUIRE_NOTE']
    if ($raw -eq '1') { $alwaysRequireNote = $true }
    elseif ($raw -ne '0' -and -not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_ALWAYS_REQUIRE_NOTE: 0/1 required; default0, incident-only note.')
    }
}

# How long an ACTIVE marker whose owner is gone and that never produced a result
# may still describe the current work. Past it the record is an earlier session's
# leftover: reconciled and dropped with a trace, never a block on this task.
$activeMarkerMaxHours = 12
if ($config.ContainsKey('TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS')) {
    $raw = [string]$config['TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS']
    $parsed = -1
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 168) {
        $activeMarkerMaxHours = $parsed
    }
    elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS: integer1..168 required; default12.')
    }
}

$coordinationWaitSeconds = 2
if ($config.ContainsKey('TEST_COMPLETION_COORDINATION_WAIT_SECONDS')) {
    $raw = [string]$config['TEST_COMPLETION_COORDINATION_WAIT_SECONDS']
    $parsed = -1
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 30) {
        $coordinationWaitSeconds = $parsed
    }
    elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_COORDINATION_WAIT_SECONDS: integer0..30 required; default2.')
    }
}

