# Smoke test for the RulesCheck hook and for the per-client install targeting
# of Install-Hook.ps1 (-ClaudeOnly / -CodexOnly / default both).
#
# Fully offline. The hook's environment is isolated per call: USERPROFILE
# points at a fake home (global rules dirs), LOCALAPPDATA at a throwaway state
# dir, and CLAUDE_PROJECT_DIR is explicitly set or removed to simulate the
# Claude vs Codex client (Claude Code exports it on hook processes, Codex does
# not). Payloads are delivered through a real stdin file handle (see
# Test-Engine.ps1 for why pipes are not used).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-RulesCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$Hook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Rules-Check\Rules-Check.ps1'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
foreach ($required in @($Hook, $InstallScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 300
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-rulestest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$FakeHome = Join-Path $Work 'home'
$FakeAppData = Join-Path $Work 'appdata'
New-Item -ItemType Directory -Path $Work, $FakeHome, $FakeAppData -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedUserProfile = $env:USERPROFILE
$SavedLocalAppData = $env:LOCALAPPDATA
$SavedClaudeDir = $env:CLAUDE_PROJECT_DIR
# Isolates Install-Hook.ps1's install registry away from this real checkout's
# own registry for every in-process & $InstallScript call below.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$env:HOOKMAKER_STATE_DIR = Join-Path $Work 'state'

# ---- helpers ----
function Fire {
    # $RawStdin intentionally UNTYPED: [string] coerces $null to '' (see LESSON.md).
    param([string]$Cwd, [bool]$Claude = $true, [string]$EventName = 'SessionStart', $RawStdin = $null, [string]$HookArgs = '', [string]$HookPath = $Hook, [string]$Exe = 'pwsh')
    $payload = $RawStdin
    if ($null -eq $payload) {
        $payload = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName } | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') {
        $file = (Get-Process -Id $PID).Path
        $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'
        $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    if ($HookArgs -ne '') { $argLine += ' ' + $HookArgs }
    # Simulated client + isolated home/state, inherited by the child process.
    $env:USERPROFILE = $FakeHome
    $env:LOCALAPPDATA = $FakeAppData
    if ($Claude) { $env:CLAUDE_PROJECT_DIR = $Cwd } else { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    try {
        $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    }
    finally {
        $env:USERPROFILE = $SavedUserProfile
        $env:LOCALAPPDATA = $SavedLocalAppData
        if ($null -ne $SavedClaudeDir) { $env:CLAUDE_PROJECT_DIR = $SavedClaudeDir } else { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
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

function New-RuleFile {
    param([string]$Dir, [string]$Name, [string]$Content = 'rule body')
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText((Join-Path $Dir $Name), $Content)
}

try {
    # =====================================================================
    Write-Host '--- input handling ---' -ForegroundColor Cyan
    $proj1 = Join-Path $Work 'proj1'; New-Item -ItemType Directory -Path $proj1 -Force | Out-Null
    $r = Fire -Cwd $proj1 -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $proj1 -RawStdin 'not json'
    Check 'garbage stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $proj1 -EventName 'Stop'
    Check 'Stop event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- claude: first run, silence, and change detection ---' -ForegroundColor Cyan
    $r = Fire -Cwd $proj1
    Check 'no rules dirs -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'no rules dirs -> no state written' (-not (Test-Path (Join-Path $FakeAppData 'HookMaker\state')))

    $globalClaude = Join-Path $FakeHome '.claude\rules'
    New-RuleFile $globalClaude 'alpha.md'
    New-RuleFile $globalClaude 'beta.md'
    $r = Fire -Cwd $proj1
    Check 'first run -> reports all global rules' ($r.Out -like '*RULES CHECK (claude)*first check*alpha.md*beta.md*') $r.Out
    # JSON output escapes backslashes, so match on the dir with doubled slashes.
    Check 'first run -> names the global dir' ($r.Out -like ('*Global rules (' + $globalClaude.Replace('\', '\\') + ')*')) $r.Out
    $r = Fire -Cwd $proj1
    Check 'unchanged -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $proj1 -EventName 'UserPromptSubmit'
    Check 'unchanged (UserPromptSubmit) -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    New-RuleFile $globalClaude 'gamma.md'
    $r = Fire -Cwd $proj1
    Check 'added file -> NEW reported once' ($r.Out -like '*NEW:*gamma.md*' -and $r.Out -like '*FULL rule set*') $r.Out
    $r = Fire -Cwd $proj1
    Check 'after NEW acknowledged -> silent' ($r.Out -eq '') $r.Out

    (Get-Item (Join-Path $globalClaude 'alpha.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)
    $r = Fire -Cwd $proj1
    Check 'touched file -> CHANGED reported' ($r.Out -like '*CHANGED:*alpha.md*') $r.Out

    $projRules = Join-Path $proj1 '.claude\rules'
    New-RuleFile $projRules 'local.md'
    $r = Fire -Cwd $proj1
    Check 'project rules dir -> NEW + Project rules section' ($r.Out -like '*NEW:*local.md*' -and $r.Out -like '*Project rules*') $r.Out

    Remove-Item (Join-Path $globalClaude 'beta.md') -Force
    $r = Fire -Cwd $proj1
    Check 'deleted file -> REMOVED reported' ($r.Out -like '*REMOVED:*beta.md*') $r.Out
    $r = Fire -Cwd $proj1
    Check 'stable again -> silent' ($r.Out -eq '') $r.Out

    # State is per project: a second project gets its own first-run report.
    $proj2 = Join-Path $Work 'proj2'; New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
    $r = Fire -Cwd $proj2
    Check 'second project -> its own first-run report' ($r.Out -like '*first check*alpha.md*') $r.Out

    # =====================================================================
    Write-Host '--- codex client ---' -ForegroundColor Cyan
    $r = Fire -Cwd $proj1 -Claude $false
    Check 'codex with no .codex rules -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $globalCodex = Join-Path $FakeHome '.codex\rules'
    New-RuleFile $globalCodex 'codex-rule.md'
    $r = Fire -Cwd $proj1 -Claude $false
    Check 'codex first run -> reports codex rules only' ($r.Out -like '*RULES CHECK (codex)*codex-rule.md*' -and $r.Out -notlike '*alpha.md*') $r.Out
    $r = Fire -Cwd $proj1
    Check 'codex state does not disturb claude state' ($r.Out -eq '') $r.Out
    $r = Fire -Cwd $proj2 -Claude $true -HookArgs '-Client codex'
    Check 'explicit -Client codex overrides detection' ($r.Out -like '*RULES CHECK (codex)*codex-rule.md*') $r.Out

    # =====================================================================
    Write-Host '--- .env GLOBAL_RULES_DIR override + 5.1 host ---' -ForegroundColor Cyan
    # Copy the hook so the test's .env never touches the real hook folder.
    # The hook dot-sources ..\_hooklib.ps1, so place the lib one level up.
    $hookCopyDir = Join-Path $Work 'hookcopy'
    New-Item -ItemType Directory -Path $hookCopyDir -Force | Out-Null
    Copy-Item $Hook (Join-Path $hookCopyDir 'Rules-Check.ps1')
    Copy-Item (Join-Path (Split-Path -Parent $Hook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1')
    $customRules = Join-Path $Work 'customrules'
    New-RuleFile $customRules 'special.md'
    [System.IO.File]::WriteAllText((Join-Path $hookCopyDir '.env'), "GLOBAL_RULES_DIR=$customRules`r`n")
    $proj3 = Join-Path $Work 'proj3'; New-Item -ItemType Directory -Path $proj3 -Force | Out-Null
    $r = Fire -Cwd $proj3 -HookPath (Join-Path $hookCopyDir 'Rules-Check.ps1')
    Check '.env GLOBAL_RULES_DIR override is used' ($r.Out -like '*special.md*' -and $r.Out -notlike '*alpha.md*') $r.Out

    $proj4 = Join-Path $Work 'proj4'; New-Item -ItemType Directory -Path $proj4 -Force | Out-Null
    $r = Fire -Cwd $proj4 -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 host works' ($r.Out -like '*RULES CHECK (claude)*alpha.md*') $r.Out

    # =====================================================================
    Write-Host '--- Install-Hook.ps1 client targeting ---' -ForegroundColor Cyan
    $tgtA = Join-Path $Work 'tgt-claude'; New-Item -ItemType Directory -Path $tgtA -Force | Out-Null
    & $InstallScript -CustomHook $Hook -Events @('SessionStart') -TargetProject $tgtA -ClaudeOnly *> $null
    Check '-ClaudeOnly -> settings.local.json written' (Test-Path (Join-Path $tgtA '.claude\settings.local.json'))
    Check '-ClaudeOnly -> no codex hooks.json' (-not (Test-Path (Join-Path $tgtA '.codex\hooks.json')))

    $tgtB = Join-Path $Work 'tgt-codex'; New-Item -ItemType Directory -Path $tgtB -Force | Out-Null
    & $InstallScript -CustomHook $Hook -Events @('SessionStart') -TargetProject $tgtB -CodexOnly *> $null
    Check '-CodexOnly -> codex hooks.json written' (Test-Path (Join-Path $tgtB '.codex\hooks.json'))
    Check '-CodexOnly -> no claude settings' (-not (Test-Path (Join-Path $tgtB '.claude\settings.local.json')))

    $tgtC = Join-Path $Work 'tgt-both'; New-Item -ItemType Directory -Path $tgtC -Force | Out-Null
    & $InstallScript -CustomHook $Hook -Events @('SessionStart') -TargetProject $tgtC *> $null
    $claudeJson = ''
    if (Test-Path (Join-Path $tgtC '.claude\settings.local.json')) { $claudeJson = [System.IO.File]::ReadAllText((Join-Path $tgtC '.claude\settings.local.json')) }
    Check 'default -> both clients written' ($claudeJson -ne '' -and (Test-Path (Join-Path $tgtC '.codex\hooks.json')))
    Check 'installed command points at Rules-Check' ($claudeJson -like '*Rules-Check.ps1*')
    # The copy folder + script use the friendly hyphenated name (Rules-Check).
    Check 'install is self-contained (local runtime copy)' (($claudeJson -like '*hooks\\Hook-Maker\\Rules-Check\\Rules-Check.ps1*') -and (Test-Path (Join-Path $tgtC '.claude\hooks\Hook-Maker\Rules-Check\Rules-Check.ps1')) -and (Test-Path (Join-Path $tgtC '.claude\hooks\Hook-Maker\Rules-Check\_hooklib.ps1')))
    # Re-install must REPLACE the old registration, not duplicate it.
    & $InstallScript -CustomHook $Hook -Events @('SessionStart') -TargetProject $tgtC *> $null
    $claudeJson2 = [System.IO.File]::ReadAllText((Join-Path $tgtC '.claude\settings.local.json'))
    $occurrences = ([regex]::Matches($claudeJson2, 'Rules-Check\.ps1')).Count
    Check 're-install replaces instead of duplicating' ($occurrences -eq 1)
    # The runtime copy must run standalone: fire it with a rules dir present.
    New-RuleFile (Join-Path $FakeHome '.claude\rules') 'copyrun.md'
    $tgtProj = Join-Path $Work 'tgt-run'; New-Item -ItemType Directory -Path $tgtProj -Force | Out-Null
    $r = Fire -Cwd $tgtProj -HookPath (Join-Path $tgtC '.claude\hooks\Hook-Maker\Rules-Check\Rules-Check.ps1')
    Check 'runtime copy runs standalone (dot-source resolves)' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*copyrun.md*') $r.Out

    # Migration and ownership proof.
    #
    # A registration using the historical TOOL-FOLDER layout
    # (<toolRoot>\hooks\<Name>\<Name>.ps1) is only claimed when the path is
    # rooted under a tool root Hook Maker can PROVE is its own - this
    # installation, or one recorded by an earlier install in the registry.
    # An identical-looking path somewhere else belongs to somebody else and is
    # preserved, because that shape alone is not evidence of ownership.
    $tgtMig = Join-Path $Work 'tgt-mig'; New-Item -ItemType Directory -Path (Join-Path $tgtMig '.claude') -Force | Out-Null
    $provenLegacy = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Rules-Check\Rules-Check.ps1') + '"'
    $foreignLegacy = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "D:\SomeoneElsesProject\hooks\Rules-Check\Rules-Check.ps1"'
    $legacyJson = @{ hooks = @{ SessionStart = @(@{ matcher = 'startup|resume|clear|compact'; hooks = @(
        @{ type = 'command'; command = $provenLegacy; timeout = 60 },
        @{ type = 'command'; command = $foreignLegacy; timeout = 60 }) }) } } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $tgtMig '.claude\settings.local.json'), $legacyJson, (New-Object System.Text.UTF8Encoding $false))
    & $InstallScript -CustomHook $Hook -Events @('SessionStart') -TargetProject $tgtMig -ClaudeOnly *> $null
    $migJson = [System.IO.File]::ReadAllText((Join-Path $tgtMig '.claude\settings.local.json'))
    Check 'a PROVEN old tool-folder registration is pruned on migration' ($migJson -notmatch [regex]::Escape((Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Rules-Check\Rules-Check.ps1')))
    Check 'an unprovable same-shape registration is PRESERVED, not deleted' ($migJson -like '*SomeoneElsesProject*')
    Check 'the new self-contained registration is present exactly once' (([regex]::Matches($migJson, 'Hook-Maker')).Count -eq 1)
}
finally {
    $env:USERPROFILE = $SavedUserProfile
    $env:LOCALAPPDATA = $SavedLocalAppData
    if ($null -ne $SavedClaudeDir) { $env:CLAUDE_PROJECT_DIR = $SavedClaudeDir } else { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
