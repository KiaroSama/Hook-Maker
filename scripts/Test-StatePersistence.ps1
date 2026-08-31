# Offline REGRESSION SUITE proving the install registry (state\install-registry.json)
# is REAL persistent state - not an in-memory convenience - and the single source
# of truth for "what is installed", never the hooks\ folder (which only lists what
# is AVAILABLE to install).
#
# Every load-bearing step below runs as a SEPARATELY SPAWNED PowerShell process
# (Start-Process ... -Wait), matching Install-Hook.ps1's/Uninstall-Hook.ps1's own
# documented caveat that they read $HOME/env once at process start: an in-process
# `& $Script` call (or worse, a bare JSON round-trip in this same session) proves
# nothing about surviving a real process boundary. Covers:
#   - the canonical default registry path (<ToolRoot>\state\install-registry.json)
#     when HOOKMAKER_STATE_DIR is unset, proven WITHOUT touching this checkout's
#     real state\ directory;
#   - a corrupt registry is quarantined byte-for-byte and rebuilt, never silently
#     replaced (driving the EXISTING Update-InstallRegistry/Move-CorruptInstallRegistry
#     behavior via a real spawned install, not reimplementing it);
#   - full lifecycle: Process A installs a STANDALONE custom hook (its source
#     lives outside hooks\, so friendly-name-based reconstruction of the source
#     path is IMPOSSIBLE - only the persisted `sourceScript` field can locate it)
#     -> Process A exits -> Process B (a fresh process) loads the registry back
#     and proves the exact record survived (source path, hookType, scope/target,
#     per-client events, settings paths, runtime scripts) -> the source is edited
#     -> Process B updates via the wizard's real "Update previously installed
#     hooks" action, which must resolve the source through the PERSISTED path ->
#     Process B exits -> Process C uninstalls by the PERSISTED record id and
#     proves the record and only its own artifacts are gone;
#   - the source hook file is hashed at each boundary and never mutated by
#     install/update/uninstall - only ever read from;
#   - no second tracking database/catalog file appears anywhere in the cycle;
#   - the registry never stores a neighbouring .env secret;
#   - native Git managed metadata (nativeGit.*) persists across a process
#     boundary too, for the one hook type that has it.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-StatePersistence.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$UninstallScript = Join-Path $ScriptRoot 'Uninstall-Hook.ps1'
$SetupScript = Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($InstallScript, $UninstallScript, $SetupScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Same load order every other suite in this project uses: hooks\_hooklib.ps1
# first (Get-ShortHash, Read-JsonFile, Write-JsonFileAtomic, Set-ObjectProperty),
# then _installplan.ps1, then _installlib.ps1 (which itself dot-sources
# _installregistry.ps1). Used here ONLY for read-only verification helpers
# (Get-InstallRegistryPath, Read-InstallRegistry, Get-ClientSubrecord) - every
# actual install/update/uninstall MUTATION below goes through a spawned process.
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-statepersist'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Test-BytesEqual { param([byte[]]$A, [byte[]]$B) return [System.Linq.Enumerable]::SequenceEqual([byte[]]$A, [byte[]]$B) }
$HostExecutable = (Get-Process -Id $PID).Path

# Isolates every spawned process below from this real checkout's own
# state\install-registry.json. Only the STATE DIRECTORY is overridden - $ToolRoot
# stays the real checkout (matching every other suite), so the code under test
# is the real code, only its state file is redirected.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

$SafeCwd = Join-Path $Work 'safe-cwd'
New-Item -ItemType Directory -Path $SafeCwd -Force | Out-Null

function New-Config {
    param([string]$Path)
    '{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[]}' | Set-Content -LiteralPath $Path -Encoding utf8
}

# ---- Process A / Process C: spawn Install-Hook.ps1 / Uninstall-Hook.ps1 as a
# REAL OS process (Start-Process, not `&`) - each reads $HOME/env once at start,
# same caveat Install-Hook.ps1 itself documents, and neither shares memory with
# this orchestrator or with any other spawned process below.
function Invoke-InstallProcess {
    param([string[]]$ScriptArgs, [string]$StateDir = $IsolatedStateDir)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "instout-$token.txt"; $errF = Join-Path $Work "insterr-$token.txt"
    $quoted = $ScriptArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $argLine = '-NoLogo -NoProfile -File "' + $InstallScript + '" ' + ($quoted -join ' ')
    $startArgs = @{
        FilePath = $HostExecutable; ArgumentList = $argLine
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $StateDir }
    }
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err }
}

