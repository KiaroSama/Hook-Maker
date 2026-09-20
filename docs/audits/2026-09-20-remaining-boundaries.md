# Remaining-boundary repair: PR #13

**Read and obey all applicable user, global, repository, client and installed-hook rules before review or integration. Preserve unrelated work, private configuration and native safeguards. Do not disable a gate, erase an unresolved incident, weaken a test or substitute a cooldown for a repair. Only the requester or their reviewing agent may merge or close PRs; the audit assistant opens and updates this PR only.**

PR: https://github.com/KiaroSama/Hook-Maker/pull/13

Baseline: `2d42d10196163b538fd47fae70e15b41b2827907`.

This is a limited repair of two previously identified remaining areas, not another general audit. Already merged PRs, including #5 and #12, are not reopened. The stricter final-display requirement is not implicitly closed by these changes.

## Process identity and cleanup

The old descendant walk compared every process's creation time with the root rather than its immediate parent. A purported grandchild created after the root but before its parent could be accepted. Creation identities were then discarded before termination, allowing a PID-reuse window. A missing timestamp was not always refused. Cleanup of the caller's own PID also considered its children, and every process-query exception was classified as absence. An exact-depth leaf could incorrectly report truncation.

The new helper validates each direct edge and retains `{Id, Created}` identities. It pins the process handle before checking creation time and terminates that same OS object, not a fresh PID lookup. Invalid/self-rooted cleanup returns before enumeration. Only the specific no-such-PID outcome proves absence; denied or unavailable metadata remains unproven. Reverse breadth-first order visits descendants before parents. A real edge beyond the depth bound, unknown identity, exhausted deadline or remaining process prevents `Cleared=true`.

`Invoke-QuietCommand` records the root's creation time while its retained child handle is available and supplies it to both timeout and inherited-pipe cleanup. The optional legacy fallback accepts the argument without claiming the modern helper's guarantees. These changes do not remove bounded command waits or reinterpret exit 124 as successful work.

The tests combine deterministic graph cases with two explicitly test-owned, self-expiring native processes. A deliberately stale snapshot must preserve the replacement identity while terminating the actual owned root. Access denial is injected only in a test-local function scope. No unrelated user process is a fixture.

## Complete runtime source preflight

The previous payload producer silently omitted several missing shared sources. That allowed a damaged checkout to define a smaller plan and validate an incomplete installation against it. All seven shared sources must now be readable and nonempty before the producer contributes any artifact. Missing, unreadable or empty required files are reported together. Test-Run-Guard also requires its `scripts/Run-Tests-Guarded.ps1` companion.

Normal destination names, shared payload contents and legacy runtime compatibility remain. This preflight builds the plan in memory; it does not replace target runtime files. The outer installer may create its resource/lock directory before planning, so this is not a claim of zero filesystem activity anywhere.

## Integration test correction, not relaxed verification

Full CI at initial PR head `46a03eebfbb6b2f59a8a37d88e21a540b9d59a81` had six successful jobs and one failing job: Cloudflare's required-executable mirror assertion. The producer and independent consumer actually listed the same libraries, but the test extracted expected paths with a regex for literal source-code concatenations. The new loop-based producer did not match that source spelling.

The assertion now consumes the actual production `Get-ManagedInstallPlan` output for a standalone probe, thereby isolating the common payload from package-specific scripts/data. It verifies the generated entrypoint, a nonempty duplicate-free shared set, and exactly the supported client keys. Each client's independent literal mirror is compared separately with that plan; a union cannot hide a missing dependency in one client. Missing-from-disk-and-manifest negative cases and the complete ownership/readiness suite are preserved. No production dependency was removed merely to match the old test.

## Verification and closure

`remaining-boundaries.yml` runs the actual current and exact-baseline source on Windows PowerShell 5.1 and PowerShell 7. Each subject must produce all 32 case records and no unexpected outcome or harness exception. Current runs require zero failures; historical runs require exactly the 22 documented expected failures. Those historical failures are not included in current-product pass counts. Both owned processes and the project-owned workspace have explicit cleanup checks.

Require the final-head full CI and the independent review, task and storage workflows as well. Pending, cancelled, absent or failed checks are not successes. Exact final commit/run/artifact identities belong in the PR conversation after completion. The one-shot branch-local publishers remove themselves; only read-only verification remains in the proposed tree. Existing GitHub Actions Dependabot coverage is retained.

The reviewer must inspect the actual diff and exact-head evidence and fix any remaining in-scope regression in the same PR without weakening controls. When verified, merge only under the requester's authorization and verify the final remote/integrated revision. If direct integration is impossible, implement and verify the equivalent repair, link its commit and then close only the superseded PR. No PR should be closed just to conceal unfinished work.

## Original requirements still requiring implementation

A pre-task reminder saying that DONE/REMAINING belongs last is not a publication barrier. The current Summary handler is silent at Stop, but other handlers can still act after the response. A supported final-output owner, settled gate/configuration/evidence generation and live client event/display trace are needed to prove exactly one genuinely last handoff. Neither sorting registrations, display-only rewriting nor dropping unresolved checks proves that contract.

Terminal-aware state retention is also separate: active and unresolved state must remain protected, and only explicitly finished/eligible entries may be retired under the same transaction. This PR does not introduce that lifecycle or claim that unrelated green tests establish it. Keep these two remaining acceptance items explicit rather than restarting a broad audit or labeling them DONE.

## Primary references

- https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.handle
- https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.starttime
- https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.kill
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-process
- https://code.claude.com/docs/en/hooks
- https://developers.openai.com/codex/hooks
