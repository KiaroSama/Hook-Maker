# Utf8-Encoding-Check - strict UTF-8 hygiene for text written by agents.
#
# ROLE: DETECTOR + GATE (global-hook-rules.md SS Hook Roles).
#   - It NEVER rewrites, transcodes, normalizes or otherwise mutates ANY file.
#     Detection and reporting only - fixing an encoding is always the agent's
#     own explicit, visible edit.
#   - Its only state lives under %LOCALAPPDATA%\HookMaker\state - never in the
#     project. The pre-push mode writes no state at all.
#
# Events: SessionStart, Stop (SubagentStop behaves exactly like Stop), plus a
# native git pre-push mode selected by the -GitPrePush switch - the SAME
# invocation contract as Secrets-Check.ps1: the managed pre-push wrapper runs
#   powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass
#     -File <this script> -GitPrePush   < <teed ref-update stdin>
# so the switch is this hook's ONLY parameter, cwd is the process working
# directory (git runs pre-push hooks from the repo top level), stdin is git's
# raw "<local ref> <local sha> <remote ref> <remote sha>" lines, exit 0
# allows the push and any non-zero blocks it. Block reasons go to stderr.
#
# WHAT IT ENFORCES: all text written by agents/automation defaults to STRICT
# UTF-8. Valid UTF-8 with OR without a BOM (EF BB BF) both pass - a BOM alone
# is never a violation. Non-UTF-8 text (an invalid byte sequence, UTF-16
# LE/BE, a legacy codepage) needs a narrow, documented exception in the
# optional project-tracked registry (.utf8-encoding-exceptions.json, below),
# or it is reported and, when NEW/CHANGED during a task, blocked.
#
# CLASSIFICATION (deterministic, on raw bytes - never replacement-char
# decoding): [System.Text.UTF8Encoding]::new($false, $true) with an exception
# fallback decides valid/invalid. A UTF-16 BOM (FF FE / FE FF), or NUL bytes
# concentrated on ONE byte parity in the first bounded window, classifies
# UTF-16 LE/BE - non-UTF-8 TEXT, never a binary skip. NUL bytes spread across
# BOTH parities are binary evidence (binary content is not a text violation).
# A file over UTF8_MAX_FILE_KB has only its first window heuristically
# checked: binary-looking -> binary; UTF-16-looking -> still a violation;
# text-looking -> 'oversized' (UNKNOWN - honestly reported, fail-closed at
# pre-push, never silently passed). An unreadable file is 'unreadable'
# (unknown). A known-binary EXTENSION alone never classifies content: bytes
# are read first, and the extension list only downgrades an ambiguous
# 'invalid'/'oversized' result for a recognized binary type - so text bytes
# under a .png name are still validated by content, and NUL-filled bytes
# under a .txt name are still binary regardless of the text-ish extension.
#
# EVENTS IN DETAIL:
#   SessionStart - bounded METADATA-ONLY baseline (relative path, size, mtime
#     ticks, classification - NEVER contents) into local state. Pre-existing
#     non-UTF-8 text is a concise ADVISORY, never a block. A clean, fully
#     covered baseline is silent. Incomplete coverage fails OPEN with an
#     honest partial note naming the real cause.
#   Stop / SubagentStop - inspects ONLY text files created or modified during
#     the task: working tree + staged content via bounded
#     `git status --porcelain --untracked-files=all` (argument array; staged
#     blobs are read via `git ls-files -s` + `git cat-file blob` so a
#     staged-then-reverted file is still seen), commits made during the task
#     via `git diff --name-only <baseline HEAD> HEAD` when the SessionStart
#     baseline recorded a HEAD, and the baseline size/mtime delta for non-git
#     projects. A confirmed NEW/CHANGED non-UTF-8 text file without a valid
#     exception BLOCKS (decision:block for both clients). Unknown/partial
#     coverage is reported honestly and is NEVER an all-clear. The actionable
#     state is fingerprinted per session: an unchanged block is emitted once
#     (repeats become a short advisory), changed state re-evaluates
#     immediately. stop_hook_active is honoured before anything else.
#   -GitPrePush - resolves the exact outgoing commit range per pushed ref
#     from git's real ref-update stdin (a deletion - local sha all-zero -
#     pushes nothing and is skipped; a NEW branch - remote sha all-zero -
#     scans commits not reachable from any remote-tracking ref via
#     `rev-list <sha> --not --remotes`, the same fallback Secrets-Check uses;
#     force-pushes/non-fast-forwards use the same `<remote>..<local>` range,
#     which needs no fast-forward ancestry). Changed blobs are enumerated per
#     outgoing commit via `git diff-tree -r --root --no-commit-id
#     --diff-filter=d` and each blob's raw bytes are read via `git cat-file
#     blob` (argument-array plumbing throughout; a blob is validated even
#     when a later outgoing commit deleted the file). It FAILS CLOSED: an
#     unresolvable range, an unreadable or oversized TEXT blob, or a
#     commit/blob ceiling overflow blocks the push with an explicit message
#     instead of passing an unscanned range. Binary blobs never
#     false-positive. Nothing is checked out and nothing is mutated.
#
# EXCEPTION REGISTRY (optional, project-tracked, NEVER auto-created):
# .utf8-encoding-exceptions.json at the project root (path overridable via
# UTF8_EXCEPTION_FILE, which must itself stay inside the project). Schema:
#   { "version": 1, "exceptions": [
#       { "path": "docs/legacy-notes.txt", "encoding": "windows-1252",
#         "reason": "vendor export kept byte-identical for diffing",
#         "verification": "reviewed 2026-07-01" } ] }
# An entry is honoured ONLY when ALL of these hold: the path is relative,
# contains no '..', stays physically inside the project (Test-PathInside),
# and is an exact relative path or ONE narrow glob (a single '*', no '**',
# no '?'/'['/']', at least 3 literal characters); the encoding is one of
# utf-16le, utf-16be, windows-1252, iso-8859-1, latin-1, shift_jis, euc-jp,
# gb18030 (there is deliberately NO 'binary' label - an exception can never
# reclassify binary as text, and binary content needs no exception because it
# is never a text violation); the reason is a concrete non-placeholder string
# of at least 5 characters. The registry file itself must be valid strict
# UTF-8. A malformed, ambiguous or overly broad entry is REJECTED with a
# warning and NEVER grants an exception - a rejected entry can only make the
# gate stricter, never looser.
#
# OUTPUT (client-aware, matching Test-Plan-Check / Ci-Status-Check):
#   real block -> { decision:'block', reason } for BOTH clients.
#   advisory   -> shaped by the shared Write-HookResult adapter, which also
#                 decides the client (Get-HookClientId: HOOKMAKER_CLIENT, else
#                 CLAUDE_PROJECT_DIR, else Codex - an INPUT hookSpecificOutput
#                 is NOT a client signal). Claude always, and Codex OFF Stop,
#                 get hookSpecificOutput.additionalContext; Codex gets
#                 systemMessage on Stop/SubagentStop only. Findings name only
#                 the relative path, the classification and the safe action -
#                 NEVER raw bytes, file contents, secrets or prompts.
#   pre-push   -> human-readable reasons on stderr, exit 1 to block.
#
# Optional .env next to this script (copy .env.example):
#   UTF8_MAX_FILES          files classified per scan; also the changed-file
#                           and outgoing-blob ceilings          (default 400)
#   UTF8_MAX_FILE_KB        KB ceiling per file/blob            (default 1024)
#   UTF8_MAX_DIRECTORIES    directories the walk may visit      (default 4000)
#   UTF8_MAX_SCAN_SECONDS   wall seconds per scan               (default 10)
#   UTF8_MAX_FINDINGS       findings shown before capping       (default 8)
#   UTF8_EXCEPTION_FILE     project-relative registry path
#                           (default .utf8-encoding-exceptions.json)
#   UTF8_ADVISORY_ONLY      true = Stop never blocks            (default false)
# An invalid integer is reported in plain text and the default is used. An
# invalid UTF8_ADVISORY_ONLY falls back to advisory-only (true) - the
# NON-WIDENING fallback Test-Completion-Check uses: a typo must never make
# this hook block on MORE than intended.

