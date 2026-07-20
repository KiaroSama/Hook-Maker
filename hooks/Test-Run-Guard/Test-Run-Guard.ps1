# Test-Run-Guard - the DURING stage of the three-stage test enforcement
# (global-test-rules.md "Three-Stage Test Enforcement", global-hook-rules.md
# "Test Hook Architecture").
#
# ROLE (global-hook-rules.md "Hook Roles"):
#   PreToolUse  -> GATE.     Blocks ONE thing: a clearly-recognised RAW test
#                            command that is about to run with no bounded
#                            runner around it. It answers with the EXACT safe
#                            replacement, and nothing else it sees is its
#                            business.
#   PostToolUse -> DETECTOR. Reads the guarded runner's structured result and
#                            reports what actually happened - timeout, kill,
#                            leaked process, non-zero exit. Never blocks.
#
# WHY THE HOOK DOES NOT WATCH THE RUN: this process returns in milliseconds and
# is gone long before the suite finishes. The watchdog lives in
# scripts\Run-Tests-Guarded.ps1, which owns the child process for its whole
# life. This hook only decides whether that owner exists, and later reads what
# it recorded. "High CPU means hung" is a judgement neither of them makes -
# see the runner's Test-ShouldTerminate.
#
# RECOGNITION IS CONSERVATIVE AND STRUCTURED. The command is treated as DATA:
# tokenized with quotes respected, split on separator TOKENS, and matched on the
# PROGRAM token (plus, where it disambiguates, its subcommand). It is never
# evaluated, never concatenated into a shell string, and never handed to
# Invoke-Expression - this hook starts no process at all. A `pwsh -Command
# '<string>'` payload is deliberately NOT inspected: recognising it would mean
# parsing a shell, so it stays silent. Anything not positively recognised
# produces total silence; a false positive here would block real work.
#
# Optional .env next to this script (copy .env.example - it documents every key
# and the defaults). An invalid value is reported ONCE in plain text and the
# default is used: a malformed setting must never make this an unconditional
# blocker, nor silently disable it.
#
# COORDINATION STATE written for Test-Completion-Check. Project key =
# Get-ShortHash(lowercased cwd), the key Test-Temp-Cleanup and Cloudflare-Deploy
# already use.
#   TestRunGuard-observed-<key>.json  { observedUtc, fingerprint, guarded }
#       "a test command happened for THIS repo state". Written on PreToolUse for
#       every recognised test command - blocked, advised, or already guarded -
#       with `guarded` recording which. This is what lets Test-Completion-Check
#       refuse a "tests passed" claim when nothing produced a result. A blocked
#       command is recorded too: the intent to test is what creates the
#       obligation to show evidence, and a re-run through the guarded runner
#       simply overwrites the record with guarded=true.
#   TestRunGuard-result-<key>.json    written by Run-Tests-Guarded.ps1 itself
#       via the -ResultPath this hook puts in the replacement command line.
#
# TestRunGuard-active-<key>.json { pid, startedUtc } is NOT written, and that is
# deliberate - see the note above Write-ObservedRecord. Its consumer treats an
# absent file as "not evaluated", so omitting it is silent, whereas a guessed
# pid would be a false completion blocker on a recycled process id.
#
# TIMESTAMPS ARE ISO-8601 ROUND-TRIP ('o'), never ticks. ConvertFrom-Json turns
# an 'o' string back into a Kind=Utc [DateTime], which the consumer's
# ConvertTo-UtcTime returns unchanged - no second offset subtraction, no drift.
# A ticks string is NOT parseable by [DateTime]::TryParse and would read as no
# timestamp at all (verified both ways on this machine).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

# ---- configuration ---------------------------------------------------------

$script:ConfigIssues = New-Object System.Collections.Generic.List[string]

