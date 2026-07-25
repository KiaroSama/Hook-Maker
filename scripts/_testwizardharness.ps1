# Test-Wizard.ps1 shared harness: the stdin-driven Invoke-Wizard runner (a
# fresh config + project dirs and an isolated install registry per run), the
# throwaway config/project builders, and the settings readers that report a
# hook's registered events and per-registration timeouts.
#
# Dot-sourced by Test-Wizard.ps1 into the caller's scope (uses its $Work /
# $Setup / $IsolatedStateDir) - not a standalone suite.

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
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine; RedirectStandardInput = $inF
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        # -Environment MERGES with the inherited environment (see LESSON.md) -
        # this only adds HOOKMAKER_STATE_DIR, everything else stays inherited.
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-Process @startArgs
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

# Every registered handler timeout for one hook, one entry per registration, so
# a missing timeout property reads as '' rather than silently matching.
function Get-RegisteredTimeouts {
    param([string]$SettingsPath, [string]$HookName)
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    $pattern = '[\\/]' + [regex]::Escape($HookName) + '[\\/]' + [regex]::Escape($HookName + '.ps1')
    $timeouts = New-Object System.Collections.Generic.List[string]
    foreach ($event in $settings.hooks.PSObject.Properties) {
        foreach ($group in @($event.Value)) {
            foreach ($handler in @($group.hooks)) {
                $matched = $false
                foreach ($property in @('command', 'commandWindows', 'command_windows')) {
                    if ($null -ne $handler.PSObject.Properties[$property] -and [string]$handler.$property -match $pattern) { $matched = $true }
                }
                if (-not $matched) { continue }
                if ($null -ne $handler.PSObject.Properties['timeout']) { [void]$timeouts.Add([string]$handler.timeout) }
                else { [void]$timeouts.Add('') }
            }
        }
    }
    return $timeouts.ToArray()
}
