# ---------------------------------------------------------------------------
# Noninteractive hook-status scan engine (menu 22's worker).
#
# ONE responsibility: turn a filesystem root into structured, verified evidence
# about which hooks are registered there - Claude registrations, Codex
# registrations and native Git hooks - and (optionally) persist that evidence as
# `discovered` records in the existing install registry.
#
# It has NO UI dependencies: it prints only progress (on the progress stream)
# and writes a machine-readable result document to -ResultPath. A separate UI
# layer renders it.
#
# Safety model - the whole point of this file:
#   * It NEVER executes anything it discovers. No hook is run, no command from a
#     settings file is invoked, no discovered PowerShell is dot-sourced, no
#     interpreter is launched. The only child process this file ever starts is
#     `git config --get`, with an argument ARRAY (never a shell string) and a
#     bounded timeout - and `git config` cannot run a hook.
#   * It is READ-ONLY with respect to the scanned root. Nothing is written,
#     moved, renamed or deleted there. The only path written is the registry
#     under <ToolRoot>\state, and only after a scan that reached a terminal
#     'ok' or 'partial' outcome.
#   * It opens only KNOWN candidate locations (a `.claude`/`.codex` settings
#     file, a `.git` pointer file, a git config, a git hook entrypoint) - never
#     an arbitrary file it happens to walk past.
#   * It hashes only candidate targets, native entrypoints and artifacts that
#     may become tracked - never every file on a drive.
#   * The walk is iterative and streaming (one directory's listing at a time),
#     has NO depth cap by default, does not follow reparse points, and isolates
#     a failure to enumerate ONE directory so an unreadable folder can never
#     abort a whole scan.
#
# Identity comes from scripts\_hookdiscovery.ps1 and nowhere else - the remover
# recomputes the same fingerprints from the live file and refuses to act unless
# they still match, so the two computations must never drift apart.
#
# Usage:
#   pwsh -NoLogo -NoProfile -File .\scripts\Get-HookStatus.ps1 `
#        -ScanRoot C:\Projects -ResultPath C:\temp\scan.json [-IncludeGlobal] [-NoPersist]
# ---------------------------------------------------------------------------

param(
    # The directory to scan. Defaults to the current location. May be an
    # arbitrary ancestor (a whole drive) or a subtree that is already INSIDE a
    # runtime/native tree - the latter triggers a bounded upward lookup for the
    # nearest settings/git context (see Find-UpwardContext).
    [string]$ScanRoot,
    # Also inspect the canonical current-user Claude/Codex settings files, even
    # when they live outside -ScanRoot.
    [switch]$IncludeGlobal,
    # Hook Maker's own root (where state\install-registry.json lives).
    # Overridable for tests / relocated checkouts.
    [string]$ToolRoot,
    # Machine-readable scan-result document destination (see the shared
    # contract). Written on EVERY terminal outcome, including failure.
    [string]$ResultPath,
    # Compute and report everything, but write nothing to the registry.
    [switch]$NoPersist,
    # Traversal depth limit for tests and manual CLI use ONLY. 0 (the default)
    # means UNLIMITED - the normal path must have no depth, item-count or
    # project-count limit whatsoever.
    [int]$MaxDepth = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- library load order (same contract as Uninstall-Hook.ps1) --------------
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
$ToolRoot = [System.IO.Path]::GetFullPath($ToolRoot)
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
. (Join-Path $PSScriptRoot '_installplan.ps1')
. (Join-Path $PSScriptRoot '_installlib.ps1')
# LAST on purpose: _installplan.ps1 defines its own stricter Test-IsReparsePoint
# (for copy safety - it answers $true for an unreadable path). Discovery needs
# _hookdiscovery.ps1's definition, so it must win.
. (Join-Path $PSScriptRoot '_hookdiscovery.ps1')
. (Join-Path $PSScriptRoot '_hookstatusscan.ps1')
. (Join-Path $PSScriptRoot '_hookstatusrecords.ps1')

# ---- scan state ------------------------------------------------------------

$script:ScanId = [guid]::NewGuid().ToString('N').Substring(0, 16)
$script:StartedAt = [DateTime]::UtcNow
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Errors = New-Object System.Collections.Generic.List[string]
$script:Inaccessible = New-Object System.Collections.Generic.List[string]
$script:SkippedReparse = New-Object System.Collections.Generic.List[string]
$script:ScanRoots = New-Object System.Collections.Generic.List[string]
$script:RegistrationFindings = New-Object System.Collections.Generic.List[object]
$script:NativeFindings = New-Object System.Collections.Generic.List[object]
$script:Findings = @()
$script:DirectoriesInspected = 0
$script:SettingsFilesSeen = 0
$script:GitRepositoriesSeen = 0
$script:CandidateRootsSeen = 0
$script:RecordsAdded = 0
$script:RecordsUpdated = 0
$script:RecordsMatched = 0
$script:Canceled = $false
$script:Persisted = $false

function Add-ScanWarning {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $text = [string]$Message
    if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + '...' }
    if (-not $script:Warnings.Contains($text)) { [void]$script:Warnings.Add($text) }
}
function Add-ScanError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $text = [string]$Message
    if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + '...' }
    if (-not $script:Errors.Contains($text)) { [void]$script:Errors.Add($text) }
}

