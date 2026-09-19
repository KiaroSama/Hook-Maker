# Dot-sourced scenario block of Test-InstallRegistry.ps1: THE REGISTRY WRITE AS
# A TRANSACTION (L07).
#
# Every case here runs against an ISOLATED fake tool root under $Work, never the
# suite's real registry: these are half-written, future-schema and reserved-name
# states, and creating them in the shared registry would make the rest of the
# suite assert against damage this block staged.
#
# The five defects, each reproducible before the fix:
#   1. Completeness was "every expected FILE EXISTS", so a batch that rewrote
#      two existing records and died after the first read back as complete -
#      one file new, one still holding its old bytes.
#   2. The directory was created by the caller BEFORE the marker, so a crash in
#      that window left an empty unmarked directory - authoritative by
#      definition, and it published "nothing is installed".
#   3. The per-record upsert never asked whether the directory held a complete
#      generation or whether its metadata came from a NEWER build.
#   4. `_writing` was a legal record id, so a record could BE the generation
#      marker - and activation deleted it. Windows device names were legal too.
#   5. The readback proved only the id field, which an older generation of the
#      same record satisfies.
#
# NOT a standalone suite: dot-sourced into the entry suite's scope (Check,
# $script:Pass/$script:Fail, $Work).

    # =====================================================================
    Write-Host '--- the registry write is a transaction: generation, identity, verified bytes (L07) ---' -ForegroundColor Cyan

    $txRoot = Join-Path $Work 'registry-tx'
    New-Item -ItemType Directory -Path $txRoot -Force | Out-Null
    # HOOKMAKER_STATE_DIR OVERRIDES THE TOOL ROOT, which is how this block first
    # went wrong: the suite points every registry at one isolated state
    # directory, so a "fake tool root" passed as -ToolRoot resolved straight
    # back onto the SUITE'S OWN registry - and the half-written generations
    # below then broke the suites that share it. Each case therefore redirects
    # the state directory as well, and the suite's value is restored at the end.
    $txSavedStateDir = $env:HOOKMAKER_STATE_DIR
    function Use-TxToolRoot {
        param([Parameter(Mandatory = $true)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $env:HOOKMAKER_STATE_DIR = (Join-Path $Path 'state')
        return $Path
    }

    # ---- reserved ids ----------------------------------------------------
    Check 'the generation marker name is not a legal record id' (
        -not (Test-InstallRecordIdSafe -Id '_writing')) '_writing'
    Check 'the metadata name is not a legal record id' (
        -not (Test-InstallRecordIdSafe -Id '_meta')) '_meta'
    foreach ($device in @('CON', 'nul', 'Com1', 'LPT9', 'aux')) {
        Check ('a Windows device name is not a legal record id: ' + $device) (
            -not (Test-InstallRecordIdSafe -Id $device)) $device
    }
    Check 'a device name with an extension is still reserved' (
        -not (Test-InstallRecordIdSafe -Id 'con.old')) 'con.old'
    Check 'an ordinary id is still legal' (Test-InstallRecordIdSafe -Id 'hook-abc_123.v2') 'hook-abc_123.v2'
    $reservedSnapshot = Test-InstallRegistrySnapshot -Registry ([pscustomobject]@{
            version = 2
            installs = @([pscustomobject]@{ id = '_writing'; friendlyName = 'X' })
        })
    Check 'a snapshot containing a reserved id is rejected before anything is written' (
        -not $reservedSnapshot.Ok) $reservedSnapshot.Reason

    # ---- the marker creates the directory it marks -----------------------
    $txA = Use-TxToolRoot -Path (Join-Path $txRoot 'a')
    $txADir = Get-InstallRegistryDirectory -ToolRoot $txA
    Check 'the registry directory does not exist yet' (-not (Test-Path -LiteralPath $txADir)) $txADir
    [void](Start-InstallRegistryGeneration -ToolRoot $txA -ExpectedFileNames @('x.json'))
    Check 'starting a generation creates the directory AND its marker together' (
        (Test-Path -LiteralPath $txADir -PathType Container) -and
        (Test-Path -LiteralPath (Get-InstallRegistryMarkerPath -ToolRoot $txA) -PathType Leaf)) $txADir
    Check 'and that directory is NOT authoritative while the marker stands' (
        -not (Get-InstallRegistryGenerationState -ToolRoot $txA).Complete) ''

    # ---- a half-rewritten batch is INCOMPLETE, not merely present ---------
    $txB = Use-TxToolRoot -Path (Join-Path $txRoot 'b')
    $first = [pscustomobject][ordered]@{ id = 'rec-one'; friendlyName = 'One'; schema = 2 }
    $second = [pscustomobject][ordered]@{ id = 'rec-two'; friendlyName = 'Two'; schema = 2 }
    Save-InstallRegistry -ToolRoot $txB -Registry ([pscustomobject][ordered]@{ version = 2; installs = @($first, $second) })
    Check 'a completed save leaves no marker behind' (
        (Get-InstallRegistryGenerationState -ToolRoot $txB).Complete) ''

    # Now describe a batch that MEANT to rewrite both records, and write only
    # the first. Both files exist; one still holds its previous bytes.
    $newFirst = [pscustomobject][ordered]@{ id = 'rec-one'; friendlyName = 'One v2'; schema = 2 }
    $newSecond = [pscustomobject][ordered]@{ id = 'rec-two'; friendlyName = 'Two v2'; schema = 2 }
    $intended = Test-InstallRegistrySnapshot -Registry ([pscustomobject][ordered]@{ version = 2; installs = @($newFirst, $newSecond) })
    Check 'the snapshot validator carries the INTENDED bytes of each record' (
        @($intended.Expected).Count -eq 2 -and -not [string]::IsNullOrWhiteSpace([string]$intended.Expected[0].sha256)) ''
    [void](Start-InstallRegistryGeneration -ToolRoot $txB -ExpectedFileNames @($intended.FileNames) -ExpectedRecords @($intended.Expected))
    Write-JsonFileAtomic -Value $newFirst -Path (Get-InstallRecordPath -ToolRoot $txB -Id 'rec-one')
    $halfState = Get-InstallRegistryGenerationState -ToolRoot $txB
    Check 'a batch whose second record still holds its OLD bytes is INCOMPLETE, though every file exists' (
        -not $halfState.Complete) $halfState.Reason
    Check 'and the reason says the batch is half written, not that a file is missing' (
        $halfState.Reason -match 'half written') $halfState.Reason

    # ---- an upsert RECOVERS the interrupted batch, it does not wedge ------
    # Refusing for ever was half the answer and the wrong half: one interrupted
    # write would have stopped every later install until a human deleted a file.
    # The records that survived the batch are a coherent set, so they BECOME the
    # registry - nothing is deleted, and the batch's lost intent stays lost.
    $recoveringUpsert = Update-InstallRegistry -ToolRoot $txB -Record ([pscustomobject][ordered]@{
            id = 'rec-three'; friendlyName = 'Three'; schema = 2 })
    Check 'an upsert after an interrupted batch RECOVERS instead of refusing for ever' ($recoveringUpsert.Ok) $recoveringUpsert.Warning
    Check 'the generation is complete again afterwards' (
        (Get-InstallRegistryGenerationState -ToolRoot $txB).Complete) ''
    Check 'the new record was written' (
        Test-Path -LiteralPath (Join-Path (Get-InstallRegistryDirectory -ToolRoot $txB) 'rec-three.json')) ''
    Check 'and every record that survived the interrupted batch is still there' (
        (Test-Path -LiteralPath (Get-InstallRecordPath -ToolRoot $txB -Id 'rec-one')) -and
        (Test-Path -LiteralPath (Get-InstallRecordPath -ToolRoot $txB -Id 'rec-two'))) ''
    $recoveredIds = @((Read-InstallRegistry -ToolRoot $txB).installs | ForEach-Object { [string]$_.id } | Sort-Object)
    Check 'the recovered registry reads back with all three records' (
        ($recoveredIds -join ',') -eq 'rec-one,rec-three,rec-two') ($recoveredIds -join ',')

    # ---- a future schema is left untouched, never quarantined ------------
    $txC = Use-TxToolRoot -Path (Join-Path $txRoot 'c')
    Save-InstallRegistry -ToolRoot $txC -Registry ([pscustomobject][ordered]@{ version = 2; installs = @($first) })
    $futureMeta = Join-Path (Get-InstallRegistryDirectory -ToolRoot $txC) '_meta.json'
    Write-JsonFileAtomic -Value ([pscustomobject]@{ version = 99 }) -Path $futureMeta
    $futureBytes = [System.IO.File]::ReadAllText($futureMeta, [System.Text.Encoding]::UTF8)
    $futureUpsert = Update-InstallRegistry -ToolRoot $txC -Record ([pscustomobject][ordered]@{
            id = 'rec-future'; friendlyName = 'Future'; schema = 2 })
    Check 'an upsert into a FUTURE schema is refused' (-not $futureUpsert.Ok) $futureUpsert.Warning
    Check 'the refusal names the newer build rather than calling the state corrupt' (
        $futureUpsert.Warning -match 'newer Hook Maker') $futureUpsert.Warning
    Check 'the future metadata is left byte-for-byte untouched' (
        [System.IO.File]::ReadAllText($futureMeta, [System.Text.Encoding]::UTF8) -ceq $futureBytes) ''
    Check 'and no record was added beside it' (
        -not (Test-Path -LiteralPath (Join-Path (Get-InstallRegistryDirectory -ToolRoot $txC) 'rec-future.json'))) ''

    # ---- the readback proves the PAYLOAD, not just the id ----------------
    $sameIdOtherPayload = ([pscustomobject][ordered]@{ id = 'rec-one'; friendlyName = 'a different generation' } | ConvertTo-Json -Depth 50)
    $idOnly = Test-InstallRecordWriteVerified -Text $sameIdOtherPayload -ExpectedId 'rec-one'
    Check 'the id check alone still passes for a DIFFERENT payload with the same id' ($idOnly.Ok) $idOnly.Reason
    $wantedText = ($newFirst | ConvertTo-Json -Depth 50)
    $withDigest = Test-InstallRecordWriteVerified -Text $sameIdOtherPayload -ExpectedId 'rec-one' -ExpectedSha256 (Get-InstallRecordDigest -Text $wantedText)
    Check 'with the intended digest, the wrong payload is caught' (-not $withDigest.Ok) $withDigest.Reason
    $exact = Test-InstallRecordWriteVerified -Text $wantedText -ExpectedId 'rec-one' -ExpectedSha256 (Get-InstallRecordDigest -Text $wantedText)
    Check 'and the record that WAS composed verifies' ($exact.Ok) $exact.Reason

    # The suite's own registry is the one every other block asserts against.
    $env:HOOKMAKER_STATE_DIR = $txSavedStateDir
