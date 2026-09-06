# Test-Completion-Check: THE INCIDENT LEDGER.
#
# This hook's own durable state, and the invariants that make it correct. Two
# concurrent incidents each need their own resolved-state AND their own note
# obligation: a single scalar slot let one overwrite the other, so a resolved
# incident could re-block forever and a note requirement could vanish before it
# was ever evaluated. Everything that reads, merges, bounds and writes that
# ledger lives here - including the concurrent-Stop merge that must not lose an
# update.
#
# Dot-sourced by Test-Completion-Check.ps1 via $PSScriptRoot, which resolves the
# same way here and in an installed runtime directory.


# ---- this hook's own state (a per-incident LEDGER, not single slots) --------
# TWO independent concurrent incidents (run A and run B both terminated/leaked)
# each need their OWN resolved-state AND their own note obligation. A single
# scalar slot let B overwrite A: A then re-blocked and, once re-resolved,
# forgot B - an unbounded ping-pong, and A's note requirement could vanish
# before it was ever evaluated. So the state is now:
#   resolvedIncidents : a BOUNDED, most-recent-first-capped SET of resolved
#                       incident keys (membership, never a single equality).
#   pendingNotes      : a BOUNDED, insertion-ordered MAP incidentKey -> { reason,
#                       baseline } - each obligation carries the note-byte
#                       snapshot taken when IT was registered, so two concurrent
#                       incidents demand two DISTINCT notes and resolving one
#                       never forgets the other.
# The old single-value shape is migrated forward on read; the collection shape
# is always written. Bounded (caps below) and secret-free, still plain JSON.
$script:MaxResolvedIncidents = 50
$script:MaxPendingNotes = 50
# An ABANDONED active marker that has aged past the horizon is reconciled, not
# silently deleted: the run it described really did die without recording how,
# and erasing that with no trace is exactly the ownerless-task blind spot this
# gate exists to close. It is a TRACE, not an obligation - a previous session's
# leftover must not block the current task - so it lives here rather than in
# pendingNotes, bounded and oldest-first-capped like everything else.
$script:MaxExpiredMarkers = 20
$script:expiredMarkers = New-Object System.Collections.Generic.List[object]
$script:resolvedIncidents = New-Object System.Collections.Generic.List[string]
$script:pendingNotes = New-Object System.Collections.Specialized.OrderedDictionary
# Set when a newly-seen incident could NOT be tracked because the ledger is full
# of UNRESOLVED obligations. An unresolved note is never silently dropped to make
# room; the overflow is surfaced (a bounded block) so the backlog is cleared
# first. Kept bounded overall - the cap never grows.
$script:pendingOverflow = $false
$deferredFingerprint = ''

$previous = $null
try { $previous = Read-JsonFile $statePath } catch { $previous = $null }
if ($null -ne $previous) {
    $rawResolved = Get-Field $previous 'resolvedIncidents'
    if ($null -ne $rawResolved) {
        foreach ($k in @($rawResolved)) { $ks = [string]$k; if ($ks -ne '' -and -not $script:resolvedIncidents.Contains($ks)) { [void]$script:resolvedIncidents.Add($ks) } }
    }
    else {
        $legacyResolved = [string](Get-Field $previous 'resolvedIncident')   # old single-value form
        if ($legacyResolved -ne '') { [void]$script:resolvedIncidents.Add($legacyResolved) }
    }
    while ($script:resolvedIncidents.Count -gt $script:MaxResolvedIncidents) { $script:resolvedIncidents.RemoveAt(0) }

    $rawPending = Get-Field $previous 'pendingNotes'
    if ($null -ne $rawPending) {
        foreach ($entry in @($rawPending)) {
            $ek = [string](Get-Field $entry 'key')
            if ($ek -eq '' -or $script:pendingNotes.Contains($ek)) { continue }
            $eb = -1L; $rawEb = Get-Field $entry 'baseline'
            if ($null -ne $rawEb) { try { $eb = [int64]$rawEb } catch { $eb = -1L } }
            $script:pendingNotes[$ek] = [pscustomobject]@{ reason = [string](Get-Field $entry 'reason'); baseline = $eb }
        }
    }
    else {
        $legacyKey = [string](Get-Field $previous 'pendingNoteKey')   # old single-value form
        if ($legacyKey -ne '') {
            $lb = -1L; $rawLb = Get-Field $previous 'pendingNoteBaseline'
            if ($null -ne $rawLb) { try { $lb = [int64]$rawLb } catch { $lb = -1L } }
            $script:pendingNotes[$legacyKey] = [pscustomobject]@{ reason = [string](Get-Field $previous 'pendingNoteReason'); baseline = $lb }
        }
    }
    $rawExpired = Get-Field $previous 'expiredMarkers'
    if ($null -ne $rawExpired) {
        foreach ($e in @($rawExpired)) {
            $er = [string](Get-Field $e 'runId')
            if ($er -eq '') { continue }   # the empty-array-as-'' JSON quirk, as resolvedIncidents guards it
            [void]$script:expiredMarkers.Add([pscustomobject]@{ runId = $er; detail = [string](Get-Field $e 'detail'); expiredUtc = [string](Get-Field $e 'expiredUtc') })
        }
        while ($script:expiredMarkers.Count -gt $script:MaxExpiredMarkers) { $script:expiredMarkers.RemoveAt(0) }
    }
    $deferredFingerprint = [string](Get-Field $previous 'deferredFingerprint')
}
$script:deferredFingerprint = $deferredFingerprint

