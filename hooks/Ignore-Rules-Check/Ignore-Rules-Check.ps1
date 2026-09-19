# Ignore-Rules-Check - enforces local/private git-ignore rules before/after tasks and pushes.
#
# Default public template files (.env.example/.env.sample/.env.template/.env.dist) are
# intentionally exempt via `!`-prefixed negation patterns and may stay tracked; only real
# env files (.env, .env.local, .env.production, ...) and other managed patterns are
# protected. Patterns are written/compared in INSERTION order (never alphabetically
# sorted - see below), and a path whose effective `git check-ignore` match is a negation
# is treated as explicitly allowed, never as a tracked/staged violation.

param([switch]$GitPrePush)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = if ($GitPrePush) {
    [pscustomobject]@{ cwd = (Get-Location).Path; hook_event_name = 'GitPrePush' }
}
else {
    Read-HookInput
}
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ($eventName -notin @('SessionStart', 'Stop', 'SubagentStop', 'GitPrePush')) { exit 0 }
$isStopEvent = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')
# Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
# for ANY gate's block, and exiting on it alone let one block silence the
# other twelve on the same Stop.
if ($isStopEvent -and (Test-StopStandDown -HookInput $hookInput -HookName 'Ignore-Rules-Check')) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }
$inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { exit 0 }

$patterns = New-Object System.Collections.Generic.List[string]
# ORDER IS SEMANTIC, so nothing here is ever reordered or removed - the set is
# declared stable and last-match/negation behaviour depends on the positions.
# The 2026-09-19 additions go in their canonical places: both Spec Kit
# directories straight after /.ai/ (infrastructure AND the per-feature
# spec/plan/tasks - the tracking half was reversed on the same day, so neither
# is committed), then the regenerated code index after /graphify-out/, then the
# local plans directory.
@(
    '/.ai/', '/.specify/', '/specs/', '/secrets.md', '/explain-AI.md', '/reference.md',
    '/CLAUDE.md', '/AGENTS.md',
    '/.agents/', '/.claude/', '/.kiro/', '/.codex/', '/.cursor/', '/.cline/', '/graphify-out/',
    '/.codebase-memory/', '/plans/',
    '.ignoreme', '**/.ignoreme', '/.env', '/.env.*', '!/.env.example', '!/.env.sample',
    '!/.env.template', '!/.env.dist'
) | ForEach-Object { [void]$patterns.Add($_) }

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
if ($config.ContainsKey('EXTRA_PATTERNS')) {
    foreach ($item in $config['EXTRA_PATTERNS'].Split(';')) {
        $item = $item.Trim()
        if ($item -ne '') { [void]$patterns.Add($item) }
    }
}

# Extract only path-like backtick tokens from explicit ignore/local-only rules.
$ruleFiles = New-Object System.Collections.Generic.List[string]
foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
    $path = Join-Path $cwd $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { [void]$ruleFiles.Add($path) }
}
foreach ($relativeDir in @('.agents\rules', '.claude\rules', '.codex\rules', '.cursor\rules', '.cline\rules')) {
    $dir = Join-Path $cwd $relativeDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue)) {
        [void]$ruleFiles.Add($file.FullName)
    }
}
foreach ($file in $ruleFiles) {
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if ($line -notmatch '(?i)(git.?ignore|local-only|never\s+(?:be\s+)?commit|do\s+not\s+commit|must\s+not.*commit)') { continue }
        foreach ($match in [regex]::Matches($line, '`([^`]+)`')) {
            $item = $match.Groups[1].Value.Trim().Replace('\', '/')
            $item = $item -replace '^(?i)<(?:project|repo)(?:Root)?>/', ''
            if ($item -eq '' -or $item -match '[\s:|<>]' -or $item -in @('.git', '.git/', '.gitignore')) { continue }
            if ($item.StartsWith('./')) { $item = $item.Substring(2) }
            if (-not $item.StartsWith('/') -and -not $item.StartsWith('**/')) { $item = '/' + $item }
            if ($item -match '^/?[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.*-]+)*/?$' -or $item.StartsWith('**/')) {
                [void]$patterns.Add($item)
            }
        }
    }
}
# Dedupe while PRESERVING insertion order - never alphabetically sort. Gitignore is
# last-match-wins: the built-in order intentionally puts a negation exception
# (`!/.env.example`) AFTER the broader ignore it un-ignores (`/.env.*`). An alphabetical
# sort would move every `!`-prefixed negation before its `/`-prefixed pattern (`!` < `/`
# in ASCII), silently making every negation exception dead on arrival once written.
$patterns = @($patterns | Select-Object -Unique)
# The PROTECTED set (used to flag a tracked/staged path that must be untracked) excludes
# negation/allow rules - a negation match means "explicitly allowed to stay tracked", not
# "protected". Only non-negated positive patterns are ever grounds for a block.
$protectedPatterns = @($patterns | Where-Object { -not $_.StartsWith('!') })

