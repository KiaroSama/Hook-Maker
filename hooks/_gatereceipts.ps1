# Affirmative Stop evidence, scoped to the work/actor that actually produced it.
# A completion owns one attempt token. It cannot overwrite a different attempt,
# another actor, another turn, or another closing response. Concurrent attempts
# are combined conservatively: a running/error/block attempt is never a pass.
# These receipts attest discovered managed hooks, not the client's display order.
Set-StrictMode -Version 2.0

$script:ReceiptGateNames = @(
    'Ai-Memory-Check', 'Ci-Status-Check', 'Cloudflare-Deploy', 'Docs-Freshness-Check',
    'Feature-Request-Check', 'Git-Sync-Check', 'Graph-Update-Check', 'Ignore-Rules-Check',
    'Large-File-Check', 'Mcp-Usage-Check', 'Rules-Check', 'Secrets-Check', 'Skills-Check',
    'Test-Completion-Check', 'Test-Temp-Cleanup', 'Utf8-Encoding-Check'
)
$script:ReceiptTerminalVerdicts = @('pass', 'block', 'error')
$script:StopGateVerdict = ''
$script:GateReceiptGlobalRoot = $HOME
$script:GateReceiptWaitMs = 8000

function Get-StopReceiptDigest {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-StopReceiptScope {
    param($HookInput)
    $session = [string](Get-Field $HookInput 'session_id')
    $client = Get-HookClientId
    $root = [string](Get-Field $HookInput 'cwd')
    $eventName = [string](Get-Field $HookInput 'hook_event_name')
    if ([string]::IsNullOrWhiteSpace($session) -or $client -eq 'unknown' -or [string]::IsNullOrWhiteSpace($root) -or
        $eventName -cnotin @('Stop', 'SubagentStop')) { return $null }
    $actor = Get-StopAgentKey -HookInput $HookInput
    if ($eventName -ceq 'SubagentStop' -and [string]::IsNullOrWhiteSpace([string](Get-Field $HookInput 'agent_id'))) { return $null }
    $identity = Get-CurrentUserTaskIdentity -HookInput $HookInput
    $turn = [string](Get-Field $HookInput 'turn_id')
    $task = if ($null -ne $identity -and -not $identity.Degraded) { [string]$identity.TaskId } else { '' }
    if ($task -eq '' -and $turn -eq '') { return $null }
    $closing = Get-ClosingAssistantText -HookInput $HookInput
    if (-not $closing.Known) { return $null }
    $project = Get-StopProjectKey -ProjectRoot $root
    $configuration = Get-RequiredStopGates -HookInput $HookInput
    if (-not $configuration.Known) { return $null }
    # JSON framing prevents separator characters in user-supplied identifiers
    # from aliasing another scope. Raw answers/identifiers never enter the file.
    $key = @($project, $client, $session, $actor, $eventName, $task, $turn,
        [string](Get-Field $HookInput 'stop_hook_active'), (Get-StopReceiptDigest $closing.Text), $configuration.Fingerprint) | ConvertTo-Json -Compress
    return [pscustomobject]@{ Project = $project; Id = (Get-StopReceiptDigest $key) }
}

function Get-StopGateReceiptPath {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$Gate)
    if ($Gate -cnotmatch '^[A-Za-z0-9-]{1,64}$') { return '' }
    $scope = Get-StopReceiptScope -HookInput $HookInput
    if ($null -eq $scope) { return '' }
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('GateReceipt-v2-' + $scope.Project + '-' + $scope.Id + '-' + $Gate + '.json'))
}

