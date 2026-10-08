# Test-hook identity and historical recovery

The canonical changes are in `hooks/Test-Completion-Check/Test-Completion-Check.ps1`,
its `_deepdebug.ps1`, `_ledger.ps1` and `_recovery.ps1` modules, and
`hooks/Test-Run-Guard/_commandanalysis.ps1` plus `Test-Run-Guard.ps1`. Regression
coverage stays in the existing `Test-TestCompletionCheck.ps1` and
`Test-TestRunGuard.ps1` harnesses with their focused scenario modules.

`Test-Completion-Check` activates its deep-debug verdict only when a parsed user
message starts with `::deep-debug` (optionally followed by the requested scope).
It supports Claude user messages and Codex `event_msg/user_message` and
`response_item/message/role=user` records. Quotes, code fences, loaded instructions,
assistant/tool records, annotations and hook context do not authorize activation.
An arbitrary `prompt` field on a Stop event is not proof of user intent.
Ordinary image attachments do not suppress an explicit user text command, and
image data never supplies command text.

Reads remain bounded to the final 64 KiB. Incomplete or malformed JSON records
cannot establish intent. A validated schema-2 marker preserves activation for
the same session. Legacy schema-1 markers remain on disk but are inactive unless
an explicit command is found; migration retains the original marker as evidence.
If an old legitimate command has already left the bounded tail, send the explicit
command again to establish validated session state.

`Test-Run-Guard` derives executable and argument identity from supported literal
PowerShell syntax without evaluating expressions. `-Arguments @('one','two')`,
literal scalar/comma lists and JSON arrays preserve argument boundaries. Nested
array elements that need PowerShell-specific string conversion are unsupported.
Nonempty `-ArgumentsJson` takes precedence, as in the real runner. Unknown or
dynamic arguments and invalid JSON cannot become a fabricated empty argument list.
Use full identity parameter names for observer correlation: PowerShell abbreviations
such as `-ArgumentsJ` remain executable by the runner but are unknown to the observer.
The observer reports the unsupported identity instead of creating an impossible
observation or borrowing another run's successful result. Existing failure,
freshness, incomplete-run and process-cleanup checks still apply.

Historical incidents normally resolve through exact newer clean evidence, and
since 2026-09-20 that covers strictly more than it used to: supersession matches on
the COMMAND and no longer requires the later clean receipt to carry the same
project fingerprint. A failure therefore clears when you fix it and re-run the same
command green, even though the fix changed the working tree, and a receipt written
without a fingerprint at all is no longer permanently unclearable. See
`docs/adr/0001-supersede-by-project-not-tree-state.md`.

Since 2026-09-29 an observation that never received its receipt - a guarded run started
without the full identity the hook printed (`-RunId`, `-ProjectFingerprint`, `-ResultPath`),
or a run killed before it could write one - no longer blocks for ever: it is superseded by a
LATER guarded run of the same command in the same project state that is paired to its own
observation, finished ok and left no process behind. A run observed at the same moment
(started together), an older run, a failed or leaking run, an unpaired run, or a run of a
different command never clears it. The practical rule: never hand-type the guarded runner
command, and never append a pipe or redirection to it; run exactly the replacement
`Test-Run-Guard` prints, because that is the one carrying the identity a later receipt can
pair with.

Since 2026-10-05 supported literal guarded calls with missing/blank/unusable/stale
`-ProjectFingerprint` refuse at PreToolUse before observation. The printed correction
changes only that binding and preserves caller options. A foreign literal working
directory requires that project's session context; dynamic syntax gets advice without
a guessed observation. Standalone callers also must supply a nonempty fingerprint,
or the runner exits3 before child/capture/evidence. This prevents NEW mismatches;
it does not fill historical fields. A fresh health command can supersede only the
same complete health command under the rules above, never a separate mutation
acceptance command. Repeating live create/delete acceptance requires fresh explicit
authorization.

## Unavailable repository state and audited legacy evidence

`projectKey` addresses a project's coordination files; it is not repository-state
proof. Git refusal/failure in a repository produces `repositoryState=unavailable`
and an empty `repositoryStateFingerprint`. Recognized PreToolUse commands are
refused before observation; no path hash, tool-input rewrite, automatic Git trust,
ownership or ACL change is used. A deliberately non-Git workspace remains
`nonrepository`, explicitly degraded, never certified CURRENT repository state.

