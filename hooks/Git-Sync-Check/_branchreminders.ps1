# Side-branch and push-once reminders (plan 012 step 2c, steering V38).
#
# ADVISORY ONLY. Rule (global-repository-rules.md): work stays on the default
# branch; a side branch, worktree or pull request needs the user's request or a
# forcing reason stated in the report, and then the whole task uses ONE branch
# and ONE pull request. A task pushes once, after all the work, because every
# push and every pull request starts its own CI run.
#
# PreToolUse context only - never a permission decision, so a reminder can
# neither approve a command the user's permission mode would ask about nor
# block one. The command text is classified as DATA; nothing here executes it.
# "The task still has open work" is measured, not guessed: uncommitted changes
# in the working tree at the moment of the push.

Set-StrictMode -Version 2.0

# Returns 'branch', 'push' or '' for one shell command line.
function Get-GitWorkflowCommandKind {
    param([AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command) -or $Command.Length -gt 8192) { return '' }
    foreach ($part in @($Command -split '&&|\|\||;|\r?\n|\|')) {
        $text = $part.Trim()
        if ($text -match '^(?:gh)\s+pr\s+create\b') { return 'branch' }
        if ($text -notmatch '^git(?:\s+-C\s+("[^"]*"|''[^'']*''|\S+))?\s+(.*)$') { continue }
        $rest = $Matches[2]
        if ($rest -match '^(?:checkout\s+-[bB]|switch\s+(?:-[cC]|--create|--force-create))\b') { return 'branch' }
        if ($rest -match '^worktree\s+add\b') { return 'branch' }
        # `git branch <name>` creates one; listing, deleting, renaming, showing
        # or configuring an existing branch does not.
        if ($rest -match '^branch\s+(?!-)[^\s]+\s*(?:\S+\s*)?$') { return 'branch' }
        if ($rest -match '^push\b') { return 'push' }
    }
    return ''
}

function Get-GitWorkflowReminder {
    param([Parameter(Mandatory = $true)]$HookInput)
    $toolInput = Get-Field $HookInput 'tool_input'
    if ($null -eq $toolInput) { return '' }
    $kind = Get-GitWorkflowCommandKind -Command ([string](Get-Field $toolInput 'command'))
    if ($kind -eq 'branch') {
        return ('GIT WORKFLOW REMINDER: work stays on the default branch. A side branch, worktree or pull request ' +
            'needs the user''s request or a forcing reason you state in the report (for example a protected default ' +
            'branch); then use ONE branch and ONE pull request for the whole task, and account for it at the end. ' +
            'Rule: global-repository-rules.md.')
    }
    if ($kind -eq 'push') {
        $cwd = [string](Get-Field $HookInput 'cwd')
        if ([string]::IsNullOrWhiteSpace($cwd) -or $null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
        $dirty = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'status', '--porcelain', '--untracked-files=no') -TimeoutSeconds 5 | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0 -or $dirty.Count -eq 0) { return '' }
        return ('GIT WORKFLOW REMINDER: this task still has ' + $dirty.Count + ' uncommitted change(s). A task pushes ONCE, ' +
            'after all the work - every push and every pull request starts its own CI run. Finish, commit, then push. ' +
            'Rule: global-repository-rules.md.')
    }
    return ''
}

# Stop: the open pull requests next to the branch list, so every side branch
# and PR this task opened is accounted for. Bounded and read-only; an
# unavailable gh or a non-GitHub remote says so rather than claiming none.
function Get-OpenPullRequestLine {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return 'Open pull requests: not checked (gh is not available).' }
    Push-Location -LiteralPath $RepoPath
    try { $raw = @(Invoke-QuietCommand -FilePath gh -ArgumentList @('pr', 'list', '--state', 'open', '--limit', '20', '--json', 'number,headRefName') -TimeoutSeconds 8); $ghExit = $LASTEXITCODE }
    finally { Pop-Location }
    if ($ghExit -ne 0) { return 'Open pull requests: not checked (gh pr list failed - no GitHub remote or no access).' }
    $prs = @()
    try { $prs = @(($raw -join "`n") | ConvertFrom-Json) } catch { return 'Open pull requests: not checked (unreadable gh output).' }
    if ($prs.Count -eq 0) { return 'Open pull requests: none.' }
    $names = @($prs | ForEach-Object { '#' + [string]$_.number + ' (' + [string]$_.headRefName + ')' })
    return ('Open pull requests: ' + ($names -join ', ') + ' - merge, close, or name each in the report with why it stays open.')
}
