# 1. A failed run is superseded by project, not by tree state

Date: 2026-09-20

## Status

Accepted

## Context

`Test-Completion-Check` blocks completion while it can see a failed guarded run. The escape is
supersession: a later clean run of the same work means the failure has been dealt with.

Until now a supersede required the later clean receipt to carry **the same `projectFingerprint`** as
the failure. That fingerprint is a hash of `HEAD` plus `git status --porcelain`, so it identifies one
exact state of the working tree and changes on every commit and every edit.

That made the rule unsatisfiable for its own primary case. The normal sequence is:

1. a run fails
2. you find the cause and fix it — which changes the tree
3. you re-run, and it is green

At step 3 the fingerprint no longer matches the one recorded at step 1, so the green run cannot
supersede the failure it just fixed. The gate then cites that failure until the 24-hour prune
horizon passes. Observed here on 2026-09-19: four consecutive green runs of a repaired suite failed
to clear a block, while the project fingerprint moved `f75bfa688e` → `c9ec36359e` → `9957100e58`
across three commits in one afternoon.

A second, narrower hole made it worse: a receipt written without a fingerprint at all was rejected
before any scan, so it could never be superseded by anything.

## Decision

A failed run is superseded by a later clean run with the **same command fingerprint** and the **same
project key**, and no requirement on the project fingerprint.

The project key is the right pairing identity because it is what a project *is*, across all of its
states. The project fingerprint remains on the receipt — it is genuine evidence about which tree a
run measured, and other readers use it — but it is not a condition of supersession.

## Consequences

**What improves.** Fixing a failure and re-running green clears the block, which is what a user
expects and could not previously achieve. A receipt written without a fingerprint is no longer
permanently unclearable.

**What we give up.** The gate no longer distinguishes "re-run green on the same tree" from "re-run
green after changes". A green run on a *later* tree now clears a failure from an earlier one. We
accept this: the alternative is a gate that cannot be cleared by fixing the problem, and a gate
nobody can clear is worked around rather than obeyed — which costs more safety than it buys.

**What stays strict.** The command fingerprint match is unchanged, and it is computed over the whole
argument vector. A run covering three suites therefore does not supersede a one-suite failure. That
is deliberate — different arguments are different work — but it surprises people in practice, so it
is stated in the hook's own documentation rather than left to be discovered.
