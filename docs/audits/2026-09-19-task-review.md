# Task continuation integration review

Read and obey the user's applicable repository, client, global and hook rules before changing or integrating this PR. Do not disable safeguards, fabricate evidence, replace a blocked verdict with success, or merge unrelated work.

## Defects and repairs

The pre-repair shared project task file let another session/client overwrite the current identity. Schema 2 scopes state to project, client and session and serializes publication with a stable lock. Identical text in a new documented Codex turn is not duplicate delivery. A pending correction carries a consumed opaque receipt, so truncated synthetic feedback can retain the original task without refilling its allowance. Prompt bodies are not persisted.

Integration testing found two further replay paths: a delayed older dispatch within the same task minted a new identity, and its delayed Stop sealed a newer dispatch. Duplicate detection now covers the task's bounded known-turn collection; only the current dispatch can seal its phase. The early Stop hint must not suppress reevaluation of known-task evidence. Actual duplicate/refusal admission remains one atomic ledger transaction, with semantic evidence fingerprints and a finite shared allowance. Unknown provenance keeps the conservative degraded path; it is not a new task inferred from transcript growth.

The ledger validates its own persisted document under its mutation lock and rejects corrupt/future state without replacement. Stop advisories use user-facing systemMessage instead of model context. Rejected writes and exhausted allowance remain explicitly unverified or unresolved, never clean. Required pre-tool and native pre-push safety checks are not disabled.

Full integration tests now distinguish unresolved state from repeated message delivery. Invalid documentation acknowledgements and bare/untagged incident notes stay invalid even when an unchanged message is deduplicated; another genuine task/session still sees the live obligation. The original incident receipt is retained when writing its valid note. Stop/SubagentStop output assertions match the actual adapter, including PowerShell 5.1 and deep-debug paths.

The graph test previously interpolated an environment variable on the left-hand side of a nested PowerShell command, logged an error, and nevertheless passed because an earlier cooldown already suppressed the hook. It now invokes the real ledger producer under a saved/restored isolated environment in a separate project with no cooldown stamp, checks successful admission and containment, and rejects stderr.

## Verification contract

The dedicated workflow exercises the production PowerShell on both Windows hosts, concurrent processes with a readiness barrier, held-lock failure, replay, missing provenance, corrupt/future ledgers, and wire output. A separately pinned historical implementation and scenario reproduce the five replay/early-hint failures; an unrelated exception is not accepted as the expected red proof. All current scenarios must pass, as must the complete ordinary CI, not only the dedicated job. Audit workspaces use the existing project-owned test helper; explicit JSON/source artifacts carry the tested revision.

## Final display boundary is not silently redefined

These fixes bound continuation and preserve task identity. They do not by themselves establish that a DONE/REMAINING summary is the final visible content of an interactive client. A post-response Stop callback, even one returning systemMessage, is not a pre-publication barrier. The full display-level requirement needs supported client integration plus a complete event trace; no live authenticated Claude/Codex frontend was exercised by these filesystem/PowerShell tests.

Known turn history is bounded, not an unlimited replay archive. A Stop-only installation with no prompt-boundary delivery has degraded identity rather than invented provenance. Review these boundaries explicitly during rollout. Do not claim exact-once UI publication, universal interleaving coverage or zero possible bugs on the strength of this PR's unit/integration results.

## Reviewer handoff

PR #2 is the task/continuation patch. Review the actual diff and exact-head CI, retaining the negative controls above. Repair any remaining failing acceptance condition before merging. PR #3 is independent storage work and must also be reviewed; PR #1 is unrelated. Only the requester or their reviewing agent is authorized to merge or close these PRs. Final integration must preserve custom registrations, local configuration and unrelated work, and verify the final pushed commit.
