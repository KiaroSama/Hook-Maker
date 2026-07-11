# Cross-Project Sync Hooks

Keep the `.ai` knowledge directories of related projects in sync through Claude Code and
Codex CLI lifecycle hooks. When a source project's knowledge changes, the hook stages the
changed files inside the destination project and asks the agent to review and import what is
durable — before it starts the user's task.

## Components

| File | Purpose |
| --- | --- |
| `CrossProjectSyncHook.ps1` | Hook engine: change detection (quick fingerprint + SHA-256), staging, review message, acknowledgement. |
| `Setup-SyncGroup.ps1` | Interactive wizard: builds a full-mesh sync group from a list of project paths, then installs the hook. |
| `run.ps1` | Launcher for the wizard (prefers PowerShell 7, falls back to Windows PowerShell). |
| `Install-Hook.ps1` | Writes the hook command into `~/.claude/settings.json` and `~/.codex/hooks.json`. |
| `Validate-Config.ps1` | Validates `sync-hooks.json`. |
| `sync-hooks.json` | All profiles and routes. No project paths are hard-coded in the scripts. |
| `examples/` | Profile templates. |

## Quick start

```powershell
.\run.ps1
```

Choose option `1`, enter each project root path (finish with `done`), review the summary and
confirm (Enter = yes). The wizard:

1. Creates missing `.ai` directories.
2. Writes a full-mesh profile — every project becomes a sync destination of every other.
3. Validates the configuration.
4. Installs the hook for both Claude Code and Codex.

Re-running the wizard with the same paths updates the same profile (its id is a hash of the
sorted project roots), so existing sync state is preserved.

## How syncing works

- On `SessionStart` and `UserPromptSubmit` the hook checks, for the project you are working
  in, whether any source project's knowledge changed since the last acknowledgement.
- Unchanged sources cost one quick fingerprint and exit silently; SHA-256 only runs when the
  quick fingerprint moves; a pending review is shown at most once per session.
- Real changes are staged under `<project>/.ai/.cross-project-sync/` with a manifest, and the
  agent receives review instructions plus an acknowledgement command to run afterwards.
- An empty, never-synced source is recorded silently as a baseline (no empty review packages).

## Notes

- Codex requires trusting new hooks: run `/hooks` inside Codex after installing.
- Restart clients after installing — hooks load at session start.
- Each wizard execution writes a log to `logs/` (`Setup-SyncGroup_YYYY-MM-DD_HH-mm-ss_UTC.log`).
- `Setup-SyncGroup.ps1 -NoInstall` updates only the configuration without touching client settings.
- Persian guide: `README-FA.txt`.
