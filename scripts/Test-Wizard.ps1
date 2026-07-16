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
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

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
    $hostExecutable = (Get-Process -Id $PID).Path
    $p = Start-Process $hostExecutable -ArgumentList $argLine -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -Wait -NoNewWindow -PassThru
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

function Get-RegisteredEvents {
    param([string]$SettingsPath, [string]$HookName)
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    $events = New-Object System.Collections.Generic.List[string]
    $pattern = '[\\/]' + [regex]::Escape($HookName) + '[\\/]' + [regex]::Escape($HookName + '.ps1')
    foreach ($event in $settings.hooks.PSObject.Properties) {
        $matched = $false
        foreach ($group in @($event.Value)) {
            foreach ($handler in @($group.hooks)) {
                foreach ($property in @('command', 'commandWindows', 'command_windows')) {
                    if ($null -ne $handler.PSObject.Properties[$property] -and [string]$handler.$property -match $pattern) { $matched = $true }
                }
            }
        }
        if ($matched) { [void]$events.Add($event.Name) }
    }
    return $events.ToArray()
}

try {
    # =====================================================================
    Write-Host '--- menu structure + listing + sync-group create (-NoInstall) ---' -ForegroundColor Cyan
    $cfg1 = Join-Path $Work 'cfg1.json'; New-Config $cfg1
    $a = New-Proj 'A1'; $b = New-Proj 'B1'
    # main 1 -> sub 1 (install existing) -> item 2 (sync group) -> A,B,done -> client Both -> start
    $r = Invoke-Wizard -Config $cfg1 -NoInstall -Answers @('1', '1', '2', $a, $b, 'done', '1', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    Check 'main menu merged (Create or install a hook)' ($r.Out -match '1\. Create or install a hook')
    Check 'no separate top-level sync-group option' ($r.Out -notmatch '1\. Create or update a sync group\s*\r?\n\s*2\. Show')
    Check 'select-all is list item 1' ($r.Out -match '1\. Select all hooks')
    Check 'sync group is list item 2' ($r.Out -match '2\. Create or update a sync group')
    Check 'context hook menu names match their whole-.ai scope' ($r.Out -match 'Ai-Context-Check' -and $r.Out -match 'Ai-Context-Load')
    Check 'old memory-only menu names are hidden' ($r.Out -notmatch 'Ai-Memory-(Check|Load)')
    # The engine is reachable ONLY through item 2's hardcoded description line
    # (checked by "menu parts are pipe-separated" below), NOT by its own
    # hyphenated name as a separate list item: installed as a generic custom
    # hook (no -Profile, no config copy) it can never find its routing config
    # once copied into a project and silently does nothing.
    Check 'engine is NOT a separate numbered list entry' ($r.Out -notmatch '\d+\.\s+Cross-Project')
    Check 'listing shows timing tags' ($r.Out -match '\[post-task\]' -and $r.Out -match '\[pre-task\]')
    Check 'listing shows short descriptions' ($r.Out -match 'relevant \.ai context files' -and $r.Out -match 'checks global \+ project rules')
    Check 'menu parts are pipe-separated' ($r.Out -match 'Create or update a sync group \| \[pre-task\] \| cross-project \.ai knowledge sync')
    $menuOrder = @(
        '1\. Select all hooks', '2\. Create or update a sync group', '3\. Ai-Context-Check',
        '4\. Ai-Context-Load', '5\. Ci-Status-Check', '6\. Dependabot-Check',
        '7\. Github-Baseline-Check', '8\. Git-Sync-Check', '9\. Graph-Read-Check',
        '10\. Graph-Update-Check', '11\. Large-File-Check', '12\. Mcp-Usage-Check',
        '13\. Rules-Check', '14\. Skills-Check', '15\. Secrets-Check',
        '16\. Ignore-Rules-Check', '17\. Cloudflare-Deploy'
    ) -join '[\s\S]*'
    Check 'hooks follow the requested menu order (Select all -> sync group -> hooks, Cloudflare-Deploy last)' ($r.Out -match $menuOrder)
    Check '_hooklib excluded from listing' ($r.Out -notmatch '_hooklib')
    Check 'full back suffix on sub-prompts' ($r.Out -match 'back=0' -and $r.Out -match 'quit=exit')
    Check 'main-menu suffix is quit-only' ($r.Out -match 'Select an option.*\{quit=exit\}')
    Check 'config validated' ($r.Out -match 'configuration validated')
    Check 'install skipped (-NoInstall)' ($r.Out -match 'hook install skipped')
    $prof1 = @((Get-Content $cfg1 -Raw | ConvertFrom-Json).profiles)
    Check 'one full-mesh profile written' ($prof1.Count -eq 1 -and $prof1[0].id -match '^sync-group-[0-9a-f]{10}$' -and @($prof1[0].routes).Count -eq 2)

    # =====================================================================
    Write-Host '--- back navigation returns exactly one menu level ---' -ForegroundColor Cyan
    $cfgNav = Join-Path $Work 'cfg-nav.json'; New-Config $cfgNav
    $rNav = Invoke-Wizard -Config $cfgNav -Answers @(
        '1', '1', '2', '0', # sync-group project entry -> hook list
        '0',                # hook list -> create/install menu
        '2', '0',           # create-hook first prompt -> create/install menu
        '3', '0',           # config-install hook list -> create/install menu
        '0',                # create/install menu -> main menu
        'exit'
    )
    Check 'sync-group project back returns to the hook list' (([regex]::Matches($rNav.Out, 'Tip: use lists and ranges')).Count -eq 2)
    Check 'sub-flow back always returns to the create/install menu' (([regex]::Matches($rNav.Out, 'Create or Install a Hook')).Count -eq 4)
    Check 'create/install back returns to the main menu' (([regex]::Matches($rNav.Out, 'Main menu:')).Count -eq 2)

    # =====================================================================
    Write-Host '--- install a real hook (list offset + Claude-only targeting) ---' -ForegroundColor Cyan
    $cfg2 = Join-Path $Work 'cfg2.json'; New-Config $cfg2
    $t = New-Proj 'T2'
    # main 1 -> sub 1 (install existing) -> item 3 (displayed as Ai-Context-Check,
    # internally Ai-Memory-Check) -> events SessionStart -> client Claude -> target -> done -> start
    $r = Invoke-Wizard -Config $cfg2 -Answers @('1', '1', '3', '2', '2', $t, 'done', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    Check 'event menu separates camel-case labels' ($r.Out -match 'Session Start \+ User Prompt Submit' -and $r.Out -match 'User Prompt Submit' -and $r.Out -match 'Pre Tool Use, Post Tool Use, Stop')
    $claude2 = Join-Path $t '.claude\settings.local.json'
    Check 'claude settings written' (Test-Path $claude2)
    $j2 = ''; if (Test-Path $claude2) { $j2 = [System.IO.File]::ReadAllText($claude2) }
    Check 'item 3 installed the FIRST real hook (Ai-Memory-Check)' ($j2 -match 'Ai-Memory-Check\.ps1')
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
    $r = Invoke-Wizard -Config $cfg3 -Answers @('1', '1', '2', $a3, $b3, 'done', '1', '', '0')
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
        $engProjects = 'hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\SYNC-PROJECTS.txt'
        Check "$name command uses the local engine copy" ($jc -like ('*' + $eng.Replace('\', '\\') + '*') -and $jc -notlike '*Hook Maker*')
        Check "$name claude runtime copy complete" ((Test-Path (Join-Path $proj (Join-Path '.claude' $eng))) -and (Test-Path (Join-Path $proj '.claude\hooks\Hook-Maker\_hooklib.ps1')) -and (Test-Path (Join-Path $proj (Join-Path '.claude' $engCfg))))
        Check "$name codex runtime copy complete" ((Test-Path (Join-Path $proj (Join-Path '.codex' $eng))) -and (Test-Path (Join-Path $proj (Join-Path '.codex' $engCfg))))
        foreach ($clientDir in @('.claude', '.codex')) {
            $projectList = Join-Path $proj (Join-Path $clientDir $engProjects)
            $projectListText = ''; if (Test-Path $projectList) { $projectListText = [System.IO.File]::ReadAllText($projectList) }
            Check "$name $clientDir runtime lists the sync projects" ((Test-Path $projectList) -and $projectListText.Contains($a3) -and $projectListText.Contains($b3))
        }
        # The copied engine must actually RUN from inside the project with the
        # copied config: fire it once via stdin and require a clean exit.
        $localEngine = Join-Path $proj (Join-Path '.claude' $eng)
        $localCfg = Join-Path $proj (Join-Path '.claude' $engCfg)
        $inE = Join-Path $Work ('eng-' + $name + '.json'); $outE = "$inE.out"; $errE = "$inE.err"
        [System.IO.File]::WriteAllText($inE, (@{ session_id = 'wiztest'; cwd = $proj; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
        $engineHost = (Get-Process -Id $PID).Path
        $pe = Start-Process $engineHost -ArgumentList ('-NoLogo -NoProfile -NonInteractive -File "' + $localEngine + '" -ConfigPath "' + $localCfg + '" -Profile "' + $profId3 + '"') -RedirectStandardInput $inE -RedirectStandardOutput $outE -RedirectStandardError $errE -Wait -NoNewWindow -PassThru
        $errText = ''; if (Test-Path $errE) { $errText = ([System.IO.File]::ReadAllText($errE)).Trim() }
        Check "$name local engine copy runs cleanly" ($pe.ExitCode -eq 0 -and $errText -eq '')
    }

    # =====================================================================
    Write-Host '--- multi-select install (range + list, recommended events) ---' -ForegroundColor Cyan
    $cfg4 = Join-Path $Work 'cfg4.json'; New-Config $cfg4
    $m = New-Proj 'Multi'
    # main 1 -> sub 1 -> "3-8,15,17" (eight advisory hooks incl. Cloudflare-Deploy,
    #        now the LAST individual entry; the engine is excluded from this
    #        list entirely, see the guard test below)
    #        -> mode 1 (recommended events per hook) -> client Both -> target -> done -> start -> exit
    $r = Invoke-Wizard -Config $cfg4 -Answers @('1', '1', '3-8,15,17', '1', '1', $m, 'done', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    Check 'selection accepts a range combined with a single item' ($r.Out -notmatch 'Enter number\(s\)')
    Check 'multi-hook header has a blank line before its options' ($r.Out -match 'Configuring 8 hooks:[^\r\n]*\r?\n\r?\n\s*1\.')
    $setupSource = [System.IO.File]::ReadAllText($Setup)
    Check 'multi-hook header label uses a different color from hook names' ($setupSource -match "Get-Painted \('Configuring '.*\`$C\.Input.*Get-Painted \`$selectedNames \`$C\.White")
    $installedFolders = @(Get-ChildItem -LiteralPath (Join-Path $m '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'eight distinct hooks installed in one pass' ($installedFolders.Count -eq 8)
    Check 'each installed under its own friendly folder' ($installedFolders -notcontains 'Cross-Project-.ai-Knowledge-Sync' -and (@($installedFolders | Where-Object { $_ -match '-' }).Count -eq 8))
    $codexFolders = @(Get-ChildItem -LiteralPath (Join-Path $m '.codex\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'batch honored client=Both (codex got all eight too)' ($codexFolders.Count -eq 8)
    $expectedEvents = [ordered]@{
        'Ai-Memory-Check'       = 'Stop'
        'Ai-Memory-Load'        = 'SessionStart,UserPromptSubmit'
        'Ci-Status-Check'       = 'Stop'
        'Dependabot-Check'      = 'SessionStart'
        'Github-Baseline-Check' = 'SessionStart'
        'Git-Sync-Check'        = 'SessionStart,Stop'
        'Cloudflare-Deploy'     = 'Stop'
        'Secrets-Check'         = 'SessionStart,Stop'
    }
    $recommendedEventsApplied = $true
    foreach ($entry in $expectedEvents.GetEnumerator()) {
        $expected = @($entry.Value.Split(',') | Sort-Object) -join ','
        $claudeEvents = @(Get-RegisteredEvents (Join-Path $m '.claude\settings.local.json') $entry.Key | Sort-Object) -join ','
        $codexEvents = @(Get-RegisteredEvents (Join-Path $m '.codex\hooks.json') $entry.Key | Sort-Object) -join ','
        if ($claudeEvents -ne $expected -or $codexEvents -ne $expected) { $recommendedEventsApplied = $false }
    }
    Check 'batch applies each hook recommended events in both clients' $recommendedEventsApplied
    Check 'summary lists all eight (8 event lines)' (([regex]::Matches($r.Out, 'events:')).Count -ge 8)

    # =====================================================================
    Write-Host '--- Select all hooks (aggregate menu item 1 = sync group + every hook) ---' -ForegroundColor Cyan
    $RealHooksDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
    $hookCount = @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' }).Count
    $syncX = New-Proj 'SelectAllSyncX'; $syncY = New-Proj 'SelectAllSyncY'

    $cfgAll = Join-Path $Work 'cfg-all.json'; New-Config $cfgAll
    $allProj = New-Proj 'SelectAllProj'
    # main 1 -> sub 1 -> "1" (select all: sync group + every hook) ->
    #   [sync group: syncX, syncY, done, client Both, confirm] ->
    #   [hooks: mode 1 (recommended events), client Both, target, done, confirm]
    $rAll = Invoke-Wizard -Config $cfgAll -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', '', '1', '1', $allProj, 'done', '', '0')
    Check 'exit 0' ($rAll.Exit -eq 0)
    Check 'no stderr' ($rAll.Err -eq '')
    Check 'select-all alone (no "2" typed) still runs the sync group' ($rAll.Out -match 'Running the sync group first')
    Check ('select-all configures every discovered hook (' + $hookCount + ')') ($rAll.Out -match ('Configuring ' + $hookCount + ' hooks:'))
    Check 'completion summary reports both the sync group and the resolved hook count' ($rAll.Out -match ('Sync group \+ ' + $hookCount + ' hook\(s\) installed'))
    $allFolders = @(Get-ChildItem -LiteralPath (Join-Path $allProj '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'select-all installs every discovered hook exactly once (no duplicates)' ($allFolders.Count -eq $hookCount -and @($allFolders | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0)
    Check 'select-all never installs the sync engine as a plain hook (at the hooks target)' ($allFolders -notcontains 'Cross-Project-.ai-Knowledge-Sync')
    Check 'select-all includes Cloudflare-Deploy (the last individual entry)' ($allFolders -contains 'Cloudflare-Deploy')
    $profAll = @((Get-Content $cfgAll -Raw | ConvertFrom-Json).profiles)
    Check 'select-all applies the sync-group profile exactly once' ($profAll.Count -eq 1 -and @($profAll[0].routes).Count -eq 2)
    Check 'sync group installed its engine at the sync-group targets, not the hooks target' (
        (Test-Path (Join-Path $syncX '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1')) -and
        (Test-Path (Join-Path $syncY '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1')))

    # Combining "1" (select all) with an explicit individual pick must not
    # install anything twice, and the sync group still runs exactly once.
    $cfgAllCombo = Join-Path $Work 'cfg-all-combo.json'; New-Config $cfgAllCombo
    $comboProj = New-Proj 'SelectAllCombo'
    $rCombo = Invoke-Wizard -Config $cfgAllCombo -Answers @('1', '1', '1,5', $syncX, $syncY, 'done', '1', '', '1', '1', $comboProj, 'done', '', '0')
    Check 'select-all + explicit pick still runs the sync group exactly once' ((@([regex]::Matches($rCombo.Out, 'Running the sync group first'))).Count -eq 1)
    Check 'select-all combined with an explicit pick still configures each hook exactly once' ($rCombo.Out -match ('Configuring ' + $hookCount + ' hooks:'))

    # Combining "1" with "2" (the sync group's own item) must not run the
    # sync group twice either.
    $cfgAllWith2 = Join-Path $Work 'cfg-all-with2.json'; New-Config $cfgAllWith2
    $with2Proj = New-Proj 'SelectAllWith2'
    $rWith2 = Invoke-Wizard -Config $cfgAllWith2 -Answers @('1', '1', '1,2', $syncX, $syncY, 'done', '1', '', '1', '1', $with2Proj, 'done', '', '0')
    Check 'select-all + explicit "2" still runs the sync group exactly once (no duplicate)' ((@([regex]::Matches($rWith2.Out, 'Running the sync group first'))).Count -eq 1)
    Check '"1,2" still configures every hook exactly once' ($rWith2.Out -match ('Configuring ' + $hookCount + ' hooks:'))

    # Canceling the sync-group confirmation must not install any individual
    # hook and must not claim success.
    $cfgCancel = Join-Path $Work 'cfg-all-cancel.json'; New-Config $cfgCancel
    $cancelProj = New-Proj 'SelectAllCancel'
    $rCancel = Invoke-Wizard -Config $cfgCancel -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', 'n', '0')
    Check 'exit 0 (sync-group stage canceled)' ($rCancel.Exit -eq 0)
    Check 'canceling the sync-group stage reports Canceled, not success' ($rCancel.Out -match 'Canceled\. Nothing was changed\.' -and $rCancel.Out -notmatch 'hook\(s\) installed')
    Check 'canceling the sync-group stage installs no individual hook' (-not (Test-Path (Join-Path $cancelProj '.claude')))

    # Claude-only and Codex-only client scoping still apply with Select All
    # (checked at the hooks target; the sync-group phase uses its own choice).
    $cfgAllClaude = Join-Path $Work 'cfg-all-claude.json'; New-Config $cfgAllClaude
    $claudeOnlyProj = New-Proj 'SelectAllClaude'
    $null = Invoke-Wizard -Config $cfgAllClaude -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', '', '1', '2', $claudeOnlyProj, 'done', '', '0')
    Check 'select-all honors Claude-only client scoping' ((Test-Path (Join-Path $claudeOnlyProj '.claude\settings.local.json')) -and -not (Test-Path (Join-Path $claudeOnlyProj '.codex')))

    $cfgAllCodex = Join-Path $Work 'cfg-all-codex.json'; New-Config $cfgAllCodex
    $codexOnlyProj = New-Proj 'SelectAllCodex'
    $null = Invoke-Wizard -Config $cfgAllCodex -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', '', '1', '3', $codexOnlyProj, 'done', '', '0')
    Check 'select-all honors Codex-only client scoping' ((Test-Path (Join-Path $codexOnlyProj '.codex\hooks.json')) -and -not (Test-Path (Join-Path $codexOnlyProj '.claude')))

    # Selecting the LAST individual entry (a single-hook pick, no aggregate)
    # installs Cloudflare-Deploy specifically and does NOT run the sync group.
    $cfgLast = Join-Path $Work 'cfg-last.json'; New-Config $cfgLast
    $lastProj = New-Proj 'LastEntryProj'
    $rLast = Invoke-Wizard -Config $cfgLast -Answers @('1', '1', ($hookCount + 2).ToString(), '2', '2', $lastProj, 'done', '', '0')
    Check 'selecting the last individual entry installs Cloudflare-Deploy' (Test-Path (Join-Path $lastProj '.claude\hooks\Hook-Maker\Cloudflare-Deploy\Cloudflare-Deploy.ps1'))
    Check 'selecting a single individual entry does not run the sync group' ($rLast.Out -notmatch 'Running the sync group first')

    # Reinstalling via Select All stays idempotent: same set, no duplicate
    # registrations, nothing previously installed goes missing, sync-group
    # profile is updated in place rather than duplicated.
    $rAllAgain = Invoke-Wizard -Config $cfgAll -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', '', '1', '1', $allProj, 'done', '', '0')
    Check 'exit 0 (select-all reinstall)' ($rAllAgain.Exit -eq 0)
    $allFoldersAgain = @(Get-ChildItem -LiteralPath (Join-Path $allProj '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'reinstall via select-all stays idempotent (same hook count)' ($allFoldersAgain.Count -eq $hookCount)
    Check 'reinstall preserves every previously-installed hook (none dropped or duplicated)' (((@($allFolders | Sort-Object)) -join ',') -eq ((@($allFoldersAgain | Sort-Object)) -join ','))
    $profAllAgain = @((Get-Content $cfgAll -Raw | ConvertFrom-Json).profiles)
    Check 'reinstall does not duplicate the sync-group profile' ($profAllAgain.Count -eq 1 -and $profAllAgain[0].id -eq $profAll[0].id)
    # Parse the JSON (rather than raw-text/regex match it) so JSON's own
    # backslash-escaping ("\\") can never be mistaken for a missing/duplicate
    # entry: count actual handler entries whose (decoded) command references
    # Ai-Memory-Check's runtime copy.
    $claudeSettingsAllObj = Get-Content -LiteralPath (Join-Path $allProj '.claude\settings.local.json') -Raw | ConvertFrom-Json
    $aiMemHandlerCount = 0
    foreach ($eventProp in $claudeSettingsAllObj.hooks.PSObject.Properties) {
        foreach ($group in @($eventProp.Value)) {
            foreach ($handler in @($group.hooks)) {
                if ([string]$handler.command -like '*Ai-Memory-Check\Ai-Memory-Check.ps1*') { $aiMemHandlerCount++ }
            }
        }
    }
    Check 'reinstall does not duplicate a hook''s registration' ($aiMemHandlerCount -eq 1)

    # Future-proof: a synthetic, unknown hook folder must be picked up by
    # Select All with NO code change - proves the set is derived dynamically
    # from Get-HookEntries, never a hard-coded count. Created/removed inside
    # its own try/finally so the real hooks\ directory is never left dirty.
    $syntheticName = 'ZZZ-Synthetic-Test-Hook'
    $syntheticDir = Join-Path $RealHooksDir $syntheticName
    try {
        New-Item -ItemType Directory -Path $syntheticDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $syntheticDir ($syntheticName + '.ps1')) -Value 'exit 0' -Encoding utf8
        $newHookCount = @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' }).Count
        Check 'synthetic fixture increases the discovered hook count by exactly one' ($newHookCount -eq $hookCount + 1)

        $cfgFuture = Join-Path $Work 'cfg-future.json'; New-Config $cfgFuture
        $futureProj = New-Proj 'SelectAllFuture'
        $rFuture = Invoke-Wizard -Config $cfgFuture -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', '', '1', '1', $futureProj, 'done', '', '0')
        Check 'exit 0 (with synthetic hook present)' ($rFuture.Exit -eq 0)
        Check 'select-all dynamically picks up the new hook count - no hard-coded 16' ($rFuture.Out -match ('Configuring ' + $newHookCount + ' hooks:'))
        $futureFolders = @(Get-ChildItem -LiteralPath (Join-Path $futureProj '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        Check 'select-all includes the synthetic hook without any code change' ($futureFolders -contains $syntheticName)
    }
    finally {
        if (Test-Path -LiteralPath $syntheticDir) {
            Get-ChildItem -LiteralPath $syntheticDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $syntheticDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Check 'synthetic fixture directory was cleaned up' (-not (Test-Path -LiteralPath $syntheticDir))
    }

    # =====================================================================
    Write-Host '--- an unwritable project .ai directory must not crash the wizard ---' -ForegroundColor Cyan
    # Real regression: a project whose .ai directory cannot be created
    # (permission denied / read-only location) raised a terminating
    # UnauthorizedAccessException that propagated out of Invoke-CreateGroup ->
    # Invoke-InstallExistingHook -> the main menu -> run.ps1, killing the whole
    # wizard and ejecting the user. It must instead report the failure, change
    # nothing, and return to the hook list. The denial is created with a real
    # ACL (icacls "add subdirectory" deny), matching the reported failure.
    $cfgAcl = Join-Path $Work 'cfg-acl.json'; New-Config $cfgAcl
    $aclOk = New-Proj 'AclOkProj'
    $aclBlocked = New-Proj 'AclBlockedProj'
    $aclUser = $env:USERNAME
    $aclApplied = $false
    try {
        & icacls $aclBlocked /deny "${aclUser}:(AD)" *> $null
        $aclApplied = ($LASTEXITCODE -eq 0)
        if ($aclApplied) {
            # Confirm the denial actually reproduces the reported exception.
            $aclRepro = $false
            try { New-Item -ItemType Directory -Path (Join-Path $aclBlocked '.ai') -Force -ErrorAction Stop | Out-Null }
            catch { $aclRepro = ($_.Exception -is [System.UnauthorizedAccessException]) }
            Check 'ACL fixture reproduces the reported UnauthorizedAccessException' $aclRepro

            $rAcl = Invoke-Wizard -Config $cfgAcl -Answers @('1', '1', '2', $aclOk, $aclBlocked, 'done', '1', '', '0', 'exit')
            Check 'an unwritable .ai directory does NOT crash the wizard (exit 0, no fatal)' ($rAcl.Exit -eq 0 -and $rAcl.Err -notmatch 'UnauthorizedAccessException') ($rAcl.Err)
            Check 'the failing project path is reported' ($rAcl.Out -match 'Could not create 1 knowledge' -and $rAcl.Out -match 'AclBlockedProj') $rAcl.Out
            Check 'it states nothing was changed' ($rAcl.Out -match 'Nothing was changed') $rAcl.Out
            Check 'the wizard returns to the hook list instead of exiting' ((([regex]::Matches($rAcl.Out, 'Available hooks')).Count) -ge 2) $rAcl.Out
            $profAcl = @((Get-Content $cfgAcl -Raw | ConvertFrom-Json).profiles)
            Check 'no sync profile is written when a .ai directory could not be created' ($profAcl.Count -eq 0)
        }
        else {
            Write-Host '[SKIP] icacls deny could not be applied; skipping the unwritable-.ai regression' -ForegroundColor Yellow
        }
    }
    finally {
        if ($aclApplied) { & icacls $aclBlocked /remove:d "$aclUser" *> $null }
    }

    # =====================================================================
    Write-Host '--- repeated project prompts + confirmation back navigation ---' -ForegroundColor Cyan
    $cfgBack = Join-Path $Work 'cfg-back.json'; New-Config $cfgBack
    $backA = New-Proj 'BackA'; $backB = New-Proj 'BackB'
    # Configure two hooks with shared targets, back from confirmation, then
    # enter done immediately: existing targets must still be present.
    $rBack = Invoke-Wizard -Config $cfgBack -Answers @('1', '1', '3,4', '1', '1', $backA, $backB, 'done', '0', 'done', 'exit')
    # Repeated child prompts inside ONE parent question use hierarchical
    # "<parent>-<slot>" numbering (e.g. "12-1.", "12-2.") - they must NOT each
    # steal a fresh top-level integer (the confirmed bug this replaces).
    $nestedPromptMatches = @([regex]::Matches($rBack.Out, '(?m)^(\d+)-(\d+)\. Project root path'))
    Check 'repeated project prompts use hierarchical <parent>-<slot> numbering, not fresh top-level integers' (
        $nestedPromptMatches.Count -ge 2 -and
        $nestedPromptMatches[0].Groups[1].Value -eq $nestedPromptMatches[1].Groups[1].Value -and
        $nestedPromptMatches[0].Groups[2].Value -eq '1' -and $nestedPromptMatches[1].Groups[2].Value -eq '2')
    Check 'no repeated project prompt appears as a bare top-level integer' (-not ($rBack.Out -match '(?m)^\d+\. Project root path'))
    Check 'confirmation back returns to project entry instead of the hook list' (([regex]::Matches($rBack.Out, 'Add Projects')).Count -eq 2 -and ([regex]::Matches($rBack.Out, 'Available hooks')).Count -eq 1)
    Check 'confirmation back preserves the existing project list' (([regex]::Matches($rBack.Out, 'projects: BackA, BackB')).Count -eq 4)

    # =====================================================================
    Write-Host '--- hierarchical numbering: invalid/duplicate/overlap/undo retain the correct slot ---' -ForegroundColor Cyan
    $cfgSlots = Join-Path $Work 'cfg-slots.json'; New-Config $cfgSlots
    $slotA = New-Proj 'Slot A With Spaces'
    $slotB = New-Proj 'SlotB'
    $missingPath = Join-Path $Work 'does-not-exist-anywhere'
    $overlapChild = Join-Path $slotA 'nested'
    New-Item -ItemType Directory -Path $overlapChild -Force | Out-Null
    $rSlots = Invoke-Wizard -Config $cfgSlots -Answers @(
        '1', '1', '3', '1', '1',
        $slotA,             # slot 1 accepted
        $missingPath,       # invalid (missing dir) -> re-shows slot 2
        $slotA,              # duplicate -> re-shows slot 2
        $overlapChild,       # overlaps slotA -> re-shows slot 2
        $slotB,             # slot 2 accepted
        'undo',             # removes slotB -> back to slot 2
        $slotB,             # slot 2 accepted again
        'done', 'y', 'exit'
    )
    $slotMatches = @([regex]::Matches($rSlots.Out, '(?m)^(\d+)-(\d+)\. Project root path'))
    $slotNumbers = @($slotMatches | ForEach-Object { [int]$_.Groups[2].Value })
    Check 'invalid/duplicate/overlap all re-display the SAME child slot (2) instead of advancing' (
        $slotNumbers.Count -ge 6 -and
        $slotNumbers[0] -eq 1 -and $slotNumbers[1] -eq 2 -and $slotNumbers[2] -eq 2 -and $slotNumbers[3] -eq 2 -and $slotNumbers[4] -eq 2)
    # slotNumbers[5] is "3" - the prompt shown BEFORE the 'undo' answer is read
    # (childNumber had already advanced past the just-accepted slotB). The
    # prompt shown AFTER undo processes (slotNumbers[6]) is what proves the
    # slot stepped back to 2 instead of continuing at 3.
    Check 'undo steps the slot counter back (re-shows slot 2, not 3)' ($slotNumbers.Count -ge 7 -and $slotNumbers[6] -eq 2) ($slotNumbers -join ',')
    Check 'a project path containing spaces is accepted' ($rSlots.Out -match [regex]::Escape('Slot A With Spaces'))
    Check 'the missing directory is rejected without being added' ($rSlots.Out -match 'Directory not found')
    Check 'the duplicate path is rejected without being added' ($rSlots.Out -match 'Already added')
    Check 'the overlapping nested path is rejected without being added' ($rSlots.Out -match 'Path overlaps an already added project')

    # =====================================================================
    Write-Host '--- hierarchical numbering: back=0 and subsequent top-level numbering stay correct ---' -ForegroundColor Cyan
    $cfgAfter = Join-Path $Work 'cfg-after-nested.json'; New-Config $cfgAfter
    $afterA = New-Proj 'AfterA'; $afterB = New-Proj 'AfterB'
    $rAfter = Invoke-Wizard -Config $cfgAfter -Answers @('1', '1', '3', '1', '1', '0', '1', $afterA, $afterB, 'done', 'y', 'exit')
    Check 'back=0 from the first child slot returns to the correct parent stage (client select)' (([regex]::Matches($rAfter.Out, 'Select the client')).Count -eq 2)
    $afterConfirmMatches = @([regex]::Matches($rAfter.Out, '(?m)^(\d+)\. Start now\?'))
    Check 'genuine top-level numbering after the nested collection is unaffected (still a plain integer, not <n>-<n>)' ($afterConfirmMatches.Count -ge 1)

    # =====================================================================
    Write-Host '--- multi-select: sync group (1) combined with a hook runs both, once ---' -ForegroundColor Cyan
    $cfg5 = Join-Path $Work 'cfg5.json'; New-Config $cfg5
    $c = New-Proj 'ComboC'; $d = New-Proj 'ComboD'; $e = New-Proj 'ComboE'
    # main 1 -> sub 1 -> "2,3" (sync group + Ai-Memory-Check) ->
    #   [sync group wizard: C, D, done, client Both, confirm] ->
    #   [single-hook config: events SessionStart+UPS, client Both, target E, done, confirm] -> exit
    $r2 = Invoke-Wizard -Config $cfg5 -Answers @('1', '1', '2,3', $c, $d, 'done', '1', '', '1', '1', $e, 'done', '', '0')
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
    $r3 = Invoke-Wizard -Config $cfg6 -Answers @('1', '1', '2', $f, $g, 'done', '1', '', '0')
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
