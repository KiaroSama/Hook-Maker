# A skip-marked documentation-only commit on a verified-green parent (plan 046
# item k; global-github-automation-rules.md Section 8 "Documentation Before the
# Push; Documentation-Only Commits Skip CI"). Documentation cannot change a test
# result, so such a commit starts no run by design: it gets a one-time note that
# names the parent the tests passed on, recorded as `docs-only-carryover` -
# NEVER `ci-green`, so Test-Completion-Check (which accepts only `ci-green` for
# the exact HEAD) keeps its current behaviour.
#
# Anything else keeps today's behaviour: no skip marker, a file that is not
# documentation, a parent that was not verified green, or a branch whose
# protection requires status checks (a skipped commit would leave them pending).

$script:DocsOnlySkipMarkers = @('[skip ci]', '[ci skip]', '[no ci]', '[skip actions]', '[actions skip]')

function Test-CommitHasSkipMarker {
    param([string]$Message)
    $lower = ([string]$Message).ToLowerInvariant()
    foreach ($marker in $script:DocsOnlySkipMarkers) { if ($lower.Contains($marker)) { return $true } }
    return ($Message -match '(?im)^skip-checks:\s*true\s*$')
}

# Tracked public documentation only: a .md/.txt outside workflow, test,
# fixture and example paths. A README a check consumes would need that check,
# so a path that looks like a fixture or an example never counts.
function Test-DocumentationOnlyPath {
    param([string]$Path)
    $p = ([string]$Path).Replace('\', '/').ToLowerInvariant()
    if ($p -notmatch '\.(md|txt)$') { return $false }
    if ($p.StartsWith('.github/')) { return $false }
    return ($p -notmatch '(^|/)(tests?|fixtures?|examples?|samples?|testdata)(/|$)' -and $p -notmatch '\.example\.')
}

# The last SHA observed green: this commit's own record when it says
# ci-green, or the parent a previous docs-only carry-over named.
function Get-VerifiedGreenBase {
    param([string]$StatePath)
    try {
        if (-not [IO.File]::Exists($StatePath)) { return '' }
        $lines = @([IO.File]::ReadAllLines($StatePath))
        if ($lines.Count -lt 4 -or $lines[1].Trim() -cne 'verified') { return '' }
        if ($lines[3].Trim() -ceq 'ci-green') { return $lines[0].Trim() }
        if ($lines[3].Trim() -ceq 'docs-only-carryover' -and $lines.Count -ge 5) { return $lines[4].Trim() }
    }
    catch { }
    return ''
}

# $null (today's behaviour) or @{ Parent; Files } when the carry-over applies.
function Get-DocsOnlyCarryover {
    param([string]$ProjectRoot, [string]$Sha, [string]$Branch, [string]$RepoSlug, [string]$StatePath)
    $message = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'log', '-1', '--format=%B', $Sha)) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not (Test-CommitHasSkipMarker -Message $message)) { return $null }
    $base = Get-VerifiedGreenBase -StatePath $StatePath
    if ($base -eq '' -or $base -ceq $Sha) { return $null }
    $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'merge-base', '--is-ancestor', $base, $Sha)
    if ($LASTEXITCODE -ne 0) { return $null }
    $files = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'diff', '--name-only', '--no-renames', $base, $Sha) |
        ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
    if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { return $null }
    if (@($files | Where-Object { -not (Test-DocumentationOnlyPath -Path $_) }).Count -gt 0) { return $null }
    # Required status checks would stay pending on a skipped commit. No
    # protection (404 / "not protected") is the only answer that lets it through.
    $protection = @(Invoke-GhBounded -ArgumentList @('api', ('repos/' + $RepoSlug + '/branches/' + $Branch + '/protection/required_status_checks'))) -join "`n"
    if ($LASTEXITCODE -eq 0) {
        try {
            $doc = $protection | ConvertFrom-Json
            $required = @(@(Get-Field $doc 'contexts') + @(Get-Field $doc 'checks') | Where-Object { $null -ne $_ })
            if ($required.Count -gt 0) { return $null }
        }
        catch { return $null }
    }
    elseif ($script:GhBudgetExhausted -or $protection -notmatch '(?i)(not protected|not found|404)') { return $null }
    return [pscustomobject]@{ Parent = $base; Files = @($files) }
}

# Writes the carry-over record and exits with the note, or returns quietly.
function Invoke-DocsOnlyCarryover {
    param([string]$ProjectRoot, [string]$Sha, [string]$Branch, [string]$RepoSlug, [string]$StatePath, [string]$EventName)
    $carry = Get-DocsOnlyCarryover -ProjectRoot $ProjectRoot -Sha $Sha -Branch $Branch -RepoSlug $RepoSlug -StatePath $StatePath
    if ($null -eq $carry) { return }
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $StatePath))
        [IO.File]::WriteAllLines($StatePath, @($Sha, 'verified', [DateTime]::UtcNow.ToString('o'), 'docs-only-carryover', $carry.Parent))
    }
    catch { }
    $shown = @($carry.Files | Select-Object -First 5)
    $more = if ($carry.Files.Count -gt $shown.Count) { ', ...' } else { '' }
    exit (Write-HookResult -EventName $EventName -Kind 'advisory' -Message ('CI CHECK: tests verified green on ' + $carry.Parent.Substring(0, [Math]::Min(7, $carry.Parent.Length)) +
        '; ' + $Sha.Substring(0, [Math]::Min(7, $Sha.Length)) + ' changes documentation only (' + $carry.Files.Count + ' file(s): ' + ($shown -join ', ') + $more +
        ') and carries a skip marker, so no run was started. Report the tests as passed on that parent - this commit is not a new green result.')).ExitCode
}
