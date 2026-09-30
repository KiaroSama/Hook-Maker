# Docs-Freshness-Check - a mandatory review boundary (never a prose rewriter)
# for whether this task's changes made tracked, published documentation stale.
#
# SessionStart: silently records a metadata-only baseline (starting HEAD,
# repo-state fingerprint, tracked public .md/.txt paths + content hashes).
#
# Stop: computes the task delta from the SessionStart baseline (commits +
# staged + working-tree changes, so it still works even if the agent already
# committed), classifies each changed non-doc file as real content change or
# comment/blank-only noise, and - only when real, non-excluded impact exists -
# blocks ONCE per distinct impact fingerprint with a bounded, ranked list of
# candidate tracked .md/.txt files to review. It never edits, invents, or
# rewrites documentation prose itself; it only detects and gates.
#
# PreToolUse: on a shell `git push` (recognised per segment by the shared
# tokenizer), the same classifier runs over the task delta plus the commits
# not yet on the upstream. Real non-doc impact without a matching
# acknowledgement denies the push ONCE per impact fingerprint, so the docs land
# in the same push and CI runs once. Documentation-only outgoing commits pass.
# The retry is not denied again, and it is not an acknowledgement: Stop still
# requires one. Local, bounded git reads only - no network, no tests.
#
# Mandatory acknowledgement (the only way to clear a block):
#   powershell.exe -File Docs-Freshness-Check.ps1 -Acknowledge `
#     -ProjectRoot "<path>" -ImpactFingerprint "<fp>" -Result Updated|NoUpdate `
#     -Files "<comma,separated,relative,doc,paths>" -Reason "<concrete reason>"
# Updated requires at least one real -Files entry; NoUpdate requires a concrete
# (non-generic) -Reason. Every acknowledged path must be a canonical,
# project-relative, tracked/staged .md or .txt file inside ProjectRoot and not
# under a hard-excluded location. The acknowledgement is bound to the EXACT
# impact fingerprint; any later non-doc change invalidates it and requires a
# fresh review. Acknowledgement state is local-only (LOCALAPPDATA), never
# committed, and never authorizes anything beyond the fingerprint it matches.
#
# Hard exclusions (never requested for review regardless of config):
# .git/.ai/.claude/.codex/.agents/.cross-project-sync, secrets.md, generated/
# vendor/build/cache directories (node_modules, dist, build, out, target,
# venv, __pycache__, coverage, graphify-out, logs, ...), fixture/snapshot/
# golden-file directories, and LICENSE*/NOTICE*/COPYING* legal text.
#
# Optional .env next to this script (copy .env.example):
#   DOC_EXTENSIONS           file extensions treated as documentation (default .md,.txt)
#   MAX_CHANGED_FILES        cap on changed files inspected per Stop (default 100)
#   MAX_DOC_FILES            cap on tracked doc files inventoried (default 200)
#   MAX_FINDINGS             cap on paths listed in a report (default 20)
#   REQUIRE_ACKNOWLEDGEMENT  master switch for the mandatory block (default true)
#   EXTRA_INCLUDE_PATTERNS   extra relative-path wildcard patterns to treat as impact-worthy (semicolon separated)
#   EXTRA_EXCLUDE_PATTERNS   extra relative-path wildcard patterns to exclude (semicolon separated)
# Configuration can never override the hard exclusions above.

