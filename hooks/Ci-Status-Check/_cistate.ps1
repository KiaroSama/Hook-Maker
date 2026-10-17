# Serialized atomic CI records: concurrent pending writers cannot clobber an
# fresh proven carryover for the same SHA or split a versioned receipt.
$ciProofRoot = if ([IO.File]::Exists((Join-Path $PSScriptRoot '_ciprovenance.ps1'))) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $ciProofRoot '_ciprovenance.ps1')
function Write-CiStateAtomic {
    param([string]$Path, [string[]]$Lines)
    $mutex = New-Object Threading.Mutex($false, ('Local\HookMaker-CiState-' + (Get-ShortHash $Path.ToLowerInvariant())))
    $owned = $false; $temporary = ''
    try {
        $waitMs = 1000
        if (Get-Command Get-HookRemainingSeconds -ErrorAction SilentlyContinue) { $waitMs = [Math]::Min($waitMs, 1000 * (Get-HookRemainingSeconds)) }
        if ($waitMs -le 0) { return $false }
        try { $owned = $mutex.WaitOne($waitMs) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return $false }
        if ([IO.File]::Exists($Path)) {
            $old = @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))
            $previous = Read-CiCarryover -Lines $old -Sha $Lines[0] -NoticeIdentityOnly
            $fresh = Read-CiCarryover -Lines $old -Sha $Lines[0]
            $incoming = Read-CiCarryover -Lines $Lines -Sha $Lines[0]
            if (($Lines[1] -eq 'pending' -and $null -ne $fresh) -or
                ($null -ne $previous -and $null -ne $incoming -and
                    $incoming.repository -ieq $previous.repository -and $incoming.parent -ceq $previous.parent -and
                    $incoming.sourceFingerprint -ceq $previous.sourceFingerprint)) { return $false }
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllLines($temporary, $Lines, (New-Object Text.UTF8Encoding $false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
        return $true
    }
    catch { return $false }
    finally {
        if ($temporary -ne '' -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    }
}
function Save-State {
    param([string]$Outcome, [string]$Evidence = '')
    $when = [DateTimeOffset]::UtcNow.ToString('o')
    $lines = @($script:sha, $Outcome, $when, $Evidence)
    if ($Evidence -ceq 'ci-green') {
        $current = Get-Variable snapshot -ValueOnly -ErrorAction SilentlyContinue
        if ($null -eq $current -or -not $current.AllSuccess -or $null -eq (Get-Field $current 'Provenance')) { return }
        $proof = $current.Provenance
        $script:CiStateWriteAccepted = $false
        $proof.observedUtc = $when
        $lines += ($proof | ConvertTo-Json -Depth 12 -Compress)
        if ($null -eq (Read-CiProvenance -Lines $lines -Repository $script:repoSlug -Sha $script:sha)) { return }
    }
    $script:CiStateWriteAccepted = Write-CiStateAtomic -Path $script:statePath -Lines $lines
    if (-not $script:CiStateWriteAccepted -and $Outcome -eq 'pending') {
        $lines = @(); try { $lines = @([IO.File]::ReadAllLines($script:statePath, [Text.Encoding]::UTF8)) } catch { }
        if ($null -ne (Read-CiCarryover -Lines $lines -Repository $script:repoSlug -Sha $script:sha)) { exit 0 }
    }
}

# Existing cooldown semantics, with one recovery opportunity when pending has
# overwritten the green cache. Remote final-SHA evidence still precedes carryover.
function Invoke-CiStateGate {
    $stateSha = ''; $stateOutcome = ''; $stateTime = [DateTime]::MinValue
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $stateLines = [IO.File]::ReadAllLines($statePath, [Text.Encoding]::UTF8)
            if ($stateLines.Count -ge 3) {
                $stateSha = $stateLines[0].Trim(); $stateOutcome = $stateLines[1].Trim()
                $stateTime = [DateTime]::Parse($stateLines[2].Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            }
        }
        catch { }
    }
    if ($null -ne $prefetchedSnapshot -or $stateSha -cne $sha) { return }
    # A matching historical label cannot prove current workload provenance.
    # Fresh bounded evaluation below is required even for a versioned receipt.
    if ($stateOutcome -eq 'verified') { return }
    if ($stateOutcome -eq 'pending') {
        $message = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'log', '-1', '--format=%B', $sha)) -join "`n"
        if ($LASTEXITCODE -eq 0 -and (Test-CommitHasSkipMarker $message)) {
            $script:prefetchedSnapshot = Get-CiRunSnapshot -RepoSlug $repoSlug -Sha $sha -ProjectRoot $cwd -Branch $branch
            # Use the newly read final-SHA snapshot, rather than repeating a
            # cached pending complaint. Unknown lookup keeps the old cooldown.
            if ($null -ne $script:prefetchedSnapshot) { return }
        }
    }
    $ageMinutes = ([DateTime]::UtcNow - $stateTime).TotalMinutes
    if ($stateOutcome -eq 'failed' -and $ageMinutes -lt $failureCooldown) {
        $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Ci-Status-Check' -EventName $eventName -Reason ('CI CHECK: pushed commit ' + $sha7 + ' still has failed checks. Detailed failure guidance was recently reported; completion remains blocked until a replacement commit is pushed or the failure is reported as an external/manual blocker.')
        exit $emit.ExitCode
    }
    if ($stateOutcome -eq 'pending' -and $ageMinutes -lt $pendingCooldown) {
        $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Ci-Status-Check' -EventName $eventName -Reason ('CI CHECK: pushed commit ' + $sha7 + ' is still awaiting terminal checks. Detailed status was recently reported; completion remains blocked.')
        exit $emit.ExitCode
    }
}
