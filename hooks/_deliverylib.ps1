# Atomic reminder reservations, not proof of UI delivery or task completion.
# A stable lock serializes the check and reservation; only its owner may emit.
# Records contain hashes and UTC ticks, never prompts, tool arguments or secrets.
# Expiration is permitted only for explicitly time-limited informational notes.
# Persistent gate receipts are never evicted merely to make room for another.

function Get-DeliveryIdentity {
    param([Parameter(Mandatory = $true)]$HookInput)
    $session = Get-Field $HookInput 'session_id'
    $client = Get-HookClientId
    if ($session -isnot [string] -or [string]::IsNullOrWhiteSpace($session) -or $client -eq 'unknown') { return '' }
    return (@($client, $session, (Get-StopAgentKey -HookInput $HookInput)) | ConvertTo-Json -Compress)
}

function Get-DeliveryHash {
    param([Parameter(Mandatory = $true)][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-DeliveryClaim {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Identity,
        [AllowEmptyString()][string]$Fingerprint,
        # -1 means persistent per-actor last-state suppression; 0 means no delay.
        [ValidateRange(-1, 1440)][int]$CooldownMinutes = -1,
        [switch]$Force
    )
    $answer = [pscustomobject]@{ Ok = $false; Admitted = $false; Reason = 'identity-unavailable' }
    if ([string]::IsNullOrWhiteSpace($Identity) -or [string]::IsNullOrWhiteSpace($Fingerprint)) { return $answer }
    $lock = $null; $temporary = ''; $now = [DateTime]::UtcNow.Ticks
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            try { $lock = [IO.File]::Open(($Path + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch { if ($clock.ElapsedMilliseconds -ge 2000) { $answer.Reason = 'busy'; return $answer }; Start-Sleep -Milliseconds 25 }
        } while ($null -eq $lock)
        $document = [pscustomobject]@{ schema = 1; entries = [pscustomobject]@{} }
        if ([IO.File]::Exists($Path)) {
            if ((New-Object IO.FileInfo($Path)).Length -gt 1048576) { $answer.Reason = 'capacity'; return $answer }
            $document = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json -ErrorAction Stop
            if ($document -isnot [System.Management.Automation.PSCustomObject] -or
                $null -eq $document.PSObject.Properties['schema'] -or $document.schema -ne 1 -or
                $null -eq $document.PSObject.Properties['entries'] -or $document.entries -isnot [System.Management.Automation.PSCustomObject]) {
                $answer.Reason = 'invalid-state'; return $answer
            }
        }
        $properties = @($document.entries.PSObject.Properties)
        if ($properties.Count -gt 1024) { $answer.Reason = 'capacity'; return $answer }
        foreach ($property in $properties) {
            $entry = $property.Value; $reserved = [int64]0; $expires = [int64]0
            if ($property.Name -cnotmatch '^[0-9a-f]{64}$' -or
                [string](Get-Field $entry 'fingerprint') -cnotmatch '^[0-9a-f]{64}$' -or
                -not [int64]::TryParse([string](Get-Field $entry 'reservedTicks'), [ref]$reserved) -or
                -not [int64]::TryParse([string](Get-Field $entry 'expiresTicks'), [ref]$expires) -or
                $reserved -le 0 -or $reserved -gt [DateTime]::UtcNow.AddMinutes(5).Ticks -or
                ($expires -ne 0 -and ($expires -lt $reserved -or $expires -gt [DateTime]::MaxValue.Ticks))) {
                $answer.Reason = 'invalid-state'; return $answer
            }
            if ($expires -gt 0 -and $expires -le $now) { $document.entries.PSObject.Properties.Remove($property.Name) }
        }
        $key = Get-DeliveryHash $Identity; $fingerprintHash = Get-DeliveryHash $Fingerprint
        $prior = $document.entries.PSObject.Properties[$key]
        if (-not $Force -and $CooldownMinutes -ne 0 -and $null -ne $prior -and $prior.Value.fingerprint -ceq $fingerprintHash) {
            return [pscustomobject]@{ Ok = $true; Admitted = $false; Reason = 'already-reserved' }
        }
        if ($null -eq $prior -and @($document.entries.PSObject.Properties).Count -ge 1024) { $answer.Reason = 'capacity'; return $answer }
        $expires = if ($CooldownMinutes -lt 0) { [int64]0 } else { ([DateTime]::new($now, [DateTimeKind]::Utc)).AddMinutes($CooldownMinutes).Ticks }
        $entry = [pscustomobject]@{ fingerprint = $fingerprintHash; reservedTicks = [string]$now; expiresTicks = [string]$expires }
        Set-ObjectProperty -Object $document.entries -Name $key -Value $entry
        $json = $document | ConvertTo-Json -Depth 6 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1048576) { $answer.Reason = 'capacity'; return $answer }
        $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
        return [pscustomobject]@{ Ok = $true; Admitted = $true; Reason = 'reserved' }
    }
    catch { $answer.Reason = 'state-unavailable'; return $answer }
    finally {
        if ($temporary -ne '' -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ($null -ne $lock) { $lock.Dispose() }
        # Do not unlink a stable lock while another process is opening it.
    }
}