param([switch]$GitPrePush)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = if ($GitPrePush) {
    # Native pre-push: no JSON on stdin - stdin carries git's raw ref-update
    # lines, and the working directory IS the repository (Secrets-Check:107).
    [pscustomobject]@{ cwd = (Get-Location).Path; hook_event_name = 'GitPrePush' }
}
else {
    Read-HookInput
}
if ($null -eq $hookInput) { exit 0 }

# Raw "<local ref> <local sha> <remote ref> <remote sha>" lines, one per
# pushed ref. The managed wrapper tees the real stdin into a file and feeds
# the SAME file to every stage, so reading it here does not consume it for
# the rest of the chain.
$refUpdateLines = @()
if ($GitPrePush) {
    try {
        $rawRefUpdates = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($rawRefUpdates)) {
            $refUpdateLines = @($rawRefUpdates -split '\r?\n' | Where-Object { $_.Trim() -ne '' })
        }
    }
    catch { }
}

# ---- recursion guard: FIRST, before anything else is evaluated ----
if (-not $GitPrePush -and (Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }

$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'Stop' -and $eventName -ne 'SubagentStop' -and $eventName -ne 'GitPrePush') { exit 0 }
$isStopLike = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$sessionId = [string](Get-Field $hookInput 'session_id')

# ---- optional .env (invalid -> reported + a safe default) ----
$configWarnings = New-Object System.Collections.Generic.List[string]
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

function Read-BoundedIntSetting {
    param([string]$Key, [int]$Default, [int]$Min, [int]$Max)
    if (-not $config.ContainsKey($Key)) { return $Default }
    $raw = [string]$config[$Key]
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) { return $parsed }
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add($Key + ' is not an integer in ' + $Min + '..' + $Max + '; using the default ' + $Default + '.')
    }
    return $Default
}

$maxFiles     = Read-BoundedIntSetting 'UTF8_MAX_FILES'         400 1 100000
$maxFileBytes = 1KB * (Read-BoundedIntSetting 'UTF8_MAX_FILE_KB' 1024 1 1048576)
$maxDirs      = Read-BoundedIntSetting 'UTF8_MAX_DIRECTORIES'  4000 1 1000000
$maxSeconds   = Read-BoundedIntSetting 'UTF8_MAX_SCAN_SECONDS'   10 1 3600
$maxFindings  = Read-BoundedIntSetting 'UTF8_MAX_FINDINGS'        8 1 1000

# Invalid -> advisory-only (true), NOT the blocking default: the setting was
# clearly meant to be changed, and a typo must never WIDEN what is blocked on
# (the exact fallback rule Test-Completion-Check documents). Reported, never
# silent.
$advisoryOnly = $false
if ($config.ContainsKey('UTF8_ADVISORY_ONLY')) {
    $raw = [string]$config['UTF8_ADVISORY_ONLY']
    if ($raw -match '^(?i:true|1|yes)$') { $advisoryOnly = $true }
    elseif ($raw -notmatch '^(?i:false|0|no)$' -and -not [string]::IsNullOrWhiteSpace($raw)) {
        $advisoryOnly = $true
        [void]$configWarnings.Add('UTF8_ADVISORY_ONLY must be true or false; falling back to advisory-only (true) so a malformed value can never widen what is blocked on.')
    }
}