# ---- result document -------------------------------------------------------

# Fence for the stdout channel. Deliberately unmistakable, and deliberately NOT
# valid JSON, so a caller can find the document inside arbitrary console output
# without guessing. Shared with Setup-SyncGroupHookStatus.ps1 and the suites -
# if you change these, change every extractor with them.
$script:ResultBeginMarker = '<<<HOOKMAKER-SCAN-RESULT>>>'
$script:ResultEndMarker = '<<<END-HOOKMAKER-SCAN-RESULT>>>'

# Written on EVERY terminal outcome. `coverage.complete` is false whenever any
# directory could not be read or any reparse point was skipped: a scan that did
# not see everything must never be able to claim it did, because a caller uses
# that flag to decide whether "not found" means "gone".
#
# TWO DELIVERY CHANNELS, and the second one exists to resolve a real conflict:
#   -ResultPath given  -> written to that file (refused if it is inside a scan
#                         root, so the scan can neither contaminate the tree it
#                         is inspecting nor observe its own output).
#   -ResultPath absent -> the JSON is emitted to STDOUT and no file is created
#                         anywhere.
#
# Without the second channel, "never writes inside the scanned root" and "a drive
# root such as G:\ is a valid scan root" cannot both hold on a single-volume
# machine: every writable path, including %TEMP%, is inside the scanned tree, so
# the caller has nowhere legal to put a result file. Returning the document
# instead of storing it removes the file from the problem entirely. The wizard
# uses this channel, which is why menu 22 can scan a whole drive.
function Write-ScanResult {
    param([Parameter(Mandatory = $true)][ValidateSet('ok', 'partial', 'failed', 'canceled')][string]$Overall)
    try {
        $ambiguousCount = @(@($script:Findings) | Where-Object {
            $null -ne $_ -and ([string]$_.status -eq 'ambiguous' -or [string]$_.status -eq 'manualRepair')
        }).Count
        $document = [pscustomobject][ordered]@{
            schema         = 1
            overall        = $Overall
            scanId         = $script:ScanId
            scanRoots      = @($script:ScanRoots.ToArray())
            includeGlobal  = [bool]$IncludeGlobal
            coverage       = [pscustomobject][ordered]@{
                complete      = (($script:Inaccessible.Count -eq 0) -and ($script:SkippedReparse.Count -eq 0) -and (-not $script:Canceled) -and ($MaxDepth -le 0))
                inaccessible  = @($script:Inaccessible.ToArray())
                skippedReparse = @($script:SkippedReparse.ToArray())
                # Dependency/build caches excluded BY NAME. Reported so the
                # result never implies it looked everywhere, but NOT counted
                # against completeness: these trees cannot hold a registration,
                # a managed runtime or a repository worth reading, so excluding
                # them is scoping, not a gap.
                prunedDirectories = $script:PrunedDirectoryCount
                prunedNames       = @($script:PrunedDirectoryNamesSeen | Sort-Object)
            }
            counts         = [pscustomobject][ordered]@{
                directories     = $script:DirectoriesInspected
                settingsFiles   = $script:SettingsFilesSeen
                gitRepositories = $script:GitRepositoriesSeen
                logicalHooks    = @($script:Findings).Count
                ambiguous       = $ambiguousCount
            }
            findings       = @($script:Findings)
            recordsAdded   = $script:RecordsAdded
            recordsUpdated = $script:RecordsUpdated
            recordsMatched = $script:RecordsMatched
            warnings       = @($script:Warnings.ToArray())
            errors         = @($script:Errors.ToArray())
            registryPath   = (Get-InstallRegistryPath -ToolRoot $ToolRoot)
            elapsedSeconds = [math]::Round(([DateTime]::UtcNow - $script:StartedAt).TotalSeconds, 3)
            atUtc          = [DateTime]::UtcNow.ToString('o')
        }
        $json = $document | ConvertTo-Json -Depth 30

        if ([string]::IsNullOrWhiteSpace($ResultPath)) {
            # STDOUT channel, FENCED.
            #
            # The fence is not decoration. PowerShell's stream separation
            # (success vs information) only exists inside one PowerShell process:
            # once this script runs as a CHILD, everything it writes to the
            # console - progress lines included - arrives on the parent's stdout
            # together, and a caller that simply parsed the lot would choke on
            # the first progress line. The markers let any caller, in-process or
            # cross-process, extract exactly the document and ignore the rest.
            Write-Output $script:ResultBeginMarker
            Write-Output $json
            Write-Output $script:ResultEndMarker
            return
        }

        $directory = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($ResultPath, $json, ([System.Text.UTF8Encoding]::new($false)))
    }
    catch {
        # A result-file failure must never mask the scan's own outcome.
    }
}