function ConvertFrom-StopReceiptDocument {
    param([string]$Path, [string]$ScopeId, [string]$Gate)
    if (-not [IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 65536) { throw 'receipt missing or oversized' }
    $raw = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $doc = $raw | ConvertFrom-Json -DateKind String }
    else { $doc = $raw | ConvertFrom-Json }
    if ($doc -isnot [Management.Automation.PSCustomObject] -or $doc.schema -is [string] -or $doc.schema -ne 2 -or
        $doc.scope -isnot [string] -or $doc.scope -cne $ScopeId -or $doc.gate -isnot [string] -or $doc.gate -cne $Gate -or
        $doc.attempts -isnot [System.Array] -or $doc.attempts.Count -lt 1 -or $doc.attempts.Count -gt 64) { throw 'receipt shape or provenance' }
    $seen = @{}
    foreach ($attempt in $doc.attempts) {
        if ($attempt.id -isnot [string] -or $attempt.id -cnotmatch '^[a-f0-9]{32}$' -or $seen.ContainsKey($attempt.id) -or
            $attempt.verdict -isnot [string] -or $attempt.verdict -cnotin (@('running') + $script:ReceiptTerminalVerdicts)) { throw 'receipt attempt identity' }
        $seen[$attempt.id] = $true
        $started = [DateTime]::MinValue; $at = [DateTime]::MinValue
        foreach ($name in @('started', 'at')) {
            $date = [DateTime]::MinValue
            if ($attempt.$name -isnot [string] -or -not [DateTime]::TryParseExact($attempt.$name, 'o', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$date) -or $date.Kind -eq [DateTimeKind]::Unspecified -or
                $date.ToUniversalTime() -gt [DateTime]::UtcNow.AddSeconds(1)) { throw 'receipt timestamp' }
            if ($name -eq 'started') { $started = $date } else { $at = $date }
        }
        if ($at -lt $started) { throw 'receipt timestamp order' }
    }
    return $doc
}

function Write-StopGateReceiptFile {
    param([string]$Path, [string]$Gate, [string]$Verdict, [string]$AttemptId = '')
    # A legacy writer without an owned token cannot manufacture v2 evidence.
    if ($AttemptId -cnotmatch '^[a-f0-9]{32}$' -or $Verdict -cnotin (@('running') + $script:ReceiptTerminalVerdicts)) { return $false }
    $match = [regex]::Match([IO.Path]::GetFileName($Path), '^GateReceipt-v2-[a-f0-9]+-([a-f0-9]{64})-([A-Za-z0-9-]{1,64})\.json$')
    if (-not $match.Success -or $match.Groups[2].Value -cne $Gate) { return $false }
    $scopeId = $match.Groups[1].Value
    $handle = $null; $temp = ''
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            try { $handle = [IO.File]::Open(($Path + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch { if ($clock.ElapsedMilliseconds -ge 500) { return $false }; Start-Sleep -Milliseconds 10 }
        } while ($null -eq $handle)
        $doc = if ([IO.File]::Exists($Path)) { ConvertFrom-StopReceiptDocument $Path $scopeId $Gate } else {
            [pscustomobject]@{ schema = 2; scope = $scopeId; gate = $Gate; attempts = @() }
        }
        $owned = @($doc.attempts | Where-Object { $_.id -ceq $AttemptId })
        if ($Verdict -ceq 'running') {
            if ($owned.Count -gt 0) { return ($owned[0].verdict -ceq 'running') }
            if ($doc.attempts.Count -ge 64) { return $false }
            $stamp = [DateTime]::UtcNow.ToString('o')
            $doc.attempts = @(@($doc.attempts) + [pscustomobject]@{ id = $AttemptId; verdict = 'running'; started = $stamp; at = $stamp })
        }
        else {
            if ($owned.Count -ne 1) { return $false }
            if ($owned[0].verdict -cne 'running') { return ($owned[0].verdict -ceq $Verdict) }
            $owned[0].verdict = $Verdict; $owned[0].at = [DateTime]::UtcNow.ToString('o')
        }
        $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Depth 5 -Compress), (New-Object Text.UTF8Encoding($false)))
        $null = ConvertFrom-StopReceiptDocument $temp $scopeId $Gate
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
        $temp = ''; return $true
    }
    catch { return $false }
    finally {
        if ($temp -ne '' -and [IO.File]::Exists($temp)) { try { [IO.File]::Delete($temp) } catch { } }
        if ($null -ne $handle) { $handle.Dispose() }
        # Never unlink a lock inode a waiting writer may already own.
    }
}

