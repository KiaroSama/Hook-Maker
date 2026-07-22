# Shared helpers for Hook Maker's shipped hooks. Each hook dot-sources this
# once ( . (Join-Path $PSScriptRoot '..\_hooklib.ps1') ) so the identical
# stdin / .env / hash / JSON boilerplate lives in exactly one place. The
# underscore prefix keeps it out of the wizard's hook discovery
# (Get-HookEntries skips '_'-prefixed names). StrictMode 2.0 clean; every
# function is self-contained so it works from any host or scope.

# Field accessor tolerant of a missing property or a $null value.
function Get-Field {
    param($Obj, [string]$Name)
    if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) {
        return $Obj.$Name
    }
    return $null
}

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $full = [System.IO.Path]::GetFullPath($expanded)
    return $full.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $candidatePath = Normalize-Path $Candidate
    $parentPath = Normalize-Path $Parent
    if ([string]::Equals($candidatePath, $parentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $parentPath + [System.IO.Path]::DirectorySeparatorChar
    return $candidatePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

# Reads the hook event JSON from stdin. Returns the parsed object, or $null on
# empty / non-JSON input (the caller then exits silently).
function Read-HookInput {
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return ($raw | ConvertFrom-Json)
        }
    }
    catch { }
    return $null
}

# Parses a KEY=VALUE .env file ('#' comments allowed). Returns a hashtable;
# empty when the file is absent or blank.
function Read-HookEnv {
    param([string]$Path)
    $values = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -gt 0) {
            $values[$trimmed.Substring(0, $separator).Trim()] = $trimmed.Substring($separator + 1).Trim()
        }
    }
    return $values
}

# 10-char lowercase hex SHA-256 prefix — stable per-project state file keys.
function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally {
        $sha.Dispose()
    }
}

# Reads a JSON file into an object, or $null when absent / blank.
function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

# Writes an object as UTF-8 (no BOM) JSON via a temp file + atomic move.
function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = $Path + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

# ---- HM-07: bounded rolling test-timing history (READ side) -----------------
# Samples live ONLY in local Hook-Maker state (%LOCALAPPDATA%\HookMaker\state),
# one file per (canonical project key + command/suite fingerprint), never in the
# project. Each sample is sanitized: runId, elapsed seconds, outcome, UTC, the
# effective worker ceiling and an optional safe suite label - never an argument,
# path, prompt, secret, user name or token. The standalone guarded runner WRITES
# them (Run-Tests-Guarded.ps1); these helpers READ them so Test-Plan-Check can
# surface a baseline and Test-Completion-Check can report a meaningful regression.
# The WRITER mirrors TimingMaxSamples exactly - keep the two in lockstep.
$script:TimingMaxSamples = 30
$script:TimingMinBaseline = 5        # this many COMPARABLE ok runs before judging
$script:TimingRelFactor = 1.5        # >= 50% slower than the median, AND ...
$script:TimingAbsSeconds = 30        # ... >= 30s slower in absolute terms

function Get-TimingHistoryPath {
    param([string]$StateDir, [string]$ProjectKey, [string]$CommandFingerprint)
    return (Join-Path $StateDir ('TestTiming-' + $ProjectKey + '-' + $CommandFingerprint + '.json'))
}

# The ok-only, worker-comparable elapsed samples. A run taken with a DIFFERENT
# worker ceiling is not comparable (more workers => faster), so a worker-count
# change yields too few comparable samples rather than a false regression.
function Get-ComparableOkSeconds {
    param($History, [int]$WorkerCeiling, [string]$ExcludeRunId = '')
    $out = New-Object System.Collections.Generic.List[double]
    if ($null -eq $History -or -not $History.PSObject.Properties['samples']) { return $out }
    foreach ($s in @($History.samples)) {
        if ($null -eq $s) { continue }
        # The run being judged has already been recorded by the runner, so exclude
        # it: a run must be compared against PRIOR history, never against itself.
        if ($ExcludeRunId -ne '' -and ([string](Get-Field $s 'runId')) -eq $ExcludeRunId) { continue }
        if (([string](Get-Field $s 'outcome')) -ne 'ok') { continue }
        $wc = -1; [void][int]::TryParse([string](Get-Field $s 'workerCeiling'), [ref]$wc)
        if ($wc -ne $WorkerCeiling) { continue }
        $sec = 0.0
        if ([double]::TryParse([string](Get-Field $s 'elapsedSeconds'), [ref]$sec) -and $sec -ge 0) { [void]$out.Add($sec) }
    }
    return $out
}