$ignorePath = Join-Path $cwd '.gitignore'
$existing = ''
if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($ignorePath)
}
$existingLines = @($existing -split '\r?\n' | ForEach-Object { $_.Trim() })
# Is a managed negation actually DOING anything? Presence alone is not enough: sorting an
# existing .gitignore (common tooling behaviour) hoists every '!' line above '/.env.*'
# ('!' < '/' in ASCII), which silently re-ignores the public templates AND makes an
# already-tracked .env.example match the protected '/.env.*' pattern, producing a false
# "TRACKED protected paths" block. A dead negation is treated as missing and re-appended.
#
# ASK GIT, do not re-derive gitignore semantics. This used to compare positions against
# every managed positive that precedes the negation in the canonical list, which was far
# too strong: `/plans/` cannot re-ignore `.env.example`, yet a `/plans/` line sitting later
# in the file than a correctly-anchored negation condemned it. And the hook appends its own
# block at the END, so its own positives landed after the user's mid-file negations - every
# run then judged them dead and appended again, for ever. Reported from a consumer project
# on 2026-09-20 and reproduced in this repository's own .gitignore the same day
# (`/plans/` at line 53 killing `!/.env.example` at line 47). `git check-ignore` answers
# the only question that matters - "is this path ignored right now" - including
# last-match-wins, and removes the whole ordered comparison. See `.ai/BUGS_HOOKS.md`.
function Test-NegationLive {
    param([string]$Negation, [string[]]$Lines, [string]$Root, [string[]]$Ordered)
    if ([array]::LastIndexOf($Lines, $Negation) -lt 0) { return $false }
    $path = $Negation.TrimStart('!').TrimStart('/')
    if ($path -eq '') { return $false }
    # A project that deliberately re-protects this exact path with its own
    # POSITIVE pattern wins. EXTRA_PATTERNS are appended after the defaults, so
    # such an override sits later in the canonical order than the negation it
    # overrides. Without this, git would report the path as ignored (correctly,
    # because the override is doing its job), the negation would be judged dead,
    # and re-appending it would silently defeat the override the project asked
    # for. Pinned by 'an explicit project-specific positive rule still blocks
    # .env.example'.
    $negAt = [array]::IndexOf($Ordered, $Negation)
    if ($negAt -ge 0) {
        $override = '/' + $path
        $overrideAt = [array]::LastIndexOf($Ordered, $override)
        if ($overrideAt -gt $negAt) { return $true }
    }
    # No git: presence is the whole answer. A machine that cannot run git cannot
    # push either, and guessing here is what used to loop.
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $true }
    Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'check-ignore', '--no-index', '-q', '--', $path) | Out-Null
    # 0 = git still ignores it, so the negation is NOT effective and is re-added.
    # 1 = not ignored, the negation is doing its job wherever it sits.
    # anything else is a git error: treat present as enough rather than loop.
    if ($LASTEXITCODE -eq 0) { return $false }
    return $true
}
$missing = @($patterns | Where-Object {
        if ($_.StartsWith('!')) { -not (Test-NegationLive -Negation $_ -Lines $existingLines -Root $cwd -Ordered $patterns) }
        else { $existingLines -notcontains $_ }
    })