function Read-StopGateReceipt {
    param([string]$Path, [DateTime]$Since = [DateTime]::MinValue)
    try {
        $match = [regex]::Match([IO.Path]::GetFileName($Path), '^GateReceipt-v2-[a-f0-9]+-([a-f0-9]{64})-([A-Za-z0-9-]{1,64})\.json$')
        if (-not $match.Success) { return $null }
        $doc = ConvertFrom-StopReceiptDocument $Path $match.Groups[1].Value $match.Groups[2].Value
        $rows = @($doc.attempts | Where-Object { [DateTime]::Parse($_.started, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() -ge $Since.ToUniversalTime() })
        if ($rows.Count -eq 0) { return $null }
        $verdict = 'pass'
        if (@($rows | Where-Object { $_.verdict -ceq 'error' }).Count) { $verdict = 'error' }
        elseif (@($rows | Where-Object { $_.verdict -ceq 'block' }).Count) { $verdict = 'block' }
        elseif (@($rows | Where-Object { $_.verdict -ceq 'running' }).Count) { $verdict = 'running' }
        $newest = @($rows | ForEach-Object { [DateTime]::Parse($_.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } | Sort-Object -Descending)[0]
        return [pscustomobject]@{ Verdict = $verdict; At = $newest; Attempts = $rows.Count; RunningCount = @($rows | Where-Object { $_.verdict -ceq 'running' }).Count; Scope = $doc.scope }
    }
    catch { return $null }
}

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
    # Keep an existing directory/unreadable entry so the parser reports UNKNOWN
    # instead of silently treating an invalid registration as absent.
    return @($files | Where-Object { Test-Path -LiteralPath $_ -ErrorAction Stop } | Sort-Object -Unique)
}

function Test-StopReceiptMatcher {
    param($Group, $HookInput)
    if ([string](Get-Field $HookInput 'hook_event_name') -cne 'SubagentStop') { return $true }
    $matcher = Get-Field $Group 'matcher'
    if ($null -eq $matcher -or $matcher -ceq '' -or $matcher -ceq '*') { return $true }
    if ($matcher -isnot [string]) { throw 'matcher type' }
    $agentType = [string](Get-Field $HookInput 'agent_type')
    if ([string]::IsNullOrWhiteSpace($agentType)) { throw 'agent type unavailable' }
    # Codex uses unanchored regex, while Claude uses exact literal lists for
    # simple names. Do not silently give the two clients the same semantics.
    if ((Get-HookClientId) -ceq 'codex') {
        if ($matcher -cnotmatch '^[A-Za-z0-9_|\-]+$') { throw 'matcher needs client resolution' }
        foreach ($part in @($matcher -split '[|]')) {
            if ($agentType.IndexOf($part, [StringComparison]::Ordinal) -ge 0) { return $true }
        }
        return $false
    }
    # Hyphens changed semantics in Claude 2.1.195. No authenticated client
    # version is available here, so that ambiguous case remains UNKNOWN.
    if ($matcher -cnotmatch '^[A-Za-z0-9_ ,|]+$') { throw 'matcher needs client version/resolution' }
    return (@($matcher -split '[,|]' | ForEach-Object { $_.Trim() }) -ccontains $agentType)
}

function Get-RequiredStopGates {
    param([Parameter(Mandatory = $true)]$HookInput)
    $unknown = [pscustomobject]@{ Known = $false; Gates = @(); Observer = $false; Fingerprint = ''; Coverage = 'discovered-managed' }
    try {
        $files = @(Get-StopRegistrationFiles $HookInput)
        if ($files.Count -eq 0) { return $unknown }
        $eventName = [string](Get-Field $HookInput 'hook_event_name')
        if ($eventName -cnotin @('Stop', 'SubagentStop')) { return $unknown }
        $names = @{}; $commands = @{}; $observer = $false; $hashes = @()
        foreach ($file in $files) {
            if (-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file -ErrorAction Stop).Length -gt 1048576) { return $unknown }
            $raw = [IO.File]::ReadAllText($file, (New-Object Text.UTF8Encoding($false, $true)))
            $hashes += @($file, (Get-StopReceiptDigest $raw))
            $doc = $raw | ConvertFrom-Json
            if ($doc -isnot [Management.Automation.PSCustomObject]) { return $unknown }
            $property = $doc.PSObject.Properties['hooks']
            if ($null -eq $property) { continue }
            if ($property.Value -isnot [Management.Automation.PSCustomObject]) { return $unknown }
            $groups = $property.Value.PSObject.Properties[$eventName]
            if ($null -eq $groups) { continue }
            if ($groups.Value -isnot [System.Array]) { return $unknown }
            foreach ($group in $groups.Value) {
                if ($group -isnot [Management.Automation.PSCustomObject] -or $null -eq $group.PSObject.Properties['hooks'] -or $group.hooks -isnot [System.Array]) { return $unknown }
                if (-not (Test-StopReceiptMatcher $group $HookInput)) { continue }
                foreach ($handler in $group.hooks) {
                    if ($handler -isnot [Management.Automation.PSCustomObject]) { return $unknown }
                    if ([string](Get-Field $handler 'type') -cne 'command') { continue }
                    $command = Get-Field $handler 'command'
                    if ((Get-HookClientId) -ceq 'codex' -and $null -ne $handler.PSObject.Properties['commandWindows']) { $command = $handler.commandWindows }
                    if ($command -isnot [string]) { return $unknown }
                    $parts = @($command)
                    $argsProperty = $handler.PSObject.Properties['args']
                    if ($null -ne $argsProperty) {
                        if ($argsProperty.Value -isnot [System.Array]) { return $unknown }
                        foreach ($argument in $argsProperty.Value) { if ($argument -isnot [string]) { return $unknown }; $parts += $argument }
                    }
                    $combined = $parts -join ' '
                    $matches = [regex]::Matches($combined, '[\\/]Hook-Maker[\\/]([A-Za-z0-9.-]{1,64})[\\/]([A-Za-z0-9.-]{1,64})\.ps1')
                    if ($matches.Count -eq 0) { continue }
                    if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -cne $matches[0].Groups[2].Value) { return $unknown }
                    $name = $matches[0].Groups[1].Value
                    if ($name -ceq 'Session-Summary-Check') { $observer = $true; continue }
                    if ($script:ReceiptGateNames -cnotcontains $name) { continue }
                    if ($null -ne (Get-Field $handler 'if') -or (Get-Field $handler 'async') -eq $true) { return $unknown }
                    # Distinct registrations of one gate cannot be proven by
                    # one gate-name receipt; refuse rather than collapse them.
                    $signature = $parts | ConvertTo-Json -Compress
                    if ($commands.ContainsKey($name) -and $commands[$name] -cne $signature) { return $unknown }
                    $commands[$name] = $signature; $names[$name] = $true
                }
            }
        }
        return [pscustomobject]@{ Known = $true; Gates = @($names.Keys | Sort-Object); Observer = $observer;
            Fingerprint = (Get-StopReceiptDigest ($hashes | ConvertTo-Json -Compress)); Coverage = 'discovered-managed' }
    }
    catch { return $unknown }
}

