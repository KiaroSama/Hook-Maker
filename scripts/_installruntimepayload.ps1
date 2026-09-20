# WHAT TRAVELS WITH AN INSTALLED HOOK.
#
# An installed runtime is SELF-CONTAINED: it never loads anything from the tool
# checkout, because a hook installed in another project must keep working when
# this repository moves, changes or disappears. That makes "which files ride
# along with the entry script" a responsibility of its own, and this file owns
# it - the shared libraries each hook gets its own private copy of, and the
# companion executable a single hook needs to function at all.
#
# Split out of _installplan.ps1 at the 800-line ceiling. The planner still owns
# WHAT A PLAN IS (artifacts, hashes, generated content, ownership); this owns the
# fixed list of things that must be in every plan for the runtime to run.
#
# Dot-sourced by _installplan.ps1; uses its Add-Artifact and New-PlanArtifact.

# The shared libraries. Each hook gets its OWN PRIVATE copy inside its runtime
# directory and its installed script is rewritten to dot-source that copy.
function Add-SharedRuntimeLibraryArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    # Each hook gets its OWN PRIVATE copy of the shared library inside its
    # runtime directory, and its installed script is rewritten to dot-source
    # that private copy. A single shared library at the runtime root meant
    # updating one hook silently swapped the library every OTHER already
    # installed hook loads - a cross-hook version skew with no version boundary.
    $hookLib = Join-Path $ToolRoot 'hooks\_hooklib.ps1'
    if (Test-Path -LiteralPath $hookLib -PathType Leaf) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/_hooklib.ps1') -Kind 'File' -SourcePath $hookLib)
    }

    # _stoplib.ps1 travels WITH _hooklib.ps1, which dot-sources it as a sibling.
    # It is loaded optionally there, so a runtime installed before this file
    # existed keeps the single-marker fallback instead of failing to start - but
    # a runtime installed FROM HERE must get it, or the Stop ledger silently
    # degrades to the behaviour it was written to replace.
    $stopLib = Join-Path $ToolRoot 'hooks\_stoplib.ps1'
    if (Test-Path -LiteralPath $stopLib -PathType Leaf) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/_stoplib.ps1') -Kind 'File' -SourcePath $stopLib)
    }

    # _evidencelib.ps1 travels with them for the same reason: _hooklib.ps1
    # dot-sources it as an optional sibling, so a runtime installed FROM HERE
    # must get it or the closing gates fall back to the prefix-only test this
    # file was written to replace.
    $evidenceLib = Join-Path $ToolRoot 'hooks\_evidencelib.ps1'
    if (Test-Path -LiteralPath $evidenceLib -PathType Leaf) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/_evidencelib.ps1') -Kind 'File' -SourcePath $evidenceLib)
    }

    # _taskidentity.ps1, same contract again: _hooklib.ps1 dot-sources it as an
    # optional sibling and mints the task boundary through it. A runtime
    # installed FROM HERE without it would derive Stop identity from transcript
    # statistics, which is the bounded degraded path, not the intended one.
    $taskIdentityLib = Join-Path $ToolRoot 'hooks\_taskidentity.ps1'
    if (Test-Path -LiteralPath $taskIdentityLib -PathType Leaf) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/_taskidentity.ps1') -Kind 'File' -SourcePath $taskIdentityLib)
    }

    $deliveryLib = Join-Path $ToolRoot 'hooks\_deliverylib.ps1'
    if (-not (Test-Path -LiteralPath $deliveryLib -PathType Leaf)) { throw 'The shared delivery library is missing from this checkout.' }
    Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/_deliverylib.ps1') -Kind 'File' -SourcePath $deliveryLib)

    # _scope.ps1 is dot-sourced DIRECTLY by the hooks that need it, not by
    # _hooklib.ps1 - but the contract is the same: an installed runtime that
    # lacks it cannot answer "is this prompt project work?" or "is this
    # directory the project's own source?", and both consumers would throw on a
    # missing sibling rather than degrade.
    $scopeLib = Join-Path $ToolRoot 'hooks\_scope.ps1'
    if (Test-Path -LiteralPath $scopeLib -PathType Leaf) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/_scope.ps1') -Kind 'File' -SourcePath $scopeLib)
    }
}

# The companion EXECUTABLE one hook cannot work without.
function Add-CompanionRuntimeArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    # Test-Run-Guard's gate is only real if scripts\Run-Tests-Guarded.ps1 travels
    # WITH it. In a freshly-set-up target project the runner exists nowhere else,
    # and Test-Run-Guard's Find-GuardedRunner then finds nothing and silently
    # downgrades the gate to advisory - the exact defect. Ship the CANONICAL
    # runner (single source of truth in scripts\, never a committed duplicate)
    # into the installed hook's own scripts\ subdir, which is candidate[0] of
    # Find-GuardedRunner ($PSScriptRoot\scripts\Run-Tests-Guarded.ps1). It is a
    # standalone script (no _hooklib dependency), so it is copied verbatim and
    # becomes an Immutable managed artifact - editing the source runner is then
    # drift the updater repairs, keeping the shipped copy in lockstep.
    if ([string]::Equals($FriendlyName, 'Test-Run-Guard', [System.StringComparison]::OrdinalIgnoreCase)) {
        $guardedRunnerSource = Join-Path $ToolRoot 'scripts\Run-Tests-Guarded.ps1'
        if (Test-Path -LiteralPath $guardedRunnerSource -PathType Leaf) {
            Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/scripts/Run-Tests-Guarded.ps1') -Kind 'File' -SourcePath $guardedRunnerSource)
        }
    }
}
