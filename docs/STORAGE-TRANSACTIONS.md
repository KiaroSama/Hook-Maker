# Registry transactions and cross-project review state

## Registry

Batch save and snapshot reads use the same reentrant process/file lock as per-record updates. A batch first copies and verifies the previous committed snapshot, then publishes `install-registry.transaction.json` outside the live record directory. Only after the complete intended file set, digests and metadata are verified does activation remove that marker. Readers of an incomplete transaction use the verified previous snapshot, never a mixture of rewritten and surviving files.

Recovery verifies that snapshot and restores it; the failed live generation is preserved separately for inspection. An unfinished delete-all batch does not become complete merely because its expected set is empty. Future schema metadata is never downgraded. A legacy incomplete marker without a committed rollback snapshot is reported as unavailable instead of promoting arbitrary surviving records. Do not manually delete that marker to make an integrity error disappear.

The O(1) normal single-record path remains: the full backup cost belongs to batch transactions, not each install. Supported metadata and record identity validation remain prerequisites for mutation. The extra journal stores existing metadata, not prompt contents, hook inputs or credentials.

## Sync review state

The engine atomically publishes a source snapshot fingerprint and one bounded review batch in a separate `.v3.json` file. Older engines keep using the unsuffixed `.json` file. It emits paths only after that write succeeds. A failed publish leaves the old state and can be retried. The route mutex covers scans and acknowledgement.

Acknowledgement verifies that the command binds the listed batch to a fresh source snapshot. It records only that batch and previously checked files. The engine checks ancestry and the opened source file handle before hashing. The v3 writer never changes old state or inbox bytes. It can read prior acknowledged file records; it does not trust old pending reviews. Complete uninstall retires only the exact owned v3 state and its regular scan stamp, without inspecting legacy state or inboxes.

## Regression evidence

`storage-integrity-regressions.yml` runs both native Windows hosts. `Test-StorageIntegrity.ps1` covers partial-batch recovery, delete-all interruption, future-schema refusal, and path confinement. `Test-PackagePublication.ps1` holds a real file lock to check that a failed state write preserves the original bytes. The engine suite tests exact source paths, stale acknowledgement, junction refusal and untouched legacy inboxes.

The ordinary full CI is still required. A dedicated regression artifact reports its exact tested revision and actual per-case outcomes. A failure, timeout or absent required artifact is never counted as a pass. Review and merge belong to the requester; this audit does not merge or close PRs.
