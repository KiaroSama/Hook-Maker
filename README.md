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
| `scripts/Install-Hook.ps1` | Writes a hook command into a project's `.claude/settings.local.json` + `.codex/hooks.json` (or, with no `-TargetProject`, the global `~/.claude` + `~/.codex`). Supports `-CustomHook <path>`. |
| `scripts/Validate-Config.ps1` | Validates `sync-hooks.json`. |
| `scripts/Test-Engine.ps1` | Self-contained engine smoke test (18 assertions, runs under pwsh and PowerShell 5.1). |
| `scripts/Test-GitHubHooks.ps1` | Offline test suite for the GitHub hooks (119 assertions; mocks git state and `gh`, no network/account). |
| `scripts/Test-RulesCheck.ps1` | Offline test suite for the Rules-Check hook and per-client install targeting (33 assertions). |
| `scripts/Test-Wizard.ps1` | Drives the interactive wizard end-to-end via stdin (menu, hook listing, list/range multi-select, Select All = sync group + every hook, client targeting, real self-contained installs, graceful handling of an unwritable project `.ai` directory, hierarchical `<parent>-<slot>` numbering for repeated project-path prompts) against temp projects (123 assertions). |
| `scripts/Test-SecretsCheck.ps1` | Offline test suite for the Secrets-Check hook (nested env discovery, critical/advisory pre-push policy, ignore/tracked/staged/index leak, outgoing-commit + committed-then-removed `.env*`/`secrets.md` history scan, fail-closed incomplete-scan handling via real bare-remote pushes, a real secret leaked into a tracked template file, throttled unused scan; real throwaway git repos, 70 assertions). |
| `scripts/Test-AiMemoryLoad.ps1` | Offline test suite for Ai-Memory-Load and Graph-Read-Check (content fingerprinting, whole-.ai/ file listing, truncation, graph-exists gate; 22 assertions). |
| `scripts/Test-AiMemoryCheck.ps1` | Offline test suite for the Ai-Memory-Check hook (missing/stale memory.md, real specialized-file enumeration, cooldown; real throwaway git repos, 11 assertions). |
| `scripts/Test-ContextHooks.ps1` | Offline test suite for Mcp-Usage-Check and Skills-Check (16 assertions). |
| `scripts/Test-IgnoreRulesCheck.ps1` | Offline test suite for the deterministic Ignore → Secrets → previous-hook pre-push chain, relative/absolute custom hooks paths, and template-env-file (`.env.example`/`.env.sample`/`.env.template`/`.env.dist`) allow-listing (32 assertions; real pushes, PowerShell 5.1). |
| `scripts/Test-GitSyncCheck.ps1` | Offline test suite for the Git-Sync-Check hook (mandatory Stop instruction wording, fingerprint+session repeat gating, ahead/behind/dirty/no-upstream detection, non-destructive SessionStart context, the hook never writing to git itself; real throwaway git repos + bare remotes, 25 assertions). |
| `scripts/Test-DependencyVersionCheck.ps1` | Offline test suite for the Dependency-Version-Check hook (npm/pip outdated classification via PATH-shimmed mocks — no live registry calls, GitHub Actions/runtime-pin/Docker static checks, content-fingerprint cache invalidation, new-dependency prompt guidance, advisory-only/no-file-modification guarantees; 36 assertions, PowerShell 5.1). |
| `scripts/_testlib.ps1` | Shared assertion helper used by the offline PowerShell test suites. |
| `logs/` | Wizard execution logs (created on demand, not committed). |

## Shipped hooks

