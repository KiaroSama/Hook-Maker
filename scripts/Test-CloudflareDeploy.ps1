# Offline test suite for Cloudflare-Deploy: deployment-worthiness/environment/
# pre-deploy-review/post-deploy-verification/failure-handling content, PLUS
# the release-readiness gate (clean+pushed+CI-green-if-applicable+cleanup-
# coordination) that decides whether the decision is shown AT ALL.
#
# The cleanup-coordination half proves the SHARED category contract with
# Test-Temp-Cleanup: only a FRESH `clean` for the current repo-state fingerprint
# is release-ready, while `review-required`, `residue-confirmed`, `partial`,
# `unknown`, a stale fingerprint, a missing record, and any retired/unrecognized
# value all keep this hook silent - and a same-Stop race is resolved by a LATER
# Stop, never by an ordering assumption or an in-invocation retry. `gh` is
# PATH-shimmed (same convention as Test-CiStatusCheck.ps1's gh.ps1) - no live
# GitHub calls. Remotes are real local bare repos (same convention as
# Test-GitSyncCheck.ps1) so the generic @{upstream}/ahead-count check is
# exercised for real, without needing an actual GitHub remote.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-CloudflareDeploy.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HooksRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Cloudflare-Deploy\Cloudflare-Deploy.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-cftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
function New-GitRepo {
    param([string]$Name)
    $p = New-Proj $Name
    & git -C $p init -q -b main
    & git -C $p config user.email 't@t'
    & git -C $p config user.name 't'
    return $p
}
function Add-Commit {
    param([string]$Repo, [string]$Message = 'c')
    & git -C $Repo add -A
    & git -C $Repo commit -q -m $Message
}
# A clean, fully-pushed repo with a wrangler config - the baseline "ready"
# fixture every readiness-gate test starts from and deviates one axis at a time.
function New-ReadyWorkersRepo {
    param([string]$Name)
    $p = New-GitRepo $Name
    Write-Utf8 (Join-Path $p 'wrangler.toml') 'name = "test"'
    Add-Commit $p 'init'
    $remote = Join-Path $Work ($Name + '-remote.git')
    & git init -q --bare $remote
    & git -C $p remote add origin $remote
    & git -C $p push -q -u origin main
    return $p
}
# Get-GitHubRepository (used only for the CI query) recognizes a remote by
# its URL string via regex - it never needs to reach it. Swap the origin URL
# to a github.com-shaped address AFTER all real local pushes are done, so the
# already-established @{upstream} tracking ref keeps working with the real
# bare-repo history while the CI step recognizes a "GitHub" repository.
function Set-FakeGithubRemote {
    param([string]$Root, [string]$Name)
    & git -C $Root remote set-url origin ('https://github.com/hookmaker-test/' + $Name + '.git')
}

# ---- gh shim: intercepts `gh run list` in child processes (same convention
# as Test-CiStatusCheck.ps1's gh.ps1) - no live GitHub calls. ----
$ShimDir = Join-Path $Work 'ghshim'
$MockDir = Join-Path $Work 'ghmock'
New-Item -ItemType Directory -Path $ShimDir, $MockDir -Force | Out-Null
$ghMock = @'
$mockDir = $env:GH_MOCK_DIR
if (-not $mockDir) { exit 1 }
$a = @($args)
if ($a.Count -ge 2 -and $a[0] -eq 'run' -and $a[1] -eq 'list') {
    $f = Join-Path $mockDir 'run_list.json'
    if (Test-Path $f) { Write-Output (Get-Content $f -Raw) } else { Write-Output '[]' }
    exit 0
}
exit 1
'@
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'gh.ps1'), $ghMock)
$PathWithoutRealGh = (@($env:PATH -split ';' | Where-Object {
    $_ -ne '' -and -not (Test-Path -LiteralPath (Join-Path $_ 'gh.exe') -PathType Leaf)
}) -join ';')
function Set-GhMock {
    param([string]$RunJson = '')
    Remove-Item (Join-Path $MockDir '*') -Force -ErrorAction SilentlyContinue
    if ($RunJson -ne '') { Set-Content (Join-Path $MockDir 'run_list.json') $RunJson -Encoding utf8 }
}