# Record that an abandoned active marker was expired and dropped. Deduplicated by
# runId so re-seeing the same leftover cannot grow the ledger; bounded oldest-first.
function Add-ExpiredMarker {
    param([string]$RunId, [string]$Detail)
    $key = if ([string]::IsNullOrWhiteSpace($RunId)) { '(no run id)' } else { $RunId }
    # .ToArray(), NOT @($list): the array subexpression over a List[object]
    # throws `Argument types do not match` on both Windows PowerShell 5.1 and
    # pwsh 7 (List[string] is fine, which is why the sibling loops below can use
    # it). Snapshotting is still the point - the loop may Add on the same list.
    foreach ($e in $script:expiredMarkers.ToArray()) { if ([string]$e.runId -eq $key) { return } }
    [void]$script:expiredMarkers.Add([pscustomobject]@{ runId = $key; detail = $Detail; expiredUtc = [DateTime]::UtcNow.ToString('o') })
    while ($script:expiredMarkers.Count -gt $script:MaxExpiredMarkers) { $script:expiredMarkers.RemoveAt(0) }
}

function Test-IncidentResolved {
    param([string]$Key)
    return (-not [string]::IsNullOrWhiteSpace($Key) -and $script:resolvedIncidents.Contains($Key))
}

# Move an incident key into the bounded resolved SET (most-recent-capped) and
# drop any pending-note obligation it had - resolving one incident.
function Add-ResolvedIncident {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    if (-not $script:resolvedIncidents.Contains($Key)) { [void]$script:resolvedIncidents.Add($Key) }
    while ($script:resolvedIncidents.Count -gt $script:MaxResolvedIncidents) { $script:resolvedIncidents.RemoveAt(0) }
    if ($script:pendingNotes.Contains($Key)) { $script:pendingNotes.Remove($Key) }
}

# Has this incident's owed note been written? Requires BOTH its own tag (so one
# note cannot clear a different incident) AND real added content past its byte
# baseline (so a bare tag with nothing else does not count).
function Test-PendingNoteSatisfied {
    param([string]$Key)
    if (-not $script:pendingNotes.Contains($Key)) { return $false }
    $entry = $script:pendingNotes[$Key]
    $base = [int64]$entry.baseline
    if ($base -lt 0) { return $false }
    if (((Get-NoteBytes -Root $script:cwd) - $base) -lt $script:MinNoteBytes) { return $false }
    return (Test-NoteTagPresent -Root $script:cwd -Key $Key)
}

