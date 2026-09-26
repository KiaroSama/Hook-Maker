# Gate receipts - the affirmative half of "every gate passed".
#
# WHY THIS EXISTS (order 58 section 6, spec 007 RD-4). The summary observer
# could only ever record "readiness unverified": a gate that blocks leaves a
# ledger entry, but a gate that finished WITHOUT blocking left nothing, and
# silence is not a pass - a gate that crashed or was killed by its timeout is
# silent too. So every blocking Stop gate now writes a receipt for each Stop
# round it evaluates, and the observer publishes READY only when every gate the
# client actually registered for this event wrote `pass` in this round.
#
# RECEIPT LIFECYCLE, per gate, per client session:
#   running  written when the gate starts evaluating a Stop round
#   pass     it finished without emitting or being refused a block
#   block    Write-StopBlockResult ran (emitted, or refused by the ledger)
#   error    it threw
# A gate killed by its hook timeout never reaches the finally block, so its
# receipt stays `running` - read as "no receipt", never as a pass. A legacy
# gate that stands down on its OWN re-entry writes nothing (its block stays);
# a task-scoped gate re-evaluates, and a suppressed repeat still marks `block`.
#
# WHAT THIS DOES NOT DO. It does not own the client's output transport, so it
# cannot withhold a summary that is already displayed; it only lets the
# observer tell a settled task from an unsettled one (see _generation.ps1).
#
# Loaded by _evidencelib.ps1 (which _hooklib.ps1 already loads), OPTIONALLY: a
# gate calls Start-StopGateReceipt only when the command exists, so a runtime
# copied before this file existed keeps working and simply writes no receipt.

Set-StrictMode -Version 2.0

# The gates that write receipts. A registered Stop hook outside this list is not
# a gate (an advisory, an executor, the observer itself) and is never required.
$script:ReceiptGateNames = @(
    'Ai-Memory-Check', 'Ci-Status-Check', 'Cloudflare-Deploy', 'Docs-Freshness-Check',
    'Feature-Request-Check', 'Git-Sync-Check', 'Graph-Update-Check', 'Ignore-Rules-Check',
    'Large-File-Check', 'Mcp-Usage-Check', 'Rules-Check', 'Secrets-Check', 'Skills-Check',
    'Test-Completion-Check', 'Test-Temp-Cleanup', 'Utf8-Encoding-Check'
)
$script:ReceiptTerminalVerdicts = @('pass', 'block', 'error')
$script:StopGateVerdict = ''
# Seams with production defaults: the user-level registration root and the
# bounded wait. The wait stays under the observer's own 10 s hook timeout -
# updates keep an install's recorded timeout - so a gate slower than this is
# reported as no-receipt rather than the observer being killed mid-write.
$script:GateReceiptGlobalRoot = $HOME
$script:GateReceiptWaitMs = 8000

function Get-StopGateReceiptPath {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$Gate)
    $session = [string](Get-Field $HookInput 'session_id')
    $client = Get-HookClientId
    $root = [string](Get-Field $HookInput 'cwd')
    if ([string]::IsNullOrWhiteSpace($session) -or $client -eq 'unknown' -or [string]::IsNullOrWhiteSpace($root)) { return '' }
    if ($Gate -cnotmatch '^[A-Za-z0-9-]{1,64}$') { return '' }
    $projectKey = Get-ShortHash $root.ToLowerInvariant()
    if ($null -ne (Get-Command Get-StopProjectKey -ErrorAction SilentlyContinue)) {
        try { $projectKey = Get-StopProjectKey -ProjectRoot $root } catch { }
    }
    $stem = 'GateReceipt-' + $projectKey + '-' + (Get-ShortHash ($client + '|' + $session)) + '-' + $Gate
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ($stem + '.json'))
}

function Write-StopGateReceiptFile {
    param([string]$Path, [string]$Gate, [string]$Verdict)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        $doc = [pscustomobject][ordered]@{ schema = 1; gate = $Gate; verdict = $Verdict; at = [DateTime]::UtcNow.ToString('o') }
        [IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
        $temp = ''
    }
    catch { }
    finally { if ($temp -ne '' -and [IO.File]::Exists($temp)) { try { [IO.File]::Delete($temp) } catch { } } }
}

function Read-StopGateReceipt {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $doc = $raw | ConvertFrom-Json -DateKind String }
        else { $doc = $raw | ConvertFrom-Json }
        $at = [DateTime]::MinValue
        if ([string]$doc.verdict -notin (@('running') + $script:ReceiptTerminalVerdicts)) { return $null }
        if (-not [DateTime]::TryParseExact([string]$doc.at, 'o', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { return $null }
        return [pscustomobject]@{ Verdict = [string]$doc.verdict; At = $at.ToUniversalTime() }
    }
    catch { return $null }
}

# The client's own registration files for this event, as a list of paths that
# exist. Shared by the observer check below and by the required-gate parser.
function Get-StopRegistrationFiles {
    param([Parameter(Mandatory = $true)]$HookInput)
    $client = Get-HookClientId
    $root = [string]$env:CLAUDE_PROJECT_DIR
    if ($client -ne 'claude' -or [string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-Field $HookInput 'cwd') }
    if ([string]::IsNullOrWhiteSpace($root)) { return @() }
    $files = switch ($client) {
        'claude' { @((Join-Path $root '.claude\settings.local.json'), (Join-Path $root '.claude\settings.json'), (Join-Path $script:GateReceiptGlobalRoot '.claude\settings.json')) }
        'codex' { @((Join-Path $root '.codex\hooks.json'), (Join-Path $script:GateReceiptGlobalRoot '.codex\hooks.json')) }
        default { @() }
    }
    return @($files | Where-Object { [IO.File]::Exists($_) })
}

