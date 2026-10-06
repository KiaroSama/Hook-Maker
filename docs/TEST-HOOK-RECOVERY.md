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

The association requires the original incident, a strictly newer clean receipt
from that project, complete recovery identity, its own substantive tagged note,
and no active run or surviving original descendant. The ledger mutex serializes
validation and updates. Both receipt hashes, identities, timestamps and the reason
remain auditable. A note alone never certifies success. Historical recovery does
not certify the current product state or resolve any other incident.

Focused checks use the existing guarded runner around
`scripts/Test-TestRunGuard.ps1` and `scripts/Test-TestCompletionCheck.ps1`.
The latter supports `-ActivationOnly`, `-RecoveryOnly`, `-OrphanOnly`, `-SurvivorsOnly` and `-EvidenceSelectionOnly` for scoped regressions; `-OrphanOnly` runs the five unpaired-observation cases alone. `-EvidenceSelectionOnly` checks historical versus fresh paired success, both input orders, historical-only STALE and unresolved unsafe evidence for Claude and Codex, plus one-to-one pairing and same-command supersession, with isolated state and artificial ages.

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
