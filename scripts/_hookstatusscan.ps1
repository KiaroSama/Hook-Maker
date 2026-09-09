# ---------------------------------------------------------------------------
# Discovery half of the hook-status scan engine: the walk itself. Dot-sourced
# by Get-HookStatus.ps1 ONLY - it runs in that script's scope, so every
# $script: state variable (Warnings, Inaccessible, SkippedReparse,
# RegistrationFindings, NativeFindings, counters, ...) and every helper it
# calls (Add-ScanWarning, Show-ScanProgress, and the record builders in
# _hookstatusrecords.ps1) resolve at CALL time, once the whole engine and its
# libraries are loaded and only "main" is executing. Do not dot-source this
# file directly.
#
# The raw-finding readers the walk dispatches to live in two sibling modules,
# dot-sourced below into this same scope. Each script file's $PSScriptRoot is
# its OWN directory even inside a dot-source chain, so the siblings resolve
# correctly no matter where the entry script was loaded from:
#   _hookstatusscanregistrations.ps1 - Claude/Codex settings parsing and Kiro
#                                      per-hook-file registration parsing
#   _hookstatusscangit.ps1           - native Git hook discovery
#
# Responsibility of THIS file: shared path helpers plus turning a filesystem
# location into VISITS - which directories are walked, what is never followed,
# which known candidate locations are handed to the readers, and the bounded
# upward context lookup. See _hookstatusrecords.ps1 for turning the readers'
# raw findings into verified logical records.
# ---------------------------------------------------------------------------

# ---- shared path helpers ---------------------------------------------------

# Dependency and build CACHES: never descended into, by name.
#
# A real scan of one machine walked 22,254 directories in 106s and came back
# PARTIAL - because 10 of its 14 skipped reparse points were npm/pnpm package
# junctions inside node_modules and .next. Those trees hold no registration, no
# managed runtime and no Git repository worth reading; walking them cost most of
# the time and produced a permanent "coverage incomplete" for a part of the disk
# that can never contain what the scan is looking for.
#
# This is deliberately NOT $script:PlanForbiddenDirectoryNames from
# _installplan.ps1. That list also excludes .claude, .codex, .ai and .agents -
# which is right when copying files INTO a runtime and exactly wrong here, since
# those directories are where registrations actually live.
#
# Kept to caches that cannot plausibly be a project root a user syncs. 'dist',
# 'build', 'out', 'bin', 'obj' and 'target' are deliberately ABSENT: a project
# can legitimately live at ...\build\myapp, and skipping it would hide a real
# install. Pruning is reported, never silent - see the coverage section of the
# result document.
$script:ScanPrunedDirectoryNames = @(
    'node_modules', '.next', '.nuxt', '.svelte-kit', '.angular', '.parcel-cache',
    '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.tox',
    '.gradle', '.terraform', '.turbo',
    # Reference collections, not projects: third-party skills, MCP servers and
    # assorted material kept for reading. They hold other people's agent
    # configuration - including .claude and .codex directories that are NOT
    # installs of ours - so walking them produced findings and reparse-point
    # skips for hooks nobody installed here. Add machine-specific collection
    # folders here; keep real project trees out of this list.
    '.OTHERS', '.SKILLS', '.MCPs'
)
# Count plus the DISTINCT names actually hit - not the paths. A machine with
# hundreds of node_modules trees would otherwise bloat the result document with
# thousands of paths that all say the same thing.
$script:PrunedDirectoryCount = 0
$script:PrunedDirectoryNamesSeen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
$script:SeenDirectoryKeys = New-Object System.Collections.Generic.HashSet[string]
$script:SeenSettingsKeys = New-Object System.Collections.Generic.HashSet[string]
$script:SeenGitKeys = New-Object System.Collections.Generic.HashSet[string]

function Test-PathUnderAny {
    param([string]$Path, [string[]]$Parents)
    foreach ($parent in @($Parents)) {
        if ([string]::IsNullOrWhiteSpace($parent)) { continue }
        try { if (Test-PathContainedIn -ChildPath $Path -ParentPath $parent) { return $true } }
        catch { }
    }
    return $false
}

# ---- the readers -----------------------------------------------------------

# Loaded before the walk that dispatches to them, into this same scope. Order
# between the two does not matter: both only define functions and load-time
# lookup state; nothing runs until main drives the walk.
. (Join-Path $PSScriptRoot '_hookstatusscanregistrations.ps1')
. (Join-Path $PSScriptRoot '_hookstatusscangit.ps1')

