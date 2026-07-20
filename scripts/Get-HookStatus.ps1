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

# Written on EVERY terminal outcome. `coverage.complete` is false whenever any
# directory could not be read or any reparse point was skipped: a scan that did
# not see everything must never be able to claim it did, because a caller uses
# that flag to decide whether "not found" means "gone".
function Write-ScanResult {
    param([Parameter(Mandatory = $true)][ValidateSet('ok', 'partial', 'failed', 'canceled')][string]$Overall)
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
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
        $directory = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($ResultPath, ($document | ConvertTo-Json -Depth 30), ([System.Text.UTF8Encoding]::new($false)))
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

# ---- shared path helpers ---------------------------------------------------

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

# ---- Claude / Codex settings parsing ---------------------------------------

# The canonical global settings locations, as the installer itself writes them.
function Get-GlobalSettingsCandidates {
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($client in @('claude', 'codex')) {
        $path = ''
        try { $path = Get-CanonicalClientSettingsPath -ClientName $client -Scope 'global' }
        catch { continue }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        [void]$candidates.Add([pscustomobject]@{ Client = $client; Path = $path })
    }
    return $candidates.ToArray()
}

$script:GlobalSettingsKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($candidate in @(Get-GlobalSettingsCandidates)) {
    [void]$script:GlobalSettingsKeys.Add((Get-CanonicalPathKey $candidate.Path))
}

# Scope is decided by the FILE'S OWN location, not by how the scan reached it: a
# global settings file found because it happened to sit inside the scanned root
# is still global.
function Get-SettingsScopeInfo {
    param([string]$SettingsPath)
    $key = Get-CanonicalPathKey $SettingsPath
    if ($script:GlobalSettingsKeys.Contains($key)) {
        return [pscustomobject]@{ Scope = 'global'; ProjectRoot = '' }
    }
    # <root>\.claude\settings.local.json -> <root>
    $clientDirectory = Split-Path -Parent $SettingsPath
    $projectRoot = Split-Path -Parent $clientDirectory
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        return [pscustomobject]@{ Scope = 'global'; ProjectRoot = '' }
    }
    return [pscustomobject]@{ Scope = 'project'; ProjectRoot = (Get-CanonicalPathOrEmpty $projectRoot) }
}

# Turns ONE settings file into per-handler findings.
#
# Every event and every handler is reported - there is deliberately NO filter on
# Hook Maker's name, path, marker, profile or command. A third-party hook is
# exactly as much an "installed hook" as ours, and hiding it would defeat the
# purpose of the scan.
#
# Malformed JSON is a FINDING (a warning plus a coverage note), never a crash.
function Read-SettingsRegistrations {
    param([Parameter(Mandatory = $true)][string]$SettingsPath, [Parameter(Mandatory = $true)][string]$Client)

    $key = Get-CanonicalPathKey $SettingsPath
    if ($key -eq '') { return }
    # THE global gate, enforced at the single point where any settings file is
    # opened rather than at each caller. -IncludeGlobal is a direct answer to a
    # direct question, so "declined" has to mean the current user's global
    # settings files are never read - no matter which path would reach them.
    # Both the downward walk (a scan root that happens to sit at or above the
    # user's profile) and the direct-subtree lookup (a scan root inside
    # $HOME\.claude\...) can otherwise land on exactly those files.
    if (-not $IncludeGlobal -and $script:GlobalSettingsKeys.Contains($key)) { return }
    if (-not $script:SeenSettingsKeys.Add($key)) { return }
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return }
    $script:SettingsFilesSeen++
    $script:CandidateRootsSeen++

    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.Encoding]::UTF8) }
    catch {
        Add-ScanWarning ('settings file could not be read: ' + $SettingsPath + ' (' + $_.Exception.Message + ')')
        [void]$script:Inaccessible.Add($SettingsPath)
        return
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $document = $null
    try { $document = $raw | ConvertFrom-Json }
    catch {
        Add-ScanWarning ('settings file is not valid JSON and was skipped: ' + $SettingsPath)
        return
    }
    if ($null -eq $document -or $document -isnot [psobject]) { return }
    # An unrelated but perfectly valid JSON file at a candidate name simply has
    # no hooks object - that is a clean no-op, not a warning.
    $hooksProperty = $document.PSObject.Properties['hooks']
    if ($null -eq $hooksProperty -or $null -eq $hooksProperty.Value) { return }
    $hooksObject = $hooksProperty.Value
    if ($hooksObject -isnot [psobject] -or $hooksObject -is [System.Collections.IEnumerable]) { return }

    $scopeInfo = Get-SettingsScopeInfo -SettingsPath $SettingsPath
    $canonicalSettings = Get-CanonicalPathOrEmpty $SettingsPath

    foreach ($eventProperty in @($hooksObject.PSObject.Properties)) {
        $eventName = [string]$eventProperty.Name
        $groups = $eventProperty.Value
        if ($null -eq $groups) { continue }
        foreach ($group in @($groups)) {
            if ($null -eq $group -or $group -isnot [psobject]) { continue }
            $handlersProperty = $group.PSObject.Properties['hooks']
            if ($null -eq $handlersProperty -or $null -eq $handlersProperty.Value) { continue }
            $matcherFingerprint = ''
            try { $matcherFingerprint = Get-MatcherFingerprint -Group $group } catch { }
            foreach ($handler in @($handlersProperty.Value)) {
                if ($null -eq $handler -or $handler -isnot [psobject]) { continue }
                $finding = New-RegistrationFinding -Client $Client -SettingsPath $canonicalSettings `
                    -Scope $scopeInfo.Scope -ProjectRoot $scopeInfo.ProjectRoot `
                    -EventName $eventName -Group $group -MatcherFingerprint $matcherFingerprint -Handler $handler
                if ($null -ne $finding) { [void]$script:RegistrationFindings.Add($finding) }
            }
        }
    }
}

