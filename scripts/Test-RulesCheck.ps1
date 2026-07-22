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

function New-PromptStdin {
    param([string]$Cwd, [string]$Prompt, [string]$SessionId = 't')
    return @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = 'UserPromptSubmit'; prompt = $Prompt } | ConvertTo-Json
}

# Parses hookSpecificOutput.additionalContext out of a hook's raw JSON stdout;
# '' when the output is empty or not the expected shape.
function Get-AdditionalContext {
    param([string]$RawOut)
    try {
        $doc = $RawOut | ConvertFrom-Json
        if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['hookSpecificOutput']) {
            return [string]$doc.hookSpecificOutput.additionalContext
        }
    }
    catch { }
    return ''
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

    # =====================================================================
    Write-Host '--- E-01: canonical rule routing + UTF-8 guidance (claude) ---' -ForegroundColor Cyan
    $projE1 = Join-Path $Work 'projE1'; New-Item -ItemType Directory -Path $projE1 -Force | Out-Null
    $r = Fire -Cwd $projE1
    Check 'first-run note names the canonical rule set by canonical installed names' (
        $r.Out -like '*custom-instructions.md*' -and $r.Out -like '*WORKFLOWS.md*' -and $r.Out -like '*CODEWORDS.md*' -and
        $r.Out -like '*ai-context-memory-policy.md*' -and $r.Out -like '*global-hook-rules.md*' -and
        $r.Out -like '*global-test-rules.md*' -and $r.Out -like '*global-github-automation-rules.md*') $r.Out
    Check 'conditional rules stay conditional (MCP work / codebase navigation only)' (
        $r.Out -like '*global-mcp-rules.md only when MCP work applies*' -and
        $r.Out -like '*graphify.md only when codebase navigation applies*') $r.Out
    Check 'claude loads EXACTLY skill-policy.md and never references the codex policy' (
        $r.Out -match 'load ONLY skill-policy\.md' -and $r.Out -match 'never both together' -and $r.Out -notmatch 'codex') $r.Out
    Check 'the note warns against uploaded/version-suffixed filenames like "(17)"' (
        $r.Out -like '*version-suffixed*' -and $r.Out -like '*custom-instructions (17).md*') $r.Out
    Check 'UTF-8 guidance: strict default, distrust OS/shell/runtime defaults' (
        $r.Out -like '*STRICT UTF-8*' -and $r.Out -like '*never trust OS/shell/runtime default encodings*') $r.Out
    Check 'UTF-8 guidance: BOM and no-BOM are both UTF-8; BOM is a separate compatibility decision' (
        $r.Out -like '*with a BOM and without a BOM are both valid UTF-8*' -and $r.Out -like '*separate compatibility decision*') $r.Out
    Check 'UTF-8 guidance: exception = narrow scope + exact encoding + reason + forcing system + verification' (
        $r.Out -like '*narrow path/scope*' -and $r.Out -like '*exact encoding*' -and $r.Out -like '*technical reason*' -and
        $r.Out -like '*forcing system*' -and $r.Out -like '*compatibility verification*') $r.Out
    # A real uploaded-style copy in the rules dir is flagged, not trusted.
    New-RuleFile $globalClaude 'custom-instructions (17).md'
    $r = Fire -Cwd $projE1
    Check 'a version-suffixed rule FILE on disk is flagged as non-canonical' (
        $r.Out -like '*NEW:*custom-instructions (17).md*' -and $r.Out -like '*WARNING - version-suffixed*') $r.Out
    Remove-Item (Join-Path $globalClaude 'custom-instructions (17).md') -Force
    $r = Fire -Cwd $projE1
    Check 'removing the uploaded copy clears the warning (REMOVED reported, no WARNING)' (
        $r.Out -like '*REMOVED:*custom-instructions (17).md*' -and $r.Out -notlike '*WARNING - version-suffixed*') $r.Out

    # =====================================================================
    Write-Host '--- E-01: canonical rule routing (codex) ---' -ForegroundColor Cyan
    $projE1x = Join-Path $Work 'projE1x'; New-Item -ItemType Directory -Path $projE1x -Force | Out-Null
    $r = Fire -Cwd $projE1x -Claude $false
    Check 'codex loads EXACTLY skill-policy-codex-optimized.md and never the claude policy' (
        $r.Out -match 'load ONLY skill-policy-codex-optimized\.md' -and $r.Out -match 'never both together' -and
        $r.Out -notmatch 'skill-policy\.md') $r.Out

    # =====================================================================
    Write-Host '--- E-01: ::deep-debug codeword gating + guidance ---' -ForegroundColor Cyan
    $projDD = Join-Path $Work 'projDD'; New-Item -ItemType Directory -Path $projDD -Force | Out-Null
    $null = Fire -Cwd $projDD   # consume the first-run baseline report
    $r = Fire -Cwd $projDD -RawStdin (New-PromptStdin -Cwd $projDD -Prompt 'let us deep debug the login flow and deep-debug some more' -SessionId 'dd-s1')
    Check 'ordinary prose "deep debug" does NOT activate the codeword path' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $projDD -RawStdin (New-PromptStdin -Cwd $projDD -Prompt 'run ::deep-debug on the parser' -SessionId 'dd-s1')
    Check 'a standalone ::deep-debug DOES emit the bounded-workflow guidance' (
        $r.Out -like '*::deep-debug is a BOUNDED composite workflow*' -and
        $r.Out -like '*DEEP DEBUG: COMPLETE or DEEP DEBUG: BLOCKED*' -and
        $r.Out -like '*never an endless audit/refactor/fix loop*') $r.Out
    Check 'guidance keeps /goal NATIVE (never shadowed/aliased/codeworded/synthesized)' (
        $r.Out -like '*/goal is a NATIVE command*' -and
        $r.Out -like '*never shadowed, aliased, converted into a codeword, or synthetically executed by a hook*') $r.Out
    Check 'guidance frames ::multi-agent as ONE integration + final verification' (
        $r.Out -like '*::multi-agent is a workflow dependency*' -and $r.Out -like '*ONE integration*' -and
        $r.Out -like '*final verification on the unified tree*' -and $r.Out -like '*no nested agent trees*') $r.Out
    Check 'guidance: Ponytail (native /ponytail:ponytail-audit) runs exactly ONCE after all verification' (
        $r.Out -like '*/ponytail:ponytail-audit*' -and $r.Out -like '*exactly ONCE*' -and
        $r.Out -like '*integrated verification have completed*') $r.Out
    Check 'guidance: after Ponytail never a new audit/refactor/debug cycle' (
        $r.Out -like '*only safe accepted simplifications*' -and $r.Out -like '*never a new audit/refactor/debug cycle*') $r.Out
    $r2 = Fire -Cwd $projDD -RawStdin (New-PromptStdin -Cwd $projDD -Prompt '::deep-debug again please' -SessionId 'dd-s1')
    Check 'repeated unchanged ::deep-debug guidance is fingerprint-suppressed in the SAME session' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r3 = Fire -Cwd $projDD -RawStdin (New-PromptStdin -Cwd $projDD -Prompt '::deep-debug' -SessionId 'dd-s2')
    Check 'a NEW session re-reports the ::deep-debug guidance' ($r3.Out -like '*BOUNDED composite workflow*') $r3.Out
    (Get-Item (Join-Path $globalClaude 'alpha.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(15)
    $r4 = Fire -Cwd $projDD -RawStdin (New-PromptStdin -Cwd $projDD -Prompt '::deep-debug' -SessionId 'dd-s2')
    Check 'changed rule state still re-reports while consumed dd guidance stays suppressed' (
        $r4.Out -like '*CHANGED:*alpha.md*' -and $r4.Out -notlike '*BOUNDED composite workflow*') $r4.Out
    # Codex shape: same graph bounds, client-native command references only.
    $projDDx = Join-Path $Work 'projDDx'; New-Item -ItemType Directory -Path $projDDx -Force | Out-Null
    $null = Fire -Cwd $projDDx -Claude $false   # consume the codex first-run baseline
    $r = Fire -Cwd $projDDx -Claude $false -RawStdin (New-PromptStdin -Cwd $projDDx -Prompt '::deep-debug' -SessionId 'ddx-s1')
    Check 'codex ::deep-debug guidance uses client-native references, not Claude slash literals' (
        $r.Out -like '*BOUNDED composite workflow*' -and $r.Out -like '*client-native goal command*' -and
        $r.Out -like '*ponytail-audit capability*' -and $r.Out -notlike '*/ponytail:ponytail-audit*' -and
        $r.Out -notlike '*/goal*') $r.Out

    # =====================================================================
    Write-Host '--- E-01: static safety + installed-runtime parity ---' -ForegroundColor Cyan
    # The hook only REFERENCES native commands as text; it must never gain an
    # execution path (same static assertion style as the Test-Run-Guard suite).
    $hookText = [System.IO.File]::ReadAllText($Hook)
    Check 'hook source has NO execution primitives (Start-Process/Invoke-Expression/iex/call operator on data)' (
        $hookText -notmatch 'Start-Process' -and $hookText -notmatch 'Invoke-Expression' -and
        $hookText -notmatch '(?i)\biex\b' -and $hookText -notmatch '&\s*\$') $hookText.Substring(0, 200)
    Check 'native /goal and /ponytail:ponytail-audit appear in source as referenced text' (
        $hookText -like '*/goal*' -and $hookText -like '*/ponytail:ponytail-audit*')
    # Installed-runtime parity: the runtime copy installed above must produce
    # byte-identical ::deep-debug guidance to the source hook (same client,
    # same prompt, fresh per-project state for each).
    $runtimeCopy = Join-Path $tgtC '.claude\hooks\Hook-Maker\Rules-Check\Rules-Check.ps1'
    $parityA = Join-Path $Work 'parityA'; New-Item -ItemType Directory -Path $parityA -Force | Out-Null
    $parityB = Join-Path $Work 'parityB'; New-Item -ItemType Directory -Path $parityB -Force | Out-Null
    $null = Fire -Cwd $parityA
    $null = Fire -Cwd $parityB -HookPath $runtimeCopy
    $rSrc = Fire -Cwd $parityA -RawStdin (New-PromptStdin -Cwd $parityA -Prompt '::deep-debug' -SessionId 'par-1')
    $rCopy = Fire -Cwd $parityB -HookPath $runtimeCopy -RawStdin (New-PromptStdin -Cwd $parityB -Prompt '::deep-debug' -SessionId 'par-1')
    $srcCtx = Get-AdditionalContext $rSrc.Out
    $copyCtx = Get-AdditionalContext $rCopy.Out
    Check 'installed runtime copy emits IDENTICAL ::deep-debug guidance to the source hook' (
        $srcCtx -ne '' -and $srcCtx -eq $copyCtx) ('src=[' + $srcCtx + '] copy=[' + $copyCtx + ']')
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
