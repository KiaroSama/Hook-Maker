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

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-cftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$FakeLocalAppData = Join-Path $Work '_fakelocal'
$FakeUserProfile = Join-Path $Work '_fakeprofile'
New-Item -ItemType Directory -Path $FakeUserProfile -Force | Out-Null
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

    # =====================================================================
    Write-Host '--- managed ownership: every client, both scopes ---' -ForegroundColor Cyan
    # The gate must apply on EVERY supported client's REAL registration schema,
    # and only when the runtime behind it is ownership-proven. Kiro's
    # registration is a per-hook v1 file under .kiro\hooks - the same directory
    # its RUNTIME deliberately stays out of - and it registers kiro-launch.ps1,
    # not the hook script, so the ownership metadata is what says which file the
    # command must point at.
    foreach ($client in @('claude', 'codex', 'kiro')) {
        $gatedRepo = New-ReadyWorkersRepo ('CleanupOn-' + $client)
        New-ManagedCleanupInstall -Base $gatedRepo -Client $client | Out-Null
        Write-CleanupResult -Root $gatedRepo -Category 'review-required'
        $r = Fire -Cwd $gatedRepo
        Check ('a managed ' + $client + ' project install is detected: review-required -> silent') (
            $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

        $readyRepo = New-ReadyWorkersRepo ('CleanupOnReady-' + $client)
        New-ManagedCleanupInstall -Base $readyRepo -Client $client | Out-Null
        Write-CleanupResult -Root $readyRepo -Category 'clean'
        $r = Fire -Cwd $readyRepo
        Check ('a managed ' + $client + ' project install with a fresh clean shows the decision') (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out
    }

    # A non-rooted command path resolves against the scope base, the way a client
    # resolves it against the project - it must still count.
    $relativeCommand = New-ReadyWorkersRepo 'CleanupRelativeCommand'
    New-ManagedCleanupInstall -Base $relativeCommand -CommandForm 'relative' | Out-Null
    $r = Fire -Cwd $relativeCommand
    Check 'a RELATIVE command path into the managed runtime still proves the install (no record yet -> silent)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # A GLOBAL install lives in the user profile (the fake one Fire redirects
    # USERPROFILE to) and records no project key, because it serves every
    # project. Written and removed HERE so no other fixture inherits it.
    $globalRepo = New-ReadyWorkersRepo 'CleanupGlobalScope'
    New-ManagedCleanupInstall -Base $FakeUserProfile -Scope 'global' | Out-Null
    try {
        $r = Fire -Cwd $globalRepo
        Check 'a valid GLOBAL managed install applies the gate for a project with no local evidence at all' (
            $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

        $globalReady = New-ReadyWorkersRepo 'CleanupGlobalScopeReady'
        Write-CleanupResult -Root $globalReady -Category 'clean'
        $r = Fire -Cwd $globalReady
        Check 'the same global install with a fresh clean shows the decision' (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out
        # NO "project doc claiming global scope, with a real global install
        # present" case here on purpose: with the gate already applying via the
        # global install, that assertion would read as silent whether the project
        # document was rejected or accepted - it cannot fail for its own reason.
        # The scope check is proven by the wrong-scope NEGATIVE below, where the
        # decision being shown is only possible if the mismatch was rejected.
    }
    finally {
        Remove-Item -LiteralPath (Join-Path $FakeUserProfile '.claude') -Recurse -Force -ErrorAction SilentlyContinue
    }

    # =====================================================================
    Write-Host '--- negative evidence: nothing heuristic proves an install ---' -ForegroundColor Cyan
    # EVERY case here must SHOW the deployment decision. That is the whole point
    # of the direction change: a negative SKIPS the cleanup gate, so the agent
    # still gets step 1's "no disposable test cache/temp residue" requirement.
    # The old direction applied the gate and then waited forever for a fresh
    # 'clean' nothing would ever write - a permanently dead reminder.
    #
    # A second project's key, computed the way the installer would compute it for
    # that project. Nothing is created there: the point is only that the key
    # belongs to a DIFFERENT root than the one the hook recomputes.
    $foreignProjectKey = Get-ShortHash (Normalize-Path (Join-Path $Work 'SomeOtherProject')).ToLowerInvariant()
    $negativeCases = @(
        [pscustomobject]@{
            Name  = 'a fingerprint-CURRENT coordination result ALONE'
            Why   = 'only the hook writes one, but a leftover state file is not an active install'
            Build = { param($Repo) Write-CleanupResult -Root $Repo -Category 'review-required' }
        }
        [pscustomobject]@{
            Name  = 'a fingerprint-current result plus a bare runtime DIRECTORY'
            Why   = 'a hand-made or half-deleted folder satisfies a listing while nothing there can run'
            Build = { param($Repo) New-CleanupMarker -Root $Repo | Out-Null; Write-CleanupResult -Root $Repo -Category 'clean' }
        }
        [pscustomobject]@{
            Name  = 'a runtime directory only, with no registration anywhere'
            Why   = 'the removers delete this directory on the same success path that retires the record'
            Build = { param($Repo) New-CleanupMarker -Root $Repo | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a STALE coordination record with no registration'
            Why   = 'a surviving stale record evidences an install that is GONE'
            Build = { param($Repo) Write-CleanupResult -Root $Repo -Category 'clean' -StaleFingerprint }
        }
        [pscustomobject]@{
            Name  = 'a MALFORMED registration document naming the hook'
            Why   = 'a document nobody can parse proves no active registration - this reverses the old conservative verdict'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'malformed' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a document that only NAME-DROPS the hook'
            Why   = 'no command, no runtime, so nothing would ever record a fresh clean'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'nameDrop' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a real managed command quoted in a NON-command field'
            Why   = 'only the handler''s own command fields count, never any string in the document'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'nonCommandField' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro action carrying the command under a non-command key'
            Why   = 'action.command is the only field a Kiro command action runs'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -CommandForm 'nonCommandField' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a FOREIGN Kiro entry holding a real managed command'
            Why   = 'the entry name must be the one the ownership metadata records; a neighbour cannot borrow it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -KiroEntryName 'someone-elses-hook-stop' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a real managed command in a Kiro file Hook Maker does not own'
            Why   = 'only .kiro\hooks\hookmaker-<slug>.json is ours; a shared/foreign document is never parsed for ownership'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -KiroFileName 'foreign-hook.json' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro document that is not the v1 shape'
            Why   = 'a legacy 0.x/.kiro.hook document is not something this hook can reason about'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -KiroVersion 'v0' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a runtime copied in by hand under a path carrying both magic segments'
            Why   = '\Hook-Maker\ + \Test-Temp-Cleanup\ in a path spelling is not containment under the client''s runtime root'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'outside' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a relative command path that escapes the runtime root with ..'
            Why   = 'the escaped target exists on disk, so only the containment check can reject it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'escape' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata claiming the WRONG client'
            Why   = 'the metadata must agree with the document that referenced it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'claude' -Metadata @{ client = 'codex' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata claiming the WRONG scope'
            Why   = 'a project-scope document cannot be backed by a global-scope runtime record'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ scope = 'global' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata carrying ANOTHER project''s projectKey'
            Why   = 'THE check that catches a runtime copied in from a different project'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ projectKey = $foreignProjectKey } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with an EMPTY projectKey on a project install'
            Why   = 'only a global install is project-unbound'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ projectKey = '' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro install whose recordId disagrees with the entry''s own marker'
            Why   = 'recordId cannot be cross-checked against the tool-root registry, so it is proven against the entry that carries it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -Metadata @{ recordId = 'rec-someone-else' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with no recordId at all'
            Why   = 'an install with no managed identity is not a managed install'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ recordId = '<remove>' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with no registrationName'
            Why   = 'the metadata must say which registration it belongs to'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ registrationName = '<remove>' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro install whose registrationName prefix does not match the entry'
            Why   = 'metadata and the located entry must be the same registration'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -Metadata @{ registrationName = 'hookmaker-other-install-something' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro registrationName truncated to a prefix that would match anything managed'
            Why   = 'a startsWith test must not be satisfiable by degrading the recorded value'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -Metadata @{ registrationName = 'h' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Claude registrationName that is not the managed runtime segment pair'
            Why   = 'a handler entry has no name, so the recorded identity is the segment pair the installer writes'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ registrationName = 'Some-Other-Root/Test-Temp-Cleanup' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with an unknown schemaVersion'
            Why   = 'a version this hook does not understand cannot be validated field by field'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ schemaVersion = 99 } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata naming a different hook'
            Why   = 'friendlyName must be this hook'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ friendlyName = 'Some-Other-Hook' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a registration whose command points somewhere the metadata does not name'
            Why   = 'the registered target must BE the recorded runtime script'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ runtimeScriptRelativePath = 'Test-Temp-Cleanup/some-other-script.ps1' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'MISSING ownership metadata beside a live runtime'
            Why   = 'a runtime that cannot prove ownership is not evidence, however plausible its path'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -NoMetadata | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a MODIFIED manifest hash'
            Why   = 'the manifest must vouch for the bytes that would actually execute'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ runtimeManifest = @(@{ path = 'Test-Temp-Cleanup/Test-Temp-Cleanup.ps1'; sha256 = ('a' * 64) }) } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest with no entry for the runtime script'
            Why   = 'an unlisted script is unverified, not verified-by-omission'
            # Every OTHER entry hashes correctly, so this can only fail on the
            # missing entry point - not on a bogus hash standing in for it.
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -ManifestOmitsRuntimeScript | Out-Null }
        }
        # ---- the registered EVENT, not merely a registration -----------------
        # Ownership proves WHOSE runtime it is; it says nothing about WHEN it
        # runs. A managed install on any non-Stop event never reaches the Stop
        # that writes the fresh 'clean' this gate waits for, so counting it as
        # installed parks the reminder behind a result that registration cannot
        # produce - the same permanently dead gate, reached from a new direction.
        [pscustomobject]@{
            Name  = 'a fully ownership-proven Claude install registered on SessionStart only'
            Why   = 'no Stop handler exists, so nothing will ever record a result for this gate to read'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -RegisteredEvent 'SessionStart' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a fully ownership-proven Kiro install whose only entry triggers on SessionStart'
            Why   = 'a Kiro file holds one entry PER trigger, so the file existing says nothing about Stop'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -RegisteredEvent 'SessionStart' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Claude registration under a lower-case "stop" key'
            Why   = 'the client matches the event key literally, so a mis-cased key fires nothing'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -RegisteredEvent 'stop' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro entry whose trigger is lower-case "stop"'
            Why   = 'KIRO_PROTOCOL.md records the triggers as confirmed exact casing'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -RegisteredEvent 'stop' | Out-Null }
        }
        # ---- the whole runtime, not just its entry point ---------------------
        # The registration names ONE file, but that file is a door, not the room:
        # Claude/Codex run <hook>.ps1 which dot-sources _hooklib.ps1, and Kiro
        # runs kiro-launch.ps1 which runs the hook which loads the same library.
        # Verifying only the named file left the entire body of executing code
        # unchecked.
        [pscustomobject]@{
            Name  = 'a library BEHIND an untouched Claude entry point, modified after the manifest'
            Why   = 'the registered script still hashes correctly; only whole-manifest verification sees this'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -TamperLibrary | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a library behind an untouched Kiro LAUNCHER, modified after the manifest'
            Why   = 'Kiro registers the launcher, so everything it goes on to run sits behind the one recorded path'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -TamperLibrary | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest entry whose path climbs out of the runtime root with ..'
            Why   = 'a manifest must not be able to vouch for a file outside the runtime it describes'
            Build = {
                param($Repo)
                New-ManagedCleanupInstall -Base $Repo -ManifestExtra @(@{ path = '../../../../elsewhere.ps1'; sha256 = ('c' * 64) }) | Out-Null
            }
        }
        # ---- the manifest must be COMPLETE, not merely internally correct -----
        # A manifest describes itself. Verifying every entry it lists says
        # nothing about what it left OUT, and an omitted dependency is not
        # merely unverified - it is never looked at. Every case below leaves the
        # remaining entries perfectly valid and sawRegistered true, so only a
        # completeness rule can reject them.
        [pscustomobject]@{
            Name  = 'a Claude manifest that simply OMITS _hooklib.ps1 while the file still sits there'
            Why   = 'the entry point dot-sources it, so dropping its entry hides the library from the check entirely'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -OmitFromManifest @('_hooklib.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro manifest that OMITS the main hook script behind the launcher'
            Why   = 'Kiro registers kiro-launch.ps1, so the hook it runs is exactly the part an omission can hide'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -OmitFromManifest @('Test-Temp-Cleanup.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro manifest that omits _hooklib.ps1 two levels behind the registration'
            Why   = 'launcher -> hook -> library: the deepest dependency is the easiest one to leave unlisted'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -OmitFromManifest @('_hooklib.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a required dependency deleted from disk AND from the manifest'
            Why   = 'nothing on disk contradicts the manifest, so only a required set known independently catches it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -RemoveLeaf @('_hooklib.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'an unlisted extra .ps1 sitting in the managed runtime directory'
            Why   = 'the entry point could load it and nothing verified it; no required-set check would look for it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -UnlistedExtraFile | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest listing the same path twice, both entries hashing correctly'
            Why   = 'the installer never emits a duplicate; with a WRONG hash this would only prove the hash check'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -DuplicateEntry '_hooklib.ps1' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest longer than the writer can emit'
            Why   = 'a manifest past the install plan''s cap did not come from an install, and bounds a Stop hook''s hashing'
            Build = {
                param($Repo)
                $pad = @(1..65 | ForEach-Object { @{ path = ('Test-Temp-Cleanup/pad-' + $_ + '.ps1'); sha256 = ('d' * 64) } })
                New-ManagedCleanupInstall -Base $Repo -ManifestExtra $pad | Out-Null
            }
        }
        [pscustomobject]@{
            Name  = 'a runtime script MODIFIED after the manifest was written'
            Why   = 'this is the same check from the other side - the file changed, the recorded hash did not'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -TamperRuntime | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a registration whose runtime script is MISSING'
            Why   = 'nothing can fire, so nothing will ever record a fresh clean'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -MissingRuntime | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a STALE registration left behind after uninstall'
            Why   = 'the uninstaller removes runtime + metadata; the registration alone is residue'
            Build = {
                param($Repo)
                New-ManagedCleanupInstall -Base $Repo | Out-Null
                Remove-Item -LiteralPath (Join-Path $Repo '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -Recurse -Force
            }
        }
    )
    $negativeIndex = 0
    foreach ($case in $negativeCases) {
        $negativeIndex++
        $negativeRepo = New-ReadyWorkersRepo ('CleanupNegative' + $negativeIndex)
        & $case.Build $negativeRepo
        $r = Fire -Cwd $negativeRepo
        Check ($case.Name + ' is NOT install evidence - gate skipped, decision SHOWN (' + $case.Why + ')') (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') ($r.Out + ' || ' + $r.Err)
    }

    # Two of the loop cases above deserve a note, because a reader will ask
    # whether they pass for the right reason: 'outside' and 'escape' both point a
    # command at a file that genuinely EXISTS on disk, so neither can be rejected
    # by a missing target. The red proof is the evidence - the pre-change hook
    # required Test-Path on the resolved target and ACCEPTED both, which is only
    # possible if the file was there. What rejects them now is containment.

    # A reparse-point escape is the one containment case '..' cannot express: the
    # command's target is lexically inside the runtime root, the file exists, the
    # metadata parses and the manifest hash matches - the runtime DIRECTORY is
    # just a junction to somewhere else, so the bytes that would execute are not
    # the ones the containment test approved. Junction creation needs no
    # elevation, but it needs a filesystem that supports it; if it is
    # unavailable the case is reported as skipped rather than counted as a pass.
    $junctionRepo = New-ReadyWorkersRepo 'CleanupReparseEscape'
    New-ManagedCleanupInstall -Base $junctionRepo | Out-Null
    $junctionHookDir = Join-Path $junctionRepo '.claude\hooks\Hook-Maker\Test-Temp-Cleanup'
    $junctionTarget = Join-Path $Work 'junction-target\Test-Temp-Cleanup'
    $junctionMade = $false
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $junctionTarget) -Force | Out-Null
        Move-Item -LiteralPath $junctionHookDir -Destination $junctionTarget
        New-Item -ItemType Junction -Path $junctionHookDir -Target $junctionTarget -ErrorAction Stop | Out-Null
        $junctionMade = $true
    }
    catch {
        Write-Host ('SKIPPED (junctions unavailable here): ' + $_.Exception.Message) -ForegroundColor Yellow
    }
    if ($junctionMade) {
        Check 'the junction fixture really is a reparse point holding the live runtime script' (
            (([System.IO.File]::GetAttributes($junctionHookDir)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
            (Test-Path -LiteralPath (Join-Path $junctionHookDir 'Test-Temp-Cleanup.ps1') -PathType Leaf))
        $r = Fire -Cwd $junctionRepo
        Check 'a REPARSE-POINT escape inside the runtime root is NOT install evidence - gate skipped, decision SHOWN' (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') ($r.Out + ' || ' + $r.Err)
    }

    # An UNREADABLE registration is the one negative that cannot be built from
    # file content: the document is a perfectly valid managed registration, held
    # open with FileShare.None for the duration of the Stop. Refusing to read is
    # no longer treated as proof of presence - the negative direction only costs
    # a shown decision, while the old direction silenced the reminder for as long
    # as the lock (or a corrupt file) lasted.
    $lockedRepo = New-ReadyWorkersRepo 'CleanupUnreadableRegistration'
    $lockedPath = New-ManagedCleanupInstall -Base $lockedRepo
    # THE CONTROL RUNS FIRST, and the order is not cosmetic. A silent Stop writes
    # no cooldown state, but a Stop that SHOWS the decision does - so firing the
    # locked case first would leave the "readable again" control inside the
    # cooldown window, where it would report silence for a reason that has nothing
    # to do with the gate and pass for the wrong reason.
    $r = Fire -Cwd $lockedRepo
    Check 'the control: this registration IS a valid managed install while readable (gate applies -> silent)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $lockedHandle = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $r = Fire -Cwd $lockedRepo
        Check 'the SAME registration held unreadable is NOT install evidence - gate skipped, decision SHOWN' (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') ($r.Out + ' || ' + $r.Err)
    }
    finally { $lockedHandle.Dispose() }

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
    Write-Host '--- ordering and structural honesty are stated in the code ---' -ForegroundColor Cyan
    # The order is a behaviour contract, not an implementation detail, so it is
    # asserted rather than left to be re-derived by the next reader.
    Check 'the hook states the ordering: prove the install BEFORE reading coordination state' (
        $cfText -match 'prove an ACTIVE MANAGED installation' -and
        $cfText -match 'only then read coordination state') $cfText
    Check 'the hook states that a coordination record is never installation evidence on its own' (
        $cfText -match 'NEVER installation evidence on its own') $cfText
    # Structural honesty: the registry cross-check is impossible from an
    # installed runtime, and the code must SAY so rather than fake one.
    Check 'the hook says why recordId is not cross-checked against the install registry' (
        $cfText -match 'install-registry\.json is unreachable' -and
        $cfText -match 'INTERNAL agreement only') $cfText
    Check 'the hook does not pretend to read the tool-root registry' (
        $cfText -notmatch 'Get-InstallRegistry' -and $cfText -notmatch 'Read-InstallRegistry') $cfText
    Check 'the retired recursive command-string walk is gone' (
        $cfText -notmatch 'Get-RegistrationCommandValues' -and
        $cfText -notmatch 'Test-CleanupCommandEvidence') $cfText

    # =====================================================================
    Write-Host '--- the client mirrors still equal the capability table ---' -ForegroundColor Cyan
    # An installed runtime is self-contained - the installer rewrites _hooklib.ps1
    # into it but copies no sibling out of scripts\ - so the per-client
    # registration locations AND runtime roots must be MIRRORED into the hook
    # rather than read from the table. That is only safe while something proves
    # each mirror still EQUALS the table: the previous runtime-root mirror went
    # stale the moment a third client was added, and a whole gate was skipped
    # silently. The runtime-root mirror is back (as a containment bound, never as
    # evidence), so it needs the same proof.
    $cfParseErrors = $null
    $cfAst = [System.Management.Automation.Language.Parser]::ParseFile($Hook, [ref]$null, [ref]$cfParseErrors)
    Check 'the hook parses with no errors' (@($cfParseErrors).Count -eq 0) (@($cfParseErrors) -join '; ')
    # Only path-shaped constants are compared: a hashtable literal's KEYS are
    # string constants too, and they are not what this mirrors.
    function Get-MirroredPaths {
        param([string]$VariableName)
        $assignments = @($cfAst.FindAll({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left.Extent.Text -eq $VariableName }, $true))
        if ($assignments.Count -ne 1) { return @('<expected exactly one assignment, found ' + $assignments.Count + '>') }
        return @($assignments[0].Right.FindAll({
            $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            ForEach-Object { $_.Value } | Where-Object { $_ -like '*\*' } | Sort-Object -Unique)
    }
    # Expected: every project+global registration FILE of every shared-settings
    # client, deduplicated (Codex uses one path for both scopes). Kiro is a
    # DIRECTORY of per-hook files and is mirrored separately.
    $tableRegs = @()
    $tableRuntimeRoots = @()
    foreach ($cfClientId in @(Get-HookMakerClientIds)) {
        $cfCap = Get-HookMakerClientCapability -ClientId $cfClientId
        $tableRuntimeRoots += @([string]$cfCap.runtimeRelativeRoot)
        if ([string]$cfCap.registrationKind -eq 'perHookFile') { continue }
        $tableRegs += @([string]$cfCap.projectRegistration, [string]$cfCap.globalRegistration)
    }
    $tableRegs = @($tableRegs | Sort-Object -Unique)
    $tableRuntimeRoots = @($tableRuntimeRoots | Sort-Object -Unique)
    $mirroredRegs = Get-MirroredPaths '$script:CleanupRegistrationFiles'
    Check 'the registration mirror equals the capability table exactly (no missing client, no stale extra)' (
        ($mirroredRegs -join '|') -eq ($tableRegs -join '|')) (
        'mirror=[' + ($mirroredRegs -join ', ') + '] table=[' + ($tableRegs -join ', ') + ']')
    $mirroredRuntimeRoots = Get-MirroredPaths '$script:CleanupRuntimeRoots'
    Check 'the RUNTIME-ROOT mirror equals the capability table exactly (the list that rotted last time)' (
        ($mirroredRuntimeRoots -join '|') -eq ($tableRuntimeRoots -join '|')) (
        'mirror=[' + ($mirroredRuntimeRoots -join ', ') + '] table=[' + ($tableRuntimeRoots -join ', ') + ']')
    $mirroredKiroDir = Get-MirroredPaths '$script:CleanupKiroRegistrationDir'
    Check 'the Kiro registration DIRECTORY mirror equals the table (per-hook files under .kiro\hooks)' (
        ($mirroredKiroDir -join '|') -eq [string](Get-HookMakerClientCapability -ClientId 'kiro').projectRegistration) (
        $mirroredKiroDir -join ', ')
    # The Kiro managed-FILENAME rule is owned by scripts\_installkiro.ps1
    # (Test-KiroManagedFileName), not by the capability table, so it is pinned
    # against that file directly.
    $kiroInstallText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '_installkiro.ps1'))
    $kiroFilePattern = '^hookmaker-[a-z0-9-]+\.json$'
    Check 'the Kiro managed-filename mirror equals the installer''s own ownership rule' (
        $cfText -match [regex]::Escape($kiroFilePattern) -and $kiroInstallText -match [regex]::Escape($kiroFilePattern)) $kiroFilePattern
    # The manifest-entry cap is a fourth mirror: the hook refuses a manifest
    # longer than the plan can emit, which is only meaningful while the two
    # numbers agree. Raise the writer's cap alone and the hook starts rejecting
    # real installs; lower it alone and the bound stops matching reality.
    $planText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '_installplan.ps1'))
    $writerCap = ([regex]::Match($planText, '\$script:RuntimeMetadataManifestCap\s*=\s*(\d+)')).Groups[1].Value
    $readerCap = ([regex]::Match($cfText, '\$script:CleanupManifestCap\s*=\s*(\d+)')).Groups[1].Value
    Check 'the manifest-entry cap mirror equals the install plan''s own writer cap' (
        $writerCap -ne '' -and $writerCap -eq $readerCap) ('writer=[' + $writerCap + '] reader=[' + $readerCap + ']')
    # A fifth mirror, and the one most likely to rot silently: the required
    # executables. If the plan starts staging a new shared artifact, a required
    # set frozen at today's two names would go on accepting a manifest that
    # omits the new one - the exact hole this check exists to close. So derive
    # what the plan ACTUALLY stages for any hook and require the hook's set to
    # match it.
    #
    # Three exclusions, each for a stated reason rather than to make the numbers
    # agree:
    #   '/'                            the fragment of the main-script expression
    #                                  ($FriendlyName + '/' + $FriendlyName +
    #                                  '.ps1'); the hook derives that name from
    #                                  its own hook-name constant.
    #   scripts/Run-Tests-Guarded.ps1  staged ONLY for Test-Run-Guard, so it is
    #                                  never part of a Test-Temp-Cleanup runtime.
    #   non-.ps1                       sync-hooks.json and SYNC-PROJECTS.txt are
    #                                  DATA staged only for the sync-engine
    #                                  hooks. This check - and the disk scan it
    #                                  backs - is deliberately about executables:
    #                                  what the entry point can LOAD. A data file
    #                                  is out of its scope, stated rather than
    #                                  silently dropped.
    $plannedLeaves = @([regex]::Matches($planText, '\$FriendlyName \+ ''/([^'']+)''') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -like '*.ps1' -and $_ -ne 'scripts/Run-Tests-Guarded.ps1' } | Sort-Object -Unique)
    $requiredAst = @($cfAst.FindAll({
                $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $args[0].Left.Extent.Text -eq '$script:CleanupRequiredRuntimeLeaves' }, $true))
    $requiredLeaves = @()
    if ($requiredAst.Count -eq 1) {
        $requiredLeaves = @($requiredAst[0].Right.FindAll({
                    $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            ForEach-Object { $_.Value } | Where-Object { $_ -like '*.ps1' } | Sort-Object -Unique)
    }
    Check 'the REQUIRED-executable mirror equals what the install plan actually stages for a hook' (
        $plannedLeaves.Count -gt 0 -and ($requiredLeaves -join '|') -eq ($plannedLeaves -join '|')) (
        'required=[' + ($requiredLeaves -join ', ') + '] planned=[' + ($plannedLeaves -join ', ') + ']')
    # ...and Kiro must require the launcher its registration names, which the
    # union above cannot show on its own.
    $kiroRequired = ''
    if ($requiredAst.Count -eq 1) {
        $kiroRequired = [string]($requiredAst[0].Right.Extent.Text -match "kiro'\s*=\s*@\([^)]*kiro-launch\.ps1")
    }
    Check 'the Kiro required set specifically includes kiro-launch.ps1' ($kiroRequired -eq 'True') $kiroRequired

    # =====================================================================
    Write-Host '--- the ownership-metadata contract has two sides that must agree ---' -ForegroundColor Cyan
    # THE PRODUCER of .hookmaker-runtime.json is the canonical install plan in
    # scripts\_installplan.ps1; THE CONSUMER is this hook. Nothing else connects
    # them - the file is written by the installer and read by a runtime that
    # cannot reach the installer - so the field names, the schema version and the
    # two registration-identity SHAPES are pinned here, in one place, exactly the
    # way the shared result-category list above is. This suite's own fixtures are
    # hand-built, so without this guard a rename on either side would leave the
    # fixtures green and every real install unrecognized.
    $planText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '_installplan.ps1'))
    Check 'both sides name the same metadata file' (
        $planText -match [regex]::Escape('.hookmaker-runtime.json') -and
        $cfText -match [regex]::Escape('.hookmaker-runtime.json')) '.hookmaker-runtime.json'
    Check 'both sides agree on schemaVersion 1' (
        $planText -match [regex]::Escape('RuntimeMetadataSchemaVersion = 1') -and
        $cfText -match [regex]::Escape("CleanupMetadataSchemaVersion = '1'")) 'schemaVersion 1'
    foreach ($metadataField in @('schemaVersion', 'recordId', 'friendlyName', 'client', 'scope',
            'projectKey', 'registrationName', 'runtimeScriptRelativePath', 'runtimeManifest')) {
        Check ('both sides use the field name "' + $metadataField + '"') (
            $planText -match [regex]::Escape('"' + $metadataField + '"') -and
            $cfText -match [regex]::Escape("'" + $metadataField + "'")) $metadataField
    }
    Check 'the producer records the Kiro registration identity as an entry-name PREFIX (not one entry name)' (
        $planText -match [regex]::Escape('(Get-KiroManagedNamePrefix -ManagedId $RecordId) + (ConvertTo-KiroSlug -Text $FriendlyName)')) $planText
    Check 'the producer records the Claude/Codex registration identity as the managed runtime segment pair' (
        $planText -match [regex]::Escape("('Hook-Maker/' + `$FriendlyName)")) $planText
    Check 'the producer hashes the project key with the same Normalize-Path/Get-ShortHash pair this consumer recomputes' (
        $planText -match [regex]::Escape('Get-ShortHash ((Normalize-Path $ProjectRoot).ToLowerInvariant())') -and
        $cfText -match [regex]::Escape('Get-ShortHash (Normalize-Path $Root).ToLowerInvariant()')) 'projectKey derivation'
    Check 'the producer records manifest hashes in lower-case hex (this consumer compares case-insensitively anyway)' (
        $planText -match 'ToLowerInvariant\(\)' -and $cfText -match [regex]::Escape('[0-9a-fA-F]{64}')) 'sha256 casing'

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