| Hook | Runs | What it does |
| --- | --- | --- |
| `Cross-Project-.ai-Knowledge-Sync` | pre-task (SessionStart, UserPromptSubmit) | The sync engine: stages changed `.ai` knowledge from related projects for review. |
| `Git-Sync-Check` | pre-task + post-task (Stop) | Reports uncommitted/unpushed/unpulled work at SessionStart/UserPromptSubmit as non-blocking context (never modifies the repository). On Stop it is a detection-and-instruction boundary, not an executor — the hook itself never runs `git add`/`commit`/`pull`/`push`; instead it gives the agent a **mandatory** operational instruction to reconcile the repository now (stage this task's verified changes, commit with a neutral message, push) instead of waiting for a separate user request, unless doing so is unsafe (failing tests, incomplete work, unrelated pre-existing changes, secrets/protected files, a merge/rebase/conflict state, or an authorization/permission block) — in which case the agent preserves the work and reports why. A real git inspection runs on every Stop (never a blind time-only skip); repeat blocking is gated by a fingerprint of the actionable state (branch/HEAD/upstream/ahead-behind/status) combined with the session id, so a given state is instructed once per session, while a changed state or a new session is evaluated and instructed again immediately. |
| `Ai-Memory-Load` (menu: `Ai-Context-Load`) | pre-task (SessionStart, UserPromptSubmit) | Loads `.ai/memory.md` (the startup router) directly into context and lists every other top-level `.ai/*.md` file by name, so the agent can route to the relevant project context without loading unrelated files. Fingerprinted on the router content plus the file set; capped with a truncation note; silent when no `.ai/memory.md` exists. |
| `Ai-Memory-Check` (menu: `Ai-Context-Check`) | post-task (Stop) | If the project's `.ai` context is stale, asks the AI to update whichever existing `.ai/*.md` files are relevant — or finish if nothing durable was learned. |
| `Graph-Read-Check` | pre-task (SessionStart) | If `graphify-out/graph.json` exists, reminds the AI to prefer scoped `graphify query`/`path`/`explain` over broad file browsing **only when the task actually needs codebase understanding** — silent when no graph exists, so non-codebase-projects pay zero tokens. |
| `Graph-Update-Check` | post-task (Stop) | If `graphify-out/graph.json` is stale, asks the AI to decide whether `graphify update .` is warranted. |
| `Cloudflare-Deploy` | post-task (Stop) | In Workers projects (wrangler config present), asks the AI to deploy when the result should go live. |
| `Skills-Check` | pre-task (SessionStart) | Compact Skill Policy reminder listing the copied skills, the `.ai/SKILLS.md` record, and the library. |
| `Mcp-Usage-Check` | pre-task (SessionStart) | Compact reminder to consider MCP servers/tools (docs lookup, browser, DB) when they materially help. |
| `Large-File-Check` | pre-task + post-task (Stop) | Pre-task: reminds to prefer small, multi-part files (split by responsibility, ~500-800 lines = split signal). Post-task: scans for oversized source files and asks the AI whether a split is safe and worthwhile. |
| `Dependabot-Check` | pre-task (SessionStart) | In a GitHub repo, reports pending pull requests from the verified `app/dependabot` author (with exact head SHA, classification, merge/check state) so they are reviewed before unrelated work. Detection only — never merges. |
| `Ci-Status-Check` | post-task (Stop) | After a push, blocks "done" until checks for the **exact** pushed commit reach an acceptable terminal state. Pending/failed authorization remains blocking even while repeated detail is cooled down; GitHub queries are throttled, exact-SHA, and bound to the SAME resolved remote used for both repository selection and pushed-state verification (never a mismatched `@{upstream}`). Missing access is never reported as verified. When CI is blocked only by a confirmed **external** condition (GitHub outage, no hosted runner, an org/repo permission failure, an externally-controlled secret being unavailable, a manual approval/environment gate, ...), the agent can record an explicit, evidenced, local-only exception bound to the exact repository + pushed SHA: `-ReportExternalBlocker -Classification <category> -Reason "<evidence>"`. **Eligibility is conservative:** an exception may only be recorded when the observed GitHub run state is non-code-failure identifiable without reading logs — still pending / a manual gate, or a completed run whose conclusion is `cancelled`/`timed_out`/`stale`/`action_required`. A completed `failure`/`startup_failure` is **never** eligible (the hook cannot tell a real code/test/build/lint failure from an external one without trusted evidence), regardless of classification (including `other-external`); the classifications describe *why*, but cannot excuse a generic `failure`. Recording **always queries the exact-SHA CI state first** — refused if already green, refused on a genuine completed failure, refused if CI can't be queried — and captures a non-secret CI fingerprint (`databaseId`/`attempt`/`workflowName`/`status`/`conclusion`/`updatedAt`, so a rerun is distinguishable). It never marks the commit verified/green; **while active, Stop emits a non-blocking "CI NOT VERIFIED GREEN" notice** so the final task context cannot misrepresent CI as successful. The notice shape is client-aware: **Claude Code** receives `hookSpecificOutput.additionalContext` (the officially documented model-visible field for Stop), while **Codex** receives `systemMessage` (its only documented common Stop output field — surfaced to the user/event stream; Codex does not document model-visible Stop context, so this is the strongest verified non-blocking option there). Neither shape ever uses `decision: "block"`. The client is detected the same way as the rest of this project (`CLAUDE_PROJECT_DIR` present → Claude, absent → Codex). Every later Stop re-verifies on a throttle (`EXTERNAL_BLOCKER_RECHECK_MINUTES`, default 15): the same fingerprint keeps completion allowed, CI turning green retires the exception and verifies normally (no external wording), and CI changing to a different state invalidates it and blocks again. Expires after `EXTERNAL_BLOCKER_TTL_MINUTES` (default 1440); a new commit or different repository invalidates it immediately. This is not a log-analysis subsystem. |
| `Github-Baseline-Check` | pre-task (SessionStart) | Checks that workflows contain blocking project validation (not empty/deploy-only YAML) — recognizing block-style, flow-style (`on: [push, pull_request]`), bare-value, and block-sequence triggers scoped to the **direct children** of the top-level `on:` block (an unrelated nested `push:` step input, e.g. `docker/build-push-action`, or a trigger word nested deeper as an option such as a `push` key under `workflow_dispatch: inputs:`, is never mistaken for a trigger), and multiline `run: \|` validation blocks (skipping full-line shell comments, so a keyword appearing only in a comment like `# TODO: run npm test` is not counted). A `workflow_call` reusable workflow counts as CI only when a directly-triggered local workflow actually `uses:` it (an uncalled reusable workflow is reported as a gap, not assumed complete). Flags broad `continue-on-error` and unsafe PR-target execution, detects common ecosystems in pruned deep monorepos (a bare `pyproject.toml` defaults to the `pip` Dependabot ecosystem, which also covers Poetry; reclassified as `uv` only when `uv.lock` is present), and validates `dependabot.yml` directory/directories coverage. Deliberately does not evaluate `if:` step conditions, check least-privilege `permissions:`, or confirm a reusable workflow called only from another repository — a lightweight, deterministic heuristic, not a full YAML/static analyzer. |
| `Rules-Check` | pre-task (SessionStart, UserPromptSubmit) | Verifies the configured rules were read before the task starts: the **global** rules directory (`~\.claude\rules` / `~\.codex\rules`) plus the current project's **local** rules directory (`<project>\.claude\rules` / `<project>\.codex\rules`). First check lists all rules files; afterwards it stays silent until a rules file is added/changed/removed, then reports exactly what moved. Detects the running client automatically (Claude Code exports `CLAUDE_PROJECT_DIR` on hook processes; Codex does not). |
| `Secrets-Check` | pre-task + post-task (Stop) | Safely scans real `.env*` files throughout active project subtrees (templates, dependencies, builds, caches, assistant runtimes, and reparse points are pruned). Lifecycle events retain registry/placeholder/unused advisories. The leak scan merges and deduplicates git **working-tree and index** matches (`git grep` + `git grep --cached`), so a value staged then cleaned from the working copy only — or committed and later edited away locally without staging that edit — is still caught. During native pre-push it **additionally scans the exact commits about to be pushed**, resolved from git's real pre-push ref-update stdin (`<local ref> <local sha> <remote ref> <remote sha>`): a secret sitting in an outgoing commit is caught even when the working tree and index are already clean. The outgoing-history scan does **not** exclude `.env*`/`secrets.md` — a committed real `.env` or registry file in outgoing history is itself a leak, even if it was later deleted/untracked before the push. New branches (all-zero remote sha), deletions (all-zero local sha), force-pushes/non-fast-forwards, and multiple refs in one push are all handled. It **fails closed**: the whole range is scanned in bounded batches (no commit cap), and if any ref range cannot be resolved (unresolvable remote sha, `rev-list`/`git grep` error) the push is **blocked** with a safe incomplete-scan message rather than treated as clean. Native pre-push blocks only confirmed indexing/leak/outgoing/incomplete-scan risks; advisory-only findings exit successfully. Secret values are never printed. **Limitation:** `Secrets-Check` is a registry/value-based leak guard, not a full entropy/pattern/history secret scanner — it can only match values it currently knows (from active `.env*` files or the local `secrets.md`). A secret introduced and later removed from outgoing history **and** every current source is no longer known to it and cannot be matched; use an established dedicated historical-secret scanner in CI for unknown credentials. |
| `Ignore-Rules-Check` | pre-task (SessionStart) + post-task (Stop) + native Git pre-push | Auto-adds required local/private patterns to `.gitignore`, extracts additional paths from explicit local-only/never-commit project rules, and blocks completion while required fixes remain. Default public template files (`.env.example`/`.env.sample`/`.env.template`/`.env.dist`) are intentionally allowed to stay tracked via `!`-negation exceptions — they are never reported as a protected path that must be untracked, while real env files (`.env`, `.env.local`, `.env.production`, ...) remain protected. Patterns are written and compared in **insertion order**, never alphabetically sorted (an alphabetical sort would silently break every negation exception, since `!` sorts before `/`), and a path whose effective `git check-ignore` match is a negation is always treated as explicitly allowed. Project installs create a deterministic pre-push chain: Ignore → Secrets → preserved previous hook. Large-File-Check remains advisory and never decides whether a push may proceed. Optional extra patterns can be set in `.env`. |
| `Dependency-Version-Check` | pre-task (SessionStart, UserPromptSubmit) | **Advisory only** — never modifies manifests/lockfiles/workflows/Dockerfiles, never runs an upgrade, never auto-merges Dependabot PRs, never blocks completion. SessionStart reports version-freshness findings for ecosystems actually detected in the project: real `npm outdated --json` (exits 1 when outdated packages exist — treated as success, not a failure) and `pip list --outdated --format=json` classify each update as patch/minor/major/prerelease; GitHub Actions get a static known-minimum-major check on `uses:` refs; runtime pins (`.nvmrc`/`.node-version`/`.python-version`/`engines.node`) and Docker base images (`FROM` tags) are checked against a small known-EOL list, and a floating/untagged image is flagged as non-reproducible. Ecosystems without a verified, reliable JSON command here (pnpm, Yarn, Bun, Poetry, uv, .NET, Java/Gradle/Maven, Rust/Cargo, PHP Composer, Ruby Bundler) are detected and reported as an **incomplete** check with the exact command to run manually, rather than guessing at an unconfirmed schema or a fragile text-table parse — it never claims a dependency is current when a check could not run. `UserPromptSubmit` reuses the cached findings and additionally injects "prefer the latest stable compatible version, not a prerelease" guidance when the prompt looks like it's adding a dependency/framework/runtime/build tool/action/Docker image or starting a project from scratch. Cached per-project by a fingerprint of detected ecosystems + manifest/lockfile/workflow/Dockerfile/runtime-pin **content** hashes (not just presence), so an unrelated task stays fast while any real change triggers a fresh scan; default cooldown is 7 days. Complements `Dependabot-Check` (existing PRs) and `Github-Baseline-Check` (CI/Dependabot baseline structure) without duplicating either. |

All advisory hooks are token-efficient by design: they stay **silent** unless a deterministic
signal fires (staleness, wrangler config, out-of-sync git, pending Dependabot PR, unverified
push), they respect a per-project **cooldown/fingerprint**, they never loop (`stop_hook_active`
guard), and the decision always stays with the AI — every reminder explicitly allows finishing
without action. The GitHub hooks degrade safely (silent, never a false "all clear") when git,
a remote, `gh`, authentication, or network access is missing.

Matching lifecycle hooks for the same event run concurrently and are intentionally independent;
their registration order is display-only. The native pre-push chain is the only ordered sequence.
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

Main menu: `1` **Create or install a hook** (opens a sub-menu: create a new hook, install an
existing one, or install from config), `2` show configured profiles, `3` validate. `0` goes back,
`exit` quits.

Under **Install an existing hook**, list item `1` is **Select all hooks** — an aggregate action
(not a hook itself) that runs the **complete former full-list flow**: the sync-group wizard AND
every individual hook below, in one pass, using each hook's recommended events with a shared
client/projects answer. You do **not** need to also type `2` — `1` alone always includes the sync
group. The individual-hook set is derived dynamically from the hooks actually shipped (never a
hard-coded count), so adding or removing a hook folder changes it automatically, and the sync
group always runs exactly once even if `2` is also listed explicitly (e.g. `1,2`). List item `2` is
the **sync group** on its own. Individual hooks start at `3`, each showing a colored
`[pre-task]`/`[post-task]` tag and a one-line description, with `Cloudflare-Deploy` fixed as the
**last** individual entry. You can also **install a subset** with lists and ranges (e.g. `3-8,18`)
— use each hook's recommended events with shared client/projects or configure each separately,
then a summary lists exactly what will be installed. Combining `1` with an explicit pick (e.g.
`1,5`) never installs anything twice. If the sync-group stage is canceled, the individual hooks are
not installed and nothing is falsely reported as completed.

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
