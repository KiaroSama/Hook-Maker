# Docs-Freshness-Check: the PreToolUse `git push` gate and the Stop [skip ci]
# advice. Dot-sourced by Test-DocsFreshnessCheck.ps1 inside its try block, so
# $Work, Fire, FireAck, Get-Fingerprint, New-IsolatedHookCopy, New-GitRepo,
# Add-Commit, Write-Utf8 and Check all come from there. Upstreams are local
# bare repositories; nothing here reaches a network.

# A repo with a bare upstream, a SessionStart baseline, nothing outgoing yet.
function New-PushScenario {
    param([string]$Name)
    $hc = New-IsolatedHookCopy
    $repo = New-GitRepo $Name
    Write-Utf8 (Join-Path $repo 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $repo 'a.ps1') "function A { 1 }`n"
    Add-Commit $repo 'init'
    $remote = Join-Path $Work ($Name + '-remote.git')
    & git init -q --bare -b main $remote
    & git -C $repo remote add origin $remote
    & git -C $repo push -q -u origin main 2>$null | Out-Null
    Fire -HookPath $hc.Script -Cwd $repo -EventName 'SessionStart' -LocalAppData $hc.LocalAppData | Out-Null
    return [pscustomobject]@{ Hook = $hc; Repo = $repo }
}

function Invoke-PushAttempt {
    param($Scenario, [string]$Command = 'git push', [string]$Client = 'claude', [string]$Cwd = '')
    if ($Cwd -eq '') { $Cwd = $Scenario.Repo }
    return (Fire -HookPath $Scenario.Hook.Script -Cwd $Cwd -EventName 'PreToolUse' -LocalAppData $Scenario.Hook.LocalAppData -Command $Command -Client $Client)
}

function Get-DenyReason {
    param([string]$Text)
    try { return [string](($Text | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason) } catch { return '' }
}

function Get-TestShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant().Substring(0, 10) }
    finally { $sha.Dispose() }
}

# =====================================================================
Write-Host '--- PreToolUse: a push carrying unreviewed code is denied once per fingerprint ---' -ForegroundColor Cyan
$push1 = New-PushScenario 'PushGate'
Write-Utf8 (Join-Path $push1.Repo 'a.ps1') "function A { 2 }`n"
Add-Commit $push1.Repo 'code'
$rDeny = Invoke-PushAttempt $push1
$denyReason = Get-DenyReason $rDeny.Out
Check 'a push carrying a real code change and no acknowledgement is denied (Claude permissionDecision deny)' (
    $rDeny.Exit -eq 0 -and $rDeny.Out -match '"permissionDecision":"deny"') ($rDeny.Out + ' | err=' + $rDeny.Err)
Check 'the deny names the changed file and the ranked candidate docs' (
    $denyReason -match 'a\.ps1' -and $denyReason -match 'Candidate tracked documentation to review \(ranked\): README\.md') $denyReason
Check 'the deny carries the same -Acknowledge recovery command the Stop gate prints' (
    $denyReason -match '-Acknowledge -ProjectRoot' -and $denyReason -match '-ImpactFingerprint "[a-f0-9]+"' -and $denyReason -match '-Result NoUpdate') $denyReason
Check 'the deny says the docs land in this one push (CI runs once)' ($denyReason -match 'this one push \(CI runs once\)') $denyReason
$fpPush = [regex]::Match($denyReason, '-ImpactFingerprint "([a-f0-9]+)"').Groups[1].Value
$rRetry = Invoke-PushAttempt $push1
Check 'the same push again with the fingerprint unchanged is not denied again (silent)' (
    $rRetry.Exit -eq 0 -and $rRetry.Out -eq '' -and $rRetry.Err -eq '') ($rRetry.Out + ' | err=' + $rRetry.Err)
$rStopOwed = Fire -HookPath $push1.Hook.Script -Cwd $push1.Repo -EventName 'Stop' -LocalAppData $push1.Hook.LocalAppData
Check 'the allowed retry is not an acknowledgement: Stop still blocks on the same fingerprint' (
    $rStopOwed.Out -match '"decision":"block"' -and (Get-Fingerprint $rStopOwed.Out) -eq $fpPush) $rStopOwed.Out