param(
    [switch]$Acknowledge,
    [string]$ProjectRoot,
    [string]$ImpactFingerprint,
    [ValidateSet('Updated', 'NoUpdate')][string]$Result,
    [string]$Files = '',
    [string]$Reason = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
function Get-BoolConfig { param([string]$Key, [bool]$Default) if ($config.ContainsKey($Key)) { return ($config[$Key] -eq 'true') }; return $Default }
function Get-IntConfig { param([string]$Key, [int]$Default) if ($config.ContainsKey($Key)) { $parsed = 0; if ([int]::TryParse($config[$Key], [ref]$parsed)) { return $parsed } }; return $Default }

$docExtensions = @('.md', '.txt')
if ($config.ContainsKey('DOC_EXTENSIONS') -and $config['DOC_EXTENSIONS'] -ne '') {
    $docExtensions = @($config['DOC_EXTENSIONS'].Split(',') | ForEach-Object {
            $e = $_.Trim().ToLowerInvariant()
            if ($e -ne '' -and -not $e.StartsWith('.')) { $e = '.' + $e }
            $e
        } | Where-Object { $_ -ne '' -and $_ -ne '.' })
}
$maxChangedFiles = Get-IntConfig 'MAX_CHANGED_FILES' 100
$maxDocFiles = Get-IntConfig 'MAX_DOC_FILES' 200
$maxFindings = Get-IntConfig 'MAX_FINDINGS' 20
$requireAck = Get-BoolConfig 'REQUIRE_ACKNOWLEDGEMENT' $true
$extraInclude = @()
if ($config.ContainsKey('EXTRA_INCLUDE_PATTERNS')) { $extraInclude = @($config['EXTRA_INCLUDE_PATTERNS'].Split(';') | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }) }
$extraExclude = @()
if ($config.ContainsKey('EXTRA_EXCLUDE_PATTERNS')) { $extraExclude = @($config['EXTRA_EXCLUDE_PATTERNS'].Split(';') | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }) }

$script:HardExcludeDirs = @(
    '.git', '.ai', '.claude', '.codex', '.agents', '.cross-project-sync',
    'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target',
    'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env',
    'bin', 'obj', 'graphify-out', 'logs', '.next', '.nuxt', '.tox', '.ci-runner'
)
$script:HardExcludeNameFragments = @('fixture', 'snapshot', 'golden', '__snapshots__')
$script:LegalNamePattern = '^(LICENSE|NOTICE|COPYING)'

function Test-HardExcludedPath {
    param([string]$RelPath)
    $relLower = $RelPath.ToLowerInvariant().Replace('\', '/')
    if ($relLower -eq 'secrets.md') { return $true }
    foreach ($seg in $relLower.Split('/')) {
        if ($script:HardExcludeDirs -contains $seg) { return $true }
    }
    foreach ($frag in $script:HardExcludeNameFragments) { if ($relLower.Contains($frag)) { return $true } }
    $leaf = Split-Path -Leaf $RelPath
    if ($leaf -match $script:LegalNamePattern) { return $true }
    foreach ($pattern in $extraExclude) { if ($RelPath -like $pattern) { return $true } }
    return $false
}

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'

# ==========================================================================
# -Acknowledge: direct CLI command, not a hook-event invocation.
# ==========================================================================
if ($Acknowledge) {
    if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        Write-Host 'Docs-Freshness-Check: -ProjectRoot is required and must be an existing directory.'
        exit 1
    }
    $rootFull = Normalize-Path $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($ImpactFingerprint)) {
        Write-Host 'Docs-Freshness-Check: -ImpactFingerprint is required.'
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($Result)) {
        Write-Host 'Docs-Freshness-Check: -Result Updated|NoUpdate is required.'
        exit 1
    }
    $reasonTrim = $Reason.Trim()
    $genericReasons = @('none', 'not needed', 'n/a', 'na', 'done', 'ok', 'fine', 'nothing', 'no reason', 'update', 'updated', 'no update', 'skip', 'skipped')
    if ($reasonTrim -eq '' -or $genericReasons -contains $reasonTrim.ToLowerInvariant()) {
        Write-Host 'Docs-Freshness-Check: -Reason must be a concrete, non-generic explanation.'
        exit 1
    }
    $fileList = @()
    if (-not [string]::IsNullOrWhiteSpace($Files)) {
        $fileList = @($Files.Split(',') | ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_ -ne '' })
    }
    if ($Result -eq 'Updated' -and $fileList.Count -eq 0) {
        Write-Host 'Docs-Freshness-Check: -Result Updated requires at least one -Files entry.'
        exit 1
    }
    $invalid = @()
    foreach ($f in $fileList) {
        if ([System.IO.Path]::IsPathRooted($f) -or $f.Contains('..') -or $f.StartsWith('//') -or $f -match '^[A-Za-z]:') { $invalid += $f; continue }
        $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
        if ($docExtensions -notcontains $ext) { $invalid += $f; continue }
        if (Test-HardExcludedPath $f) { $invalid += $f; continue }
        $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($f.Replace('/', '\'))))
        if (-not (Test-PathInside -Candidate $full -Parent $rootFull)) { $invalid += $f; continue }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $invalid += $f; continue }
        $tracked = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'ls-files', '--', $f)) | Where-Object { $_ })
        $staged = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'diff', '--cached', '--name-only', '--', $f)) | Where-Object { $_ })
        if ($tracked.Count -eq 0 -and $staged.Count -eq 0) { $invalid += $f; continue }
    }
    if ($invalid.Count -gt 0) {
        Write-Host ('Docs-Freshness-Check: rejected - not a canonical tracked/staged in-project doc file: ' + ($invalid -join ', '))
        exit 1
    }
    $ackKey = Get-ShortHash $rootFull.ToLowerInvariant()
    $ackPath = Join-Path $stateDir ('DocsFreshnessCheck-ack-' + $ackKey + '.json')
    $record = [ordered]@{
        impactFingerprint = $ImpactFingerprint
        result            = $Result
        files             = $fileList
        reason            = $reasonTrim
        timestampUtc      = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonFileAtomic -Value $record -Path $ackPath
    Write-Host 'Docs-Freshness-Check: review acknowledged.'
    exit 0
}