function Fire {
    param([string]$Cwd, [string]$SessionId = 't', [switch]$StopHookActive, [switch]$WithGh, [string]$Exe = 'pwsh')
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = 'Stop' }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $Hook + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"' }
    $childPath = if ($WithGh) { ($ShimDir + ';' + $PathWithoutRealGh) } else { $PathWithoutRealGh }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    # Env is handed over by INHERITANCE, not Start-Process -Environment: that
    # parameter does not exist on Windows PowerShell 5.1, so a -Environment-only
    # harness silently let the child use the REAL %LOCALAPPDATA% and the real
    # PATH on that host - which is why the gh-mock and cleanup-state cases used
    # to fail only under 5.1. Set here, restore in finally, one code path.
    $savedPath = $env:PATH
    $savedLocalAppData = $env:LOCALAPPDATA
    $savedMockDir = $env:GH_MOCK_DIR
    try {
        $env:PATH = $childPath
        $env:LOCALAPPDATA = $FakeLocalAppData
        $env:GH_MOCK_DIR = $MockDir
        $proc = Start-Process @startArgs
    }
    finally {
        $env:PATH = $savedPath
        $env:LOCALAPPDATA = $savedLocalAppData
        $env:GH_MOCK_DIR = $savedMockDir
    }
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

try {
    # =====================================================================
    Write-Host '--- non-Workers projects stay silent ---' -ForegroundColor Cyan
    $plain = New-GitRepo 'Plain'
    Add-Commit $plain 'init'
    $r = Fire -Cwd $plain
    Check 'no wrangler config -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Workers project, ready state: deployment-worthiness decision reminder ---' -ForegroundColor Cyan
    $cf = New-ReadyWorkersRepo 'CfProj'
    $r = Fire -Cwd $cf
    Check 'a ready Workers project receives a Stop reminder' ($r.Out -match '"decision":"block"' -and $r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out
    Check 'the message explicitly says deployment is not automatic' ($r.Out -match 'Deployment is NOT automatic just because this config exists') $r.Out
    Check 'partial/experimental/docs-only work is explicitly allowed to finish without deploying' (
        $r.Out -match 'documentation-only, an experiment, or the release commit is not known - finish now WITHOUT deploying') $r.Out
    Check 'environment selection is required and production is not silently assumed' (
        $r.Out -match 'never silently default to production') $r.Out
    Check 'pre-deploy checks include tests/build and the exact release state' (
        $r.Out -match 'tests/typecheck/lint/build pass' -and $r.Out -match 'exact release commit is known') $r.Out
    Check 'disposable test cache/temp residue must not be part of the release' ($r.Out -match 'disposable test cache/temp residue') $r.Out
    Check 'CI-green is considered when the repo uses CI' ($r.Out -match 'CI for that commit is green if this repo uses CI') $r.Out
    Check 'bindings/migrations are considered conditionally, not unconditionally' (
        $r.Out -match 'only where relevant to this diff' -and $r.Out -match 'D1 databases and migrations') $r.Out
    Check 'post-deploy smoke/health verification is required' (
        $r.Out -match 'Post-deployment verification is REQUIRED' -and $r.Out -match 'smoke-test the public/staging URL') $r.Out
    Check 'command success alone is not described as sufficient proof' (
        $r.Out -match 'do not claim deployment succeeded solely because the command exited 0') $r.Out
    Check 'failure is reported accurately, never hidden, never claimed live' (
        $r.Out -match 'never hide a failed deployment' -and $r.Out -match 'never claim the task is live if it is not') $r.Out
    Check 'redeploy-on-failure is not blind/repeated' ($r.Out -match 'do not repeatedly redeploy blindly') $r.Out
    Check 'no secret values are requested or printed' ($r.Out -match 'Never print secret values')
    Check 'the deploy command itself is still suggested' ($r.Out -match 'npx wrangler deploy') $r.Out

    # =====================================================================
    Write-Host '--- cooldown and stop_hook_active remain intact ---' -ForegroundColor Cyan
    $r2 = Fire -Cwd $cf
    Check 'repeated Stop within the cooldown window (same unchanged commit) stays silent' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $cf2 = New-ReadyWorkersRepo 'CfProjGuard'
    $r3 = Fire -Cwd $cf2 -StopHookActive
    Check 'stop_hook_active short-circuits before any wrangler/git inspection' ($r3.Exit -eq 0 -and $r3.Out -eq '')

    # =====================================================================
    Write-Host '--- release-readiness gate: never shown when the repo/CI/cleanup state is not ready ---' -ForegroundColor Cyan
    $dirty = New-ReadyWorkersRepo 'Dirty'
    Write-Utf8 (Join-Path $dirty 'new.txt') 'uncommitted'
    $r = Fire -Cwd $dirty
    Check 'a dirty working tree stays silent (no reminder at all)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $ahead = New-ReadyWorkersRepo 'Ahead'
    Write-Utf8 (Join-Path $ahead 'new.txt') 'v2'
    Add-Commit $ahead 'unpushed change'
    $r = Fire -Cwd $ahead
    Check 'an unpushed (ahead-of-remote) commit stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $noRemote = New-GitRepo 'NoRemote'
    Write-Utf8 (Join-Path $noRemote 'wrangler.toml') 'name = "test"'
    Add-Commit $noRemote 'init'
    $r = Fire -Cwd $noRemote
    Check 'no configured remote/upstream at all stays silent (release commit not known to be pushed)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- release-readiness gate: CI, only when this repo actually uses CI ---' -ForegroundColor Cyan
    $ciNoGh = New-ReadyWorkersRepo 'CiNoGh'
    New-Item -ItemType Directory -Path (Join-Path $ciNoGh '.github\workflows') -Force | Out-Null
    Write-Utf8 (Join-Path $ciNoGh '.github\workflows\ci.yml') 'on: push'
    Add-Commit $ciNoGh 'add ci'
    & git -C $ciNoGh push -q
    Set-FakeGithubRemote -Root $ciNoGh -Name 'CiNoGh'
    $r = Fire -Cwd $ciNoGh
    Check 'CI workflows present but gh unavailable -> silent (cannot verify green)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $ciFail = New-ReadyWorkersRepo 'CiFail'
    New-Item -ItemType Directory -Path (Join-Path $ciFail '.github\workflows') -Force | Out-Null
    Write-Utf8 (Join-Path $ciFail '.github\workflows\ci.yml') 'on: push'
    Add-Commit $ciFail 'add ci'
    & git -C $ciFail push -q
    Set-FakeGithubRemote -Root $ciFail -Name 'CiFail'
    Set-GhMock -RunJson '[{"status":"completed","conclusion":"failure"}]'
    $r = Fire -Cwd $ciFail -WithGh
    Check 'CI verified NOT green -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $ciGreen = New-ReadyWorkersRepo 'CiGreen'
    New-Item -ItemType Directory -Path (Join-Path $ciGreen '.github\workflows') -Force | Out-Null
    Write-Utf8 (Join-Path $ciGreen '.github\workflows\ci.yml') 'on: push'
    Add-Commit $ciGreen 'add ci'
    & git -C $ciGreen push -q
    Set-FakeGithubRemote -Root $ciGreen -Name 'CiGreen'
    Set-GhMock -RunJson '[{"status":"completed","conclusion":"success"}]'
    $r = Fire -Cwd $ciGreen -WithGh
    Check 'CI verified green for the exact HEAD -> the decision is shown' ($r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out

    # Regression: the run list was decoded as `@($runsJson | ConvertFrom-Json)`.
    # Windows PowerShell 5.1 does not enumerate a JSON array through the
    # pipeline, so that collected ONE element of type Object[] at any array
    # length; Get-Field reads PSObject.Properties, which is empty on an
    # Object[], so no run ever looked completed/success and the CI-green gate
    # was unreachable on 5.1. The single-run assertion above covers it too - it
    # was the one the defect originally broke. This multi-run pair additionally
    # pins that enumeration keeps working past the first element, and that a
    # failure anywhere in the list still blocks.
    # Each CI case needs its OWN repo, like CiFail/CiGreen above: the hook keys
    # its coordination state to the repo-state fingerprint, so re-firing at the
    # same state is not a clean second observation.
    $ciMulti = New-ReadyWorkersRepo 'CiGreenMulti'
    New-Item -ItemType Directory -Path (Join-Path $ciMulti '.github\workflows') -Force | Out-Null
    Write-Utf8 (Join-Path $ciMulti '.github\workflows\ci.yml') 'on: push'
    Add-Commit $ciMulti 'add ci'
    & git -C $ciMulti push -q
    Set-FakeGithubRemote -Root $ciMulti -Name 'CiGreenMulti'
    Set-GhMock -RunJson '[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"}]'
    $r = Fire -Cwd $ciMulti -WithGh
    Check 'MULTIPLE green runs for the exact HEAD still pass the CI gate (5.1 array-decode regression)' (
        $r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out

    # ...and a multi-run list containing one failure must still block, so the
    # fix cannot be "enumerate, then stop checking".
    $ciMixed = New-ReadyWorkersRepo 'CiMixed'
    New-Item -ItemType Directory -Path (Join-Path $ciMixed '.github\workflows') -Force | Out-Null
    Write-Utf8 (Join-Path $ciMixed '.github\workflows\ci.yml') 'on: push'
    Add-Commit $ciMixed 'add ci'
    & git -C $ciMixed push -q
    Set-FakeGithubRemote -Root $ciMixed -Name 'CiMixed'
    Set-GhMock -RunJson '[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]'
    $r = Fire -Cwd $ciMixed -WithGh
    Check 'one failing run among several keeps the deploy decision silent' (
        $r.Out -notmatch 'CLOUDFLARE DEPLOY CHECK') $r.Out

    # =====================================================================
    Write-Host '--- release-readiness gate: Test-Temp-Cleanup coordination ---' -ForegroundColor Cyan
    # Not installed at all for this project -> the cleanup gate does not apply.
    $noCleanup = New-ReadyWorkersRepo 'NoCleanupInstalled'
    $r = Fire -Cwd $noCleanup
    Check 'cleanup not installed for this project -> gate skipped, decision shown' ($r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out

    function New-CleanupMarker {
        param([string]$Root)
        New-Item -ItemType Directory -Path (Join-Path $Root '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -Force | Out-Null
    }
    function Write-CleanupResult {
        param([string]$Root, [string]$Category, [switch]$StaleFingerprint)
        . $HookLib
        $fingerprint = if ($StaleFingerprint) { 'stale0000' } else { Get-RepoStateFingerprint -ProjectRoot $Root }
        $key = Get-ShortHash $Root.ToLowerInvariant()
        $stateDir = Join-Path $FakeLocalAppData 'HookMaker\state'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $record = [ordered]@{ sessionId = 't'; fingerprint = $fingerprint; category = $Category; timestampUtc = [DateTime]::UtcNow.ToString('o') }
        ($record | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $stateDir ('TestTempCleanup-result-' + $key + '.json')) -Encoding utf8
    }

    $missingResult = New-ReadyWorkersRepo 'CleanupMissingResult'
    New-CleanupMarker $missingResult
    $r = Fire -Cwd $missingResult
    Check 'cleanup installed but no result recorded yet -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # NO same-event ordering assumption: the racing Stop above stayed silent and
    # wrote no cooldown, so once the producer records a fresh result the decision
    # appears on a LATER Stop. Nothing is retried inside one invocation.
    Write-CleanupResult -Root $missingResult -Category 'clean'
    $r = Fire -Cwd $missingResult
    Check 'once the producer records clean, a LATER Stop shows the decision (race resolved, never retried in-invocation)' (
        $r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out

    $staleResult = New-ReadyWorkersRepo 'CleanupStaleResult'
    New-CleanupMarker $staleResult
    Write-CleanupResult -Root $staleResult -Category 'clean' -StaleFingerprint
    $r = Fire -Cwd $staleResult
    Check 'a stale/mismatched cleanup fingerprint -> silent even when the category is clean' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # SHARED CONTRACT with hooks\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1: exactly
    # one of these five values is ever recorded, and only 'clean' is release-ready.
    $notReadyCategories = @('review-required', 'residue-confirmed', 'partial', 'unknown')
    $caseIndex = 0
    foreach ($category in $notReadyCategories) {
        $caseIndex++
        $repo = New-ReadyWorkersRepo ('CleanupNotReady' + $caseIndex)
        New-CleanupMarker $repo
        Write-CleanupResult -Root $repo -Category $category
        $r = Fire -Cwd $repo
        Check ('cleanup reported "' + $category + '" for the current state -> silent, NOT release-ready') (
            $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    }

    # A value from an older or newer producer is not release-ready either.
    $legacyCategory = New-ReadyWorkersRepo 'CleanupLegacyCategory'
    New-CleanupMarker $legacyCategory
    Write-CleanupResult -Root $legacyCategory -Category 'safe-cleaned'
    $r = Fire -Cwd $legacyCategory
    Check 'the retired "safe-cleaned" category is no longer release-ready -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $cleanCleanup = New-ReadyWorkersRepo 'CleanupClean'
    New-CleanupMarker $cleanCleanup
    Write-CleanupResult -Root $cleanCleanup -Category 'clean'
    $r = Fire -Cwd $cleanCleanup
    Check 'ONLY a fresh "clean" for the current state shows the decision' ($r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out

    # =====================================================================
    Write-Host '--- the shared category contract is declared, not inferred ---' -ForegroundColor Cyan
    $cfText = [System.IO.File]::ReadAllText($Hook)
    $producerText = [System.IO.File]::ReadAllText((Join-Path $HooksRoot 'Test-Temp-Cleanup\Test-Temp-Cleanup.ps1'))
    $sharedList = "'clean', 'review-required', 'residue-confirmed', 'partial', 'unknown'"
    Check 'this consumer declares the full category list explicitly' ($cfText -match [regex]::Escape($sharedList)) $sharedList
    Check 'the producer declares the identical list (no silent drift)' ($producerText -match [regex]::Escape($sharedList)) $sharedList
    Check 'the consumer names the producer file in the contract comment' ($cfText -match 'Test-Temp-Cleanup\.ps1') $cfText
    Check 'only clean is treated as release-ready' ($cfText -match [regex]::Escape("CleanupReleaseReadyCategories = @('clean')")) $cfText
    Check 'the deletion-era categories are gone from this consumer' (
        $cfText -notmatch 'safe-cleaned' -and $cfText -notmatch 'review-only-preserved') $cfText
    Check 'the concurrency contract is still documented (no registration-order assumption)' (
        $cfText -match 'may run concurrently' -and $cfText -match 'never assumes') $cfText

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $cf3 = New-ReadyWorkersRepo 'CfProjPs5'
    $r4 = Fire -Cwd $cf3 -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 emits the reminder cleanly' ($r4.Exit -eq 0 -and $r4.Out -match 'CLOUDFLARE DEPLOY CHECK' -and $r4.Out -match 'Post-deployment verification is REQUIRED') $r4.Err
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
