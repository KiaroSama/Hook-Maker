<div align="center">

# Hook Maker

**Build, install, and manage Claude Code and Codex CLI hooks on Windows.**

[![GitHub Actions CI workflow on main](https://img.shields.io/badge/CI-GitHub%20Actions-16a34a)](.github/workflows/ci.yml)
[![Proprietary software license](https://img.shields.io/badge/license-Proprietary-2563eb)](LICENSE)
[![PowerShell 7.6.10 and Windows PowerShell 5.1.26100.10068 measured locally](https://img.shields.io/badge/PowerShell-7.6.10%20%7C%205.1.26100.10068-8b5cf6)](.github/workflows/ci.yml)
[![Runs on Windows](https://img.shields.io/badge/platform-Windows-0891b2)](.github/workflows/ci.yml)
[![Launch the setup wizard with run.ps1](https://img.shields.io/badge/install-PowerShell%20wizard-4f46e5)](run.ps1)
[![Hook reference with events and configuration](https://img.shields.io/badge/docs-Hook%20reference-0284c7)](docs/HOOKS.md)
[![Measured size of tracked repository files in decimal megabytes](https://img.shields.io/badge/repo%20size-7.8%20MB-ca8a04)](README.md)
[![Registers hooks for Claude Code and Codex CLI](https://img.shields.io/badge/clients-Claude%20Code%20%7C%20Codex%20CLI-b45309)](docs/HOOKS.md)
[![Shipped hook count includes 30 packages and the sync engine](https://img.shields.io/badge/hooks-31%20shipped-15803d)](docs/HOOKS.md)
[![Cross-project knowledge sync includes a configurable manifest](https://img.shields.io/badge/sync-Knowledge%20sync-0d9488)](sync-hooks.example.json)
[![Read the registry and sync transaction contracts](https://img.shields.io/badge/registry-Transactional%20updates-334155)](docs/STORAGE-TRANSACTIONS.md)
[![Support donations](https://img.shields.io/badge/Support-donations-d04a9a)](#donate)

</div>

[راهنمای فارسی](README-FA.md) · [Hook reference](docs/HOOKS.md) · [Operator guide](docs/OPERATIONS.md)

## What Hook Maker does

31 hooks ship with Hook Maker: 30 custom hook packages and a cross-project knowledge sync engine. The wizard installs selected hooks into project folders and registers them for one or both clients. The sync engine stages changed knowledge for review in related projects; the destination agent decides what to import.

## Quick start

You need Windows, PowerShell 7 (recommended) or Windows PowerShell 5.1, and the client you plan to use. Have Git available for Git-aware hooks. Some hooks need additional tools; check the [hook reference](docs/HOOKS.md) before installing those.

Open PowerShell in your Hook Maker checkout and run:

```powershell
.\run.ps1
```

1. Choose `1` (**Create or install a hook**), then `1` (**Install an existing hook**).
2. Choose an individual hook, `2` for a sync group, or `1` to install the sync group and all shipped custom hooks. To install a subset, use a list or range such as `3-8,20`.
3. Select Claude Code, Codex CLI, or both. Enter the target project paths, review the events and destinations, then confirm.
4. Restart the client. In Codex, use `/hooks` to review and trust the newly registered command before trying it.

An individual hook offers its recommended events first. Once installed, the target holds its own runtime copy; changes in the Hook Maker checkout do not update it automatically.

## Configure hooks and sync

Each shipped hook includes an `.env.example` with its settings. Copy it to `.env` in the hook folder and supply `TARGET_PROJECTS` (semicolon-separated paths), `EVENTS`, and `CLIENTS` (`Both`, `Claude`, or `Codex`). In the wizard, choose `1` then `3` to install from config without prompts. Keep populated local configuration out of Git.

For knowledge sync, choose a sync group with at least two project roots. The wizard creates or updates its `sync-hooks.json` routes so every member can send changes to the others. The staged files are proposals, not automatic edits to the destination's knowledge. See the [sample config](sync-hooks.example.json) and [sync instructions](docs/OPERATIONS.md#sync-config).

## Manage installed hooks

| Menu entry | Use |
| --- | --- |
| `33` Update | Refresh installed runtimes and report what changed. |
| `34` Status | Inspect registrations and installed files without executing the hooks. |
| `35` Uninstall | Remove selected registrations and files Hook Maker owns. |
| `36` Reset groups | Preview the list and confirm removal of all sync groups. Installed hooks stay in place. |
| `37` Fix moved project | Reconnect a project after a rename or move. |

Or preview fleet updates from the checkout:

```powershell
pwsh -NoProfile -File .\scripts\Update-Fleet.ps1 -WhatIf
```

The preview lists current, stale, pending-migration, unreachable and skipped registrations. Review it before applying changes. See the [operator guide](docs/OPERATIONS.md) for update, removal, runtime location, logging, and custom hook examples.

## Troubleshooting and reference

- [Hook reference](docs/HOOKS.md): events, configuration and how each hook reports findings.
- [Test and update recovery](docs/TEST-HOOK-RECOVERY.md): blocked or interrupted operations. A historical recovery record does not validate a new run.
- [CI input evidence](docs/ci-input-evidence.md): read-only inspection of which documents a workflow might consume.
- [Storage transactions](docs/STORAGE-TRANSACTIONS.md) and [task continuation](docs/TASK-CONTINUATION-CONTRACT.md): what Hook Maker preserves across failures and restarts.

Management logs are UTF-8 and live under `logs/`, with UTC filenames. Review them locally and redact project paths and account identifiers before sharing excerpts. The operator guide lists retention and logging options.

## License

Proprietary software. See [LICENSE](LICENSE).

## Donate

| Currency | Network | Address |
| --- | --- | --- |
| Bitcoin (BTC) | Bitcoin | `bc1qmth5m03pu5hujw5xw5jmywam3jj3sqwqupesdt` |
| USDT, BNB, USDC, etc. | BEP20 | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
| USDT, TRX, USDC, etc. | TRC20 | `TWBA3xFTqgZAeAYMxqo85xWnzvty3DcAhw` |
| Ethereum (ETH) | ERC20 | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
| TON | TON | `UQCN8Umo_OfOWqImZetQsrNStPcmLkMAKajFyiCOhso23NDb` |
| Litecoin (LTC) | LTC | `ltc1qntqnnrunadurnw4cshv3qgspywrueyyeyngwuy` |
| Solana (SOL) | Solana | `7B2wkczUjmkDhETwQuknBL8sUsbuV7nErxc317TmQuwR` |
| Polygon (POL) | Polygon | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