# ---- the walk --------------------------------------------------------------

# Iterative and streaming: one directory's listing is materialized at a time
# (so an enumeration error can be caught for THAT directory), the frontier is an
# explicit stack, and nothing about the tree as a whole is ever held in memory.
function Invoke-ScanWalk {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonicalRoot = Get-CanonicalPathOrEmpty $Root
    if ($canonicalRoot -eq '' -or -not (Test-Path -LiteralPath $canonicalRoot -PathType Container)) {
        Add-ScanWarning ('scan root is not an existing directory and was skipped: ' + $Root)
        return
    }
    # A reparse-point root never reaches here: main refuses it outright, before
    # anything is scanned (see the -ScanRoot checks at the bottom of this file).

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $canonicalRoot; Depth = 0 })

    while ($stack.Count -gt 0) {
        if ($script:Canceled) { return }
        $current = $stack.Pop()
        $key = Get-CanonicalPathKey $current.Path
        if ($key -eq '' -or -not $script:SeenDirectoryKeys.Add($key)) { continue }
        $script:DirectoriesInspected++
        Show-ScanProgress

        $entries = @()
        try { $entries = @((New-Object System.IO.DirectoryInfo $current.Path).EnumerateFileSystemInfos()) }
        catch {
            # Access denied, path too long, or the directory vanished mid-scan.
            # Isolated to THIS directory - one unreadable folder must never be
            # able to abort a whole drive scan.
            [void]$script:Inaccessible.Add([string]$current.Path)
            continue
        }

        $parentName = ''
        $grandParentName = ''
        try {
            $currentInfo = New-Object System.IO.DirectoryInfo $current.Path
            $parentName = $currentInfo.Name
            if ($null -ne $currentInfo.Parent) { $grandParentName = $currentInfo.Parent.Name }
        }
        catch { }

        # Is THIS directory a per-hook-file registration directory? A
        # perHookFile client owns a whole directory of registrations rather than
        # one known filename, so it is handled once here instead of per file -
        # and recognised by POSITION (leaf name plus containing directory name),
        # so an ordinary folder called 'hooks' elsewhere is never mistaken for
        # one. Ownership is still proven per document inside the reader.

        foreach ($entry in $entries) {
            if ($script:Canceled) { return }
            $isDirectory = (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -eq [System.IO.FileAttributes]::Directory)
            if ($isDirectory) {
                # Prune FIRST, before the reparse check: most of the reparse
                # points on a developer machine are package junctions INSIDE
                # these trees, and pruning the parent means they are never
                # enumerated at all - so they stop being reported as coverage
                # gaps, which is what they never really were.
                if ($script:ScanPrunedDirectoryNames -contains $entry.Name) {
                    $script:PrunedDirectoryCount++
                    [void]$script:PrunedDirectoryNamesSeen.Add([string]$entry.Name)
                    continue
                }
                # A virtualenv whose directory name is none of the conventional
                # spellings above is still a virtualenv, and still cannot hold a
                # registration. Reported under the MARKER name rather than the
                # directory's own, so the distinct-names contract stays a small
                # stable set instead of gaining an entry per oddly named venv.
                if (Test-IsMarkerPrunedDirectory -Path $entry.FullName) {
                    $script:PrunedDirectoryCount++
                    [void]$script:PrunedDirectoryNamesSeen.Add('pyvenv.cfg')
                    continue
                }
                # Reparse check BEFORE the '.git' name dispatch below - a '.git'
                # entry that is itself a junction/symlink must be caught here
                # too, or Read-GitRepository would follow it via an explicit
                # path read (Resolve-GitDirectory / core.hooksPath), scanning
                # outside -ScanRoot and breaking the guarantee for the one name
                # checked first.
                # Attribute check first, then the shared helper. Both answer the
                # same question; the attribute is already in hand from the
                # enumeration, so it avoids a second stat on the common path.
                if ((($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) -or
                    (Test-IsReparsePoint -Path $entry.FullName)) {
                    # Never followed: a junction to an ancestor is an infinite
                    # tree and one pointing outside the root would silently scan
                    # somewhere the user did not ask for.
                    [void]$script:SkippedReparse.Add([string]$entry.FullName)
                    continue
                }
                if ($entry.Name -eq '.git') {
                    # A repository, not a folder to descend into: git's object
                    # store is large, contains nothing registrable, and its
                    # hooks directory is reached by path below.
                    Read-GitRepository -RepositoryRoot $current.Path
                    continue
                }
                $childDepth = [int]$current.Depth + 1
                # $MaxDepth 0/unset = unlimited. This branch exists only so
                # tests and manual CLI use can bound a walk.
                if ($MaxDepth -gt 0 -and $childDepth -gt $MaxDepth) { continue }
                $stack.Push([pscustomobject]@{ Path = [string]$entry.FullName; Depth = $childDepth })
                continue
            }

            # Files: only KNOWN candidate names at KNOWN positions are opened.
            if ($entry.Name -eq '.git') {
                Read-GitRepository -RepositoryRoot $current.Path
                continue
            }
            if ($parentName -eq '.claude' -and ($entry.Name -eq 'settings.local.json' -or $entry.Name -eq 'settings.json')) {
                Read-SettingsRegistrations -SettingsPath $entry.FullName -Client 'claude'
                continue
            }
            if ($parentName -eq '.codex' -and $entry.Name -eq 'hooks.json') {
                Read-SettingsRegistrations -SettingsPath $entry.FullName -Client 'codex'
                continue
            }
        }
    }
}

