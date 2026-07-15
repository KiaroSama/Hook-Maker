# Functional test for the interactive wizard (Setup-SyncGroup.ps1). The wizard
# has no unit surface, so it is driven end to end through stdin - this is the
# only layer that exercises the menu structure, prompt rendering, hook listing,
# the client (-ClaudeOnly/-CodexOnly) splat, and the real Install-Hook writes.
# Two bugs hid here before this suite existed: a dropped prompt param and an
# array-vs-hashtable splat that mis-bound -ClaudeOnly onto Install-Hook's first
# positional parameter. Everything runs against throwaway temp projects.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-Wizard.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Setup = Join-Path $PSScriptRoot 'Setup-SyncGroup.ps1'
if (-not (Test-Path -LiteralPath $Setup -PathType Leaf)) {
    Write-Host "Wizard not found: $Setup" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red }
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-wiztest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# Drives the wizard with a list of stdin answers. Returns exit code, ANSI-stripped
# stdout, and trimmed stderr. A fresh config + project dirs per run keep it isolated.
function Invoke-Wizard {
    param([string[]]$Answers, [string]$Config, [switch]$NoInstall)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "in-$token.txt"; $outF = Join-Path $Work "out-$token.txt"; $errF = Join-Path $Work "err-$token.txt"
    [System.IO.File]::WriteAllText($inF, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    $argLine = '-NoLogo -NoProfile -File "' + $Setup + '" -ConfigPath "' + $Config + '"'
    if ($NoInstall) { $argLine += ' -NoInstall' }
    $p = Start-Process pwsh -ArgumentList $argLine -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -Wait -NoNewWindow -PassThru
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\x1b\[[0-9;]*m", ''); Err = $err }
}

function New-Config {
    param([string]$Path)
    '{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[]}' |
        Set-Content -LiteralPath $Path -Encoding utf8
}
function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

try {
    # =====================================================================
    Write-Host '--- menu structure + listing + sync-group create (-NoInstall) ---' -ForegroundColor Cyan
    $cfg1 = Join-Path $Work 'cfg1.json'; New-Config $cfg1
    $a = New-Proj 'A1'; $b = New-Proj 'B1'
    # main 1 -> sub 1 (install existing) -> item 1 (sync group) -> A,B,done -> client Both -> start
    $r = Invoke-Wizard -Config $cfg1 -NoInstall -Answers @('1', '1', '1', $a, $b, 'done', '1', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    Check 'main menu merged (Create or install a hook)' ($r.Out -match '1\. Create or install a hook')
    Check 'no separate top-level sync-group option' ($r.Out -notmatch '1\. Create or update a sync group\s*\r?\n\s*2\. Show')
    Check 'sync group is list item 1' ($r.Out -match '1\. Create or update a sync group')
    Check 'context hook menu names match their whole-.ai scope' ($r.Out -match 'Ai-Context-Check' -and $r.Out -match 'Ai-Context-Load')
    Check 'old memory-only menu names are hidden' ($r.Out -notmatch 'Ai-Memory-(Check|Load)')
    # The engine is reachable ONLY through item 1's hardcoded description line
    # (checked by "menu parts are pipe-separated" below), NOT by its own
    # hyphenated name as a separate list item: installed as a generic custom
    # hook (no -Profile, no config copy) it can never find its routing config
    # once copied into a project and silently does nothing.
    Check 'engine is NOT a separate numbered list entry' ($r.Out -notmatch '\d+\.\s+Cross-Project')
    Check 'listing shows timing tags' ($r.Out -match '\[post-task\]' -and $r.Out -match '\[pre-task\]')
    Check 'listing shows short descriptions' ($r.Out -match 'relevant \.ai context files' -and $r.Out -match 'checks global \+ project rules')
    Check 'menu parts are pipe-separated' ($r.Out -match 'Create or update a sync group \| \[pre-task\] \| cross-project \.ai knowledge sync')
    $menuOrder = @(
        '1\. Create or update a sync group', '2\. Ai-Context-Check', '3\. Ai-Context-Load',
        '4\. Ci-Status-Check', '5\. Dependabot-Check', '6\. Github-Baseline-Check',
        '7\. Git-Sync-Check', '8\. Cloudflare-Deploy', '9\. Graph-Read-Check',
        '10\. Graph-Update-Check', '11\. Large-File-Check', '12\. Mcp-Usage-Check',
        '13\. Rules-Check', '14\. Skills-Check', '15\. Secrets-Check'
    ) -join '[\s\S]*'
    Check 'hooks follow the requested menu order' ($r.Out -match $menuOrder)
    Check '_hooklib excluded from listing' ($r.Out -notmatch '_hooklib')
    Check 'full back suffix on sub-prompts' ($r.Out -match 'back=0' -and $r.Out -match 'quit=exit')
    Check 'main-menu suffix is quit-only' ($r.Out -match 'Select an option.*\{quit=exit\}')
    Check 'config validated' ($r.Out -match 'configuration validated')
    Check 'install skipped (-NoInstall)' ($r.Out -match 'hook install skipped')
    $prof1 = @((Get-Content $cfg1 -Raw | ConvertFrom-Json).profiles)
    Check 'one full-mesh profile written' ($prof1.Count -eq 1 -and $prof1[0].id -match '^sync-group-[0-9a-f]{10}$' -and @($prof1[0].routes).Count -eq 2)

    # =====================================================================
    Write-Host '--- install a real hook (list offset + Claude-only targeting) ---' -ForegroundColor Cyan
    $cfg2 = Join-Path $Work 'cfg2.json'; New-Config $cfg2
    $t = New-Proj 'T2'
    # main 1 -> sub 1 (install existing) -> item 2 (displayed as Ai-Context-Check,
    # internally Ai-Memory-Check) -> events SessionStart -> client Claude -> target -> done -> start
    $r = Invoke-Wizard -Config $cfg2 -Answers @('1', '1', '2', '2', '2', $t, 'done', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    $claude2 = Join-Path $t '.claude\settings.local.json'
    Check 'claude settings written' (Test-Path $claude2)
    $j2 = ''; if (Test-Path $claude2) { $j2 = [System.IO.File]::ReadAllText($claude2) }
    Check 'item 2 installed the FIRST real hook (Ai-Memory-Check)' ($j2 -match 'Ai-Memory-Check\.ps1')
    Check 'did not install a neighbor hook' ($j2 -notmatch 'Ci-Status-Check')
    Check 'Claude-only leaves codex untouched' (-not (Test-Path (Join-Path $t '.codex\hooks.json')) -and -not (Test-Path (Join-Path $t '.codex')))
    # Self-contained install: the command points at a runtime copy INSIDE the
    # project, named with the friendly hyphenated hook name.
    Check 'command points at the project-local copy' ($j2 -like '*hooks\\Hook-Maker\\Ai-Memory-Check\\Ai-Memory-Check.ps1*')
    Check 'command does not reference the tool folder' ($j2 -notlike '*Hook Maker*')
    Check 'runtime copy of the hook exists' (Test-Path (Join-Path $t '.claude\hooks\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1'))
    Check 'runtime copy of _hooklib exists' (Test-Path (Join-Path $t '.claude\hooks\Hook-Maker\_hooklib.ps1'))
    Check 'runtime copy has no .env.example' (-not (Test-Path (Join-Path $t '.claude\hooks\Hook-Maker\Ai-Memory-Check\.env.example')))

    # =====================================================================
    Write-Host '--- sync group with a real install (both clients) ---' -ForegroundColor Cyan
    $cfg3 = Join-Path $Work 'cfg3.json'; New-Config $cfg3
    $a3 = New-Proj 'A3'; $b3 = New-Proj 'B3'
    $r = Invoke-Wizard -Config $cfg3 -Answers @('1', '1', '1', $a3, $b3, 'done', '1', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    $profId3 = (@((Get-Content $cfg3 -Raw | ConvertFrom-Json).profiles)[0]).id
    foreach ($proj in @($a3, $b3)) {
        $name = Split-Path -Leaf $proj
        Check "$name got claude settings" (Test-Path (Join-Path $proj '.claude\settings.local.json'))
        Check "$name got codex hooks" (Test-Path (Join-Path $proj '.codex\hooks.json'))
        $cl = Join-Path $proj '.claude\settings.local.json'
        $jc = ''; if (Test-Path $cl) { $jc = [System.IO.File]::ReadAllText($cl) }
        Check "$name command points at engine + this profile" ($jc -match 'Cross-Project-\.ai-Knowledge-Sync\.ps1' -and $jc -match [regex]::Escape($profId3))
        # Self-contained: engine + lib + routing config copied into BOTH clients,
        # the engine folder/script under the friendly name.
        $eng = 'hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'
        $engCfg = 'hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\sync-hooks.json'
        Check "$name command uses the local engine copy" ($jc -like ('*' + $eng.Replace('\', '\\') + '*') -and $jc -notlike '*Hook Maker*')
        Check "$name claude runtime copy complete" ((Test-Path (Join-Path $proj (Join-Path '.claude' $eng))) -and (Test-Path (Join-Path $proj '.claude\hooks\Hook-Maker\_hooklib.ps1')) -and (Test-Path (Join-Path $proj (Join-Path '.claude' $engCfg))))
        Check "$name codex runtime copy complete" ((Test-Path (Join-Path $proj (Join-Path '.codex' $eng))) -and (Test-Path (Join-Path $proj (Join-Path '.codex' $engCfg))))
        # The copied engine must actually RUN from inside the project with the
        # copied config: fire it once via stdin and require a clean exit.
        $localEngine = Join-Path $proj (Join-Path '.claude' $eng)
        $localCfg = Join-Path $proj (Join-Path '.claude' $engCfg)
        $inE = Join-Path $Work ('eng-' + $name + '.json'); $outE = "$inE.out"; $errE = "$inE.err"
        [System.IO.File]::WriteAllText($inE, (@{ session_id = 'wiztest'; cwd = $proj; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
        $pe = Start-Process pwsh -ArgumentList ('-NoLogo -NoProfile -NonInteractive -File "' + $localEngine + '" -ConfigPath "' + $localCfg + '" -Profile "' + $profId3 + '"') -RedirectStandardInput $inE -RedirectStandardOutput $outE -RedirectStandardError $errE -Wait -NoNewWindow -PassThru
        $errText = ''; if (Test-Path $errE) { $errText = ([System.IO.File]::ReadAllText($errE)).Trim() }
        Check "$name local engine copy runs cleanly" ($pe.ExitCode -eq 0 -and $errText -eq '')
    }

    # =====================================================================
    Write-Host '--- multi-select install (comma list, same settings) ---' -ForegroundColor Cyan
    $cfg4 = Join-Path $Work 'cfg4.json'; New-Config $cfg4
    $m = New-Proj 'Multi'
    # main 1 -> sub 1 -> "2,3,4" (three advisory hooks; the engine is excluded
    #        from this list entirely, see the guard test below)
    #        -> mode 1 (same) -> events SessionStart -> client Both -> target -> done -> start -> exit
    $r = Invoke-Wizard -Config $cfg4 -Answers @('1', '1', '2,3,4', '1', '2', '1', $m, 'done', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    $installedFolders = @(Get-ChildItem -LiteralPath (Join-Path $m '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'three distinct hooks installed in one pass' ($installedFolders.Count -eq 3)
    Check 'each installed under its own friendly folder' ($installedFolders -notcontains 'Cross-Project-.ai-Knowledge-Sync' -and (@($installedFolders | Where-Object { $_ -match '-' }).Count -eq 3))
    $codexFolders = @(Get-ChildItem -LiteralPath (Join-Path $m '.codex\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'batch honored client=Both (codex got all three too)' ($codexFolders.Count -eq 3)
    Check 'summary lists all three (3 event lines)' (([regex]::Matches($r.Out, 'events:')).Count -ge 3)

    # =====================================================================
    Write-Host '--- multi-select: sync group (1) combined with a hook runs both, once ---' -ForegroundColor Cyan
    $cfg5 = Join-Path $Work 'cfg5.json'; New-Config $cfg5
    $c = New-Proj 'ComboC'; $d = New-Proj 'ComboD'; $e = New-Proj 'ComboE'
    # main 1 -> sub 1 -> "1,2" (sync group + Ai-Memory-Check) ->
    #   [sync group wizard: C, D, done, client Both, confirm] ->
    #   [single-hook config: events SessionStart+UPS, client Both, target E, done, confirm] -> exit
    $r2 = Invoke-Wizard -Config $cfg5 -Answers @('1', '1', '1,2', $c, $d, 'done', '1', '', '1', '1', $e, 'done', '', '0')
    Check 'exit 0' ($r2.Exit -eq 0)
    Check 'no stderr' ($r2.Err -eq '')
    Check 'runs the sync group first, then the hook, without repeating the menu' ($r2.Out -match 'Running the sync group first')
    Check 'completion message counts both' ($r2.Out -match 'Sync group \+ 1 hook\(s\) installed')
    $prof5 = @((Get-Content $cfg5 -Raw | ConvertFrom-Json).profiles)
    Check 'sync group profile was applied' ($prof5.Count -eq 1 -and @($prof5[0].routes).Count -eq 2)
    Check 'the hook was installed at the separate target' (Test-Path (Join-Path $e '.claude\hooks\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1'))
    Check 'the sync group did NOT install the hook, or vice versa' ((-not (Test-Path (Join-Path $c '.claude\hooks\Hook-Maker\Ai-Memory-Check'))) -and (-not (Test-Path (Join-Path $e '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync'))))

    Write-Host '--- multi-select: sync group alone still works (unchanged) ---' -ForegroundColor Cyan
    $cfg6 = Join-Path $Work 'cfg6.json'; New-Config $cfg6
    $f = New-Proj 'SoloF'; $g = New-Proj 'SoloG'
    $r3 = Invoke-Wizard -Config $cfg6 -Answers @('1', '1', '1', $f, $g, 'done', '1', '', '0')
    Check 'exit 0' ($r3.Exit -eq 0)
    Check 'no stderr' ($r3.Err -eq '')
    # NOTE: -match is case-INSENSITIVE by default, and the main menu's own
    # static description text is "(sync group + hooks\ folder)" - a plain
    # 'Sync group \+' pattern collides with that. Anchor on "N hook(s)
    # installed" (the actual completion-message shape) to target only the
    # combined-install summary, never the menu label.
    Check 'sync-group-only completion message (no "+ N hooks installed")' ($r3.Out -match 'Restart the Claude/Codex clients' -and $r3.Out -notmatch 'Sync group \+ \d+ hook')
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
