# Storage integrity and native-test review

Read and obey every applicable user, global, repository, client and hook rule before editing or integrating this PR. Preserve private configuration and foreign hooks. Do not bypass a check, remove an incident, or label an unverified run successful to make the task appear complete.

## Registry recovery

The original interrupted batch recovery could promote a mixture of newly rewritten and surviving records. An empty expected filename list could also label an unfinished delete-all operation complete, and recovery could overwrite metadata written by a newer schema.

The repair journals the previous committed snapshot before mutating the live directory, with the journal outside that directory so the first-save window is covered. Snapshot readers and writers share a reentrant file lock. Readers of an incomplete batch use verified prior bytes; activation requires the entire intended filename set, record digests and metadata. Recovery restores the verified committed generation and retains the failed generation separately for inspection. Newer schema metadata is not downgraded; legacy incomplete state without a rollback snapshot is explicitly unavailable, not silently promoted.

A stable lock file is intentional. Removing its name after releasing a handle races a waiting writer. The two former lock-absence tests now acquire the same file exclusively and dispose that handle, proving it is available to the next writer without requiring its inode to disappear. Per-record updates retain their ordinary O(1) path; full snapshots belong to batch save/recovery only.

## Reviewed package integrity and publication

The old acknowledgement checked a manifest's repeated fingerprint without proving the reviewed bytes. Pending state now binds the manifest digest and exact staged-file records; acknowledgement revalidates the manifest, file set, each digest and containment. Empty and single-record arrays keep their JSON array provenance. Missing or additional files, traversal, a file masquerading as an ancestor, unreadable ancestry and reparse redirection fail verification.

Each new package gets an immutable generation directory. New pending state is committed before superseded packages are retired. A real state-file sharing violation is tested: failed publication preserves the old state pointer byte-for-byte and its reviewed package. Cleanup refusal remains a deferred outcome rather than a false acknowledgement or a false publication failure.

Further negative controls exposed the empty-root case: an empty junction must not pass simply because there are zero records to hash. Verification now rejects a redirected files root before iterating records. Retirement checks descendants before deleting; it refuses a tree containing any internal reparse point and preserves the external sentinel. These are deterministic containment/link tests, not a claim of exhaustive protection against every hostile concurrent filesystem rename interleaving.

## Native-test reliability

The graph fixture previously expanded LOCALAPPDATA into a nested shell command's assignment target, emitted a PowerShell error, and could still pass because a previous cooldown already suppressed output. The corrected test uses the production ledger producer in an independently isolated project with no cooldown stamp. It verifies admission, state containment, empty stdout and empty stderr, and restores its environment in finally.

A previous full CI run timed out in the first PowerShell 7 clean runner canary; its three assertions had no useful result document. Its root cause was not established from that empty evidence. The new harness retains process exit, elapsed time, result/capture existence and the returned document for every case, and removes the previous argv capture before starting another case. A dedicated job runs the four actual clean/failing host combinations with the original deadlines and requires all four evidence documents. It does not silently retry, increase a timeout, or classify an absent result as success. The complete ordinary CI still runs the full runner suite.

All new regression workspaces use the existing project-owned test helper. Only explicit diagnostic/source/result artifacts are exported by the read-only verification workflows. New verification actions are pinned by commit; the existing weekly github-actions Dependabot coverage remains appropriate for this pure PowerShell repository.

## Acceptance and integration

The dedicated storage job must pass every registry and package assertion on Windows PowerShell 5.1 and PowerShell 7. The dedicated runner job must pass four cases and twelve assertions with fresh evidence. The ordinary full CI must also be green on the exact proposed revision. Red, cancelled, absent and still-running jobs are not passes.

PR #3 contains this storage work. PR #2 contains the independently reviewed task/Stop work; their shared graph-fixture correction is identical. Do not merge unrelated PR #1. Only the requester or their reviewing agent may merge or close the PRs. That reviewer must inspect the complete diff, resolve any integration issue, preserve the negative controls, verify the final pushed integration commit, and then close the review with explicit evidence.