# When -ScanRoot is already INSIDE a runtime or native tree (say
# ...\.claude\hooks\Hook-Maker), walking down from it finds the runtime files but
# not the registration that points at them. So the enclosing context is looked up
# UPWARD - but in exactly ONE bounded hop, not by climbing.
#
# The hop is derived from the root's own path components: the OUTERMOST
# `.claude` / `.codex` / `.kiro` / `.git` component in -ScanRoot marks the tree
# the user pointed inside, and its parent is that tree's project root. Only that
# one directory is inspected, and only at its known settings/git locations - no
# ancestor is ever enumerated.
#
# `.kiro` is a marker because Kiro's runtime root is `.kiro\hook-runtime\
# Hook-Maker`, so a scan aimed there was previously left with NO enclosing
# context at all. It resolves the same project root the other two do, and its
# own registrations - one JSON per install under `.kiro\hooks` - are read here
# as a bounded directory pass, the perHookFile equivalent of the two known
# settings leaves.
#
# Deriving the hop instead of walking up until something is found is what keeps
# this from silently becoming an unrestricted scan outside the user's root: a
# climb from an ordinary temp folder would eventually reach the user's home and
# read the real global settings nobody asked about.
function Find-UpwardContext {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonical = Get-CanonicalPathOrEmpty $Root
    if ($canonical -eq '') { return }
    $segments = @($canonical.Split([char[]]@('\', '/')))
    $markerIndex = -1
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ($segments[$i] -eq '.claude' -or $segments[$i] -eq '.codex' -or $segments[$i] -eq '.git') { $markerIndex = $i; break }
    }
    # No client/native component in the path: -ScanRoot is an ordinary directory
    # and the downward walk already covers everything reachable from it.
    if ($markerIndex -lt 1) { return }

    $contextRoot = Get-CanonicalPathOrEmpty (($segments[0..($markerIndex - 1)]) -join [string][System.IO.Path]::DirectorySeparatorChar)
    if ($contextRoot -eq '' -or -not (Test-Path -LiteralPath $contextRoot -PathType Container)) { return }

    foreach ($leaf in @('.claude\settings.local.json', '.claude\settings.json')) {
        $candidate = Join-Path $contextRoot $leaf
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Read-SettingsRegistrations -SettingsPath $candidate -Client 'claude' }
    }
    $codexCandidate = Join-Path $contextRoot '.codex\hooks.json'
    if (Test-Path -LiteralPath $codexCandidate -PathType Leaf) { Read-SettingsRegistrations -SettingsPath $codexCandidate -Client 'codex' }

    $contextGitPath = Join-Path $contextRoot '.git'
    # Same reparse guard as the downward walk: a '.git' DIRECTORY reached by
    # this single upward hop must not be followed if it is itself a junction.
    if ((Test-Path -LiteralPath $contextGitPath -PathType Container) -and (Test-IsReparsePoint -Path $contextGitPath)) {
        [void]$script:SkippedReparse.Add($contextGitPath)
    }
    elseif (Test-Path -LiteralPath $contextGitPath) {
        Read-GitRepository -RepositoryRoot $contextRoot
    }
}