# A receipt is state, and state is only written where something reads it: the
# summary observer must be registered in this client's own files. A project
# without it gets no receipt at all (the same rule the Stop ledger follows).
function Test-StopObserverRegistered {
    param([Parameter(Mandatory = $true)]$HookInput)
    foreach ($file in @(Get-StopRegistrationFiles -HookInput $HookInput)) {
        try {
            if ([IO.File]::ReadAllText($file) -match '[\\/]+Hook-Maker[\\/]+Session-Summary-Check[\\/]+Session-Summary-Check\.ps1') { return $true }
        }
        catch { }
    }
    return $false
}

# Receipts are keyed per session, so a project's old ones are pruned when a new
# round starts: bounded by project, never a machine-wide sweep.
function Remove-StaleStopGateReceipts {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $dir = Split-Path -Parent $Path
        $prefix = ([IO.Path]::GetFileName($Path) -split '-')[0..1] -join '-'
        $cutoff = [DateTime]::UtcNow.AddDays(-3)
        foreach ($old in @(Get-ChildItem -LiteralPath $dir -File -Filter ($prefix + '-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -lt $cutoff } | Select-Object -First 200)) {
            try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop } catch { }
        }
    }
    catch { }
}

# Called by a gate once it has its input. Returns $null when this is not a Stop
# round, when no summary observer is registered to read the receipt, or when
# the gate is standing down on its own re-entry (its block is already the
# round's verdict and must not be overwritten).
function Start-StopGateReceipt {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$HookName)
    $eventName = [string](Get-Field $HookInput 'hook_event_name')
    if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { return $null }
    if ($null -ne (Get-Command Test-StopStandDown -ErrorAction SilentlyContinue)) {
        try { if (Test-StopStandDown -HookInput $HookInput -HookName $HookName) { return $null } } catch { }
    }
    $path = Get-StopGateReceiptPath -HookInput $HookInput -Gate $HookName
    if ($path -eq '') { return $null }
    if (-not (Test-StopObserverRegistered -HookInput $HookInput)) { return $null }
    $script:StopGateVerdict = ''
    Remove-StaleStopGateReceipts -Path $path
    Write-StopGateReceiptFile -Path $path -Gate $HookName -Verdict 'running'
    return [pscustomobject]@{ Path = $path; Gate = $HookName; Crashed = $false }
}

function Complete-StopGateReceipt {
    param($Receipt)
    if ($null -eq $Receipt) { return }
    $verdict = 'pass'
    if ($Receipt.Crashed) { $verdict = 'error' }
    elseif ($script:StopGateVerdict -eq 'block') { $verdict = 'block' }
    Write-StopGateReceiptFile -Path $Receipt.Path -Gate $Receipt.Gate -Verdict $verdict
}

# The gates the CLIENT registered for this event, read from its own
# registration files - never guessed from what happens to be installed. Returns
# Known=$false when no registration file exists or one cannot be read:
# readiness is then unknown, never assumed.
function Get-RequiredStopGates {
    param([Parameter(Mandatory = $true)]$HookInput)
    $eventName = [string](Get-Field $HookInput 'hook_event_name')
    # No registration file at all is UNKNOWN, not "no gates": the observer then
    # cannot tell a gate-free project from one whose registration it failed to find.
    $files = @(Get-StopRegistrationFiles -HookInput $HookInput)
    if ($files.Count -eq 0) { return [pscustomobject]@{ Known = $false; Gates = @() } }
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($file in $files) {
        try {
            $doc = [IO.File]::ReadAllText($file, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
            $hooks = Get-Field $doc 'hooks'
            if ($null -eq $hooks) { continue }
            foreach ($group in @(Get-Field $hooks $eventName)) {
                if ($null -eq $group) { continue }
                foreach ($handler in @(Get-Field $group 'hooks')) {
                    if ($null -eq $handler) { continue }
                    foreach ($field in @('command', 'commandWindows')) {
                        $command = [string](Get-Field $handler $field)
                        $m = [regex]::Match($command, '[\\/]Hook-Maker[\\/]([A-Za-z0-9.-]{1,64})[\\/]([A-Za-z0-9.-]{1,64})\.ps1')
                        if ($m.Success -and $m.Groups[1].Value -ceq $m.Groups[2].Value -and $script:ReceiptGateNames -ccontains $m.Groups[1].Value) {
                            [void]$names.Add($m.Groups[1].Value)
                        }
                    }
                }
            }
        }
        catch { return [pscustomobject]@{ Known = $false; Gates = @() } }
    }
    return [pscustomobject]@{ Known = $true; Gates = @($names | Sort-Object) }
}

# Waits, bounded, until every required gate has a TERMINAL receipt written in
# this round (at or after $Since), then reports each gate's verdict. A receipt
# older than $Since belongs to an earlier round and is not evidence for this one.
function Wait-StopGateReceipts {
    param([Parameter(Mandatory = $true)]$HookInput, [string[]]$Gates, [DateTime]$Since, [int]$TimeoutMs = $script:GateReceiptWaitMs)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $results = @{}
    while ($true) {
        $pending = 0
        foreach ($gate in $Gates) {
            $receipt = Read-StopGateReceipt -Path (Get-StopGateReceiptPath -HookInput $HookInput -Gate $gate)
            $state = 'no-receipt'
            if ($null -ne $receipt -and $receipt.At -ge $Since -and $receipt.Verdict -in $script:ReceiptTerminalVerdicts) { $state = $receipt.Verdict }
            else { $pending++ }
            $results[$gate] = $state
        }
        if ($pending -eq 0 -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 250
    }
    return $results
}