# Register a durable-note obligation for one incident, capturing the CURRENT
# note-byte baseline so each incident demands its own added content. No-op when
# the incident is already resolved or already owes a note.
#
# On overflow the OLDEST entry is NOT blindly dropped (that could discard an
# unresolved lesson). A slot is freed only by evicting an obligation that is
# already SATISFIED (its tagged note is written); if every tracked obligation is
# still unresolved, the new one is not added and the overflow is surfaced instead,
# so an unresolved note is never lost and the cap still never grows.
function Register-PendingNote {
    param([string]$Key, [string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    if ($script:resolvedIncidents.Contains($Key) -or $script:pendingNotes.Contains($Key)) { return }
    if ($script:pendingNotes.Count -ge $script:MaxPendingNotes) {
        $freed = $false
        foreach ($existing in @($script:pendingNotes.Keys)) {
            if (Test-PendingNoteSatisfied -Key ([string]$existing)) {
                Add-ResolvedIncident ([string]$existing)   # satisfied -> resolved, frees a slot
                $freed = $true
                break
            }
        }
        if (-not $freed) {
            # ponytail: at MaxPendingNotes genuinely-unresolved incidents the newest
            # is surfaced as an overflow block rather than tracked individually - a
            # hard ceiling that keeps growth bounded without dropping a live lesson.
            $script:pendingOverflow = $true
            return
        }
    }
    $script:pendingNotes[$Key] = [pscustomobject]@{ reason = $Reason; baseline = (Get-NoteBytes -Root $script:cwd) }
}

# Earliest (smallest, so registered when fewer note bytes existed) of two
# baselines; a negative (unknown) baseline yields to a known one.
function Get-EarliestBaseline {
    param([int64]$A, [int64]$B)
    if ($A -lt 0) { return $B }
    if ($B -lt 0) { return $A }
    if ($A -lt $B) { return $A } else { return $B }
}

# RE-READ the on-disk ledger and MERGE it into the in-memory state, run INSIDE the
# cross-process lock right before writing. Two Stops racing on one project each
# read the same (possibly empty) ledger, mutate in memory, and overwrite the whole
# file; without this merge the later writer would clobber the earlier one's
# incidents. Union rules: resolvedIncidents unioned; pendingNotes unioned by key
# keeping the earliest baseline; a key that is resolved never remains pending. Our
# own prior write in this invocation merges idempotently.
function Merge-DiskLedger {
    $disk = $null
    try { $disk = Read-JsonFile $script:statePath } catch { $disk = $null }
    if ($null -eq $disk) { return }
    $diskResolved = Get-Field $disk 'resolvedIncidents'
    if ($null -ne $diskResolved) {
        foreach ($k in @($diskResolved)) {
            $ks = [string]$k
            if ($ks -ne '' -and -not $script:resolvedIncidents.Contains($ks)) { [void]$script:resolvedIncidents.Add($ks) }
        }
    }
    while ($script:resolvedIncidents.Count -gt $script:MaxResolvedIncidents) { $script:resolvedIncidents.RemoveAt(0) }
    $diskPending = Get-Field $disk 'pendingNotes'
    if ($null -ne $diskPending) {
        foreach ($entry in @($diskPending)) {
            $ek = [string](Get-Field $entry 'key')
            if ($ek -eq '' -or $script:resolvedIncidents.Contains($ek)) { continue }   # resolved wins over pending
            $eb = -1L; $rawEb = Get-Field $entry 'baseline'
            if ($null -ne $rawEb) { try { $eb = [int64]$rawEb } catch { $eb = -1L } }
            if ($script:pendingNotes.Contains($ek)) {
                $cur = $script:pendingNotes[$ek]
                $merged = Get-EarliestBaseline ([int64]$cur.baseline) $eb
                $script:pendingNotes[$ek] = [pscustomobject]@{ reason = [string]$cur.reason; baseline = $merged }
            }
            else {
                $script:pendingNotes[$ek] = [pscustomobject]@{ reason = [string](Get-Field $entry 'reason'); baseline = $eb }
            }
        }
    }
    $diskExpired = Get-Field $disk 'expiredMarkers'
    if ($null -ne $diskExpired) {
        foreach ($e in @($diskExpired)) { Add-ExpiredMarker -RunId ([string](Get-Field $e 'runId')) -Detail ([string](Get-Field $e 'detail')) }
    }
    foreach ($rk in @($script:resolvedIncidents)) { if ($script:pendingNotes.Contains($rk)) { $script:pendingNotes.Remove($rk) } }
    # ponytail: a merged union >MaxPendingNotes only in the pathological >50-distinct
    # -incident case the concurrent-Stop race never reaches; keep it bounded.
    while ($script:pendingNotes.Count -gt $script:MaxPendingNotes) {
        $oldest = @($script:pendingNotes.Keys)[0]
        if ($null -eq $oldest) { break }
        $script:pendingNotes.Remove([string]$oldest)
    }
}

# Persist the ledger. The whole read-merge-write runs under a project-keyed
# cross-process Mutex (the shared crash-aware-lock idea from
# scripts\_installregistry.ps1's registry lock) so concurrent Stops on one project
# cannot lose each other's incidents. The mutex is global-namespaced from the
# project key; acquisition is bounded and best-effort - if it cannot be taken we
# still merge and write rather than corrupt or deadlock. An AbandonedMutexException
# means a previous holder died mid-write; we then own it, exactly like the file
# lock reclaiming an orphan.
function Save-CompletionState {
    param([string]$Deferred)
    if ($null -eq $Deferred) { $Deferred = $script:deferredFingerprint }
    $script:deferredFingerprint = $Deferred
    $mutex = $null
    $acquired = $false
    try {
        try {
            $mutex = New-Object System.Threading.Mutex($false, ('Global\HookMakerTCC-' + $script:projectKey))
            try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5)) }
            catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        }
        catch { $mutex = $null; $acquired = $false }

        Merge-DiskLedger

        try {
            $notes = New-Object System.Collections.Generic.List[object]
            foreach ($k in @($script:pendingNotes.Keys)) {
                $entry = $script:pendingNotes[$k]
                [void]$notes.Add([pscustomobject]@{ key = [string]$k; reason = [string]$entry.reason; baseline = [int64]$entry.baseline })
            }
            Write-JsonFileAtomic -Value ([pscustomobject]@{
                    resolvedIncidents   = @($script:resolvedIncidents.ToArray())
                    expiredMarkers      = @($script:expiredMarkers.ToArray())
                    pendingNotes        = @($notes.ToArray())
                    deferredFingerprint = $Deferred
                    updatedUtc          = [DateTime]::UtcNow.ToString('o')
                }) -Path $script:statePath
        }
        catch { }
    }
    finally {
        if ($null -ne $mutex) {
            if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
            try { $mutex.Dispose() } catch { }
        }
    }
}
