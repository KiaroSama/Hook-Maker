# The coordination record Test-Temp-Cleanup hands to its consumers.
#
# A sibling, not inline: the entry point is past the file-size ceiling, so
# nothing new may be written there - and the handoff document is its own
# responsibility anyway. The install plan stages every .ps1 in a hook's package
# directory, so this travels with the runtime.
#
# The consumer is Cloudflare-Deploy's _cleanupevidence.ps1, which mirrors this
# contract rather than sharing it: an installed runtime is self-contained.
#
# WHAT CHANGED WITH GENERATION 3
#
# 1. THE TIMESTAMP WAS TAKEN AFTER THE SCAN. A candidate created after its own
#    directory had been visited, but before the record was written, was newer
#    than nothing: it carried a timestamp EARLIER than the recorded one, so the
#    consumer's freshness witness accepted evidence that had never inspected it.
#    The reference is the moment the scan STARTED now. Anything cleanup-relevant
#    touched from then on is newer than the reference, which is the conservative
#    direction and the only one that cannot bless an uninspected path.
#
# 2. THE CONFIGURED EXTRA NAMES WERE INVISIBLE to the consumer. It runs as a
#    separate installed runtime and cannot read this hook's .env, so it mirrored
#    the SHIPPED names only. That kept its observation a subset - safe against
#    false rejection, and wrong in the other direction: a configured extra
#    candidate appearing after the scan was a name the witness never looked for,
#    so a stale verdict stayed "clean". The effective configuration travels in
#    the record now, and the consumer widens its witness to match.
$script:CleanupRecordSchemaVersion = 3
$script:CleanupRecordProducerGeneration = 3

# EVERY string here allows an EMPTY value. They are mandatory because the caller
# must decide each one, not because a blank is invalid: a session id can be
# absent, and Get-RepoStateFingerprint returns '' whenever the project is not a
# usable Git repository - a real state the consumer already reads as "no usable
# hint". Rejecting it turned an ordinary non-repo project into a hook that threw
# and wrote no record at all.
function New-CleanupCoordinationRecord {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Fingerprint,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Category,
        [Parameter(Mandatory = $true)][bool]$ScanComplete,
        [AllowEmptyCollection()][string[]]$PartialCauses = @(),
        [int]$CandidateCount = 0,
        [int]$ReviewCount = 0,
        [int]$ResidueCount = 0,
        [AllowEmptyString()][string]$EvidenceFingerprint = '',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ScanStartedUtc,
        [AllowEmptyCollection()][string[]]$ExtraCandidateNames = @(),
        [AllowEmptyCollection()][string[]]$ExtraReviewNames = @()
    )
    return [ordered]@{
        # Versioned handoff identity; contract mirrored and revalidated in
        # Cloudflare-Deploy\_cleanupevidence.ps1.
        schemaVersion       = $script:CleanupRecordSchemaVersion
        producerGeneration  = $script:CleanupRecordProducerGeneration
        sessionId           = $SessionId
        # A CACHE HINT, never proof: it hashes HEAD plus porcelain STRINGS, so
        # two contents behind one ' M path' hash alike and an IGNORED path never
        # appears at all.
        fingerprint         = $Fingerprint
        category            = $Category
        scanComplete        = $ScanComplete
        partialCauses       = @($PartialCauses)
        candidateCount      = $CandidateCount
        reviewCount         = $ReviewCount
        residueCount        = $ResidueCount
        evidenceFingerprint = $EvidenceFingerprint
        # The freshness reference: when the walk BEGAN, not when it finished.
        scanStartedUtc      = $ScanStartedUtc
        # The detection configuration this verdict was actually produced under,
        # so the consumer can look for the same names this scan looked for.
        extraCandidateNames = @($ExtraCandidateNames)
        extraReviewNames    = @($ExtraReviewNames)
        timestampUtc        = [DateTime]::UtcNow.ToString('o')
    }
}