function New-RegistrationFinding {
    param(
        [string]$Client, [string]$SettingsPath, [string]$Scope, [string]$ProjectRoot,
        [string]$EventName, $Group, [string]$MatcherFingerprint, $Handler
    )
    $handlerFingerprint = ''
    try { $handlerFingerprint = Get-HandlerFingerprint -Handler $Handler }
    catch {
        Add-ScanWarning ('a handler in ' + $SettingsPath + ' could not be fingerprinted and was skipped')
        return $null
    }
    $handlerType = ''
    if ($null -ne $Handler.PSObject.Properties['type'] -and $null -ne $Handler.type) { $handlerType = [string]$Handler.type }

    $agreement = Get-HandlerTargetAgreement -Handler $Handler
    $fieldNames = @($agreement.FieldNames)
    $parsedTargets = @($agreement.ParsedTargets)

    # Which of the four contract statuses this handler is in. "Cannot be proven"
    # is a first-class outcome, not an error: such a registration is still an
    # installed hook, it just cannot be removed automatically.
    $registrationStatus = 'parsed'
    $targetExists = $false
    if ($fieldNames.Count -eq 0 -or -not $agreement.AnyParsed) {
        $registrationStatus = 'unparsedCommand'
    }
    elseif (-not $agreement.AllAgree) {
        # Covers both "the fields name different targets" and "one field parsed,
        # another did not" - in either case the fields do not agree, so removing
        # the registration could silence something the other field pointed at.
        $registrationStatus = 'fieldsDisagree'
    }
    else {
        $targetExists = (Test-Path -LiteralPath $parsedTargets[0] -PathType Leaf)
        if (-not $targetExists) { $registrationStatus = 'targetMissing' }
    }

    # Ownership: proven Hook Maker path shape, provably something else, or -
    # when nothing could be parsed - honestly unknown.
    $managedBy = 'unknown'
    $hookMakerName = ''
    if ($agreement.AnyParsed) {
        $managedBy = 'external'
        foreach ($field in @(Get-DiscoveryCommandFields -Handler $Handler)) {
            $info = $null
            try { $info = Get-HookMakerCommandInfo -Command $field.Value -KnownToolRoots @(Get-KnownToolRoots -ToolRoot $ToolRoot) }
            catch { continue }
            if ($null -ne $info -and $info.IsHookMaker) { $managedBy = 'hookMaker'; $hookMakerName = [string]$info.HookName; break }
        }
    }

    return [pscustomobject]@{
        Client             = $Client
        SettingsPath       = $SettingsPath
        Scope              = $Scope
        ProjectRoot        = $ProjectRoot
        EventName          = $EventName
        HandlerFingerprint = $handlerFingerprint
        MatcherFingerprint = $MatcherFingerprint
        HandlerType        = $handlerType
        CommandFieldNames  = $fieldNames
        ParsedTargets      = $parsedTargets
        RegistrationStatus = $registrationStatus
        TargetExists       = $targetExists
        ManagedBy          = $managedBy
        HookMakerName      = $hookMakerName
    }
}

# ---- native Git discovery --------------------------------------------------

# `git config --get` with an argument ARRAY (never a shell string, so nothing in
# a repository path can be interpolated), a bounded timeout, and a clean
# fallback when git is absent. `git config` cannot run a hook.
$script:GitExecutable = $null
$script:GitProbed = $false
function Get-GitExecutable {
    if (-not $script:GitProbed) {
        $script:GitProbed = $true
        try {
            $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) { $script:GitExecutable = [string]$command.Source }
        }
        catch { $script:GitExecutable = $null }
    }
    return $script:GitExecutable
}

