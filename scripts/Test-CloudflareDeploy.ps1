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
# Stop, never by an ordering assumption or an in-invocation retry. It also pins
# what counts as EVIDENCE that cleanup is installed at all, which is now exact
# managed OWNERSHIP and nothing weaker: the client's real registration schema
# parsed for its actual command/action field, that command's -File target
# canonicalized and physically contained under that client's runtime root for the
# declared scope, and the runtime's own .hookmaker-runtime.json agreeing on
# friendlyName/client/scope/recomputed projectKey/runtime script plus a matching
# manifest sha256. Unreadable, malformed, foreign, copied-in, path-name-matching,
# escaped and metadata-mismatched evidence are ALL negative, a coordination
# record is never installation evidence on its own, every negative SHOWS the
# decision rather than silencing the reminder forever, and no evidence of any
# kind can SATISFY the gate - only a fresh `clean` does. `gh` is
# PATH-shimmed (same convention as Test-CiStatusCheck.ps1's gh.ps1) - no live
# GitHub calls. Remotes are real local bare repos (same convention as
# Test-GitSyncCheck.ps1) so the generic @{upstream}/ahead-count check is
# exercised for real, without needing an actual GitHub remote.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-CloudflareDeploy.ps1 [-KeepArtifacts]
#         ... -HookPathOverride <path>   run the same assertions against another
#                                        copy of the hook (used to prove new
#                                        assertions go RED against the pre-change
#                                        file exported with `git show HEAD:...`).
#                                        The copy needs a sibling _hooklib.ps1 one
#                                        directory up, exactly like the real hook.
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts, [string]$HookPathOverride)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HooksRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Cloudflare-Deploy\Cloudflare-Deploy.ps1'
if (-not [string]::IsNullOrWhiteSpace($HookPathOverride)) { $Hook = $HookPathOverride }
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Dot-sourced HERE, not deeper down, because the managed-install FIXTURES need
# both: the capability table is the single source of truth for each client's
# registration file and runtime root (so the fixtures cannot drift from the
# installer the way a second hardcoded list would), and the hook library
# supplies the exact Normalize-Path/Get-ShortHash pair both the producer and the
# ownership metadata's projectKey are computed with.
. (Join-Path $PSScriptRoot '_clientcapability.ps1')
. $HookLib

