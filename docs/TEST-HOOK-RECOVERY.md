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
The latter supports `-ActivationOnly` and `-RecoveryOnly` for scoped regressions.

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