Write-Utf8 (Join-Path $push1.Repo 'README.md') "# Proj`n`nA() now returns 2.`n"
Add-Commit $push1.Repo 'docs'
$rAckPush = FireAck -HookPath $push1.Hook.Script -ProjectRoot $push1.Repo -Fingerprint $fpPush -Result Updated -Files 'README.md' -Reason 'documented the new A() return value' -LocalAppData $push1.Hook.LocalAppData
Check 'the acknowledgement for the pushed fingerprint is accepted' ($rAckPush.Exit -eq 0) ($rAckPush.Out + $rAckPush.Err)
$rAfterAck = Invoke-PushAttempt $push1
Check 'after the acknowledgement the push is allowed silently, although the docs commit moved HEAD' (
    $rAfterAck.Exit -eq 0 -and $rAfterAck.Out -eq '' -and $rAfterAck.Err -eq '') ($rAfterAck.Out + ' | err=' + $rAfterAck.Err)
$rStopAcked = Fire -HookPath $push1.Hook.Script -Cwd $push1.Repo -EventName 'Stop' -LocalAppData $push1.Hook.LocalAppData
Check 'the same acknowledgement clears Stop too' ($rStopAcked.Exit -eq 0 -and $rStopAcked.Out -eq '') $rStopAcked.Out

# =====================================================================
Write-Host '--- PreToolUse: documentation-only outgoing commits and no-impact pushes are silent ---' -ForegroundColor Cyan
$push2 = New-PushScenario 'PushDocsOnly'
Write-Utf8 (Join-Path $push2.Repo 'README.md') "# Proj`n`nMore docs.`n"
Add-Commit $push2.Repo 'docs only'
# Uncommitted code stays behind; only the documentation commit leaves.
Write-Utf8 (Join-Path $push2.Repo 'a.ps1') "function A { 3 }`n"
$rDocsOnly = Invoke-PushAttempt $push2
Check 'documentation-only outgoing commits are allowed silently' (
    $rDocsOnly.Exit -eq 0 -and $rDocsOnly.Out -eq '' -and $rDocsOnly.Err -eq '') ($rDocsOnly.Out + ' | err=' + $rDocsOnly.Err)
$push3 = New-PushScenario 'PushNoImpact'
$rNoImpact = Invoke-PushAttempt $push3
Check 'a push from a repository with no impact is silent' (
    $rNoImpact.Exit -eq 0 -and $rNoImpact.Out -eq '' -and $rNoImpact.Err -eq '') ($rNoImpact.Out + ' | err=' + $rNoImpact.Err)

# =====================================================================
Write-Host '--- PreToolUse: only a real git push is recognised ---' -ForegroundColor Cyan
$push4 = New-PushScenario 'PushRecognition'
Write-Utf8 (Join-Path $push4.Repo 'a.ps1') "function A { 2 }`n"
Add-Commit $push4.Repo 'code'
foreach ($notPush in @('git status', 'echo "git push"', 'git pushx', 'git log --oneline -1')) {
    $rNotPush = Invoke-PushAttempt $push4 $notPush
    Check ('a non-push command is silent: ' + $notPush) (
        $rNotPush.Exit -eq 0 -and $rNotPush.Out -eq '' -and $rNotPush.Err -eq '') ($rNotPush.Out + ' | err=' + $rNotPush.Err)
}
Check 'non-push commands record no push-deny state' (
    @(Get-ChildItem -LiteralPath (Join-Path $push4.Hook.LocalAppData 'HookMaker\state') -Filter 'DocsFreshnessCheck-pushdeny-*' -ErrorAction SilentlyContinue).Count -eq 0)
# From the parent directory, so only -C can point the gate at the repository.
$rDashC = Invoke-PushAttempt $push4 'git -C PushRecognition push origin main' -Cwd $Work
Check 'git -C <dir> push is recognised and resolved against the cwd' (
    $rDashC.Out -match '"permissionDecision":"deny"' -and (Get-DenyReason $rDashC.Out) -match 'a\.ps1') ($rDashC.Out + ' | err=' + $rDashC.Err)
