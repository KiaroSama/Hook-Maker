# Hook Maker

Build, install, and manage Claude Code / Codex CLI hooks — including a ready-made
cross-project knowledge sync: it keeps the `.ai` knowledge directories of related projects
in sync. When a source project's knowledge changes, the hook stages the changed files inside
the destination project and asks the agent to review and import what is durable — before it
starts the user's task.

## Layout

| Path | Purpose |
| --- | --- |
| `run.ps1` | The launcher — the only script in the root. Runs the wizard in the current terminal (PowerShell 7 first). |
| `sync-hooks.example.json` | The tracked example config (what CI validates). |
| `sync-hooks.json` | Your real profiles and routes — **machine-local and git-ignored** (it holds your project paths). Auto-created from the sample on the first wizard run. |
| `hooks/<Name>/` | One folder per hook: `<Name>.ps1` + `.env.example` (tracked) + `.env` (your local copy, git-ignored). |
| `hooks/_hooklib.ps1` | Shared helpers (stdin/`.env`/path/object/hash/JSON/work-time) the shipped hooks dot-source; the `_` prefix keeps it out of the hook picker. |
| `scripts/Setup-SyncGroup.ps1` | Interactive wizard: sync groups, hook creation/installs, profile listing, validation. |
| `scripts/Install-Hook.ps1` | Writes a hook command into a project's `.claude/settings.local.json` + `.codex/hooks.json` (or, with no `-TargetProject`, the global `~/.claude` + `~/.codex`). Supports `-CustomHook <path>`. Records the install in `state/install-registry.json` on success (see "Updating previously installed hooks"). |
| `scripts/Validate-Config.ps1` | Validates `sync-hooks.json`. |
| `scripts/Test-Engine.ps1` | Self-contained engine smoke test (18 assertions, runs under pwsh and PowerShell 5.1). |
| `scripts/Test-GitHubHooks.ps1` | Offline test suite for the GitHub hooks (133 assertions; mocks git state and `gh`, no network/account). |
| `scripts/Test-RulesCheck.ps1` | Offline test suite for the Rules-Check hook and per-client install targeting (33 assertions). |
| `scripts/Test-Wizard.ps1` | Drives the interactive wizard end-to-end via stdin (menu incl. "Update previously installed hooks", hook listing, list/range multi-select, Select All = sync group + every hook, client targeting, real self-contained installs, single-hook installs defaulting to that hook's own recommended events, a valid non-empty timing tag for every shipped hook, an unwritable project `.ai` directory failing safely with no partial rollback left behind and pre-existing `.ai` directories untouched, hierarchical `<parent>-<slot>` numbering for repeated project-path prompts, installer/idempotency + source-hash verification for the menu-affected hooks) against temp projects (156 assertions). |
| `scripts/Test-SecretsCheck.ps1` | Offline test suite for the Secrets-Check hook (nested env discovery, Secret/PublicConfig/Unknown classification precedence, PUBLIC_CONFIG_KEYS-cannot-declassify-a-credential, AUTH/OAUTH token-boundary matching, critical-only-blocks Stop policy, ignore/tracked/staged/index leak, outgoing-commit + committed-then-removed `.env*`/`secrets.md` history scan, fail-closed incomplete-scan handling via real bare-remote pushes, a real secret leaked into a tracked template file, throttled unused scan; real throwaway git repos, 113 assertions). |
| `scripts/Test-AiMemoryLoad.ps1` | Offline test suite for Ai-Memory-Load and Graph-Read-Check (content fingerprinting, whole-.ai/ file listing, truncation, graph-exists gate, UserPromptSubmit codebase-structure relevance gating; 27 assertions). |
| `scripts/Test-AiMemoryCheck.ps1` | Offline test suite for the Ai-Memory-Check hook (missing/stale memory.md, real specialized-file enumeration, cooldown; real throwaway git repos, 11 assertions). |
| `scripts/Test-ContextHooks.ps1` | Offline test suite for Mcp-Usage-Check (SessionStart + prompt-relevance-gated UserPromptSubmit) and Skills-Check (SessionStart discovery, UserPromptSubmit task-relevance nudge, Stop "Skills used:" summary requirement) (32 assertions). |
| `scripts/Test-IgnoreRulesCheck.ps1` | Offline test suite for the deterministic Ignore → Secrets → previous-hook pre-push chain, relative/absolute custom hooks paths, and template-env-file (`.env.example`/`.env.sample`/`.env.template`/`.env.dist`) allow-listing (32 assertions; real pushes, PowerShell 5.1). |
| `scripts/Test-GitSyncCheck.ps1` | Offline test suite for the Git-Sync-Check hook (mandatory Stop instruction wording, fingerprint+session repeat gating, ahead/behind/dirty/no-upstream detection, non-destructive SessionStart context, the hook never writing to git itself; real throwaway git repos + bare remotes, 25 assertions). |
| `scripts/Test-DependencyVersionCheck.ps1` | Offline test suite for the Dependency-Version-Check hook (npm/pip outdated classification via PATH-shimmed mocks — no live registry calls, GitHub Actions/runtime-pin/Docker static checks, content-fingerprint cache invalidation, new-dependency prompt guidance, advisory-only/no-file-modification guarantees; 36 assertions, PowerShell 5.1). |
| `scripts/Test-CloudflareDeploy.ps1` | Offline test suite for the Cloudflare-Deploy hook (deployment-worthiness criteria, explicit environment selection, conditional pre-deploy review, required post-deployment verification wording, failure handling, cooldown/`stop_hook_active`, the release-readiness gate — clean/pushed/CI-green-if-applicable/Test-Temp-Cleanup coordination — via real bare-remote pushes and a PATH-shimmed `gh`; 30 assertions, PowerShell 5.1). |
| `scripts/Test-GraphUpdateCheck.ps1` | Offline test suite for the Graph-Update-Check hook (structural-impact criteria replacing file-count wording, staleness/freshness detection, cooldown/`stop_hook_active`; 14 assertions, PowerShell 5.1). |
| `scripts/Test-TestTempCleanup.ps1` | Offline test suite for the Test-Temp-Cleanup hook (SessionStart baseline, safe-candidate deletion + rescan verification, tracked/staged/reparse-point/hard-protected-root preservation, review-only-by-default, missing-baseline conservative fallback, path/byte limits, locked-candidate failure fingerprint with no-loop guarantee, Claude/Codex output shapes; 31 assertions, PowerShell 5.1). |
| `scripts/Test-DocsFreshnessCheck.ps1` | Offline test suite for the Docs-Freshness-Check hook (SessionStart baseline, task-delta detection across committed/staged/working-tree changes, comment/blank-only-change silence, hard exclusions, ranked tracked-doc candidates, content-hashed impact fingerprint immune to unrelated doc edits, the Updated/NoUpdate acknowledgement flow with rejection of generic reasons and out-of-root/private/untracked paths, acknowledgement invalidation on a further non-doc change, `stop_hook_active`, self-contained installer copies; real throwaway git repos, 40 assertions, PowerShell 5.1). |
| `scripts/Test-InstallRegistry.ps1` | Offline test suite for the install registry and "Update previously installed hooks" (single/multi/config-based/generated/sync-engine installs tracked without duplication, Claude/Codex/Both + project/global scope, byte-for-byte refresh preserving events/client/target/scope/profile, never installing a never-installed hook, missing-source/target reported and skipped, second-run idempotency, no secret/`.env`/prompt content ever stored, unrelated JSON preserved; **installed-state drift** — deleted/modified runtime script, stale or missing shared `_hooklib.ps1`, removed Claude/Codex registration, moved event, changed matcher, duplicate registration, one wiped client runtime — detected and repaired with no source change at all; **managed manifest** covering `.env`/copied helpers/added/removed files while ignoring runtime-generated files; **per-client semantics** (Claude `SessionStart` + Codex `Stop` preserved independently across an update, repairing one client leaving the other byte-for-byte untouched); **v1→v2 migration** deriving events from live registrations and flagging unprovable records for manual repair; **native pre-push** with a deliberately corrupted companion repaired, chain order/single-wrapper/stdin-replay/fail-closed preserved and the user's previous hook byte-for-byte intact; **corrupt-registry quarantine** (malformed JSON, wrong field types, unsupported version, stale `.tmp`, unique collision names, quarantine failure leaving the original untouched, concurrent lock-guarded writers losing no records); real throwaway projects/git repos + disposable custom-hook fixtures, 153 assertions). |
| `scripts/_testlib.ps1` | Shared assertion helper used by the offline PowerShell test suites. |
| `logs/` | Wizard execution logs (created on demand, not committed). |
| `scripts/_installlib.ps1` | Install-time-only library: the install registry (schema, validation, atomic+locked writes, corruption quarantine, v1→v2 migration), the managed-file manifest builders, and the installed-state integrity evaluation behind "Update previously installed hooks". Deliberately separate from `hooks/_hooklib.ps1`, which is copied into every installed runtime. |
| `state/` | **Machine-local and git-ignored.** `install-registry.json` — what Hook Maker has installed and where (see "Updating previously installed hooks"); never holds secret/`.env`/prompt content or file contents. A damaged registry is preserved beside it as `install-registry.corrupt-<UTC timestamp>-<short hash>.json` instead of being overwritten. |

## Shipped hooks

| Hook | Runs | What it does |
| --- | --- | --- |
| `Cross-Project-.ai-Knowledge-Sync` | pre-task (SessionStart, UserPromptSubmit) | The sync engine: stages changed `.ai` knowledge from related projects for review. |
| `Git-Sync-Check` | pre-task + post-task (Stop) | Reports uncommitted/unpushed/unpulled work at SessionStart/UserPromptSubmit as non-blocking context (never modifies the repository). On Stop it is a detection-and-instruction boundary, not an executor — the hook itself never runs `git add`/`commit`/`pull`/`push`; instead it gives the agent a **mandatory** operational instruction to reconcile the repository now (stage this task's verified changes, commit with a neutral message, push) instead of waiting for a separate user request, unless doing so is unsafe (failing tests, incomplete work, unrelated pre-existing changes, secrets/protected files, a merge/rebase/conflict state, or an authorization/permission block) — in which case the agent preserves the work and reports why. A real git inspection runs on every Stop (never a blind time-only skip); repeat blocking is gated by a fingerprint of the actionable state (branch/HEAD/upstream/ahead-behind/status) combined with the session id, so a given state is instructed once per session, while a changed state or a new session is evaluated and instructed again immediately. |
| `Ai-Memory-Load` (menu: `Ai-Context-Load`) | pre-task (SessionStart, UserPromptSubmit) | Loads `.ai/memory.md` (the startup router) directly into context and lists every other top-level `.ai/*.md` file by name, so the agent can route to the relevant project context without loading unrelated files. Fingerprinted on the router content plus the file set; capped with a truncation note; silent when no `.ai/memory.md` exists. |
| `Ai-Memory-Check` (menu: `Ai-Context-Check`) | post-task (Stop) | If the project's `.ai` context is stale, asks the AI to update whichever existing `.ai/*.md` files are relevant — or finish if nothing durable was learned. |
| `Graph-Read-Check` | pre-task (SessionStart, UserPromptSubmit) | If `graphify-out/graph.json` exists, the SessionStart note gives the compact graph-availability policy once; `UserPromptSubmit` reminds again **only when the prompt itself suggests codebase structure/dependency/call-path/architecture/broad-impact understanding is needed** (fingerprinted per session so an unchanged reminder isn't repeated) — silent when no graph exists, so non-codebase-projects pay zero tokens. |
| `Graph-Update-Check` | post-task (Stop) | If `graphify-out/graph.json` is stale, asks the AI to decide whether `graphify update .` is warranted based on **structural impact** (added/removed/renamed symbols, changed exports/imports/call/inheritance relationships, new entry points, changed cross-file dependencies) — never on how many files changed: a one-file change can still be graph-relevant while a multi-file change (docs/comments/formatting-only, literal/config values, generated output) can be graph-irrelevant. |
| `Cloudflare-Deploy` | post-task (Stop) | In Workers projects (wrangler config present), first checks **release readiness** — a deterministic gate, never based on hook registration/menu order, since matching-event hooks may run concurrently: stays completely silent (no reminder shown at all this Stop) unless the working tree is clean, the exact commit is known to be pushed (any configured upstream, not only GitHub), CI (if this repo has `.github/workflows`) is verified green for that exact SHA, and — when `Test-Temp-Cleanup` is installed for this project — it has reported a fresh `clean`/`safe-cleaned`/`review-only-preserved` result for the *current* repo state (a stale, missing, `failed`, or `incomplete-limit` cleanup result also keeps it silent; a race on the same Stop just means it re-evaluates on the next one, never a loop). Once ready, it walks the AI through a **deployment-worthiness decision** (deploy only when the task is complete, tests/typecheck/lint/build pass, the exact release commit is known, CI is green if the repo uses CI, no secrets/local-only files, unrelated changes, or disposable test cache/temp residue are included, the environment/bindings/migrations are understood, and project rules permit it — otherwise finish without deploying), **explicit environment selection** (never silently defaults to production), a **conditional Cloudflare-specific pre-deploy review** (Worker name, env vars, bindings, D1/KV/R2/Queues/Durable Objects + migrations, service bindings, routes, cron, compat flags, CLI version, build output — only what's relevant to the diff), and **required post-deployment verification** (record environment/Worker/exact commit SHA/deploy command (no secrets)/version or URL, then smoke-test or otherwise confirm it — a zero exit code alone is never treated as proof, and a failure is never hidden or blindly redeployed). |
| `Skills-Check` | pre-task (SessionStart, UserPromptSubmit) + post-task (Stop) | SessionStart discovers/lists available project skills + the policy, once per session. `UserPromptSubmit` reminds to pick only what's relevant to the current task (fingerprinted so it doesn't repeat noisily within a session). `Stop` requires the final task summary to include a `Skills used: <name1>, <name2>` line for skills **actually invoked** — never merely installed, available, discovered, copied, considered, or read but unused; omitted entirely when none were used; never forces a skill for a trivial task. |
| `Mcp-Usage-Check` | pre-task (SessionStart, UserPromptSubmit) | SessionStart loads the compact MCP policy once. `UserPromptSubmit` reminds again **only when the prompt itself suggests docs/browser/database/GitHub/other MCP use would materially help** (fingerprinted per session so an unchanged reminder isn't repeated) — silent for prompts with no such signal. |
| `Large-File-Check` | pre-task + post-task (Stop) | Pre-task: reminds to prefer small, multi-part files (split by responsibility, ~500-800 lines = split signal). Post-task: scans for oversized source files and asks the AI whether a split is safe and worthwhile. |
| `Dependabot-Check` | pre-task (SessionStart) | In a GitHub repo, reports pending pull requests from the verified `app/dependabot` author (with exact head SHA, classification, merge/check state) so they are reviewed before unrelated work. Detection only — never merges. |
| `Ci-Status-Check` | post-task (Stop) | After a push, blocks "done" until checks for the **exact** pushed commit reach an acceptable terminal state. Pending/failed authorization remains blocking even while repeated detail is cooled down; GitHub queries are throttled, exact-SHA, and bound to the SAME resolved remote used for both repository selection and pushed-state verification (never a mismatched `@{upstream}`). Missing access is never reported as verified. When CI is blocked only by a confirmed **external** condition (GitHub outage, no hosted runner, an org/repo permission failure, an externally-controlled secret being unavailable, a manual approval/environment gate, ...), the agent can record an explicit, evidenced, local-only exception bound to the exact repository + pushed SHA: `-ReportExternalBlocker -Classification <category> -Reason "<evidence>"`. **Eligibility is conservative:** an exception may only be recorded when the observed GitHub run state is non-code-failure identifiable without reading logs — still pending / a manual gate, or a completed run whose conclusion is `cancelled`/`timed_out`/`stale`/`action_required`. A completed `failure`/`startup_failure` is **never** eligible (the hook cannot tell a real code/test/build/lint failure from an external one without trusted evidence), regardless of classification (including `other-external`); the classifications describe *why*, but cannot excuse a generic `failure`. Recording **always queries the exact-SHA CI state first** — refused if already green, refused on a genuine completed failure, refused if CI can't be queried — and captures a non-secret CI fingerprint (`databaseId`/`attempt`/`workflowName`/`status`/`conclusion`/`updatedAt`, so a rerun is distinguishable). It never marks the commit verified/green; **while active, Stop emits a non-blocking "CI NOT VERIFIED GREEN" notice** so the final task context cannot misrepresent CI as successful. The notice shape is client-aware: **Claude Code** receives `hookSpecificOutput.additionalContext` (the officially documented model-visible field for Stop), while **Codex** receives `systemMessage` (its only documented common Stop output field — surfaced to the user/event stream; Codex does not document model-visible Stop context, so this is the strongest verified non-blocking option there). Neither shape ever uses `decision: "block"`. The client is detected the same way as the rest of this project (`CLAUDE_PROJECT_DIR` present → Claude, absent → Codex). Every later Stop re-verifies on a throttle (`EXTERNAL_BLOCKER_RECHECK_MINUTES`, default 15): the same fingerprint keeps completion allowed, CI turning green retires the exception and verifies normally (no external wording), and CI changing to a different state invalidates it and blocks again. Expires after `EXTERNAL_BLOCKER_TTL_MINUTES` (default 1440); a new commit or different repository invalidates it immediately. This is not a log-analysis subsystem. |
| `Github-Baseline-Check` | pre-task (SessionStart) | Checks that workflows contain blocking project validation (not empty/deploy-only YAML) — recognizing block-style, flow-style (`on: [push, pull_request]`), bare-value, and block-sequence triggers scoped to the **direct children** of the top-level `on:` block (an unrelated nested `push:` step input, e.g. `docker/build-push-action`, or a trigger word nested deeper as an option such as a `push` key under `workflow_dispatch: inputs:`, is never mistaken for a trigger), and multiline `run: \|` validation blocks (skipping full-line shell comments, so a keyword appearing only in a comment like `# TODO: run npm test` is not counted). A `workflow_call` reusable workflow counts as CI only when a directly-triggered local workflow actually `uses:` it (an uncalled reusable workflow is reported as a gap, not assumed complete). Flags broad `continue-on-error` and unsafe PR-target execution, detects common ecosystems in pruned deep monorepos (a bare `pyproject.toml` defaults to the `pip` Dependabot ecosystem, which also covers Poetry; reclassified as `uv` only when `uv.lock` is present), and validates `dependabot.yml` directory/directories coverage. Deliberately does not evaluate `if:` step conditions, check least-privilege `permissions:`, or confirm a reusable workflow called only from another repository — a lightweight, deterministic heuristic, not a full YAML/static analyzer. |
| `Rules-Check` | pre-task (SessionStart, UserPromptSubmit) | Verifies the configured rules were read before the task starts: the **global** rules directory (`~\.claude\rules` / `~\.codex\rules`) plus the current project's **local** rules directory (`<project>\.claude\rules` / `<project>\.codex\rules`). First check lists all rules files; afterwards it stays silent until a rules file is added/changed/removed, then reports exactly what moved. Detects the running client automatically (Claude Code exports `CLAUDE_PROJECT_DIR` on hook processes; Codex does not). |
| `Secrets-Check` | pre-task + post-task (Stop) | Safely scans real `.env*` files throughout active project subtrees (templates, dependencies, builds, caches, assistant runtimes, and reparse points are pruned). Lifecycle events retain registry/placeholder/unused advisories. The leak scan merges and deduplicates git **working-tree and index** matches (`git grep` + `git grep --cached`), so a value staged then cleaned from the working copy only — or committed and later edited away locally without staging that edit — is still caught. During native pre-push it **additionally scans the exact commits about to be pushed**, resolved from git's real pre-push ref-update stdin (`<local ref> <local sha> <remote ref> <remote sha>`): a secret sitting in an outgoing commit is caught even when the working tree and index are already clean. The outgoing-history scan does **not** exclude `.env*`/`secrets.md` — a committed real `.env` or registry file in outgoing history is itself a leak, even if it was later deleted/untracked before the push. New branches (all-zero remote sha), deletions (all-zero local sha), force-pushes/non-fast-forwards, and multiple refs in one push are all handled. It **fails closed**: the whole range is scanned in bounded batches (no commit cap), and if any ref range cannot be resolved (unresolvable remote sha, `rev-list`/`git grep` error) the push is **blocked** with a safe incomplete-scan message rather than treated as clean. Native pre-push blocks only confirmed indexing/leak/outgoing/incomplete-scan risks; advisory-only findings exit successfully. Secret values are never printed. **Limitation:** `Secrets-Check` is a registry/value-based leak guard, not a full entropy/pattern/history secret scanner — it can only match values it currently knows (from active `.env*` files or the local `secrets.md`). A secret introduced and later removed from outgoing history **and** every current source is no longer known to it and cannot be matched; use an established dedicated historical-secret scanner in CI for unknown credentials. |
| `Ignore-Rules-Check` | pre-task (SessionStart) + post-task (Stop) + native Git pre-push | Auto-adds required local/private patterns to `.gitignore`, extracts additional paths from explicit local-only/never-commit project rules, and blocks completion while required fixes remain. Default public template files (`.env.example`/`.env.sample`/`.env.template`/`.env.dist`) are intentionally allowed to stay tracked via `!`-negation exceptions — they are never reported as a protected path that must be untracked, while real env files (`.env`, `.env.local`, `.env.production`, ...) remain protected. Patterns are written and compared in **insertion order**, never alphabetically sorted (an alphabetical sort would silently break every negation exception, since `!` sorts before `/`), and a path whose effective `git check-ignore` match is a negation is always treated as explicitly allowed. Project installs create a deterministic pre-push chain: Ignore → Secrets → preserved previous hook. Large-File-Check remains advisory and never decides whether a push may proceed. Optional extra patterns can be set in `.env`. |
| `Dependency-Version-Check` | pre-task (SessionStart, UserPromptSubmit) | **Advisory only** — never modifies manifests/lockfiles/workflows/Dockerfiles, never runs an upgrade, never auto-merges Dependabot PRs, never blocks completion. SessionStart reports version-freshness findings for ecosystems actually detected in the project: real `npm outdated --json` (exits 1 when outdated packages exist — treated as success, not a failure) and `pip list --outdated --format=json` classify each update as patch/minor/major/prerelease; GitHub Actions get a static known-minimum-major check on `uses:` refs; runtime pins (`.nvmrc`/`.node-version`/`.python-version`/`engines.node`) and Docker base images (`FROM` tags) are checked against a small known-EOL list, and a floating/untagged image is flagged as non-reproducible. Ecosystems without a verified, reliable JSON command here (pnpm, Yarn, Bun, Poetry, uv, .NET, Java/Gradle/Maven, Rust/Cargo, PHP Composer, Ruby Bundler) are detected and reported as an **incomplete** check with the exact command to run manually, rather than guessing at an unconfirmed schema or a fragile text-table parse — it never claims a dependency is current when a check could not run. `UserPromptSubmit` reuses the cached findings and additionally injects "prefer the latest stable compatible version, not a prerelease" guidance when the prompt looks like it's adding a dependency/framework/runtime/build tool/action/Docker image or starting a project from scratch. Cached per-project by a fingerprint of detected ecosystems + manifest/lockfile/workflow/Dockerfile/runtime-pin **content** hashes (not just presence), so an unrelated task stays fast while any real change triggers a fresh scan; default cooldown is 7 days. Complements `Dependabot-Check` (existing PRs) and `Github-Baseline-Check` (CI/Dependabot baseline structure) without duplicating either. |
| `Test-Temp-Cleanup` | pre-task (SessionStart) + post-task (Stop) | Removes safe, project-local, disposable test cache/temp residue (`.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.hypothesis`, task-created `__pycache__`/`*.pyc`/`*.pyo`, `.nyc_output`, `.test-tmp`/`.test-temp`, ...) that is contained inside the project root, not a symlink/junction/reparse point, and confirmed **untracked/ignored** in git (never tracked or staged). SessionStart records a metadata-only baseline (relative paths, category, size, mtime, git state — never file contents or secret values); Stop rescans, deletes only what's eligible, and **verifies every deletion with a rescan** before reporting success. Diagnostic/review artifacts (`coverage/`, `test-results/`, screenshots, ...) are **preserved by default** — deletable only via the explicit `DELETE_REVIEW_ARTIFACTS=true` opt-in. Never runs `git clean`/`git reset`, never touches the git index, never deletes `.git`/`.ai`/`.claude`/`.codex` or dependency/build roots (`node_modules`, venvs, `target`, `dist`, `build`, `out`, ...) by name, and never descends into them looking for nested candidates. Conservative limits (`MAX_DELETE_PATHS`, `MAX_DELETE_BYTES`, `MAX_FINDINGS`) stop and report "incomplete" rather than over-deleting. A locked/permission-denied candidate blocks once per session (never loops on the same unchanged failure). Writes a small coordination state that `Cloudflare-Deploy` reads before offering to deploy (see above). |
| `Docs-Freshness-Check` | pre-task (SessionStart) + post-task (Stop) | A mandatory review boundary for whether this task's changes made tracked, published documentation stale — never a prose rewriter: it detects and gates, the agent edits. SessionStart silently records a metadata-only baseline (starting HEAD, repo-state fingerprint, tracked public `.md`/`.txt` paths + content hashes). Stop computes the task delta from that baseline (commits + staged + working-tree changes, so it still works even if the agent already committed), classifies each changed non-doc file as a real content change or comment/blank-only noise (so pure internal refactors and formatting-only edits stay silent), and — only when real, non-excluded impact exists — blocks **once** per distinct impact fingerprint with a bounded, ranked list of candidate tracked `.md`/`.txt` files to review (conventionally-named files and files sharing a directory with the changed code rank first). Hard exclusions (never requested for review regardless of config): `.ai`/`.claude`/`.codex`/`.agents`/`.cross-project-sync`, `secrets.md`, generated/vendor/build/cache directories, fixture/snapshot/golden files, and `LICENSE*`/`NOTICE*`/`COPYING*`. The impact fingerprint is content-hashed from only the non-doc changed files, so an unrelated documentation edit never shifts it. The only way to clear a block is a fingerprint-bound acknowledgement command (`-Acknowledge -ProjectRoot <path> -ImpactFingerprint <fp> -Result Updated|NoUpdate -Files <relative,doc,paths> -Reason "<concrete reason>"`): `Updated` requires at least one real, tracked/staged, in-project, non-excluded `.md`/`.txt` file; `NoUpdate` requires a concrete, non-generic reason (`none`/`n/a`/`done`/... are rejected). Acknowledgement is local-only state, never committed, and a later non-doc change invalidates it, requiring a fresh review. |

All advisory hooks are token-efficient by design: they stay **silent** unless a deterministic
signal fires (staleness, wrangler config, out-of-sync git, pending Dependabot PR, unverified
push), they respect a per-project **cooldown/fingerprint**, they never loop (`stop_hook_active`
guard), and the decision always stays with the AI — every reminder explicitly allows finishing
without action. The GitHub hooks degrade safely (silent, never a false "all clear") when git,
a remote, `gh`, authentication, or network access is missing.

Matching lifecycle hooks for the same event run concurrently and are intentionally independent;
their registration order (and menu position) is display-only and never guarantees execution order.
`Cloudflare-Deploy` and `Test-Temp-Cleanup` hand off state through a small fingerprinted file
instead of assuming one runs "after" the other on the same Stop. The native pre-push chain is the
only ordered sequence.
It honors Git's resolved `core.hooksPath` (default, relative, nested, absolute, and paths with spaces), preserves an existing pre-push hook once, and is idempotent.

## Hook configs (.env)

Each hook folder ships a tracked `.env.example`. Copy it to `.env` (git-ignored) and fill in
your local values — most importantly `TARGET_PROJECTS` (semicolon-separated project roots),
`EVENTS`, and `CLIENTS` (`Both`, `Claude`, or `Codex`). Then use menu `1 -> 3` (*Install from
config*) and the wizard installs the hook into all listed projects **without asking any
questions**. The sync engine's `.env` supports `SYNC_PROJECTS`, which the sync-group flow offers
to use instead of asking for paths.

## Claude / Codex / both

Every hook can be installed for either client or both. The interactive flows (the sync group and
**Install an existing hook**) ask **Client: 1 Both, 2 Claude only, 3 Codex only** before the
target projects; config-based installs read the same choice from the hook's `CLIENTS` key. Claude
entries land in `.claude/settings.local.json`, Codex entries in `.codex/hooks.json` — a
Claude-only install never touches the Codex file and vice versa.

## Quick start

```powershell
.\run.ps1
```

Double-clicking `run.ps1` opens the wizard in a Windows Terminal window when `wt.exe` is
available; otherwise it runs in the current console with the best available PowerShell.

Main menu: `1` **Create or install a hook** (opens a sub-menu: install an existing hook, create a
new hook, install from config, or update previously installed hooks — see "Updating previously
installed hooks" below), `2` show configured profiles, `3` validate. `0` goes back, `exit` quits.

Under **Install an existing hook**, list item `1` is **Select all hooks** — an aggregate action
(not a hook itself) that runs the **complete former full-list flow**: the sync-group wizard AND
every individual hook below, in one pass, using each hook's recommended events with a shared
client/projects answer. You do **not** need to also type `2` — `1` alone always includes the sync
group. The individual-hook set is derived dynamically from the hooks actually shipped (never a
hard-coded count), so adding or removing a hook folder changes it automatically, and the sync
group always runs exactly once even if `2` is also listed explicitly (e.g. `1,2`). List item `2` is
the **sync group** on its own. Individual hooks start at `3`, each showing a colored
`[pre-task]`/`[post-task]` tag and a one-line description, with `Cloudflare-Deploy` fixed as the
**last** individual entry. You can also **install a subset** with lists and ranges (e.g. `3-8,20`)
— use each hook's recommended events with shared client/projects or configure each separately,
then a summary lists exactly what will be installed. Combining `1` with an explicit pick (e.g.
`1,5`) never installs anything twice. If the sync-group stage is canceled, the individual hooks are
not installed and nothing is falsely reported as completed. Picking a **single** hook shows that
hook's own recommended events as the first, clearly-labeled event choice (e.g. "This hook's
recommended events (Stop)") — a bare Enter installs on the events that hook actually needs, not a
generic default; the other fixed choices and a fully custom event list remain available too.

The **sync group** also lives inside `1` → **Install an existing hook** as list item `2`
("Create or update a sync group") for when you want it on its own. Including `2` in a selection
(e.g. `2,4-6`) runs the sync-group wizard first, then installs the rest of the selection right
after — one pass, no need to re-enter this menu. The sync engine itself is **not** listed as its
own numbered hook — installing it as a plain custom hook would skip its `-Profile`/routing config,
so it only works through this flow.
Choose item 2 (alone or in a list), enter each project root path (finish with `done`), pick the
client, review the summary and confirm (Enter = yes). Repeated child prompts inside one question —
like each project-path entry — use **hierarchical numbering** (`12-1.`, `12-2.`, `12-3.`, ...)
instead of each one stealing a fresh top-level question number; an invalid/duplicate/overlapping
path or `undo` keeps or steps back the same child slot instead of advancing it. The wizard:

1. Creates missing `.ai` directories.
2. Writes a full-mesh profile — every project becomes a sync destination of every other.
3. Validates the configuration.
4. Installs the hook **inside each project** as a self-contained runtime copy
   (`.claude/hooks/Hook-Maker/` + `settings.local.json` for Claude, `.codex/hooks/Hook-Maker/` +
   `hooks.json` for Codex) — not in your global settings, so only these projects carry it, and
   nothing depends on where the Hook Maker folder lives.

Re-running the wizard with the same paths updates the same profile (its id is a hash of the
sorted project roots), so existing sync state is preserved.

## Where the hook lives — installs are self-contained

Every install **copies the hook runtime into the target itself** (Kiro-style): the script, the
shared `_hooklib.ps1`, its `.env` (if present) and — for the sync engine — a copy of the routing
config plus `SYNC-PROJECTS.txt` (the readable project names and paths in that sync group) land in

- `<project>/.claude/hooks/Hook-Maker/<Friendly-Name>/` for Claude (registered in
  `<project>/.claude/settings.local.json`, auto-gitignored — the command holds a machine-specific
  absolute path), and
- `<project>/.codex/hooks/Hook-Maker/<Friendly-Name>/` for Codex (registered in
  `<project>/.codex/hooks.json`; loads only after you trust it via `/hooks`),

where `<Friendly-Name>` is the hook's readable, hyphenated name (e.g. the sync engine lands in
`Hook-Maker/Cross-Project-.ai-Knowledge-Sync/`, `Mcp-Usage-Check` in `Hook-Maker/Mcp-Usage-Check/`),

and the registered command points at that copy. **Moving, renaming, or deleting the Hook Maker
folder never breaks an installed hook.** The flip side: copies do not auto-update — after
changing a hook, its `.env`, or a sync group, re-run the install (or the sync-group flow) and
the copies are refreshed; a re-install *replaces* the hook's old registration (even one that
pointed into the tool folder) instead of duplicating it. Other content in the settings files is
preserved, and a timestamped backup is written first.

Global install works the same way: `scripts/Install-Hook.ps1` with no `-TargetProject` copies to
`~/.claude/hooks/Hook-Maker/` + `~/.codex/hooks/Hook-Maker/` and registers in
`~/.claude/settings.json` and `~/.codex/hooks.json`.

## Updating previously installed hooks

Because installs are self-contained copies, editing a hook's source under `hooks/` (or updating
Hook Maker itself) does **not** change any copy you already installed — the copies are frozen at
install time. Rather than re-selecting and reconfiguring every hook you've installed one by one,
use the final item in **`1` → Install an existing hook / Create or install a hook**:

`4` **Update previously installed hooks**

This reads a local install registry, shows a plan, asks **one** confirmation, then repairs
everything that needs it — reusing each installation's original events, client selection,
target/global scope, and (for the sync engine) profile/config, so you never re-answer the same
questions. It never installs a hook that was never installed, never touches unrelated
settings-file content, and a second run with nothing changed reports everything as already current
(no-op).

### What "up to date" actually means

An installation is reported as **up to date** only when *all* of the following hold — it is never
inferred from the registry's own last-known hashes, which only describe what was true at install
time:

- the registry record and schema are valid, and the recorded source still resolves;
- the current **managed-source manifest** matches the one recorded at install time;
- every managed file **actually on disk** matches that source manifest;
- every expected registration exists **exactly once**, with the matching event, matcher, command,
  and timeout for that client;
- no stale registration for the same installation is left on another event;
- the target/scope/profile/config still exist;
- any native Git pre-push integration is intact.

Anything else is planned as an **update** with a precise reason (`source changed`,
`installed file missing`, `installed file modified`, `shared runtime is stale`,
`registration missing`, `registration drifted`, `duplicate registration`, `stale registration`,
`native integration stale`), or **skipped** with a precise non-destructive reason. Deleting,
corrupting, or hand-editing an installed runtime file, or removing/altering a registration, is
therefore detected and repaired even when the source has not changed at all.

### Managed files

The manifest covers **every** file the installer copies for that hook — the main script, the shared
`_hooklib.ps1`, the hook's own `.env` (hashed as a whole file; its values are never read or stored),
any other helper/data file in the hook's source folder, and the sync engine's copied config. So a
change to only a hook's `.env` or only a copied helper still triggers an update. Files the installer
does not copy (`.env.example`) and files generated or mutated at runtime (`SYNC-PROJECTS.txt`, logs)
are deliberately excluded so they never cause permanent false drift.

### Per-client semantics

Claude and Codex are tracked **separately** inside one logical installation. Installing a hook for
Claude on `SessionStart` and later for Codex on `Stop` in the same project is a supported
combination: each client keeps its own events, matcher, command, timeout, status message, runtime
paths, and manifest, and the updater repairs each client with **its own** saved parameters. Adding,
removing, or repairing one client never rewrites the other. Client selection is stored explicitly at
install time — never guessed from which runtime files happen to exist on disk.

### Native Git pre-push

`Ignore-Rules-Check`'s native Git pre-push chain is treated as part of that installation, including
its bundled managed companions (currently `Secrets-Check`). A change to a companion's **source**, or
a corrupted/missing managed companion **on disk**, plans the parent hook for update. Repair rebuilds
the wrapper exactly once, keeps the `Ignore → Secrets → previous hook` order, preserves the
fail-closed `|| exit` chaining and the single-read stdin buffering/replay, and leaves a pre-existing
(non-Hook-Maker) `pre-push.hookmaker-existing` hook **byte-for-byte untouched** — it is user-owned,
so it is never hashed, rewritten, or deleted.

Every successful install (single hook, a batch, config-based, a generated/custom hook, or the sync
engine, from any client/scope combination) is recorded — through the same shared step inside
`Install-Hook.ps1` — in `state/install-registry.json` at the Hook Maker project root:
**machine-local and git-ignored**, never committed. Entries store paths, content hashes, and the
install parameters needed to reproduce a refresh — never `.env` values, secret values, file
contents, or any prompt/tool-input content. Reinstalling the same hook into the same scope updates
its existing entry instead of creating a duplicate. Registry writes are atomic and guarded by a
bounded lock file, so two installs running at once cannot lose each other's records. The lock is
**crash-aware**: it is held as an open exclusive handle carrying non-secret owner metadata (PID,
process start time, host, timestamp, token), so a lock left behind by a killed process is
recognized as an orphan and reclaimed instead of blocking every future write forever.

### Per-hook private runtime library

Each installed hook gets its **own** `_hooklib.ps1` inside its runtime directory, and its installed
script is deterministically rewritten to dot-source that private copy. Repository sources are never
modified; the rewritten content is hashed in the plan and verified like any other artifact. This
removes cross-hook version skew — updating one hook can no longer change the library another
already-installed hook loads. A legacy shared library at the runtime root is retired only after
every hook under that root has its own copy, so hooks installed by older versions keep working
until they are updated.

### Registry validation and per-record isolation

Every record is validated before any of its fields are read: required fields and their types,
scope, hook type, engine profile/config, per-client subrecords (runtime path, settings path,
non-empty events) and manifest entry shape. A schema version **newer** than this build supports is
refused explicitly rather than assumed valid, and an older one is reported as needing migration.

A record that fails validation — or whose evaluation throws for any other reason — becomes an
isolated, precisely-reported skip. It never aborts the run, the remaining records are still
evaluated, and nothing about the bad record is modified or guessed at; it is left for manual
repair.

### Component-level repair

The integrity check reports a per-component result — source, Claude, Codex, native Git — instead of
stopping at the first problem it finds. The updater then reinstalls **only** the damaged components.
Repairing a healthy client would rewrite its settings file, add another timestamped backup and bump
its runtime timestamps for no reason, so it is left completely untouched and reported as such.

A changed **source** is a shared dependency: every client is stale by definition, so they are all
refreshed together. A missing user-owned pre-push hook is reported as `manual repair required` and
is never "repaired" by recreating it.

### Registration field verification

Every field the installer owns is verified **independently** per client and event: handler type,
`command`, `commandWindows`, timeout, statusMessage, matcher, the exact occurrence count, and the
absence of stale registrations on other events. A matching portable command no longer hides a
corrupted Windows command — Codex handlers carry both forms and each is checked on its own.

Fields Hook Maker does not own are left alone, and a record written before a field was tracked
simply carries no expectation for it rather than being reported as drifted.

### Structured outcomes

`Install-Hook.ps1 -ResultPath <file>` writes a versioned, machine-readable document describing the
outcome of each component (validation, Claude, Codex, native Git, registry). Programmatic callers
read that instead of parsing console text or assuming "no exception means success".

It distinguishes states that matter: `ok`, `failed`, `skipped` (not applicable to this invocation),
and `trackingFailed` — runtime and settings were applied but the registry write did not land, which
is reported as **partial**, never as success. The updater consumes this document *and* independently
re-reads the record and re-verifies integrity afterwards, so nothing is reported as updated unless
it is genuinely current.

Registry persistence itself is verified rather than assumed: after writing, the registry is read
back and the exact record confirmed present. (A directory occupying the registry path previously
caused the atomic write to land *inside* it while reporting success.)

### Known limitations

- Legacy discovery/removal supports only the historical layouts listed under
  "Registration ownership" above; other historical forms are reported, never rewritten.
- Concurrency is protected by a crash-aware lock around the **registry**. Settings files and
  runtime directories do not yet have their own locks, so two installs targeting the *same* client
  settings file at the same instant are not fully serialized.
- Runtime replacement is staged, hash-verified and swapped, with the previous runtime restored if
  the swap fails. That is compensating rollback, not crash-atomicity: a machine that dies mid-swap
  can still need one reinstall.
- Per-component *history* is not persisted in the registry yet — outcomes are reported for the
  current run, but past attempts are not kept per component.
- Concurrency is protected only around the registry (see above); settings files and runtime
  directories still have no lock of their own.

### Custom-hook source boundaries

A hook source is installed as one of two things, and the distinction is a
security boundary, not a convenience:

- **Package** — the script sits in `<hooks root>/<Name>/<Name>.ps1`, i.e. a folder that is a
  *direct child* of a recognized hooks root. Its (filtered) folder contents are installed with it.
  `.env.example`-style templates are never shipped, and `.git`, `.ai`, `.claude`, `node_modules`,
  build output and similar directories are never copied even from inside a package.
- **Standalone** — anything else, including a loose script in a hooks root. **Only that one file**
  is installed, and the hook is named after the *script*.

An arbitrary parent directory is never treated as a hook package, so pointing `-CustomHook` at a
script inside an unrelated project cannot copy that project's `.git`, `.env`, credentials or source
into a settings-registered runtime directory. Reparse points (symlinks/junctions) are refused
rather than followed out of the declared boundary.

### Transactional install and update

Replacing a runtime is staged, not destructive: the new tree is built in a sibling staging
directory and every planned artifact is hash-verified **before** anything live is touched, then
swapped into place; if the swap itself fails the previous runtime is restored. A failure at any
earlier point leaves the existing installation exactly as it was, and abandoned staging directories
from an interrupted run are cleaned up on the next install. Settings files are written the same
way — serialized to a sibling temp file, re-parsed from disk to prove they load, then atomically
replaced — so a failure can never leave truncated or unparseable settings behind.

### Registration ownership

A registered handler is recognized as Hook Maker's by its **managed runtime path**, checked across
`command`, `commandWindows` and `command_windows` — never by a bare script basename. Your own
handler pointing at a script that merely shares a filename with a shipped hook is preserved across
reinstalls.

Two forms are unambiguous and always ours: the current `…/hooks/Hook-Maker/<Name>/<file>.ps1`
layout and the older un-hyphenated `HookMaker` runtime root.

The pre-self-contained tool-folder form `…/hooks/<Name>/<Name>.ps1` is **not** proof of ownership on
its own — any project can have that shape. It is claimed only when the path is rooted under a tool
root Hook Maker can prove is its own: this installation, or one recorded by an earlier install in
the registry. An identical-looking path anywhere else is treated as **ambiguous**: preserved and
reported, never removed.

### Input validation

The installer validates before it mutates anything: `-ClaudeOnly` and `-CodexOnly` are mutually
exclusive, at least one valid event is required, event names are checked against the supported set
and deduplicated, and a target project must already exist. An invalid invocation leaves runtime,
settings, registry and native Git hooks completely untouched.

### If the registry is damaged

A registry that is unreadable, not valid JSON, structurally invalid, **present but empty/truncated**,
or written by a newer schema version is **never** silently treated as empty and overwritten. (An
absent file is genuinely "no registry yet"; a zero-byte one is an interrupted write whose previous
contents mattered.) The next install preserves its exact
bytes under `state/install-registry.corrupt-<UTC timestamp>-<short hash>.json`, warns with that
path, and only then starts a fresh registry. If the file cannot be quarantined, it is left
completely untouched and the install reports that **tracking failed** — the hook itself may still be
correctly installed, but it is never claimed to be tracked when it is not. The updater refuses to
list or verify anything against a damaged registry rather than reporting a misleading "up to date".

A hook installed by an **older** version of Hook Maker (before this registry existed) is picked up
automatically the moment `4` runs, for the current project, the global scope, and any other project
already referenced by your sync config's profiles — the only scopes a durable path is known for.
A Hook-Maker-managed installation in some other, unreferenced project can't be discovered this way;
reinstall it there once (any method) and it enters the registry going forward.

## How syncing works

- On `SessionStart` and `UserPromptSubmit` the hook checks, for the project you are working
  in, whether any source project's knowledge changed since the last acknowledgement.
- Unchanged sources cost one quick fingerprint and exit silently; SHA-256 only runs when the
  quick fingerprint moves; a pending review is shown at most once per session.
- Real changes are staged under `<project>/.ai/.cross-project-sync/` with a manifest, and the
  agent receives review instructions plus an acknowledgement command to run afterwards.
- An empty, never-synced source is recorded silently as a baseline (no empty review packages).

## Writing your own hooks

The easiest path is launcher menu `1` -> **Create a new hook**: name it, pick a
template, answer at most one question, and a working `.ps1` lands in `hooks/` (optionally
installed right away). Templates:

1. **Context note** — injects a fixed note (your text) into every session/prompt.
2. **Prompt guard** — blocks prompts containing your forbidden words.
3. **Tool logger** — appends every tool call to a log file next to the hook.
4. **Git sync check** — warns when the project is out of sync with its git remote (uncommitted
   changes, unpushed/unpulled commits, or a branch that was never pushed); silent for in-sync
   and non-git projects, and falls back to the last fetched state when offline.
5. **Empty skeleton** — a commented template for your own logic.

Template 4 is also shipped ready-made as `hooks/Git-Sync-Check/Git-Sync-Check.ps1` if you prefer to
install it directly (menu `1` -> install an existing hook).

In the wizard, `0` steps back one question and `exit` quits; the menus never pause for Enter.

Under the hood, a hook is just a script in `hooks/` that reads a JSON event from **stdin**
and, optionally, prints a JSON response to **stdout**. Minimal example (`hooks\MyHook.ps1`):

```powershell
$e = [Console]::In.ReadToEnd() | ConvertFrom-Json
# $e.hook_event_name, $e.cwd, $e.session_id, and event fields (e.g. $e.prompt) are available.
# Say nothing:
exit 0
# ...or inject context for the model:
@{ hookSpecificOutput = @{ hookEventName = $e.hook_event_name; additionalContext = 'note' } } |
    ConvertTo-Json -Depth 5 -Compress
```

Drop the file into `hooks/` and use launcher menu `1` — it lists every `.ps1` there,
asks for the events (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
or a custom list), the client, and the target projects, then installs it into each project's settings.
Give it its own config file next to `sync-hooks.json` if it needs configuration.

Manual install without the wizard:

```powershell
.\scripts\Install-Hook.ps1 -CustomHook .\hooks\MyHook.ps1 -Events SessionStart,UserPromptSubmit -TargetProject "<projectRoot>"
```

## Notes

- Codex requires trusting new hooks: run `/hooks` inside each project and trust the command.
- Restart clients after installing — hooks load at session start.
- Each wizard execution writes a log to `logs/` (`Setup-SyncGroup_YYYY-MM-DD_HH-mm-ss_UTC.log`).
- `scripts\Setup-SyncGroup.ps1 -NoInstall` updates only the configuration without installing hooks.
- Run the engine smoke test with `pwsh -File scripts\Test-Engine.ps1` (works under PowerShell 5.1 too).
- Persian guide: `README-FA.md`.

## License

Proprietary — all rights reserved. See `LICENSE`.
