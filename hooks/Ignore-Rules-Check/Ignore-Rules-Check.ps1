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
if ($isStopEvent -and (Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }
$inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { exit 0 }

$patterns = New-Object System.Collections.Generic.List[string]
@(
    '/.ai/', '/secrets.md', '/explain-AI.md', '/reference.md', '/CLAUDE.md', '/AGENTS.md',
    '/.agents/', '/.claude/', '/.kiro/', '/.codex/', '/.cursor/', '/.cline/', '/graphify-out/',
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
foreach ($relativeDir in @('.agents\rules', '.claude\rules', '.codex\rules', '.cursor\rules', '.cline\rules', '.kiro\rules')) {
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
# A managed negation is only ALIVE if it sits after every managed positive pattern that
# precedes it in insertion order - gitignore is last-match-wins. Presence alone is not
# enough: sorting an existing .gitignore (common tooling behaviour) hoists every '!' line
# above '/.env.*' ('!' < '/' in ASCII), which silently re-ignores the public templates AND
# makes an already-tracked .env.example match the protected '/.env.*' pattern, producing a
# false "TRACKED protected paths" block. A dead negation is therefore treated as missing
# and re-appended, restoring precedence without removing or weakening any existing rule.
function Test-NegationLive {
    param([string]$Negation, [string[]]$Ordered, [string[]]$Lines)
    $at = [array]::LastIndexOf($Lines, $Negation)
    if ($at -lt 0) { return $false }
    foreach ($pattern in $Ordered) {
        if ($pattern -eq $Negation) { break }
        if ($pattern.StartsWith('!')) { continue }
        if ([array]::LastIndexOf($Lines, $pattern) -gt $at) { return $false }
    }
    return $true
}
$missing = @($patterns | Where-Object {
        if ($_.StartsWith('!')) { -not (Test-NegationLive -Negation $_ -Ordered $patterns -Lines $existingLines) }
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
foreach ($file in @($trackedFiles + $stagedFiles | Sort-Object -Unique)) {
    $detail = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'check-ignore', '--no-index', '-v', '--', $file))
    if ($LASTEXITCODE -ne 0 -or $detail.Count -eq 0) { continue }
    $text = [string]$detail[0]
    $tab = $text.IndexOf("`t")
    if ($tab -lt 0) { continue }
    $source = $text.Substring(0, $tab)
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
    @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
    exit 0
}
@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $reason } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