# Values are never echoed back - a setting can hold anything a user typed.
# Only the KEY, the accepted range, and the default used instead are reported.
function Get-IntSetting {
    param([hashtable]$Config, [string]$Key, [int]$Default, [int]$Minimum, [int]$Maximum)
    if (-not $Config.ContainsKey($Key)) { return $Default }
    $raw = ([string]$Config[$Key]).Trim()
    if ($raw -eq '') { return $Default }
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        [void]$script:ConfigIssues.Add($Key + ' must be a whole number between ' + $Minimum + ' and ' + $Maximum + ' - using the default ' + $Default)
        return $Default
    }
    return $parsed
}

function Get-BoolSetting {
    param([hashtable]$Config, [string]$Key, [bool]$Default)
    if (-not $Config.ContainsKey($Key)) { return $Default }
    $raw = ([string]$Config[$Key]).Trim().ToLowerInvariant()
    if ($raw -eq '') { return $Default }
    if ($raw -in @('1', 'true', 'yes', 'on')) { return $true }
    if ($raw -in @('0', 'false', 'no', 'off')) { return $false }
    [void]$script:ConfigIssues.Add($Key + ' must be 0 or 1 - using the default ' + $(if ($Default) { '1' } else { '0' }))
    return $Default
}

function Get-ListSetting {
    param([hashtable]$Config, [string]$Key)
    if (-not $Config.ContainsKey($Key)) { return @() }
    return @(([string]$Config[$Key]).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# ---- command parsing (data only - nothing here executes anything) ----------

# Quote-aware tokenizer. A quoted run stays ONE token, so an argument holding a
# space, a pipe, an ampersand or a semicolon can never be mistaken for a
# separator or split into two arguments.
function Split-CommandTokens {
    param([string]$Text)
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Text, '"([^"]*)"|''([^'']*)''|(\S+)')) {
        if ($match.Groups[1].Success) { [void]$tokens.Add($match.Groups[1].Value) }
        elseif ($match.Groups[2].Success) { [void]$tokens.Add($match.Groups[2].Value) }
        else { [void]$tokens.Add($match.Groups[3].Value) }
    }
    return $tokens.ToArray()
}

# Separator TOKENS only. Because the tokenizer already swallowed quoted runs, a
# '|' inside "-k 'a|b'" is part of a token and cannot split anything here.
$script:SeparatorTokens = @('&&', '||', ';', '|', '&', "`n")

function Split-CommandSegments {
    param([string[]]$Tokens)
    $segments = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[string]
    foreach ($token in @($Tokens)) {
        if ($script:SeparatorTokens -contains $token) {
            if ($current.Count -gt 0) { [void]$segments.Add($current.ToArray()) }
            $current = New-Object System.Collections.Generic.List[string]
            continue
        }
        [void]$current.Add($token)
    }
    if ($current.Count -gt 0) { [void]$segments.Add($current.ToArray()) }
    return $segments.ToArray()
}

