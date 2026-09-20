# PR #5: native integration repairs and review handoff

**First obey every applicable user, global, repository, client and installed-hook rule. Do not disable a check, erase a live incident, hide an unexpected failure, modify unrelated work or force a merge to finish. Only the requester or their reviewing agent may merge or close PRs. The audit assistant may update this PR but may not merge or close it.**

Actual PR: https://github.com/KiaroSama/Hook-Maker/pull/5

The existing PR contains the evidence, delivery-reservation, state-capacity and installer-outcome repairs described in `2026-09-20-review.md`. It is not a documentation-only PR. This follow-up repairs the specific native integration failures at head `aee6b31206f3c3139a04600224d0c17a44b3d4ff`, rather than opening a duplicate PR or claiming the failed head was already verified.

## Reproduced failures and implemented corrections

### A. Unset optional Skills library crashes Windows PowerShell 5.1

`hooks/Skills-Check/Skills-Check.ps1` passed an empty string to `Test-Path -LiteralPath` when neither `SKILLS_DIR` nor `AI_SKILLS_DIR` was configured. The 5.1 parameter binder raised an error before either the prompt consumer or the UNKNOWN closing-evidence path could run. Recorded native traces have exit 1, empty stdout and an empty-LiteralPath error at the original line 139. PowerShell 7 did not reproduce the same binder failure, so its green result did not cover 5.1.

The repair guards the optional directory with `IsNullOrWhiteSpace` before testing the filesystem. It does not invent a library path, import a skill or skip the remaining project/global skill checks. E17 retains the real Stop consumer assertion: UNKNOWN evidence stays unknown, exits 0 with no stderr and does not borrow an old declaration. E18 now explicitly verifies that the real prompt consumer still emits its closing requirement with an unset optional library. The old-code control expects this additional failure on 5.1 only; assertions and harness exceptions are not silently reclassified as product failures.

### B. Independent runtime verification omitted the new delivery helper

The planner now stages `_deliverylib.ps1`, but Cloudflare's independently maintained required-executable set still listed only the previous dependencies. Updating only a self-declared manifest would not prove an omitted file exists. Both client mirrors in `hooks/Cloudflare-Deploy/Cloudflare-Deploy.ps1` now include the delivery library. The positive fixture in `Test-CloudflareDeploy.ps1` stages the same complete set.

The independent equality assertion against the actual production plan remains. Two new negative controls remove `_deliverylib.ps1` from BOTH disk and metadata, separately for Claude and Codex. Both must reject the incomplete ownership proof. This cannot be replaced by a hash-mismatch-only test, because a file omitted from both places has no hash left to mismatch.

### C. Standalone installation's exact-file test had the retired expected set

The actual standalone install correctly shipped the new helper, but `_testinstallregistrysafety.ps1` treated it as an unexpected file. Its ordinal exact expected set now includes `_deliverylib.ps1`. The test still compares the complete set, and all neighboring-secret, `.env`, source-code, VCS and cache exclusion controls remain. No broad wildcard or permissive subset comparison replaces that proof.

### D. Migration tests constructed an incomplete miniature runtime

`Test-InstalledRuntimeMigration.ps1` copied only `_hooklib.ps1` into its miniature source checkout and installed fixtures. The current plan correctly refused the missing delivery dependency, aborting the suite before it could verify migration behavior. The fixture now uses `Copy-TestRuntimeLibraries`, which delegates to the actual production runtime artifact plan, for both the source and installed copies. The migration event, ownership, hash, custom-binding and foreign-handler refusal assertions are retained. This is not permission for the real planner to accept an incomplete checkout.

## Evidence and acceptance

Original red runs:
- Native review matrix: https://github.com/KiaroSama/Hook-Maker/actions/runs/35488871696
- Complete CI: https://github.com/KiaroSama/Hook-Maker/actions/runs/35488871799
- Original 5.1 wire traces and tested source: https://github.com/KiaroSama/Hook-Maker/actions/runs/35488871696/artifacts/10597829570

At that revision, the current 5.1 contracts had one unexpected failure out of 56; its 35 integration cases passed. The full registry bucket also had the stale exact-file assertion and the aborted migration suite; the hooks bucket had the independent required-executable mismatch. These observations are recorded failures, not passing verification of this correction.

Acceptance requires the new exact-head native matrix to pass on Windows PowerShell 5.1 and PowerShell 7, with current and historical subjects reported separately. Require both result documents, all case outcomes and no assertion/harness exception. Also require the entire ordinary CI plus the retained task/storage workflows. A pending, cancelled, failed or absent check is not success. The PR conversation records final run URLs and result counts after they actually complete; this document does not predeclare their outcome.

The temporary branch-scoped patch writer removes itself from the resulting tree. No write-enabled repair workflow is intended for integration into `main`. The intended persistent verification workflows remain read-only; actions are pinned by immutable commit, and the existing GitHub Actions Dependabot configuration remains active.

## Non-negotiable scope distinction

This PR's reservation and evidence corrections are not the full live-client final-display protocol. The strict user requirement remains one DONE/REMAINING handoff only after required work and callbacks finish, with no repeated managed-hook message or tool continuation for unchanged finalized work. Neither a timestamp, a cooldown nor a silent Summary Stop handler proves that condition. The two clients' display/Stop capabilities must be checked against supported versions, and a live event/display trace is required before claiming that broader feature complete. In particular, a display-only text transformation is not evidence that all pending gates have finished.

Do not mark unimplemented terminal-aware retention, missing-source preflight across every optional legacy helper, or any unresolved inherited-pipe failure as fixed solely because this PR's narrower tests pass. Reconcile the earlier F01-F03 work order against the actual code and retain precise acceptance items rather than hiding them in a blanket DONE claim.

## Reviewing agent instructions

Review PR #5 directly; do not apply an old candidate ZIP over it or recreate already-merged PRs #2/#3. Work on the existing PR branch unless a real conflict or protection rule requires another branch. Inspect code, production call paths, positive and negative tests, native artifacts and exact tested head. Repair every applicable finding uncovered by that review in the same review session; do not merely describe it and leave the corresponding fix unimplemented.

When the scoped changes and final integrated tree are verified and required checks pass, merge using the user's authorization and verify the resulting remote commit. If direct integration is impossible, implement and verify the equivalent repair manually, link the exact replacement commit and then close only the superseded PR. A conflict, timeout, missing credential or untested client must be reported accurately, never bypassed. All PRs in this review's agreed scope must end either merged with verified code or superseded by a linked verified equivalent, not closed to conceal unfinished work. The audit assistant does not perform these merge/closure actions.

## Useful primary documentation

- Microsoft Test-Path, including null/empty/whitespace behavior: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/test-path
- Claude hook reference, Stop/SubagentStop and display semantics: https://code.claude.com/docs/en/hooks
- Codex hook reference, direct fields and child transcript provenance: https://developers.openai.com/codex/hooks
- GitHub workflow execution and token-trigger behavior: https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow
- GitHub workflow syntax, matrix and permissions: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax

These are reference links, not a claim that a documented client feature was exercised by these Windows fixtures.