### Explicit exact-root approval

Ownership refusal, missing Git, permission failure, missing repository, concurrent
state changes and other Git errors have distinct sanitized diagnoses. An owner
may explicitly approve one physical repository root, not a parent collection or
wildcard. General project selection is not approval. From Hook Maker's checkout:

```powershell
& './scripts/Set-RepositoryTrust.ps1' -ProjectRoot '<exact physical root>' -Approve -OwnerConfirmed
```

Use `-Status` to inspect or `-Revoke` to revoke, instead of `-Approve`. The user-local
record is bound to the current user, exact root and repository metadata identity;
replacement invalidates it. Reparse paths are refused: select the verified physical
root. No global Git config, ownership or ACL changes occur. Only approved child
Git processes receive command-scoped configuration; unrelated runtime settings
are retained, broad inherited directory trust is reset for that child, and
unsupported `GIT_CONFIG_PARAMETERS`, malformed pairs or repository-routing overrides
such as `GIT_DIR`/`GIT_WORK_TREE` fail closed. Approval and state are checked again
immediately before the actual child environment is applied.

PreToolUse, the standalone runner, Stop and incident recovery use the same bounded
HEAD plus sorted-status acquisition. A changed/mismatched state is refused before
the runner creates a child, capture or evidence. Non-Git compatibility remains
explicitly degraded. Run the unchanged approved read-only invocation only; an
approval never authorizes a deployment, account request or mutating test.

The approval CLI logs startup/action/error/final exit to UTF-8 `logs/` files named
`Set-RepositoryTrust_YYYY-MM-DD_HH-mm-ss_UTC.log`, with collision suffixes, UTC
`[timestamp] [LEVEL] [TRUST]` entries and closed handlers. No secret values are
recorded; initialization failure reports a console fallback. Logs are retained
until explicitly reviewed for local support, never uploaded automatically.

Completion retains legacy path-only/unidentified observations instead of dropping
them as old-state. Each identity block names the exact run ID, full command
fingerprint, UTC observation time, failed matching field and supported recovery.
A different command or unrelated green CI cannot repair it. Unchanged findings
are admitted once; changed evidence is reevaluated without creating a new note
obligation for an ordinary unknown outcome. Active, failed, terminated and leaking
runs remain independent obligations.

Historical receipts and observations remain byte-for-byte on disk, including
valid Git-bound records. Age, old repository state and supersession may retire an
eligible entry only from the current evaluation's in-memory view, never delete
its original file. Retention is not fresh proof, successful recovery or a gate
waiver; unresolved negative findings and durable-note obligations remain.
Previously missing files cannot be reconstructed from hashes or transcripts.
A verified surviving byte-copy is historical evidence, not a fabricated receipt.

For an explicit, read-only reconciliation report, choose a new local destination
in an existing directory:

```powershell
& '<installed runtime>\Test-Completion-Check.ps1' `
  -AuditEvidence -ProjectRoot '<affected project>' `
  -AuditPath '<new local report path>.json'
```

The report exposes `pairStatus=PAIRED|UNPAIRED`, the uniquely assigned result path/hash
and its actual outcome. An assigned pair has an empty matching `failedField`,
not a false consumed/unproven diagnostic. Pairing does not certify successful
execution or current state; paired negative/live evidence retains its obligations,
and malformed active evidence cannot certify supersession.

The report retains original SHA-256 hashes and records `UNKNOWN` or `SUPERSEDED`
under the existing later, own-paired same-complete-command rule. Historical
supersession is not CURRENT repository proof. It never records `SUCCESS`, modifies
receipts/observations, resolves an incident or waives the gate. `UNKNOWN` remains
unresolved. Concurrent evidence changes abort the export; existing destinations
are never overwritten. Keep the report local. A mutating acceptance command
requires fresh authorization before any replay; do not rerun a different suite
merely to suppress the warning.

The manual association below is now only for the case a re-run cannot reproduce:
a repaired wrapper whose COMMAND identity legitimately changed. An operator who has
independently verified equivalent test scope can use:

