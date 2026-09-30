# Stop receipt isolation and finalization convergence — PR #32

**FIRST: fully obey every applicable owner Rules file, global/repository/client instruction, installed hook and the prescribed Spec Kit chain. Never disable a gate, erase an incident or weaken a regression to produce DONE. Every published author and committer email must be exactly `Kiaro.Sama.Dev@gmail.com`. The audit assistant may create/update PRs only; the authorized reviewing agent owns integration, rewriting pre-existing branch/tag history, merge and closure under the actual Rules.**

Code-bearing PR: https://github.com/KiaroSama/Hook-Maker/pull/32 . Baseline: `1e4102e749126639cebc8bdd168c8b6be70fb198`. Work on the existing PR branch, `fix/receipt-isolation-20260930`, unless a real protection/conflict requirement forces another. Do not apply a historical candidate ZIP over the current code.

## 1. Root causes, implementation and acceptance

### RC-01: receipt storage collided across work and actors

`hooks/_gatereceipts.ps1` formerly keyed one file by project/client/session/gate only. A child, another turn or a later task could overwrite or borrow a previous pass. Schema-2 paths bind canonical project, client, session, actor, event, durable task/native turn, continuation flag, current closing-evidence digest and discovered registration revision, framed as JSON before SHA-256. Unusable evidence or missing provenance is UNKNOWN, not a guessed identity. Raw answer text is not stored. S01–S06 cover the separate identity dimensions; P07 proves that changing configuration invalidates a pass even for identical answer text.

### RC-02: atomic replacement did not make concurrent completion safe

Independent instances replaced one verdict, so a late pass could conceal another running or blocked invocation. Each start now receives an immutable attempt token. Its start/completion validates and mutates under one stable exclusive lock, with a 500 ms acquisition bound. Only that token's running attempt may complete. Error/block/running dominates pass across participating attempts; duplicate terminal delivery is byte-idempotent. Schema, gate/scope, typed fields, timestamp bounds and prospective serialized bytes are checked before replacement. A failed write does not authorize a pass. Attempts cap at 64 without eviction. Old project receipt GC cannot erase a still-running attempt or unlink its stable lock. A01–A07, V01 and four real barrier-synchronized workers cover these invariants.

### RC-03: registration reconstruction omitted or misclassified required work

Script paths in argv were skipped; Windows/Unix commands were unioned; an observer mentioned on another event could enable collection; malformed/null configuration looked empty; child matchers were ignored; distinct registrations of one named gate collapsed into one proof.

The resolver now validates bounded typed configuration, selects the effective Windows override where supported, examines command plus argv, binds the observer to the actual event and refuses ambiguous managed registrations. It checks registration fingerprints across the wait and immediately before applying the generation snapshot. Matchers use a deliberately supported subset: Codex literal regex alternatives are unanchored; Claude simple lists are exact. Complex regex is UNKNOWN rather than assumed portable between engines. Hyphen-dependent Claude behavior without an authenticated client version is also UNKNOWN. P01–P11 include positive substring controls, exact-list negative controls, argv, override, malformed/ambiguous configuration and configuration changes.

Coverage is explicitly `discovered-managed`. Standard JSON files do not constitute an authoritative list of all plugin, skill, inline-TOML, trust-filtered or managed-policy hooks. Do not relabel an empty discovered set as proof that every possible client gate ran.

### RC-04: an unverified first observation could never settle

`Publish-GenerationSummary` returned AlreadyPublished unconditionally, even after the same live task's missing checks passed. The observation could remain permanently active/unverified. Fresh affirmative evidence may now finalize that same generation without recording another publication: `Published` stays false, `AlreadyPublished` remains true, the original observation timestamp survives, the first failure is retained and a later verification timestamp is added. A negative verdict prevents promotion. Required receipt verdicts are written in one generation snapshot instead of N separate mutations. F01–F05 cover failed evidence, eventual success, retained history, no second publication and the actual observer path.

This does not reopen terminal generations or refund correction allowance. The old lifecycle fixture previously abandoned a running attempt and fabricated another pass to overwrite it; it now completes the attempt it actually started. Its positive and negative assertions remain.

### RC-05: the shared native test launcher lost process exit codes

The first new matrix passed all 34 receipt cases on both hosts, but the existing generation suite reported two failures on Windows PowerShell 5.1 because its bounded Start-Process helper returned a null exit code for redirected/NoNewWindow children. The PowerShell upstream issue documents the handle-lifetime defect and workaround.

The repair retains `Process.Handle` before the bounded wait in the shared `Start-BoundedProcess` helper, instead of creating another special runner or removing the failing assertions. The generation fixture disposes its process object and now checks empty stderr as well as exit/stdout. H01 exercises actual success exit 0 and failure exit 7 through the subject's real shared helper on both hosts. Baseline expectations distinguish the 5.1 defect from the already-working PowerShell 7 behavior.

## 2. Verification and non-repetition contract

The read-only `receipt-isolation.yml` workflow runs the current implementation and exact historical source on Windows PowerShell 5.1 and PowerShell 7. The final suite has 41 named executions per subject/host. Historical failures are separately designated: 30 expected failures on PowerShell 7 and 32 on 5.1; current source must have none. A harness exception, absent case, timeout, cancelled job or wrong expected-failure set is not success. Each current leg also runs the existing 48-assertion generation suite. Every ordinary CI and prior regression workflow remains a prerequisite, not just this focused matrix.

The first red run remains available: https://github.com/KiaroSama/Hook-Maker/actions/runs/36712738381 . It is not called a pass and was not retried unchanged. Final exact-head URLs, counts and artifact digests are recorded in the PR conversation and downloadable handoff after observation. The expected counts above are acceptance requirements, not a predeclared execution result.

