# Read-only CI input evidence

`Get-CiInputEvidence.ps1` inventories immutable local Git evidence before attempting
semantic CI-input analysis. It is a diagnostic tool, **not an input certificate**.
Every report has `verdict: UNKNOWN` and `gateWaived: false`. No hook consumes the
report, and a successful command does not establish docs-only carryover or CI green.

## Run

Use an existing repository's top-level directory, an exact lowercase 40-hex commit
and public tracked `.md`/`.txt` document paths. The output parent must already exist;
output and diagnostics must be outside the inspected repository. Existing output is
never overwritten. Separate output names permit repeated comparisons.

```powershell
& ./scripts/Get-CiInputEvidence.ps1 `
  -ProjectRoot 'D:/Projects/Example' `
  -Commit '<exact-40-hex-commit>' `
  -Document @('docs/guide.md', 'docs/format.md') `
  -ResultPath 'D:/Evidence/example-inputs.json' `
  -LogDirectory 'D:/Evidence/logs'
```

The example commit is a placeholder, not executable input. Git must support
`--no-lazy-fetch`; unsupported Git fails without a report.
Git replacement objects are disabled. Missing local objects are not fetched.
Neither target commands nor downloaded dependencies are executed. The tool does
not install packages, change Git trust/permissions, or alter target files/state.

## What the report means

- Exact commit/tree and each candidate blob identity, file mode, byte size and category.
- Line-number operation categories: workflow run/action declarations, reads,
  path discovery, embedded inputs, dependencies and external execution. Source and
  command text are deliberately omitted.
- Discovery coverage, explicit unsupported/partial areas and unresolved effects.
  Regex matches are navigation evidence; absence of matches is not a safety proof.
- Protected inputs are excluded before content searches. Their count makes coverage
  partial. Symlinks/submodules are unsupported, never silently resolved.

Exit `0` means diagnostic discovery completed, **not semantic independence**.
Exit `2` means partial discovery, including budget exhaustion. Exit `1` means invalid
input or operational failure, with no partial output publication. Reports are local
review artifacts; do not publish raw reports from private repositories.

## Independent budgets

Defaults: 120 seconds discovery, five seconds per Git query, 16 MiB captured output
per query, 8 MiB aggregate inspected content, 200 inspected candidates, one grep
worker and 100,000 tree entries. CLI limits: `-TimeoutSeconds` 1–600,
`-MaxCandidates` 1–5000 and `-MaxContentBytes` 1024–67108864. A report retains at most
5000 candidate details and 1000 operation locations per inspected file; omissions
remain explicit. Sorting/publication can add a short bounded-size processing tail;
query termination allows two seconds cleanup. These are independent preanalysis
limits; the existing hook's 40-second/100-candidate/1-MiB limits are unchanged.

## Diagnostics

A new UTF-8 `Get-CiInputEvidence_YYYY-MM-DD_HH-mm-ss_UTC.log` is allocated per run,
with a collision suffix when necessary. Default directory is Hook Maker's `logs`,
resolved relative to the tool, not caller CWD. Use `-LogDirectory` when inspecting
Hook Maker itself. Entries use `[timestamp UTC] [INFO] [AUDIT]` and sanitized
execution/start/completion/failure metadata; raw source, commands, environment and
credential values are omitted. Logging failure uses a console warning rather than
claiming a log exists. Logs close after each append; retention is manual. Inspect
and redact diagnostic logs before attaching them for support.

## Known limits

The tool does not parse complete YAML, resolve every imported module or establish
transitive Rust/JavaScript/native build effects. Dependency checksums establish
identity, not non-consumption. A complete discovery report can still contain
unproved executable boundaries. A verified ancestor's postconditions may eventually
provide one part of a checked proof, but this tool neither generates nor accepts
such a proof. Full historical carryover acceptance remains separate.
