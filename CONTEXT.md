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

## Generation

One unit of the user's work, from the request that starts it to the summary that hands it back. A
hook that sends the assistant back for a correction does **not** start a new one: the correction
belongs to the generation it corrects, which is what stops a gate from refilling a task's correction
allowance by blocking it. A resumed task after an interruption is the same generation too. Only
genuine new work from the user begins another.

Deliberately not "session" and not "turn": a session holds many generations, and one generation
spans many turns.

## Terminal

A generation is terminal when the finalization path has **recorded** that it ended — either its
summary was published, or it ended without that and the outcome says so. Terminality is written, never
inferred: an old timestamp, a quiet store or a vanished process is not evidence that work finished.
A generation that is merely stale is still live.

## Finalized

The state recorded when a summary publication has an explicit ready record and no recorded
unresolved verdict. Observing summary text alone does not establish this state. An unverified
publication is a different fact from verified finalization, and neither is a claim that the store
controls what the client displays.

## Collection

Compacting eligible verified terminal generations into retained tombstones so new work can be recorded. It never removes a live
generation, an unresolved finding or an unpublished receipt, whatever their age, and **age alone
never makes anything collectable**. When the store is full and nothing is terminal, the refusal is
explicit — evicting the oldest entry would discard an active correction chain and refund its
allowance, which is the failure this rule exists to prevent.

## Tombstone

What a collected generation leaves behind: enough to recognise a late event from it and reject it as
retired, and nothing more. Without one, a delayed receipt arriving after collection reads as a brand
new generation.
