# Offline smoke test for the Secrets-Check hook: auto-append (file-to-file,
# never printed), placeholder detection, git ignore/tracked/staged/leak checks,
# the throttled unused-secret scan, and the Stop-event block shape. Uses real
# throwaway git repos (no network) and an isolated LOCALAPPDATA for state.
# The classification and git-boundary/outgoing scenario blocks are dot-sourced
# from _testsecretscheckclassify.ps1 / _testsecretscheckoutgoing.ps1 (they run
# in this script's scope; execution order is unchanged).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-SecretsCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$Hook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Secrets-Check\Secrets-Check.ps1'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
foreach ($required in @($Hook, $InstallScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-secretstest'
$FakeAppData = Join-Path $Work 'appdata'
New-Item -ItemType Directory -Path $Work, $FakeAppData -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$SavedLocalAppData = $env:LOCALAPPDATA
# Isolates Install-Hook.ps1's install registry (state\install-registry.json)
# away from this real checkout's own registry for every in-process & call.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$env:HOOKMAKER_STATE_DIR = Join-Path $Work 'state'

function Fire {
    # $RawStdin intentionally UNTYPED: [string] coerces $null to '' (see LESSON.md).
    param([string]$Cwd, [string]$EventName = 'SessionStart', $RawStdin = $null, [string]$HookPath = $Hook, [string]$Exe = '', [bool]$StopHookActive = $false, [switch]$GitPrePush)
    $payload = $RawStdin
    if ($null -eq $payload) {
        $obj = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName }
        if ($StopHookActive) { $obj['stop_hook_active'] = $true }
        $payload = $obj | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    if ($GitPrePush) { $argLine += ' -GitPrePush' }
    $env:LOCALAPPDATA = $FakeAppData
    try {
        # -GitPrePush resolves cwd from the PROCESS's actual working directory
        # (Get-Location), not from any stdin field - WorkingDirectory must be
        # set explicitly so the hook inspects the intended repo.
        $proc = Start-BoundedProcess -FilePath $file -ArgumentList $argLine -WorkingDirectory $Cwd -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    }
    finally {
        $env:LOCALAPPDATA = $SavedLocalAppData
    }
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    if ($err -ne '' -and $env:HOOKMAKER_TEST_DEBUG -eq '1') {
        Write-Host ('  [stderr] ' + $err.Split("`n")[0]) -ForegroundColor DarkYellow
    }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

function New-GitProj {
    param([string]$Name)
    $repo = New-Proj $Name
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    & git -C $repo config core.autocrlf false
    return $repo
}

function Add-Commit {
    param([string]$Repo, [string]$Message = 'c')
    & git -C $Repo add -A 2>$null | Out-Null
    & git -C $Repo commit -q -m $Message 2>$null | Out-Null
}

# ---- outgoing-commit (real push-safety) test helpers ----
function New-PushableRepo {
    param([string]$Name)
    $repo = New-GitProj $Name
    $bare = Join-Path $Work ($Name + '.git')
    & git init -q --bare $bare 2>$null | Out-Null
    & git -C $repo remote add origin $bare 2>$null | Out-Null
    return $repo
}

function Push-Repo {
    param([string]$Repo, [string]$Branch = 'main')
    & git -C $Repo push -q origin $Branch 2>$null | Out-Null
}

# Builds one real pre-push ref-update stdin line from actual git plumbing
# (local HEAD sha + the local remote-tracking ref, refreshed by every real
# push) - not hand-typed shas. LocalSha/RemoteSha are intentionally UNTYPED:
# a [string] param would coerce an omitted $null default to '' (see
# LESSON.md), making "was it explicitly passed?" unanswerable.
function Get-RefUpdateLine {
    param([string]$Repo, [string]$Branch = 'main', $LocalSha = $null, $RemoteSha = $null)
    $local = if ($null -ne $LocalSha) { [string]$LocalSha } else { ((& git -C $Repo rev-parse ('refs/heads/' + $Branch)) | Out-String).Trim() }
    $remote = if ($null -ne $RemoteSha) { [string]$RemoteSha } else {
        $resolved = & git -C $Repo rev-parse ('refs/remotes/origin/' + $Branch) 2>$null
        if ($LASTEXITCODE -eq 0) { ([string]$resolved).Trim() } else { '0' * 40 }
    }
    return ('refs/heads/' + $Branch + ' ' + $local + ' refs/heads/' + $Branch + ' ' + $remote + "`n")
}

# Fires Secrets-Check.ps1 -GitPrePush with an explicit, real ref-update stdin
# payload (what git's native pre-push hook actually receives), instead of the
# synthetic single-field object the plain Fire helper builds.
function FireGitPrePush {
    param([string]$Cwd, [string]$StdinText, [string]$HookPath = $Hook, [string]$Exe = '')
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $StdinText, (New-Object System.Text.UTF8Encoding $false))
    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '" -GitPrePush'
    }
    else {
        $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '" -GitPrePush'
    }
    $env:LOCALAPPDATA = $FakeAppData
    try {
        $proc = Start-BoundedProcess -FilePath $file -ArgumentList $argLine -WorkingDirectory $Cwd -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    }
    finally {
        $env:LOCALAPPDATA = $SavedLocalAppData
    }
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Copies the hook + a custom .env into an isolated folder (own _hooklib copy,
# since the hook dot-sources "..\_hooklib.ps1").
function New-ConfiguredHookCopy {
    param([hashtable]$EnvOverrides)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Secrets-Check.ps1')
    # The copy dot-sources "..\_hooklib.ps1" relative to itself, which resolves
    # to $Work\_hooklib.ps1 since $dir sits one level under $Work.
    Copy-Item (Join-Path (Split-Path -Parent $Hook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
    Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    return (Join-Path $dir 'Secrets-Check.ps1')
}

try {
    # =====================================================================
    Write-Host '--- input handling ---' -ForegroundColor Cyan
    $plain = New-Proj 'Plain'
    $r = Fire -Cwd $plain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $plain -RawStdin 'not json'
    Check 'garbage stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $plain -EventName 'Stop' -StopHookActive $true
    Check 'stop_hook_active -> silent regardless of findings' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- nothing to check -> silent, no writes ---' -ForegroundColor Cyan
    $empty = New-Proj 'Empty'
    $r = Fire -Cwd $empty
    Check 'no .env, no secrets.md -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'no secrets.md created' (-not (Test-Path (Join-Path $empty 'secrets.md')))
    Check 'no state written' (-not (Test-Path (Join-Path $FakeAppData 'HookMaker\state')) -or @(Get-ChildItem (Join-Path $FakeAppData 'HookMaker\state') -Filter 'Secrets-Check-*' -ErrorAction SilentlyContinue).Count -eq 0)

    # =====================================================================
    Write-Host '--- auto-append: real secret, value never printed, then silent ---' -ForegroundColor Cyan
    $proj1 = New-Proj 'AutoAppend'
    Write-Utf8 (Join-Path $proj1 '.env') "API_KEY=sk-live-abcdef1234567890`r`n"
    $r = Fire -Cwd $proj1
    Check 'reports auto-added key' ($r.Out -like '*Auto-added*API_KEY*') $r.Out
    Check 'the real secret VALUE is never printed to output' ($r.Out -notlike '*sk-live-abcdef1234567890*') $r.Out
    Check 'secrets.md was created' (Test-Path (Join-Path $proj1 'secrets.md'))
    $secretsContent1 = [System.IO.File]::ReadAllText((Join-Path $proj1 'secrets.md'))
    Check 'secrets.md documents the key name' ($secretsContent1 -match 'API_KEY')
    Check 'secrets.md contains the real value (that IS its job)' ($secretsContent1 -match 'sk-live-abcdef1234567890')
    # Nothing left to report (already documented, real value, no git) -> silent.
    $r2 = Fire -Cwd $proj1
    Check 'nothing left to report -> silent on next run' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out

    # =====================================================================
    Write-Host '--- a standing finding (placeholder) is deduped once stable ---' -ForegroundColor Cyan
    $proj1b = New-Proj 'PlaceholderPersist'
    Write-Utf8 (Join-Path $proj1b '.env') "DB_PASSWORD=changeme`r`n"
    $r1 = Fire -Cwd $proj1b
    Check 'first run: auto-added + placeholder both reported' ($r1.Out -like '*Auto-added*DB_PASSWORD*' -and $r1.Out -like '*placeholder*DB_PASSWORD*') $r1.Out
    # Second run's fingerprint differs from the first (moved out of "added" into
    # "still a standing placeholder"), so it reports once more...
    $r2 = Fire -Cwd $proj1b
    Check 'second run: still reports the standing placeholder' ($r2.Out -like '*placeholder*DB_PASSWORD*') $r2.Out
    # ...but the THIRD run has the identical fingerprint to the second, so the
    # cooldown now dedupes it - this is the real "not nagged forever" guarantee.
    $r3 = Fire -Cwd $proj1b
    Check 'third run: identical standing state is deduped by cooldown' ($r3.Exit -eq 0 -and $r3.Out -eq '') $r3.Out

    # =====================================================================
    Write-Host '--- AUTO_APPEND=false: report only, never writes ---' -ForegroundColor Cyan
    $proj2 = New-Proj 'NoAutoAppend'
    Write-Utf8 (Join-Path $proj2 '.env') "SOME_TOKEN=abcdefghij1234567890`r`n"
    $noAppendHook = New-ConfiguredHookCopy @{ AUTO_APPEND = 'false' }
    $r = Fire -Cwd $proj2 -HookPath $noAppendHook
    Check 'reports missing-undocumented instead of auto-added' ($r.Out -like '*Found in .env but NOT in secrets.md*SOME_TOKEN*' -and $r.Out -notlike '*Auto-added*') $r.Out
    Check 'secrets.md NOT created when AUTO_APPEND=false' (-not (Test-Path (Join-Path $proj2 'secrets.md')))

    # =====================================================================
    # AUTO_APPEND stays at its default here: the point is that the write itself
    # is refused, not that the feature is off. Reporting "not ignored" AFTER
    # creating the file would leave a committable file full of live credentials
    # in the window before the user reads the warning.
    Write-Host '--- pre-write guard: no secret value lands in an unignored secrets.md ---' -ForegroundColor Cyan
    $guardValue = 'zzzsentinelvalue1234567890'
    $projGuard = New-GitProj 'PreWriteNotIgnored'
    Write-Utf8 (Join-Path $projGuard '.env') ("GUARD_PREWRITE_TOKEN=$guardValue`r`n")
    $r = Fire -Cwd $projGuard
    Check 'secrets.md NOT created when the repo does not ignore it' (-not (Test-Path (Join-Path $projGuard 'secrets.md'))) $r.Out
    # Deliberately keyed on the REFUSAL, not just on "NOT covered by .gitignore":
    # the pre-existing post-hoc check emits that phrase too, but only once the
    # file already exists - so asserting the phrase alone would still pass
    # against the unfixed hook and prove nothing.
    Check 'refusal names the key, says it refused, and never claims an auto-add' (
        $r.Out -like '*GUARD_PREWRITE_TOKEN*' -and $r.Out -like '*refusing to write*' -and
        $r.Out -like '*NOT covered by .gitignore*' -and $r.Out -notlike '*Auto-added*') $r.Out
    Check 'refusal never prints the secret value' ($r.Out -notlike ('*' + $guardValue + '*')) $r.Out

    # Control: the guard refuses an unsafe write, it does not disable the feature.
    $projGuardOk = New-GitProj 'PreWriteIgnored'
    Write-Utf8 (Join-Path $projGuardOk '.gitignore') "/secrets.md`n"
    Write-Utf8 (Join-Path $projGuardOk '.env') ("GUARD_PREWRITE_TOKEN=$guardValue`r`n")
    $r = Fire -Cwd $projGuardOk
    Check 'secrets.md IS written once /secrets.md is ignored' (Test-Path (Join-Path $projGuardOk 'secrets.md')) $r.Out
    Check 'the ignored secrets.md documents the key' ((Test-Path (Join-Path $projGuardOk 'secrets.md')) -and [System.IO.File]::ReadAllText((Join-Path $projGuardOk 'secrets.md')) -match 'GUARD_PREWRITE_TOKEN') $r.Out

    # =====================================================================
    Write-Host '--- git: secrets.md not ignored ---' -ForegroundColor Cyan
    $proj3 = New-GitProj 'NotIgnored'
    # Seed the repo WITHOUT touching secrets.md, so it stays untracked and this
    # test isolates the ignore-pattern check from the separate tracked/staged ones.
    Write-Utf8 (Join-Path $proj3 'README.md') 'seed'
    Add-Commit $proj3 'seed'
    Write-Utf8 (Join-Path $proj3 'secrets.md') "# Secrets`n`n## FOO`n- Value: bar`n"
    $r = Fire -Cwd $proj3
    Check 'CRITICAL: secrets.md not covered by .gitignore' ($r.Out -like '*CRITICAL*' -and $r.Out -like '*secrets.md*NOT covered by .gitignore*') $r.Out
    Write-Utf8 (Join-Path $proj3 '.gitignore') "secrets.md`n"
    $r = Fire -Cwd $proj3
    Check 'no longer flagged once .gitignore covers it' ($r.Exit -eq 0 -and $r.Out -notlike '*NOT covered*') $r.Out

    # =====================================================================
    Write-Host '--- git: secrets.md staged then tracked ---' -ForegroundColor Cyan
    $proj4 = New-GitProj 'StagedTracked'
    Write-Utf8 (Join-Path $proj4 'secrets.md') "# Secrets`n`n## FOO`n- Value: bar`n"
    & git -C $proj4 add secrets.md 2>$null | Out-Null
    $r = Fire -Cwd $proj4
    Check 'CRITICAL: secrets.md staged for commit' ($r.Out -like '*STAGED for commit*') $r.Out
    & git -C $proj4 commit -q -m 'oops' 2>$null | Out-Null
    $r = Fire -Cwd $proj4
    Check 'CRITICAL: secrets.md tracked by git' ($r.Out -like '*TRACKED by git*') $r.Out

    # =====================================================================
    Write-Host '--- git: a real .env file itself tracked ---' -ForegroundColor Cyan
    $proj5 = New-GitProj 'EnvTracked'
    Write-Utf8 (Join-Path $proj5 '.env') "LEAK_TOKEN=abcdefghij1234567890`r`n"
    Write-Utf8 (Join-Path $proj5 '.gitignore') "secrets.md`n"
    Add-Commit $proj5 'commit env by mistake'
    $r = Fire -Cwd $proj5
    Check 'CRITICAL: .env itself is tracked by git' ($r.Out -like '*.env*TRACKED by git*') $r.Out

    $nested = New-GitProj 'NestedEnv'
    New-Item -ItemType Directory -Path (Join-Path $nested 'apps\api'), (Join-Path $nested 'node_modules\pkg') -Force | Out-Null
    Write-Utf8 (Join-Path $nested '.gitignore') "secrets.md`n"
    Write-Utf8 (Join-Path $nested 'apps\api\.env.local') "NESTED_TOKEN=abcdefghij1234567890`r`n"
    Write-Utf8 (Join-Path $nested 'apps\api\.env.example') "EXAMPLE=not-real`r`n"
    Write-Utf8 (Join-Path $nested 'node_modules\pkg\.env') "IGNORED=abcdefghij1234567890`r`n"
    & git -C $nested add -f apps/api/.env.local
    & git -C $nested commit -q -m 'nested env'
    $r = Fire -Cwd $nested
    Check 'nested real env is detected with relative path' ($r.Out -match 'apps[/\\]api[/\\]\.env\.local' -and $r.Out -notmatch 'node_modules') $r.Out

    # =====================================================================
    Write-Host '--- git: leaked value inside a tracked file (reported by name/path only) ---' -ForegroundColor Cyan
    $proj6 = New-GitProj 'Leaked'
    Write-Utf8 (Join-Path $proj6 '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $proj6 '.env') "LEAKED_SECRET=zzzverylongsecretvalue999`r`n"
    Write-Utf8 (Join-Path $proj6 'notes.txt') "reminder: token is zzzverylongsecretvalue999 do not share`r`n"
    Add-Commit $proj6 'seed'
    $r = Fire -Cwd $proj6
    Check 'CRITICAL: leak detected in tracked file' ($r.Out -like '*LEAKED_SECRET*appears in a git-tracked file*notes.txt*') $r.Out
    Check 'leak report never contains the raw value' ($r.Out -notlike '*zzzverylongsecretvalue999*') $r.Out

    # A real secret value accidentally copy-pasted into a TRACKED template file
    # (.env.example) must still be caught - Ignore-Rules-Check intentionally
    # allows .env.example/.env.sample/.env.template/.env.dist to stay tracked
    # (a path-privacy decision), but that must never weaken Secrets-Check's
    # independent exact-value leak scan, which treats .env.example as an
    # ordinary tracked file (it is excluded only from being a discovered
    # SOURCE of secrets, not from being a reported match target).
    $proj6b = New-GitProj 'LeakedTemplate'
    Write-Utf8 (Join-Path $proj6b '.gitignore') ".env`nsecrets.md`n!/.env.example`n"
    Write-Utf8 (Join-Path $proj6b '.env') "REAL_TEMPLATE_SECRET=templateleakvalue1234567890`r`n"
    Write-Utf8 (Join-Path $proj6b '.env.example') "REAL_TEMPLATE_SECRET=templateleakvalue1234567890`r`n"
    & git -C $proj6b add -f .env.example 2>$null | Out-Null
    Add-Commit $proj6b 'track template with an accidentally leaked real value'
    $r = Fire -Cwd $proj6b
    Check 'a real secret value copy-pasted into a tracked .env.example is still caught' ($r.Out -like '*REAL_TEMPLATE_SECRET*appears in a git-tracked file*.env.example*') $r.Out
    Check 'the tracked-template leak report never contains the raw value' ($r.Out -notlike '*templateleakvalue1234567890*') $r.Out

    # Classification scenarios (PublicConfig/Secret/Unknown, overrides, grouping).
    . (Join-Path $PSScriptRoot '_testsecretscheckclassify.ps1')

    # Git-boundary scenarios: index/worktree leak scans + the outgoing pre-push gate.
    . (Join-Path $PSScriptRoot '_testsecretscheckoutgoing.ps1')

    # =====================================================================
    Write-Host '--- unused-secret scan (throttled) ---' -ForegroundColor Cyan
    $proj7 = New-GitProj 'Unused'
    Write-Utf8 (Join-Path $proj7 '.gitignore') "secrets.md`n"
    Write-Utf8 (Join-Path $proj7 'config.ps1') '$x = "REFERENCED_KEY"' + "`r`n"
    Write-Utf8 (Join-Path $proj7 'secrets.md') "# Secrets`n`n## REFERENCED_KEY`n- Value: a`n`n## ORPHAN_KEY`n- Value: b`n"
    Add-Commit $proj7 'seed'
    $forcedScanHook = New-ConfiguredHookCopy @{ UNUSED_SCAN_COOLDOWN_MINUTES = '0' }
    $r = Fire -Cwd $proj7 -HookPath $forcedScanHook
    Check 'flags the truly unused key' ($r.Out -like '*not referenced elsewhere*ORPHAN_KEY*') $r.Out
    Check 'does NOT flag the key that is referenced elsewhere' ($r.Out -notlike '*not referenced elsewhere*REFERENCED_KEY*') $r.Out
    # Immediately re-checking with the REAL hook's default (long) cooldown must
    # skip the scan - satisfies "not every time, only very infrequently".
    $r2 = Fire -Cwd $proj7
    Check 'default long cooldown skips the unused scan on the very next run' ($r2.Out -notlike '*not referenced elsewhere*') $r2.Out

    # =====================================================================
    Write-Host '--- Stop event: only a CRITICAL finding produces decision:block ---' -ForegroundColor Cyan
    $proj8 = New-GitProj 'StopBlockCritical'
    Write-Utf8 (Join-Path $proj8 'secrets.md') "# Secrets`n`n## FOO`n- Value: realsecretvalue1234567890`n"
    $r = Fire -Cwd $proj8 -EventName 'Stop'
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'Stop with a CRITICAL finding returns decision:block' ($null -ne $parsed -and [string]$parsed.decision -eq 'block') $r.Out
    Check 'critical block reason names the problem, never a secret value' ($null -ne $parsed -and [string]$parsed.reason -like '*NOT covered by .gitignore*' -and [string]$parsed.reason -notlike '*realsecretvalue1234567890*') $r.Out

    Write-Host '--- Stop event: Unknown-only findings never block (advisory only) ---' -ForegroundColor Cyan
    $projUnknownStop = New-GitProj 'UnknownStopNonBlocking'
    Write-Utf8 (Join-Path $projUnknownStop '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projUnknownStop '.env') "WIDGET_ID=abc123`r`n"
    Add-Commit $projUnknownStop 'seed'
    $r = Fire -Cwd $projUnknownStop -EventName 'Stop'
    Check 'Unknown-only Stop output is never decision:block' ($r.Out -notlike '*"decision":"block"*') $r.Out
    Check 'Unknown-only Stop output still surfaces the advisory context' ($r.Out -like '*Classification unclear*WIDGET_ID*') $r.Out
    Check 'Unknown-only Stop exits zero' ($r.Exit -eq 0) $r.Out

    Write-Host '--- the advisory names WHICH .env, and that answer is true ---' -ForegroundColor Cyan
    # "Classify explicitly via ... in .env" used to name no file. A reader takes
    # that as the PROJECT's .env - the very file being complained about - where
    # the keys have no effect and nothing says why. These assertions pin both
    # halves: the message names the config path, and the two .env files really
    # do behave the way it claims.
    # Matched against the RAW JSON, so the path is compared in its JSON-escaped
    # form (every backslash doubled) rather than round-tripping through a
    # parser - the same style as the sibling assertions above.
    $configEnvPath = Join-Path (Split-Path -Parent $Hook) '.env'
    $configEnvJson = $configEnvPath.Replace('\', '\\')
    Check 'the advisory prints the FULL path of the .env it actually reads' (
        $r.Out -like ('*' + $configEnvJson + '*')) $r.Out
    Check 'the advisory says explicitly that the scanned project .env is not it' (
        $r.Out -like '*NOT in the scanned project .env*') $r.Out

    # The claim under test: keys in the SCANNED project .env change nothing.
    $projWrongEnv = New-GitProj 'ClassifyInProjectEnv'
    Write-Utf8 (Join-Path $projWrongEnv '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projWrongEnv '.env') "WIDGET_ID=abc123`r`nPUBLIC_CONFIG_KEYS=WIDGET_ID`r`n"
    Add-Commit $projWrongEnv 'seed'
    $rWrong = Fire -Cwd $projWrongEnv -EventName 'Stop'
    Check 'PUBLIC_CONFIG_KEYS in the scanned project .env does NOT classify the key' (
        $rWrong.Out -like '*Classification unclear*WIDGET_ID*') $rWrong.Out

    # The other half: the same key in the hook's own .env does classify it.
    $rightHook = New-ConfiguredHookCopy @{ PUBLIC_CONFIG_KEYS = 'WIDGET_ID' }
    $projRightEnv = New-GitProj 'ClassifyInHookEnv'
    Write-Utf8 (Join-Path $projRightEnv '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projRightEnv '.env') "WIDGET_ID=abc123`r`n"
    Add-Commit $projRightEnv 'seed'
    $rRight = Fire -Cwd $projRightEnv -EventName 'Stop' -HookPath $rightHook
    Check 'PUBLIC_CONFIG_KEYS in the hook''s own .env DOES classify the key' (
        $rRight.Out -notlike '*Classification unclear*WIDGET_ID*') $rRight.Out

    Write-Host '--- Stop event: a successful auto-add alone never blocks (advisory only) ---' -ForegroundColor Cyan
    $projAutoAddStop = New-Proj 'AutoAddStopNonBlocking'
    Write-Utf8 (Join-Path $projAutoAddStop '.env') "STOP_TOKEN=abcdefghij1234567890`r`n"
    $r = Fire -Cwd $projAutoAddStop -EventName 'Stop'
    Check 'successful auto-add alone at Stop is never decision:block' ($r.Out -notlike '*"decision":"block"*') $r.Out
    Check 'successful auto-add alone at Stop still reports the addition' ($r.Out -like '*Auto-added*STOP_TOKEN*') $r.Out
    Check 'auto-add-only Stop never prints the secret value' ($r.Out -notlike '*abcdefghij1234567890*') $r.Out

    $advisory = New-GitProj 'AdvisoryPush'
    Write-Utf8 (Join-Path $advisory '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $advisory '.env') "PLACEHOLDER_TOKEN=changeme`r`n"
    $r = Fire -Cwd $advisory -GitPrePush
    Check 'advisory-only pre-push findings exit zero' ($r.Exit -eq 0) $r.Err
    Check 'advisory-only pre-push is quiet' ([string]::IsNullOrWhiteSpace($r.Out) -and [string]::IsNullOrWhiteSpace($r.Err)) ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- Hook Maker''s own numeric/boolean config keys are public by default ---' -ForegroundColor Cyan
    # A project that configures any hook has a .env full of these, and every one
    # of them used to come back as Unknown - an advisory asking the operator to
    # classify keys this tool itself documents. They are public config now.
    # The LAST two cases are the ones that matter: the built-in list sits BELOW
    # both credential tiers, so one of OUR OWN keys holding a real token is still
    # Secret, and a genuine credential key is untouched. If those ever pass, the
    # list has become a way to smuggle a secret past the scanner.
    $projOwnKeys = New-GitProj 'OwnConfigKeys'
    Write-Utf8 (Join-Path $projOwnKeys '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projOwnKeys '.env') (
        "MAX_SCAN_ENTRIES=40000`r`n" +
        "MAX_SCAN_DEPTH=10`r`n" +
        "MAX_FINDINGS=20`r`n" +
        "ENABLE_SUBAGENT_STOP=false`r`n" +
        # The Stripe-shaped fixture is CONCATENATED, never a contiguous literal.
        # GitHub push protection matches sk_live_ by PATTERN, not by entropy, so
        # any literal here blocks every push of this repository for ever - an
        # obviously-synthetic value is blocked exactly like a real one. The hook
        # under test receives the assembled value, so what this case proves is
        # unchanged: a credential-SHAPED value beats our own-key allowlist.
        # Do not "simplify" this back into a single string.
        "MAX_CHARS=sk" + "_live_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789`r`n" +
        "API_TOKEN=ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789`r`n")
    Add-Commit $projOwnKeys 'seed'
    $rOwn = Fire -Cwd $projOwnKeys -EventName 'SessionStart'
    foreach ($ownKey in @('MAX_SCAN_ENTRIES', 'MAX_SCAN_DEPTH', 'MAX_FINDINGS', 'ENABLE_SUBAGENT_STOP')) {
        Check ('a documented numeric/boolean config key of ours is not reported: ' + $ownKey) (
            $rOwn.Out -notmatch [regex]::Escape($ownKey)) $rOwn.Out
    }
    Check 'one of OUR OWN keys holding a real token is STILL reported (value beats the built-in list)' (
        $rOwn.Out -match 'MAX_CHARS') $rOwn.Out
    Check 'a genuine credential key is still reported alongside it' (
        $rOwn.Out -match 'API_TOKEN') $rOwn.Out
    # A free-form key of ours is deliberately NOT in the list: its value is
    # arbitrary text, so Unknown-and-advisory stays the honest answer.
    $projFreeForm = New-GitProj 'OwnFreeFormKey'
    Write-Utf8 (Join-Path $projFreeForm '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projFreeForm '.env') "DEPLOY_COMMAND=npx wrangler deploy --api-token abcdef0123456789abcdef0123456789`r`n"
    Add-Commit $projFreeForm 'seed'
    $rFree = Fire -Cwd $projFreeForm -EventName 'SessionStart'
    Check 'a free-form config key of ours is NOT silently made public' (
        $rFree.Out -match 'DEPLOY_COMMAND') $rFree.Out

    Write-Host '--- regression guards: the three hard blocks stay hard ---' -ForegroundColor Cyan

    # These three are the load-bearing blocks. Detection of each is asserted in
    # detail further up; what is guarded HERE is that each still actually BLOCKS
    # (decision:block at Stop), so a future false-positive fix cannot quietly
    # downgrade any of them to advisory.
    function Test-StopBlocks {
        param([string]$Out)
        $parsed = $null
        try { $parsed = $Out | ConvertFrom-Json } catch { return $false }
        return ($null -ne $parsed -and [string]$parsed.decision -eq 'block')
    }

    $blkNotIgnored = New-GitProj 'BlockSecretsMdNotIgnored'
    Write-Utf8 (Join-Path $blkNotIgnored 'secrets.md') "# Secrets`n`n## FOO`n- Value: blocknotignored1234567890`n"
    $r = Fire -Cwd $blkNotIgnored -EventName 'Stop'
    Check 'secrets.md present but NOT git-ignored still hard-blocks' (
        (Test-StopBlocks $r.Out) -and $r.Out -like '*NOT covered by .gitignore*') $r.Out

    $blkTracked = New-GitProj 'BlockSecretsMdTracked'
    Write-Utf8 (Join-Path $blkTracked '.gitignore') "secrets.md`n"
    Write-Utf8 (Join-Path $blkTracked 'secrets.md') "# Secrets`n`n## FOO`n- Value: blocktracked1234567890`n"
    & git -C $blkTracked add -f secrets.md 2>$null | Out-Null
    $r = Fire -Cwd $blkTracked -EventName 'Stop'
    Check 'staged secrets.md still hard-blocks' ((Test-StopBlocks $r.Out) -and $r.Out -like '*STAGED for commit*') $r.Out
    Add-Commit $blkTracked 'track secrets.md'
    $r = Fire -Cwd $blkTracked -EventName 'Stop'
    Check 'tracked secrets.md still hard-blocks' ((Test-StopBlocks $r.Out) -and $r.Out -like '*TRACKED by git*') $r.Out

    $blkLeak = New-GitProj 'BlockValueLeak'
    Write-Utf8 (Join-Path $blkLeak '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $blkLeak '.env') "GUARD_LEAK_TOKEN=guardleakvalue1234567890`r`n"
    Write-Utf8 (Join-Path $blkLeak 'notes.txt') "guardleakvalue1234567890`r`n"
    Add-Commit $blkLeak 'seed'
    $r = Fire -Cwd $blkLeak -EventName 'Stop'
    Check 'a real secret VALUE leak into a tracked file still hard-blocks' (
        (Test-StopBlocks $r.Out) -and $r.Out -like '*GUARD_LEAK_TOKEN*appears in a git-tracked file*') $r.Out
    Check 'the hard-block reason never prints the leaked value' ($r.Out -notlike '*guardleakvalue1234567890*') $r.Out

    $blkEnvTracked = New-GitProj 'BlockEnvTracked'
    Write-Utf8 (Join-Path $blkEnvTracked '.gitignore') "secrets.md`n"
    Write-Utf8 (Join-Path $blkEnvTracked '.env') "GUARD_ENV_TOKEN=guardenvvalue1234567890`r`n"
    Add-Commit $blkEnvTracked 'commit .env by mistake'
    $r = Fire -Cwd $blkEnvTracked -EventName 'Stop'
    Check 'a tracked real .env file still hard-blocks' (
        (Test-StopBlocks $r.Out) -and $r.Out -like '*.env*TRACKED by git*') $r.Out

    # =====================================================================
    Write-Host '--- a clean, ignored .venv is not a secret finding (git protection != deployment) ---' -ForegroundColor Cyan

    # An intentionally required .venv that is git-ignored must not be rejected
    # SOLELY for being ignored, nor for vendoring opaque token-SHAPED constants
    # inside third-party package files. Being ignored is a git-protection fact;
    # whether a deployment pipeline includes the directory is a separate concern
    # this hook neither decides nor authorizes.
    $venv = New-PushableRepo 'CleanVenvDeployment'
    Write-Utf8 (Join-Path $venv '.gitignore') ".env`nsecrets.md`n.venv/`n"
    Write-Utf8 (Join-Path $venv '.env') "VENV_APP_SECRET=venvrealsecretvalue1234567890`r`n"
    $venvPkg = Join-Path $venv '.venv\Lib\site-packages\thirdparty\tests'
    New-Item -ItemType Directory -Path $venvPkg -Force | Out-Null
    # Vendored test fixtures that LOOK like credentials but are inert package data.
    Write-Utf8 (Join-Path $venvPkg 'fixture_tokens.py') (
        "SAMPLE_JWT = `"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJURVNUIn0.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`"`r`n" +
        "SAMPLE_B64 = `"QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVoxMjM0NTY3ODkw`"`r`n" +
        "FAKE_API_KEY = `"sk_test_PLACEHOLDER_NOT_A_REAL_KEY_000000`"`r`n")
    Write-Utf8 (Join-Path $venv 'app.py') "print('hello')`r`n"
    Add-Commit $venv 'app plus an ignored .venv'
    $r = Fire -Cwd $venv -EventName 'Stop'
    Check 'an ignored .venv is never reported as a tracked/staged secret file' ($r.Out -notlike '*.venv*') $r.Out
    Check 'token-shaped constants vendored inside .venv are never registered as secrets' (
        $r.Out -notlike '*SAMPLE_JWT*' -and $r.Out -notlike '*SAMPLE_B64*' -and $r.Out -notlike '*FAKE_API_KEY*') $r.Out
    Check 'the whole .venv directory is never classified as a secret' ($r.Out -notlike '*Classification unclear*.venv*') $r.Out
    $venvTracked = @(& git -C $venv ls-files -- .venv | Where-Object { $_ })
    Check 'the hook never tracks the ignored .venv as a side effect' ($venvTracked.Count -eq 0) ($venvTracked -join ', ')
    $rVenvPush = FireGitPrePush -Cwd $venv -StdinText (Get-RefUpdateLine -Repo $venv)
    Check 'a push is not blocked merely because an ignored .venv exists' ($rVenvPush.Exit -eq 0) $rVenvPush.Err

    # The allowance is NOT a blanket exemption: once a .venv file is actually
    # force-tracked, it is ordinary tracked content and a REAL secret value in it
    # must still be caught by the scan that legitimately covers it.
    $venvLeak = New-GitProj 'VenvForceTrackedLeak'
    Write-Utf8 (Join-Path $venvLeak '.gitignore') ".env`nsecrets.md`n.venv/`n"
    Write-Utf8 (Join-Path $venvLeak '.env') "VENVLEAK_SECRET=venvleakvalue1234567890`r`n"
    $venvLeakDir = Join-Path $venvLeak '.venv\Lib\site-packages\app_config'
    New-Item -ItemType Directory -Path $venvLeakDir -Force | Out-Null
    Write-Utf8 (Join-Path $venvLeakDir 'settings.py') "TOKEN = `"venvleakvalue1234567890`"`r`n"
    & git -C $venvLeak add -f '.venv/Lib/site-packages/app_config/settings.py' 2>$null | Out-Null
    Add-Commit $venvLeak 'force-track a .venv file that carries a real secret'
    $r = Fire -Cwd $venvLeak -EventName 'Stop'
    Check 'a REAL secret force-tracked inside .venv is still caught' (
        $r.Out -like '*VENVLEAK_SECRET*appears in a git-tracked file*settings.py*') $r.Out
    Check 'the force-tracked .venv leak report never prints the raw value' ($r.Out -notlike '*venvleakvalue1234567890*') $r.Out

    # =====================================================================
    Write-Host '--- Install-Hook.ps1: self-contained copy ---' -ForegroundColor Cyan
    $tgt = New-Proj 'Install'
    & $InstallScript -CustomHook $Hook -Events @('SessionStart', 'Stop') -TargetProject $tgt -ClaudeOnly *> $null
    $claudeJson = ''
    if (Test-Path (Join-Path $tgt '.claude\settings.local.json')) { $claudeJson = [System.IO.File]::ReadAllText((Join-Path $tgt '.claude\settings.local.json')) }
    Check 'installs as a self-contained local copy' (($claudeJson -like '*hooks\\Hook-Maker\\Secrets-Check\\Secrets-Check.ps1*') -and (Test-Path (Join-Path $tgt '.claude\hooks\Hook-Maker\Secrets-Check\Secrets-Check.ps1')) -and (Test-Path (Join-Path $tgt '.claude\hooks\Hook-Maker\Secrets-Check\_hooklib.ps1')))
    Check 'does not reference the tool folder' ($claudeJson -notlike '*Hook Maker*')

    # =====================================================================
    # =====================================================================
    Write-Host '--- isolation: the real user config is never touched ---' -ForegroundColor Cyan
    # GetTempPath() sits UNDER the real user profile on Windows, so a workspace
    # path leaking into ~\.claude or ~\.codex is a realistic failure, not theory.
    # Comparing timestamps would be flaky (a live agent session writes there);
    # a reference to this run's unique workspace path is unambiguous.
    $realUserConfigs = @(
        (Join-Path $env:USERPROFILE '.claude\settings.json'),
        (Join-Path $env:USERPROFILE '.claude\settings.local.json'),
        (Join-Path $env:USERPROFILE '.codex\config.toml')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $leaked = @($realUserConfigs | Where-Object { [System.IO.File]::ReadAllText($_) -like ('*' + $Work + '*') })
    Check 'no fixture path ever leaks into the real ~\.claude / ~\.codex config' ($leaked.Count -eq 0) ($leaked -join ', ')

    Write-Host '--- Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $proj9 = New-Proj 'Host51'
    Write-Utf8 (Join-Path $proj9 '.env') "HOST_TOKEN=abcdefghij1234567890`r`n"
    $r = Fire -Cwd $proj9 -Exe 'powershell.exe'
    Check '5.1 host: auto-append + report works' ($r.Exit -eq 0 -and $r.Out -like '*Auto-added*HOST_TOKEN*' -and $r.Out -notlike '*abcdefghij1234567890*') $r.Out
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
