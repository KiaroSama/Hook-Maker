# Test-TestRunGuard.ps1 shared harness: the UTF-8 writer, the filename-safe
# runId helper, the per-case isolated hook copy + fake LOCALAPPDATA factory,
# the stdin-driven Fire process runner, and the output parsers (client-shape
# message extraction, single-JSON validation, replacement-line extraction).
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# $Work / $Hook / $HookLib) - not a standalone suite.

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

# Filename-safe runId, matching Test-Run-Guard.ps1/Run-Tests-Guarded.ps1's
# Get-SafeRunId - the per-run suffix of every coordination file.
function Get-SafeRunId { param([string]$Id) $s = ([string]$Id).ToLowerInvariant() -replace '[^a-z0-9]', ''; if ($s -eq '') { $s = [guid]::NewGuid().ToString('N') } return $s }

# Per-case isolated hook copy + fake LOCALAPPDATA, so result/report/config state
# never collides across cases or with the real machine state.
# EVERY .ps1 beside the hook, not just the entry point. The real installer
# stages the whole hook PACKAGE, so a copy that took one file would exercise a
# runtime that cannot exist - and silently breaks the moment a hook grows a
# companion module, which Test-Run-Guard now has. One definition, so a future
# split cannot reintroduce the single-file copy at some other call site.
function Copy-HookPackage {
    param([Parameter(Mandatory = $true)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -File -Filter '*.ps1')) {
        Copy-Item $file.FullName (Join-Path $Destination $file.Name) -Force
    }
}

function New-IsolatedHookCopy {
    param([hashtable]$EnvOverrides = @{})
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-HookPackage -Destination $dir
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($EnvOverrides.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
        Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Run-Guard.ps1'); LocalAppData = $fakeLocal }
}

function Fire {
    param(
        [string]$HookPath, [string]$Cwd, [string]$EventName, [string]$Command,
        [string[]]$CommandArray, [string]$LocalAppData, [switch]$NoClaudeProjectDir, [string]$Exe = 'pwsh'
    )
    $toolInput = @{ description = 'x' }
    if ($PSBoundParameters.ContainsKey('CommandArray')) { $toolInput['command'] = @($CommandArray) }
    else { $toolInput['command'] = $Command }
    $obj = @{ session_id = 'sess1'; cwd = $Cwd; hook_event_name = $EventName; tool_name = 'Bash'; tool_input = $toolInput }
    $payload = $obj | ConvertTo-Json -Depth 6
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    Write-Utf8 $inFile $payload
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' }
    $startArgs = @{
        FilePath               = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait                   = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        # -Environment MERGES with the inherited environment, so an ambient
        # CLAUDE_PROJECT_DIR from this very runner would leak into a "Codex"
        # case. Set it explicitly to '' rather than omitting the key.
        $childEnv = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData }
        $childEnv['CLAUDE_PROJECT_DIR'] = if ($NoClaudeProjectDir) { '' } else { $Cwd }
        $startArgs.Environment = $childEnv
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# The model-visible text, whichever client shape carried it.
function Get-Message {
    param([string]$Out)
    if ([string]::IsNullOrWhiteSpace($Out)) { return '' }
    try { $parsed = $Out | ConvertFrom-Json } catch { return '' }
    foreach ($path in @('permissionDecisionReason', 'additionalContext')) {
        if ($null -ne $parsed.PSObject.Properties['hookSpecificOutput'] -and
            $null -ne $parsed.hookSpecificOutput.PSObject.Properties[$path]) {
            return [string]$parsed.hookSpecificOutput.$path
        }
    }
    if ($null -ne $parsed.PSObject.Properties['systemMessage']) { return [string]$parsed.systemMessage }
    return ''
}

function Test-IsSingleJson {
    param([string]$Out)
    if ([string]::IsNullOrWhiteSpace($Out)) { return $false }
    try { $null = $Out | ConvertFrom-Json; return $true } catch { return $false }
}

# Pulls the recommended invocation out of the finding: the line starting 'pwsh'.
function Get-Replacement {
    param([string]$Message)
    foreach ($line in ($Message -split "`n")) {
        if ($line.Trim().StartsWith('pwsh ')) { return $line.Trim() }
    }
    return ''
}
