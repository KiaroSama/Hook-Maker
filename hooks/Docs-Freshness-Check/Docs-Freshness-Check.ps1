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
    'bin', 'obj', 'graphify-out', 'logs', '.next', '.nuxt', '.tox'
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
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$rootFull = Normalize-Path $cwd
$sessionId = [string](Get-Field $hookInput 'session_id')
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'Stop') { exit 0 }

$gitAvailable = ($null -ne (Get-Command git -ErrorAction SilentlyContinue))
if ($gitAvailable) {
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'rev-parse', '--is-inside-work-tree')
    $gitAvailable = ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
}
if (-not $gitAvailable) { exit 0 }

$projectKey = Get-ShortHash $rootFull.ToLowerInvariant()
$baselinePath = Join-Path $stateDir ('DocsFreshnessCheck-baseline-' + $projectKey + '.json')
$ackPath = Join-Path $stateDir ('DocsFreshnessCheck-ack-' + $projectKey + '.json')

function Get-TrackedFiles {
    param([string]$Root)
    return @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'ls-files')) | Where-Object { $_ } | Sort-Object -Unique)
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
# Stop: task-delta detection -> ranked candidates -> mandatory acknowledgement.
# ==========================================================================
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }

try {
    $baseline = Read-JsonFile -Path $baselinePath
    $baselineAvailable = ($null -ne $baseline) -and ($sessionId -ne '') -and ([string](Get-Field $baseline 'sessionId') -eq $sessionId)
    $startingHead = if ($baselineAvailable) { [string](Get-Field $baseline 'startingHeadSha') } else { '' }

    # git diff <ref> (no second ref) compares that ref against the CURRENT
    # working tree - i.e. committed + staged + unstaged changes in one call.
    # Missing baseline -> conservative fallback: only currently uncommitted
    # changes against HEAD (we cannot know how far back the task started).
    $diffRange = if ($baselineAvailable -and $startingHead -ne '') { $startingHead } else { 'HEAD' }

    $changed = New-Object System.Collections.Generic.List[object]
    $raw = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'diff', '--name-status', $diffRange)
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($raw | Where-Object { $_ })) {
            $parts = [string]$line -split "`t"
            if ($parts.Count -ge 2) { [void]$changed.Add([pscustomobject]@{ Status = $parts[0]; Path = $parts[$parts.Count - 1] }) }
        }
    }
    # Untracked new files clearly intended for the repo (not ignored).
    $untracked = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'status', '--porcelain', '--untracked-files=all')) | Where-Object { $_ -and ([string]$_).StartsWith('??') })
    foreach ($u in $untracked) {
        $p = ([string]$u).Substring(3).Trim().Trim('"')
        [void]$changed.Add([pscustomobject]@{ Status = 'A'; Path = $p })
    }
    $changedPaths = @($changed | Sort-Object Path -Unique)
    if ($changedPaths.Count -gt $maxChangedFiles) { $changedPaths = @($changedPaths | Select-Object -First $maxChangedFiles) }

    $nonDocCandidates = New-Object System.Collections.Generic.List[object]
    $docChangedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($c in $changedPaths) {
        $forceIncluded = $false
        foreach ($pattern in $extraInclude) { if ($c.Path -like $pattern) { $forceIncluded = $true; break } }
        if ((Test-HardExcludedPath $c.Path) -and -not $forceIncluded) { continue }
        $ext = [System.IO.Path]::GetExtension($c.Path).ToLowerInvariant()
        if ($docExtensions -contains $ext) { [void]$docChangedPaths.Add($c.Path); continue }
        [void]$nonDocCandidates.Add($c)
    }

    function Get-CommentPrefix {
        param([string]$Ext)
        if (@('.ps1', '.psm1', '.py', '.sh', '.yml', '.yaml', '.rb', '.pl') -contains $Ext) { return '#' }
        if (@('.js', '.ts', '.jsx', '.tsx', '.go', '.cs', '.java', '.rs', '.c', '.cpp', '.h', '.php', '.swift', '.kt') -contains $Ext) { return '//' }
        return $null
    }

    function Test-RealContentChange {
        param([string]$Root, [string]$RelPath, [string]$Range)
        $ext = [System.IO.Path]::GetExtension($RelPath).ToLowerInvariant()
        $commentPrefix = Get-CommentPrefix $ext
        $diffArgs = @('-C', $Root, 'diff', '--unified=0', $Range, '--', $RelPath)
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

    $realImpactFiles = New-Object System.Collections.Generic.List[string]
    foreach ($c in $nonDocCandidates) {
        if ($c.Status -eq 'A' -or $c.Status -eq 'D' -or ([string]$c.Status).StartsWith('R') -or ([string]$c.Status).StartsWith('C')) {
            [void]$realImpactFiles.Add($c.Path)
            continue
        }
        if (Test-RealContentChange -Root $rootFull -RelPath $c.Path -Range $diffRange) {
            [void]$realImpactFiles.Add($c.Path)
        }
    }

    if ($realImpactFiles.Count -eq 0) { exit 0 }

    $currentHead = ''
    $h2 = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'rev-parse', 'HEAD')
    if ($LASTEXITCODE -eq 0) { $currentHead = [string]$h2 }
    # Content-hash the REAL IMPACT (non-doc) files only - never the generic
    # repo-state fingerprint, which also reflects doc-file status lines and
    # would otherwise let an unrelated documentation edit silently shift the
    # fingerprint and invalidate a still-valid acknowledgement (a documentation
    # edit must never erase the identity of the functional task changes).
    $impactContentParts = New-Object System.Collections.Generic.List[string]
    foreach ($f in ($realImpactFiles.ToArray() | Sort-Object)) {
        $full = Join-Path $rootFull ($f.Replace('/', '\'))
        $blobHash = 'deleted'
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $blobHash = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $rootFull, 'hash-object', '--', $f))
            if ($LASTEXITCODE -ne 0) { $blobHash = 'unreadable' }
        }
        [void]$impactContentParts.Add($f + ':' + $blobHash)
    }
    $impactSource = $startingHead + '|' + $currentHead + '|' + ($impactContentParts.ToArray() -join ',')
    $impactFingerprint = Get-ShortHash $impactSource

    $ackValid = -not $requireAck
    if ($requireAck) {
        $ack = Read-JsonFile -Path $ackPath
        if ($null -ne $ack -and [string](Get-Field $ack 'impactFingerprint') -eq $impactFingerprint) { $ackValid = $true }
    }
    if ($ackValid) { exit 0 }

    $allTrackedNow = Get-TrackedFiles -Root $rootFull
    $allDocFiles = @($allTrackedNow | Where-Object { $docExtensions -contains ([System.IO.Path]::GetExtension($_).ToLowerInvariant()) -and -not (Test-HardExcludedPath $_) } | Select-Object -First $maxDocFiles)

    $conventionalNames = @('README', 'CHANGELOG', 'CONTRIBUTING', 'SECURITY', 'FAQ', 'INSTALL', 'USAGE', 'API', 'CONFIG', 'MIGRATION', 'TROUBLESHOOTING')
    $impactDirs = @($realImpactFiles.ToArray() | ForEach-Object { Split-Path -Parent $_ } | Where-Object { $null -ne $_ } | Select-Object -Unique)

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

    $boundedImpact = @($realImpactFiles.ToArray() | Select-Object -First $maxFindings)
    $ackCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Acknowledge -ProjectRoot "' + $rootFull + '" -ImpactFingerprint "' + $impactFingerprint + '" -Result Updated -Files "<comma-separated relative doc paths>" -Reason "<concise factual reason>"'
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('DOCS FRESHNESS CHECK: this task changed ' + $boundedImpact.Count + ' project file(s) that may make published documentation stale: ' + ($boundedImpact -join ', ') + '.')
    if ($candidateDocs.Count -gt 0) {
        [void]$lines.Add('Candidate tracked documentation to review (ranked): ' + ($candidateDocs -join ', ') + '.')
    }
    else {
        [void]$lines.Add('No tracked .md/.txt documentation exists yet in this project to review.')
    }
    [void]$lines.Add('Check whether any of these are now stale: user-visible behavior/features; CLI commands, flags, prompts, menu numbering/labels/output/examples; config keys/env vars/defaults; public APIs/exports/endpoints/schemas; install/prerequisites/runtime/dependency instructions; file paths/project layout; deployment/migration/compatibility/security notes; troubleshooting/limitations; or published test/assertion counts and capability lists.')
    [void]$lines.Add('Update ONLY the tracked public .md/.txt files actually made stale by this task - do not edit unrelated docs merely for consistency or wording.')
    [void]$lines.Add('Then run exactly one acknowledgement command to clear this: ' + $ackCommand + ' (use -Result NoUpdate -Reason "<why no doc became inaccurate>" instead if nothing needs updating).')
    $reason = $lines.ToArray() -join "`n"
    @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
    exit 0
}
catch {
    $errMsg = 'DOCS FRESHNESS CHECK: could not reliably determine whether documentation needs review this time (detection error) - do not assume documentation is current; review tracked README/CHANGELOG/docs manually if this task changed user-visible behavior.'
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $errMsg } } | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
