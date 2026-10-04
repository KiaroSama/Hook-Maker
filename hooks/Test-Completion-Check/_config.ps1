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
        [void]$configWarnings.Add('TEST_COMPLETION_EVIDENCE_MINUTES is not an integer in 1..10080; using the default 180.')
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
        [void]$configWarnings.Add('TEST_COMPLETION_ADVISORY_ONLY must be 0 or 1; falling back to advisory-only (1) so a malformed value can never widen what is blocked on.')
    }
}

$alwaysRequireNote = $false
if ($config.ContainsKey('TEST_COMPLETION_ALWAYS_REQUIRE_NOTE')) {
    $raw = [string]$config['TEST_COMPLETION_ALWAYS_REQUIRE_NOTE']
    if ($raw -eq '1') { $alwaysRequireNote = $true }
    elseif ($raw -ne '0' -and -not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_ALWAYS_REQUIRE_NOTE must be 0 or 1; using the default 0 (a note is required only after an incident).')
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
        [void]$configWarnings.Add('TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS is not an integer in 1..168; using the default 12.')
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
        [void]$configWarnings.Add('TEST_COMPLETION_COORDINATION_WAIT_SECONDS is not an integer in 0..30; using the default 2.')
    }
}