function Get-Median {
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    $n = $v.Count
    if ($n -eq 0) { return 0.0 }
    if ($n % 2 -eq 1) { return [double]$v[($n - 1) / 2] }
    return ([double]$v[$n / 2 - 1] + [double]$v[$n / 2]) / 2.0
}

# A meaningful regression needs enough comparable ok history AND this run being
# both >= TimingRelFactor x and >= TimingAbsSeconds slower than the ROBUST median
# (so one earlier outlier neither redefines the baseline nor gets flagged). It is
# advisory by design - the caller decides how to surface it.
function Test-TimingRegression {
    param($History, [int]$WorkerCeiling, [double]$ElapsedSeconds, [string]$ExcludeRunId = '')
    # @() around the call: returning a List[double] unrolls to a bare double when it
    # holds one element, so re-wrap to a stable array before Count/Get-Median.
    $ok = @(Get-ComparableOkSeconds -History $History -WorkerCeiling $WorkerCeiling -ExcludeRunId $ExcludeRunId)
    $median = Get-Median -Values $ok
    $isReg = $false
    if ($ok.Count -ge $script:TimingMinBaseline -and $median -gt 0) {
        if ($ElapsedSeconds -ge ($median * $script:TimingRelFactor) -and ($ElapsedSeconds - $median) -ge $script:TimingAbsSeconds) { $isReg = $true }
    }
    return [pscustomobject]@{
        IsRegression   = $isReg
        Median         = [Math]::Round($median, 1)
        Samples        = $ok.Count
        ElapsedSeconds = [Math]::Round($ElapsedSeconds, 1)
        MinBaseline    = $script:TimingMinBaseline
    }
}

# Runs an external command (git, gh, ...) whose stderr must NEVER become a
# terminating error, even when the command exits non-zero. Windows PowerShell
# 5.1 promotes ANY stderr line from a native command into a NativeCommandError
# under $ErrorActionPreference='Stop' - and, verified empirically, `2>$null`,
# `2>&1 | Out-Null`, and `*>$null` all fail to prevent that promotion under 5.1
# (pwsh 7 is unaffected, which is why this only shows up against the real
# Claude client). Only relaxing $ErrorActionPreference around the call works.
# Returns stdout lines (redirecting stderr away); $LASTEXITCODE is left intact
# for the caller exactly as a raw `&` call would leave it.
function Invoke-QuietCommand {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$ArgumentList)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        return & $FilePath @ArgumentList 2>$null
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Get-GitHubRepository {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return $null }

    $remoteNames = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'remote') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $valid = @{}
    foreach ($remoteName in $remoteNames) {
        $url = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'remote', 'get-url', [string]$remoteName))
        if ($LASTEXITCODE -ne 0) { continue }
        if ($url -match '^(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$') {
            $valid[[string]$remoteName] = ($Matches[1] + '/' + $Matches[2])
        }
    }
    if ($valid.Count -eq 0) { return $null }

    $branchName = ''
    $branchRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', 'HEAD'))
    if ($LASTEXITCODE -eq 0 -and $branchRaw -ne '' -and $branchRaw -ne 'HEAD') { $branchName = $branchRaw }

    $branchRemote = ''
    if ($branchName -ne '') {
        $configuredRemote = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'config', '--get', ('branch.' + $branchName + '.remote')))
        if ($LASTEXITCODE -eq 0) { $branchRemote = $configuredRemote }
    }

    $selected = ''
    if ($branchRemote -ne '' -and $valid.ContainsKey($branchRemote)) { $selected = $branchRemote }
    if ($selected -eq '' -and $valid.ContainsKey('origin')) { $selected = 'origin' }
    if ($selected -eq '' -and $valid.Count -eq 1) { $selected = [string]@($valid.Keys)[0] }
    if ($selected -eq '') { return $null }

    # TrackingRef is the remote-tracking ref a caller may safely diff HEAD
    # against to decide "is HEAD pushed to the repository just selected". It is
    # populated ONLY when it is guaranteed to belong to $selected:
    # - the branch's own configured upstream, but only when that upstream's
    #   remote IS $selected (so @{upstream} cannot silently point at a
    #   different, possibly non-GitHub, remote than the repository resolved
    #   above); or
    # - a same-named remote-tracking branch under $selected, when the branch
    #   upstream doesn't match (or isn't configured at all).
    # Left empty when neither can be trusted - callers must then degrade
    # without claiming a pushed/verified state.
    $trackingRef = ''
    if ($branchName -ne '') {
        if ($branchRemote -eq $selected) {
            $upstreamRef = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', '@{upstream}'))
            if ($LASTEXITCODE -eq 0 -and $upstreamRef -ne '') { $trackingRef = $upstreamRef }
        }
        if ($trackingRef -eq '') {
            $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--verify', '--quiet', ('refs/remotes/' + $selected + '/' + $branchName))
            if ($LASTEXITCODE -eq 0) { $trackingRef = $selected + '/' + $branchName }
        }
    }

    return [pscustomobject]@{ Remote = $selected; Repository = [string]$valid[$selected]; Branch = $branchName; TrackingRef = $trackingRef }
}

