# Git-Sync-Check - the public commit identity reminder.
#
# Dot-sourced by Git-Sync-Check.ps1; definitions only, no exit.
#
# The owner's rule: the ONLY address on the owner's author, committer, tagger
# and trailer identities is the public one below. Asked how the hook should
# recognise a private address without ever holding it, the owner chose a
# REMINDER every time over a hashed list or a gate: the hook counts what is not
# the public address, never prints an address, and the agent does the checking
# and the rewriting. So this file reads and counts - it never blocks, never
# rewrites history, never force-pushes and never changes configuration.
#
# What is NOT counted as the owner's: bot identities (`[bot]`) and bare
# `noreply@<domain>` system addresses such as GitHub's own web-merge committer
# or an AI co-author trailer. A user noreply such as `<id>+name@users.noreply.
# github.com` IS a person's address and IS counted - that is the case the rule
# exists for.

$script:PublicCommitEmail = 'Kiaro.Sama.Dev@gmail.com'
# Bounded: the scan answers "is there anything to check", not "list it all".
$script:IdentityScanMaxCommits = 5000

function Test-SystemCommitEmail {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { return $true }
    $e = $Email.Trim().ToLowerInvariant()
    if ($e.Contains('[bot]')) { return $true }
    return ($e -match '^noreply@')
}

# Classifies every address in the given lines. Each line carries tab-separated
# fields; trailer fields may hold `Name <email>`, so only the bracketed part is
# taken from them. Returns COUNTS only - the addresses never leave this function.
function Measure-CommitIdentityLines {
    param([string[]]$Lines)
    $other = 0; $public = 0; $system = 0
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $lineHasOther = $false
        foreach ($field in ([string]$line -split "`t")) {
            $f = $field.Trim()
            if ($f -eq '') { continue }
            $m = [regex]::Match($f, '<([^<>\s]+@[^<>\s]+)>')
            $email = if ($m.Success) { $m.Groups[1].Value } elseif ($f -match '^[^\s<>]+@[^\s<>]+$') { $f } else { '' }
            if ($email -eq '') { continue }
            if ([string]::Equals($email, $script:PublicCommitEmail, [System.StringComparison]::OrdinalIgnoreCase)) { $public++ }
            elseif (Test-SystemCommitEmail $email) { $system++ }
            else { $lineHasOther = $true }
        }
        if ($lineHasOther) { $other++ }
    }
    return [pscustomobject]@{ OtherCommits = $other; PublicFields = $public; SystemFields = $system }
}

# The effective identity check prints PASS/FAIL, never the value.
function Get-CommitIdentityReport {
    param([Parameter(Mandatory = $true)][string]$RepoPath, [string]$Range = '')
    $effective = Invoke-Git @('config', '--get', 'user.email') -RepoPath $RepoPath
    $effectiveOk = $effective.Ok -and $effective.Output.Count -gt 0 -and
        [string]::Equals(([string]$effective.Output[0]).Trim(), $script:PublicCommitEmail, [System.StringComparison]::OrdinalIgnoreCase)

    $format = '--format=%ae%x09%ce%x09%(trailers:key=Co-authored-by,key=Signed-off-by,valueonly,separator=%x09)'
    $logArgs = @('log', '-n', [string]$script:IdentityScanMaxCommits, $format)
    if ($Range -ne '') { $logArgs += $Range } else { $logArgs += '--all' }
    $log = Invoke-Git $logArgs -RepoPath $RepoPath
    $scanned = 0
    $measure = [pscustomobject]@{ OtherCommits = 0; PublicFields = 0; SystemFields = 0 }
    if ($log.Ok) {
        $lines = @($log.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $scanned = $lines.Count
        $measure = Measure-CommitIdentityLines $lines
    }
    $tagOther = 0
    if ($Range -eq '') {
        $tags = Invoke-Git @('for-each-ref', 'refs/tags', '--format=%(taggeremail)') -RepoPath $RepoPath
        if ($tags.Ok) { $tagOther = (Measure-CommitIdentityLines @($tags.Output)).OtherCommits }
    }
    return [pscustomobject]@{
        EffectiveOk  = [bool]$effectiveOk
        LogOk        = [bool]$log.Ok
        Scanned      = $scanned
        Truncated    = ($scanned -ge $script:IdentityScanMaxCommits)
        OtherCommits = [int]$measure.OtherCommits
        OtherTags    = [int]$tagOther
    }
}

function Get-CommitIdentityReminder {
    param([Parameter(Mandatory = $true)]$Report, [string]$Scope = 'history')
    $what = if ($Scope -eq 'history') { 'this repository''s commits and tags (old ones and every new one)' } else { 'the commits made in this session' }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('COMMIT IDENTITY: check that ' + $what + ' carry ONLY ' + $script:PublicCommitEmail + ' for the owner''s author, committer, tagger and co-author/sign-off identities, and no other address. Any commit that carries another address of the owner''s MUST be rewritten (private backup first, rewrite only the owner''s identity, publish with --force-with-lease=<ref>:<old-oid>, then verify CI on the new SHA). Rule: global-repository-rules.md, Public Commit Identity and Private Email Remediation.')
    if (-not $Report.LogOk) {
        [void]$lines.Add('- The commit log could not be read, so how many commits carry another address is UNKNOWN.')
    }
    else {
        $scope = if ($Report.Truncated) { 'in the newest ' + $Report.Scanned + ' commits (scan capped - older ones were not read)' } else { 'across ' + $Report.Scanned + ' commit(s)' }
        [void]$lines.Add('- ' + $Report.OtherCommits + ' commit(s) ' + $scope + ' carry an address other than the public one (bots and bare noreply@ system addresses not counted). Addresses are not shown here; list them yourself and decide which are the owner''s.')
        if ($Report.OtherTags -gt 0) { [void]$lines.Add('- ' + $Report.OtherTags + ' annotated tag(s) carry another tagger address.') }
    }
    if (-not $Report.EffectiveOk) {
        [void]$lines.Add('- The effective user.email for this repository is NOT the public address - set it before the next commit: git config --local user.email ' + $script:PublicCommitEmail)
    }
    [void]$lines.Add('- Changing user.email or adding .mailmap does not remove an address already inside Git objects.')
    return ($lines.ToArray() -join "`n")
}
