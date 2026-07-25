# ---------------------------------------------------------------------------
# Discovery half of the hook-status scan engine. Dot-sourced by
# Get-HookStatus.ps1 ONLY - it runs in that script's scope, so every
# $script: state variable (Warnings, Inaccessible, SkippedReparse,
# RegistrationFindings, NativeFindings, counters, ...) and every helper it
# calls (Add-ScanWarning, Show-ScanProgress, and the record builders in
# _hookstatusrecords.ps1) resolve at CALL time, once the whole engine and its
# libraries are loaded and only "main" is executing. Do not dot-source this
# file directly, and it must not dot-source anything itself.
#
# Responsibility: turn a filesystem location into raw findings - Claude/Codex
# settings registrations and native Git hooks - via settings parsing, git/
# native discovery, and the directory walk itself. See _hookstatusrecords.ps1
# for turning those findings into verified logical records.
# ---------------------------------------------------------------------------
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
        try { $parentName = (New-Object System.IO.DirectoryInfo $current.Path).Name } catch { }

        foreach ($entry in $entries) {
            if ($script:Canceled) { return }
            $isDirectory = (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -eq [System.IO.FileAttributes]::Directory)
            if ($isDirectory) {
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
# context at all. It resolves the same project root the other two do, and the
# leaves read below are unchanged. Kiro's OWN registrations are not read here:
# it is a perHookFile client (one JSON per install under `.kiro\hooks`), which
# this scanner's known-name/known-position settings parser does not cover.
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
        if ($segments[$i] -eq '.claude' -or $segments[$i] -eq '.codex' -or $segments[$i] -eq '.kiro' -or $segments[$i] -eq '.git') { $markerIndex = $i; break }
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