$exceptionFileSetting = '.utf8-encoding-exceptions.json'
if ($config.ContainsKey('UTF8_EXCEPTION_FILE') -and -not [string]::IsNullOrWhiteSpace([string]$config['UTF8_EXCEPTION_FILE'])) {
    $exceptionFileSetting = ([string]$config['UTF8_EXCEPTION_FILE']).Trim()
}

# ---- constants --------------------------------------------------------------
# Directory names pruned BEFORE descent (Secrets-Check.ps1 $excludedDirs).
$script:ExcludedDirs = @('.git', 'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target', 'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env', '.ai', 'graphify-out', '.claude', '.codex', '.agents', 'bin', 'obj', '.tox', 'site-packages')
# Extensions that may DOWNGRADE an ambiguous 'invalid'/'oversized' result to
# binary. Never consulted before the bytes themselves have been examined.
$script:KnownBinaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.avif', '.pdf', '.zip', '.gz', '.tgz', '.bz2', '.xz', '.7z', '.rar', '.jar', '.war', '.exe', '.dll', '.so', '.dylib', '.pdb', '.lib', '.a', '.o', '.obj', '.bin', '.dat', '.db', '.sqlite', '.sqlite3', '.mdb', '.mp3', '.mp4', '.m4a', '.avi', '.mov', '.mkv', '.wav', '.ogg', '.flac', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.class', '.pyc', '.pyo', '.pyd', '.wasm', '.node', '.iso', '.dmg', '.msi', '.cab', '.nupkg', '.snupkg', '.whl', '.egg', '.parquet', '.xls', '.xlsx', '.doc', '.docx', '.ppt', '.pptx', '.swf', '.psd', '.ai0')
$script:RecognizedEncodings = @('utf-16le', 'utf-16be', 'windows-1252', 'iso-8859-1', 'latin-1', 'shift_jis', 'euc-jp', 'gb18030')
$script:PlaceholderReasons = @('todo', 'tbd', 'n/a', 'none', '-', 'x', 'fixme', 'because', 'reason')
$script:HeuristicWindowBytes = 8192
# Pre-push commit ceiling. Blobs are bounded by UTF8_MAX_FILES; overflow of
# either FAILS CLOSED because pre-push coverage is REQUIRED, never sampled.
$script:MaxOutgoingCommits = 5000
$script:ViolationClasses = @('invalid', 'utf16le', 'utf16be')

# ---- classification and the exception registry ------------------------------
. (Join-Path $PSScriptRoot '_classification.ps1')

# ---- misc helpers -----------------------------------------------------------
function Test-PathExcluded {
    param([string]$RelativePath)
    foreach ($segment in $RelativePath.Split('/')) {
        if ($script:ExcludedDirs -contains $segment.ToLowerInvariant()) { return $true }
    }
    return $false
}