# ==========================================================================
# Hook-event invocation (stdin JSON).
# ==========================================================================
$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
# Receipt for this Stop round (spec 007 RD-4): running now; pass, block or error
# when the gate finishes. A timeout kill leaves it running, never a pass.
$gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Docs-Freshness-Check' } else { $null }
try {
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$rootFull = Normalize-Path $cwd
$sessionId = [string](Get-Field $hookInput 'session_id')
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'Stop' -and $eventName -ne 'PreToolUse') { exit 0 }

# Is this tool call a `git push`? Returns the directory git pushes from, or ''.
# The command is DATA: tokenized, never executed or re-parsed as a nested shell.
function Get-GitPushDirectory {
    param($HookInput, [string]$Cwd)
    $toolInput = Get-Field $HookInput 'tool_input'
    if ($null -eq $toolInput) { return '' }
    $raw = Get-Field $toolInput 'command'
    if ($null -eq $raw) { $raw = Get-Field $toolInput 'cmd' }
    $tokens = @()
    if ($raw -is [string]) {
        if ($raw.Length -gt 8192) { return '' }
        $tokens = @(Split-CommandTokens -Text $raw)
    }
    elseif ($raw -is [System.Collections.IEnumerable]) { $tokens = @(@($raw) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' }) }
    # `a; git push` usually arrives with the semicolon glued to the token before
    # it; the shared tokenizer splits only on a standalone separator.
    $split = New-Object System.Collections.Generic.List[string]
    foreach ($token in $tokens) {
        if ($token.Length -gt 1 -and $token.EndsWith(';')) { [void]$split.Add($token.TrimEnd(';')); [void]$split.Add(';') }
        else { [void]$split.Add($token) }
    }
    foreach ($segment in @(Split-CommandSegments -Tokens $split.ToArray())) {
        $seg = @($segment)
        if ($seg.Count -lt 2 -or (Get-ProgramName $seg[0]) -ne 'git') { continue }
        $dir = $Cwd
        $i = 1
        while ($i -lt $seg.Count -and $seg[$i].StartsWith('-')) {
            if (@('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env') -ccontains $seg[$i]) {
                if ($i + 1 -ge $seg.Count) { break }
                if ($seg[$i] -ceq '-C') {
                    $value = $seg[$i + 1]
                    # .NET Framework throws on characters a path cannot hold (`a|b`): not a push this hook can place.
                    try { $dir = if ([System.IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $dir $value } } catch { return '' }
                }
                $i += 2
                continue
            }
            $i++
        }
        if ($i -lt $seg.Count -and $seg[$i] -ceq 'push') { return $dir }
    }
    return ''
}

if ($eventName -eq 'PreToolUse') {
    $commandTokensPath = Join-Path $PSScriptRoot '_commandtokens.ps1'
    if (-not (Test-Path -LiteralPath $commandTokensPath -PathType Leaf)) { $commandTokensPath = Join-Path $PSScriptRoot '..\_commandtokens.ps1' }
    . $commandTokensPath
    $pushDir = Get-GitPushDirectory -HookInput $hookInput -Cwd $rootFull
    if ($pushDir -eq '' -or -not (Test-Path -LiteralPath $pushDir -PathType Container)) { exit 0 }
    $rootFull = Normalize-Path $pushDir
}

$gitAvailable = ($null -ne (Get-Command git -ErrorAction SilentlyContinue))
if ($gitAvailable) {
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'rev-parse', '--is-inside-work-tree')
    $gitAvailable = ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
}
if (-not $gitAvailable) { exit 0 }

$projectKey = Get-ShortHash $rootFull.ToLowerInvariant()
$baselinePath = Join-Path $stateDir ('DocsFreshnessCheck-baseline-' + $projectKey + '.json')
$ackPath = Join-Path $stateDir ('DocsFreshnessCheck-ack-' + $projectKey + '.json')

# -c core.quotepath=false: without it, git quotes+escapes a non-ASCII tracked
# name (e.g. "caf\303\251.md" for a name ending in e-acute) - that raw quoted string then flows
# into [System.IO.Path]::GetExtension() at every call site below, and the
# embedded '"' throws (illegal path character) on PS 5.1, aborting the whole
# hook. Raw UTF-8 output can never contain that quoting, so it never reaches
# GetExtension in a form that can throw.
function Get-TrackedFiles {
    param([string]$Root)
    return @((Invoke-QuietCommand -FilePath git -ArgumentList @('-c', 'core.quotepath=false', '-C', $Root, 'ls-files')) | Where-Object { $_ } | Sort-Object -Unique)
}

# ==========================================================================
# SessionStart: silent, metadata-only baseline.
# ==========================================================================
if ($eventName -eq 'SessionStart') {
    $headSha = ''
    $h = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'rev-parse', 'HEAD')
    if ($LASTEXITCODE -eq 0) { $headSha = [string]$h }

    $allTracked = Get-TrackedFiles -Root $rootFull
    $docPaths = @($allTracked | Where-Object { $docExtensions -contains ([System.IO.Path]::GetExtension($_).ToLowerInvariant()) -and -not (Test-HardExcludedPath $_) } | Select-Object -First $maxDocFiles)
    $docHashes = [ordered]@{}
    foreach ($rel in $docPaths) {
        $full = Join-Path $rootFull ($rel.Replace('/', '\'))
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            try { $docHashes[$rel] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash } catch { }
        }
    }
    $baseline = [ordered]@{
        sessionId        = $sessionId
        startingHeadSha  = $headSha
        repoFingerprint  = (Get-RepoStateFingerprint -ProjectRoot $rootFull)
        docHashes        = $docHashes
        timestampUtc     = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonFileAtomic -Value $baseline -Path $baselinePath
    exit 0
}

# ==========================================================================
# Shared detection. Stop and the PreToolUse push gate classify through these
# same functions, so the two can never disagree about what counts as impact.
# ==========================================================================
function Get-ChangedEntries {
    param([string]$Root, [string[]]$Range, [switch]$WithUntracked)
    $changed = New-Object System.Collections.Generic.List[object]
    # -c core.quotepath=false here too: these Path values also reach
    # [System.IO.Path]::GetExtension() below (real-content classification,
    # doc/non-doc split) - same crash risk as Get-TrackedFiles above.
    $raw = Invoke-QuietCommand -FilePath git -ArgumentList (@('-c', 'core.quotepath=false', '-C', $Root, 'diff', '--name-status') + $Range)
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($raw | Where-Object { $_ })) {
            $parts = [string]$line -split "`t"
            if ($parts.Count -ge 2) { [void]$changed.Add([pscustomobject]@{ Status = $parts[0]; Path = $parts[$parts.Count - 1] }) }
        }
    }
    if ($WithUntracked) {
        # Untracked new files clearly intended for the repo (not ignored).
        $untracked = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-c', 'core.quotepath=false', '-C', $Root, 'status', '--porcelain', '--untracked-files=all')) | Where-Object { $_ -and ([string]$_).StartsWith('??') })
        foreach ($u in $untracked) {
            $p = ([string]$u).Substring(3).Trim().Trim('"')
            [void]$changed.Add([pscustomobject]@{ Status = 'A'; Path = $p })
        }
    }
    return $changed.ToArray()
}

function Get-CommentPrefix {
    param([string]$Ext)
    if (@('.ps1', '.psm1', '.py', '.sh', '.yml', '.yaml', '.rb', '.pl') -contains $Ext) { return '#' }
    if (@('.js', '.ts', '.jsx', '.tsx', '.go', '.cs', '.java', '.rs', '.c', '.cpp', '.h', '.php', '.swift', '.kt') -contains $Ext) { return '//' }
    return $null
}

function Test-RealContentChange {
    param([string]$Root, [string]$RelPath, [string[]]$Range)
    $ext = [System.IO.Path]::GetExtension($RelPath).ToLowerInvariant()
    $commentPrefix = Get-CommentPrefix $ext
    $diffArgs = @('-C', $Root, 'diff', '--unified=0') + $Range + @('--', $RelPath)
    $lines = Invoke-QuietCommand -FilePath git -ArgumentList $diffArgs
    if ($LASTEXITCODE -ne 0) { return $true }
    foreach ($line in @($lines | Where-Object { $_ })) {
        $l = [string]$line
        if ($l.StartsWith('+++') -or $l.StartsWith('---') -or $l.StartsWith('@@') -or $l.StartsWith('diff ') -or $l.StartsWith('index ')) { continue }
        if (-not ($l.StartsWith('+') -or $l.StartsWith('-'))) { continue }
        $content = $l.Substring(1).Trim()
        if ($content -eq '') { continue }
        if ($null -ne $commentPrefix -and $content.StartsWith($commentPrefix)) { continue }
        return $true
    }
    return $false
}

# The real impact among $Changed: non-doc, not hard-excluded, and not a
# comment/blank-only edit, each judged against the range it was listed from.
function Get-RealImpactFiles {
    param([string]$Root, [object[]]$Changed, [string[]]$Range)
    $changedPaths = @($Changed | Sort-Object Path -Unique)
    if ($changedPaths.Count -gt $maxChangedFiles) { $changedPaths = @($changedPaths | Select-Object -First $maxChangedFiles) }
    $impact = New-Object System.Collections.Generic.List[string]
    foreach ($c in $changedPaths) {
        $forceIncluded = $false
        foreach ($pattern in $extraInclude) { if ($c.Path -like $pattern) { $forceIncluded = $true; break } }
        if ((Test-HardExcludedPath $c.Path) -and -not $forceIncluded) { continue }
        $ext = [System.IO.Path]::GetExtension($c.Path).ToLowerInvariant()
        if ($docExtensions -contains $ext) { continue }
        if ($c.Status -eq 'A' -or $c.Status -eq 'D' -or ([string]$c.Status).StartsWith('R') -or ([string]$c.Status).StartsWith('C')) {
            [void]$impact.Add($c.Path)
            continue
        }
        if (Test-RealContentChange -Root $Root -RelPath $c.Path -Range $Range) { [void]$impact.Add($c.Path) }
    }
    return $impact.ToArray()
}

# Content-hash the REAL IMPACT (non-doc) files only - never the generic
# repo-state fingerprint, which also reflects doc-file status lines and
# would otherwise let an unrelated documentation edit silently shift the
# fingerprint and invalidate a still-valid acknowledgement (a documentation
# edit must never erase the identity of the functional task changes).
# The current HEAD is left out for the same reason: committing the reviewed
# docs moves HEAD, and a fingerprint that moved with it denied the push that
# carries those docs a second time and orphaned the acknowledgement for it.
function Get-ImpactFingerprint {
    param([string]$Root, [string]$StartingHead, [string[]]$Files)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($Files | Sort-Object -Unique)) {
        $full = Join-Path $Root ($f.Replace('/', '\'))
        $blobHash = 'deleted'
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $blobHash = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'hash-object', '--', $f))
            if ($LASTEXITCODE -ne 0) { $blobHash = 'unreadable' }
        }
        [void]$parts.Add($f + ':' + $blobHash)
    }
    return (Get-ShortHash ($StartingHead + '|' + ($parts.ToArray() -join ',')))
}

