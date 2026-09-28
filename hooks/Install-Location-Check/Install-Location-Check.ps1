# Install-Location-Check - advisory PreToolUse hook for install commands whose
# target is on the system drive (global-environment-rules.md -> Install
# Locations: Never the System Drive by Default; global-hook-rules.md hook list).
#
# ROLE (global-hook-rules.md "Hook Roles"): DETECTOR / ADVISORY. It never
# blocks, never approves, never rewrites the command and never runs an
# installer. The output is context only - hookSpecificOutput.additionalContext
# with NO permissionDecision, because permissionDecision "allow" is an approval
# on both Claude Code and Codex and would skip the user's own permission prompt.
#
# WHAT IT DOES. The tool command is treated as DATA with the shared tokenizer
# (hooks\_commandtokens.ps1): quote-aware tokens, split into segments on
# separator tokens. Each segment is matched against the installer families in
# _installfamilies.ps1; each package found gets its install target, which is
# resolved to its PHYSICAL path (links on the target and on every parent
# followed - _physicalpath.ps1). One advisory line per package whose physical
# path is on the system drive and outside the project.
#
# SILENT WHEN: the physical target is off the system drive; the target is
# inside the project (node_modules, the project .venv); the same package was
# already advised this session (fingerprint = session + family + package,
# stored hashed); the command is not recognised; the target cannot be
# resolved (a query timed out or failed). Any internal error is silence too:
# an advisory hook must never be the reason a command did not run.
#
# Optional .env next to this script (copy .env.example).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot '..\_hooklib.ps1')
    $commandTokensPath = Join-Path $PSScriptRoot '_commandtokens.ps1'
    if (-not (Test-Path -LiteralPath $commandTokensPath -PathType Leaf)) { $commandTokensPath = Join-Path $PSScriptRoot '..\_commandtokens.ps1' }
    . $commandTokensPath
    . (Join-Path $PSScriptRoot '_physicalpath.ps1')
    . (Join-Path $PSScriptRoot '_installfamilies.ps1')
}
catch { exit 0 }

function Get-InstallStateDirectory {
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path $root 'HookMaker\state')
}

# The advisory lines for one command. Separated from the event plumbing so the
# tests can drive it in-process with the seams in _physicalpath.ps1 set.
function Get-InstallAdvisories {
    param([string[]]$Tokens, [string]$ProjectRoot, [string]$SessionId, [string]$StateDirectory)
    $sessionKey = Get-ShortHash ($SessionId.ToLowerInvariant())
    $seenPath = Join-Path $StateDirectory ('InstallLocation-' + $sessionKey + '.txt')
    $cachePath = Join-Path $StateDirectory ('InstallLocation-query-' + $sessionKey + '.txt')
    $seen = New-Object System.Collections.Generic.HashSet[string]
    try {
        if (Test-Path -LiteralPath $seenPath -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($seenPath)) { [void]$seen.Add($line.Trim()) }
        }
    }
    catch { }
    $lines = New-Object System.Collections.Generic.List[string]
    $newFingerprints = New-Object System.Collections.Generic.List[string]
    $drive = Get-InstallSystemDrive
    # `a; b` usually arrives with the semicolon glued to the token before it.
    # The shared tokenizer splits only on a standalone separator (Test-Run-Guard
    # depends on that), so the split happens here, for this hook alone.
    $split = New-Object System.Collections.Generic.List[string]
    foreach ($token in @($Tokens)) {
        if ($token.Length -gt 1 -and $token.EndsWith(';')) { [void]$split.Add($token.TrimEnd(';')); [void]$split.Add(';') }
        else { [void]$split.Add($token) }
    }
    $Tokens = $split.ToArray()
    foreach ($segment in @(Split-CommandSegments -Tokens $Tokens)) {
        foreach ($finding in @(Get-InstallFindings -Tokens @($segment) -AllTokens $Tokens -ProjectRoot $ProjectRoot)) {
            $fingerprint = Get-ShortHash (($SessionId + '|' + $finding.Family + '|' + $finding.Package).ToLowerInvariant())
            if ($seen.Contains($fingerprint)) { continue }
            $target = $finding.Target
            if ([string]::IsNullOrWhiteSpace($target) -and $null -ne $finding.Query) {
                $target = Get-CachedInstallQuery -CachePath $cachePath -Kind $finding.Query.Kind -Program $finding.Query.Program -Arguments @($finding.Query.Arguments)
            }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $ProjectRoot $target }
            $physical = Resolve-PhysicalPath $target
            if (-not (Test-OnSystemDrive $physical)) { continue }
            if (Test-PathInside -Candidate $physical -Parent $ProjectRoot) { continue }
            [void]$seen.Add($fingerprint)
            [void]$newFingerprints.Add($fingerprint)
            [void]$lines.Add('INSTALL LOCATION: ' + $finding.Family + ' would install ' + $finding.Package + ' into ' + $physical + ' on ' + $drive +
                '. Ask the user for the install path first, naming the package and what it is, unless a remembered answer or a stated reason ' +
                '(installer offers no other location, Windows requires it, the user chose ' + $drive + ') covers it; then point the tool''s own ' +
                'setting at that path and verify where it landed. Rule: global-environment-rules.md -> Install Locations.')
        }
    }
    if ($newFingerprints.Count -gt 0) {
        try {
            if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) { New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null }
            [System.IO.File]::AppendAllText($seenPath, (($newFingerprints.ToArray() -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { }
    }
    return $lines.ToArray()
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $hookInput = Read-HookInput
    if ($null -eq $hookInput) { exit 0 }
    if ([string](Get-Field $hookInput 'hook_event_name') -ne 'PreToolUse') { exit 0 }
    $toolInput = Get-Field $hookInput 'tool_input'
    $rawCommand = Get-Field $toolInput 'command'
    if ($null -eq $rawCommand) { $rawCommand = Get-Field $toolInput 'cmd' }
    if ($null -eq $rawCommand) { exit 0 }
    # Claude sends a string; a Codex-style shell tool may send an argv array,
    # which is already tokenized.
    $tokens = @()
    if ($rawCommand -is [string]) { $tokens = @(Split-CommandTokens -Text $rawCommand) }
    elseif ($rawCommand -is [System.Collections.IEnumerable]) { $tokens = @(@($rawCommand) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' }) }
    if ($tokens.Count -eq 0) { exit 0 }

    $projectRoot = [string](Get-Field $hookInput 'cwd')
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = [string]$env:CLAUDE_PROJECT_DIR }
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }
    $sessionId = [string](Get-Field $hookInput 'session_id')
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'no-session' }

    $config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
    $timeout = 0
    if ($config.ContainsKey('QUERY_TIMEOUT_SECONDS') -and [int]::TryParse([string]$config['QUERY_TIMEOUT_SECONDS'], [ref]$timeout) -and $timeout -ge 1 -and $timeout -le 8) {
        $script:InstallLocationQueryTimeout = $timeout
    }

    $lines = @(Get-InstallAdvisories -Tokens $tokens -ProjectRoot $projectRoot -SessionId $sessionId -StateDirectory (Get-InstallStateDirectory))
    if ($lines.Count -gt 0) {
        $null = Write-HookResult -EventName 'PreToolUse' -Kind 'advisory' -Message ($lines -join "`n")
    }
}
catch { }
exit 0
