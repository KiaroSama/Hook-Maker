# Generation observation and retention repair

**First obey every applicable user, global, repository, client and installed-hook rule. Preserve private configuration, unrelated work and native gates. Do not weaken tests, mute checks or erase unresolved work. The audit assistant creates/updates the fix PR only; the requester or their authorized reviewing agent owns merge and closure.**

Baseline: `b6614ba1b47d82440bb62cb431077f87035b9f01`, after PRs #13, #16, #19 and #22. This is the agreed summary/finalization and terminal-retention review, not another general audit or unrelated refactor.

## Findings and implemented corrections

### G1: Stop was not proof that a summary existed

The entry point called `Publish-GenerationSummary` on every Stop/SubagentStop without reading the response. Ordinary, empty, quoted, fenced and placeholder responses consumed the publication slot, so a later actual summary appeared to be a duplicate. A child without its own response could also receive a spurious publication.

`Observe-GenerationSummary` now uses the shared current, child-aware closing-evidence reader and requires two substantive summary sections outside examples. It supports English DONE/REMAINING and Persian equivalents with RTL controls. Unknown/currently unusable evidence does not fall back to another actor. No raw response is persisted. Stop remains silent, and a duplicate observation leaves the first record unchanged. The actual installed event catalog now includes the silent Stop/SubagentStop observers; migration version 2 recognizes the exact formerly shipped pre-task-only binding. Existing custom/foreign/tampered binding protections remain.

### G2: No objection was not all-gates readiness

A working record with no objections was accepted as ready even though no required gate had affirmed it. The entry point also passed historical session blocks as if they were current objections. The helper now requires an explicit ready state with evidence, rejects recorded negative verdicts and evidence mismatch, and recomputes the decision inside the publication lock. A stale ready boolean cannot bypass a late negative verdict. The passive observer supplies no complete affirmative manifest, so its observation stays unverified rather than inventing readiness. A later notice describes that uncertainty without demanding another summary; historical blocks remain history, not current blockers.

### R1: Terminal and retired identities could reopen

The setter could change finalized/unverified back to working. The verdict-registration path could recreate a collected identity because only some callers checked tombstones. Terminal transitions are now monotonic, and every creation checks retirement. A terminal verdict mutation or a late retired event fails without replacing valid bytes. Assigning finalized to a live entry requires an actual ready publication without negative verdicts. Task-record/Stop-ledger schemas and correction counters are unchanged.

### R2: Collection removed unresolved facts and replay protection

The old collector removed every terminal-labelled record, including unresolved negative verdicts and unreported publication warnings, then evicted oldest tombstones above 64. Collection now requires a verified finalized publication and no negative verdict. Active, unverified, unresolved and unreported-warning records survive. Full tombstone capacity is a bounded refusal, not permission to evict replay protection. Limits remain 32 detailed records and 64 tombstones. This is safe capacity handling, not unlimited retention; a trustworthy replay horizon/archive authority would be needed before retiring these identities further.

### R3: A parent could consume a child's warning

The failure-notice consumer scanned every actor in the same session/client file. A parent could mark a child's warning reported and deprive that child of its own notice. Consumption now filters to the current actor. It remains atomic and once-only, without turning historical warnings into a new task's current gate.

### V1: Weak schema validation could change the verdict

Verdict booleans, publication fields, timestamps, duplicate identities and tombstones were incompletely validated; the JSON string `"false"` could be truthy. The reader now checks supported schema, typed fields, bounded collections/text, valid timestamps and unique nonoverlapping identities. Stored scope must match the requested session/client on reads too. The prospective file is validated by the same reader before replacement; corrupt/future/oversized state is not reset into a fresh identity. Identity is rechecked after lock acquisition and logical no-ops do not rewrite the store. Native JSON date decoding differences are handled explicitly.

## Verification contract

The dedicated `generation-safety.yml` matrix runs current and exact historical source on Windows PowerShell 5.1 and PowerShell 7. It exercises real hook processes, negative current/parent/example evidence, explicit-ready controls, stale-ready races, terminal/replay protection, malformed state, held locks, and six real concurrent publishers released from a readiness barrier. Expected historical failures are separately designated; an exception, missing case or timeout never passes an old-code control. The existing generation suite gains a real no-summary Stop negative control instead of assuming every Stop is publication. The existing full CI and all prior workflows remain enabled.

The new persistent workflow is read-only, commit-pinned, bounded, includes manual dispatch and retains source/result provenance for 14 days. Existing weekly GitHub Actions Dependabot coverage includes it. Final exact-head outcome/counts belong in the PR conversation only after observed execution, not predeclared here. No temporary publisher is part of the final tree.

## The user's final-display requirement is not redefined

These fixes make the passive observer truthful and bounded retention safe. They do not turn a post-response hook into a pre-publication barrier. The stricter requirement is still one genuinely last visible summary after all required work and callbacks, with no subsequent managed continuation for unchanged work. Enforcing that needs an output-owning integration, affirmative completion from the effective required gate set including children, and an end-to-end trace from the actual installed client. MessageDisplay rewriting is display-only, not completion authority or a change to the model's transcript. Do not claim universal impossibility of other architectures or pretend this observer implements one. No authenticated frontend or private global installation is exercised by these Windows fixtures.

## Reviewing-agent instructions

Inspect the actual PR diff and exact-head artifacts, not an older candidate ZIP. Use the existing PR branch unless a real conflict/protection requirement forces another. Resolve applicable integration failures with code and positive/negative tests in the same review session, not another instruction-only report. Do not add unrelated improvements to the completion scope.

After the scoped implementation, full CI, native cases and integrated runtime/update/uninstall behavior are verified, the authorized reviewer may merge and verify the final pushed remote commit. If direct integration is impossible, implement and verify the equivalent fix, link its exact replacement commit, then close the superseded PR. All PRs in the agreed repair scope must be merged with verified code or superseded by a verified linked equivalent; closing unfinished work is not completion. The audit assistant performs neither merge nor closure, and the separate live-client presentation requirement cannot be marked DONE by accepting this observer repair.

## Primary references

- Claude lifecycle, parallel matching hooks and MessageDisplay: https://code.claude.com/docs/en/hooks
- Codex Stop continuation and child evidence: https://developers.openai.com/codex/hooks
- PowerShell JSON date conversion: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json
- Atomic file replacement: https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace
- Workflow permissions and matrices: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- Actions dependency updates: https://docs.github.com/en/code-security/dependabot/working-with-dependabot/keeping-your-actions-up-to-date-with-dependabot