function Get-ReviewRequestLines {
    param([string]$Root, [string[]]$ImpactFiles, [string]$Fingerprint)
    $allDocFiles = @(Get-TrackedFiles -Root $Root | Where-Object { $docExtensions -contains ([System.IO.Path]::GetExtension($_).ToLowerInvariant()) -and -not (Test-HardExcludedPath $_) } | Select-Object -First $maxDocFiles)

    $conventionalNames = @('README', 'CHANGELOG', 'CONTRIBUTING', 'SECURITY', 'FAQ', 'INSTALL', 'USAGE', 'API', 'CONFIG', 'MIGRATION', 'TROUBLESHOOTING')
    $impactDirs = @($ImpactFiles | ForEach-Object { Split-Path -Parent $_ } | Where-Object { $null -ne $_ } | Select-Object -Unique)

    $ranked = New-Object System.Collections.Generic.List[string]
    $rest = New-Object System.Collections.Generic.List[string]
    foreach ($doc in $allDocFiles) {
        $leaf = ([System.IO.Path]::GetFileNameWithoutExtension($doc)).ToUpperInvariant()
        $isConventional = $false
        foreach ($name in $conventionalNames) { if ($leaf.StartsWith($name)) { $isConventional = $true; break } }
        $docDir = Split-Path -Parent $doc
        $isProximate = $impactDirs -contains $docDir
        if ($isConventional -or $isProximate) { [void]$ranked.Add($doc) } else { [void]$rest.Add($doc) }
    }
    $candidateDocs = @(@($ranked.ToArray()) + @($rest.ToArray()) | Select-Object -First $maxFindings)

    $boundedImpact = @($ImpactFiles | Select-Object -First $maxFindings)
    $ackCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Acknowledge -ProjectRoot "' + $Root + '" -ImpactFingerprint "' + $Fingerprint + '" -Result Updated -Files "<comma-separated relative doc paths>" -Reason "<concise factual reason>"'
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('DOCS FRESHNESS CHECK: this task changed ' + $boundedImpact.Count + ' project file(s) that may make published documentation stale: ' + ($boundedImpact -join ', ') + '.')
    if ($candidateDocs.Count -gt 0) {
        [void]$lines.Add('Candidate tracked documentation to review (ranked): ' + ($candidateDocs -join ', ') + '.')
    }
    else {
        [void]$lines.Add('No tracked .md/.txt documentation exists yet in this project to review.')
    }
    # E-10: the review-topic list also names encoding policy/exceptions, hook
    # lifecycle (install/update/status/uninstall) and native chain order, and
    # documented workflow boundaries - the doc-impact areas the UTF-8 hook and
    # ::deep-debug work introduced. Detection stays generic (any real non-doc
    # change); pure internal changes still clear with -Result NoUpdate.
    [void]$lines.Add('Check whether any of these are now stale: user-visible behavior/features; CLI commands, flags, prompts, menu numbering/labels/output/examples; config keys/env vars/defaults; public APIs/exports/endpoints/schemas; install/prerequisites/runtime/dependency instructions; file paths/project layout; deployment/migration/compatibility/security notes; troubleshooting/limitations; text-encoding policy and documented encoding-exception formats; hook install/update/status/uninstall behavior and native Git hook chain order; documented workflow boundaries (e.g. ::deep-debug and the single final Ponytail pass); or published test/assertion counts and capability lists.')
    [void]$lines.Add('Update ONLY the tracked public .md/.txt files actually made stale by this task - do not edit unrelated docs merely for consistency or wording.')
    [void]$lines.Add('Then run exactly one acknowledgement command to clear this: ' + $ackCommand + ' (use -Result NoUpdate -Reason "<why no doc became inaccurate>" instead if nothing needs updating).')
    return $lines.ToArray()
}