$Work = New-TestWorkspace -Prefix 'hookmaker-cftest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$FakeLocalAppData = Join-Path $Work '_fakelocal'
$FakeUserProfile = Join-Path $Work '_fakeprofile'
New-Item -ItemType Directory -Path $FakeUserProfile -Force | Out-Null
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
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
    $savedUserProfile = $env:USERPROFILE
    try {
        $env:PATH = $childPath
        $env:LOCALAPPDATA = $FakeLocalAppData
        $env:GH_MOCK_DIR = $MockDir
        # USERPROFILE is redirected for the same reason LOCALAPPDATA is: the
        # hook now reads USER-scope registration files for install evidence,
        # and on this dev machine the REAL ~/.claude/settings.json genuinely
        # references Test-Temp-Cleanup - every "not installed" fixture would
        # silently read as installed against the real profile.
        $env:USERPROFILE = $FakeUserProfile
        $proc = Start-Process @startArgs
    }
    finally {
        $env:PATH = $savedPath
        $env:LOCALAPPDATA = $savedLocalAppData
        $env:GH_MOCK_DIR = $savedMockDir
        $env:USERPROFILE = $savedUserProfile
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
    # stop_hook_active means "a Stop gate blocked and the agent is coming
    # back" - NOT "YOU blocked". Thirteen gates share the one flag, so a gate
    # standing down on it alone went silent for somebody else's block, and
    # the next Stop ran with the secret-leak, UTF-8 and CI gates all muted.
    # Each gate now stands down only on its OWN re-entry.
    $r3 = Fire -Cwd $cf2 -StopHookActive
    Check 'stop_hook_active ALONE does not silence it (another gate blocked, not this one)' ($r3.Exit -eq 0 -and $r3.Out -ne '') $r3.Out
    $savedLocalForMarker = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $FakeLocalAppData
    try { $markerPath = Get-StopBlockMarkerPath -HookName 'Cloudflare-Deploy' -ProjectRoot $cf2 }
    finally { $env:LOCALAPPDATA = $savedLocalForMarker }
    New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($markerPath, 't')
    $r4 = Fire -Cwd $cf2 -StopHookActive
    Check 'stop_hook_active PLUS its own marker for this session -> silent (own re-entry)' ($r4.Exit -eq 0 -and $r4.Out -eq '') $r4.Out

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

    # A bare directory named after the hook, and nothing else. Exactly the
    # NON-evidence the runtime-directory-only negative below pins.
    function New-CleanupMarker {
        param([string]$Root, [string]$Client = 'claude')
        $marker = Join-Path (Join-Path $Root ([string](Get-HookMakerClientCapability -ClientId $Client).runtimeRelativeRoot)) 'Test-Temp-Cleanup'
        New-Item -ItemType Directory -Path $marker -Force | Out-Null
        Add-FixtureExcludes -Root $Root
        return $marker
    }

    # Anything a fixture writes into a readiness-gated repo MUST be ignored via
    # .git\info\exclude, or the tree goes DIRTY and the hook goes silent for a
    # reason that has nothing to do with the gate under test - and an assertion
    # expecting "silent" then passes for the wrong reason. This repo has been
    # burned by exactly that twice. Every fixture below routes through here.
    function Add-FixtureExcludes {
        param([string]$Root)
        $excludeDir = Join-Path $Root '.git\info'
        if (-not (Test-Path -LiteralPath $excludeDir -PathType Container)) { return }
        Add-Content -LiteralPath (Join-Path $excludeDir 'exclude') -Value "/.claude/`n/.codex/`n/.kiro/`n/tools/" -Encoding UTF8
    }

    # ---- THE managed-install fixture ----------------------------------------
    # Hand-builds what the installer produces for one (client, scope): the
    # runtime script, the ownership metadata beside it
    # (<runtimeRoot>\Test-Temp-Cleanup\.hookmaker-runtime.json), and a
    # registration document in that client's REAL schema - Claude/Codex
    # hooks.<Event>[].hooks[] with type='command', Kiro a v1 per-hook file with a
    # named entry and action.command. Every negative case deviates exactly ONE
    # axis from this, which is what makes each of them prove its own rule instead
    # of failing for an unrelated reason.
    #
    # -Metadata overrides individual metadata fields; the value '<remove>' drops
    # the key entirely. -CommandForm selects how (or whether) the registration
    # points at the runtime. The real installer's output is asserted separately
    # at integration; these fixtures pin the CONTRACT.
    function New-ManagedCleanupInstall {
        param(
            [Parameter(Mandatory = $true)][string]$Base,
            [ValidateSet('claude', 'codex', 'kiro')][string]$Client = 'claude',
            [ValidateSet('project', 'global')][string]$Scope = 'project',
            [string]$ProjectRoot = '',
            [hashtable]$Metadata = @{},
            [switch]$NoMetadata,
            [switch]$MissingRuntime,
            [switch]$TamperRuntime,
            [switch]$TamperLibrary,
            [switch]$ManifestOmitsRuntimeScript,
            # Leaves the file on disk, drops its manifest entry.
            [string[]]$OmitFromManifest = @(),
            # Drops the file AND its entry - the dependency is simply gone.
            [string[]]$RemoveLeaf = @(),
            [switch]$UnlistedExtraFile,
            # A SECOND entry for this leaf carrying its REAL hash. A duplicate
            # with a wrong hash would be rejected for the hash, proving nothing
            # about duplication.
            [string]$DuplicateEntry = '',
            # Entries APPENDED to an otherwise correct manifest. The registered
            # script's own entry stays valid, so a case built this way cannot
            # pass merely because the entry point failed its own lookup - the
            # extra entries are the only thing left to reject.
            [object[]]$ManifestExtra = @(),
            # The event the registration is written under: the hooks.<Event> key
            # for Claude/Codex, the entry's trigger for Kiro. Only Stop can
            # produce the result the gate waits for.
            [string]$RegisteredEvent = 'Stop',
            [ValidateSet('absolute', 'relative', 'escape', 'outside', 'nonCommandField', 'nameDrop', 'malformed', 'none')]
            [string]$CommandForm = 'absolute',
            [string]$KiroVersion = 'v1',
            [string]$KiroEntryName = '',
            [string]$KiroFileName = ''
        )
        if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = $Base }
        $capability = Get-HookMakerClientCapability -ClientId $Client
        $runtimeRelativeRoot = [string]$capability.runtimeRelativeRoot
        $runtimeRoot = Join-Path $Base $runtimeRelativeRoot
        $hookDir = Join-Path $runtimeRoot 'Test-Temp-Cleanup'
        # Kiro registers the LAUNCHER, not the hook script - the ownership
        # metadata is what says which, so the fixture must differ per client too.
        $scriptName = if ($Client -eq 'kiro') { 'kiro-launch.ps1' } else { 'Test-Temp-Cleanup.ps1' }
        $scriptRelative = 'Test-Temp-Cleanup/' + $scriptName
        $scriptPath = Join-Path $hookDir $scriptName
        $recordId = 'rec-' + $Client + '-' + $Scope
        # EXACTLY the two shapes scripts\_installplan.ps1's
        # Get-RuntimeMetadataRegistrationName produces. The Kiro value is the
        # entry-name PREFIX every entry of one install shares, NOT any single
        # entry name - a Kiro install writes one entry per physical trigger - so
        # the fixture's entry name is deliberately LONGER than the recorded value.
        # A fixture that recorded the full name would let an equality check in the
        # consumer pass here and reject every real install.
        $managedNamePrefix = 'hookmaker-' + $recordId + '-test-temp-cleanup'
        $managedEntryName = $managedNamePrefix + '-stop'

        New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
        # A real install NEVER stages the entry point alone. Per
        # scripts\_installplan.ps1, every client gets <hook>\_hooklib.ps1 (the
        # library the entry point dot-sources) and <hook>\<hook>.ps1, and Kiro
        # additionally gets the kiro-launch.ps1 its registration actually names.
        # The fixture stages the same set so the positive cases prove MULTI-entry
        # verification and the completeness negatives have real files to omit.
        $runtimeLeaves = @('_hooklib.ps1', 'Test-Temp-Cleanup.ps1')
        if ($Client -eq 'kiro') { $runtimeLeaves += 'kiro-launch.ps1' }
        foreach ($leaf in $runtimeLeaves) {
            # -MissingRuntime removes only the REGISTERED script; the rest of the
            # runtime stays, so that case still fails for its own reason.
            if ($MissingRuntime -and $leaf -eq $scriptName) { continue }
            if ($RemoveLeaf -contains $leaf) { continue }
            Write-Utf8 (Join-Path $hookDir $leaf) ('# fixture managed runtime file: ' + $leaf)
        }
        # An executable the manifest cannot account for. Only the disk-side scan
        # can reject this - no required-set check would ever look for it.
        if ($UnlistedExtraFile) { Write-Utf8 (Join-Path $hookDir 'extra-helper.ps1') '# nothing accounts for me' }

        if (-not $NoMetadata) {
            $manifest = @()
            foreach ($leaf in $runtimeLeaves) {
                # -RemoveLeaf drops the file AND its entry: the dependency is
                # simply gone, which the disk scan cannot see and only the
                # required set catches. -OmitFromManifest leaves the file and
                # drops the entry.
                if ($RemoveLeaf -contains $leaf -or $OmitFromManifest -contains $leaf) { continue }
                if ($ManifestOmitsRuntimeScript -and $leaf -eq $scriptName) { continue }
                $leafPath = Join-Path $hookDir $leaf
                $leafHash = if ($MissingRuntime -and $leaf -eq $scriptName) { ('0' * 64) }
                else { (Get-FileHash -LiteralPath $leafPath -Algorithm SHA256).Hash.ToLowerInvariant() }
                $manifest += @{ path = ('Test-Temp-Cleanup/' + $leaf); sha256 = $leafHash }
            }
            if (-not [string]::IsNullOrWhiteSpace($DuplicateEntry)) {
                $manifest += @{
                    path   = ('Test-Temp-Cleanup/' + $DuplicateEntry)
                    sha256 = (Get-FileHash -LiteralPath (Join-Path $hookDir $DuplicateEntry) -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
            if ($ManifestExtra.Count -gt 0) { $manifest = @($manifest) + @($ManifestExtra) }
            # A global install serves every project and records no project key.
            $projectKey = if ($Scope -eq 'project') { Get-ShortHash (Normalize-Path $ProjectRoot).ToLowerInvariant() } else { '' }
            $registrationName = if ($Client -eq 'kiro') { $managedNamePrefix } else { 'Hook-Maker/Test-Temp-Cleanup' }
            $record = [ordered]@{
                schemaVersion             = 1
                recordId                  = $recordId
                friendlyName              = 'Test-Temp-Cleanup'
                client                    = $Client
                scope                     = $Scope
                projectKey                = $projectKey
                registrationName          = $registrationName
                runtimeScriptRelativePath = $scriptRelative
                runtimeManifest           = $manifest
            }
            foreach ($key in @($Metadata.Keys)) {
                if ([string]$Metadata[$key] -eq '<remove>') { $record.Remove($key) } else { $record[$key] = $Metadata[$key] }
            }
            Write-Utf8 (Join-Path $hookDir '.hookmaker-runtime.json') ($record | ConvertTo-Json -Depth 6)
        }
        # AFTER the manifest was computed: the recorded hash no longer describes
        # what would execute.
        if ($TamperRuntime) { Write-Utf8 $scriptPath '# tampered after the manifest was written' }
        # The entry point is left INTACT here: only a file behind it changed,
        # which is exactly what verifying one manifest entry could not see.
        if ($TamperLibrary) { Write-Utf8 (Join-Path $hookDir '_hooklib.ps1') '# tampered after the manifest was written' }

        $commandTarget = $scriptPath
        if ($CommandForm -eq 'relative') {
            $commandTarget = Join-Path (Join-Path $runtimeRelativeRoot 'Test-Temp-Cleanup') $scriptName
        }
        elseif ($CommandForm -eq 'escape') {
            # Starts INSIDE the runtime root and climbs out with '..' - the
            # classic containment bypass. The up-count is derived from the
            # client's own runtime root (its segments + Test-Temp-Cleanup + the
            # scope base) so this stays correct if a client's root changes depth.
            $up = (@('..') * (@($runtimeRelativeRoot -split '\\').Count + 2)) -join '\'
            $escapedDir = Join-Path (Join-Path (Split-Path -Parent $Base) 'escaped') 'Test-Temp-Cleanup'
            New-Item -ItemType Directory -Path $escapedDir -Force | Out-Null
            Write-Utf8 (Join-Path $escapedDir $scriptName) '# outside every runtime root'
            $commandTarget = Join-Path (Join-Path (Join-Path $runtimeRelativeRoot 'Test-Temp-Cleanup') $up) ('escaped\Test-Temp-Cleanup\' + $scriptName)
        }
        elseif ($CommandForm -eq 'outside') {
            # A live script whose path carries BOTH segments the retired
            # heuristic keyed on (\Hook-Maker\ and \Test-Temp-Cleanup\) while
            # sitting nowhere near this client's runtime root: someone else's
            # tool, or a runtime copied in by hand.
            $foreignDir = Join-Path $Base 'tools\other-vendor\Hook-Maker\Test-Temp-Cleanup'
            New-Item -ItemType Directory -Path $foreignDir -Force | Out-Null
            $commandTarget = Join-Path $foreignDir $scriptName
            Write-Utf8 $commandTarget '# someone else'
        }

        if ($CommandForm -ne 'none') {
            # Hand-built JSON on purpose: the on-disk document must carry the
            # JSON-escaped \\ form the parser has to survive.
            $escapedTarget = $commandTarget.Replace('\', '\\')
            $commandString = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"' + $escapedTarget + '\"'
            $document = ''
            if ($Client -eq 'kiro') {
                $entryName = if ([string]::IsNullOrWhiteSpace($KiroEntryName)) { $managedEntryName } else { $KiroEntryName }
                $registrationFileName = if ([string]::IsNullOrWhiteSpace($KiroFileName)) { 'hookmaker-test-temp-cleanup-' + $recordId + '.json' } else { $KiroFileName }
                $registrationPath = Join-Path (Join-Path $Base '.kiro\hooks') $registrationFileName
                # description carries Get-KiroManagedMarker's [hookmaker:<id>],
                # one of the two ownership proofs the Kiro writer embeds.
                $entryBody = '"name":"' + $entryName + '","description":"Test-Temp-Cleanup - managed by Hook Maker; edit through Hook Maker, not by hand. [hookmaker:' + $recordId + ']","trigger":"' + $RegisteredEvent + '"'
                $document = switch ($CommandForm) {
                    'nameDrop' { '{"version":"' + $KiroVersion + '","hooks":[{' + $entryBody + ',"timeout":45,"enabled":true}]}' }
                    'malformed' { '{"version":"v1","hooks":[{"name":"Test-Temp-Cleanup' }
                    'nonCommandField' { '{"version":"' + $KiroVersion + '","hooks":[{' + $entryBody + ',"action":{"type":"command","notes":"example: ' + $commandString + '"},"timeout":45,"enabled":true}]}' }
                    default { '{"version":"' + $KiroVersion + '","hooks":[{' + $entryBody + ',"action":{"type":"command","command":"' + $commandString + '"},"timeout":45,"enabled":true}]}' }
                }
            }
            else {
                $registrationPath = Join-Path $Base ([string]$capability.($Scope + 'Registration'))
                $document = switch ($CommandForm) {
                    'nameDrop' { '{"description":"this document only mentions Test-Temp-Cleanup by name","hooks":{}}' }
                    'malformed' { '{"hooks": broken json naming Test-Temp-Cleanup' }
                    'nonCommandField' { '{"hooks":{"' + $RegisteredEvent + '":[{"hooks":[{"type":"command","notes":"example: ' + $commandString + '"}]}]}}' }
                    default { '{"hooks":{"' + $RegisteredEvent + '":[{"hooks":[{"type":"command","command":"' + $commandString + '","timeout":45}]}]}}' }
                }
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $registrationPath) -Force | Out-Null
            Write-Utf8 $registrationPath $document
            Add-FixtureExcludes -Root $Base
            return $registrationPath
        }
        Add-FixtureExcludes -Root $Base
        return ''
    }

    function Write-CleanupResult {
        param([string]$Root, [string]$Category, [switch]$StaleFingerprint)
        $fingerprint = if ($StaleFingerprint) { 'stale0000' } else { Get-RepoStateFingerprint -ProjectRoot $Root }
        $key = Get-ShortHash (Normalize-Path $Root).ToLowerInvariant()
        $stateDir = Join-Path $FakeLocalAppData 'HookMaker\state'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $record = [ordered]@{ sessionId = 't'; fingerprint = $fingerprint; category = $Category; timestampUtc = [DateTime]::UtcNow.ToString('o') }
        ($record | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $stateDir ('TestTempCleanup-result-' + $key + '.json')) -Encoding utf8
    }

    $missingResult = New-ReadyWorkersRepo 'CleanupMissingResult'
    New-ManagedCleanupInstall -Base $missingResult | Out-Null
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
    New-ManagedCleanupInstall -Base $staleResult | Out-Null
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
        New-ManagedCleanupInstall -Base $repo | Out-Null
        Write-CleanupResult -Root $repo -Category $category
        $r = Fire -Cwd $repo
        Check ('cleanup reported "' + $category + '" for the current state -> silent, NOT release-ready') (
            $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    }

    # A value from an older or newer producer is not release-ready either.
    $legacyCategory = New-ReadyWorkersRepo 'CleanupLegacyCategory'
    New-ManagedCleanupInstall -Base $legacyCategory | Out-Null
    Write-CleanupResult -Root $legacyCategory -Category 'safe-cleaned'
    $r = Fire -Cwd $legacyCategory
    Check 'the retired "safe-cleaned" category is no longer release-ready -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $cleanCleanup = New-ReadyWorkersRepo 'CleanupClean'
    New-ManagedCleanupInstall -Base $cleanCleanup | Out-Null
    Write-CleanupResult -Root $cleanCleanup -Category 'clean'
    $r = Fire -Cwd $cleanCleanup
    Check 'ONLY a fresh "clean" for the current state shows the decision' ($r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out

    # ONE canonicalization, TWO consumers. The coordination record's filename and
    # the ownership metadata's projectKey are both
    # Get-ShortHash(Normalize-Path(root).ToLowerInvariant()), so a cwd carrying a
    # trailing separator names the SAME directory but a DIFFERENT raw string.
    # Skip Normalize-Path on either side and the hook reads a record nothing
    # writes AND rejects its own project's metadata - concluding "not installed"
    # and skipping the cleanliness half of release readiness for a workspace it
    # proved nothing about. review-required (not clean) is used deliberately: the
    # assertion only holds if BOTH reads landed.
    $spelledRepo = New-ReadyWorkersRepo 'CleanupPathSpelling'
    New-ManagedCleanupInstall -Base $spelledRepo | Out-Null
    Write-CleanupResult -Root $spelledRepo -Category 'review-required'
    $r = Fire -Cwd ($spelledRepo + '\')
    Check 'a trailing-separator cwd still resolves BOTH the producer''s record and this project''s ownership key (review-required -> silent)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # ---- managed-ownership evidence ---------------------------------------
    . (Join-Path $PSScriptRoot '_testcloudflareownership.ps1')

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