# Deterministic per-project state fingerprint (HEAD sha + sorted status lines,
# hashed - never raw paths/content). Used to bind one hook's Stop-time result
# to the EXACT repository state another hook observes on a later Stop, so
# lifecycle hooks that fire concurrently on the same event (registration order
# is display-only, never execution order) can hand off state safely without
# racing: a consumer only trusts a producer's recorded state when this
# fingerprint still matches what the consumer observes right now.
function Get-RepoStateFingerprint {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return '' }
    $head = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) { return '' }
    $status = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain')) | Where-Object { $_ } | Sort-Object)
    return Get-ShortHash ($head + '|' + ($status -join '|'))
}

function Get-LatestWorkTimeUtc {
    param([string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return $null
    }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') {
        return $null
    }
    $latest = [DateTime]::MinValue
    $commitUnix = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'log', '-1', '--format=%ct')
    if ($LASTEXITCODE -eq 0 -and $commitUnix) {
        $latest = [DateTimeOffset]::FromUnixTimeSeconds([int64]([string]$commitUnix)).UtcDateTime
    }
    $status = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain')
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($status)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            $lineText = [string]$line
            # A rename/copy line is "XY old -> new" (X or Y = R/C) instead of "XY path" -
            # only the destination half exists on disk. Treating the raw "old -> new" text
            # as one literal path embeds the arrow's '>' via Join-Path below, and
            # Test-Path -LiteralPath then throws on PS 5.1 ('>' is an illegal path char).
            $code = $lineText.Substring(0, 2)
            $relative = $lineText.Substring(3)
            if ($code.Contains('R') -or $code.Contains('C')) {
                $arrowIndex = $relative.IndexOf(' -> ')
                if ($arrowIndex -ge 0) { $relative = $relative.Substring($arrowIndex + 4) }
            }
            $relative = $relative.Trim('"')
            if ($relative -like '.ai/*' -or $relative -like 'graphify-out/*' -or $relative -like 'logs/*') { continue }
            try {
                $full = Join-Path $ProjectRoot ($relative.Replace('/', '\'))
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $modified = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc
                    if ($modified -gt $latest) { $latest = $modified }
                }
            }
            catch { }
        }
    }
    if ($latest -eq [DateTime]::MinValue) {
        return $null
    }
    return $latest
}

# Friendly, hyphen-separated hook name. The shipped hook folders are already
# hyphenated (Cross-Project-.ai-Knowledge-Sync, Mcp-Usage-Check, ...), so this
# is a no-op for them; it still tidies a user's PascalCase custom-hook name
# (MyContextHook -> My-Context-Hook) for the menu + the installed copy folder.
function Get-HookFriendlyName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($Name, '([A-Z]+)([A-Z][a-z])', '$1-$2')
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($hyphenated, '([a-z0-9])([A-Z])', '$1-$2')
    return $hyphenated
}
