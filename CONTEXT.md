# Context

The shared language of this project. A glossary and nothing else — no implementation detail, no
decisions (those are ADRs under `docs/adr/`), no task state (that lives outside the repository).

## Test command

A command whose purpose is to **run a test suite**: `pytest`, `jest`, `vitest`, `go test`,
`npm test`, this repository's own `Run-Tests.ps1` and its `Test-<Suite>.ps1` suites.

Not to be confused with a **condition script** (below). `Test-` is an approved PowerShell verb
meaning "evaluate a condition and return the result" — `Test-Path`, `Test-Connection`. A file named
`Test-<Noun>.ps1` is therefore ambiguous on its name alone, and this project contains both kinds.

## Condition script

A PowerShell script named with the `Test-` verb that **evaluates a condition** rather than running a
suite. Every shipped hook whose name begins with `Test-` is one of these: `Test-Plan-Check`,
`Test-Run-Guard`, `Test-Completion-Check`. A condition script is never a test command, even though
its filename matches the same pattern.

## Guarded run

An execution of a test command through `Run-Tests-Guarded.ps1`, which owns the child process for its
whole life and records what happened. A test command executed any other way is an **unguarded run**
and leaves no evidence.

## Receipt

The result document a guarded run writes. It carries the run's identity — which command, which
project, when, how it ended — and is the only thing a later reader knows about that run. A receipt
missing an identity field cannot be paired with anything.

## Project key

The stable identifier for a project across all of its runs. It appears in every receipt's filename
and does not change when the project's contents change.

## Project fingerprint

The identifier of one exact **state** of a project's working tree. It changes whenever the tree
changes — a commit, an edit, a staged file. It identifies a moment, never a project.

## Incident

A FINDING that demands acknowledgement before work can be called complete - not a run, and not a
receipt. Identity comes from what the run found: the command it executed plus how that ended. So
repeated evidence of one defect is ONE incident however many receipts it leaves, while a different
command or a different failure mode is a different incident. An incident carries a key so a human
can name it when resolving it; a run with no key cannot be addressed by the documented recovery
path.

Keying it to the receipt instead was a defect: one repair once owed four separately tagged notes
because it had left four receipts. See `docs/adr/0001-supersede-by-project-not-tree-state.md` for
the sibling decision about what "the same run" means.

## Superseded

A failed run is superseded when the **same work has since been re-run clean**. "The same work" means
the same command in the same project — deliberately not the same tree state, because fixing the
failure necessarily changes the tree. See `docs/adr/0001-supersede-by-project-not-tree-state.md`.
