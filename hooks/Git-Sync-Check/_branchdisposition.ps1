# Git-Sync-Check - every branch gets a disposition before the task finishes.
#
# Dot-sourced by Git-Sync-Check.ps1; definitions only, no exit.
#
# The rule (global-repository-rules.md, "Leave no branch open"): when a task
# created or worked on a branch, every local and remote branch is merged into
# its base and deleted, closed and deleted once its unique commits are carried
# elsewhere or worthless, or named in the final report with the reason it
# survives. This file only DESCRIBES the branches for that decision: two
# bounded for-each-ref calls against the base, and no fetch, merge, deletion or
# worktree removal - disposition needs judgement, sometimes the owner's answer.
#
# Remote-tracking refs are only as fresh as the fetch Git-Sync-Check already
# runs at the top of every invocation; when that fetch failed, this says so
# instead of implying the picture is current.

$script:DispositionMaxBranches = 40

# The base to judge against: the remote's default branch when known, else the
# branch this session started on, else main/master when present.
function Get-DispositionBase {
    param([Parameter(Mandatory = $true)][string]$RepoPath, [string]$Fallback = '')
    $originHead = Invoke-Git @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') -RepoPath $RepoPath
    if ($originHead.Ok -and $originHead.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$originHead.Output[0])) {
        return ([string]$originHead.Output[0]).Trim()
    }
    if ($Fallback -ne '') { return $Fallback }
    foreach ($candidate in @('main', 'master')) {
        $probe = Invoke-Git @('rev-parse', '--verify', '--quiet', ('refs/heads/' + $candidate)) -RepoPath $RepoPath
        if ($probe.Ok) { return $candidate }
    }
    return ''
}

function Get-BranchDisposition {
    param([Parameter(Mandatory = $true)][string]$RepoPath, [string]$Fallback = '', [bool]$FetchOk = $true)
    $partial = New-Object System.Collections.Generic.List[string]
    $base = Get-DispositionBase -RepoPath $RepoPath -Fallback $Fallback
    if ($base -eq '') {
        [void]$partial.Add('no base branch could be determined (no origin/HEAD, no session branch, no main/master)')
        return [pscustomobject]@{ Base = ''; Merged = @(); Unique = @(); Partial = @($partial.ToArray()); Capped = $false }
    }
    $remotes = Invoke-Git @('remote') -RepoPath $RepoPath
    if (-not $remotes.Ok -or @($remotes.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
        [void]$partial.Add('no remote is configured, so only local branches are listed')
    }
    elseif (-not $FetchOk) {
        [void]$partial.Add('this run could not fetch, so remote-tracking branches are as of the last successful fetch')
    }
    $head = Invoke-Git @('symbolic-ref', '--quiet', 'HEAD') -RepoPath $RepoPath
    if (-not $head.Ok) { [void]$partial.Add('HEAD is detached') }

    $baseShort = $base -replace '^origin/', ''
    $keep = {
        param($name)
        $n = [string]$name
        if ([string]::IsNullOrWhiteSpace($n)) { return $false }
        if ($n -match '/HEAD$' -or $n -eq 'HEAD') { return $false }
        return -not ($n -eq $base -or $n -eq $baseShort -or $n -eq ('origin/' + $baseShort))
    }
    $merged = Invoke-Git @('for-each-ref', ('--merged=' + $base), '--format=%(refname:short)', 'refs/heads', 'refs/remotes') -RepoPath $RepoPath
    $unique = Invoke-Git @('for-each-ref', ('--no-merged=' + $base), '--format=%(refname:short)', 'refs/heads', 'refs/remotes') -RepoPath $RepoPath
    if (-not $merged.Ok -or -not $unique.Ok) { [void]$partial.Add('the branch listing against ' + $base + ' failed') }
    $mergedNames = @(@($merged.Output) | Where-Object { & $keep $_ } | ForEach-Object { ([string]$_).Trim() })
    $uniqueNames = @(@($unique.Output) | Where-Object { & $keep $_ } | ForEach-Object { ([string]$_).Trim() })
    $capped = ($mergedNames.Count + $uniqueNames.Count) -gt $script:DispositionMaxBranches
    return [pscustomobject]@{
        Base    = $base
        Merged  = @($mergedNames | Select-Object -First $script:DispositionMaxBranches)
        Unique  = @($uniqueNames | Select-Object -First $script:DispositionMaxBranches)
        Partial = @($partial.ToArray())
        Capped  = $capped
    }
}

function Get-BranchDispositionInstruction {
    param([Parameter(Mandatory = $true)]$Disposition)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Leave no branch open: every branch of this repository is merged into its base and deleted, closed and deleted once its unique commits are confirmed carried elsewhere or worthless, or named in your final report with the reason it survives. Never delete a branch with unique unmerged commits, a protected branch, an unknown branch, or someone else''s work; a branch whose content you cannot verify is reported, not disposed of.')
    if ($Disposition.Base -ne '') {
        if (@($Disposition.Merged).Count -gt 0) { [void]$lines.Add('- merged into ' + $Disposition.Base + ' (safe to delete once confirmed): ' + (@($Disposition.Merged) -join ', ')) }
        if (@($Disposition.Unique).Count -gt 0) { [void]$lines.Add('- holding commits not in ' + $Disposition.Base + ' (merge, confirm carried elsewhere, or explain): ' + (@($Disposition.Unique) -join ', ')) }
        if (@($Disposition.Merged).Count -eq 0 -and @($Disposition.Unique).Count -eq 0) { [void]$lines.Add('- no branch besides ' + $Disposition.Base + ' was found.') }
        if ($Disposition.Capped) { [void]$lines.Add('- the listing was capped at ' + $script:DispositionMaxBranches + ' per kind; more branches exist.') }
    }
    foreach ($p in @($Disposition.Partial)) { [void]$lines.Add('- partial coverage: ' + $p + '.') }
    return ($lines.ToArray() -join "`n")
}
