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
    param([string]$Cwd, [string]$EventName = 'Stop', [string]$Exe = 'pwsh', $RawStdin = $null)
    $payload = $RawStdin
    if ($null -eq $payload) {
        $payload = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName } | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    $file = $Exe
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
    Check 'install creates a managed native pre-push hook' ((Test-Path -LiteralPath $nativeHook) -and ([System.IO.File]::ReadAllText($nativeHook) -match 'Hook Maker: Ignore-Rules-Check'))
    Check 'install preserves an existing pre-push hook' (Test-Path -LiteralPath ($nativeHook + '.hookmaker-existing'))

    $remote = Join-Path $Work 'remote.git'
    & git init -q --bare $remote
    & git -C $pushRepo remote add origin $remote
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    Check 'first push is blocked after auto-fixing missing ignore rules' ($LASTEXITCODE -ne 0 -and $pushOutput -match 'IGNORE RULES CHECK' -and (Test-Path -LiteralPath (Join-Path $pushRepo '.gitignore'))) $pushOutput

    & git -C $pushRepo add .gitignore
    & git -C $pushRepo commit -q -m c2
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    Check 'clean push succeeds and still runs the previous hook' ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $pushRepo 'previous-hook.txt'))) $pushOutput
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
