# Registry transactions and reviewed sync generations

## Registry

Batch save and snapshot reads use the same reentrant process/file lock as per-record updates. A batch first copies and verifies the previous committed snapshot, then publishes `install-registry.transaction.json` outside the live record directory. Only after the complete intended file set, digests and metadata are verified does activation remove that marker. Readers of an incomplete transaction use the verified previous snapshot, never a mixture of rewritten and surviving files.

Recovery verifies that snapshot and restores it; the failed live generation is preserved separately for inspection. An unfinished delete-all batch does not become complete merely because its expected set is empty. Future schema metadata is never downgraded. A legacy incomplete marker without a committed rollback snapshot is reported as unavailable instead of promoting arbitrary surviving records. Do not manually delete that marker to make an integrity error disappear.

The O(1) normal single-record path remains: the full backup cost belongs to batch transactions, not each install. Supported metadata and record identity validation remain prerequisites for mutation. The extra journal stores existing metadata, not prompt contents, hook inputs or credentials.

## Sync packages

A new package has a unique immutable generation directory. Source path ancestry and staged destinations must remain within their trusted configured boundaries without reparse redirection. Staged files are verified against their source snapshot before publication. The manifest hash and staged-file records travel with pending state. Acknowledgement revalidates the exact staged file set, every recorded digest, the manifest bytes and path ownership. A manifest repeating the expected fingerprint is insufficient by itself.

Publication commits the new state pointer before retiring older generations. Copy/verification/state-write failure must preserve the old pending generation. Cleanup failure is a separate deferred outcome, not evidence that publication failed or that review succeeded. Legacy pending packages without byte proof are rebuilt by the ordinary delivery path and must be reviewed again before acknowledgement; they are not silently trusted.

## Regression evidence

`storage-integrity-regressions.yml` runs both native Windows hosts. `Test-StorageIntegrity.ps1` reproduces partial-batch recovery, delete-all interruption, future-schema refusal, staged-byte tampering, missing files and path confinement. `Test-PackagePublication.ps1` uses real production package functions, positive one-file/empty-package controls, tampered and injected files, a real file-sharing failure at state publication, and an internal junction with a preserved external sentinel.

The ordinary full CI is still required. A dedicated regression artifact reports its exact tested revision and actual per-case outcomes. A failure, timeout or absent required artifact is never counted as a pass. Review and merge belong to the requester; this audit does not merge or close PRs.