$push5 = New-PushScenario 'PushChained'
Write-Utf8 (Join-Path $push5.Repo 'a.ps1') "function A { 2 }`n"
Add-Commit $push5.Repo 'code'
$rChained = Invoke-PushAttempt $push5 'git status && git push' -Client 'codex'
Check 'x && git push is recognised; Codex gets exit 2 with the reason on stderr' (
    $rChained.Exit -eq 2 -and $rChained.Err -match 'DOCS FRESHNESS CHECK' -and $rChained.Err -match 'this one push') ($rChained.Out + ' | err=' + $rChained.Err)

# =====================================================================
Write-Host '--- Stop: a review still owed on a ci-green pushed HEAD asks for a [skip ci] docs commit ---' -ForegroundColor Cyan
function New-CiScenario {
    param([string]$Name)
    $hc = New-IsolatedHookCopy
    $repo = New-GitRepo $Name
    Write-Utf8 (Join-Path $repo 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $repo 'a.ps1') "function A { 1 }`n"
    Add-Commit $repo 'init'
    & git -C $repo remote add origin 'https://github.com/octo/docs-demo.git'
    Fire -HookPath $hc.Script -Cwd $repo -EventName 'SessionStart' -LocalAppData $hc.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $repo 'a.ps1') "function A { 2 }`n"
    Add-Commit $repo 'code'
    return [pscustomobject]@{ Hook = $hc; Repo = $repo }
}
$ci1 = New-CiScenario 'CiGreen'
$ciHead = ([string](& git -C $ci1.Repo rev-parse HEAD)).Trim()
$ciStateDir = Join-Path $ci1.Hook.LocalAppData 'HookMaker\state'
New-Item -ItemType Directory -Path $ciStateDir -Force | Out-Null
# The record Ci-Status-Check writes: sha / outcome / timestamp / evidence.
$ciNote = Join-Path $ciStateDir ('CiStatusCheck-' + (Get-TestShortHash ($ci1.Repo.ToLowerInvariant() + '|octo/docs-demo')) + '.txt')
[System.IO.File]::WriteAllLines($ciNote, @($ciHead, 'verified', [DateTime]::UtcNow.ToString('o'), 'ci-green'))
$rGreen = Fire -HookPath $ci1.Hook.Script -Cwd $ci1.Repo -EventName 'Stop' -LocalAppData $ci1.Hook.LocalAppData
Check 'ci-green pushed HEAD + review owed: the block names [skip ci], no suite, and the parent SHA' (
    $rGreen.Out -match '"decision":"block"' -and $rGreen.Out -match '\[skip ci\]' -and $rGreen.Out -match 'run no suite' -and
    $rGreen.Out -match ('parent SHA ' + $ciHead.Substring(0, 7))) $rGreen.Out
$ci2 = New-CiScenario 'CiNotRecorded'
$rNotGreen = Fire -HookPath $ci2.Hook.Script -Cwd $ci2.Repo -EventName 'Stop' -LocalAppData $ci2.Hook.LocalAppData
Check 'without a ci-green record the block keeps today''s text (no [skip ci])' (
    $rNotGreen.Out -match '"decision":"block"' -and $rNotGreen.Out -notmatch 'skip ci') $rNotGreen.Out

# A -C value no path can hold must not crash the hook on Windows PowerShell 5.1,
# where .NET Framework's IsPathRooted throws on it; the command is simply not a
# push this hook can place (review finding, 2026-09-30).
$badC = New-CiScenario 'BadDashC'
$rBadC = Fire -HookPath $badC.Hook.Script -Cwd $badC.Repo -EventName 'PreToolUse' -LocalAppData $badC.Hook.LocalAppData -Command 'git -C "a|b" push' -Exe 'powershell'
Check 'git -C with a character no path can hold exits cleanly on 5.1' ($rBadC.Exit -eq 0 -and $rBadC.Out -notmatch 'deny') ('exit=' + $rBadC.Exit + ' ' + $rBadC.Err)
