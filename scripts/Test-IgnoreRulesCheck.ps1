param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Ignore-Rules-Check\Ignore-Rules-Check.ps1'
$InstallScript = Join-Path $PSScriptRoot 'Install-Hook.ps1'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-ignoretest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Repo {
    param([string]$Name)
    $repo = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    return $repo
}

function Fire {
    param([string]$Cwd, [string]$EventName = 'Stop', [string]$Exe = '', $RawStdin = $null)
    $payload = $RawStdin
    if ($null -eq $payload) {
        $payload = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName } | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    $file = if ([string]::IsNullOrWhiteSpace($Exe)) { (Get-Process -Id $PID).Path } else { $Exe }
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"'
    $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

try {
    if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
        Write-Host 'Hook not found (expected RED before implementation).' -ForegroundColor Red
        exit 1
    }

    $repo = New-Repo 'auto'
    $rulesDir = Join-Path $repo '.claude\rules'
    New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $rulesDir 'local.md'), 'Keep `/private-cache/` local-only and git-ignored.', (New-Object System.Text.UTF8Encoding $false))

    $r = Fire -Cwd $repo -RawStdin ''
    Check 'empty stdin -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $repo -EventName 'UserPromptSubmit'
    Check 'unconfigured event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $repo -EventName 'SessionStart'
    $ignore = [System.IO.File]::ReadAllText((Join-Path $repo '.gitignore'))
    Check 'SessionStart auto-adds required protected patterns' ($ignore -match '(?m)^/\.ai/$' -and $ignore -match '(?m)^/AGENTS\.md$' -and $ignore -match '(?m)^\*\*/\.ignoreme$') $ignore
    Check 'SessionStart extracts a local-only path from project rules' ($ignore -match '(?m)^/private-cache/$') $ignore
    Check 'pre-task auto-fix reports context' ($r.Out -match '"hookSpecificOutput"' -and $r.Out -match 'Auto-added') $r.Out
    $r = Fire -Cwd $repo
    Check 'clean post-task Stop -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $post = New-Repo 'post'
    $r = Fire -Cwd $post
    $postIgnore = [System.IO.File]::ReadAllText((Join-Path $post '.gitignore'))
    Check 'Stop also auto-adds required protected patterns' ($postIgnore -match '(?m)^/\.ai/$') $postIgnore
    Check 'post-task auto-fix blocks once for review' ($r.Out -match '"decision":"block"' -and $r.Out -match 'Auto-added') $r.Out

    $tracked = New-Repo 'tracked'
    [System.IO.File]::WriteAllText((Join-Path $tracked 'AGENTS.md'), 'private', (New-Object System.Text.UTF8Encoding $false))
    & git -C $tracked add -f AGENTS.md
    & git -C $tracked commit -q -m c
    $r = Fire -Cwd $tracked
    Check 'tracked protected file blocks completion' ($r.Out -match 'TRACKED' -and $r.Out -match 'AGENTS.md') $r.Out

    $ps5 = New-Repo 'ps5'
    $r = Fire -Cwd $ps5 -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 auto-fix works' ($r.Exit -eq 0 -and (Test-Path -LiteralPath (Join-Path $ps5 '.gitignore'))) $r.Err

    Write-Host '--- native git pre-push enforcement ---' -ForegroundColor Cyan
    $pushRepo = New-Repo 'pre push'
    & git -C $pushRepo config core.autocrlf false
    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'file.txt'), 'v1', (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add file.txt
    & git -C $pushRepo commit -q -m c1
    $nativeHook = Join-Path $pushRepo '.git\hooks\pre-push'
    [System.IO.File]::WriteAllText($nativeHook, "#!/bin/sh`necho previous > previous-hook.txt`n", (New-Object System.Text.UTF8Encoding $false))
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $pushRepo -CodexOnly *> $null
    $nativeBody = [System.IO.File]::ReadAllText($nativeHook)
    Check 'install creates a managed native pre-push hook' ((Test-Path -LiteralPath $nativeHook) -and ($nativeBody -match 'Hook Maker: Ignore-Rules-Check'))
    Check 'install preserves an existing pre-push hook' (Test-Path -LiteralPath ($nativeHook + '.hookmaker-existing'))
    $prePushRuntime = Join-Path $pushRepo '.git\hooks\Hook-Maker'
    $ignoreCommand = $nativeBody.IndexOf('Ignore-Rules-Check.ps1')
    $secretsCommand = $nativeBody.IndexOf('Secrets-Check.ps1')
    $previousCommand = $nativeBody.IndexOf('.hookmaker-existing')
    Check 'pre-push bundles only the two push-safety checks' (
        (Test-Path -LiteralPath (Join-Path $prePushRuntime 'Ignore-Rules-Check\Ignore-Rules-Check.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $prePushRuntime 'Secrets-Check\Secrets-Check.ps1')) -and
        -not (Test-Path -LiteralPath (Join-Path $prePushRuntime 'Large-File-Check')) -and
        $nativeBody -notmatch 'Large-File-Check\.ps1')
    Check 'pre-push order is Ignore then Secrets then previous hook' (
        $ignoreCommand -ge 0 -and $ignoreCommand -lt $secretsCommand -and $secretsCommand -lt $previousCommand)

    $customRepo = New-Repo 'custom hooks path'
    & git -C $customRepo config core.hooksPath '.config/hooks nested'
    $customHooks = Join-Path $customRepo '.config\hooks nested'
    New-Item -ItemType Directory -Path $customHooks -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $customHooks 'pre-push'), "#!/bin/sh`necho custom > custom-hook.txt`n", (New-Object System.Text.UTF8Encoding $false))
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $customRepo -CodexOnly *> $null
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $customRepo -CodexOnly *> $null
    $customBody = [System.IO.File]::ReadAllText((Join-Path $customHooks 'pre-push'))
    Check 'relative custom hooksPath receives managed runtime without hooks/hooks duplication' (
        (Test-Path (Join-Path $customHooks 'Hook-Maker\Ignore-Rules-Check\Ignore-Rules-Check.ps1')) -and
        -not (Test-Path (Join-Path $customHooks 'hooks\Hook-Maker')))
    Check 'custom pre-push is preserved exactly once across reinstall' (
        (Test-Path (Join-Path $customHooks 'pre-push.hookmaker-existing')) -and
        ([regex]::Matches($customBody, 'Hook Maker: Ignore-Rules-Check').Count -eq 1))

    $absoluteRepo = New-Repo 'absolute hooks repo'
    $absoluteHooks = Join-Path $Work 'absolute hooks path'
    New-Item -ItemType Directory -Path $absoluteHooks -Force | Out-Null
    & git -C $absoluteRepo config core.hooksPath $absoluteHooks
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $absoluteRepo -CodexOnly *> $null
    Check 'absolute custom hooksPath with spaces receives the managed chain' (
        (Test-Path (Join-Path $absoluteHooks 'pre-push')) -and
        (Test-Path (Join-Path $absoluteHooks 'Hook-Maker\Secrets-Check\Secrets-Check.ps1')))

    $remote = Join-Path $Work 'remote.git'
    & git init -q --bare $remote
    & git -C $pushRepo remote add origin $remote
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'first push is blocked after auto-fixing missing ignore rules' ($pushExit -ne 0 -and $pushOutput -match 'IGNORE RULES CHECK' -and (Test-Path -LiteralPath (Join-Path $pushRepo '.gitignore'))) $pushOutput

    & git -C $pushRepo add .gitignore
    & git -C $pushRepo commit -q -m c2
    [System.IO.File]::WriteAllText((Join-Path $pushRepo '.env'), 'API_KEY=fixture-value-123456789', (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'leak.txt'), 'fixture-value-123456789', (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add leak.txt
    & git -C $pushRepo commit -q -m c2b
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'Secrets-Check blocks before the previous hook' ($pushExit -ne 0 -and $pushOutput -match 'SECRETS CHECK' -and -not (Test-Path -LiteralPath (Join-Path $pushRepo 'previous-hook.txt'))) $pushOutput

    Remove-Item -LiteralPath (Join-Path $pushRepo 'leak.txt') -Force
    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'use.txt'), 'API_KEY', (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllLines((Join-Path $pushRepo 'big.ps1'), @(1..801 | ForEach-Object { '# line' }), (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add use.txt big.ps1
    & git -C $pushRepo commit -q -m c3
    $largeHook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Large-File-Check\Large-File-Check.ps1'
    $largePrePushOutput = (& $largeHook -GitPrePush 2>&1 | Out-String)
    Check 'Large-File-Check never decides whether a push may proceed' ($LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($largePrePushOutput)) $largePrePushOutput
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'large source files do not block push and the previous hook runs' ($pushExit -eq 0 -and $pushOutput -notmatch 'LARGE FILE CHECK' -and (Test-Path -LiteralPath (Join-Path $pushRepo 'previous-hook.txt'))) $pushOutput

    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'big.ps1'), '# small', (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add big.ps1
    & git -C $pushRepo commit -q -m c4
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'clean push succeeds and still runs the previous hook' ($pushExit -eq 0 -and (Test-Path -LiteralPath (Join-Path $pushRepo 'previous-hook.txt'))) $pushOutput
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        Get-ChildItem -LiteralPath $Work -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        [System.IO.Directory]::Delete($Work, $true)
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