if ($missing.Count -gt 0) {
    $prefix = $existing.TrimEnd()
    if ($prefix -ne '') { $prefix += "`n`n" }
    $header = '# Hook Maker: local/private files (auto-managed)'
    if ($existingLines -contains $header) { $header = '' }
    $block = @($header) + $missing | Where-Object { $_ -ne '' }
    [System.IO.File]::WriteAllText($ignorePath, $prefix + ($block -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

# A .gitignore entry does not untrack an already indexed file; block until fixed.
$tracked = New-Object System.Collections.Generic.List[string]
$staged = New-Object System.Collections.Generic.List[string]
$trackedFiles = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'ls-files') | Where-Object { $_ })
$stagedFiles = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff', '--cached', '--name-only') | Where-Object { $_ })
# One `git check-ignore -v` per BATCH of paths, never per path: a process spawn
# costs ~40 ms, so a 200-file repository paid ~9 s here at every Stop. The paths
# go on the command line (Windows caps it at 32,767 characters), so batches are
# cut by accumulated length. `-v` prints `<source>:<line>:<pattern><TAB><path>`
# for each MATCHING path and nothing for the rest; exit 1 only means "nothing
# in this batch matched", anything above 1 is a real error and the batch is
# skipped rather than guessed at.
$batchCharLimit = 8000
$batches = New-Object System.Collections.Generic.List[object]
$current = New-Object System.Collections.Generic.List[string]
$currentChars = 0
foreach ($file in @($trackedFiles + $stagedFiles | Sort-Object -Unique)) {
    if ($current.Count -gt 0 -and ($currentChars + $file.Length + 3) -gt $batchCharLimit) {
        [void]$batches.Add($current.ToArray())
        $current = New-Object System.Collections.Generic.List[string]
        $currentChars = 0
    }
    [void]$current.Add($file)
    $currentChars += $file.Length + 3
}
if ($current.Count -gt 0) { [void]$batches.Add($current.ToArray()) }
foreach ($paths in $batches) {
    $detail = @(Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $cwd, 'check-ignore', '--no-index', '-v', '--') + @($paths)))
    if ($LASTEXITCODE -gt 1 -or $detail.Count -eq 0) { continue }
    foreach ($line in $detail) {
        $text = [string]$line
        $tab = $text.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $source = $text.Substring(0, $tab)
        $file = $text.Substring($tab + 1)
        $colon = $source.LastIndexOf(':')
        if ($colon -lt 0) { continue }
        $matchedPattern = $source.Substring($colon + 1)
        # The effective (last-matching) rule is a negation - Git explicitly allows this path
        # to stay tracked (e.g. `.env.example` against `!/.env.example`). Never protected.
        if ($matchedPattern.StartsWith('!')) { continue }
        if ($protectedPatterns -notcontains $matchedPattern) { continue }
        if ($trackedFiles -contains $file) { [void]$tracked.Add($file) }
        if ($stagedFiles -contains $file) { [void]$staged.Add($file) }
    }
}

if ($missing.Count -eq 0 -and $tracked.Count -eq 0 -and $staged.Count -eq 0) { exit 0 }
$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('IGNORE RULES CHECK (' + $cwd + '):')
if ($missing.Count -gt 0) { [void]$lines.Add('Auto-added ' + $missing.Count + ' missing pattern(s) to .gitignore: ' + ($missing -join ', ')) }
if ($tracked.Count -gt 0) { [void]$lines.Add('TRACKED protected paths must be untracked before push (preserve local files): ' + (($tracked | Sort-Object -Unique) -join ', ')) }
if ($staged.Count -gt 0) { [void]$lines.Add('STAGED protected paths must be removed from the index before push: ' + (($staged | Sort-Object -Unique) -join ', ')) }
[void]$lines.Add('Review .gitignore, preserve local files, and add any other project-specific private/generated paths required by the current rules before pushing.')
$reason = $lines.ToArray() -join "`n"
if ($GitPrePush) {
    [Console]::Error.WriteLine($reason)
    exit 1
}
if ($isStopEvent) {
    # Record the block so THIS hook's own re-entry is recognised; another
    # gate's block must not mute it, and its own must not repeat.
    $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Ignore-Rules-Check' -EventName $eventName -Reason $reason
    exit $emit.ExitCode
}
$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $reason
exit $emit.ExitCode
