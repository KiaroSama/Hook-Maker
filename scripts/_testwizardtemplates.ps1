# Test-Wizard.ps1 scenario block: the guided "Create a new hook" templates.
# Template 4 reuses the shipped Git-Sync-Check, which is split into sibling
# modules; a generated copy without them died at dot-source time on every event.
# The case generates it through the real wizard and RUNS the result.
#
# Dot-sourced by Test-Wizard.ps1 into the caller's scope (uses its harness).

    Write-Host '--- template 4 (git sync) generates a hook that runs ---' -ForegroundColor Cyan
    $tplName = 'ZZZ-TplGit'
    $realHooks = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
    $tplFolder = Join-Path $realHooks $tplName
    $cfgTpl = Join-Path $Work 'tpl-config.json'
    New-Config $cfgTpl
    try {
        $r = Invoke-Wizard -Config $cfgTpl -NoInstall -Answers @('1', '2', $tplName, '4', 'n', '0', '0')
        $shippedSiblings = @(Get-ChildItem -LiteralPath (Join-Path $realHooks 'Git-Sync-Check') -File -Filter '_*.ps1' | ForEach-Object { $_.Name } | Sort-Object)
        $generated = @(Get-ChildItem -LiteralPath $tplFolder -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        Check 'template 4: the entry script and .env.example are generated' (
            ($generated -contains ($tplName + '.ps1')) -and ($generated -contains '.env.example')) (($generated -join ', ') + ' | ' + $r.Out)
        Check 'template 4: every private sibling of the shipped hook is copied' (
            $shippedSiblings.Count -gt 0 -and @($shippedSiblings | Where-Object { $generated -notcontains $_ }).Count -eq 0) (
            'shipped=' + ($shippedSiblings -join ',') + ' generated=' + ($generated -join ','))
        $envText = [System.IO.File]::ReadAllText((Join-Path $tplFolder '.env.example'))
        Check 'template 4: default events match the shipped hook (its Stop half included)' (
            $envText -match '(?m)^EVENTS=SessionStart,PreToolUse,Stop,SubagentStop\r?$') $envText

        # A repository with one commit and no remote: enough for every event.
        $tplRepo = Join-Path $Work 'tpl repo'
        New-Item -ItemType Directory -Path $tplRepo -Force | Out-Null
        & git -C $tplRepo init -q 2>$null
        [System.IO.File]::WriteAllText((Join-Path $tplRepo 'a.txt'), 'x')
        & git -C $tplRepo add a.txt 2>$null
        & git -C $tplRepo -c user.email=t@example.invalid -c user.name=t commit -q -m init 2>$null
        $payload = @{ session_id = 'tpl1'; cwd = $tplRepo; hook_event_name = 'SessionStart'; source = 'startup' } | ConvertTo-Json
        $inF = Join-Path $Work 'tpl-in.json'; $outF = Join-Path $Work 'tpl-out.txt'; $errF = Join-Path $Work 'tpl-err.txt'
        [System.IO.File]::WriteAllText($inF, $payload, (New-Object System.Text.UTF8Encoding $false))
        $p = Start-BoundedProcess -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru `
            -ArgumentList @('-NoLogo', '-NoProfile', '-File', (Join-Path $tplFolder ($tplName + '.ps1'))) `
            -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF
        $tplErr = if (Test-Path -LiteralPath $errF) { ([System.IO.File]::ReadAllText($errF)).Trim() } else { '' }
        Check 'template 4: the generated hook runs a SessionStart event with exit 0 and no error' (
            $p.ExitCode -eq 0 -and $tplErr -eq '') ('exit=' + $p.ExitCode + ' err=' + $tplErr)
    }
    finally {
        Remove-Item -LiteralPath $tplFolder -Recurse -Force -ErrorAction SilentlyContinue
        Check 'the ZZZ-TplGit fixture was removed from the real hooks directory' (-not (Test-Path -LiteralPath $tplFolder)) $tplFolder
    }