function Test-StopObserverRegistered {
    param([Parameter(Mandatory = $true)]$HookInput)
    $configuration = Get-RequiredStopGates $HookInput
    return ($configuration.Known -and $configuration.Observer)
}

function Remove-StaleStopGateReceipts {
    param([Parameter(Mandatory = $true)][string]$Path)
    # Receipt snapshots are not correction allowances. Only completed old
    # snapshots within THIS project may go; never unlink their stable lock.
    try {
        $m = [regex]::Match([IO.Path]::GetFileName($Path), '^(GateReceipt-v2-[a-f0-9]+)-')
        if (-not $m.Success) { return }
        foreach ($old in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -File -Filter ($m.Groups[1].Value + '-*.json') -ErrorAction Stop | Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-3) } | Select-Object -First 200)) {
            $handle = $null
            try {
                $handle = [IO.File]::Open(($old.FullName + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
                $receipt = Read-StopGateReceipt $old.FullName
                if ($null -ne $receipt -and $receipt.RunningCount -eq 0 -and $receipt.At -lt [DateTime]::UtcNow.AddDays(-3)) { [IO.File]::Delete($old.FullName) }
            }
            catch { }
            finally { if ($null -ne $handle) { $handle.Dispose() } }
        }
    }
    catch { }
}

function Start-StopGateReceipt {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$HookName)
    $eventName = [string](Get-Field $HookInput 'hook_event_name')
    if ($eventName -cnotin @('Stop', 'SubagentStop')) { return $null }
    if (Test-StopStandDown -HookInput $HookInput -HookName $HookName) { return $null }
    $path = Get-StopGateReceiptPath $HookInput $HookName
    if ($path -eq '' -or -not (Test-StopObserverRegistered $HookInput)) { return $null }
    $script:StopGateVerdict = ''
    Remove-StaleStopGateReceipts $path
    $token = [guid]::NewGuid().ToString('N')
    if (-not (Write-StopGateReceiptFile $path $HookName 'running' $token)) { return $null }
    return [pscustomobject]@{ Path = $path; Gate = $HookName; AttemptId = $token; Crashed = $false }
}

