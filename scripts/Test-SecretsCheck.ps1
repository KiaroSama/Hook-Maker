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
        $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
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
