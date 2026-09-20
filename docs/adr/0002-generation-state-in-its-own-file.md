# 2. Generation state lives in its own file, not in the task record

Date: 2026-09-20

## Status

Accepted

## Context

The finalization and retention work needs to store, per generation, a state (`working`,
`validating`, `ready`, `finalized`, plus an unverified outcome), the evidence that state rests on,
the verdict each required gate reported, and a publication record.

The obvious home for it is the existing task record — `hooks/_taskidentity.ps1` already keys by
project, client, session and actor, already takes a lock, already writes atomically, and already
holds the correction allowance that the finalization rules talk about. Putting the new fields there
would mean one file, one lock, one schema.

Two facts make that the expensive option:

- **The record is validated strictly, and the validation is a gate.** A document that fails it reads
  as `corrupt`, and a corrupt record is not repaired silently — it costs the session its recorded
  continuation state. The validator rejects unknown shapes rather than ignoring them.
- **That record is installed in 29 projects.** Every one of them runs whatever version of the
  library its last install carried. A field added on one side of that fleet, read by a runtime that
  predates it, is not a local mistake: it is every project's task record reading as corrupt at once,
  and the fleet is refreshed by a roll-out that takes real time to complete.

The failure mode is therefore not "a bug in one project" but "one schema edit, 29 projects broken
simultaneously, recovered only by a full re-install".

## Decision

Generation state lives in **its own state file**, written beside the task record and keyed the same
way. The task record's schema does not change.

Nothing reads generation state to decide whether a task record is valid, and nothing reads the task
record to decide whether generation state is valid. A runtime that has one file and not the other
degrades to what it can see rather than failing.

## Consequences

**What this costs.** Two files, two locks, and no single atomic write spanning both. Anything that
must be consistent across the two has to tolerate seeing one updated before the other, so the design
may not put a fact in one file that only makes sense given a simultaneous fact in the other.

**What it buys.** An old runtime meeting the new file ignores a file it does not know about; a new
runtime meeting no file starts one. Neither reads the other's document as corrupt. The blast radius
of a schema mistake is the new feature, not the fleet's continuation state — and rolling the feature
back is deleting a file rather than migrating 29 projects' records.

**Rejected: version the task record.** Add a `version` field and have the reader upgrade a record
that lacks one. Tidier, and it keeps one file. Rejected because the upgrade path itself runs in all
29 projects, so a mistake in it has exactly the blast radius this decision exists to avoid — and the
tidiness is worth less than that.

**Rejected: accept the reset.** Add the fields, let old records read as corrupt, let them be
discarded. Simplest code by a wide margin. Rejected because the discarded content is the block
history and the correction allowance: wiping those refunds every outstanding obligation across the
fleet, which is the same defect as evicting an active chain to make room.