function Complete-StopGateReceipt {
    param($Receipt)
    if ($null -eq $Receipt) { return }
    $verdict = 'pass'
    if ($Receipt.Crashed) { $verdict = 'error' }
    elseif ($script:StopGateVerdict -ceq 'block') { $verdict = 'block' }
    $null = Write-StopGateReceiptFile $Receipt.Path $Receipt.Gate $verdict $Receipt.AttemptId
}

function Wait-StopGateReceipts {
    param([Parameter(Mandatory = $true)]$HookInput, [string[]]$Gates, [DateTime]$Since,
        [int]$TimeoutMs = $script:GateReceiptWaitMs, [string]$RegistrationFingerprint = '')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $limit = [Math]::Min(8000, [Math]::Max(0, $TimeoutMs))
    $results = @{}; $initial = Get-RequiredStopGates $HookInput
    $fingerprint = if ($RegistrationFingerprint -ne '') { $RegistrationFingerprint } else { $initial.Fingerprint }
    $paths = @{}; foreach ($gate in $Gates) { $paths[$gate] = Get-StopGateReceiptPath $HookInput $gate }
    do {
        $pending = 0
        foreach ($gate in $Gates) {
            $receipt = Read-StopGateReceipt -Path $paths[$gate] -Since $Since
            $state = 'no-receipt'
            if ($null -ne $receipt -and $receipt.Verdict -cin $script:ReceiptTerminalVerdicts) { $state = $receipt.Verdict } else { $pending++ }
            $results[$gate] = $state
        }
        if ($pending -eq 0 -or $clock.ElapsedMilliseconds -ge $limit) { break }
        Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Max(1, $limit - $clock.ElapsedMilliseconds)))
    } while ($true)
    $current = Get-RequiredStopGates $HookInput
    if (-not $current.Known -or $current.Fingerprint -cne $fingerprint -or -not $initial.Known) {
        foreach ($gate in $Gates) { $results[$gate] = 'registration-changed' }
    }
    return $results
}