# Same guarantee Install-Hook.ps1/Uninstall-Hook.ps1 give: a bare exception
# anywhere below still lands a valid result document, then propagates exactly as
# it would have. A failed scan persists NOTHING.
trap {
    $message = [string]$_.Exception.Message
    # Same debug switch the test suites use: the stack trace is diagnostic only
    # and never part of a normal result document.
    if ($env:HOOKMAKER_TEST_DEBUG -eq '1') { $message += ' | at ' + [string]$_.ScriptStackTrace }
    Add-ScanError $message
    Write-ScanResult -Overall 'failed'
    break
}

# Ctrl+C must leave the registry byte-identical, so cancellation only ever sets
# a flag the walk checks - the persistence step is simply never reached.
try {
    [Console]::add_CancelKeyPress({
        param($eventSender, $eventArgs)
        $eventArgs.Cancel = $true
        $script:Canceled = $true
    })
}
catch {
    # No console (redirected/service host): cooperative cancellation is simply
    # unavailable, which is not an error.
}

# ---- progress --------------------------------------------------------------

$script:LastProgressAt = [DateTime]::UtcNow
function Show-ScanProgress {
    param([switch]$Force)
    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $script:LastProgressAt).TotalMilliseconds -lt 750) { return }
    $script:LastProgressAt = $now
    $elapsed = [math]::Round(($now - $script:StartedAt).TotalSeconds, 1)
    try {
        Write-Progress -Id 1 -Activity 'Scanning for installed hooks' -Status (
            'directories ' + $script:DirectoriesInspected +
            ' | candidate roots ' + $script:CandidateRootsSeen +
            ' | registrations ' + ($script:RegistrationFindings.Count + $script:NativeFindings.Count) +
            ' | ' + $elapsed + 's')
    }
    catch { }
}

# Discovery (settings/git parsing + the directory walk) lives in
# _hookstatusscan.ps1; grouping findings into verified records and persisting
# them lives in _hookstatusrecords.ps1 - both dot-sourced above and sharing
# this script's scope/state.

# ---- main ------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ScanRoot)) { $ScanRoot = (Get-Location).Path }
$ScanRoot = Get-CanonicalPathOrEmpty $ScanRoot
if ($ScanRoot -eq '' -or -not (Test-Path -LiteralPath $ScanRoot -PathType Container)) {
    throw ('-ScanRoot is not an existing directory: ' + $ScanRoot)
}
# Option (a): refuse a reparse-point root outright rather than resolving and
# walking it. This scanner's contract is that junctions/symlinks are NOT
# followed, and the root is not an exception: a junction can point anywhere,
# so "scan this folder" would silently become "scan somewhere else". Being
# named explicitly proves the caller meant this PATH, not that they know where
# it lands. Nothing is scanned, so this is not a partial scan - it is a scan
# that did not run. A caller who genuinely means the target passes the physical
# directory; an interactive layer is free to resolve it, SHOW the target and ask
# first, which is a decision this noninteractive worker cannot make.
if (Test-IsReparsePoint -Path $ScanRoot) {
    throw ('-ScanRoot is a reparse point (junction/symlink) and is never followed: ' + $ScanRoot +
        ' - re-run with the physical directory it points at if that is what you meant.')
}
[void]$script:ScanRoots.Add($ScanRoot)