function Invoke-UninstallProcess {
    param([string]$RecordId)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "uninstout-$token.txt"; $errF = Join-Path $Work "uninsterr-$token.txt"
    $resultFile = Join-Path $Work "uninstresult-$token.json"
    $argLine = '-NoLogo -NoProfile -File "' + $UninstallScript + '" -RecordId "' + $RecordId + '" -ToolRoot "' + $ToolRoot + '" -ResultPath "' + $resultFile + '"'
    $startArgs = @{
        FilePath = $HostExecutable; ArgumentList = $argLine
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-Process @startArgs
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    $doc = $null
    if (Test-Path -LiteralPath $resultFile) { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json }
    return [pscustomobject]@{ Exit = $p.ExitCode; Err = $err; Result = $doc }
}

# Process B (update): spawns Setup-SyncGroup.ps1's real wizard, driving its
# actual "Update previously installed hooks" action via scripted stdin - the
# SAME production code path the task requires (Invoke-UpdateInstalledHooks
# resolves the source through the record's persisted `sourceScript`, never a
# name-rebuilt guess). Mirrors Test-InstallRegistry.ps1's proven Invoke-Wizard.
function Invoke-Wizard {
    param([string[]]$Answers, [string]$Config)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "wizin-$token.txt"; $outF = Join-Path $Work "wizout-$token.txt"; $errF = Join-Path $Work "wizerr-$token.txt"
    [System.IO.File]::WriteAllText($inF, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    $argLine = '-NoLogo -NoProfile -File "' + $SetupScript + '" -ConfigPath "' + $Config + '"'
    $startArgs = @{
        FilePath = $HostExecutable; ArgumentList = $argLine; RedirectStandardInput = $inF
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        # The updater's legacy scan inspects (Get-Location)'s .claude/.codex as
        # one scope - WorkingDirectory MUST be an isolated dir with none of its
        # own, never this real checkout's own directory.
        WorkingDirectory = $SafeCwd
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\x1b\[[0-9;]*m", ''); Err = $err }
}

# Process B (load state): a tiny harness generated once into the TEMP workspace
# (never into the repo - it is a disposable test artifact, exactly like the
# input/output files every other suite writes into $Work), then spawned as its
# own OS process so "loading the state" genuinely happens somewhere that never
# shared memory with whatever installed/updated/uninstalled it. It dumps only
# the fields this suite asserts on - never secrets, file contents or stdin.
$DumpHarness = Join-Path $Work 'dump-state.ps1'
Write-Utf8 $DumpHarness @'
param(
    [Parameter(Mandatory = $true)][string]$ToolRoot,
    [Parameter(Mandatory = $true)][string]$FriendlyName,
    [string]$TargetProjectRoot = '',
    [Parameter(Mandatory = $true)][string]$ResultPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
. (Join-Path $ToolRoot 'scripts\_installplan.ps1')
. (Join-Path $ToolRoot 'scripts\_installlib.ps1')

$registry = Read-InstallRegistry -ToolRoot $ToolRoot
$found = @($registry.installs | Where-Object {
    [string]$_.friendlyName -eq $FriendlyName -and
    ([string]::IsNullOrWhiteSpace($TargetProjectRoot) -or [string]$_.targetProjectRoot -eq $TargetProjectRoot)
})

$dump = [ordered]@{
    found = ($found.Count -gt 0); count = $found.Count
    id = ''; hookType = ''; scope = ''; targetProjectRoot = ''; sourceScript = ''; createdUtc = ''
    clients = @{}; nativeGit = $null
}
if ($found.Count -gt 0) {
    $record = $found[0]
    $dump.id = [string]$record.id
    $dump.hookType = [string]$record.hookType
    $dump.scope = [string]$record.scope
    $dump.targetProjectRoot = [string]$record.targetProjectRoot
    $dump.sourceScript = [string]$record.sourceScript
    $dump.createdUtc = [string]$record.createdUtc
    foreach ($client in @('claude', 'codex')) {
        $sub = Get-ClientSubrecord -Record $record -Client $client
        if ($null -ne $sub) {
            $dump.clients[$client] = @{
                events = @($sub.events); settingsPath = [string]$sub.settingsPath
                runtimeScript = [string]$sub.runtimeScript; runtimeRoot = [string]$sub.runtimeRoot
            }
        }
    }
    if ($null -ne $record.PSObject.Properties['nativeGit'] -and $null -ne $record.nativeGit) {
        $ng = $record.nativeGit
        $dump.nativeGit = @{
            managed = [bool]$ng.managed; wrapperPath = [string]$ng.wrapperPath
            runtimeRoot = [string]$ng.runtimeRoot; companions = @($ng.companions)
            previousHookPreserved = [bool]$ng.previousHookPreserved
        }
    }
}
$directory = Split-Path -Parent $ResultPath
if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
[System.IO.File]::WriteAllText($ResultPath, ([pscustomobject]$dump | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
'@

function Invoke-StateDump {
    param([string]$FriendlyName, [string]$TargetProjectRoot = '')
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "dumpout-$token.txt"; $errF = Join-Path $Work "dumperr-$token.txt"
    $resultFile = Join-Path $Work "dumpresult-$token.json"
    $argLine = '-NoLogo -NoProfile -File "' + $DumpHarness + '" -ToolRoot "' + $ToolRoot + '" -FriendlyName "' + $FriendlyName + '" -ResultPath "' + $resultFile + '"'
    if (-not [string]::IsNullOrWhiteSpace($TargetProjectRoot)) { $argLine += ' -TargetProjectRoot "' + $TargetProjectRoot + '"' }
    $startArgs = @{
        FilePath = $HostExecutable; ArgumentList = $argLine
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-Process @startArgs
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    $doc = $null
    if (Test-Path -LiteralPath $resultFile) { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json }
    return [pscustomobject]@{ Exit = $p.ExitCode; Err = $err; Doc = $doc }
}

try {
    # =========================================================================
    Write-Host '--- canonical default registry path (no HOOKMAKER_STATE_DIR override) ---' -ForegroundColor Cyan
    # Pure string computation - Get-InstallRegistryPath/Get-InstallStateDirectory
    # perform ZERO filesystem I/O, so this real checkout's actual
    # state\install-registry.json is never read or written by this block.
    $savedForDefaultCheck = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = ''
    try {
        $defaultPath = Get-InstallRegistryPath -ToolRoot $ToolRoot
        $expectedDefaultPath = Join-Path (Join-Path $ToolRoot 'state') 'install-registry.json'
        Check 'with no override, the registry resolves to <ToolRoot>\state\install-registry.json' ($defaultPath -eq $expectedDefaultPath) $defaultPath
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedForDefaultCheck }
    Check 'HOOKMAKER_STATE_DIR overrides the state directory (what every other suite uses for isolation)' ((Get-InstallStateDirectory -ToolRoot $ToolRoot) -eq $IsolatedStateDir)

    # =========================================================================
    Write-Host '--- a corrupt registry is quarantined byte-for-byte and rebuilt, never silently replaced ---' -ForegroundColor Cyan
    $CorruptStateDir = Join-Path $Work 'corrupt-cycle-state'
    New-Item -ItemType Directory -Path $CorruptStateDir -Force | Out-Null
    $corruptRegistryPath = Join-Path $CorruptStateDir 'install-registry.json'
    $corruptBytesBefore = [System.Text.Encoding]::UTF8.GetBytes('{ this is deliberately not valid json at all ]][[')
    [System.IO.File]::WriteAllBytes($corruptRegistryPath, $corruptBytesBefore)

    $corruptFixtureDir = Join-Path $Work 'corrupt-fixture'
    New-Item -ItemType Directory -Path $corruptFixtureDir -Force | Out-Null
    $corruptFixture = Join-Path $corruptFixtureDir 'ZZZ-Persist-Corrupt.ps1'
    Write-Utf8 $corruptFixture "exit 0`n"
    $corruptProj = New-Proj 'CorruptCycleProj'

    $rCorrupt = Invoke-InstallProcess -StateDir $CorruptStateDir -ScriptArgs @('-CustomHook', $corruptFixture, '-Events', 'Stop', '-TargetProject', $corruptProj, '-ClaudeOnly')
    Check 'installing over a corrupt registry still succeeds (quarantine-and-rebuild, not a crash)' ($rCorrupt.Exit -eq 0) $rCorrupt.Err

    $quarantineFiles = @(Get-ChildItem -LiteralPath $CorruptStateDir -Filter 'install-registry.corrupt-*.json' -File -ErrorAction SilentlyContinue)
    Check 'the corrupt registry was quarantined under a distinct filename' ($quarantineFiles.Count -eq 1)
    if ($quarantineFiles.Count -gt 0) {
        $quarantineBytes = [System.IO.File]::ReadAllBytes($quarantineFiles[0].FullName)
        Check 'the quarantined file preserves the corrupt registry byte-for-byte' (Test-BytesEqual $quarantineBytes $corruptBytesBefore)
    }
    Check 'a fresh, valid registry now exists at the canonical path' (
        Test-Path -LiteralPath (Join-Path $CorruptStateDir 'install-registry.d') -PathType Container)

    $savedForCorruptCheck = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = $CorruptStateDir
    try {
        $rebuiltRegistry = Read-InstallRegistry -ToolRoot $ToolRoot
        $rebuiltRecord = @($rebuiltRegistry.installs | Where-Object { [string]$_.friendlyName -eq 'ZZZ-Persist-Corrupt' })
        Check 'the new install is tracked in the rebuilt registry despite the prior corruption' ($rebuiltRecord.Count -eq 1)
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedForCorruptCheck }

    # =========================================================================
    Write-Host '--- multi-process lifecycle: Process A (install) -> Process B (verify + update) -> Process C (uninstall) ---' -ForegroundColor Cyan

    # A STANDALONE source (outside any recognized hooks\ root): the friendly
    # name derived from it is the script's own basename, and NO folder named
    # after that friendly name exists anywhere under hooks\. If the updater ever
    # regressed to reconstructing "hooks/<FriendlyName>/<FriendlyName>.ps1" from
    # the name instead of using the persisted `sourceScript` field, it could
    # never find this source - proving the persisted path is what is really used.
    $sourceDir = Join-Path $Work 'persist-source'
    New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
    $fixtureName = 'ZZZ-Persist-Source'
    $fixturePath = Join-Path $sourceDir ($fixtureName + '.ps1')
    Write-Utf8 $fixturePath "exit 0 # v1`n"
    # A neighbouring secret marker: a standalone source installs ONLY its own
    # script (proven separately by Test-InstallRegistry.ps1's boundary suite),
    # so this must never reach the registry either.
    $secretMarker = 'sk-live-PersistTest-' + [guid]::NewGuid().ToString('N')
    Write-Utf8 (Join-Path $sourceDir '.env') ('FAKE_SECRET=' + $secretMarker + "`n")

    $proj = New-Proj 'PersistLifecycleProj'
    $sourceHashV1 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash

    # ---- Process A: install (both clients) ----
    # A single event: PowerShell's `-File` command-line binder (raw argv, no
    # PowerShell parsing of the argument text) only ever binds ONE bare value to
    # a [string[]] parameter per invocation - a second bare token silently falls
    # through to positional binding on an unrelated parameter instead of
    # extending the array (confirmed by direct reproduction). Every existing
    # suite's genuinely spawned installs use exactly one event for this reason;
    # a real multi-event array is only ever exercised via an in-process `&` call.
    $rA = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $fixturePath, '-Events', 'Stop', '-TargetProject', $proj)
    Check 'Process A (install) exits 0' ($rA.Exit -eq 0) $rA.Err
    # Process A exits here (Start-Process -Wait already returned) before anything below runs.
    Check 'the source file is untouched immediately after Process A installs it (install only ever COPIES from source)' ((Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash -eq $sourceHashV1)

    $registryRawAfterInstall = Get-InstallRegistryRawText -ToolRoot $ToolRoot
    Check 'the registry never stores the neighbouring .env secret value' ($registryRawAfterInstall -notmatch [regex]::Escape($secretMarker))
    Check 'the registry never stores the literal .env content marker' ($registryRawAfterInstall -notmatch 'FAKE_SECRET')

    # ---- Process B (load state): a FRESH process proves the exact record survived ----
    $dumpAfterInstall = Invoke-StateDump -FriendlyName $fixtureName -TargetProjectRoot $proj
    Check 'Process B (load state) exits 0' ($dumpAfterInstall.Exit -eq 0) $dumpAfterInstall.Err
    $recAfterInstall = $dumpAfterInstall.Doc
    Check 'a fresh process finds exactly one persisted record' ($null -ne $recAfterInstall -and $recAfterInstall.found -eq $true -and $recAfterInstall.count -eq 1)
    Check 'the persisted source path is the EXACT fixture path (not rebuilt from the hook name)' ([string]$recAfterInstall.sourceScript -eq $fixturePath) ([string]$recAfterInstall.sourceScript)
    Check 'the persisted hookType is CustomHook' ([string]$recAfterInstall.hookType -eq 'CustomHook')
    Check 'the persisted scope is project' ([string]$recAfterInstall.scope -eq 'project')
    Check 'the persisted targetProjectRoot matches' ([string]$recAfterInstall.targetProjectRoot -eq $proj)
    Check 'the persisted claude events survived' ((@($recAfterInstall.clients.claude.events) | Sort-Object) -join ',' -eq 'Stop')
    Check 'the persisted codex events survived' ((@($recAfterInstall.clients.codex.events) | Sort-Object) -join ',' -eq 'Stop')
    Check 'the persisted claude settingsPath survived' (-not [string]::IsNullOrWhiteSpace([string]$recAfterInstall.clients.claude.settingsPath))
    Check 'the persisted codex settingsPath survived' (-not [string]::IsNullOrWhiteSpace([string]$recAfterInstall.clients.codex.settingsPath))
    Check 'the persisted claude runtimeScript survived and really exists on disk' (Test-Path -LiteralPath ([string]$recAfterInstall.clients.claude.runtimeScript))
    Check 'the persisted codex runtimeScript survived and really exists on disk' (Test-Path -LiteralPath ([string]$recAfterInstall.clients.codex.runtimeScript))
    Check 'a plain custom hook has no nativeGit metadata (not applicable here)' ($null -eq $recAfterInstall.nativeGit)
    $persistedId = [string]$recAfterInstall.id
    $persistedClaudeSettings = [string]$recAfterInstall.clients.claude.settingsPath
    $persistedCodexSettings = [string]$recAfterInstall.clients.codex.settingsPath
    $persistedClaudeScript = [string]$recAfterInstall.clients.claude.runtimeScript
    $persistedCodexScript = [string]$recAfterInstall.clients.codex.runtimeScript

    # ---- Process B (update): edit the source, then update via the REAL wizard action ----
    Write-Utf8 $fixturePath "exit 0 # v2-changed`n"
    $sourceHashV2 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
    Check 'v2 content genuinely differs from v1' ($sourceHashV2 -ne $sourceHashV1)
    Check 'the installed copy still differs from the freshly-edited source before updating' ((Get-FileHash -LiteralPath $persistedClaudeScript -Algorithm SHA256).Hash -ne $sourceHashV2)

    $cfgUpdate = Join-Path $Work 'cfg-update.json'; New-Config $cfgUpdate
    # main '1' -> "Create or install a hook" -> submenu '4' -> Update previously
    # installed hooks -> one hook needs updating, so ONE confirm is asked
    # (blank = default y) -> back to main menu -> '0' exits.
    $rUpdate = Invoke-Wizard -Config $cfgUpdate -Answers @('1', '4', '', '0')
    Check 'Process B (update via the wizard) exits 0' ($rUpdate.Exit -eq 0) $rUpdate.Err
    Check 'the update plan located the fixture by its PERSISTED path and flagged it changed' ($rUpdate.Out -match ([regex]::Escape($fixtureName) + '[\s\S]*?source changed')) $rUpdate.Out

    Check 'the installed Claude copy now matches the edited source byte-for-byte' ((Get-FileHash -LiteralPath $persistedClaudeScript -Algorithm SHA256).Hash -eq $sourceHashV2)
    Check 'the installed Codex copy now matches the edited source byte-for-byte too' ((Get-FileHash -LiteralPath $persistedCodexScript -Algorithm SHA256).Hash -eq $sourceHashV2)
    Check 'the source file itself is untouched by the update (never written back to)' ((Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash -eq $sourceHashV2)

    $dumpAfterUpdate = Invoke-StateDump -FriendlyName $fixtureName -TargetProjectRoot $proj
    Check 'Process B (re-verify after update) exits 0' ($dumpAfterUpdate.Exit -eq 0) $dumpAfterUpdate.Err
    Check 'the record id is unchanged across the update (same logical install, never duplicated)' ([string]$dumpAfterUpdate.Doc.id -eq $persistedId)
    Check 'scope/target/events are still preserved after the update' (
        [string]$dumpAfterUpdate.Doc.scope -eq 'project' -and
        [string]$dumpAfterUpdate.Doc.targetProjectRoot -eq $proj -and
        (@($dumpAfterUpdate.Doc.clients.claude.events) | Sort-Object) -join ',' -eq 'Stop')
    # Process B exits here.

    # ---- Process C: uninstall by the PERSISTED record id ----
    $rUninstall = Invoke-UninstallProcess -RecordId $persistedId
    Check 'Process C (uninstall by persisted record id) exits 0' ($rUninstall.Exit -eq 0) $rUninstall.Err
    Check 'Process C reports overall ok' ([string]$rUninstall.Result.overall -eq 'ok') ($rUninstall.Result | ConvertTo-Json -Depth 5)

    Check 'the claude runtime copy is gone' (-not (Test-Path -LiteralPath $persistedClaudeScript))
    Check 'the codex runtime copy is gone' (-not (Test-Path -LiteralPath $persistedCodexScript))
    $claudeSettingsAfterUninstall = [System.IO.File]::ReadAllText($persistedClaudeSettings)
    Check 'the claude settings registration for this hook is gone' ($claudeSettingsAfterUninstall -notmatch [regex]::Escape($fixtureName))
    $codexSettingsAfterUninstall = [System.IO.File]::ReadAllText($persistedCodexSettings)
    Check 'the codex settings registration for this hook is gone' ($codexSettingsAfterUninstall -notmatch [regex]::Escape($fixtureName))

    $dumpAfterUninstall = Invoke-StateDump -FriendlyName $fixtureName -TargetProjectRoot $proj
    Check 'a fresh process confirms the record is really gone (proven by re-reading, not assumed)' ($dumpAfterUninstall.Doc.found -eq $false)

    Check 'the source hook file remains byte-identical across the whole install->update->uninstall cycle' ((Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash -eq $sourceHashV2)

    # ---- no second state database is created anywhere in the cycle ----
    $stateDirFiles = @(Get-ChildItem -LiteralPath $IsolatedStateDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    # The registry is a DIRECTORY of per-record files; the retired single
    # document and any quarantine copies may sit beside it, and nothing else may.
    $unexpectedStateFiles = @($stateDirFiles | Where-Object {
            $_ -ne 'install-registry.json' -and $_ -notmatch '\.lock$' -and
            $_ -notmatch '^install-registry\.corrupt-' -and $_ -notmatch '^install-registry\.migrated-' -and
            $_ -notmatch '^install-record-.*\.corrupt-' })
    Check 'no second tracking database/catalog file exists under the state directory' ($unexpectedStateFiles.Count -eq 0) ($unexpectedStateFiles -join ',')
    Check 'the one canonical registry store is present' (
        Test-Path -LiteralPath (Join-Path $IsolatedStateDir 'install-registry.d') -PathType Container)
    $recordFiles = @(Get-ChildItem -LiteralPath (Join-Path $IsolatedStateDir 'install-registry.d') -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $unexpectedRecordFiles = @($recordFiles | Where-Object { $_ -notmatch '\.json$' })
    Check 'the registry store holds only record documents' ($unexpectedRecordFiles.Count -eq 0) ($unexpectedRecordFiles -join ',')
    $projFiles = @(Get-ChildItem -LiteralPath $proj -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $strayTrackingFiles = @($projFiles | Where-Object { $_ -match '(?i)install-registry|\.sqlite$|\.db$' })
    Check 'no second install-tracking database exists anywhere under the target project' ($strayTrackingFiles.Count -eq 0) ($strayTrackingFiles -join ',')

    # =========================================================================
    Write-Host '--- native Git managed metadata (nativeGit.*) also survives a process boundary ---' -ForegroundColor Cyan
    $ignoreHook = Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1'
    $nativeProj = Join-Path $Work 'native-git-proj'
    New-Item -ItemType Directory -Path $nativeProj -Force | Out-Null
    Push-Location $nativeProj
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $nativeProj '.git\hooks') -Force | Out-Null

    $rNative = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $ignoreHook, '-Events', 'Stop', '-TargetProject', $nativeProj, '-ClaudeOnly')
    Check 'Process A (native-git install) exits 0' ($rNative.Exit -eq 0) $rNative.Err

    $dumpNative = Invoke-StateDump -FriendlyName 'Ignore-Rules-Check' -TargetProjectRoot $nativeProj
    Check 'Process B (load state) exits 0 for the native-git record' ($dumpNative.Exit -eq 0) $dumpNative.Err
    $nativeRec = $dumpNative.Doc
    Check 'a fresh process finds the native-git record' ($null -ne $nativeRec -and $nativeRec.found -eq $true)
    Check 'nativeGit metadata persisted: managed=true' ($nativeRec.nativeGit.managed -eq $true)
    Check 'nativeGit metadata persisted: wrapperPath is set and really exists on disk' (-not [string]::IsNullOrWhiteSpace([string]$nativeRec.nativeGit.wrapperPath) -and (Test-Path -LiteralPath ([string]$nativeRec.nativeGit.wrapperPath)))
    Check 'nativeGit metadata persisted: runtimeRoot is set' (-not [string]::IsNullOrWhiteSpace([string]$nativeRec.nativeGit.runtimeRoot))
    Check 'nativeGit metadata persisted: the Secrets-Check companion is tracked' (@($nativeRec.nativeGit.companions) -contains 'Secrets-Check')
    Check 'nativeGit metadata persisted: previousHookPreserved is false (fresh repo had no prior hook)' ($nativeRec.nativeGit.previousHookPreserved -eq $false)

    # =========================================================================
    Write-Host '--- no ZZZ-* fixture leaked into the real hooks directory ---' -ForegroundColor Cyan
    Check 'no ZZZ-Persist-* fixture exists under the real hooks\ folder' (@(Get-ChildItem -LiteralPath $RealHooksDir -Directory -Filter 'ZZZ-Persist-*' -ErrorAction SilentlyContinue).Count -eq 0)
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
