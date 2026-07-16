# Offline smoke test for the Secrets-Check hook: auto-append (file-to-file,
# never printed), placeholder detection, git ignore/tracked/staged/leak checks,
# the throttled unused-secret scan, and the Stop-event block shape. Uses real
# throwaway git repos (no network) and an isolated LOCALAPPDATA for state.
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

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-secretstest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$FakeAppData = Join-Path $Work 'appdata'
New-Item -ItemType Directory -Path $Work, $FakeAppData -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$SavedLocalAppData = $env:LOCALAPPDATA

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
        $proc = Start-Process -FilePath $file -ArgumentList $argLine -WorkingDirectory $Cwd -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
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

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
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
        $proc = Start-Process -FilePath $file -ArgumentList $argLine -WorkingDirectory $Cwd -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
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
    Write-Utf8 (Join-Path $proj5 '.env') "LEAK_KEY=abcdefghij1234567890`r`n"
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

    # =====================================================================
    Write-Host '--- git: staged/index-only leak detection (confirmed gap) ---' -ForegroundColor Cyan

    # Leak only in the WORKING TREE (a dirty, unstaged edit adds the value).
    $projLeakWt = New-GitProj 'LeakWorktreeOnly'
    Write-Utf8 (Join-Path $projLeakWt '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projLeakWt '.env') "WT_ONLY_SECRET=wtonlyvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projLeakWt 'notes.txt') "clean`r`n"
    Add-Commit $projLeakWt 'seed clean'
    Write-Utf8 (Join-Path $projLeakWt 'notes.txt') "leaked: wtonlyvalue1234567890`r`n"
    $r = Fire -Cwd $projLeakWt
    Check 'leak only in working tree (unstaged) is detected' ($r.Out -like '*WT_ONLY_SECRET*appears in a git-tracked file*notes.txt*') $r.Out
    Check 'worktree-only leak: value never printed' ($r.Out -notlike '*wtonlyvalue1234567890*') $r.Out

    # Leak only in the INDEX (staged, then the working copy is cleaned WITHOUT
    # staging that cleanup) - the confirmed gap: a working-tree-only `git grep`
    # misses this; the index scan (`git grep --cached`) must catch it.
    $projLeakIdx = New-GitProj 'LeakIndexOnly'
    Write-Utf8 (Join-Path $projLeakIdx '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projLeakIdx '.env') "IDX_ONLY_SECRET=idxonlyvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projLeakIdx 'notes.txt') "clean`r`n"
    Add-Commit $projLeakIdx 'seed clean'
    Write-Utf8 (Join-Path $projLeakIdx 'notes.txt') "leaked: idxonlyvalue1234567890`r`n"
    & git -C $projLeakIdx add notes.txt 2>$null | Out-Null
    Write-Utf8 (Join-Path $projLeakIdx 'notes.txt') "clean again (worktree only)`r`n"
    $r = Fire -Cwd $projLeakIdx
    Check 'leak only in the git index (staged) is detected' ($r.Out -like '*IDX_ONLY_SECRET*appears in a git-tracked file*notes.txt*') $r.Out
    Check 'index-only leak: value never printed' ($r.Out -notlike '*idxonlyvalue1234567890*') $r.Out

    # Same leak present in BOTH the working tree and the index - reported once.
    $projLeakBoth = New-GitProj 'LeakBoth'
    Write-Utf8 (Join-Path $projLeakBoth '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projLeakBoth '.env') "BOTH_SECRET=bothvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projLeakBoth 'notes.txt') "leaked: bothvalue1234567890`r`n"
    & git -C $projLeakBoth add notes.txt 2>$null | Out-Null
    $r = Fire -Cwd $projLeakBoth
    Check 'leak in both working tree and index is reported exactly once (deduped)' (@($r.Out -split "`n" | Where-Object { $_ -like '*BOTH_SECRET*notes.txt*' }).Count -eq 1) $r.Out

    # Cleaned AND re-staged - true negative, must NOT be flagged.
    $projClean = New-GitProj 'LeakCleanedRestaged'
    Write-Utf8 (Join-Path $projClean '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projClean '.env') "CLEANED_SECRET=cleanedvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projClean 'notes.txt') "clean`r`n"
    Add-Commit $projClean 'seed clean'
    Write-Utf8 (Join-Path $projClean 'notes.txt') "leaked: cleanedvalue1234567890`r`n"
    & git -C $projClean add notes.txt 2>$null | Out-Null
    Write-Utf8 (Join-Path $projClean 'notes.txt') "clean again`r`n"
    & git -C $projClean add notes.txt 2>$null | Out-Null
    $r = Fire -Cwd $projClean
    Check 'cleaned and re-staged file is NOT flagged as a leak' ($r.Out -notlike '*CLEANED_SECRET*appears in a git-tracked file*') $r.Out

    # Nested file path.
    $projNested = New-GitProj 'LeakNestedPath'
    Write-Utf8 (Join-Path $projNested '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projNested '.env') "NESTED_LEAK=nestedvalue1234567890`r`n"
    New-Item -ItemType Directory -Path (Join-Path $projNested 'src\deep\dir') -Force | Out-Null
    Write-Utf8 (Join-Path $projNested 'src\deep\dir\config.txt') "leaked: nestedvalue1234567890`r`n"
    Add-Commit $projNested 'nested leak'
    $r = Fire -Cwd $projNested
    Check 'nested tracked file leak is detected with relative path' ($r.Out -match 'src[/\\]deep[/\\]dir[/\\]config\.txt') $r.Out

    # Path containing spaces (project root and file name both).
    $projSpace = New-GitProj 'Leak With Space'
    Write-Utf8 (Join-Path $projSpace '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projSpace '.env') "SPACE_LEAK=spacevalue1234567890`r`n"
    Write-Utf8 (Join-Path $projSpace 'my notes.txt') "leaked: spacevalue1234567890`r`n"
    Add-Commit $projSpace 'space leak'
    $r = Fire -Cwd $projSpace
    Check 'tracked file leak is detected when project/file paths contain spaces' ($r.Out -like '*SPACE_LEAK*appears in a git-tracked file*my notes.txt*') $r.Out
    Check 'no secret value ever appears in output or stderr (leak regression block)' (
        $r.Out -notlike '*spacevalue1234567890*' -and $r.Err -notlike '*spacevalue1234567890*'
    ) ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- outgoing-commit scan: the actual push-safety boundary (confirmed gap) ---' -ForegroundColor Cyan

    # Baseline sanity: a secret committed and pushed with no cleanup at all
    # must still be caught (the simplest outgoing case).
    $outBasic = New-PushableRepo 'OutgoingBasic'
    Write-Utf8 (Join-Path $outBasic '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outBasic 'baseline'
    Push-Repo $outBasic
    Write-Utf8 (Join-Path $outBasic '.env') "BASIC_OUTGOING_SECRET=basicoutgoingvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outBasic 'leak.txt') "leak: basicoutgoingvalue1234567890`r`n"
    Add-Commit $outBasic 'introduce a leak, never cleaned'
    $rBasic = FireGitPrePush -Cwd $outBasic -StdinText (Get-RefUpdateLine -Repo $outBasic)
    Check 'basic outgoing leak (no cleanup) is detected' ($rBasic.Exit -eq 1 -and $rBasic.Err -match 'BASIC_OUTGOING_SECRET' -and $rBasic.Err -match 'outgoing commit') $rBasic.Err

    # Secret in an OLDER outgoing commit, with a later cleanup commit also in
    # the same outgoing range - both worktree AND index are clean, only
    # history still carries it (the confirmed gap: neither `git grep` nor
    # `git grep --cached` sees this; also covers "introduced and removed
    # entirely within the outgoing range", since neither commit was ever
    # previously pushed).
    $outOlder = New-PushableRepo 'OutgoingOlderPlusCleanup'
    Write-Utf8 (Join-Path $outOlder '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outOlder 'baseline'
    Push-Repo $outOlder
    Write-Utf8 (Join-Path $outOlder '.env') "OLDER_COMMIT_SECRET=oldercommitvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outOlder 'leaked.txt') "leak: oldercommitvalue1234567890`r`n"
    Add-Commit $outOlder 'introduce leak (older outgoing commit)'
    Write-Utf8 (Join-Path $outOlder 'leaked.txt') "cleaned`r`n"
    Add-Commit $outOlder 'cleanup commit (also outgoing, tree now clean)'
    Check 'worktree and index are already clean before the push check' (@(& git -C $outOlder status --porcelain).Count -eq 0)
    $rOlder = FireGitPrePush -Cwd $outOlder -StdinText (Get-RefUpdateLine -Repo $outOlder)
    Check 'secret in an older outgoing commit is detected despite a clean later cleanup commit' ($rOlder.Exit -eq 1 -and $rOlder.Err -match 'OLDER_COMMIT_SECRET' -and $rOlder.Err -match 'outgoing commit') $rOlder.Err
    Check 'older-outgoing-commit leak: value never printed' ($rOlder.Err -notlike '*oldercommitvalue1234567890*') $rOlder.Err

    # A clean outgoing range must stay silent (no false blocker).
    $outClean = New-PushableRepo 'OutgoingCleanRange'
    Write-Utf8 (Join-Path $outClean '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outClean 'baseline'
    Push-Repo $outClean
    Write-Utf8 (Join-Path $outClean '.env') "CLEANRANGE_KEY=cleanrangevalue1234567890`r`n"
    Write-Utf8 (Join-Path $outClean 'notes.txt') "nothing secret in this outgoing range`r`n"
    Add-Commit $outClean 'unrelated, clean change'
    $rClean = FireGitPrePush -Cwd $outClean -StdinText (Get-RefUpdateLine -Repo $outClean)
    Check 'clean outgoing range never blocks' ($rClean.Exit -eq 0) $rClean.Err

    # New branch push: remote sha is all-zero. Scoped to commits not already
    # on any remote-tracking ref, so the already-pushed baseline is not rescanned.
    $outNewBranch = New-PushableRepo 'OutgoingNewBranch'
    Write-Utf8 (Join-Path $outNewBranch '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outNewBranch 'baseline'
    Push-Repo $outNewBranch
    & git -C $outNewBranch checkout -q -b feature
    Write-Utf8 (Join-Path $outNewBranch '.env') "NEWBRANCH_SECRET=newbranchvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outNewBranch 'feature.txt') "leak: newbranchvalue1234567890`r`n"
    Add-Commit $outNewBranch 'feature work with a leak'
    $stdinNewBranch = Get-RefUpdateLine -Repo $outNewBranch -Branch 'feature' -RemoteSha ('0' * 40)
    $rNewBranch = FireGitPrePush -Cwd $outNewBranch -StdinText $stdinNewBranch
    Check 'new branch push (remote sha all-zero) detects a leak in its only commit' ($rNewBranch.Exit -eq 1 -and $rNewBranch.Err -match 'NEWBRANCH_SECRET') $rNewBranch.Err

    # Deletion push: local sha is all-zero - nothing is being pushed for that
    # ref, so it contributes no commits to scan and must never crash.
    $outDelete = New-PushableRepo 'OutgoingDeletion'
    Write-Utf8 (Join-Path $outDelete '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outDelete 'baseline'
    Push-Repo $outDelete
    $deleteStdin = 'refs/heads/gone ' + ('0' * 40) + ' refs/heads/gone ' + ((& git -C $outDelete rev-parse HEAD | Out-String).Trim()) + "`n"
    $rDelete = FireGitPrePush -Cwd $outDelete -StdinText $deleteStdin
    Check 'deletion push (local sha all-zero) does not crash and scans nothing for that ref' ($rDelete.Exit -eq 0) $rDelete.Err

    # Force-push/non-fast-forward: the range is exactly the NEW divergent
    # commit(s), regardless of ancestry. A replaced commit that is no longer
    # reachable from local must not be rescanned (proves cleaned/replaced
    # history that is not part of the pushed result creates no false blocker)...
    $outForceClean = New-PushableRepo 'OutgoingForceCleanDivergence'
    Write-Utf8 (Join-Path $outForceClean '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outForceClean 'baseline'
    Write-Utf8 (Join-Path $outForceClean '.env') "FORCE_REPLACED_SECRET=forcereplacedvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outForceClean 'old.txt') "leak: forcereplacedvalue1234567890`r`n"
    Add-Commit $outForceClean 'commit A (has a leak, gets replaced)'
    Push-Repo $outForceClean
    $shaA = ((& git -C $outForceClean rev-parse HEAD) | Out-String).Trim()
    & git -C $outForceClean reset -q --hard HEAD~1
    Write-Utf8 (Join-Path $outForceClean 'new.txt') "unrelated, no secret`r`n"
    Add-Commit $outForceClean 'commit B (diverged, clean)'
    $rForceClean = FireGitPrePush -Cwd $outForceClean -StdinText (Get-RefUpdateLine -Repo $outForceClean -RemoteSha $shaA)
    Check 'force-push: the replaced (no longer reachable) commit is not rescanned' ($rForceClean.Exit -eq 0) $rForceClean.Err
    # ...but a leak IN the new divergent commit is still caught.
    $outForceLeak = New-PushableRepo 'OutgoingForceLeakDivergence'
    Write-Utf8 (Join-Path $outForceLeak '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outForceLeak 'baseline'
    Write-Utf8 (Join-Path $outForceLeak 'a.txt') "commit A content`r`n"
    Add-Commit $outForceLeak 'commit A (pushed, no secret yet)'
    Push-Repo $outForceLeak
    $shaA2 = ((& git -C $outForceLeak rev-parse HEAD) | Out-String).Trim()
    & git -C $outForceLeak reset -q --hard HEAD~1
    Write-Utf8 (Join-Path $outForceLeak '.env') "FORCE_LEAK_SECRET=forceleakvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outForceLeak 'c.txt') "leak: forceleakvalue1234567890`r`n"
    Add-Commit $outForceLeak 'commit C (diverged, has a leak)'
    $rForceLeak = FireGitPrePush -Cwd $outForceLeak -StdinText (Get-RefUpdateLine -Repo $outForceLeak -RemoteSha $shaA2)
    Check 'force-push/non-fast-forward: a leak in the new divergent commit is still detected' ($rForceLeak.Exit -eq 1 -and $rForceLeak.Err -match 'FORCE_LEAK_SECRET') $rForceLeak.Err

    # Multiple ref-update lines in ONE invocation (e.g. `git push --all`):
    # both refs' outgoing commits are scanned and their leaks reported.
    $outMulti = New-PushableRepo 'OutgoingMultiRef'
    Write-Utf8 (Join-Path $outMulti '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outMulti 'baseline'
    Push-Repo $outMulti
    Write-Utf8 (Join-Path $outMulti '.env') "MULTIREF_SECRET_A=multirefvalueA1234567890`r`nMULTIREF_SECRET_B=multirefvalueB1234567890`r`n"
    & git -C $outMulti checkout -q -b branchA
    Write-Utf8 (Join-Path $outMulti 'a.txt') "leak: multirefvalueA1234567890`r`n"
    Add-Commit $outMulti 'branchA leak'
    $stdinBranchA = Get-RefUpdateLine -Repo $outMulti -Branch 'branchA' -RemoteSha ('0' * 40)
    & git -C $outMulti checkout -q main
    & git -C $outMulti checkout -q -b branchB
    Write-Utf8 (Join-Path $outMulti 'b.txt') "leak: multirefvalueB1234567890`r`n"
    Add-Commit $outMulti 'branchB leak'
    $stdinBranchB = Get-RefUpdateLine -Repo $outMulti -Branch 'branchB' -RemoteSha ('0' * 40)
    $rMulti = FireGitPrePush -Cwd $outMulti -StdinText ($stdinBranchA + $stdinBranchB)
    Check 'multiple ref-update lines in one invocation: both leaks are detected' ($rMulti.Exit -eq 1 -and $rMulti.Err -match 'MULTIREF_SECRET_A' -and $rMulti.Err -match 'MULTIREF_SECRET_B') $rMulti.Err

    # Nested path with spaces, inside an outgoing commit.
    $outNested = New-PushableRepo 'OutgoingNestedSpace'
    Write-Utf8 (Join-Path $outNested '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outNested 'baseline'
    Push-Repo $outNested
    Write-Utf8 (Join-Path $outNested '.env') "NESTED_SPACE_SECRET=nestedspacevalue1234567890`r`n"
    New-Item -ItemType Directory -Path (Join-Path $outNested 'deep dir\sub folder') -Force | Out-Null
    Write-Utf8 (Join-Path $outNested 'deep dir\sub folder\my notes.txt') "leak: nestedspacevalue1234567890`r`n"
    Add-Commit $outNested 'nested leak with spaces'
    $rNested = FireGitPrePush -Cwd $outNested -StdinText (Get-RefUpdateLine -Repo $outNested)
    Check 'nested path with spaces in an outgoing commit is detected' ($rNested.Exit -eq 1 -and $rNested.Err -match 'NESTED_SPACE_SECRET' -and $rNested.Err -match [regex]::Escape('deep dir/sub folder/my notes.txt')) $rNested.Err
    Check 'nested/spaced outgoing leak: value never printed' ($rNested.Err -notlike '*nestedspacevalue1234567890*') $rNested.Err

    # =====================================================================
    Write-Host '--- outgoing-commit scan: real end-to-end git push (native pre-push chain) ---' -ForegroundColor Cyan
    $e2e = New-PushableRepo 'OutgoingRealPush'
    $e2eIgnore = @(
        '!/.env.dist', '!/.env.example', '!/.env.sample', '!/.env.template',
        '**/.ignoreme', '.ignoreme', '/.agents/', '/.ai/', '/.claude/', '/.cline/',
        '/.codex/', '/.cursor/', '/.env', '/.env.*', '/.kiro/', '/AGENTS.md',
        '/CLAUDE.md', '/explain-AI.md', '/graphify-out/', '/reference.md', '/secrets.md'
    ) -join "`r`n"
    Write-Utf8 (Join-Path $e2e '.gitignore') ($e2eIgnore + "`r`n")
    Add-Commit $e2e 'baseline with the full required ignore ruleset'
    Push-Repo $e2e
    $ignoreHook = Join-Path (Split-Path -Parent (Split-Path -Parent $Hook)) 'Ignore-Rules-Check\Ignore-Rules-Check.ps1'
    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $e2e -CodexOnly *> $null
    Write-Utf8 (Join-Path $e2e '.env') "E2E_REALPUSH_SECRET=e2erealpushvalue1234567890`r`n"
    Write-Utf8 (Join-Path $e2e 'leak.txt') "leak: e2erealpushvalue1234567890`r`n"
    Add-Commit $e2e 'introduce a real leak commit'
    Write-Utf8 (Join-Path $e2e 'leak.txt') "cleaned`r`n"
    Add-Commit $e2e 'clean it up in a later commit (still outgoing)'
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $e2e push origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEap
    Check 'real end-to-end git push is rejected by the native pre-push chain' ($pushExit -ne 0 -and $pushOutput -match 'SECRETS CHECK' -and $pushOutput -match 'outgoing commit') $pushOutput
    Check 'real end-to-end push: the secret value never appears in git''s output' ($pushOutput -notlike '*e2erealpushvalue1234567890*') $pushOutput

    # =====================================================================
    Write-Host '--- outgoing history: committed .env*/secrets.md later removed is still blocked (item 1) ---' -ForegroundColor Cyan

    # An outgoing commit adds a real .env with a secret, a later outgoing
    # commit untracks it - the current-file scan excludes .env, but the
    # outgoing-history scan must NOT, so the leak is caught.
    $envHist = New-PushableRepo 'OutgoingEnvHistory'
    Write-Utf8 (Join-Path $envHist '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $envHist 'baseline'
    Push-Repo $envHist
    Write-Utf8 (Join-Path $envHist '.env') "ENVHIST_SECRET=envhistvalue1234567890`r`n"
    & git -C $envHist add -f .env 2>$null | Out-Null
    Add-Commit $envHist 'oops commit .env'
    & git -C $envHist rm -q --cached .env 2>$null | Out-Null
    Write-Utf8 (Join-Path $envHist '.env') "ENVHIST_SECRET=envhistvalue1234567890`r`n"
    Add-Commit $envHist 'untrack .env (local copy kept, ignored)'
    $rEnvHist = FireGitPrePush -Cwd $envHist -StdinText (Get-RefUpdateLine -Repo $envHist)
    Check 'outgoing commit adds .env then removes it: push blocked' ($rEnvHist.Exit -eq 1 -and $rEnvHist.Err -match 'ENVHIST_SECRET' -and $rEnvHist.Err -match 'outgoing commit') $rEnvHist.Err
    Check 'outgoing .env-history leak: value never printed' ($rEnvHist.Err -notlike '*envhistvalue1234567890*') $rEnvHist.Err

    # Nested .env.local, later removed.
    $envNestedHist = New-PushableRepo 'OutgoingEnvNestedHistory'
    Write-Utf8 (Join-Path $envNestedHist '.gitignore') "**/.env*`nsecrets.md`n"
    Add-Commit $envNestedHist 'baseline'
    Push-Repo $envNestedHist
    New-Item -ItemType Directory -Path (Join-Path $envNestedHist 'apps\api') -Force | Out-Null
    Write-Utf8 (Join-Path $envNestedHist 'apps\api\.env.local') "NESTED_ENVHIST_SECRET=nestedenvhistvalue1234567890`r`n"
    & git -C $envNestedHist add -f apps/api/.env.local 2>$null | Out-Null
    Add-Commit $envNestedHist 'oops commit nested .env.local'
    & git -C $envNestedHist rm -q --cached apps/api/.env.local 2>$null | Out-Null
    Write-Utf8 (Join-Path $envNestedHist 'apps\api\.env.local') "NESTED_ENVHIST_SECRET=nestedenvhistvalue1234567890`r`n"
    Add-Commit $envNestedHist 'untrack nested .env.local'
    $rNestedHist = FireGitPrePush -Cwd $envNestedHist -StdinText (Get-RefUpdateLine -Repo $envNestedHist)
    Check 'outgoing commit adds nested .env.local then removes it: push blocked' ($rNestedHist.Exit -eq 1 -and $rNestedHist.Err -match 'NESTED_ENVHIST_SECRET' -and $rNestedHist.Err -match 'apps[/\\]api[/\\]\.env\.local') $rNestedHist.Err

    # secrets.md committed then removed.
    $secHist = New-PushableRepo 'OutgoingSecretsMdHistory'
    Write-Utf8 (Join-Path $secHist '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $secHist '.env') "SECMD_SECRET=secmdvalue1234567890`r`n"
    Add-Commit $secHist 'baseline'
    Push-Repo $secHist
    Write-Utf8 (Join-Path $secHist 'secrets.md') "# Secrets`n`n## SECMD_SECRET`n- Value: secmdvalue1234567890`n"
    & git -C $secHist add -f secrets.md 2>$null | Out-Null
    Add-Commit $secHist 'oops commit secrets.md'
    & git -C $secHist rm -q --cached secrets.md 2>$null | Out-Null
    Write-Utf8 (Join-Path $secHist 'secrets.md') "# Secrets`n`n## SECMD_SECRET`n- Value: secmdvalue1234567890`n"
    Add-Commit $secHist 'untrack secrets.md'
    $rSecHist = FireGitPrePush -Cwd $secHist -StdinText (Get-RefUpdateLine -Repo $secHist)
    Check 'outgoing commit adds secrets.md then removes it: push blocked' ($rSecHist.Exit -eq 1 -and $rSecHist.Err -match 'SECMD_SECRET' -and $rSecHist.Err -match 'secrets\.md') $rSecHist.Err
    Check 'outgoing secrets.md-history leak: value never printed' ($rSecHist.Err -notlike '*secmdvalue1234567890*') $rSecHist.Err

    # A current, ignored, local-only .env (never committed) must NOT be
    # reported as an outgoing-history leak - the outgoing range is clean.
    $envLocalOnly = New-PushableRepo 'OutgoingEnvLocalOnly'
    Write-Utf8 (Join-Path $envLocalOnly '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $envLocalOnly 'readme.txt') 'nothing secret'
    Add-Commit $envLocalOnly 'baseline'
    Push-Repo $envLocalOnly
    Write-Utf8 (Join-Path $envLocalOnly '.env') "LOCALONLY_SECRET=localonlyvalue1234567890`r`n"
    Write-Utf8 (Join-Path $envLocalOnly 'notes.txt') 'a clean outgoing change'
    Add-Commit $envLocalOnly 'clean outgoing commit'
    $rLocalOnly = FireGitPrePush -Cwd $envLocalOnly -StdinText (Get-RefUpdateLine -Repo $envLocalOnly)
    Check 'a current ignored local-only .env is NOT a false outgoing-history leak' ($rLocalOnly.Exit -eq 0) $rLocalOnly.Err

    # =====================================================================
    Write-Host '--- outgoing history: incomplete scans fail closed (item 2) ---' -ForegroundColor Cyan

    # >500 outgoing commits with a secret BEYOND the former 500 cutoff must
    # still be blocked (no security-skipping cap). Build the leak first (oldest
    # outgoing commit), then pile 520 trivial commits on top.
    $bigLeak = New-PushableRepo 'OutgoingBigRangeLeak'
    Write-Utf8 (Join-Path $bigLeak '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $bigLeak 'baseline'
    Push-Repo $bigLeak
    Write-Utf8 (Join-Path $bigLeak '.env') "BIGRANGE_SECRET=bigrangevalue1234567890`r`n"
    Write-Utf8 (Join-Path $bigLeak 'deep-leak.txt') "leak: bigrangevalue1234567890`r`n"
    Add-Commit $bigLeak 'the leak, at the very bottom of a 520-deep outgoing range'
    for ($n = 1; $n -le 520; $n++) { Write-Utf8 (Join-Path $bigLeak 'counter.txt') ("commit $n"); Add-Commit $bigLeak "trivial $n" }
    $rBigLeak = FireGitPrePush -Cwd $bigLeak -StdinText (Get-RefUpdateLine -Repo $bigLeak)
    Check '>500 outgoing commits with a leak beyond the former cutoff is still blocked' ($rBigLeak.Exit -eq 1 -and $rBigLeak.Err -match 'BIGRANGE_SECRET') $rBigLeak.Err

    # >500 clean outgoing commits must still be allowed (no false block, no
    # duplicate findings from batching).
    $bigClean = New-PushableRepo 'OutgoingBigRangeClean'
    Write-Utf8 (Join-Path $bigClean '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $bigClean '.env') "BIGCLEAN_SECRET=bigcleanvalue1234567890`r`n"
    Add-Commit $bigClean 'baseline'
    Push-Repo $bigClean
    for ($n = 1; $n -le 520; $n++) { Write-Utf8 (Join-Path $bigClean 'counter.txt') ("commit $n"); Add-Commit $bigClean "trivial $n" }
    $rBigClean = FireGitPrePush -Cwd $bigClean -StdinText (Get-RefUpdateLine -Repo $bigClean)
    Check '>500 clean outgoing commits are allowed (no false block)' ($rBigClean.Exit -eq 0) $rBigClean.Err

    # An unresolvable remote SHA (not present locally) must fail closed - block
    # with a safe incomplete-scan message, never treated as clean.
    $unresolvable = New-PushableRepo 'OutgoingUnresolvableRemote'
    Write-Utf8 (Join-Path $unresolvable '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $unresolvable 'baseline'
    Push-Repo $unresolvable
    Write-Utf8 (Join-Path $unresolvable 'notes.txt') 'clean'
    Add-Commit $unresolvable 'clean change'
    $fakeRemote = 'deadbeef' + ('0' * 32)
    $rUnresolvable = FireGitPrePush -Cwd $unresolvable -StdinText (Get-RefUpdateLine -Repo $unresolvable -RemoteSha $fakeRemote)
    Check 'unresolvable remote SHA fails closed (blocked with incomplete-scan message)' ($rUnresolvable.Exit -eq 1 -and $rUnresolvable.Err -match 'could not be fully scanned' -and $rUnresolvable.Err -match 'not resolvable locally') $rUnresolvable.Err
    Check 'incomplete-scan block never prints a secret value' ($rUnresolvable.Err -notlike '*bigrangevalue*' -and $rUnresolvable.Err -notlike '*bigcleanvalue*') $rUnresolvable.Err

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
    Write-Host '--- Stop event: decision:block shape ---' -ForegroundColor Cyan
    $proj8 = New-Proj 'StopBlock'
    Write-Utf8 (Join-Path $proj8 '.env') "STOP_KEY=abcdefghij1234567890`r`n"
    $r = Fire -Cwd $proj8 -EventName 'Stop'
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'Stop with findings returns decision:block' ($null -ne $parsed -and [string]$parsed.decision -eq 'block')
    Check 'block reason mentions the key, not the value' ($null -ne $parsed -and [string]$parsed.reason -like '*STOP_KEY*' -and [string]$parsed.reason -notlike '*abcdefghij1234567890*')

    $advisory = New-GitProj 'AdvisoryPush'
    Write-Utf8 (Join-Path $advisory '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $advisory '.env') "PLACEHOLDER_KEY=changeme`r`n"
    $r = Fire -Cwd $advisory -GitPrePush
    Check 'advisory-only pre-push findings exit zero' ($r.Exit -eq 0) $r.Err
    Check 'advisory-only pre-push is quiet' ([string]::IsNullOrWhiteSpace($r.Out) -and [string]::IsNullOrWhiteSpace($r.Err)) ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- Install-Hook.ps1: self-contained copy ---' -ForegroundColor Cyan
    $tgt = New-Proj 'Install'
    & $InstallScript -CustomHook $Hook -Events @('SessionStart', 'Stop') -TargetProject $tgt -ClaudeOnly *> $null
    $claudeJson = ''
    if (Test-Path (Join-Path $tgt '.claude\settings.local.json')) { $claudeJson = [System.IO.File]::ReadAllText((Join-Path $tgt '.claude\settings.local.json')) }
    Check 'installs as a self-contained local copy' (($claudeJson -like '*hooks\\Hook-Maker\\Secrets-Check\\Secrets-Check.ps1*') -and (Test-Path (Join-Path $tgt '.claude\hooks\Hook-Maker\Secrets-Check\Secrets-Check.ps1')) -and (Test-Path (Join-Path $tgt '.claude\hooks\Hook-Maker\_hooklib.ps1')))
    Check 'does not reference the tool folder' ($claudeJson -notlike '*Hook Maker*')

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $proj9 = New-Proj 'Host51'
    Write-Utf8 (Join-Path $proj9 '.env') "HOST_KEY=abcdefghij1234567890`r`n"
    $r = Fire -Cwd $proj9 -Exe 'powershell.exe'
    Check '5.1 host: auto-append + report works' ($r.Exit -eq 0 -and $r.Out -like '*Auto-added*HOST_KEY*' -and $r.Out -notlike '*abcdefghij1234567890*') $r.Out
}
finally {
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
