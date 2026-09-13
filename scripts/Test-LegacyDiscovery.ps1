# Offline test suite for legacy/untracked hook DISCOVERY: Find-ManagedCommands
# (called by Get-LegacyHookCandidates, part of "Update previously installed
# hooks") must inspect every command-bearing field (command, commandWindows,
# command_windows) via the SAME centralized ownership parser used everywhere
# else, not just a hardcoded regex against .command alone. Covers: a
# registration stored in only one of the three fields is still found; the
# same logical registration split across command+commandWindows on one
# handler yields exactly one candidate, never two; a proven-shape path
# outside any known tool root is reported as ambiguous and never imported;
# and an unrelated script that merely shares a basename with a real hook is
# never confused with it.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-LegacyDiscovery.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$Setup = Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($Setup, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-legacydisc'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir
$SavedHookMakerLogDir = $env:HOOKMAKER_LOG_DIR
$env:HOOKMAKER_LOG_DIR = Join-Path $Work 'logs'

function New-Config {
    param([string]$Path)
    '{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[]}' | Set-Content -LiteralPath $Path -Encoding utf8
}

# Same spawned-process pattern used by every other suite that drives the
# wizard (Test-InstallRegistry.ps1's Invoke-Wizard): the updater's legacy scan
# reads (Get-Location) as the "project" scope, so WorkingDirectory steers it
# at an isolated fixture project instead of this real checkout.
function Invoke-Wizard {
    param([string[]]$Answers, [string]$Config, [string]$WorkingDirectory)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "in-$token.txt"; $outF = Join-Path $Work "out-$token.txt"; $errF = Join-Path $Work "err-$token.txt"
    [System.IO.File]::WriteAllText($inF, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    $argLine = '-NoLogo -NoProfile -File "' + $Setup + '" -ConfigPath "' + $Config + '"'
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine; RedirectStandardInput = $inF
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        WorkingDirectory = $WorkingDirectory
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-BoundedProcess @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\x1b\[[0-9;]*m", ''); Err = $err }
}

function New-HandlerSettings {
    param([string]$Path, [hashtable]$EventsToCommand)
    # $EventsToCommand: eventName -> hashtable of field=>value for one handler.
    $hooksObj = [ordered]@{}
    foreach ($eventName in $EventsToCommand.Keys) {
        $handler = [ordered]@{ type = 'command' }
        foreach ($field in $EventsToCommand[$eventName].Keys) { $handler[$field] = $EventsToCommand[$eventName][$field] }
        $hooksObj[$eventName] = @(@{ hooks = @($handler) })
    }
    $doc = @{ hooks = $hooksObj }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    ($doc | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $Path -Encoding utf8
}

try {
    Write-Host '--- Find-ManagedCommands inspects every command-bearing field ---' -ForegroundColor Cyan

    $proj = New-Proj 'LegacyDiscoveryProj'
    $claudeSettings = Join-Path $proj '.claude\settings.local.json'

    $hookMakerPath = { param($Name) 'pwsh -File "C:\Fake\.claude\hooks\Hook-Maker\' + $Name + '\' + $Name + '.ps1"' }
    $hookMakerWinPath = { param($Name) 'powershell.exe -File "C:\Fake\.claude\hooks\Hook-Maker\' + $Name + '\' + $Name + '.ps1"' }

    New-HandlerSettings -Path $claudeSettings -EventsToCommand @{
        # 1. command only
        'Stop'             = @{ command = (& $hookMakerPath 'ZZZ-Ld-Commandonly') }
        # 2. commandWindows only
        'SessionStart'     = @{ commandWindows = (& $hookMakerWinPath 'ZZZ-Ld-Winonly') }
        # 3. command_windows only
        'UserPromptSubmit' = @{ command_windows = (& $hookMakerWinPath 'ZZZ-Ld-Snakeonly') }
        # 4. portable + Windows fields together, same logical hook
        'PreCompact'       = @{ command = (& $hookMakerPath 'ZZZ-Ld-Bothfields'); commandWindows = (& $hookMakerWinPath 'ZZZ-Ld-Bothfields') }
        # 5. ambiguous near-match: proven Form-2 shape (hooks\<Name>\<Name>.ps1)
        # but rooted OUTSIDE any known tool root (only this real checkout's
        # own root is "known" in an isolated test registry) - never imported.
        'Notification'     = @{ command = 'pwsh -File "C:\SomeRandomProject\hooks\ZZZ-Ld-Ambiguous\ZZZ-Ld-Ambiguous.ps1"' }
        # 6. unrelated command that merely shares a basename with #1's hook,
        # but has no hooks\ folder shape at all - must never be confused with
        # the real ZZZ-Ld-Commandonly registration above.
        'PreToolUse'       = @{ command = 'pwsh -File "C:\Users\someone\MyTools\ZZZ-Ld-Commandonly.ps1"' }
    }

    $cfg = Join-Path $Work 'cfg.json'; New-Config $cfg
    $r = Invoke-Wizard -Config $cfg -Answers @('1', '4', 'n', '0') -WorkingDirectory $proj
    Check 'the update-plan run exits 0' ($r.Exit -eq 0) $r.Err

    Check '1. command-only registration is discovered' ($r.Out -match 'ZZZ-Ld-Commandonly') $r.Out
    Check '2. commandWindows-only registration is discovered' ($r.Out -match 'ZZZ-Ld-Winonly') $r.Out
    Check '3. command_windows-only registration is discovered' ($r.Out -match 'ZZZ-Ld-Snakeonly') $r.Out
    # Each entry is printed once in the numbered Plan list and again in the
    # "Skipped" recap below it, so count only the NUMBERED plan line (a
    # duplicate candidate would add a second numbered line, not a second
    # recap line).
    Check '4. portable+Windows fields on one handler yield exactly ONE candidate' (
        (@([regex]::Matches($r.Out, '\d+\.\s+ZZZ-Ld-Bothfields\b')) | Measure-Object).Count -eq 1) $r.Out
    Check '5. an ambiguous proven-shape path outside any known tool root is never imported' ($r.Out -notmatch 'Ld-Ambiguous') $r.Out
    Check '6. an unrelated same-basename command is never imported as a hook' (
        (@([regex]::Matches($r.Out, '\d+\.\s+ZZZ-Ld-Commandonly\b')) | Measure-Object).Count -eq 1) $r.Out

}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    $env:HOOKMAKER_LOG_DIR = $SavedHookMakerLogDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
