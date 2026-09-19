# Task identity and Stop continuation contract

## Repaired failure modes

A task identity belongs to one project, client and session. Concurrent handlers for one prompt serialize their updates and publish a complete record atomically. A second session or client cannot evict it. A new Codex `turn_id` with identical human prompt text is a new task; a replay of a registered correction is not. Main-agent Stop seals the active prompt phase so a subsequent identical Claude prompt can start fresh without a timer or transcript-mtime guess.

Correction messages carry an opaque receipt header. Receipt consumption preserves the originating task across a synthetic turn, including a shortened feedback preview. A consumed receipt does not permanently swallow future human turns. Task state contains identities, timestamps and digests, not the original prompt or tool input. Missing session provenance stays unknown.

The Stop ledger checks schema, shape, size and allowance inside its write lock. Corrupt or newer state is not reset into a fresh allowance. A failed durable write cannot authorize an untracked continuation. Lock files retain a stable inode. An unidentified task has a bounded degraded chain; changing a transcript's size or timestamp does not refill it.

Detectors may pass `FindingFingerprint` to `Write-StopBlockResult`. This must identify their semantic evidence, not just their message text: new file bytes can require a new verdict even when the displayed filename and sentence are unchanged. Unchanged findings are deduplicated; genuinely changed evidence is reevaluated within the same finite allowance. Native pre-tool denials and Git pre-push protections are not disabled by exhausting a Stop correction allowance.

## Wire output and honest terminal status

For Stop/SubagentStop, advisory/context output uses a user-visible `systemMessage`, not Claude model-visible `additionalContext`. Other events retain their existing context/permission contracts. A blocked or unknown task remains explicitly blocked/unknown when persistence or the correction allowance prevents further automatic correction. It is not converted into a clean completion.

The tests use actual Windows PowerShell 5.1 and PowerShell 7. Concurrent regression workers share a deterministic readiness barrier, have bounded ownership and do not spawn grandchildren. Full hook fixtures copy the real production shared-runtime artifact plan, rather than an artificial runtime missing its required helpers.

## Exactly-once final handoff: the client boundary

Preventing a continuation loop is necessary but is not proof that DONE/REMAINING is the last displayed content. A Stop callback runs after the assistant response; a non-continuing UI notice can still appear after that response. Independent matching hooks also run concurrently. Neither sorting registrations nor increasing a cooldown establishes a pre-publication barrier.

The strict target remains: complete required work, child tasks, local verification and requested Git/CI steps first; gather all closing findings; then publish one final DONE/REMAINING handoff. Its generation must stay bound to the task, actor, effective configuration and evidence state. No unchanged managed-hook correction, tool work or duplicate handoff may follow publication. A real new user task may rearm it; corruption, missing provenance or an unresolved finding is never proof of completion.

A release claiming that full display-level guarantee must demonstrate a supported client pre-publication/coordinator path with a complete event trace. These state/wire changes alone do not claim that an interactive Claude/Codex frontend or such a final-output barrier has been exercised. Preserve this distinction during review instead of calling a textual instruction a synchronization mechanism.

## Verification

`task-finalization-regressions.yml` runs `scripts/regression/Test-TaskIdentityIsolation.ps1` and `Test-StopConcurrency.ps1` on both Windows hosts. The ordinary CI suite remains required. The dedicated artifact records the exact tested Git revision and individual outcomes; it is not a substitute for the complete CI or a live installed-client trace.

Read the source and installed manifests together before rollout. Preserve user `.env`, foreign hooks and custom bindings. Do not bypass trust/protected-branch requirements. A missing modern runtime helper is an integrity problem, not authorization to silently fall back to unbounded legacy behavior.

Primary protocol references, verified 2026-09-19:
- https://code.claude.com/docs/en/hooks (Stop context, parallel matching handlers, common output fields)
- https://developers.openai.com/codex/hooks (Stop replay as a synthetic user prompt, turn identity, stopping precedence)