# Comparable program name: last path segment, launcher extension removed.
# '.\scripts\Run-Tests.ps1' -> 'run-tests.ps1', 'C:\bin\pytest.exe' -> 'pytest'.
function Get-ProgramName {
    param([string]$Token)
    $name = $Token.Replace('/', '\')
    $slash = $name.LastIndexOf('\')
    if ($slash -ge 0) { $name = $name.Substring($slash + 1) }
    $name = $name.ToLowerInvariant()
    foreach ($extension in @('.exe', '.cmd', '.bat', '.com')) {
        if ($name.EndsWith($extension)) { return $name.Substring(0, $name.Length - $extension.Length) }
    }
    return $name
}

# Programs that ARE a test run with no subcommand needed.
$script:DirectTestPrograms = @(
    'pytest', 'jest', 'vitest', 'mocha', 'phpunit', 'rspec', 'tox', 'nose2',
    'ctest', 'karma', 'jasmine', 'ava', 'pester'
)

# Programs that are a test run ONLY with the right subcommand. This is what
# keeps `npm run build`, `cargo build` and `go vet` silent.
$script:SubcommandTestPrograms = @{
    'npm'     = @('test', 't')
    'pnpm'    = @('test')
    'yarn'    = @('test')
    'bun'     = @('test')
    'dotnet'  = @('test')
    'cargo'   = @('test', 'nextest')
    'go'      = @('test')
    'mvn'     = @('test')
    'gradle'  = @('test')
    'gradlew' = @('test')
    'flutter' = @('test')
    'deno'    = @('test')
    'swift'   = @('test')
    'rake'    = @('test', 'spec')
    'make'    = @('test', 'check')
    'rspec'   = @()
}

$script:NodeRunners = @('npm', 'pnpm', 'yarn', 'bun')
$script:PythonPrograms = @('python', 'python3', 'py')
$script:PythonTestModules = @('pytest', 'unittest', 'nose2')
$script:PowerShellPrograms = @('pwsh', 'powershell')

# Does this segment already go through the bounded runner? Matched on the
# runner's FILE NAME anywhere in the segment, so any invocation style counts.
function Test-SegmentIsGuarded {
    param([string[]]$Tokens)
    foreach ($token in @($Tokens)) {
        if ((Get-ProgramName $token) -eq 'run-tests-guarded.ps1') { return $true }
    }
    return $false
}

# Returns $null when the segment is not recognisably a test command - which is
# the answer for almost everything, on purpose.
function Get-RecognizedTestCommand {
    param([string[]]$Tokens, [string[]]$ExtraFragments)
    $tokens = @($Tokens)
    if ($tokens.Count -eq 0) { return $null }

    $program = Get-ProgramName $tokens[0]
    $rest = @()
    if ($tokens.Count -gt 1) { $rest = @($tokens[1..($tokens.Count - 1)]) }
    # First non-switch argument: the subcommand, if there is one.
    $subcommand = ''
    foreach ($token in $rest) {
        if (-not $token.StartsWith('-')) { $subcommand = $token.ToLowerInvariant(); break }
    }

    $label = ''
    if ($script:DirectTestPrograms -contains $program) {
        $label = $program
    }
    elseif ($script:SubcommandTestPrograms.ContainsKey($program) -and $subcommand -ne '' -and (@($script:SubcommandTestPrograms[$program]) -contains $subcommand)) {
        $label = $program + ' ' + $subcommand
    }
    elseif (($script:NodeRunners -contains $program) -and $subcommand -eq 'run') {
        # `npm run test`, `npm run test:unit` - but not `npm run test-fixtures`.
        foreach ($token in $rest) {
            if ($token.StartsWith('-') -or $token.ToLowerInvariant() -eq 'run') { continue }
            $scriptName = $token.ToLowerInvariant()
            if ($scriptName -eq 'test' -or $scriptName.StartsWith('test:')) { $label = $program + ' run ' + $scriptName }
            break
        }
    }
    elseif ($program -eq 'npx' -or $program -eq 'pnpx' -or $program -eq 'bunx') {
        # `npx vitest run`, `npx --no-install jest` - the launcher is transparent,
        # so the decision is made on the program it is launching.
        foreach ($token in $rest) {
            if ($token.StartsWith('-')) { continue }
            $launched = Get-ProgramName $token
            if ($script:DirectTestPrograms -contains $launched) { $label = $program + ' ' + $launched }
            break
        }
    }
    elseif ($script:PythonPrograms -contains $program) {
        for ($i = 0; $i -lt $rest.Count - 1; $i++) {
            if ($rest[$i] -eq '-m' -and ($script:PythonTestModules -contains $rest[$i + 1].ToLowerInvariant())) {
                $label = $program + ' -m ' + $rest[$i + 1].ToLowerInvariant()
                break
            }
        }
    }
    elseif ($script:PowerShellPrograms -contains $program) {
        # Only a -File whose target is unmistakably a suite/runner script.
        # `-Command '<string>'` is NOT inspected: that would mean parsing a
        # shell, which this hook refuses to do.
        for ($i = 0; $i -lt $rest.Count - 1; $i++) {
            if ($rest[$i].ToLowerInvariant() -ne '-file') { continue }
            $target = Get-ProgramName $rest[$i + 1]
            if ($target -eq 'run-tests.ps1' -or $target -match '^test-[a-z0-9._-]+\.ps1$') {
                $label = $program + ' -File ' + $target
            }
            break
        }
    }

    if ($label -eq '') {
        # Project-declared extras (TEST_GUARD_EXTRA_TEST_COMMANDS). Deliberately
        # a fragment match on the joined segment - it is opt-in, per project, and
        # documented as such in .env.example.
        $segmentText = ($tokens -join ' ')
        foreach ($fragment in @($ExtraFragments)) {
            if ($segmentText.IndexOf($fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $label = $fragment
                break
            }
        }
    }
    if ($label -eq '') { return $null }

    return [pscustomobject]@{
        Label     = $label
        FilePath  = $tokens[0]
        Arguments = $rest
    }
}

# The whole command -> the first recognised RAW test segment, or a note that
# every recognised test segment is already guarded.
function Get-CommandVerdict {
    param([string[]]$Tokens, [string[]]$ExtraFragments, [string[]]$NeverGuard)
    $guardedSeen = $false
    foreach ($segment in @(Split-CommandSegments -Tokens $Tokens)) {
        $segmentTokens = @($segment)
        if ($segmentTokens.Count -eq 0) { continue }
        $segmentText = ($segmentTokens -join ' ')
        $skip = $false
        foreach ($fragment in @($NeverGuard)) {
            if ($segmentText.IndexOf($fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $skip = $true; break }
        }
        if ($skip) { continue }
        if (Test-SegmentIsGuarded -Tokens $segmentTokens) { $guardedSeen = $true; continue }
        $recognized = Get-RecognizedTestCommand -Tokens $segmentTokens -ExtraFragments $ExtraFragments
        if ($null -ne $recognized) {
            return [pscustomobject]@{ Kind = 'raw'; Command = $recognized }
        }
    }
    if ($guardedSeen) { return [pscustomobject]@{ Kind = 'guarded'; Command = $null } }
    return [pscustomobject]@{ Kind = 'none'; Command = $null }
}

# ---- the exact safe replacement -------------------------------------------

# -ArgumentsJson, never -Arguments. A `pwsh -File` caller cannot pass an
# argument list whose first element starts with '-': the -File parser reads that
# value as the NEXT PARAMETER NAME and fails with "Missing an argument for
# parameter 'Arguments'". Virtually every real test command starts with a
# switch, and the replacement below is exactly such a caller. See the parameter
# comments in Run-Tests-Guarded.ps1.
function New-GuardedInvocation {
    param(
        [string]$RunnerPath,
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$WallSeconds,
        [int]$IdleSeconds,
        [int]$HeartbeatSeconds,
        [int]$MaxMemoryMB,
        [string]$ResultPath
    )
    # The unary comma keeps a single-argument list a JSON ARRAY. Without it a
    # one-element array unrolls to a bare string and the runner rejects it.
    $json = (, @($Arguments) | ConvertTo-Json -Compress)
    if ($null -eq $json) { $json = '[]' }
    # Quoting only - the JSON is data for ConvertFrom-Json on the other side.
    $quotedJson = "'" + $json.Replace("'", "''") + "'"
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add('pwsh -NoLogo -NoProfile -File "' + $RunnerPath + '"')
    [void]$parts.Add('-FilePath "' + $FilePath + '"')
    [void]$parts.Add('-ArgumentsJson ' + $quotedJson)
    [void]$parts.Add('-TimeoutSeconds ' + $WallSeconds)
    [void]$parts.Add('-IdleTimeoutSeconds ' + $IdleSeconds)
    [void]$parts.Add('-HeartbeatSeconds ' + $HeartbeatSeconds)
    if ($MaxMemoryMB -gt 0) { [void]$parts.Add('-MaxMemoryMB ' + $MaxMemoryMB) }
    [void]$parts.Add('-ResultPath "' + $ResultPath + '"')
    return ($parts.ToArray() -join ' ')
}

# The runner is NOT shipped inside the installed hook folder, so it is located
# at runtime. When it cannot be found the gate DOWNGRADES to advice: a block
# whose replacement command does not exist would be worse than no block.
function Find-GuardedRunner {
    param([string]$ProjectRoot)
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        [void]$candidates.Add((Join-Path $ProjectRoot 'scripts\Run-Tests-Guarded.ps1'))
    }
    $walk = $PSScriptRoot
    for ($depth = 0; $depth -lt 5 -and -not [string]::IsNullOrWhiteSpace($walk); $depth++) {
        [void]$candidates.Add((Join-Path $walk 'scripts\Run-Tests-Guarded.ps1'))
        $walk = Split-Path -Parent $walk
    }
    foreach ($candidate in $candidates) {
        try { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } } catch { }
    }
    return ''
}

# ---- state -----------------------------------------------------------------

function Get-StateDirectory {
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path $root 'HookMaker\state')
}

# Reports the SAME finding only once. Without this the identical warning would
# be repeated on every event for an unchanged state.
function Test-ShouldReport {
    param([string]$StatePath, [string]$Fingerprint)
    try {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            if (([System.IO.File]::ReadAllText($StatePath)).Trim() -eq $Fingerprint) { return $false }
        }
    }
    catch { }
    try {
        $directory = Split-Path -Parent $StatePath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($StatePath, $Fingerprint, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
    return $true
}

# Hands Test-Completion-Check the one fact only this hook can know: a test
# command was seen for THIS repo state. The fingerprint is derived exactly as
# the consumer derives it (git state when available, else the lowercased cwd
# hash), so an observation made against one state can never be mistaken for
# evidence about another.
#
# WHY THERE IS NO MATCHING "active" RECORD: that record's `pid` must be a
# process the consumer can prove is alive. This hook cannot know one. At
# PreToolUse the guarded runner has not started; at PostToolUse it has already
# exited; and it runs as a child of the CLIENT, never of this hook, so its pid
# is never in scope here. A fabricated or guessed pid would be strictly worse
# than none: pids are recycled, so an unrelated live process would block
# completion forever. Only the runner knows its own pid - see the report.
function Write-ObservedRecord {
    param([string]$Path, [string]$ProjectRoot, [bool]$Guarded)
    $fingerprint = ''
    try { $fingerprint = [string](Get-RepoStateFingerprint -ProjectRoot $ProjectRoot) } catch { $fingerprint = '' }
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { $fingerprint = Get-ShortHash $ProjectRoot.ToLowerInvariant() }
    try {
        Write-JsonFileAtomic -Path $Path -Value ([pscustomobject][ordered]@{
                observedUtc = [DateTime]::UtcNow.ToString('o')
                fingerprint = $fingerprint
                guarded     = $Guarded
            })
    }
    catch { }    # coordination is best-effort: it must never break the gate
}

# ---- output (dual client) --------------------------------------------------
# Authority: hooks\Ci-Status-Check\Ci-Status-Check.ps1 lines 50-54 / 290-322.
# Claude Code exports CLAUDE_PROJECT_DIR on every hook process; Codex does not.

function Test-IsClaudeClient {
    return (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR))
}

function Write-HookJson {
    param($Payload)
    $Payload | ConvertTo-Json -Depth 6 -Compress | ForEach-Object { [Console]::Out.WriteLine($_) }
}

# A real gate decision. Claude gets the documented permissionDecision; Codex
# does not document one for PreToolUse, so it gets the documented systemMessage
# plus exit 2, which feeds stderr back as a blocking error.
function Write-Deny {
    param([string]$Message)
    if (Test-IsClaudeClient) {
        Write-HookJson @{
            hookSpecificOutput = @{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'deny'
                permissionDecisionReason = $Message
            }
            systemMessage      = $Message
        }
        exit 0
    }
    Write-HookJson @{ systemMessage = $Message }
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Write-Advisory {
    param([string]$EventName, [string]$Message)
    if (Test-IsClaudeClient) {
        if ($EventName -eq 'PreToolUse') {
            Write-HookJson @{
                hookSpecificOutput = @{
                    hookEventName            = 'PreToolUse'
                    permissionDecision       = 'allow'
                    permissionDecisionReason = $Message
                }
                systemMessage      = $Message
            }
        }
        else {
            Write-HookJson @{
                hookSpecificOutput = @{ hookEventName = $EventName; additionalContext = $Message }
                systemMessage      = $Message
            }
        }
        exit 0
    }
    Write-HookJson @{ systemMessage = $Message }
    exit 0
}

# ---- event -----------------------------------------------------------------

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ($eventName -ne 'PreToolUse' -and $eventName -ne 'PostToolUse') { exit 0 }

# The command, as data. Claude sends a string; a Codex-style shell tool may send
# an argv ARRAY, which is already tokenized and needs no parsing at all.
$toolInput = Get-Field $hookInput 'tool_input'
$rawCommand = Get-Field $toolInput 'command'
if ($null -eq $rawCommand) { $rawCommand = Get-Field $toolInput 'cmd' }
if ($null -eq $rawCommand) { exit 0 }

$tokens = @()
if ($rawCommand -is [string]) {
    if ([string]::IsNullOrWhiteSpace($rawCommand)) { exit 0 }
    $tokens = @(Split-CommandTokens -Text ([string]$rawCommand))
}
elseif ($rawCommand -is [System.Collections.IEnumerable]) {
    $tokens = @(@($rawCommand) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
}
if ($tokens.Count -eq 0) { exit 0 }

$projectRoot = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = [string]$env:CLAUDE_PROJECT_DIR }
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$wallSeconds = Get-IntSetting $config 'TEST_GUARD_WALL_TIMEOUT_SECONDS' 1800 1 86400
$idleSeconds = Get-IntSetting $config 'TEST_GUARD_IDLE_TIMEOUT_SECONDS' 300 0 86400
$heartbeatSeconds = Get-IntSetting $config 'TEST_GUARD_HEARTBEAT_SECONDS' 10 1 3600
$maxMemoryMB = Get-IntSetting $config 'TEST_GUARD_MAX_MEMORY_MB' 0 0 1048576
$maxWorkers = Get-IntSetting $config 'TEST_GUARD_MAX_WORKERS' 0 0 1024
$advisoryOnly = Get-BoolSetting $config 'TEST_GUARD_ADVISORY_ONLY' $false
$extraFragments = @(Get-ListSetting $config 'TEST_GUARD_EXTRA_TEST_COMMANDS')
$neverGuard = @(Get-ListSetting $config 'TEST_GUARD_NEVER_GUARD')

$stateDirectory = Get-StateDirectory
$projectKey = Get-ShortHash ($projectRoot.ToLowerInvariant())
$resultPath = Join-Path $stateDirectory ('TestRunGuard-result-' + $projectKey + '.json')
$observedPath = Join-Path $stateDirectory ('TestRunGuard-observed-' + $projectKey + '.json')
$reportStatePath = Join-Path $stateDirectory ('TestRunGuard-report-' + $projectKey + '.txt')
$configStatePath = Join-Path $stateDirectory ('TestRunGuard-config-' + $projectKey + '.txt')

# Invalid settings are reported once, then the defaults are used. Never a block:
# a typo in .env must not stop the agent from running anything.
$configNote = ''
if ($script:ConfigIssues.Count -gt 0) {
    $issues = 'TEST-RUN-GUARD CONFIG: ' + (@($script:ConfigIssues.ToArray()) -join '; ') + '.'
    if (Test-ShouldReport -StatePath $configStatePath -Fingerprint (Get-ShortHash $issues)) { $configNote = ' ' + $issues }
}

$verdict = Get-CommandVerdict -Tokens $tokens -ExtraFragments $extraFragments -NeverGuard $neverGuard

# ---- PreToolUse: the gate --------------------------------------------------

if ($eventName -eq 'PreToolUse') {
    # Every recognised test command is handed to Test-Completion-Check, whether
    # it is about to run guarded, run unguarded, or be blocked here. Silent -
    # this is a state handoff, not a finding.
    if ($verdict.Kind -ne 'none') {
        Write-ObservedRecord -Path $observedPath -ProjectRoot $projectRoot -Guarded ($verdict.Kind -eq 'guarded')
    }
    if ($verdict.Kind -ne 'raw') {
        # Unrelated, or already bounded. Nothing to say - and an already-guarded
        # command is never wrapped a second time.
        if ($configNote -ne '') { Write-Advisory -EventName 'PreToolUse' -Message $configNote.Trim() }
        exit 0
    }

    $runnerPath = Find-GuardedRunner -ProjectRoot $projectRoot
    if ($runnerPath -eq '') {
        Write-Advisory -EventName 'PreToolUse' -Message (
            'TEST RUN GUARD: this looks like a test command (' + $verdict.Command.Label +
            ') running with no bounded runner, but scripts\Run-Tests-Guarded.ps1 could not be located from ' +
            $projectRoot + ', so no exact replacement can be given. Run it under a bounded runner with a wall ' +
            'timeout, an idle/no-progress timeout and process-tree cleanup, or the run cannot be proven to have ' +
            'finished.' + $configNote)
    }

    $replacement = New-GuardedInvocation -RunnerPath $runnerPath -FilePath $verdict.Command.FilePath `
        -Arguments $verdict.Command.Arguments -WallSeconds $wallSeconds -IdleSeconds $idleSeconds `
        -HeartbeatSeconds $heartbeatSeconds -MaxMemoryMB $maxMemoryMB -ResultPath $resultPath

    $workerNote = ''
    if ($maxWorkers -gt 0) { $workerNote = ' Keep test workers at or below ' + $maxWorkers + ' for this project.' }

    $message = 'TEST RUN GUARD: "' + $verdict.Command.Label + '" is a test command with no bounded runner around it. ' +
    'A raw run has no wall ceiling, no no-progress ceiling and no process-tree cleanup, so a hang cannot be ' +
    'detected and cannot be proven to have been cleaned up. Run this instead (arguments are passed as data - ' +
    'nothing is re-parsed by a shell):' + "`n`n" + $replacement + "`n`n" +
    'The runner propagates the real exit code (124 when it terminated the run) and writes its structured result ' +
    'to the -ResultPath above, which this hook reads on PostToolUse.' + $workerNote + $configNote

    if ($advisoryOnly) {
        # TEST_GUARD_ADVISORY_ONLY=1: the finding still goes out, the command
        # still runs.
        Write-Advisory -EventName 'PreToolUse' -Message ('ADVISORY ONLY (TEST_GUARD_ADVISORY_ONLY=1) - ' + $message)
    }
    Write-Deny -Message $message
}

# ---- PostToolUse: the detector ---------------------------------------------

if ($verdict.Kind -eq 'none') {
    if ($configNote -ne '') { Write-Advisory -EventName 'PostToolUse' -Message $configNote.Trim() }
    exit 0
}

$result = $null
$resultAgeMinutes = [double]::MaxValue
try {
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $result = Read-JsonFile $resultPath
        $resultAgeMinutes = ([DateTime]::UtcNow - (Get-Item -LiteralPath $resultPath).LastWriteTimeUtc).TotalMinutes
    }
}
catch { $result = $null }

# ponytail: 60 minutes is a flat staleness ceiling. If a project routinely runs
# suites longer than that, derive it from TEST_GUARD_WALL_TIMEOUT_SECONDS.
$isStale = ($null -eq $result -or $resultAgeMinutes -gt 60)

if ($isStale) {
    # NEVER claims the run was fine. It says exactly what is missing.
    $reason = if ($null -eq $result) { 'no guarded result document exists at ' + $resultPath } else { 'the guarded result document is stale (last written ' + [Math]::Round($resultAgeMinutes) + ' minutes ago)' }
    $message = 'TEST RUN GUARD: a test command ran, but ' + $reason + '. There is therefore NO evidence about how ' +
    'that run ended - do not report it as passing. Re-run it through scripts\Run-Tests-Guarded.ps1 with ' +
    '-ResultPath "' + $resultPath + '" to get a verifiable result.' + $configNote
    if (Test-ShouldReport -StatePath $reportStatePath -Fingerprint (Get-ShortHash ('stale|' + $verdict.Kind + '|' + [Math]::Round($resultAgeMinutes / 10)))) {
        Write-Advisory -EventName 'PostToolUse' -Message $message
    }
    exit 0
}

$overall = [string](Get-Field $result 'overall')
$exitCode = Get-Field $result 'exitCode'
$terminateReason = [string](Get-Field $result 'terminateReason')
$terminateDetail = [string](Get-Field $result 'terminateDetail')
$lastProgress = [string](Get-Field $result 'lastProgress')
$leaked = @(Get-Field $result 'leakedProcessIds')
$elapsed = Get-Field $result 'elapsedSeconds'
$peakMemory = Get-Field $result 'peakMemoryMB'
$peakTree = Get-Field $result 'peakTreeSize'
$startedUtc = [string](Get-Field $result 'startedUtc')

$findings = New-Object System.Collections.Generic.List[string]

if ($overall -eq 'terminated') {
    $detail = if ($terminateDetail -ne '') { $terminateDetail } else { 'no detail recorded' }
    [void]$findings.Add('The run was TERMINATED by the guarded runner after ' + $elapsed + 's - reason: ' +
        $(if ($terminateReason -ne '') { $terminateReason } else { 'unknown' }) + ' (' + $detail + '). ' +
        'This is not a test failure and must not be reported as one: the suite never finished.')
    # The single most useful field when asking "where was it when it died".
    if ($lastProgress -ne '') { [void]$findings.Add('Last progress before termination: ' + $lastProgress) }
    else { [void]$findings.Add('No output was captured before termination, so the run produced no progress signal at all - suspect a hang before the first test.') }
}
elseif ($null -ne $exitCode -and [int]$exitCode -ne 0) {
    [void]$findings.Add('The run finished with exit code ' + [int]$exitCode + ' after ' + $elapsed + 's - it did NOT pass.')
    if ($lastProgress -ne '') { [void]$findings.Add('Last recorded output: ' + $lastProgress) }
}

if (@($leaked).Count -gt 0) {
    [void]$findings.Add('PROCESS LEAK: ' + (@($leaked) -join ', ') + ' survived the process-tree termination. ' +
        'Verify and stop them before continuing; a leaked worker holds ports, locks and temp files.')
}

if ($findings.Count -eq 0) { exit 0 }    # clean run - stay silent

$context = @()
if ($null -ne $peakMemory -and [double]$peakMemory -gt 0) { $context += ('peak memory ' + $peakMemory + 'MB') }
if ($null -ne $peakTree -and [int]$peakTree -gt 0) { $context += ('peak process tree ' + $peakTree) }
$contextLine = ''
if ($context.Count -gt 0) { $contextLine = ' Resource use: ' + ($context -join ', ') + '.' }

$message = 'TEST RUN GUARD (guarded run result): ' + (@($findings.ToArray()) -join ' ') + $contextLine + $configNote

# Bound to THIS run: a new run (new startedUtc) or a changed outcome reports
# again; the same unchanged result never does.
$fingerprint = Get-ShortHash ($startedUtc + '|' + $overall + '|' + [string]$exitCode + '|' + $terminateReason + '|' + (@($leaked) -join ','))
if (-not (Test-ShouldReport -StatePath $reportStatePath -Fingerprint $fingerprint)) { exit 0 }

Write-Advisory -EventName 'PostToolUse' -Message $message