# The pushed HEAD, when Ci-Status-Check recorded that exact SHA all-green and
# no impact file is still uncommitted; otherwise ''. Read-only and local: the
# note is what Ci-Status-Check already saw on GitHub (the same fields
# Test-Completion-Check's _cievidence.ps1 accepts). Its key hashes the raw hook
# cwd, so the raw and the normalized root are both tried.
function Get-CiGreenHead {
    param([string]$Root, [string[]]$RootKeys, [string[]]$ImpactFiles)
    $repo = Get-GitHubRepository -ProjectRoot $Root
    if ($null -eq $repo -or [string]::IsNullOrWhiteSpace([string]$repo.Repository)) { return '' }
    $head = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) { return '' }
    $head = $head.Trim()
    $status = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-c', 'core.quotepath=false', '-C', $Root, 'status', '--porcelain', '--untracked-files=all') | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { return '' }
    foreach ($entry in $status) {
        $p = [string]$entry
        if ($p.Length -lt 4) { continue }
        $p = $p.Substring(3).Trim().Trim('"')
        if ($p.Contains(' -> ')) { $p = $p.Substring($p.LastIndexOf(' -> ') + 4) }
        if ($ImpactFiles -contains $p) { return '' }
    }
    foreach ($key in @($RootKeys | Where-Object { $_ } | Select-Object -Unique)) {
        $path = Join-Path $stateDir ('CiStatusCheck-' + (Get-ShortHash ($key.ToLowerInvariant() + '|' + ([string]$repo.Repository).ToLowerInvariant())) + '.txt')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $note = @()
        try { $note = @([System.IO.File]::ReadAllLines($path)) } catch { continue }
        if ($note.Count -ge 4 -and $note[0].Trim() -ceq $head -and $note[1].Trim() -ceq 'verified' -and $note[3].Trim() -ceq 'ci-green') { return $head }
    }
    return ''
}

