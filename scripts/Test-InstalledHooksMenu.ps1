# Offline test suite for menu 22 (Uninstall Installed Hooks): proves the list
# and confirmation screens in Setup-SyncGroupInstalledHooks.ps1 render the FULL
# install identity that Get-InstalledHookSnapshot already collects - hook type,
# exact target path, per-client event names and the exact persisted
# sourceScript in the list; record id, settings path, runtime script and
# native-Git ownership status in the confirmation screen - and that declining
# the final confirmation mutates nothing (the record survives in the registry).
#
# Drives the real interactive wizard via Start-Process with a scripted stdin
# answer file (same pattern as Test-LegacyDiscovery.ps1's Invoke-Wizard):
# main menu 1 (Create or install a hook) -> submenu 1 (Install an existing
# hook) -> hook list 22 (Uninstall installed hooks) -> select the fixture's
# row -> decline ('n') at the final confirmation -> exit (0).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstalledHooksMenu.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$Setup = Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($Setup, $InstallScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Same chain as Test-UninstallHook.ps1: _hooklib.ps1 first (Get-ShortHash,
# Read-JsonFile, ...), then _installplan.ps1, then _installlib.ps1 (which
# dot-sources _installregistry.ps1 itself, so Read-InstallRegistry /
# Get-ClientSubrecord / Get-InstalledClientNames all become available).
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-menu22-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

function New-FixtureHook {
    param([string]$Name, [string]$Body = "exit 0`n")
    $dir = Join-Path $RealHooksDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Utf8 (Join-Path $dir ($Name + '.ps1')) $Body
    return (Join-Path $dir ($Name + '.ps1'))
}
function Remove-FixtureHook {
    param([string]$Name)
    $dir = Join-Path $RealHooksDir $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function New-Config {
    param([string]$Path)
    '{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[]}' | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-Registry { return Read-InstallRegistry -ToolRoot $ToolRoot }
function Get-RecordForScope {
    param([string]$FriendlyName, [string]$TargetProjectRoot)
    return @((Get-Registry).installs | Where-Object { [string]$_.friendlyName -eq $FriendlyName -and [string]$_.targetProjectRoot -eq $TargetProjectRoot })[0]
}

# Same spawned-process pattern as Test-LegacyDiscovery.ps1's Invoke-Wizard:
# writes the scripted answers to a stdin file, spawns the wizard as a real
# process (isolated by -WorkingDirectory and the HOOKMAKER_STATE_DIR
# environment override), and strips ANSI color codes from the captured output
# so assertions can match plain text.
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
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\x1b\[[0-9;]*m", ''); Err = $err }
}

try {
    Write-Host '--- menu 22 lists the full install identity and the confirmation screen repeats it ---' -ForegroundColor Cyan

    # ZZZ-Regtest-* throwaway fixture, no internal lower->upper case transition
    # (Get-HookFriendlyName hyphenates PascalCase boundaries; this name already
    # uses hyphens so its rendered label matches the name verbatim).
    $fxName = 'ZZZ-Regtest-Menu'
    $fxScript = New-FixtureHook $fxName
    try {
        $proj = New-Proj 'Menu22Proj'
        $cfg = Join-Path $Work 'cfg.json'; New-Config $cfg

        # Claude + Codex, multi-event (2 events), project-scoped.
        & $InstallScript -CustomHook $fxScript -Events @('SessionStart', 'Stop') -TargetProject $proj *> $null
        $rec = Get-RecordForScope $fxName $proj
        Check 'setup: the fixture installed a project-scoped record' ($null -ne $rec)
        Check 'setup: the record has both clients' ((@(Get-InstalledClientNames -Record $rec) | Sort-Object) -join ',' -eq 'claude,codex')

        $claudeSettings = [string]$rec.clients.claude.settingsPath
        $claudeRuntimeScript = [string]$rec.clients.claude.runtimeScript
        $codexSettings = [string]$rec.clients.codex.settingsPath
        $codexRuntimeScript = [string]$rec.clients.codex.runtimeScript

        # main menu 1 -> submenu 1 -> hook list 22 -> select row 1 (the fixture
        # record) -> decline the confirmation -> exit the main menu.
        $r = Invoke-Wizard -Config $cfg -Answers @('1', '1', '22', '1', 'n', '0') -WorkingDirectory $proj
        Check 'the wizard run exits 0' ($r.Exit -eq 0) $r.Err

        # ---- list screen: everything Get-InstalledHookSnapshot collects ----
        Check 'list: the friendly hook name appears' ($r.Out -match [regex]::Escape('ZZZ-Regtest-Menu')) $r.Out
        Check 'list: the hook type (CustomHook) appears' ($r.Out -match 'CustomHook') $r.Out
        Check 'list: the exact target project root appears' ($r.Out -match [regex]::Escape($proj)) $r.Out
        Check 'list: Claude''s events appear' ($r.Out -match 'Claude \[SessionStart, Stop\]') $r.Out
        Check 'list: Codex''s events appear' ($r.Out -match 'Codex \[SessionStart, Stop\]') $r.Out
        Check 'list: the exact persisted sourceScript appears' ($r.Out -match [regex]::Escape($fxScript)) $r.Out

        # ---- confirmation screen: record id, settings path, runtime script, native-git status ----
        Check 'confirm: the record id appears' ($r.Out -match [regex]::Escape($rec.id)) $r.Out
        Check 'confirm: the Claude settings path appears' ($r.Out -match [regex]::Escape($claudeSettings)) $r.Out
        Check 'confirm: the Codex settings path appears' ($r.Out -match [regex]::Escape($codexSettings)) $r.Out
        Check 'confirm: the Claude runtime script path appears' ($r.Out -match [regex]::Escape($claudeRuntimeScript)) $r.Out
        Check 'confirm: the Codex runtime script path appears' ($r.Out -match [regex]::Escape($codexRuntimeScript)) $r.Out
        Check 'confirm: native-Git ownership status appears (this install does not own it)' ($r.Out -match 'native Git:\s*no') $r.Out

        # ---- decline was honored: no mutation at all ----
        Check 'decline: the wizard reported "Canceled"' ($r.Out -match 'Canceled\. Nothing was changed\.') $r.Out
        $recAfter = Get-RecordForScope $fxName $proj
        Check 'decline: the record still exists in the registry' ($null -ne $recAfter -and [string]$recAfter.id -eq [string]$rec.id)
        Check 'decline: the Claude settings file is untouched' (Test-Path -LiteralPath $claudeSettings)
        Check 'decline: the Claude runtime script is untouched' (Test-Path -LiteralPath $claudeRuntimeScript)

        Write-Host ''
        Write-Host '--- sample rendered list block for this install ---' -ForegroundColor DarkGray
        # The fixture also appears earlier as a plain installable custom hook in
        # "Available hooks:" - the row we want is the one inside "Installed
        # hooks:", so anchor the search there rather than on the first match.
        $installedHeaderAt = $r.Out.IndexOf('Installed hooks:')
        $sampleStart = if ($installedHeaderAt -ge 0) { $r.Out.IndexOf('ZZZ-Regtest-Menu', $installedHeaderAt) } else { -1 }
        if ($sampleStart -ge 0) {
            $sampleEnd = $r.Out.IndexOf("`n`n", $sampleStart)
            if ($sampleEnd -lt 0) { $sampleEnd = [Math]::Min($r.Out.Length, $sampleStart + 600) }
            Write-Host $r.Out.Substring($sampleStart, $sampleEnd - $sampleStart)
        }
    }
    finally {
        Remove-FixtureHook $fxName
    }
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
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
