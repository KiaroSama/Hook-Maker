# Offline smoke test for a few simple pre-task/lightweight context hooks:
# - Mcp-Usage-Check: always emits a short MCP-usage reminder on SessionStart
#   (no deterministic gate - it is meant to be cheap and constant, matching
#   the shipped hook's own design).
# - Skills-Check: silent unless a skill source exists (copied project
#   skills, .ai/SKILLS.md record, or the configured/default skill library).
# - Large-File-Check: wording-only assertions (anti-fragmentation policy,
#   threshold-as-signal-not-rule, advisory Stop reason) - a few assertions
#   here rather than a whole new suite for wording-only behavior.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-ContextHooks.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$McpHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Mcp-Usage-Check\Mcp-Usage-Check.ps1'
$SkillsHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Skills-Check\Skills-Check.ps1'
$LargeFileHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Large-File-Check\Large-File-Check.ps1'
$AiMemoryHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Ai-Memory-Check\Ai-Memory-Check.ps1'
$HookLib = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\_hooklib.ps1'
foreach ($required in @($McpHook, $SkillsHook, $LargeFileHook, $AiMemoryHook, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-ctxtest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Fire {
    # $RawStdin intentionally UNTYPED: [string] coerces $null to '' (see LESSON.md).
    param([string]$HookPath, [string]$Cwd, [string]$EventName = 'SessionStart', $RawStdin = $null, [string]$Exe = 'pwsh')
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
        $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    $proc = Start-BoundedProcess -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    if ($err -ne '' -and $env:HOOKMAKER_TEST_DEBUG -eq '1') {
        Write-Host ('  [stderr] ' + $err.Split("`n")[0]) -ForegroundColor DarkYellow
    }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

# Copies Skills-Check + a custom .env into an isolated folder, so SKILLS_DIR /
# GLOBAL_SKILLS_DIR / PLUGIN_SKILLS_ROOT overrides never touch the real
# machine-wide skill library, the real per-user global skills directory, or the
# real plugin cache. All three are defaulted to guaranteed-absent paths unless
# the caller overrides them, keeping every case hermetic regardless of the host
# - without the PLUGIN_SKILLS_ROOT default, every "no skill source" case would
# pick up whatever plugins happen to be installed on the machine running the
# suite, which is exactly the kind of host-dependent green this suite exists to
# avoid.
function New-ConfiguredSkillsHookCopy {
    param([hashtable]$EnvOverrides)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # The whole folder, not just the entry script: the installer stages a hook's
    # own directory recursively, so a sibling module the hook dot-sources ships
    # with it. Copying one file would test a runtime that is never installed.
    Copy-Item (Join-Path (Split-Path -Parent $SkillsHook) '*.ps1') $dir
    Copy-Item (Join-Path (Split-Path -Parent $SkillsHook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
    $merged = @{}
    foreach ($k in $EnvOverrides.Keys) { $merged[$k] = $EnvOverrides[$k] }
    if (-not $merged.ContainsKey('GLOBAL_SKILLS_DIR')) {
        $merged['GLOBAL_SKILLS_DIR'] = (Join-Path $Work 'no-such-global-skills')
    }
    if (-not $merged.ContainsKey('PLUGIN_SKILLS_ROOT')) {
        $merged['PLUGIN_SKILLS_ROOT'] = (Join-Path $Work 'no-such-plugin-cache')
    }
    # The cached index is keyed by library + plugin root + client, and each copy
    # gets its own paths, so a stale index from a previous case can never leak
    # into another - but pin the TTL anyway so a long suite cannot expire one
    # mid-run and turn a deterministic assertion into a timing one.
    if (-not $merged.ContainsKey('LIBRARY_INDEX_TTL_MINUTES')) {
        $merged['LIBRARY_INDEX_TTL_MINUTES'] = '0'
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $merged.Keys) { [void]$lines.Add($key + '=' + $merged[$key]) }
    Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    return (Join-Path $dir 'Skills-Check.ps1')
}

# Skills-Check routes by CLAUDE_PROJECT_DIR (present -> Claude, absent -> Codex).
# Tests drive the route by setting/clearing it before a Fire; the child inherits
# the parent env at spawn time.
function Set-ClaudeProjectDir {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    }
    else {
        $env:CLAUDE_PROJECT_DIR = $Value
    }
}

function New-PromptStdin {
    param([string]$Cwd, [string]$EventName, [string]$Prompt, [string]$SessionId = 't')
    return @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName; prompt = $Prompt } | ConvertTo-Json
}

# ---- Write-HookResult probe -------------------------------------------------
# Runs the shared output adapter in a REAL child hook process (either host), so
# byte-comparisons below are against genuinely emitted bytes rather than an
# in-process reconstruction. stdout stays byte-pure for the comparison, stderr
# stays free for diagnostics, and the returned result object is handed back
# through a file named in the stdin payload.
$HookResultProbe = Join-Path $Work 'hookresult-probe.ps1'
$hookResultProbeBody = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path '__LIBDIR__' '_hooklib.ps1')
$in = Read-HookInput
$outcome = Write-HookResult -EventName ([string](Get-Field $in 'event')) -Kind ([string](Get-Field $in 'kind')) `
    -Message ([string](Get-Field $in 'message')) -Reason ([string](Get-Field $in 'reason')) -Client ([string](Get-Field $in 'client'))
[System.IO.File]::WriteAllText([string](Get-Field $in 'resultPath'), ($outcome | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
'@
Write-Utf8 $HookResultProbe ($hookResultProbeBody.Replace('__LIBDIR__', (Split-Path -Parent $HookLib)))

# ---- Write-HookResult construct probe ---------------------------------------
# WHY a SAME-PROCESS comparison exists at all: .NET Core randomises string
# hashing per process, so a plain @{} with two or more keys serialises its keys
# in a DIFFERENT order in different pwsh 7 processes - measured here, both
# {"decision":..,"reason":..} and {"reason":..,"decision":..} come out of the
# identical expression. That instability belongs to the shipped hooks (they all
# build plain @{} literals), not to the adapter, and .NET Framework (5.1) is
# deterministic. So byte-compatibility is proved two ways: cross-process against
# REAL captured hook output on the 5.1 host (deterministic there), and - here -
# inside ONE process on BOTH hosts, where the shipped literal and the adapter
# share a hash seed and any construct divergence ([ordered]@{}, different
# ConvertTo-Json flags, renamed keys, different escaping) shows up immediately.
$HookShapeProbe = Join-Path $Work 'hookshape-probe.ps1'
$hookShapeProbeBody = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path '__LIBDIR__' '_hooklib.ps1')
$in = Read-HookInput
$text = [string](Get-Field $in 'message')
$ev = [string](Get-Field $in 'event')

# What Write-HookResult actually writes to stdout, captured inside THIS process.
function Get-AdapterBytes {
    param([string]$Kind, [string]$Client)
    $writer = New-Object System.IO.StringWriter
    $previous = [Console]::Out
    [Console]::SetOut($writer)
    try { $null = Write-HookResult -EventName $ev -Kind $Kind -Message $text -Reason $text -Client $Client }
    finally { [Console]::SetOut($previous) }
    return $writer.ToString().Trim()
}

# The literal expressions the shipped hooks emit today (Mcp-Usage-Check.ps1:35,
# Large-File-Check.ps1:187/190, Ci-Status-Check.ps1:435/467/471, and ~59 more).
$pairs = @(
    @{ label = 'claudeContext'; hook = (@{ hookSpecificOutput = @{ hookEventName = $ev; additionalContext = $text } } | ConvertTo-Json -Depth 5 -Compress); adapter = (Get-AdapterBytes -Kind 'context' -Client 'claude') },
    @{ label = 'claudeAdvisory'; hook = (@{ hookSpecificOutput = @{ hookEventName = $ev; additionalContext = $text } } | ConvertTo-Json -Depth 5 -Compress); adapter = (Get-AdapterBytes -Kind 'advisory' -Client 'claude') },
    @{ label = 'codexSystemMessage'; hook = (@{ systemMessage = $text } | ConvertTo-Json -Depth 5 -Compress); adapter = (Get-AdapterBytes -Kind 'advisory' -Client 'codex') },
    @{ label = 'decisionBlockClaude'; hook = (@{ decision = 'block'; reason = $text } | ConvertTo-Json -Compress); adapter = (Get-AdapterBytes -Kind 'block' -Client 'claude') },
    @{ label = 'decisionBlockCodex'; hook = (@{ decision = 'block'; reason = $text } | ConvertTo-Json -Compress); adapter = (Get-AdapterBytes -Kind 'block' -Client 'codex') }
)
$bad = @()
foreach ($pair in $pairs) {
    if ($pair['hook'] -cne $pair['adapter']) { $bad += ($pair['label'] + ': hook=[' + $pair['hook'] + '] adapter=[' + $pair['adapter'] + ']') }
}
[System.IO.File]::WriteAllText([string](Get-Field $in 'resultPath'), ($bad -join ' || '), (New-Object System.Text.UTF8Encoding $false))
'@
Write-Utf8 $HookShapeProbe ($hookShapeProbeBody.Replace('__LIBDIR__', (Split-Path -Parent $HookLib)))

# Deliberately nasty payload: newline, double quote, backslash, tab, and the
# characters 5.1 escapes as &/</> but pwsh 7 does not.
$HookShapeSample = "GATE line1`nline2 " + [char]34 + 'quoted' + [char]34 + " & <> \ end`ttab"

# Runs the construct probe on one host; returns '' when every shape matched.
function Test-HookResultConstruct {
    param([string]$Exe = 'pwsh')
    $resultPath = Join-Path $Work ('hshape-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $null = Fire -HookPath $HookShapeProbe -Cwd $Work -Exe $Exe `
        -RawStdin (@{ resultPath = $resultPath; event = 'Stop'; message = $HookShapeSample } | ConvertTo-Json -Compress)
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { return 'the construct probe produced no result file' }
    return ([System.IO.File]::ReadAllText($resultPath)).Trim()
}

# Fires the probe with one Write-HookResult call and returns its raw stdout /
# stderr / exit code plus the parsed result object.
function Invoke-HookResult {
    param([hashtable]$Call, [string]$Exe = 'pwsh')
    $resultPath = Join-Path $Work ('hres-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $payload = @{ resultPath = $resultPath }
    foreach ($key in $Call.Keys) { $payload[$key] = $Call[$key] }
    $fired = Fire -HookPath $HookResultProbe -Cwd $Work -RawStdin ($payload | ConvertTo-Json -Compress) -Exe $Exe
    $outcome = $null
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $outcome = ([System.IO.File]::ReadAllText($resultPath)) | ConvertFrom-Json
    }
    return [pscustomobject]@{ Out = $fired.Out; Err = $fired.Err; Exit = $fired.Exit; Result = $outcome }
}

# Preserve the ambient client signal so the Skills-Check routing tests can flip
# it freely and restore it in the finally block.
$OrigClaudeProjectDir = $env:CLAUDE_PROJECT_DIR

try {
    # ---- sections, dot-sourced so they share this scope and harness -------
    # Split by hook-under-test. Each file is a pure relocation; the assertion
    # set and its order are unchanged.
    . (Join-Path $PSScriptRoot '_testcontextskills.ps1')
    . (Join-Path $PSScriptRoot '_testcontextlargefile.ps1')
    . (Join-Path $PSScriptRoot '_testcontextaimemory.ps1')
    . (Join-Path $PSScriptRoot '_testcontexthooklib.ps1')
    . (Join-Path $PSScriptRoot '_testcontextprocess.ps1')
}
finally {
    Set-ClaudeProjectDir $OrigClaudeProjectDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