# ==========================================================================
# Stop: task-delta detection -> ranked candidates -> mandatory acknowledgement.
# PreToolUse on a git push: the same, plus the commits the upstream lacks.
# ==========================================================================
# Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
# for ANY gate's block, and exiting on it alone let one block silence the
# other twelve on the same Stop.
if ($eventName -eq 'Stop' -and (Test-StopStandDown -HookInput $hookInput -HookName 'Docs-Freshness-Check')) { exit 0 }

try {
    $baseline = Read-JsonFile -Path $baselinePath
    $baselineAvailable = ($null -ne $baseline) -and ($sessionId -ne '') -and ([string](Get-Field $baseline 'sessionId') -eq $sessionId)
    $startingHead = if ($baselineAvailable) { [string](Get-Field $baseline 'startingHeadSha') } else { '' }

    # git diff <ref> (no second ref) compares that ref against the CURRENT
    # working tree - i.e. committed + staged + unstaged changes in one call.
    # Missing baseline -> conservative fallback: only currently uncommitted
    # changes against HEAD (we cannot know how far back the task started).
    $diffRange = if ($baselineAvailable -and $startingHead -ne '') { $startingHead } else { 'HEAD' }
    $realImpactFiles = @(Get-RealImpactFiles -Root $rootFull -Changed @(Get-ChangedEntries -Root $rootFull -Range @($diffRange) -WithUntracked) -Range @($diffRange))

    if ($eventName -eq 'PreToolUse') {
        # What leaves is what the upstream lacks. Nothing there with real
        # impact (nothing outgoing, or documentation-only commits) holds
        # nothing. No upstream yet: the task delta alone.
        $upstream = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'rev-parse', '--verify', '-q', '@{u}'))
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
            $outRange = @($upstream.Trim() + '...HEAD')
            $outgoing = @(Get-RealImpactFiles -Root $rootFull -Changed @(Get-ChangedEntries -Root $rootFull -Range $outRange) -Range $outRange)
            if ($outgoing.Count -eq 0) { exit 0 }
            $realImpactFiles = @(@($realImpactFiles) + @($outgoing) | Sort-Object -Unique)
        }
    }

    if ($realImpactFiles.Count -eq 0) { exit 0 }
    $impactFingerprint = Get-ImpactFingerprint -Root $rootFull -StartingHead $startingHead -Files $realImpactFiles

    $ackValid = -not $requireAck
    if ($requireAck) {
        $ack = Read-JsonFile -Path $ackPath
        if ($null -ne $ack -and [string](Get-Field $ack 'impactFingerprint') -eq $impactFingerprint) { $ackValid = $true }
    }
    if ($ackValid) { exit 0 }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-ReviewRequestLines -Root $rootFull -ImpactFiles $realImpactFiles -Fingerprint $impactFingerprint)) { [void]$lines.Add($line) }

    if ($eventName -eq 'PreToolUse') {
        # Once per fingerprint. The retry passes, but it acknowledges nothing:
        # Stop still asks for the acknowledgement.
        $pushDenyPath = Join-Path $stateDir ('DocsFreshnessCheck-pushdeny-' + $projectKey + '.txt')
        $denied = ''
        try { if (Test-Path -LiteralPath $pushDenyPath -PathType Leaf) { $denied = ([System.IO.File]::ReadAllText($pushDenyPath)).Trim() } } catch { $denied = '' }
        if ($denied -eq $impactFingerprint) { exit 0 }
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($pushDenyPath, $impactFingerprint)
        $lines.Insert(1, 'This git push is held once for that review: review/update the docs now and commit them so they land in this one push (CI runs once), then acknowledge and push again.')
        exit (Write-HookResult -EventName 'PreToolUse' -Kind 'deny' -Reason ($lines.ToArray() -join "`n")).ExitCode
    }

    $greenHead = Get-CiGreenHead -Root $rootFull -RootKeys @($cwd, $rootFull) -ImpactFiles $realImpactFiles
    if ($greenHead -ne '') {
        $sha7 = $greenHead.Substring(0, [Math]::Min(7, $greenHead.Length))
        [void]$lines.Add('CI is already green on the pushed HEAD ' + $sha7 + ': put the documentation update in a documentation-only commit with [skip ci] in its message, push it, run no suite, and report that the tests passed on the parent SHA ' + $sha7 + '.')
    }
    $reason = $lines.ToArray() -join "`n"
    # Record the block so THIS hook's own re-entry is recognised; another
    # gate's block must not mute it, and its own must not repeat.
    $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Docs-Freshness-Check' -FindingFingerprint $impactFingerprint -EventName $eventName -Reason $reason
    exit $emit.ExitCode
}
catch {
    # Once per session. A detection error that persists (a corrupt state file,
    # a failing git) would otherwise re-emit on every Stop, and on Claude Code
    # a Stop additionalContext re-invokes the model - a loop with nothing to
    # act on. A new session is warned again.
    $errStampPath = Join-Path $stateDir ('DocsFreshnessCheck-error-' + $projectKey + '.txt')
    $errTold = $false
    try {
        if ($sessionId -ne '' -and (Test-Path -LiteralPath $errStampPath -PathType Leaf)) {
            $errTold = (([System.IO.File]::ReadAllText($errStampPath)).Trim() -eq $sessionId)
        }
    }
    catch { $errTold = $false }
    if ($errTold) { exit 0 }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($errStampPath, $sessionId)
    }
    catch { }
    $errMsg = 'DOCS FRESHNESS CHECK: could not reliably determine whether documentation needs review this time (detection error) - do not assume documentation is current; review tracked README/CHANGELOG/docs manually if this task changed user-visible behavior.'
    # Client-aware through the shared adapter: Codex does not render
    # hookSpecificOutput.additionalContext at Stop (only systemMessage), so an
    # unconditional additionalContext here silently drops this warning on Codex.
    $null = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $errMsg
    exit 0
}
}
catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
