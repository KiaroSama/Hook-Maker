# Hook Maker

Build, install, and manage Claude Code / Codex CLI hooks — including a ready-made
cross-project knowledge sync: it keeps the `.ai` knowledge directories of related projects
in sync. When a source project's knowledge changes, the hook stages the changed files inside
the destination project and asks the agent to review and import what is durable — before it
starts the user's task.

## Layout

| Path | Purpose |
| --- | --- |
| `run.ps1` | The launcher — the only script in the root. Host priority: Windows Terminal, then PowerShell 7, then Windows PowerShell. |
| `sync-hooks.json` | All profiles and routes. No project paths are hard-coded in the scripts. |
| `hooks/` | All hooks live here: the sync engine (`CrossProjectSyncHook.ps1`) plus any custom hooks you add. |
| `scripts/Setup-SyncGroup.ps1` | Interactive wizard: sync groups, custom hook installs, profile listing, validation. |
| `scripts/Install-Hook.ps1` | Writes a hook command into a project's `.claude/settings.local.json` + `.codex/hooks.json` (or, with no `-TargetProject`, the global `~/.claude` + `~/.codex`). Supports `-CustomHook <path>`. |
| `scripts/Validate-Config.ps1` | Validates `sync-hooks.json`. |
| `scripts/Test-Engine.ps1` | Self-contained engine smoke test (18 assertions, runs under pwsh and PowerShell 5.1). |
| `examples/` | Profile templates. |
| `logs/` | Wizard execution logs (created on demand, not committed). |

## Quick start

```powershell
.\run.ps1
```

Double-clicking `run.ps1` opens the wizard in a Windows Terminal window when `wt.exe` is
available; otherwise it runs in the current console with the best available PowerShell.

Menu options: `1` sync group, `2` create or install a custom hook, `3` show profiles,
`4` validate. `0` goes back, `exit` quits.

For a sync group choose option `1`, enter each project root path (finish with `done`), review
the summary and confirm (Enter = yes). The wizard:

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

Both entries point at the same engine (`hooks/CrossProjectSyncHook.ps1`) and the same routing
file (`sync-hooks.json`, passed via `-ConfigPath`). So *which projects sync* is decided entirely
by `sync-hooks.json`; the per-project settings file only decides *where the hook is registered*.
If a settings file already has other content, it is preserved: the installer merges the hook in
(deduplicated by exact command) and writes a timestamped backup first.

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

The easiest path is launcher menu option `2` -> **Create a new hook**: name it, pick a
template, answer one or two questions, and a working `.ps1` lands in `hooks/` (optionally
installed right away). Templates:

1. **Context note** — injects a fixed note (your text) into every session/prompt.
2. **Prompt guard** — blocks prompts containing your forbidden words.
3. **Tool logger** — appends every tool call to a log file next to the hook.
4. **Empty skeleton** — a commented template for your own logic.

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

Drop the file into `hooks/` and use launcher menu option `2` — it lists every `.ps1` there,
asks for the events (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
or a custom list) and the target projects, then installs it into each project's settings.
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