if ($IncludeGlobal) {
    foreach ($candidate in @(Get-GlobalSettingsCandidates)) {
        $clientDirectory = Split-Path -Parent $candidate.Path
        $globalRoot = Split-Path -Parent $clientDirectory
        if ([string]::IsNullOrWhiteSpace($globalRoot)) { continue }
        # A global root that already lives inside the scanned root would be
        # walked anyway; adding it again would double every count.
        if (Test-PathContainedIn -ChildPath $candidate.Path -ParentPath $ScanRoot) { continue }
        $canonicalGlobalRoot = Get-CanonicalPathOrEmpty $globalRoot
        if ($canonicalGlobalRoot -ne '' -and -not $script:ScanRoots.Contains($canonicalGlobalRoot)) {
            [void]$script:ScanRoots.Add($canonicalGlobalRoot)
        }
    }
}

# "This scan never writes anything inside the folder it scans" is a guarantee,
# not a preference, so a -ResultPath that lands inside ANY scan root (including
# a global root added by -IncludeGlobal) is refused before a single directory is
# read. The refusal CANNOT be reported in the result document - that document is
# the offending path - so it is a terminating error on stderr plus a non-zero
# exit, and $ResultPath is blanked first so the trap's own write is suppressed
# too. Nothing scanned, nothing written, no registry change.
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $resultCanonical = Get-CanonicalPathOrEmpty $ResultPath
    foreach ($root in @($script:ScanRoots.ToArray())) {
        if ($resultCanonical -ne '' -and (Test-PathContainedIn -ChildPath $resultCanonical -ParentPath $root)) {
            $offending = $resultCanonical
            $ResultPath = ''
            throw ('-ResultPath resolves inside a scanned root, and this scan never writes inside what it scans: ' +
                $offending + ' is inside ' + $root + ' - choose a result path outside every scan root.')
        }
    }
}

# The upward lookup runs FIRST so a direct-subtree scan root reports its own
# registration even if the downward walk finds nothing.
Find-UpwardContext -Root $ScanRoot

foreach ($root in @($script:ScanRoots.ToArray())) {
    if ($script:Canceled) { break }
    if ($IncludeGlobal -and $root -ne $ScanRoot) {
        # A global root is inspected at its KNOWN settings locations only - the
        # user's whole home directory is never walked.
        foreach ($candidate in @(Get-GlobalSettingsCandidates)) {
            if (-not (Test-PathContainedIn -ChildPath $candidate.Path -ParentPath $root)) { continue }
            Read-SettingsRegistrations -SettingsPath $candidate.Path -Client $candidate.Client
        }
        continue
    }
    Invoke-ScanWalk -Root $root
}
Show-ScanProgress -Force
try { Write-Progress -Id 1 -Activity 'Scanning for installed hooks' -Completed } catch { }

if ($script:Canceled) {
    Write-ScanResult -Overall 'canceled'
    Write-Host 'Scan canceled. Nothing was written.'
    exit 2
}

$script:Findings = @(@(Build-RegistrationRecords) + @(Build-NativeRecords))
$script:Findings = @(Add-RuntimeArtifacts -Records $script:Findings)

$coverageComplete = (($script:Inaccessible.Count -eq 0) -and ($script:SkippedReparse.Count -eq 0) -and ($MaxDepth -le 0))
$overall = 'ok'
if (-not $coverageComplete -or $script:Warnings.Count -gt 0) { $overall = 'partial' }

if (-not $NoPersist) {
    try { Save-DiscoveredRecords -Records $script:Findings -CoverageComplete $coverageComplete }
    catch {
        Add-ScanError ('scan results could not be persisted: ' + $_.Exception.Message)
        $overall = 'partial'
    }
}

Write-ScanResult -Overall $overall
Write-Host ('Scan ' + $overall + ': ' + @($script:Findings).Count + ' logical hook(s) across ' +
    $script:DirectoriesInspected + ' director(ies).' +
    $(if ($NoPersist) { ' Nothing was persisted (-NoPersist).' } elseif ($script:Persisted) { ' Results persisted.' } else { ' Results were NOT persisted.' }))
exit 0