# git quotes a path containing specials as "..." with backslash escapes; the
# common cases (spaces stay unquoted, quotes/backslashes escaped) are handled.
# An octal-escaped non-ASCII path is left as-is - it can only fail an
# exception match, which is the strict (safe) direction.
function ConvertFrom-GitQuotedPath {
    param([string]$Path)
    if ($Path.Length -ge 2 -and $Path.StartsWith('"') -and $Path.EndsWith('"')) {
        return $Path.Substring(1, $Path.Length - 2).Replace('\"', '"').Replace('\\', '\')
    }
    return $Path
}

# ---- bounded project walk (baseline + non-git delta) ------------------------
# Explicit-stack walk mirroring Test-Plan-Check: excluded trees pruned BEFORE
# descent, a reparse-point ROOT refused (nothing pushed, marked partial),
# child reparse points never followed, lazy enumeration with the wall clock
# paid for EVERY enumerated entry. Every file is classified from its BYTES.
function Invoke-Utf8Walk {
    param([string]$Root, $Exceptions)
    $fileLimitReached = $false
    $dirLimitReached = $false
    $timeLimitReached = $false
    $scanIncomplete = $false
    $rootReparse = $false
    $dirsVisited = 0
    $entries = New-Object System.Collections.Generic.List[object]
    $walkTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $rootFull = $Root.TrimEnd('\', '/')
    try { $rootFull = (Get-Item -LiteralPath $Root -Force -ErrorAction Stop).FullName.TrimEnd('\', '/') } catch { }
    try { $rootReparse = ((([System.IO.File]::GetAttributes($rootFull)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { }
    $stack = New-Object System.Collections.Generic.Stack[string]
    if (-not $rootReparse) { $stack.Push($rootFull) }
    while ($stack.Count -gt 0) {
        if ($entries.Count -ge $maxFiles) { $fileLimitReached = $true; break }
        if ($dirsVisited -ge $maxDirs) { $dirLimitReached = $true; break }
        if ($walkTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
        $current = $stack.Pop()
        $dirsVisited++
        try {
            foreach ($dirPath in [System.IO.Directory]::EnumerateDirectories($current)) {
                if ($walkTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
                $dir = Get-Item -LiteralPath $dirPath -Force -ErrorAction SilentlyContinue
                if ($null -eq $dir -or ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                if ($script:ExcludedDirs -notcontains $dir.Name.ToLowerInvariant()) { $stack.Push($dir.FullName) }
            }
        }
        catch { $scanIncomplete = $true }
        if ($timeLimitReached) { break }
        try {
            foreach ($filePath in [System.IO.Directory]::EnumerateFiles($current)) {
                if ($entries.Count -ge $maxFiles) { $fileLimitReached = $true; break }
                if ($walkTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
                $info = Get-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
                if ($null -eq $info -or ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                $relative = $info.FullName
                if ($relative.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $relative.Substring($rootFull.Length).TrimStart('\', '/')
                }
                $relative = $relative.Replace('\', '/')
                $class = ''
                if (Test-ExceptionMatch -Exceptions $Exceptions -RelativePath $relative) {
                    $class = 'excepted'
                }
                else {
                    $read = Read-FileBytesBounded -Path $info.FullName -MaxFullBytes $maxFileBytes
                    if ($read.Failed) { $class = 'unreadable'; $scanIncomplete = $true }
                    else { $class = Resolve-ClassWithExtension -RelativePath $relative -RawClass (Get-Utf8Classification -Bytes $read.Bytes -Truncated $read.Truncated) }
                }
                [void]$entries.Add([pscustomobject]@{ p = $relative; s = [int64]$info.Length; t = [string]$info.LastWriteTimeUtc.Ticks; c = $class })
            }
        }
        catch { $scanIncomplete = $true }
        if ($timeLimitReached) { break }
    }

    $causes = New-Object System.Collections.Generic.List[string]
    if ($rootReparse) { [void]$causes.Add('the scan root is a junction/symlink and was not followed') }
    if ($fileLimitReached) { [void]$causes.Add('a file ceiling of ' + $maxFiles + ' classified files was reached') }
    if ($dirLimitReached) { [void]$causes.Add('a directory ceiling of ' + $maxDirs + ' directories was reached') }
    if ($timeLimitReached) { [void]$causes.Add('a scan time limit of ' + $maxSeconds + ' seconds was reached') }
    if ($scanIncomplete) { [void]$causes.Add('one or more files or directories could not be read') }
    return [pscustomobject]@{
        Entries = @($entries.ToArray())
        Partial = ($causes.Count -gt 0)
        PartialCause = ($causes -join ' and ')
    }
}

# ---- client-aware output ----------------------------------------------------
# Every shape decision belongs to the shared Write-HookResult adapter in
# _hooklib.ps1, including WHICH client this is: Get-HookClientId reads
# HOOKMAKER_CLIENT, else CLAUDE_PROJECT_DIR, else Codex. `hookSpecificOutput`
# in the INPUT event is NOT a documented client signal and is not consulted.
# Real block -> decision:block for Claude/Codex (the Ci-Status-Check blocking
# shape). Advisory -> additionalContext for Claude on any event and for Codex
# OFF Stop; Codex's `systemMessage` is Stop-scoped, so this hook gets it on
# Stop/SubagentStop and NOT on SessionStart. Write-HookResult never exits, so
# this helper keeps the exit itself and honours the returned ExitCode.
function Write-HookMessage {
    param([string[]]$Lines, [bool]$Blocking)
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { [void]$all.Add($line) }
    if ($configWarnings.Count -gt 0) {
        [void]$all.Add('')
        foreach ($warning in $configWarnings.ToArray()) { [void]$all.Add('Utf8-Encoding-Check .env: ' + $warning) }
    }
    $message = ($all.ToArray() -join "`n")
    if ($Blocking -and -not $advisoryOnly) {
        exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason $message).ExitCode
    }
    if ($Blocking -and $advisoryOnly) { $message = 'UTF8_ADVISORY_ONLY is set - reported, not blocked:' + "`n" + $message }
    exit (Write-HookResult -EventName $eventName -Kind 'advisory' -Message $message).ExitCode
}

# ---- shared state -----------------------------------------------------------
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$projectKey = Get-ShortHash $cwd.ToLowerInvariant()
$statePath = Join-Path $stateDir ('Utf8EncodingCheck-' + $projectKey + '.json')

$exceptions = @(Get-Utf8Exceptions -ProjectRoot $cwd)

# =============================================================================
# -GitPrePush: validate every outgoing text blob; FAIL CLOSED on any gap.
# =============================================================================
if ($GitPrePush) {
    if ($refUpdateLines.Count -eq 0) { exit 0 }
    $violations = New-Object System.Collections.Generic.List[string]
    $coverageErrors = New-Object System.Collections.Generic.List[string]
    $allZero = '0' * 40

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('UTF8 ENCODING CHECK - git is unavailable, so the outgoing range cannot be scanned; refusing to authorize the push as clean.')
        exit 1
    }

    # -- outgoing commit set (the Secrets-Check Get-OutgoingCommits shape,
    #    plus an explicit commit ceiling that fails closed on overflow) --
    $commits = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in $refUpdateLines) {
        $parts = @($line.Trim() -split '\s+')
        if ($parts.Count -lt 4) { continue }
        $localRef = $parts[0]
        $localSha = $parts[1]
        $remoteSha = $parts[3]
        if ($localSha -eq $allZero) { continue }    # deletion - nothing pushed
        $revs = @()
        if ($remoteSha -eq $allZero) {
            # New branch: scope to commits not already on any remote-tracking
            # ref, so previously-reviewed history is not rescanned.
            $revs = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-list', $localSha, '--not', '--remotes') | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                [void]$coverageErrors.Add('new ref ' + $localRef + ' - outgoing commits could not be resolved (rev-list failed); refusing to treat it as clean')
                continue
            }
        }
        else {
            $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--verify', '--quiet', ($remoteSha + '^{commit}'))
            if ($LASTEXITCODE -ne 0) {
                $shortRemote = if ($remoteSha.Length -gt 7) { $remoteSha.Substring(0, 7) } else { $remoteSha }
                [void]$coverageErrors.Add('ref ' + $localRef + ' - remote commit ' + $shortRemote + ' is not resolvable locally, so the outgoing range cannot be bounded; refusing to treat it as clean')
                continue
            }
            $revs = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-list', ($remoteSha + '..' + $localSha)) | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                [void]$coverageErrors.Add('ref ' + $localRef + ' - outgoing commits could not be resolved (rev-list failed); refusing to treat it as clean')
                continue
            }
        }
        foreach ($rev in $revs) { [void]$commits.Add([string]$rev) }
    }
    if ($commits.Count -gt $script:MaxOutgoingCommits) {
        [void]$coverageErrors.Add('the outgoing range holds ' + $commits.Count + ' commits, over the ' + $script:MaxOutgoingCommits + '-commit ceiling; required coverage would be incomplete, so the push is refused (fail closed)')
    }

    # -- changed blobs per outgoing commit (diff-tree), deduped by sha+path --
    $blobs = New-Object System.Collections.Generic.List[object]
    $seenBlobs = New-Object System.Collections.Generic.HashSet[string]
    $blobOverflow = $false
    if ($coverageErrors.Count -eq 0) {
        foreach ($commit in @($commits)) {
            if ($blobOverflow) { break }
            $diffLines = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff-tree', '-r', '--root', '--no-commit-id', '--diff-filter=d', [string]$commit) | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                $shortCommit = ([string]$commit)
                if ($shortCommit.Length -gt 7) { $shortCommit = $shortCommit.Substring(0, 7) }
                [void]$coverageErrors.Add('changed files in outgoing commit ' + $shortCommit + ' could not be enumerated; refusing to treat the push as clean')
                continue
            }
            foreach ($rawLine in $diffLines) {
                $lineText = [string]$rawLine
                if (-not $lineText.StartsWith(':')) { continue }
                $tabIndex = $lineText.IndexOf("`t")
                if ($tabIndex -lt 0) { continue }
                $meta = @($lineText.Substring(1, $tabIndex - 1) -split '\s+')
                if ($meta.Count -lt 5) { continue }
                $newSha = [string]$meta[3]
                if ($newSha -eq $allZero) { continue }
                $blobPath = (ConvertFrom-GitQuotedPath ($lineText.Substring($tabIndex + 1))).Replace('\', '/')
                if (-not $seenBlobs.Add($newSha + '|' + $blobPath)) { continue }
                if ($blobs.Count -ge $maxFiles) { $blobOverflow = $true; break }
                [void]$blobs.Add([pscustomobject]@{ Sha = $newSha; Path = $blobPath })
            }
        }
    }
    if ($blobOverflow) {
        [void]$coverageErrors.Add('the outgoing range changes more than ' + $maxFiles + ' blobs (UTF8_MAX_FILES); required coverage would be incomplete, so the push is refused (fail closed). Raise UTF8_MAX_FILES or push in smaller batches')
    }

    # -- strict validation of every enumerated blob --
    $violatedPaths = New-Object System.Collections.Generic.HashSet[string]
    if ($coverageErrors.Count -eq 0) {
        foreach ($blob in $blobs.ToArray()) {
            if (Test-ExceptionMatch -Exceptions $exceptions -RelativePath $blob.Path) { continue }
            $read = Get-GitBlobBytes -Cwd $cwd -BlobSha $blob.Sha -MaxFullBytes $maxFileBytes
            if ($read.Failed) {
                [void]$coverageErrors.Add('outgoing blob for ' + $blob.Path + ' could not be read; refusing to treat the push as clean')
                continue
            }
            $class = Resolve-ClassWithExtension -RelativePath $blob.Path -RawClass (Get-Utf8Classification -Bytes $read.Bytes -Truncated $read.Truncated)
            if ($script:ViolationClasses -contains $class) {
                if ($violatedPaths.Add($blob.Path)) {
                    [void]$violations.Add($blob.Path + ' - ' + (Get-ClassLabel $class) + ' in an outgoing commit')
                }
            }
            elseif ($class -eq 'oversized') {
                [void]$coverageErrors.Add('outgoing text blob ' + $blob.Path + ' exceeds UTF8_MAX_FILE_KB and could not be fully validated; raise the ceiling or add a documented exception (fail closed)')
            }
        }
    }

    if ($violations.Count -eq 0 -and $coverageErrors.Count -eq 0) { exit 0 }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('UTF8 ENCODING CHECK - push blocked:')
    $shown = 0
    foreach ($violation in $violations.ToArray()) {
        if ($shown -ge $maxFindings) { [void]$lines.Add('(+' + ($violations.Count - $shown) + ' more non-UTF-8 finding(s) omitted)'); break }
        [void]$lines.Add('- ' + $violation)
        $shown++
    }
    foreach ($coverageError in $coverageErrors.ToArray()) { [void]$lines.Add('- Outgoing coverage incomplete: ' + $coverageError + '.') }
    [void]$lines.Add('Re-save each named file as strict UTF-8 in a new commit (this hook never rewrites or transcodes anything), or add a narrow documented exception to ' + $exceptionFileSetting + ', then push again.')
    foreach ($warning in $configWarnings.ToArray()) { [void]$lines.Add('Utf8-Encoding-Check .env: ' + $warning) }
    # Advisory-only softens CONFIRMED findings to a warning, but an
    # unscannable REQUIRED range still fails closed - a gate must never
    # authorize a push it could not actually scan.
    [Console]::Error.WriteLine(($lines.ToArray() -join "`n"))
    if ($advisoryOnly -and $coverageErrors.Count -eq 0) { exit 0 }
    exit 1
}

# =============================================================================
# SessionStart: bounded metadata-only baseline + legacy advisory (never block).
# =============================================================================
if ($eventName -eq 'SessionStart') {
    $walk = Invoke-Utf8Walk -Root $cwd -Exceptions $exceptions

    $headSha = ''
    if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
        $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
        if ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true') {
            $headRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', 'HEAD'))
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($headRaw)) { $headSha = $headRaw.Trim() }
        }
    }

    # METADATA ONLY: relative path, size, mtime ticks, classification. File
    # CONTENTS are never stored anywhere. A fresh session clears the previous
    # block fingerprint (a new session re-evaluates from scratch).
    try {
        Write-JsonFileAtomic -Value ([pscustomobject]@{
                schema = 1
                baseline = [pscustomobject]@{
                    createdUtcTicks = [string]([DateTime]::UtcNow.Ticks)
                    head = $headSha
                    partial = $walk.Partial
                    files = @($walk.Entries)
                }
                lastBlockFingerprint = ''
                updatedUtc = [DateTime]::UtcNow.ToString('o')
            }) -Path $statePath
    }
    catch { }

    $legacy = @($walk.Entries | Where-Object { $script:ViolationClasses -contains $_.c })
    $oversizedCount = @($walk.Entries | Where-Object { $_.c -eq 'oversized' }).Count
    $unreadableCount = @($walk.Entries | Where-Object { $_.c -eq 'unreadable' }).Count

    if ($legacy.Count -eq 0 -and -not $walk.Partial -and $oversizedCount -eq 0 -and $unreadableCount -eq 0 -and $configWarnings.Count -eq 0) { exit 0 }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('UTF-8 ENCODING CHECK - baseline advisory (SessionStart never blocks; this hook never rewrites a file).')
    if ($legacy.Count -gt 0) {
        [void]$lines.Add('Pre-existing non-UTF-8 text in this project (LEGACY - advisory only; anything created or modified from now on must be strict UTF-8):')
        $shown = 0
        foreach ($entry in $legacy) {
            if ($shown -ge $maxFindings) { [void]$lines.Add('(+' + ($legacy.Count - $shown) + ' more not shown)'); break }
            [void]$lines.Add('- ' + $entry.p + ' - ' + (Get-ClassLabel $entry.c))
            $shown++
        }
        [void]$lines.Add('Convert opportunistically, or add narrow documented exceptions to ' + $exceptionFileSetting + ' ({version:1, exceptions:[{path, encoding, reason, verification}]}).')
    }
    # [string] casts: an [int] LEFT of '+' would try to numerically convert
    # the text and throw under $ErrorActionPreference='Stop'.
    if ($oversizedCount -gt 0) { [void]$lines.Add(([string]$oversizedCount) + ' file(s) exceeded UTF8_MAX_FILE_KB and were NOT validated (encoding unknown).') }
    if ($unreadableCount -gt 0) { [void]$lines.Add(([string]$unreadableCount) + ' file(s) could not be read and were NOT validated.') }
    if ($walk.Partial) {
        [void]$lines.Add('NOTE: this baseline is PARTIAL - ' + $walk.PartialCause + ' before the whole project was covered. A no-finding result is NOT an all-clear.')
    }
    Write-HookMessage -Lines $lines.ToArray() -Blocking $false
}

# =============================================================================
# Stop / SubagentStop: gate on text created or modified during the task.
# =============================================================================

# -- prior state (baseline + last block fingerprint) --
$stateDoc = $null
try { $stateDoc = Read-JsonFile $statePath } catch { $stateDoc = $null }
$baselineHead = ''
$baselinePartial = $false
$baselineFiles = @{}
$hasBaseline = $false
$lastBlockFingerprint = ''
if ($null -ne $stateDoc) {
    $lastBlockFingerprint = [string](Get-Field $stateDoc 'lastBlockFingerprint')
    $baseline = Get-Field $stateDoc 'baseline'
    if ($null -ne $baseline) {
        $ticks = [int64]0
        $freshEnough = $false
        if ([int64]::TryParse([string](Get-Field $baseline 'createdUtcTicks'), [ref]$ticks) -and $ticks -gt 0) {
            # Stale-aware: a baseline older than 7 days no longer describes
            # "this task" and is ignored rather than trusted.
            $age = [DateTime]::UtcNow - (New-Object DateTime($ticks, [DateTimeKind]::Utc))
            if ($age.TotalDays -le 7 -and $age.TotalDays -ge -1) { $freshEnough = $true }
        }
        if ($freshEnough) {
            $hasBaseline = $true
            $baselineHead = [string](Get-Field $baseline 'head')
            $baselinePartial = ((Get-Field $baseline 'partial') -eq $true)
            foreach ($entry in @(Get-Field $baseline 'files')) {
                if ($null -eq $entry) { continue }
                $entryPath = [string](Get-Field $entry 'p')
                if ($entryPath -ne '') { $baselineFiles[$entryPath] = $entry }
            }
        }
    }
}

$violations = New-Object System.Collections.Generic.List[string]
$unknownNotes = New-Object System.Collections.Generic.List[string]

$inGitRepo = $false
if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
    $inGitRepo = ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
}

if ($inGitRepo) {
    # -- candidates: working tree + staged (git status) and commits made
    #    during the task (baseline HEAD .. HEAD), merged by path --
    $candidateMap = @{}   # path -> staged flag
    $statusLines = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'status', '--porcelain', '--untracked-files=all') | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) {
        [void]$unknownNotes.Add('git status failed, so files changed in this task could not be fully determined')
    }
    else {
        foreach ($rawLine in $statusLines) {
            $lineText = [string]$rawLine
            if ($lineText.Length -lt 4) { continue }
            $code = $lineText.Substring(0, 2)
            $relative = $lineText.Substring(3)
            # A rename/copy line is "XY old -> new"; only the destination
            # exists (the _hooklib Get-LatestWorkTimeUtc lesson).
            if ($code.Contains('R') -or $code.Contains('C')) {
                $arrowIndex = $relative.IndexOf(' -> ')
                if ($arrowIndex -ge 0) { $relative = $relative.Substring($arrowIndex + 4) }
            }
            $relative = (ConvertFrom-GitQuotedPath $relative.Trim()).Replace('\', '/')
            if ($relative -eq '' -or (Test-PathExcluded $relative)) { continue }
            $indexState = $code.Substring(0, 1)
            $staged = ($indexState -ne ' ' -and $indexState -ne '?' -and $indexState -ne '!')
            if ($candidateMap.ContainsKey($relative)) { $candidateMap[$relative] = ($candidateMap[$relative] -or $staged) }
            else { $candidateMap[$relative] = $staged }
        }
    }
    if ($hasBaseline -and $baselineHead -ne '') {
        $currentHead = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', 'HEAD'))
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentHead) -and $currentHead.Trim() -ne $baselineHead) {
            $diffLines = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff', '--name-only', $baselineHead, $currentHead.Trim()) | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                [void]$unknownNotes.Add('commits made during this task could not be enumerated (git diff against the session baseline failed)')
            }
            else {
                foreach ($rawLine in $diffLines) {
                    $relative = (ConvertFrom-GitQuotedPath ([string]$rawLine).Trim()).Replace('\', '/')
                    if ($relative -eq '' -or (Test-PathExcluded $relative)) { continue }
                    if (-not $candidateMap.ContainsKey($relative)) { $candidateMap[$relative] = $false }
                }
            }
        }
    }

    # -- bounded validation of each candidate --
    $checkTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $processed = 0
    foreach ($candidatePath in @($candidateMap.Keys | Sort-Object)) {
        if ($processed -ge $maxFiles) {
            [void]$unknownNotes.Add('PARTIAL: a ceiling of ' + $maxFiles + ' changed files (UTF8_MAX_FILES) was reached before every changed file was checked')
            break
        }
        if ($checkTimer.Elapsed.TotalSeconds -ge $maxSeconds) {
            [void]$unknownNotes.Add('PARTIAL: the ' + $maxSeconds + '-second scan ceiling (UTF8_MAX_SCAN_SECONDS) was reached before every changed file was checked')
            break
        }
        $processed++
        if (Test-ExceptionMatch -Exceptions $exceptions -RelativePath $candidatePath) { continue }
        $fullPath = Join-Path $cwd ($candidatePath.Replace('/', '\'))
        $worktreeViolation = $false
        $fileExists = $false
        try { $fileExists = (Test-Path -LiteralPath $fullPath -PathType Leaf) } catch { $fileExists = $false }
        if ($fileExists) {
            $read = Read-FileBytesBounded -Path $fullPath -MaxFullBytes $maxFileBytes
            if ($read.Failed) {
                [void]$unknownNotes.Add($candidatePath + ' - changed in this task but could not be read; its encoding is NOT verified')
            }
            else {
                $class = Resolve-ClassWithExtension -RelativePath $candidatePath -RawClass (Get-Utf8Classification -Bytes $read.Bytes -Truncated $read.Truncated)
                if ($script:ViolationClasses -contains $class) {
                    [void]$violations.Add($candidatePath + ' - ' + (Get-ClassLabel $class))
                    $worktreeViolation = $true
                }
                elseif ($class -eq 'oversized') {
                    [void]$unknownNotes.Add($candidatePath + ' - changed in this task but exceeds UTF8_MAX_FILE_KB; its encoding is NOT verified')
                }
            }
        }
        # Staged content can differ from the working tree (staged then
        # reverted); read the index blob so it is still seen. Skipped when the
        # working tree already produced a violation for this path (one finding
        # per path is enough to block).
        if (-not $worktreeViolation -and $candidateMap[$candidatePath]) {
            $lsLine = [string](@(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'ls-files', '-s', '--', $candidatePath) | Where-Object { $_ } | Select-Object -First 1))
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($lsLine)) {
                $tabIndex = $lsLine.IndexOf("`t")
                $lsMeta = $lsLine
                if ($tabIndex -ge 0) { $lsMeta = $lsLine.Substring(0, $tabIndex) }
                $metaParts = @($lsMeta -split '\s+')
                if ($metaParts.Count -ge 2) {
                    $stagedSha = [string]$metaParts[1]
                    $read = Get-GitBlobBytes -Cwd $cwd -BlobSha $stagedSha -MaxFullBytes $maxFileBytes
                    if ($read.Failed) {
                        [void]$unknownNotes.Add($candidatePath + ' (staged content) - could not be read; its encoding is NOT verified')
                    }
                    else {
                        $class = Resolve-ClassWithExtension -RelativePath $candidatePath -RawClass (Get-Utf8Classification -Bytes $read.Bytes -Truncated $read.Truncated)
                        if ($script:ViolationClasses -contains $class) {
                            [void]$violations.Add($candidatePath + ' (staged content) - ' + (Get-ClassLabel $class))
                        }
                        elseif ($class -eq 'oversized') {
                            [void]$unknownNotes.Add($candidatePath + ' (staged content) - exceeds UTF8_MAX_FILE_KB; its encoding is NOT verified')
                        }
                    }
                }
            }
        }
    }
}
else {
    # -- non-git: only the SessionStart baseline can tell new/changed from
    #    pre-existing. Without a fresh baseline nothing is determinable, and
    #    inventing candidates would misreport legacy files as new - silent.
    if (-not $hasBaseline) { exit 0 }
    $walk = Invoke-Utf8Walk -Root $cwd -Exceptions $exceptions
    foreach ($entry in @($walk.Entries)) {
        $isNew = -not $baselineFiles.ContainsKey($entry.p)
        $isChanged = $false
        if (-not $isNew) {
            $old = $baselineFiles[$entry.p]
            $isChanged = (([int64](Get-Field $old 's')) -ne [int64]$entry.s) -or (([string](Get-Field $old 't')) -ne [string]$entry.t)
        }
        if (-not $isNew -and -not $isChanged) { continue }
        if ($isNew -and $baselinePartial) {
            # A partial baseline cannot prove this file is actually new -
            # blocking a possibly-legacy file would be a false positive, so it
            # is reported as unknown instead.
            if ($script:ViolationClasses -contains $entry.c) {
                [void]$unknownNotes.Add($entry.p + ' - ' + (Get-ClassLabel $entry.c) + ', but the session baseline was PARTIAL so it cannot be proven new; NOT verified as task work')
            }
            continue
        }
        if ($script:ViolationClasses -contains $entry.c) { [void]$violations.Add($entry.p + ' - ' + (Get-ClassLabel $entry.c)) }
        elseif ($entry.c -eq 'oversized') { [void]$unknownNotes.Add($entry.p + ' - changed in this task but exceeds UTF8_MAX_FILE_KB; its encoding is NOT verified') }
        elseif ($entry.c -eq 'unreadable') { [void]$unknownNotes.Add($entry.p + ' - changed in this task but could not be read; its encoding is NOT verified') }
    }
    if ($walk.Partial) { [void]$unknownNotes.Add('PARTIAL: ' + $walk.PartialCause + ' before every file was compared against the baseline') }
}

# -- persist the block fingerprint (baseline preserved as-is) --
function Save-StopState {
    param([string]$Fingerprint)
    $baselineOut = $null
    if ($null -ne $stateDoc) { $baselineOut = Get-Field $stateDoc 'baseline' }
    try {
        Write-JsonFileAtomic -Value ([pscustomobject]@{
                schema = 1
                baseline = $baselineOut
                lastBlockFingerprint = $Fingerprint
                updatedUtc = [DateTime]::UtcNow.ToString('o')
            }) -Path $statePath
    }
    catch { }
}

if ($violations.Count -gt 0) {
    # Fingerprint of the ACTIONABLE state, session-scoped: the same unchanged
    # block is emitted once per session (repeats become a short advisory);
    # any change - a new finding, a fix, a new session - re-evaluates at once.
    $fingerprint = Get-ShortHash ($sessionId + '|' + (($violations.ToArray() | Sort-Object) -join ';') + '|' + (($unknownNotes.ToArray() | Sort-Object) -join ';'))
    if ($fingerprint -eq $lastBlockFingerprint) {
        Write-HookMessage -Lines @('UTF-8 ENCODING CHECK - the non-UTF-8 findings already reported this session are unchanged and still unresolved. (Not an all-clear.)') -Blocking $false
    }
    Save-StopState -Fingerprint $fingerprint
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('UTF-8 ENCODING CHECK - non-UTF-8 text was created or modified during this task:')
    $shown = 0
    foreach ($violation in $violations.ToArray()) {
        if ($shown -ge $maxFindings) { [void]$lines.Add('(+' + ($violations.Count - $shown) + ' more finding(s) omitted)'); break }
        [void]$lines.Add('- ' + $violation)
        $shown++
    }
    if ($unknownNotes.Count -gt 0) {
        [void]$lines.Add('Also NOT verified (never an all-clear):')
        foreach ($note in $unknownNotes.ToArray()) { [void]$lines.Add('- ' + $note) }
    }
    [void]$lines.Add('Re-save each file above as strict UTF-8 yourself (this hook never rewrites, transcodes or normalizes anything), or add a narrow documented exception to ' + $exceptionFileSetting + ' ({version:1, exceptions:[{path, encoding, reason, verification}]}), then stop again.')
    Write-HookMessage -Lines $lines.ToArray() -Blocking $true
}

if ($unknownNotes.Count -gt 0) {
    if ($lastBlockFingerprint -ne '') { Save-StopState -Fingerprint '' }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('UTF-8 ENCODING CHECK - some files changed in this task could NOT be verified as UTF-8 (this is NOT an all-clear):')
    foreach ($note in $unknownNotes.ToArray()) { [void]$lines.Add('- ' + $note) }
    Write-HookMessage -Lines $lines.ToArray() -Blocking $false
}

# Clean: clear a stale block fingerprint so an identical future violation is
# treated as NEW state, then stay silent (config warnings alone never nag a
# clean Stop).
if ($lastBlockFingerprint -ne '') { Save-StopState -Fingerprint '' }
exit 0