Action references are immutable commits; jobs have deadlines, explicit owned-process/workspace cleanup and retained source/result provenance. Existing GitHub Actions Dependabot coverage includes this workflow; there is no new package ecosystem or auto-merge. No temporary write-enabled patch worker belongs in the integrated tree. Do not reopen a repaired finding without a new failing acceptance reproducer, or expand this focused correction into unrelated refactors.

## 3. Research and Spec Kit routing

The exported checkout gitignores `.ai`, `.specify`, specs, AGENTS/CLAUDE and private Rules. Those private files were not available in the exported source or relevant file search. This audit does not claim to have executed unavailable private skills.

The repository's Speckit hook routes an existing-spec defect through `speckit-converge -> speckit-implement`; new requirements use specify/clarify/plan/tasks/analyze/implement. The existing receipt contract is identified in `_testgatereceipts.ps1` as spec 007. The review agent must resolve the real `.specify/feature.json`, read `global-spec-kit-rules.md` and the applicable Rules, record this request's delta, and execute the owner's actual chain. Do not guess a feature id or mark an unexecuted phase complete. Record upstream research, source date/revision, trade-offs and accepted/rejected changes in the owner's prescribed research/decision files.

Primary sources inspected 30 September 2026:
- Claude lifecycle, parallel handlers, exact/regex matcher distinction and display timing: https://code.claude.com/docs/en/hooks
- Codex turn/child input, regex matcher and Windows command override: https://developers.openai.com/codex/hooks
- PowerShell process-handle/exit-code defect: https://github.com/PowerShell/PowerShell/issues/5421
- Process exit semantics: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.exitcode
- File replacement semantics: https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace
- Upstream Spec Kit and phases: https://github.com/github/spec-kit and https://github.github.com/spec-kit/reference/agentic-sdd.html
- History rewriting and concurrency-safe publication: https://github.com/newren/git-filter-repo and https://git-scm.com/docs/git-push

Rejected alternatives: increasing cooldown, using transcript mtime as a user-task id, keeping one last-writer-wins verdict, guessing all-gates success from silence, reimplementing JavaScript/Rust regex wholesale in .NET, and adding Redis/database infrastructure for bounded local PowerShell state. Optional improvements to consider with explicit accept/reject decisions are authoritative effective-client manifests, client-issued dispatch nonces and version-aware matcher capabilities. They must not mask or defer any reproduced bug.

## 4. Strict final-output requirement and evidence boundary

A scope/evidence digest is not a native unique dispatch nonce. Repeated identical answers within the same task/turn cannot be distinguished beyond the provenance the client supplies. Configuration discovery is not complete client/plugin coverage. Unknown registrations and unproven attempts remain unverified.

The strict user requirement remains one genuinely last DONE/REMAINING summary after every required gate, child task and requested Git/CI operation, with no subsequent managed tool/correction output for unchanged finalized work. These repairs fix concrete state/receipt convergence defects, not control of an authenticated client's display transport. A supported output-owning integration, authoritative required-gate set and live event/display trace are needed before asserting that complete UI guarantee. A silent observer, textual instruction, display-only transformation or count of green tests is not an equivalent acceptance criterion. No live frontend or private global installation was exercised by the hosted tests.

For final acceptance on the owner's installed client, retain a trace binding user task, actor, actual dispatch, registration revision, every required gate start/end, children, Git/CI completion, and the single display publication. Exercise clean work, one required correction, concurrent gates, delayed child completion, a failed/unknown gate, restart and a subsequent genuine user task. Verify no second summary or post-publication managed continuation for unchanged work. Do not bypass trust or native safety checks to obtain this result, or label that unexecuted trace DONE.

## 5. Mandatory email normalization and all-PR closure

Before every commit, amendment, cherry-pick, rebase and merge, configure local `user.email`, `GIT_AUTHOR_EMAIL` and `GIT_COMMITTER_EMAIL` as exactly `Kiaro.Sama.Dev@gmail.com`. Inspect raw `%ae` and `%ce` afterward; a mailmap or account association is not proof of rewritten objects. New final PR commits must contain that identity in both fields. Temporary connector-default scaffold ancestry must not remain in the final published PR branch.

The authorized integration agent must inventory all owner-controlled published histories. If another email exists, immediately perform the requested real metadata correction during the same session: verify a private offline backup; freeze/snapshot exact remote refs; use a reviewed git-filter-repo procedure in a fresh rewrite clone; preserve names, licenses, messages, trees, meaningful topology and genuine attribution; validate old/new mappings and parent/tree equivalence; handle signatures and hardcoded historical test SHAs; publish only inventoried refs with exact per-ref force-with-lease. Reconcile concurrent writes rather than overwriting them. Do not blindly force-push or claim that ordinary branch rewriting deletes every server-owned PR/cache object. This auditor's PR-only authority does not permit rewriting main.

Inspect **all repository PRs**, classify and resolve them according to the owner's actual Rules. Do not invent an exemption for unrelated PRs. Fix any defect found during review immediately with code and regression coverage, and complete applicable work in that same review session rather than deferring it to another audit. Reuse the existing branch unless required otherwise. Preserve concurrent owner work.

After exact-head tests, identities and installed-runtime/update/uninstall behavior are verified, the authorized review agent commits/pushes and merges directly when permitted. When direct merge is impossible, implement and verify the equivalent repair, link its exact replacement, then close the superseded PR under the Rules. All PRs must end with an explicit Rules-compliant merged/closed disposition, not remain indefinitely open or be closed to conceal unfinished work. The audit assistant performs neither merge nor closure. A genuinely unavailable required external prerequisite must be reported accurately, never fabricated as DONE.