function Get-GitConfigValue {
    param([string]$RepositoryRoot, [string]$Name, [int]$TimeoutMs = 5000)
    $executable = Get-GitExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) { return '' }
    $process = $null
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $executable
        foreach ($argument in @('-C', $RepositoryRoot, 'config', '--get', $Name)) { [void]$info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        [void]$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill($true) } catch { }
            Add-ScanWarning ('git config timed out for repository: ' + $RepositoryRoot)
            return ''
        }
        if ($process.ExitCode -ne 0) { return '' }
        return ([string]$stdout.Result).Trim()
    }
    catch {
        Add-ScanWarning ('git could not be queried for ' + $RepositoryRoot + ': ' + $_.Exception.Message)
        return ''
    }
    finally { if ($null -ne $process) { try { $process.Dispose() } catch { } } }
}

# Fallback when git is unavailable: read core.hooksPath straight out of the
# repository's own config file. Deliberately a narrow INI read of one known key,
# not a general config parser.
function Get-HooksPathFromConfigFile {
    param([string]$GitDirectory)
    $configPath = Join-Path $GitDirectory 'config'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return '' }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) }
    catch { return '' }
    $inCore = $false
    foreach ($line in ($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[')) { $inCore = ($trimmed -match '^\[core(\s|\])'); continue }
        if (-not $inCore) { continue }
        $match = [regex]::Match($trimmed, '^hooksPath\s*=\s*(.+)$', 'IgnoreCase')
        if ($match.Success) { return $match.Groups[1].Value.Trim().Trim('"') }
    }
    return ''
}

# `.git` may be a directory OR a file containing `gitdir: <path>` (worktrees and
# submodules). Both are real repositories and both must be discovered.
function Resolve-GitDirectory {
    param([string]$RepositoryRoot)
    $dotGit = Join-Path $RepositoryRoot '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) { return (Get-CanonicalPathOrEmpty $dotGit) }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { return '' }
    $text = ''
    try {
        $item = Get-Item -LiteralPath $dotGit -Force -ErrorAction Stop
        # A `.git` pointer file is a single short line; anything larger is not
        # one and is not opened as text.
        if ($item.Length -gt 8192) { return '' }
        $text = [System.IO.File]::ReadAllText($dotGit, [System.Text.Encoding]::UTF8)
    }
    catch { return '' }
    $match = [regex]::Match($text, '(?im)^\s*gitdir\s*:\s*(.+?)\s*$')
    if (-not $match.Success) { return '' }
    $target = $match.Groups[1].Value.Trim()
    if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $RepositoryRoot $target }
    return (Get-CanonicalPathOrEmpty $target)
}

