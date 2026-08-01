# Hook Maker

Build, install, and manage Claude Code / Codex CLI / Kiro hooks — including a ready-made
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
| `hooks/_hooklib.ps1` | Shared helpers (stdin/`.env`/path/object/hash/JSON/work-time) the shipped hooks dot-source; the `_` prefix keeps it out of the hook picker. It also pins the hook's own stdin/stdout to **UTF-8** at dot-source time: `[Console]` otherwise decodes with the console code page, and a hook process with no attached console (a GUI-hosted client, or any parent spawning it with `CreateNoWindow` + redirected pipes) falls back to the machine's OEM page — which silently corrupts every non-ASCII prompt, path, and filename before the hook sees it. It also holds `Get-HookClientId`, the one shared resolution of **which client is running the hook**: an explicit client id always wins; an explicit id that is not a known client resolves to `unknown` rather than falling through to a guess; `CLAUDE_PROJECT_DIR` is Claude's own positive signal; and Codex stays the default only for a runtime carrying no explicit id — which is every Claude/Codex install made before this existed, so those resolve byte-for-byte as they always did. The known-client-id list is duplicated here on purpose: an installed runtime is self-contained, so the installer rewrites this file into it but copies no sibling from `scripts\`, and the list cannot be shared by dot-sourcing — `Test-ContextHooks.ps1` asserts the two copies are identical instead. |
| `scripts/Setup-SyncGroup.ps1` | Interactive wizard: sync groups, hook creation/installs, profile listing, validation. |
| `scripts/Setup-SyncGroupBuilder.ps1` | Sync-group builder dot-sourced by the wizard: collecting project paths, building the full-mesh route profile, confirming and applying a new or updated group. |
| `scripts/Setup-SyncGroupCreateHook.ps1` | Hook authoring dot-sourced by the wizard: the guided templates and the "Create a new hook" flow that generates a new hook from them. |
| `scripts/Setup-SyncGroupInstalledHooks.ps1` | Installed-hook management dot-sourced by the wizard: the installed-hook snapshot/list model behind menu items `21`/`22`, the uninstall screen, and the one canonical numeric list/range selection parser shared with the hook menu. |
| `scripts/Setup-SyncGroupInstallFlows.ps1` | The create-or-install sub-menu's flows dot-sourced by the wizard: the main hook list with its management rows, event/client/target selection, installing every hook a profile config names, updating previously installed hooks, and the sub-menu that dispatches all four. |
| `scripts/Setup-SyncGroupPresentation.ps1` | Console presentation dot-sourced by the wizard before every other module: the colour table, the painted-line helpers (phase headers, fields, menu and hook-menu rows, numbered/nested question prompts), and the canonical per-hook menu metadata (`$script:HookMeta` — order, label, timing, description, and the optional recommended events/timeout). |
| `scripts/Uninstall-Hook.ps1` | Removes ONE install-registry record's artifacts by id — exact-ownership settings/runtime/native-Git cleanup with compensating rollback, then the registry record. Supports `-WhatIf` and the same structured `-ResultPath` contract as `Install-Hook.ps1`. Never deletes a hook's source. |
| `scripts/Install-Hook.ps1` | Writes a hook command into a project's `.claude/settings.local.json` + `.codex/hooks.json` (or, with no `-TargetProject`, the global `~/.claude` + `~/.codex`). Supports `-CustomHook <path>`. Records the install in `state/install-registry.json` on success (see "Updating previously installed hooks"). |
| `scripts/Validate-Config.ps1` | Validates `sync-hooks.json`. |
| `scripts/Test-Engine.ps1` | Self-contained engine smoke test (18 assertions, runs under pwsh and PowerShell 5.1). |
| `scripts/Test-DependabotCheck.ps1` | Offline test suite for the Dependabot-Check hook (mocks git state and `gh`, no network/account; 31 assertions). |
| `scripts/Test-CiStatusCheck.ps1` | Offline test suite for the Ci-Status-Check hook (mocks git state and `gh`, no network/account; exact-SHA binding, external-blocker record/recheck/retire, client-aware notice shapes, and annotation-proven, pagination-safe account-billing auto-detection with its fail-closed paths; 83 assertions). |
| `scripts/Test-GithubBaselineCheck.ps1` | Offline test suite for the Github-Baseline-Check hook, incl. false-positive/negative trigger audit (mocks git state and `gh`, no network/account; 35 assertions). Split with the two suites above from one combined `Test-GitHubHooks.ps1` since the three hooks share no production code, only a common `gh` mock harness. |
| `scripts/Test-RulesCheck.ps1` | Offline test suite for the Rules-Check hook and per-client install targeting (33 assertions). |
| `scripts/Test-Wizard.ps1` | Drives the interactive wizard end-to-end via stdin (menu incl. "Update previously installed hooks", hook listing, list/range multi-select, Select All = sync group + every hook, client targeting, real self-contained installs, single-hook installs defaulting to that hook's own recommended events, a valid non-empty timing tag for every shipped hook, an unwritable project `.ai` directory failing safely with no partial rollback left behind and pre-existing `.ai` directories untouched, hierarchical `<parent>-<slot>` numbering for repeated project-path prompts, **shared project paths** — the sync group's project list reused as the install targets for every other hook in the same batch so paths are entered once, **transitive sync-group merge** — creating a group that overlaps an existing one produces one full-mesh profile over the union reusing the larger group's id, installer/idempotency + source-hash verification for the menu-affected hooks) against temp projects (192 assertions). |
| `scripts/Test-SecretsCheck.ps1` | Offline test suite for the Secrets-Check hook (nested env discovery, Secret/PublicConfig/Unknown classification precedence, PUBLIC_CONFIG_KEYS-cannot-declassify-a-credential, AUTH/OAUTH token-boundary matching, critical-only-blocks Stop policy, ignore/tracked/staged/index leak, outgoing-commit + committed-then-removed `.env*`/`secrets.md` history scan, fail-closed incomplete-scan handling via real bare-remote pushes, a real secret leaked into a tracked template file, throttled unused scan, the entropy heuristic being overridable while identified credentials are not, e-mail values never treated as credentials, and by-value grouping of the leak scan; real throwaway git repos, 137 assertions). |
| `scripts/Test-AiMemoryLoad.ps1` | Offline test suite for Ai-Memory-Load and Graph-Read-Check (content fingerprinting, whole-.ai/ file listing, truncation, graph-exists gate, English + Persian codebase-structure relevance gating, missing-graph create-then-query guidance, non-executing availability check, session/graph-version fingerprint suppression; 40 assertions). |
| `scripts/Test-AiMemoryCheck.ps1` | Offline test suite for the Ai-Memory-Check hook (missing/stale memory.md, real specialized-file enumeration, cooldown; real throwaway git repos, 11 assertions). |
| `scripts/Test-ContextHooks.ps1` | Offline test suite for Mcp-Usage-Check (SessionStart + prompt-relevance-gated UserPromptSubmit) and Skills-Check (active-agent routing — Claude vs Codex, never both policies; global + shared-library + project + `.ai/SKILLS.md` discovery and dedup; same-name/different-content conflict detection; import-guidance and Stop "Skills used:" summary requirement), plus `_hooklib.ps1`'s client-identity resolution — `Get-HookClientId`: an explicit id overrides `CLAUDE_PROJECT_DIR`, an unrecognised explicit id is `unknown` and never Codex, and no signal at all is still Codex — and the guard that its duplicated client-id list matches `_clientcapability.ps1` exactly (100 assertions). |
| `scripts/Test-Utf8EncodingCheck.ps1` | Offline test suite for the Utf8-Encoding-Check hook (strict encoding classification incl. BOM/UTF-16/Windows-1252/binary-NUL/misleading extensions, exception-registry validation, SessionStart baseline + Stop task-delta blocking, fingerprint anti-loop, Claude/Codex output shapes, and native pre-push outgoing-blob scans against real repos + bare remotes; dot-sources `_testutf8*.ps1`; 105 assertions, PowerShell 5.1 + 7). |
| `scripts/Test-IgnoreRulesCheck.ps1` | Offline test suite for the deterministic Ignore → Secrets → Utf8 → previous-hook pre-push chain, relative/absolute custom hooks paths, and template-env-file (`.env.example`/`.env.sample`/`.env.template`/`.env.dist`) allow-listing (32 assertions; real pushes, PowerShell 5.1). |
| `scripts/Test-GitSyncCheck.ps1` | Offline test suite for the Git-Sync-Check hook (mandatory Stop/SubagentStop instruction wording, fingerprint+session repeat gating, ahead/behind/dirty/no-upstream detection, non-destructive SessionStart context + baseline capture, task-scoped worktree/branch reconciliation — dirty worktrees, unreachable/unpushed branches, locked/prunable reporting, client-aware non-blocking advisory — the hook never writing to git itself; real throwaway git repos + worktrees + bare remotes, PowerShell 5.1, 48 assertions). |
| `scripts/Test-DependencyVersionCheck.ps1` | Offline test suite for the Dependency-Version-Check hook (npm/pip outdated classification via PATH-shimmed mocks — no live registry calls, GitHub Actions/runtime-pin/Docker static checks, content-fingerprint cache invalidation, new-dependency prompt guidance, advisory-only/no-file-modification guarantees; 40 assertions, PowerShell 5.1). |
| `scripts/Test-CloudflareDeploy.ps1` | Offline test suite for the Cloudflare-Deploy hook (deployment-worthiness criteria, explicit environment selection, conditional pre-deploy review, required post-deployment verification wording, failure handling, cooldown/`stop_hook_active`, the release-readiness gate — clean tree / pushed / CI-green-if-applicable / a **fresh** `clean` from `Test-Temp-Cleanup`, where `review-required`, `residue-confirmed`, `partial`, `unknown`, a stale fingerprint, a missing record and any unrecognized value each keep the hook silent — via real bare-remote pushes and a PATH-shimmed `gh`). Also pins what counts as an *installed* producer: an active **`Stop`** registration in the client's real schema (a SessionStart-only or mis-cased install is not one, on any client), whose command resolves to a physically contained runtime, backed by install-generated ownership metadata whose recomputed `projectKey` matches, and whose **whole** recorded manifest still hashes — so a file behind the registered entry point, such as the `_hooklib.ps1` it dot-sources, cannot be swapped unnoticed. The manifest must also be **complete**, since it otherwise describes itself: every required executable listed (a set mirrored from the install plan, not read from the metadata), nothing executable on disk unlisted, no duplicate entry and no reparse escape — so omitting a dependency's entry cannot hide it from verification. 130 assertions, PowerShell 5.1 and 7. |
| `scripts/Test-GraphUpdateCheck.ps1` | Offline test suite for the Graph-Update-Check hook (structural-impact criteria replacing file-count wording, staleness/freshness detection, cooldown/`stop_hook_active`; 14 assertions, PowerShell 5.1). |
| `scripts/Test-TestTempCleanup.ps1` | Offline test suite for the Test-Temp-Cleanup hook. Every filesystem claim is a real on-disk assertion: **nothing is ever mutated** (a `.pytest_cache` created after the baseline still exists after Stop; review artifacts, tracked/staged candidates, junction targets and `.kiro` all survive), the hook's parsed **AST** contains no reachable project-mutation command and no mutating git subcommand, `.kiro` is hard-pruned and never descended into, the report always instructs the agent to inspect before deleting, a missing baseline stays conservative, the scan-entry ceiling yields `partial` and never `clean`, an unreadable directory yields the named cause `directory-unreadable`, unknown git state is never called disposable, unchanged evidence is anti-loop suppressed while changed evidence re-reports, the Claude and Codex adapters carry the same semantic instruction, and the five-value result-category contract still matches `Cloudflare-Deploy` (80 assertions, PowerShell 5.1). |
| `scripts/Test-DocsFreshnessCheck.ps1` | Offline test suite for the Docs-Freshness-Check hook (SessionStart baseline, task-delta detection across committed/staged/working-tree changes, comment/blank-only-change silence, hard exclusions, ranked tracked-doc candidates, content-hashed impact fingerprint immune to unrelated doc edits, the Updated/NoUpdate acknowledgement flow with rejection of generic reasons and out-of-root/private/untracked paths, acknowledgement invalidation on a further non-doc change, `stop_hook_active`, self-contained installer copies; real throwaway git repos, 40 assertions, PowerShell 5.1). |
| `scripts/Test-InstallRegistry.ps1` | Offline test suite for the install registry and "Update previously installed hooks" (single/multi/config-based/generated/sync-engine installs tracked without duplication, Claude/Codex/Both + project/global scope, byte-for-byte refresh preserving events/client/target/scope/profile, never installing a never-installed hook, missing-source/target reported and skipped, second-run idempotency, no secret/`.env`/prompt content ever stored, unrelated JSON preserved; **installed-state drift** — deleted/modified runtime script, stale or missing shared `_hooklib.ps1`, removed Claude/Codex registration, moved event, changed matcher, duplicate registration, one wiped client runtime — detected and repaired with no source change at all; **managed manifest** covering `.env`/copied helpers/added/removed files while ignoring runtime-generated files; **per-client semantics** (Claude `SessionStart` + Codex `Stop` preserved independently across an update, repairing one client leaving the other byte-for-byte untouched); **v1→v2 migration** deriving events from live registrations and flagging unprovable records for manual repair; **native pre-push** with a deliberately corrupted companion repaired, chain order/single-wrapper/stdin-replay/fail-closed preserved and the user's previous hook byte-for-byte intact; **corrupt-registry quarantine** (malformed JSON, wrong field types, unsupported version, stale `.tmp`, unique collision names, quarantine failure leaving the original untouched, concurrent lock-guarded writers losing no records); structured install-result contract guaranteed on every terminal outcome (validation/runtime/native-git failure, success, and registry-tracking failure) via a top-level trap, and post-commit-only legacy runtime/config cleanup proven with a forced staging failure; real throwaway projects/git repos + disposable custom-hook fixtures, 259 assertions). |
| `scripts/Test-InstallRegistrySchema.ps1` | Offline test suite for registry schema validation, per-record isolation (a malformed record never blocks evaluating healthy ones), corruption/availability handling (zero-byte file, orphan lock), and the path-safety primitives the installer relies on (47 assertions). |
| `scripts/Test-NativePrePushInstall.ps1` | Offline test suite for the native Git pre-push integration: chain order, single-wrapper-per-stage, stdin replay, fail-closed chaining, the user's previous hook preserved byte-for-byte, repair of a deliberately corrupted companion; real throwaway git repos (37 assertions). |
| `scripts/Test-LegacyDiscovery.ps1` | Offline test suite for legacy/untracked hook discovery ("Update previously installed hooks"): a registration in only one of `command`/`commandWindows`/`command_windows` is still found, the same registration split across two fields yields one candidate, an ambiguous proven-shape path outside any known tool root is never imported, an unrelated same-basename command is never confused with a real one (7 assertions). |
| `scripts/_testlib.ps1` | Shared assertion helper used by the offline PowerShell test suites. |
| `logs/` | Wizard execution logs (created on demand, not committed). |
| `scripts/_clientcapability.ps1` | The **one** canonical description of every client Hook Maker installs for: the client set, Hook Maker's own logical hook-event vocabulary, which of those events each client supports, and which of them that client can actually *block* on. The wizard and `Install-Hook.ps1` both derive from it (and so does `_installlib.ps1`), which removes a real defect: there used to be two independent event lists — the wizard offered 12, the installer accepted 9 — so `PermissionRequest`, `PostCompact` and `SubagentStart` were each reachable through the custom-event prompt and each fatal on install. All three are real, currently documented events, so the 9-entry list was the stale side of that pair. Event matching is case-insensitive but always writes back the canonical spelling, because client configs are case-sensitive about trigger names. A second copy of any of this data is a defect, not an optimization. |
| `scripts/_installlib.ps1` | Install-time-only library and the single entry point consumers dot-source (it dot-sources `_clientcapability.ps1` plus the three files below, so no consumer needs changing). What remains here is one concern: **is a recorded install still intact** — managed-file manifest builders and comparison, native pre-push state, registration inspection, and `Get-InstallIntegrity`. Deliberately separate from `hooks/_hooklib.ps1`, which is copied into every installed runtime. |
| `scripts/_installvalidate.ps1` | Read-only shape judgement on one persisted managed record (`Test-InstallRecordValid`, canonical-path helpers). Mutates nothing and returns `{ Ok; Reason }` — the same shape as `_uninstallownership.ps1`, keeping proofs apart from the machinery that acts on them. The canonical settings path for a record is derived from `_clientcapability.ps1`, replacing an `if ($ClientName -eq 'claude') { … } else { … }` fallthrough that made **every** non-Claude client resolve to Codex's `hooks.json` — the very file a record is validated, updated and uninstalled against. An unrecognised client is now rejected outright, and a client that registers one file per installation has no shared settings path at all, so the helper refuses rather than synthesising one the caller cannot tell is fake. Either refusal becomes an ordinary `{ Ok = $false }` rejection, because a validator that throws aborts the whole update run and leaves every healthy record after it unevaluated. Exercised by `Test-InstallRegistrySchema.ps1`. |
| `scripts/_installlegacy.ps1` | Pre-registry discovery: finds live registrations the registry never recorded (`Get-LegacyScanScopes`, `Get-ScopeSettingsPaths`, `Find-ManagedCommands`, `Get-LegacyHookCandidates`). Exercised by `Test-LegacyDiscovery.ps1`. |
| `scripts/_installregistry.ps1` | The registry-persistence layer split out of `_installlib.ps1` (which dot-sources it, so consumers need no change): registry path/shape/quarantine, crash-aware locking, record identity and per-client subrecords, v1→v2 migration, and the locked atomic record upsert. |
| `scripts/_installlibmanifest.ps1` | Manifest building/comparison and native pre-push state, split out of `_installlib.ps1` (which dot-sources it). |
| `scripts/_installlibregistration.ps1` | Registration inspection for the shared-settings clients and Kiro side by side, split out of `_installlib.ps1` (which dot-sources it). |
| `scripts/_hookstatusscanregistrations.ps1` | Claude/Codex settings parsing and Kiro per-hook-file parsing, split out of `_hookstatusscan.ps1` (which dot-sources it). |
| `scripts/_hookstatusscangit.ps1` | Native Git pre-push discovery, split out of `_hookstatusscan.ps1` (which dot-sources it). |
| `scripts/_installdiscovered.ps1` | The other record kind sharing that file, split out of `_installregistry.ps1` (which dot-sources it): a *discovered* record is one the read-only status scan found rather than one Hook Maker installed, so it has its own stable id derivation, its own field validators (including the rule that a raw command line is never persisted), and its own merge against the managed set. Exercised by `Test-InstallRegistrySchema.ps1`. |
| `scripts/_installruntime.ps1` | Runtime materialization split out of `Install-Hook.ps1` (which dot-sources it): building the self-contained runtime copy a registration points at — the planned, hash-verified, transactional swap plus its post-commit legacy cleanup — and the two command lines (Windows PowerShell / pwsh) that invoke that copy. |
| `scripts/_installclientsettings.ps1` | Client settings mutation split out of `Install-Hook.ps1` (which dot-sources it): the read-modify-write of one client's settings file — pruning only handlers this install provably owns, inserting the handler group, backing the file up, and replacing it transactionally after re-parsing the serialized JSON from disk. |
| `scripts/_installnativegit.ps1` | The native Git pre-push chain split out of `Install-Hook.ps1` (which dot-sources it): for the one hook that also manages a real `.git/hooks/pre-push` wrapper, it stages the managed runtime and its chain companions through the same canonical plan, preserves any pre-existing user hook as opaque bytes, regenerates only the owned wrapper, and records what the chain manages so the updater can detect companion drift. |
| `scripts/_installkiroclient.ps1` | The Kiro client install FLOW split out of `Install-Hook.ps1` — distinct from `_installkiro.ps1`, which is the pure document format. This file owns every Kiro filesystem write: the runtime rollback snapshot, the ordered commit of runtime then registration, the lock around the registration write, and the degradation reporting. It is dot-sourced at the position the Kiro phase runs (it carries the phase's top-level block, not only functions). |
| `state/` | **Machine-local and git-ignored.** `install-registry.json` — what Hook Maker has installed and where (see "Updating previously installed hooks"); never holds secret/`.env`/prompt content or file contents. A damaged registry is preserved beside it as `install-registry.corrupt-<UTC timestamp>-<short hash>.json` instead of being overwritten. |

## Shipped hooks

23 hooks ship with Hook Maker. The **full per-hook reference** — exact events, behaviour
contract, protections and config for every hook — lives in [docs/HOOKS.md](docs/HOOKS.md)
(moved there verbatim; the front page could no longer carry it). The fixed menu list below
enumerates every hook with a one-line summary, and each hook's own `.env.example` documents
its settings.
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
(not a hook itself) that runs the **sync group AND every individual hook below** in one pass, using
each hook's recommended events with a shared client/projects answer. You do **not** need to also
type `2` — `1` alone always includes the sync group. The individual-hook set is derived dynamically
from the hooks actually shipped (never a hard-coded count), so adding or removing a hook folder
changes it automatically; the sync group always runs exactly once even if `2` is also listed
explicitly (e.g. `1,2`), and it never runs the management actions (`25`–`28`). List item `2` is
the **sync group** on its own. Individual hooks start at `3`, each showing a colored timing tag and
a one-line description, with `Cloudflare-Deploy` fixed as the **last** individual entry. The menu
uses five distinct tag colors so they never blur together: `[pre-task]` (mint), `[post-task]`
(amber), `[pre+post-task]` (aqua), the `[all]` aggregate (orchid), and the `[manage]` actions
(teal). You can also **install a subset** with lists and ranges (e.g. `3-8,20`) — use each hook's
recommended events with shared client/projects or configure each separately, then a summary lists
exactly what will be installed. Combining `1` with an explicit pick (e.g. `1,5`) never installs
anything twice. **Shared project paths:** when the sync group runs alongside other hooks (including
via `1`), the project paths you enter for the sync group are reused as the install targets for every
other selected hook — you enter them **once**, not once per hook. If the sync-group stage is
canceled, the individual hooks are not installed and nothing is falsely reported as completed. Picking a **single** hook shows that
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

**Linking groups that overlap merges them automatically.** If a group you create shares any project
with an existing group, the two are really one mesh — you linked them. The wizard computes the
transitive closure and writes **one** full-mesh profile over the union: sync `A,B,C`, then sync `D`
with `C`, and `D` ends up meshed with `A`, `B` **and** `C`, not only `C`. The merged profile reuses
the larger group's id, so that group's already-installed hooks keep working and pick up the widened
mesh from the live config with no reinstall — only the new project (and any member of a smaller
absorbed group, whose old profile id is removed) gets an engine install. A route you had explicitly
disabled stays disabled after the merge; it is never silently re-enabled.

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
preserved, and a timestamped backup is written first — **once per wizard run, not once per hook**.
Installing 20 hooks is 20 separate installs, so a single `settings.local.json` used to collect 20
near-identical copies of itself; the first install of a run now writes
`settings.local.json.backup-install-<run>` and the rest leave it alone, so what is preserved is the
file as it was *before* the batch. Uninstalls do the same with `-uninstall-<run>`. A direct
`Install-Hook.ps1` call outside the wizard keeps the old per-invocation name.

Global install works the same way: `scripts/Install-Hook.ps1` with no `-TargetProject` copies to
`~/.claude/hooks/Hook-Maker/` + `~/.codex/hooks/Hook-Maker/` and registers in
`~/.claude/settings.json` and `~/.codex/hooks.json`.

## The hook list: fixed menu numbering

The "Available hooks" list uses **fixed numbers**, so the three management actions never move when
you add or create hooks:

| Item | What it is |
| --- | --- |
| `1` | Select all hooks — the sync group **and** every hook below (shipped + your own). Never runs `25`–`28`. |
| `2` | Create or update a sync group |
| `3`–`23` | The 21 shipped hooks, in a pinned order (`9` is `Docs-Freshness-Check`; `20`–`22` are the three test-health hooks; `23` is `Utf8-Encoding-Check`) |
| `24` | `Cloudflare-Deploy` |
| `25` | **Update installed hooks** |
| `26` | **Get hook status** |
| `27` | **Uninstall installed hooks** |
| `28` | **Reset sync groups** |
| `29`+ | Your own created/custom hooks under `hooks\`, in deterministic name order |

Discovering or creating a custom hook adds rows from `29` onward and **never shifts `25`–`28`**.

Selections accept a single number, a comma list, and inclusive ascending ranges — `1`, `1,2`,
`1,2,3-6`. `25`–`28` are management actions, not hook selections: each must be chosen on
its own, and combining any of them with hook numbers (`3,25`, `24-26`, `1,26`, `25,27`) is rejected
rather than half-executed.

## Updating installed hooks (`25`)

Because installs are self-contained copies, editing a hook's source under `hooks/` (or updating
Hook Maker itself) does **not** change any copy you already installed — the copies are frozen at
install time. Rather than re-selecting and reconfiguring every hook you've installed one by one,
use item **`25` Update installed hooks** (also reachable as `4` in the "Create or install a hook"
submenu, which is a compatibility alias for the *same* implementation).

This reads a local install registry, shows a plan, asks **one** confirmation, then repairs
everything that needs it — reusing each installation's original events, client selection,
target/global scope, and (for the sync engine) profile/config, so you never re-answer the same
questions. It updates from each record's **persisted source path**, never a path reconstructed from
the hook's name, so a hook you created yourself is refreshed from where it actually lives. If a
source was moved or deleted it is reported as missing and skipped — no other path is guessed. It
never installs a hook that was never installed, never touches unrelated settings-file content, and
a second run with nothing changed reports everything as already current (no-op).

## Getting hook status (`26`)

Item **`26` Get hook status** scans a path you choose, reports every installed hook it can find —
**Hook Maker's own and third-party alike** — and records the verified results. It is an explicit,
on-demand action: nothing scans on startup, and item `25` still only looks at its own registry.

It asks two questions:

1. **`Root folder to scan`** — a project root, a parent holding many projects, a `.claude` /
   `.codex` / `.git` / `hooks` / `Hook-Maker` directory, any ancestor of an installed hook, or a
   drive root such as `G:\`. Quoted paths, paths with spaces and environment variables all work, and
   the path is canonicalised before scanning. You do **not** have to supply the exact project root:
   given `...\.claude\hooks\Hook-Maker` it looks upward for the matching registration.
2. **`Also inspect the current user's global Claude, Codex and Kiro hook locations?`** — **defaults to
   No** (Enter means No). Answering Yes inspects only the canonical current-user `.claude`/`.codex`
   settings locations; it never walks your whole home directory. Answering No means those files are
   **not opened at all**, by any code path.

What it inspects: Claude `settings.local.json` and `settings.json`, Codex `hooks.json`, the hook
runtime trees those registrations point at, and native Git hooks — including `.git` files with
`gitdir:` (worktrees and submodules) and a custom `core.hooksPath`. All hook events and handlers are
parsed, not just Hook Maker's, and `*.sample` is ignored.

**Nothing is ever executed.** Commands found in settings are parsed as text only — never run,
dot-sourced, or resolved through an interpreter — and no Git hook is invoked. The scan is read-only
with respect to the folder you point it at, and never writes anything inside it.

Reparse points (symlinks, junctions, mount points) are **not followed** and are reported as skipped.
Directories that cannot be read produce **partial coverage**, not a failed scan: verified findings
are still saved, the run is reported as partial, and records under unreadable areas are never marked
as missing. A scan that did not see everything can never claim it did.

Verified results are saved to `<Hook-Maker>\state\install-registry.json` — the same single registry
used for installs, with discovered records kept distinct from Hook Maker's own managed ones. A later
scan updates the same record rather than duplicating it; two hooks with the same name at different
paths stay separate. A cancelled or failed scan writes nothing.

A hook Hook Maker itself installs is never also kept as a discovered one. Coverage is proved by the
exact paths the managed record registered — including a Kiro registration, which points at the
hook's `kiro-launch.ps1` shim rather than at the hook script — and a discovered record for that same
artifact is retired the next time it is recognised. Without that, reinstalling over a path an
earlier scan had discovered left a duplicate row in the uninstall list that could never be removed.

Findings are reported as either **status-only** or **safely removable**. Anything ambiguous, shared
between hooks, or outside a recognised hook root is shown but never auto-deleted.

## Uninstalling installed hooks (`27`)

Item **`27` Uninstall installed hooks** removes tracked installations — Hook Maker's own plus
anything item `26` discovered. It accepts the same `1` / `1,2` / `1,2,3-6` syntax, and shows each
row's record type and whether removal is possible.

It asks **which set** before it lists anything, because a machine that has been used for a while
holds hundreds of installs and one flat list of all of them cannot be picked from:

1. **Only the hooks in one project** (the default) — you give a folder, and only installs whose
   recorded project root is that folder *or inside it* are listed. Global-scope installs are left
   out. The folder does not have to still exist (so a deleted project can still be untracked),
   quotes around a pasted path are accepted, and a folder with no tracked install says so and
   re-offers the choice instead of dropping you out of the screen.
2. **Every installed hook** — one list of everything tracked.

When the list holds exactly one `Remove all …` row — which a project scope always produces — that
row is the selection default, so Enter clears the project. The `y/n` confirmation after it still
defaults to **No**, so pressing Enter twice changes nothing.

Two kinds of row are offered:

- **Individual** — one row per logical installation, showing the hook (and profile, for the sync
  engine), scope, exact project root or `global`, and which clients it is installed for.
- **Aggregate** — after those, one row per project (`Remove all Hook Maker hooks from project:
  <path>`) and, when global installs exist, `Remove all global Hook Maker hooks`.

Selecting an aggregate together with one of its own individual rows removes each installation
exactly once (deduplicated by record id).

**Your hook source files are never deleted.** Uninstalling removes only the installed runtime
copies, the client registrations, any native Git integration owned by that record, and the registry
record itself. The originals under `hooks\` are untouched, so you can reinstall at any time.

**A record Hook Maker cannot interpret can still be dropped — as a tracking row only.** If a record
is damaged past the point where its client list can be read, nothing can prove what it installed, so
no file is touched. The row is listed as removable with the capability `registry record only
(nothing on disk)` and removing it drops the registry entry alone; whatever is still installed stays
installed, and the next status scan finds it again as a discovered hook, which does have a removal
path. The engine switch is `Uninstall-Hook.ps1 -ForgetUnreadableRecord`, and it refuses outright for
a record that *can* be interpreted — that one has a real uninstall and must use it.

Removing a **discovered** (third-party) hook follows a stricter rule, because Hook Maker did not
install it and so cannot rely on its own install record:

- The live settings or hook file is re-read and re-fingerprinted first. If anything changed since
  the scan, nothing is removed for that record — it is kept and reported as needing manual repair.
- Handlers are matched by exact structural fingerprint plus event/matcher context. Never by
  filename, friendly name, event alone, array position, or "looks like a Hook Maker path". Every
  unrelated handler, matcher, event and JSON field in the file is preserved.
- Removing the registration and deleting the runtime file are **separate decisions**. A file is
  deleted only when it is the exact recorded target, its hash still matches, it sits inside a
  recognised hook root (`.claude\hooks`, `.codex\hooks`, or the effective Git hooks directory), it
  is a proven entrypoint rather than a shared helper, and nothing else still references it.
  Otherwise the registration goes and the file stays — reported as *registration removed; runtime
  preserved*.
- Files outside a recognised hook root are never deleted automatically, and `*.sample` Git hooks are
  never removed.

Safety properties:

- Ownership is proven by the managed runtime **path**, checked across `command`, `commandWindows`
  and `command_windows` — never by a bare filename. A handler of yours that merely points at a
  same-named script elsewhere is preserved.
- Only the selected record's own per-client runtime directory is removed, and only inside a
  physically verified boundary. Another hook's runtime, the shared `Hook-Maker` root while other
  hooks remain, and anything outside the expected path are all refused.
- Settings files are written under the same per-file lock, atomic writer and timestamped-backup
  behavior as installs; unrelated groups, handlers and JSON properties survive untouched.
- Before anything is touched you get a summary of every installation, scope, client, runtime path,
  settings path and whether native Git is involved, and it proceeds only on an explicit `y`.
  Cancelling, declining, going back, quitting or entering an invalid selection performs **no**
  mutation at all — no backups, no registry write, no file removal.
- A record is removed from the registry only after its owned cleanup is verified. If an uninstall
  is partial or ambiguous, the record is **kept** with a precise failure/manual-repair state rather
  than reporting a success that did not happen. Repeating an uninstall is idempotent.
- For native Git, the managed wrapper is regenerated around any stages that remain, or your
  previously preserved `pre-push` hook is restored **byte-for-byte** when no managed stages are
  left. A wrapper that has drifted or been tampered with is preserved and reported for manual
  repair rather than overwritten.

As with installs, this uses compensating rollback (runtime directories are set aside and restored
if a later step fails), **not** machine-crash atomicity — see "Known limitations".

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

### One runtime directory, several owners

A project that belongs to **several sync groups** gets one engine record per group — same hook, same
client, same project, differing only by profile — and they all register handlers pointing at the
**same** runtime directory. Only one of them can be named in that directory's ownership metadata, so
the others would otherwise read as drift for ever: reinstalled on every run, and still "wrong" on the
next one.

When the ownership document is the **only** file that differs, it is therefore accepted if it states
this hook, this client, this scope, this project, an internally consistent registration name and a
matching hash for every file it lists — with only the record id differing. A document that disagrees
about any of those, or that cannot be parsed, is still drift, and every other file is still compared
byte-for-byte. Uninstall ownership is unchanged: it still proves a record owns what it removes.

### Managed files

The manifest covers **every** file the installer copies for that hook — the main script, the shared
`_hooklib.ps1`, the hook's own `.env` (hashed as a whole file; its values are never read or stored),
any other helper/data file in the hook's source folder, and the sync engine's copied config. So a
change to only a hook's `.env` or only a copied helper still triggers an update. Files the installer
does not copy (`.env.example`) and files generated or mutated at runtime (`SYNC-PROJECTS.txt`, logs)
are deliberately excluded so they never cause permanent false drift.

### Per-client semantics

Claude, Codex and Kiro are tracked **separately** inside one logical installation. Installing a hook
for Claude on `SessionStart` and later for Codex on `Stop` in the same project is a supported
combination: each client keeps its own events, matcher, command, timeout, status message, runtime
paths, and manifest, and the updater repairs each client with **its own** saved parameters. Adding,
removing, or repairing one client never rewrites the other. Client selection is stored explicitly at
install time — never guessed from which runtime files happen to exist on disk.

Clients are **independent components**. If one cannot be installed, the others still are, and the
overall result is `partial` rather than `failed` — reporting `failed` would tell a caller to discard
two installations that genuinely succeeded. Only a request where *nothing* landed is `failed`.

### Kiro

Kiro registers **one JSON document per hook** under `.kiro\hooks\hookmaker-<hook>-<id>.json`, not a
shared settings file. Hook Maker owns individual **entries**, proven by a `[hookmaker:<id>]` marker,
so foreign entries in the same document are carried across untouched and a document at our own path
that turns out to be someone else's is refused rather than overwritten. The runtime is copied to
`.kiro\hook-runtime\Hook-Maker\` — deliberately **not** under `.kiro\hooks`, which Kiro scans as
configuration.

Four Kiro facts shape the install and are not worked around:

- **The input surface differs between Kiro's two surfaces, and that difference is not flattened.**
  Kiro IDE documents only `USER_PROMPT`, only on `UserPromptSubmit`. Kiro CLI v3 *does* send stdin
  JSON — it simply does not publish its field names or casing. So each entry's command ends in
  `-Trigger <trigger>` and runs through a generated `kiro-launch.ps1`, which supplies the event and
  the client identity through the environment and then runs the hook in-process, so stdin and the
  real exit code still pass through. No `session_id` is invented — session-keyed behaviour degrades
  instead of silently mispairing.
- **An input Kiro may not deliver is reported as _unverified_, never as confirmed-absent.** The
  install still degrades on it — registering a hook that silently cannot work is the worse error —
  but the report does not claim more than the documentation supports. Saying "Kiro cannot supply
  this" would state an unverified CLI v3 fact as a confirmed one.
- **A registration that disagrees with Kiro — or supplies no `-Trigger` at all — is refused, not
  guessed.** If the trigger recorded in the `.kiro\hooks` registration and the event Kiro reports
  resolve to two *different* events, or the invocation carries no resolvable `-Trigger` (every Hook
  Maker registration passes one, so its absence means the registration is not ours or was altered),
  the hook writes a bounded warning to stderr and exits non-zero instead of letting stdin select a
  branch. Corrupt (non-empty, unparseable) stdin refuses the same way. Different spellings of the
  *same* event are normalized first, so an undocumented CLI v3 casing never trips it.
- **Kiro cannot block at `Stop`** on either targeted surface, and only `SessionStart` and
  `UserPromptSubmit` add stdout to context. Stop-gating hooks therefore record `degraded-stop-gate`
  permanently, and events Kiro has no trigger for are reported by name — never dropped in silence and
  never remapped onto a different trigger.

A prompt over 64 KB of **UTF-8 bytes** (whether it arrived via `USER_PROMPT` or inside a CLI v3
stdin payload) is **withheld from hooks entirely, never truncated**: a truncated prefix is a prompt
the user did not type, and prompt-driven checks would match on it as if it were. Hooks take their
documented no-prompt degradation instead, and a one-line stderr notice reports the withholding so
it is never silent.

Kiro supports `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop`; any other
requested event is reported as unsupported for Kiro while still installing for the other clients.

### Native Git pre-push

`Ignore-Rules-Check`'s native Git pre-push chain is treated as part of that installation, including
its bundled managed companions (currently `Secrets-Check`). A change to a companion's **source**, or
a corrupted/missing managed companion **on disk**, plans the parent hook for update. Repair rebuilds
the wrapper exactly once, keeps the `Ignore → Secrets → Utf8 → previous hook` order, preserves the
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
bounded lock file, so two installs running at once cannot lose each other's records. The same
crash-aware primitive guards **each settings file** during its read-modify-write, so two processes
installing different hooks into one settings file cannot lose each other's handlers (verified with
two real concurrent processes). Locks are taken one at a time — Claude settings, then Codex
settings, then the registry, never nested — so no deadlock cycle can form. The lock is
**crash-aware**: it is held as an open exclusive handle carrying non-secret owner metadata (PID,
process start time, host, timestamp, token), so a lock left behind by a killed process is
recognized as an orphan and reclaimed instead of blocking every future write forever.

### The persistent tracking file

There is exactly **one** persistent state file, and it is the single source of truth for what Hook
Maker has installed:

```text
<Hook-Maker>\state\install-registry.json
```

`HOOKMAKER_STATE_DIR` overrides its location, but that override exists for the test suites (so they
never touch your real registry) and for a deliberate, documented relocation — it is not part of
normal use. No second registry, cache, catalog, per-project tracking database, or hidden
source-of-truth file exists anywhere.

**What it stores:** for each installation, the record id, hook identity and type, the exact source
script and source directory, the tool root, scope and target project root, profile and config path
for engine installs, the managed-file manifest (path + hash), and per client: the exact settings
path, runtime root, runtime script, registered events, generated command lines, handler type,
timeout and status message. For a managed native Git chain it additionally stores the Git hooks
path, wrapper path, expected stages, owned companions and the preserved-user-hook state.

**What it never stores:** secret values, `.env` contents, prompt or tool-input text, stdin, or the
contents of any copied file. Paths and hashes only.

**Menu `21` and `22` depend on it.** Filesystem discovery under `hooks\` is only the catalog of
hooks *available* to install — it is never proof that something *is* installed. Consequently:

- Update refreshes from each record's **persisted `sourceScript`**, never a path rebuilt from the
  hook's name. If that source has been moved or deleted it is reported as missing and skipped — no
  other path is guessed.
- Uninstall targets the **exact persisted** runtime script, settings path and command for that
  record. A handler is removed only when its parsed command proves that exact identity; a
  same-named or same-basename handler pointing anywhere else is foreign and survives.
- **Source hooks under `hooks\` are never deleted** by any operation.
- If an uninstall is partial or ambiguous, the record is **retained** with a precise
  failure/manual-repair state rather than reporting a success that did not happen.

**Persistence guarantees:** every mutation takes the crash-aware exclusive registry lock, writes to
a sibling temp file, re-parses the JSON before publishing it, and reads the record back afterwards
to confirm it persisted. A registry that cannot be parsed is quarantined with its exact original
bytes preserved beside it rather than being overwritten. Records survive across separate wizard and
script processes — that is verified by a regression that installs in one process, verifies and
updates in a second, and uninstalls in a third.

As everywhere else in this tool, this is compensating rollback rather than machine-crash atomicity
— see "Known limitations".

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

### Per-component history

Each record keeps a **bounded** history (last 10 attempts) where every entry carries the outcome of
each component for that attempt, not one flattened verdict — so a partial failure stays visible
afterwards instead of being overwritten by a later `ok`. Entries hold timestamps, component names,
statuses and reason codes only: never file contents, `.env` values, prompt text or raw output.

### Known limitations

- Legacy discovery/removal supports only the historical layouts listed under
  "Registration ownership" above; other historical forms are reported, never rewritten.
- Runtime directories and the native Git integration do not have a dedicated inter-process lock of
  their own; the registry and each settings file do.
- Runtime replacement is staged, hash-verified and swapped, with the previous runtime restored if
  the swap fails. That is compensating rollback, not crash-atomicity: a machine or process that
  dies mid-swap can still need one reinstall. The same applies to removing a discovered hook.
- A hook status scan (`22`) reports what it could actually reach. Directories it could not read, and
  reparse points it deliberately did not follow, are listed and the run is reported as **partial** —
  it does not claim that every unreadable, system or reparse directory was scanned.
- A discovered registration whose command cannot be parsed to a single target is still reported as
  an installed hook, but it cannot be removed automatically — there is no proven target to act on.

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

## Resetting sync groups (`28`)

Item **`28` Reset sync groups** removes every sync group from `sync-hooks.json` in one confirmed
step — for when the config has accumulated stale groups and you want a clean start. It lists each
group (id, name, route count) first, then asks one `y/n` question defaulting to **no** (Enter
cancels; nothing is changed on decline). A timestamped backup
(`sync-hooks.json.backup-<stamp>`) is written beside the config before anything is removed, the
disabled `example-sync-profile` template is kept, and the result is re-validated. This changes
routing **configuration only**: no hook is uninstalled and no file in any project is touched — use
item `27` for that.

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
