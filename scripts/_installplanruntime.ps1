# Transactional runtime installation, the native pre-push wrapper generator and
# the legacy shared-library retirement.
#
# The EXECUTION half of the install plan: _installplan.ps1 builds the plan as a
# data structure, this file puts it on disk - staging, hash verification,
# commit, rollback and cleanup - plus the two file-generators that live at the
# same layer. Dot-sourced by _installplan.ps1 into the caller's scope; not a
# standalone module.

# ---- transactional runtime installation ------------------------------------

# Installs a plan into <RuntimeRoot>\<FriendlyName> WITHOUT destroying the
# existing runtime unless the replacement is fully built and verified:
#   1. build everything in a sibling staging directory,
#   2. verify every planned artifact exists with the expected hash,
#   3. move the live directory aside,
#   4. move staging into place,
#   5. delete the set-aside directory.
# Any failure before step 4 leaves the previous runtime untouched; a failure
# during step 4 restores it. Abandoned staging/backup directories from an
# interrupted run are cleaned on the next install.
function Install-PlannedRuntime {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null
    }
    $destination = Join-Path $RuntimeRoot $FriendlyName
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $staging = Join-Path $RuntimeRoot ('.hookmaker-staging-' + $FriendlyName + '-' + $token)
    $setAside = Join-Path $RuntimeRoot ('.hookmaker-previous-' + $FriendlyName + '-' + $token)

    # Clean what an earlier INTERRUPTED run abandoned for this hook. Only
    # directories older than the threshold are removed: a concurrent install of
    # the same hook has its own freshly-created staging directory that matches
    # the same name pattern, and deleting it out from under that process would
    # turn a survivable race into a failed install.
    $abandonedBefore = [DateTime]::UtcNow.AddMinutes(-30)
    foreach ($prefix in @(('.hookmaker-staging-' + $FriendlyName + '-'), ('.hookmaker-previous-' + $FriendlyName + '-'))) {
        foreach ($candidate in @(Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (-not $candidate.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($candidate.CreationTimeUtc -gt $abandonedBefore) { continue }
            Remove-Item -LiteralPath $candidate.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $swapped = $false
    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $stagingHookDir = Join-Path $staging $FriendlyName
        New-Item -ItemType Directory -Path $stagingHookDir -Force | Out-Null

        foreach ($artifact in @($Plan)) {
            $relative = ([string]$artifact.relativePath)
            $targetPath = Join-Path $staging ($relative.Replace('/', '\'))
            if (-not (Test-PathContainedIn -ChildPath $targetPath -ParentPath $staging)) {
                throw ("Planned artifact escapes the staging directory: " + $relative)
            }
            $targetDir = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            if ($artifact.kind -eq 'Generated') {
                [System.IO.File]::WriteAllText($targetPath, [string]$artifact.generatedContent, [System.Text.UTF8Encoding]::new($false))
            }
            else {
                if (-not (Test-Path -LiteralPath $artifact.sourcePath -PathType Leaf)) {
                    throw ("Planned source file is missing: " + $artifact.sourcePath)
                }
                Copy-Item -LiteralPath $artifact.sourcePath -Destination $targetPath -Force
            }
        }

        # Verify the staged tree BEFORE touching the live runtime.
        foreach ($artifact in @($Plan)) {
            if ($artifact.ownership -ne 'Immutable') { continue }
            $targetPath = Join-Path $staging (([string]$artifact.relativePath).Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                throw ("Staged artifact missing after copy: " + $artifact.relativePath)
            }
            $expected = Get-PlanArtifactExpectedHash -Artifact $artifact
            # .NET rather than Get-FileHash: the cmdlet is in a MODULE that a 5.1
            # child of a pwsh 7 parent can fail to resolve (see
            # Get-PlanArtifactExpectedHash in _installplan.ps1). Same digest, and
            # it must match that function's casing exactly for the compare below.
            $actualSha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $actualStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try { $actual = ([System.BitConverter]::ToString($actualSha.ComputeHash($actualStream))).Replace('-', '').ToUpperInvariant() }
                finally { $actualStream.Dispose() }
            }
            finally { $actualSha.Dispose() }
            if ($expected -ne $actual) {
                throw ("Staged artifact does not match its source: " + $artifact.relativePath)
            }
        }

        if (Test-Path -LiteralPath $destination) {
            Move-Item -LiteralPath $destination -Destination $setAside -Force
        }
        try {
            Move-Item -LiteralPath $stagingHookDir -Destination $destination -Force
            $swapped = $true
            # The staged tree is built from the PLAN, which never contains the
            # user's own '.env'. Without this, replacing the runtime silently
            # deleted the only supported way to configure a hook. Copied from the
            # set-aside copy of the previous runtime, before the finally block
            # removes it, and never over a file the plan actually shipped.
            foreach ($userConfig in $script:ManagedRuntimeUserConfigNames) {
                $previousConfig = Join-Path $setAside ([string]$userConfig)
                if (-not (Test-Path -LiteralPath $previousConfig -PathType Leaf)) { continue }
                $restoredConfig = Join-Path $destination ([string]$userConfig)
                if (Test-Path -LiteralPath $restoredConfig) { continue }
                Copy-Item -LiteralPath $previousConfig -Destination $restoredConfig -Force
            }
        }
        catch {
            # Put the previous runtime back so the installation keeps working.
            if ((Test-Path -LiteralPath $setAside) -and -not (Test-Path -LiteralPath $destination)) {
                Move-Item -LiteralPath $setAside -Destination $destination -Force
            }
            throw
        }
        # Root-level artifacts (currently only the shared _hooklib.ps1) live
        # beside every hook rather than inside this one, so they are placed
        # after the per-hook swap. They are copied from the verified staging
        # tree, never straight from source.
        foreach ($artifact in @($Plan)) {
            $relative = [string]$artifact.relativePath
            if ($relative.Contains('/')) { continue }
            $stagedPath = Join-Path $staging $relative
            if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) { continue }
            Copy-Item -LiteralPath $stagedPath -Destination (Join-Path $RuntimeRoot $relative) -Force
        }
        return [pscustomobject]@{ Ok = $true; Destination = $destination }
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        if ($swapped -and (Test-Path -LiteralPath $setAside)) {
            Remove-Item -LiteralPath $setAside -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- native pre-push wrapper (ONE canonical generator) ---------------------

$script:PrePushMarker = '# Hook Maker: Ignore-Rules-Check'

# The single source of truth for the managed pre-push wrapper's bytes. The
# installer WRITES this and the updater's integrity check REBUILDS it to
# compare - so "is the wrapper current?" is an exact-content question, not a
# collection of substring guesses that can drift from what we actually write.
#
# Semantics that must survive any edit here (each is asserted by the suite):
#   * mktemp-backed single stdin buffer (git delivers ref lines once),
#   * `trap ... EXIT` cleanup on every exit path,
#   * every managed stage fed that SAME buffer, in the given order,
#   * `|| exit $?` after each stage => fail-closed,
#   * the preserved previous hook runs last, with "$@" forwarded and the
#     same buffered stdin.
function New-PrePushWrapperBody {
    param([Parameter(Mandatory = $true)][string[]]$ManagedScripts)

    $stages = @($ManagedScripts) | ForEach-Object {
        $scriptPath = $_.Replace('\', '/').Replace('$', '\$').Replace('`', '\`')
        'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -GitPrePush < "$STDIN_FILE" || exit $?'
    }
    return "#!/bin/sh`n" + $script:PrePushMarker + "`n" +
        "STDIN_FILE=`$(mktemp `"`${TMPDIR:-/tmp}/hookmaker-prepush.XXXXXX`") || exit 1`n" +
        "trap 'rm -f `"`$STDIN_FILE`"' EXIT`n" +
        "cat > `"`$STDIN_FILE`"`n" +
        (($stages) -join "`n") + "`n" +
        "if [ -f `"`$0.hookmaker-existing`" ]; then`n  `"`$0.hookmaker-existing`" `"`$@`" < `"`$STDIN_FILE`"`nfi`n"
}

# Line-ending normalization is the ONLY difference tolerated between the
# expected and installed wrapper (a checkout or editor may rewrite CRLF/LF).
function Compare-PrePushWrapperBody {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual
    )
    $normalize = { param($t) ($t -replace "`r`n", "`n") }
    return ([string](& $normalize $Expected) -ceq [string](& $normalize $Actual))
}

# Retires the legacy shared runtime-root _hooklib.ps1.
#
# This runs ONLY as a post-commit cleanup phase, and only when it is provably
# unreferenced: every hook directory under the runtime root must already carry
# its own private copy. A hook installed by an older version still dot-sources
# '..\_hooklib.ps1', so removing the shared file while any such hook remains
# would break it - the check is what makes the removal safe rather than a
# hopeful cleanup.
function Remove-SharedRuntimeLibrary {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $shared = Join-Path $RuntimeRoot '_hooklib.ps1'
    if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) {
        return [pscustomobject]@{ Removed = $false; Reason = 'no shared library present' }
    }
    $hookDirs = @(Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith('.hookmaker-', [System.StringComparison]::OrdinalIgnoreCase) })
    foreach ($hookDir in $hookDirs) {
        if (-not (Test-Path -LiteralPath (Join-Path $hookDir.FullName '_hooklib.ps1') -PathType Leaf)) {
            return [pscustomobject]@{ Removed = $false; Reason = ('still referenced by ' + $hookDir.Name) }
        }
    }
    try {
        Remove-Item -LiteralPath $shared -Force
        return [pscustomobject]@{ Removed = $true; Reason = 'every hook now has a private library copy' }
    }
    catch {
        return [pscustomobject]@{ Removed = $false; Reason = ('could not remove: ' + $_.Exception.Message) }
    }
}