# Classify ONE native hook file.
#
# A Hook Maker wrapper is only claimed when the canonical generator REBUILDS the
# exact file from the stage list read back out of it - a marker line alone is
# not proof, because a tampered or hand-edited wrapper still carries the marker.
# That is why managedStages is populated only on an exact rebuild match.
function Get-NativeHookClassification {
    param([string]$HookPath)
    $result = [pscustomobject]@{ Classification = 'externalNativeHook'; ManagedStages = @() }
    $text = ''
    try {
        $item = Get-Item -LiteralPath $HookPath -Force -ErrorAction Stop
        if ($item.Length -gt 262144) { return $result }
        $text = [System.IO.File]::ReadAllText($HookPath, [System.Text.Encoding]::UTF8)
    }
    catch {
        $result.Classification = 'ambiguous'
        return $result
    }
    if ($text -notlike ('*' + $script:PrePushMarker + '*')) { return $result }

    $stages = @([regex]::Matches($text, '-File\s+"([^"]+)"\s+-GitPrePush') | ForEach-Object { $_.Groups[1].Value })
    if ($stages.Count -eq 0) {
        $result.Classification = 'ambiguous'
        return $result
    }
    $expected = ''
    try { $expected = New-PrePushWrapperBody -ManagedScripts $stages } catch { $expected = '' }
    if ($expected -ne '' -and (Compare-PrePushWrapperBody -Expected $expected -Actual $text)) {
        $result.Classification = 'hookMakerWrapper'
        $result.ManagedStages = @($stages | ForEach-Object { Get-CanonicalPathOrEmpty ($_.Replace('/', '\')) } | Where-Object { $_ -ne '' })
        return $result
    }
    # Marker present but the bytes are not what this generator produces: the
    # wrapper was edited or is from another writer. Reported, never claimed.
    $result.Classification = 'ambiguous'
    return $result
}

function Read-GitRepository {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $canonicalRoot = Get-CanonicalPathOrEmpty $RepositoryRoot
    if ($canonicalRoot -eq '') { return }
    $key = Get-CanonicalPathKey $canonicalRoot
    if ($key -eq '' -or -not $script:SeenGitKeys.Add($key)) { return }
    $gitDirectory = Resolve-GitDirectory -RepositoryRoot $canonicalRoot
    if ($gitDirectory -eq '') { return }
    $script:GitRepositoriesSeen++
    $script:CandidateRootsSeen++

    $hooksPath = ''
    $configured = Get-GitConfigValue -RepositoryRoot $canonicalRoot -Name 'core.hooksPath'
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = Get-HooksPathFromConfigFile -GitDirectory $gitDirectory }
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $candidate = $configured
        if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $canonicalRoot $candidate }
        $hooksPath = Get-CanonicalPathOrEmpty $candidate
        if ($hooksPath -eq '') { Add-ScanWarning ('core.hooksPath could not be resolved for ' + $canonicalRoot) }
    }
    if ($hooksPath -eq '') { $hooksPath = Get-CanonicalPathOrEmpty (Join-Path $gitDirectory 'hooks') }
    if ($hooksPath -eq '' -or -not (Test-Path -LiteralPath $hooksPath -PathType Container)) { return }
    if (Test-IsReparsePoint -Path $hooksPath) {
        [void]$script:SkippedReparse.Add($hooksPath)
        return
    }

    $entries = @()
    try { $entries = @((New-Object System.IO.DirectoryInfo $hooksPath).EnumerateFiles()) }
    catch {
        [void]$script:Inaccessible.Add($hooksPath)
        Add-ScanWarning ('git hooks directory could not be listed: ' + $hooksPath)
        return
    }
    foreach ($entry in $entries) {
        # `*.sample` files are git's shipped examples: never installed, never
        # executed, and reporting them would bury the real hooks in noise.
        if ($entry.Name -like '*.sample') { continue }
        $classification = Get-NativeHookClassification -HookPath $entry.FullName
        [void]$script:NativeFindings.Add([pscustomobject]@{
            RepositoryRoot  = $canonicalRoot
            HooksPath       = $hooksPath
            HookName        = $entry.Name
            HookPath        = (Get-CanonicalPathOrEmpty $entry.FullName)
            HookHash        = (Get-FileSha256Hex -Path $entry.FullName)
            HookSize        = [int64]$entry.Length
            HookModifiedUtc = $entry.LastWriteTimeUtc.ToString('o')
            Classification  = $classification.Classification
            ManagedStages   = @($classification.ManagedStages)
        })
    }
}

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
    if (Test-IsReparsePoint -Path $canonicalRoot) {
        # The root itself being a reparse point is recorded but still walked:
        # the user named it explicitly, so there is no ambiguity about intent.
        [void]$script:SkippedReparse.Add($canonicalRoot)
    }

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
        try { $parentName = (New-Object System.IO.DirectoryInfo $current.Path).Name } catch { }

        foreach ($entry in $entries) {
            if ($script:Canceled) { return }
            $isDirectory = (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -eq [System.IO.FileAttributes]::Directory)
            if ($isDirectory) {
                if ($entry.Name -eq '.git') {
                    # A repository, not a folder to descend into: git's object
                    # store is large, contains nothing registrable, and its
                    # hooks directory is reached by path below.
                    Read-GitRepository -RepositoryRoot $current.Path
                    continue
                }
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
# `.claude` / `.codex` / `.git` component in -ScanRoot marks the tree the user
# pointed inside, and its parent is that tree's project root. Only that one
# directory is inspected, and only at its known settings/git locations - no
# ancestor is ever enumerated.
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
    if (Test-Path -LiteralPath (Join-Path $contextRoot '.git')) { Read-GitRepository -RepositoryRoot $contextRoot }
}

# ---- grouping into logical records -----------------------------------------

# Stable ids (Get-DiscoveredRecordId) and rescan/merge semantics
# (Merge-DiscoveredRecord, Test-DiscoveredRecordValid) come from
# _installregistry.ps1 via _installlib.ps1. This file never reimplements them -
# the registry layer is the single authority on what a discovered record is.

function Get-RegistrationFriendlyName {
    param($Findings)
    foreach ($finding in @($Findings)) {
        if (-not [string]::IsNullOrWhiteSpace($finding.HookMakerName)) { return [string]$finding.HookMakerName }
    }
    foreach ($finding in @($Findings)) {
        if (@($finding.ParsedTargets).Count -gt 0) {
            return [System.IO.Path]::GetFileNameWithoutExtension([string]@($finding.ParsedTargets)[0])
        }
    }
    $first = @($Findings)[0]
    return ([string]$first.Client + ' ' + [string]$first.EventName + ' handler')
}

# Groups per-handler findings into logical records.
#
# The grouping key is the PROVEN runtime identity, never a name:
#   * when every command field agrees on a target, the key is that canonical
#     path (so several events - and Claude+Codex together - collapse into one
#     record only because they provably run the same file);
#   * when no target can be proven, the key falls back to the handler
#     fingerprint AND the client/settings file, so two unprovable handlers can
#     never be merged across clients on a coincidence.
function Group-RegistrationFindings {
    # A plain hashtable plus an explicit key list: [ordered] would give the same
    # ordering, but its indexer is overloaded on both int and object and
    # PowerShell can bind the wrong one for a string key.
    $groups = @{}
    $order = New-Object System.Collections.Generic.List[string]
    # .ToArray() rather than @(...): PowerShell 7.6 throws "Argument types do
    # not match" when the array subexpression operator is applied directly to a
    # List[object]. Every List[object] in this file is unwrapped the same way.
    foreach ($finding in $script:RegistrationFindings.ToArray()) {
        $runtimeKey = ''
        if ($finding.RegistrationStatus -eq 'parsed' -or $finding.RegistrationStatus -eq 'targetMissing') {
            $runtimeKey = 'target:' + (Get-CanonicalPathKey @($finding.ParsedTargets)[0])
        }
        else {
            $runtimeKey = 'fp:' + $finding.HandlerFingerprint + '|' + $finding.Client + '|' + (Get-CanonicalPathKey $finding.SettingsPath)
        }
        $key = [string]$finding.Scope + '|' + (Get-CanonicalPathKey $finding.ProjectRoot) + '|' + $runtimeKey
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.Generic.List[object]
            [void]$order.Add($key)
        }
        [void]$groups[$key].Add($finding)
    }
    return [pscustomobject]@{ Map = $groups; Order = @($order.ToArray()) }
}

function New-ClientEvidence {
    param([string]$Client, $Findings)
    $first = @($Findings)[0]
    $statuses = @(@($Findings) | ForEach-Object { [string]$_.RegistrationStatus } | Sort-Object -Unique)
    # The worst status wins: a record must never look healthier than its least
    # provable handler.
    $status = 'parsed'
    foreach ($candidate in @('fieldsDisagree', 'unparsedCommand', 'targetMissing', 'parsed')) {
        if ($statuses -contains $candidate) { $status = $candidate; break }
    }
    return [pscustomobject][ordered]@{
        client              = $Client
        settingsPath        = [string]$first.SettingsPath
        events              = @(@($Findings) | ForEach-Object { [string]$_.EventName } | Sort-Object -Unique)
        handlerFingerprints = @(@($Findings) | ForEach-Object { [string]$_.HandlerFingerprint } | Sort-Object -Unique)
        matcherFingerprints = @(@($Findings) | ForEach-Object { [string]$_.MatcherFingerprint } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        handlerTypes        = @(@($Findings) | ForEach-Object { [string]$_.HandlerType } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        commandFieldNames   = @(@($Findings) | ForEach-Object { @($_.CommandFieldNames) } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        parsedTargets       = @(@($Findings) | ForEach-Object { @($_.ParsedTargets) } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        registrationStatus  = $status
    }
}

function Build-RegistrationRecords {
    $records = New-Object System.Collections.Generic.List[object]
    $now = [DateTime]::UtcNow.ToString('o')
    $groups = Group-RegistrationFindings
    foreach ($key in @($groups.Order)) {
        $findings = @($groups.Map[$key].ToArray())
        $first = $findings[0]
        $clients = @(@($findings) | ForEach-Object { [string]$_.Client } | Sort-Object -Unique)
        $clientEvidence = @()
        foreach ($client in $clients) {
            $clientEvidence += (New-ClientEvidence -Client $client -Findings @(@($findings) | Where-Object { [string]$_.Client -eq $client }))
        }
        $settingsPaths = @(@($clientEvidence) | ForEach-Object { [string]$_.settingsPath } | Sort-Object -Unique)
        $handlerFingerprints = @(@($findings) | ForEach-Object { [string]$_.HandlerFingerprint } | Sort-Object -Unique)

        $statuses = @(@($clientEvidence) | ForEach-Object { [string]$_.registrationStatus })
        $status = 'active'
        $statusReason = 'registration and target verified'
        $removalPolicy = 'full'
        $needsManualRepair = $false
        if ($statuses -contains 'fieldsDisagree') {
            $status = 'ambiguous'
            $statusReason = 'command fields disagree on the target; automatic removal is unsafe'
            $removalPolicy = 'unavailable'
            $needsManualRepair = $true
        }
        elseif ($statuses -contains 'unparsedCommand') {
            $status = 'registrationOnly'
            $statusReason = 'the command could not be parsed to a target; only the registration can be removed'
            $removalPolicy = 'registrationOnly'
        }
        elseif ($statuses -contains 'targetMissing') {
            $status = 'missingTarget'
            $statusReason = 'the registered target file does not exist'
            $removalPolicy = 'registrationOnly'
        }

        $managedBy = 'unknown'
        if (@(@($findings) | Where-Object { [string]$_.ManagedBy -eq 'hookMaker' }).Count -gt 0) { $managedBy = 'hookMaker' }
        elseif (@(@($findings) | Where-Object { [string]$_.ManagedBy -eq 'external' }).Count -gt 0) { $managedBy = 'external' }

        $id = Get-DiscoveredRecordId -Kind 'registration' -Scope ([string]$first.Scope) `
            -TargetProjectRoot ([string]$first.ProjectRoot) -Client ($clients -join ',') `
            -SettingsPath ($settingsPaths -join ',') -HandlerFingerprints $handlerFingerprints

        [void]$records.Add([pscustomobject][ordered]@{
            id                = $id
            schema            = $script:InstallRegistrySchemaVersion
            recordType        = 'discovered'
            origin            = 'statusScan'
            friendlyName      = (Get-RegistrationFriendlyName -Findings $findings)
            hookType          = $(if ($clients.Count -eq 1 -and $clients[0] -eq 'codex') { 'CodexRegistration' } else { 'ClaudeRegistration' })
            scope             = [string]$first.Scope
            targetProjectRoot = [string]$first.ProjectRoot
            firstSeenUtc      = $now
            lastSeenUtc       = $now
            lastScanId        = $script:ScanId
            scanRoots         = @($script:ScanRoots.ToArray())
            status            = $status
            statusReason      = $statusReason
            managedBy         = $managedBy
            clients           = @($clientEvidence)
            nativeGit         = $null
            runtimeArtifacts  = @()
            removalPolicy     = $removalPolicy
            needsManualRepair = $needsManualRepair
        })
    }
    return $records.ToArray()
}

function Build-NativeRecords {
    $records = New-Object System.Collections.Generic.List[object]
    $now = [DateTime]::UtcNow.ToString('o')
    foreach ($finding in $script:NativeFindings.ToArray()) {
        $status = 'active'
        $statusReason = 'native git hook present'
        $removalPolicy = 'unavailable'
        $needsManualRepair = $false
        $managedBy = 'external'
        if ($finding.Classification -eq 'hookMakerWrapper') {
            $managedBy = 'hookMaker'
            $removalPolicy = 'nativeFileOnly'
            $statusReason = 'Hook Maker managed wrapper, verified byte-for-byte'
        }
        elseif ($finding.Classification -eq 'ambiguous') {
            $status = 'manualRepair'
            $managedBy = 'unknown'
            $statusReason = 'carries the Hook Maker marker but does not match the canonical wrapper; left untouched'
            $needsManualRepair = $true
        }
        [void]$records.Add([pscustomobject][ordered]@{
            id                = (Get-DiscoveredRecordId -Kind 'native' -RepositoryRoot $finding.RepositoryRoot -HookPath $finding.HookPath -HookName $finding.HookName)
            schema            = $script:InstallRegistrySchemaVersion
            recordType        = 'discovered'
            origin            = 'statusScan'
            friendlyName      = ([string]$finding.HookName + ' (' + (Split-Path -Leaf $finding.RepositoryRoot) + ')')
            hookType          = 'NativeGitHook'
            scope             = 'project'
            targetProjectRoot = [string]$finding.RepositoryRoot
            firstSeenUtc      = $now
            lastSeenUtc       = $now
            lastScanId        = $script:ScanId
            scanRoots         = @($script:ScanRoots.ToArray())
            status            = $status
            statusReason      = $statusReason
            managedBy         = $managedBy
            clients           = @()
            nativeGit         = [pscustomobject][ordered]@{
                repositoryRoot  = [string]$finding.RepositoryRoot
                hooksPath       = [string]$finding.HooksPath
                hookName        = [string]$finding.HookName
                hookPath        = [string]$finding.HookPath
                hookHash        = [string]$finding.HookHash
                hookSize        = [int64]$finding.HookSize
                hookModifiedUtc = [string]$finding.HookModifiedUtc
                classification  = [string]$finding.Classification
                managedStages   = @($finding.ManagedStages)
            }
            runtimeArtifacts  = @()
            removalPolicy     = $removalPolicy
            needsManualRepair = $needsManualRepair
        })
    }
    return $records.ToArray()
}

# Runtime artifacts are computed AFTER every record exists, because
# "is this file shared?" is only answerable across the whole result set - and a
# shared runtime is exactly the case where deleting it would break another hook.
function Add-RuntimeArtifacts {
    param($Records)

    $referenceMap = @{}
    foreach ($record in @($Records)) {
        foreach ($client in @($record.clients)) {
            foreach ($target in @($client.parsedTargets)) {
                $key = Get-CanonicalPathKey $target
                if ($key -eq '') { continue }
                if (-not $referenceMap.ContainsKey($key)) { $referenceMap[$key] = New-Object System.Collections.Generic.List[string] }
                if (-not $referenceMap[$key].Contains([string]$record.id)) { [void]$referenceMap[$key].Add([string]$record.id) }
            }
        }
        if ($null -ne $record.nativeGit) {
            foreach ($stage in @($record.nativeGit.managedStages)) {
                $key = Get-CanonicalPathKey $stage
                if ($key -eq '') { continue }
                if (-not $referenceMap.ContainsKey($key)) { $referenceMap[$key] = New-Object System.Collections.Generic.List[string] }
                if (-not $referenceMap[$key].Contains([string]$record.id)) { [void]$referenceMap[$key].Add([string]$record.id) }
            }
        }
    }

    foreach ($record in @($Records)) {
        $artifacts = New-Object System.Collections.Generic.List[object]
        $paths = New-Object System.Collections.Generic.List[object]
        foreach ($client in @($record.clients)) {
            # 'entrypoint' is a CONTRACT literal, not a label: together with
            # classification 'registeredRuntime' it is the only combination
            # Uninstall-DiscoveredHook.ps1 will ever auto-delete. Anything that
            # must never be auto-deleted therefore carries a different kind.
            foreach ($target in @($client.parsedTargets)) { [void]$paths.Add([pscustomobject]@{ Path = $target; Kind = 'entrypoint' }) }
        }
        if ($null -ne $record.nativeGit) {
            [void]$paths.Add([pscustomobject]@{ Path = [string]$record.nativeGit.hookPath; Kind = 'entrypoint' })
            foreach ($stage in @($record.nativeGit.managedStages)) { [void]$paths.Add([pscustomobject]@{ Path = $stage; Kind = 'nativeStage' }) }
        }
        # A record with no provable target simply has no artifacts: an artifact
        # entry needs a real canonical path, and inventing an empty one would be
        # a fabricated location. The 'registrationOnly' status already says it.
        $seen = New-Object System.Collections.Generic.HashSet[string]
        foreach ($entry in $paths) {
            $key = Get-CanonicalPathKey $entry.Path
            if ($key -eq '' -or -not $seen.Add($key)) { continue }
            $exists = (Test-Path -LiteralPath $entry.Path -PathType Leaf)
            $referencedBy = @()
            if ($referenceMap.ContainsKey($key)) { $referencedBy = @($referenceMap[$key].ToArray()) }
            if ($referencedBy.Count -eq 0) { $referencedBy = @([string]$record.id) }
            $size = 0
            if ($exists) { try { $size = [int64](New-Object System.IO.FileInfo $entry.Path).Length } catch { $size = 0 } }

            $classification = 'registeredRuntime'
            $eligibility = 'eligible'
            $reason = 'referenced only by this record'
            if (-not $exists) {
                $classification = 'missingTarget'; $eligibility = 'preserve'; $reason = 'target file does not exist'
            }
            elseif ($referencedBy.Count -gt 1) {
                $classification = 'sharedRuntime'; $eligibility = 'preserve'; $reason = 'shared with another discovered hook'
            }
            elseif ([string]$record.status -eq 'ambiguous' -or [string]$record.status -eq 'manualRepair') {
                $classification = 'ambiguous'; $eligibility = 'preserve'; $reason = 'record identity is not fully proven'
            }
            elseif ($entry.Kind -eq 'nativeStage') {
                # A stage script is Hook Maker's own installed hook runtime and
                # is owned by ITS record, not by the native wrapper's.
                $classification = 'sharedRuntime'; $eligibility = 'preserve'; $reason = 'stage script is owned by its own hook record'
            }
            [void]$artifacts.Add([pscustomobject][ordered]@{
                path = [string]$entry.Path
                kind = [string]$entry.Kind
                hash = $(if ($exists) { Get-FileSha256Hex -Path $entry.Path } else { '' })
                size = $size
                classification = $classification
                referencedBy = @($referencedBy)
                deleteEligibility = $eligibility
                deleteReason = $reason
            })
        }
        # Only a REGISTRATION record can be demoted for a shared runtime. A
        # native record always references its own stage scripts (which belong to
        # their own hook records), so applying this to it would wrongly downgrade
        # every verified managed wrapper.
        if (@($record.clients).Count -gt 0 -and $artifacts.Count -gt 0 -and
            @($artifacts | Where-Object { $_.classification -eq 'sharedRuntime' }).Count -gt 0 -and
            [string]$record.status -eq 'active') {
            Set-ObjectProperty -Object $record -Name 'status' -Value 'sharedRuntime'
            Set-ObjectProperty -Object $record -Name 'statusReason' -Value 'the registered runtime is shared with another discovered hook'
            Set-ObjectProperty -Object $record -Name 'removalPolicy' -Value 'registrationOnly'
        }
        Set-ObjectProperty -Object $record -Name 'runtimeArtifacts' -Value @($artifacts.ToArray())
    }
    return $Records
}

# ---- persistence -----------------------------------------------------------

# Was this record's evidence location actually COVERED by this scan? Only a
# covered-and-readable location may be demoted to 'notSeen' - anything under an
# inaccessible or reparse-skipped subtree, or outside the roots entirely, is
# left exactly as it was, because absence of evidence here is not evidence of
# absence.
function Test-RecordCoveredByScan {
    param($Record, [string[]]$Roots)
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($client in @($Record.clients)) {
            if ($null -ne $client -and $null -ne $client.PSObject.Properties['settingsPath']) { [void]$paths.Add([string]$client.settingsPath) }
        }
        if ($null -ne $Record.PSObject.Properties['nativeGit'] -and $null -ne $Record.nativeGit -and
            $null -ne $Record.nativeGit.PSObject.Properties['hookPath']) {
            [void]$paths.Add([string]$Record.nativeGit.hookPath)
        }
    }
    catch { return $false }
    if ($paths.Count -eq 0) { return $false }
    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        if (-not (Test-PathUnderAny -Path $path -Parents $Roots)) { return $false }
        if (Test-PathUnderAny -Path $path -Parents @($script:Inaccessible.ToArray())) { return $false }
        if (Test-PathUnderAny -Path $path -Parents @($script:SkippedReparse.ToArray())) { return $false }
    }
    return $true
}

function Save-DiscoveredRecords {
    param($Records, [bool]$CoverageComplete)

    Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $state = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($state.State -eq 'corrupt') {
            # A corrupt registry can never be safely rewritten - its managed
            # records could be destroyed. Report and touch nothing.
            Add-ScanWarning ('the install registry is unreadable (' + [string]$state.Reason + '); no scan results were persisted')
            return
        }
        $registry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry

        # Every write goes through the registry layer's own merge, which owns
        # the rules this scanner must not second-guess: shape validation,
        # firstSeenUtc carry-forward, refusing to duplicate a hook a managed
        # install already accounts for, and refusing a notSeen claim from a scan
        # that did not actually cover everything.
        $incomingIds = New-Object System.Collections.Generic.HashSet[string]
        foreach ($record in @($Records)) {
            [void]$incomingIds.Add([string]$record.id)
            $outcome = Merge-DiscoveredRecord -Registry $registry -Record $record -CoverageComplete:$CoverageComplete
            switch ([string]$outcome.Action) {
                'added' { $script:RecordsAdded++ }
                'updated' { $script:RecordsUpdated++ }
                'coveredByManaged' { $script:RecordsMatched++ }
                default { Add-ScanWarning ('a finding was not recorded: ' + [string]$outcome.Reason) }
            }
        }

        # Demote only what this scan PROVABLY covered and did not find. The merge
        # rejects the claim outright when coverage was incomplete, so a partial
        # scan can never write a live hook off as gone.
        $roots = @($script:ScanRoots.ToArray())
        foreach ($record in @($registry.installs)) {
            if ($null -eq $record -or -not (Test-IsDiscoveredRecord -Record $record)) { continue }
            if ($incomingIds.Contains([string]$record.id)) { continue }
            if ([string]$record.status -eq 'notSeen') { continue }
            if (-not (Test-RecordCoveredByScan -Record $record -Roots $roots)) { continue }
            $demoted = $record.PSObject.Copy()
            Set-ObjectProperty -Object $demoted -Name 'status' -Value 'notSeen'
            Set-ObjectProperty -Object $demoted -Name 'statusReason' -Value 'covered by a later scan of the same roots but no longer present'
            Set-ObjectProperty -Object $demoted -Name 'lastScanId' -Value $script:ScanId
            Set-ObjectProperty -Object $demoted -Name 'lastSeenUtc' -Value ([DateTime]::UtcNow.ToString('o'))
            $outcome = Merge-DiscoveredRecord -Registry $registry -Record $demoted -CoverageComplete:$CoverageComplete
            if ([string]$outcome.Action -eq 'updated') { $script:RecordsUpdated++ }
        }

        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registry

        # Read-back verify: a write that cannot be read back as a valid registry
        # is a failed write, not a successful one.
        $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($verify.State -ne 'ok') {
            throw ('registry read-back verification failed: ' + [string]$verify.Reason)
        }
        $script:Persisted = $true
    }
}

# ---- main ------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ScanRoot)) { $ScanRoot = (Get-Location).Path }
$ScanRoot = Get-CanonicalPathOrEmpty $ScanRoot
if ($ScanRoot -eq '' -or -not (Test-Path -LiteralPath $ScanRoot -PathType Container)) {
    throw ('-ScanRoot is not an existing directory: ' + $ScanRoot)
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

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $resultCanonical = Get-CanonicalPathOrEmpty $ResultPath
    if ($resultCanonical -ne '' -and (Test-PathContainedIn -ChildPath $resultCanonical -ParentPath $ScanRoot)) {
        Add-ScanWarning 'the result document was written inside the scanned root, at the caller''s explicit request'
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