```powershell
& '<installed runtime>\Test-Completion-Check.ps1' `
  -ResolveIncident '<incident key>' -RecoveryRunId '<actual recovery run id>' `
  -ProjectRoot '<affected project>' `
  -Reason '<substantive explanation of equivalent scope and verified repair>'
```

An incident key can group repeated failures of the same complete command and
outcome. Explicit recovery validates every retained original in that group
(up to 50), never chooses only the first or latest receipt, and requires one
separate clean recovery that starts strictly after every original ended. Every
original needs a distinct run ID, the exact project root and an auditable receipt
hash; surviving original descendants and active runs still refuse recovery. Malformed
result/active records and unproven active ownership refuse admission, including
an identical repeated request; readable records never certify the omitted subset.
An owed durable note still requires its own substantive tagged explanation and
an already-proven origin. An unknown-origin legacy note remains unresolved;
group admission does not guess an origin or silently retire an unknown cause.
The ledger mutex serializes validation and updates; receipt producers are
independent. Membership/hashes and active markers are checked again before
publication, but this is not an atomic transaction across all producers. The association pins every
original run ID/hash and the recovery identity/hash, timestamps and reason.
Repeating the identical association is idempotent; adding, modifying or replacing
members cannot silently expand it. A later same-key failure does not inherit the
historical repair. Legacy singular associations remain readable and cannot be
silently converted into group associations. Original receipt bytes remain intact.
A note alone never certifies success. Historical recovery does not certify the
current product state, resolve another incident or promote UNKNOWN into SUCCESS.

### Expected-negative test fixtures

A child deliberately returning a nonzero exit code is still recorded as failed;
its enclosing test may pass by asserting that exact outcome. This is not a
production failure exemption. `Test-TestRunGuard.ps1` isolates nested canonical
receipts and active markers with process-local `LOCALAPPDATA` and
`HOOKMAKER_STATE_DIR`, then restores both in `finally`. The outer suite's genuine
receipt remains in the caller's store.

Old fixture receipts accidentally written into a real project are never deleted,
rewritten or automatically approved. With explicit owner approval, independently
verify the exact original hashes, complete command identity, historical fixture
assertions and enclosing run evidence. A fresh clean read-only verification can
then support the existing audited equivalent-scope association above. It pins
only those originals; their nonzero outcomes remain intact, new or different
failures remain unresolved, and no child is retrospectively called successful.

Focused checks use the existing guarded runner around
`scripts/Test-TestRunGuard.ps1` and `scripts/Test-TestCompletionCheck.ps1`.
The latter supports `-ActivationOnly`, `-RecoveryOnly`, `-GroupedRecoveryOnly`, `-OrphanOnly`, `-SurvivorsOnly` and `-EvidenceSelectionOnly` for scoped regressions; `-OrphanOnly` runs the five unpaired-observation cases alone. `-EvidenceSelectionOnly` checks historical versus fresh paired success, both input orders, historical-only STALE and unresolved unsafe evidence for Claude and Codex, plus one-to-one pairing and same-command supersession, with isolated state and artificial ages.

The activation regression reproduced 28 failing checks before repair, then passed
50 focused checks across PowerShell 7 and Windows PowerShell 5.1. The combined
completion suite passed 330 checks with no leaked processes. End-to-end argument
tests initially exercised both observer hosts against the PowerShell 7 runner.
A subsequent explicit deep-debug round reproduced and fixed the standalone 5.1
failure: .NET Framework lacks `ProcessStartInfo.ArgumentList`. The runner now uses
equivalent Win32 argument quoting through `Arguments` on that host, without a shell.
Twelve persistent checks verify both runner hosts, exact empty/quoted/backslash/
Unicode arguments, real success and failure exit codes, and process cleanup.

Argument identity reproduced 45 failing checks before repair and passed 58 focused
checks afterward. An independently found nested-array case failed twice before
the conservative rejection and passed twice afterward. The full Run-Guard suite
finished with 300 passing checks and one failing malformed-JSON fixture. Correcting
only that fixture's escaping passed all four exact-case checks on both observer
hosts; production code stayed unchanged and the full suite was not repeated.

Transcript routing follows the [Claude hook contract](https://code.claude.com/docs/en/hooks)
and the [Codex rollout structures](https://github.com/openai/codex/blob/main/codex-rs/core/src/session/rollout_reconstruction_tests.rs).
