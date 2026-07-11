# Cross-Project Sync Hooks

Keep the `.ai` knowledge directories of related projects in sync through Claude Code and
Codex CLI lifecycle hooks. When a source project's knowledge changes, the hook stages the
changed files inside the destination project and asks the agent to review and import what is
durable — before it starts the user's task.

## Layout

| Path | Purpose |
| --- | --- |
| `run.ps1` | The launcher — the only script in the root. Starts the wizard (prefers PowerShell 7). |
| `sync-hooks.json` | All profiles and routes. No project paths are hard-coded in the scripts. |
| `scripts/Setup-SyncGroup.ps1` | Interactive wizard: builds a full-mesh sync group from a list of project paths, then installs the hook. |
| `scripts/CrossProjectSyncHook.ps1` | Hook engine: change detection (quick fingerprint + SHA-256), staging, review message, acknowledgement. |
| `scripts/Install-Hook.ps1` | Writes the hook command into a project's `.claude/settings.local.json` + `.codex/hooks.json` (or, with no `-TargetProject`, the global `~/.claude` + `~/.codex`). |
| `scripts/Validate-Config.ps1` | Validates `sync-hooks.json`. |
| `scripts/Test-Engine.ps1` | Self-contained engine smoke test (18 assertions, runs under pwsh and PowerShell 5.1). |
| `examples/` | Profile templates. |
| `logs/` | Wizard execution logs (created on demand, not committed). |

## Quick start

```powershell
.\run.ps1
```

Choose option `1`, enter each project root path (finish with `done`), review the summary and
confirm (Enter = yes). The wizard:

1. Creates missing `.ai` directories.
2. Writes a full-mesh profile — every project becomes a sync destination of every other.
3. Validates the configuration.
4. Installs the hook **inside each project** (`.claude/settings.local.json` for Claude,
   `.codex/hooks.json` for Codex) — not in your global settings, so only these projects carry it.

Re-running the wizard with the same paths updates the same profile (its id is a hash of the
sorted project roots), so existing sync state is preserved.

## Where the hook lives and how it reads its config

The wizard installs the hook **per project** (local scope):

- Claude Code reads it from `<project>/.claude/settings.local.json` (auto-gitignored; the command
  holds a machine-specific absolute path, so it must not be committed).
- Codex reads it from `<project>/.codex/hooks.json` (loads only after you trust it via `/hooks`).

Both entries point at the same engine (`scripts/CrossProjectSyncHook.ps1`) and the same routing
file (`sync-hooks.json`, passed via `-ConfigPath`). So *which projects sync* is decided entirely
by `sync-hooks.json`; the per-project settings file only decides *where the hook is registered*.

Global install is still available for scripting: `scripts/Install-Hook.ps1` with no
`-TargetProject` writes to `~/.claude/settings.json` and `~/.codex/hooks.json` instead.

## How syncing works

- On `SessionStart` and `UserPromptSubmit` the hook checks, for the project you are working
  in, whether any source project's knowledge changed since the last acknowledgement.
- Unchanged sources cost one quick fingerprint and exit silently; SHA-256 only runs when the
  quick fingerprint moves; a pending review is shown at most once per session.
- Real changes are staged under `<project>/.ai/.cross-project-sync/` with a manifest, and the
  agent receives review instructions plus an acknowledgement command to run afterwards.
- An empty, never-synced source is recorded silently as a baseline (no empty review packages).

## Writing your own hooks

The `.ai` sync is just one hook. A hook is a script that reads a JSON event from **stdin** and,
optionally, prints a JSON response to **stdout**; you register it under an event in the same
settings files. Minimal example (`scripts\MyHook.ps1`):

```powershell
$e = [Console]::In.ReadToEnd() | ConvertFrom-Json
# $e.hook_event_name, $e.cwd, $e.session_id, and event fields (e.g. $e.prompt) are available.
# Say nothing:
exit 0
# ...or inject context for the model:
@{ hookSpecificOutput = @{ hookEventName = $e.hook_event_name; additionalContext = 'note' } } |
    ConvertTo-Json -Depth 5 -Compress
```

Register it in `<project>/.claude/settings.local.json` (and/or `<project>/.codex/hooks.json`)
under the event you want — `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`Stop`, etc. — using the same `{ "hooks": { "<Event>": [ { "hooks": [ { "type": "command",
"command": "..." } ] } ] } }` shape this tool writes. Give it its own config file next to
`sync-hooks.json` if it needs configuration. Run the engine test as a template for how to drive
a hook end-to-end: `pwsh -File scripts\Test-Engine.ps1`.

## Notes

- Codex requires trusting new hooks: run `/hooks` inside each project and trust the command.
- Restart clients after installing — hooks load at session start.
- Each wizard execution writes a log to `logs/` (`Setup-SyncGroup_YYYY-MM-DD_HH-mm-ss_UTC.log`).
- `scripts\Setup-SyncGroup.ps1 -NoInstall` updates only the configuration without installing hooks.
- Run the engine smoke test with `pwsh -File scripts\Test-Engine.ps1` (works under PowerShell 5.1 too).
- Persian guide: `README-FA.txt`.
