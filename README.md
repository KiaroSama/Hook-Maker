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
| `hooks/_hooklib.ps1` | Shared helpers (stdin/`.env`/hash/JSON) the shipped hooks dot-source; the `_` prefix keeps it out of the hook picker. |
| `scripts/Setup-SyncGroup.ps1` | Interactive wizard: sync groups, hook creation/installs, profile listing, validation. |
| `scripts/Install-Hook.ps1` | Writes a hook command into a project's `.claude/settings.local.json` + `.codex/hooks.json` (or, with no `-TargetProject`, the global `~/.claude` + `~/.codex`). Supports `-CustomHook <path>`. |
| `scripts/Validate-Config.ps1` | Validates `sync-hooks.json`. |
| `scripts/Test-Engine.ps1` | Self-contained engine smoke test (18 assertions, runs under pwsh and PowerShell 5.1). |
| `scripts/Test-GitHubHooks.ps1` | Offline test suite for the GitHub hooks (47 assertions; mocks git state and `gh`, no network/account). |
| `scripts/Test-RulesCheck.ps1` | Offline test suite for the Rules-Check hook and per-client install targeting (33 assertions). |
| `scripts/Test-Wizard.ps1` | Drives the interactive wizard end-to-end via stdin (menu, hook listing, comma multi-select, client targeting, real self-contained installs) against temp projects (52 assertions). |
| `logs/` | Wizard execution logs (created on demand, not committed). |

## Shipped hooks

| Hook | Runs | What it does |
| --- | --- | --- |
| `Cross-Project-.ai-Knowledge-Sync` | pre-task (SessionStart, UserPromptSubmit) | The sync engine: stages changed `.ai` knowledge from related projects for review. |
| `Git-Sync-Check` | pre-task + post-task (Stop) | Reports uncommitted/unpushed/unpulled work; on Stop asks the AI to decide whether to sync now. |
| `Ai-Memory-Check` | post-task (Stop) | If `.ai/memory.md` is older than the latest work, asks the AI to update the memory per the policy — or finish if nothing durable was learned. |
| `Graph-Update-Check` | post-task (Stop) | If `graphify-out/graph.json` is stale, asks the AI to decide whether `graphify update .` is warranted. |
| `Cloudflare-Deploy` | post-task (Stop) | In Workers projects (wrangler config present), asks the AI to deploy when the result should go live. |
| `Skills-Check` | pre-task (SessionStart) | Compact Skill Policy reminder listing the copied skills, the `.ai/SKILLS.md` record, and the library. |
| `Mcp-Usage-Check` | pre-task (SessionStart) | Compact reminder to consider MCP servers/tools (docs lookup, browser, DB) when they materially help. |
| `Large-File-Check` | pre-task + post-task (Stop) | Pre-task: reminds to prefer small, multi-part files (split by responsibility, ~500-800 lines = split signal). Post-task: scans for oversized source files and asks the AI whether a split is safe and worthwhile. |
| `Dependabot-Check` | pre-task (SessionStart) | In a GitHub repo, reports pending pull requests from the verified `app/dependabot` author (with exact head SHA, classification, merge/check state) so they are reviewed before unrelated work. Detection only — never merges. |
| `Ci-Status-Check` | post-task (Stop) | After a push, blocks "done" until the GitHub checks for the **exact** pushed commit are verified; distinguishes pending / failed / infra-flaky and points at the failed job. |
| `Github-Baseline-Check` | pre-task (SessionStart) | Checks the `.github` automation baseline against the project's real structure (CI workflow, `dependabot.yml` coverage per ecosystem/dir, optional CodeQL) and reports concrete gaps. |
| `Rules-Check` | pre-task (SessionStart, UserPromptSubmit) | Verifies the configured rules were read before the task starts: the **global** rules directory (`~\.claude\rules` / `~\.codex\rules`) plus the current project's **local** rules directory (`<project>\.claude\rules` / `<project>\.codex\rules`). First check lists all rules files; afterwards it stays silent until a rules file is added/changed/removed, then reports exactly what moved. Detects the running client automatically (Claude Code exports `CLAUDE_PROJECT_DIR` on hook processes; Codex does not). |

All advisory hooks are token-efficient by design: they stay **silent** unless a deterministic
signal fires (staleness, wrangler config, out-of-sync git, pending Dependabot PR, unverified
push), they respect a per-project **cooldown/fingerprint**, they never loop (`stop_hook_active`
guard), and the decision always stays with the AI — every reminder explicitly allows finishing
without action. The GitHub hooks degrade safely (silent, never a false "all clear") when git,
a remote, `gh`, authentication, or network access is missing.

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

Under **Install an existing hook**, each hook shows a colored `[pre-task]`/`[post-task]` tag and a
one-line description, and you can **install several at once** with a comma list (e.g. `2,4,5`) —
choose the same events/client/projects for all or configure each, then a summary lists exactly
what will be installed.

The **sync group** now lives inside `1` → **Install an existing hook** as list item `1`
("Create or update a sync group"; it can't be combined with other hooks in one comma list). Choose
it, enter each project root path (finish with `done`), pick the client, review the summary and
confirm (Enter = yes). The wizard:

1. Creates missing `.ai` directories.
2. Writes a full-mesh profile — every project becomes a sync destination of every other.
3. Validates the configuration.
4. Installs the hook **inside each project** as a self-contained runtime copy
   (`.claude/hooks/HookMaker/` + `settings.local.json` for Claude, `.codex/hooks/HookMaker/` +
   `hooks.json` for Codex) — not in your global settings, so only these projects carry it, and
   nothing depends on where the Hook Maker folder lives.

Re-running the wizard with the same paths updates the same profile (its id is a hash of the
sorted project roots), so existing sync state is preserved.

## Where the hook lives — installs are self-contained

Every install **copies the hook runtime into the target itself** (Kiro-style): the script, the
shared `_hooklib.ps1`, its `.env` (if present) and — for the sync engine — a copy of the routing
config land in

- `<project>/.claude/hooks/HookMaker/<Friendly-Name>/` for Claude (registered in
  `<project>/.claude/settings.local.json`, auto-gitignored — the command holds a machine-specific
  absolute path), and
- `<project>/.codex/hooks/HookMaker/<Friendly-Name>/` for Codex (registered in
  `<project>/.codex/hooks.json`; loads only after you trust it via `/hooks`),

where `<Friendly-Name>` is the hook's readable, hyphenated name (e.g. the sync engine lands in
`HookMaker/Cross-Project-.ai-Knowledge-Sync/`, `Mcp-Usage-Check` in `HookMaker/Mcp-Usage-Check/`),

and the registered command points at that copy. **Moving, renaming, or deleting the Hook Maker
folder never breaks an installed hook.** The flip side: copies do not auto-update — after
changing a hook, its `.env`, or a sync group, re-run the install (or the sync-group flow) and
the copies are refreshed; a re-install *replaces* the hook's old registration (even one that
pointed into the tool folder) instead of duplicating it. Other content in the settings files is
preserved, and a timestamped backup is written first.

Global install works the same way: `scripts/Install-Hook.ps1` with no `-TargetProject` copies to
`~/.claude/hooks/HookMaker/` + `~/.codex/hooks/HookMaker/` and registers in
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
