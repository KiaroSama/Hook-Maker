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
# GUIDANCE ADDITIONS (E-04, output text only - the command guard itself is
# unchanged): a recognised raw test command's deny/advisory also states the
# deep-debug/test-policy bounds the replacement already enforces (bounded
# runner, documented native timeout where supported, wall/idle, one shared
# worker ceiling, tree cleanup, exit-code propagation, no ad hoc sleeps), and -
# only when the command VISIBLY writes textual output to a file - advises
# explicit UTF-8 output using official documented syntax only (PowerShell
# -Encoding utf8, Python PYTHONUTF8/PYTHONIOENCODING); it never invents an
# encoding flag, and file validation stays with Utf8-Encoding-Check.
#
# Optional .env next to this script (copy .env.example - it documents every key
# and the defaults). An invalid value is reported ONCE in plain text and the
# default is used: a malformed setting must never make this an unconditional
# blocker, nor silently disable it.
#
# COORDINATION STATE written for Test-Completion-Check. Project key =
# Get-ShortHash(lowercased cwd), the key Test-Temp-Cleanup and Cloudflare-Deploy
# already use. Every file is PER-RUN (keyed by <projectKey>-<runId>) so two
# concurrent guarded runs in one project never overwrite each other's evidence.
#   TestRunGuard-observed-<key>-<runId>.json  { observedUtc, projectFingerprint,
#       runId, commandFingerprint, guarded }
#       "a test command happened for THIS repo state". Written on PreToolUse for
#       every recognised test command - blocked, advised, or already guarded -
#       with `guarded` recording which. This is what lets Test-Completion-Check
#       refuse a "tests passed" claim when nothing produced a result. A blocked
#       command is recorded too: the intent to test is what creates the
#       obligation to show evidence, and the re-run through the guarded runner
#       (carrying the same -RunId this hook injected) writes the paired result.
#   TestRunGuard-result-<key>-<runId>.json    written by Run-Tests-Guarded.ps1
#       itself via the per-run -ResultPath this hook puts in the replacement.
#       PostToolUse enumerates the per-run files and pairs a result to the
#       observation by run identity.
#
# TestRunGuard-active-<key>-<runId>.json { ownerPid, ... } is NOT written by this
# hook, and that is deliberate - see the note above Write-ObservedRecord. Only
# Run-Tests-Guarded.ps1 knows its own live pid; its consumer treats an absent
# file as "not evaluated", so omitting it is silent, whereas a guessed pid would
# be a false completion blocker on a recycled process id.
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

# ---- HM-06: conservative DIRECT blind-wait detection -----------------------
# A fixed "wait N seconds and hope it is ready" delay is the anti-pattern the
# during-stage exists to stop, in ad hoc tool commands as much as in committed
# tests. Detection is deliberately narrow to keep false positives near zero:
#
#  * TOP-LEVEL tokens only. The tokenizer keeps a quoted run as ONE token, so a
#    delay inside  bash -c "sleep 300"  is the single token "sleep 300", never
#    the bare keyword "sleep" - nested shell strings are therefore NEVER parsed.
#  * A literal delay is flagged only at or above the configured ceiling, so a
#    short teardown backoff (Start-Sleep -Milliseconds 200, sleep 2) passes.
#  * GNU  timeout 300 <cmd>  BOUNDS a command and is good; only the Windows delay
#    form  timeout /t N  is a blind wait.
#  * An always-true poll loop is flagged only when it also sleeps AND shows no
#    deadline/break/return/exit anywhere - any sign the author bounded it clears.
#  * A PYTHON literal sleep (`python -c "time.sleep(300)"`) is matched only in a
#    segment whose PROGRAM is python/python3/py, against the COMPLETE payload
#    token the tokenizer already produced - never by re-parsing quoting, so
#    `grep "time.sleep(300)" app.py` stays untouched.

# Parse a single literal duration token to whole seconds, or -1 if it is not a
# plain literal (a variable, an expression, anything non-numeric -> not our call).
function ConvertTo-LiteralSeconds {
    param([string]$Value, [double]$UnitSeconds = 1)
    $m = [regex]::Match(([string]$Value).Trim(), '^([0-9]+(?:\.[0-9]+)?)([smhd]?)$')
    if (-not $m.Success) { return -1 }
    $mult = switch ($m.Groups[2].Value) { 's' { 1 } 'm' { 60 } 'h' { 3600 } 'd' { 86400 } default { $UnitSeconds } }
    return [int][Math]::Floor([double]$m.Groups[1].Value * $mult)
}

function New-BlindWaitFinding {
    param([string]$Reason, [string]$SafePattern)
    return [pscustomobject]@{ Reason = $Reason; SafePattern = $SafePattern }
}

$script:BlindWaitSafeSleep = 'Wait on the real signal instead of the clock, or bound the wait with a deadline: ' +
"`n`n" + '  $deadline = [DateTime]::UtcNow.AddSeconds(<budget>)' + "`n" +
'  while ([DateTime]::UtcNow -lt $deadline) { if (<ready>) { break }; Start-Sleep -Milliseconds 200 }' + "`n`n" +
'A short bounded backoff (Start-Sleep -Milliseconds 200) INSIDE such a loop is fine - it is the fixed multi-second delay that is not.'

function Get-BlindWaitFinding {
    param([string[]]$Tokens, [int]$MaxBlindSleepSeconds)
    if ($MaxBlindSleepSeconds -le 0) { return $null }
    $t = @($Tokens)
    for ($i = 0; $i -lt $t.Count; $i++) {
        $prog = Get-ProgramName $t[$i]
        # 1) PowerShell Start-Sleep (-Seconds N, positional N, or -Milliseconds N).
        if ($prog -eq 'start-sleep') {
            $secs = -1
            for ($j = $i + 1; $j -lt $t.Count; $j++) {
                $flag = $t[$j].ToLowerInvariant()
                if (($flag -eq '-seconds' -or $flag -eq '-s') -and $j + 1 -lt $t.Count) { $secs = ConvertTo-LiteralSeconds $t[$j + 1] 1; break }
                if (($flag -eq '-milliseconds' -or $flag -eq '-ms') -and $j + 1 -lt $t.Count) { $ms = ConvertTo-LiteralSeconds $t[$j + 1] 1; if ($ms -ge 0) { $secs = [int][Math]::Floor($ms / 1000) }; break }
                if ($t[$j] -match '^[0-9]') { $secs = ConvertTo-LiteralSeconds $t[$j] 1; break }
                if (-not $t[$j].StartsWith('-')) { break }
            }
            if ($secs -ge $MaxBlindSleepSeconds) {
                return New-BlindWaitFinding -Reason ('a fixed Start-Sleep of ' + $secs + 's (>= the ' + $MaxBlindSleepSeconds + 's blind-wait ceiling) is a blind wait') -SafePattern $script:BlindWaitSafeSleep
            }
        }
        # 2) shell/coreutils sleep (sleep 300, sleep 5m).
        elseif ($prog -eq 'sleep' -and $i + 1 -lt $t.Count) {
            $secs = ConvertTo-LiteralSeconds $t[$i + 1] 1
            if ($secs -ge $MaxBlindSleepSeconds) {
                return New-BlindWaitFinding -Reason ('a fixed sleep of ' + $secs + 's (>= the ' + $MaxBlindSleepSeconds + 's blind-wait ceiling) is a blind wait') -SafePattern $script:BlindWaitSafeSleep
            }
        }
        # 3) Windows  timeout /t N  as a blind delay (GNU  timeout N <cmd>  bounds a
        #    command - the opposite - so only the /t delay form is flagged).
        elseif ($prog -eq 'timeout') {
            for ($j = $i + 1; $j -lt $t.Count; $j++) {
                if ($t[$j].ToLowerInvariant() -eq '/t' -and $j + 1 -lt $t.Count) {
                    $secs = ConvertTo-LiteralSeconds $t[$j + 1] 1
                    if ($secs -ge $MaxBlindSleepSeconds) {
                        return New-BlindWaitFinding -Reason ('timeout /t ' + $secs + ' (>= the ' + $MaxBlindSleepSeconds + 's blind-wait ceiling) is a blind delay') -SafePattern $script:BlindWaitSafeSleep
                    }
                    break
                }
            }
        }
    }
    # 4) always-true poll loop with NO visible deadline. Narrow: an always-true
    #    marker AND a sleep indicator AND no break/return/exit/deadline anywhere.
    $lowerAll = ($t -join ' ').ToLowerInvariant()
    $hasInfinite = $false
    for ($i = 0; $i -lt $t.Count; $i++) {
        $tok = $t[$i].ToLowerInvariant()
        if ($tok -eq 'while' -and $i + 1 -lt $t.Count) {
            $cond = ($t[$i + 1].ToLowerInvariant() -replace '[\s()]', '')
            if ($cond -eq '$true' -or $cond -eq 'true' -or $cond -eq '1') { $hasInfinite = $true }
        }
        if (($tok -replace '\s', '') -match '^for\(?;;\)?$') { $hasInfinite = $true }
    }
    if ($hasInfinite) {
        $hasSleep = ($lowerAll -match '\bstart-sleep\b' -or $lowerAll -match '\bsleep\b')
        $boundSignals = @('addseconds', 'addminutes', 'addhours', 'deadline', 'stopwatch', 'datetime', '-timeoutsec', '--timeout', 'maxattempts', 'attempts', 'elapsed', 'totalseconds', 'break', 'return', 'exit')
        $hasBound = $false
        foreach ($b in $boundSignals) { if ($lowerAll.Contains($b)) { $hasBound = $true; break } }
        if ($hasSleep -and -not $hasBound) {
            return New-BlindWaitFinding -Reason 'an always-true poll loop with a sleep and no visible deadline never provably ends' -SafePattern $script:BlindWaitSafeSleep
        }
    }
    # 5) PYTHON literal long sleep (`python -c "time.sleep(300)"`). The tokenizer
    #    collapsed the quoted payload into ONE token, so a regex over that complete
    #    token is NOT nested-shell parsing - no quoting is re-interpreted. Scoped
    #    per SEGMENT, and only when the segment's PROGRAM is python/python3/py, so
    #    `grep "time.sleep(300)" app.py` and `echo time.sleep(300)` never match.
    #    ($script:PythonPrograms is declared further down; script scope resolves at
    #    call time, and the only caller runs long after top-level init.)
    foreach ($segment in @(Split-CommandSegments -Tokens $t)) {
        $seg = @($segment)
        if ($seg.Count -lt 2) { continue }
        if ($script:PythonPrograms -notcontains (Get-ProgramName $seg[0])) { continue }
        for ($i = 1; $i -lt $seg.Count; $i++) {
            # The literal may sit inside a larger payload token
            # (`import time; time.sleep(300)`) - every occurrence is checked.
            foreach ($m in [regex]::Matches($seg[$i], 'time\.sleep\(\s*([0-9]+(?:\.[0-9]+)?)\s*\)')) {
                $secs = [int][Math]::Floor([double]$m.Groups[1].Value)
                if ($secs -ge $MaxBlindSleepSeconds) {
                    return New-BlindWaitFinding -Reason ('a literal python time.sleep(' + $secs + ') (>= the ' + $MaxBlindSleepSeconds + 's blind-wait ceiling) is a blind wait') -SafePattern $script:BlindWaitSafeSleep
                }
            }
        }
    }
    return $null
}

# ---- run identity (must match Run-Tests-Guarded.ps1 byte-for-byte) ----------
# SHA-256 prefix over the executable + argument ARRAY, NUL-joined, exe lowercased.
# The observing hook and the runner both derive it this way so "what ran" has one
# canonical id. This is the SAME algorithm as Run-Tests-Guarded.ps1's
# Get-CommandFingerprint - keep the two in lockstep.
function Get-CommandFingerprint {
    param([string]$ExecutablePath, [string[]]$ArgumentList)
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add(([string]$ExecutablePath).ToLowerInvariant())
    foreach ($a in @($ArgumentList)) { [void]$parts.Add([string]$a) }
    $joined = ($parts.ToArray() -join "`0")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 32)
    }
    finally { $sha.Dispose() }
}

# Filename-safe form of a runId (must match Run-Tests-Guarded.ps1's Get-SafeRunId
# byte-for-byte): lowercased, non [a-z0-9] stripped. This is what turns the runId
# into the per-run suffix of the coordination filenames, so two runs in one
# project never share a state file.
function Get-SafeRunId {
    param([string]$RunId)
    $safe = ([string]$RunId).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($safe -eq '') { $safe = Get-ShortHash ([string]$RunId) }
    return $safe
}

# Pulls the identity + the INNER executable/arguments back out of an
# already-guarded command line (`... Run-Tests-Guarded.ps1 -FilePath X
# -ArgumentsJson [...] -RunId R -ProjectFingerprint F ...`). Used so the observed
# record for a guarded run carries the SAME command fingerprint the runner will
# compute, and preserves an injected runId instead of minting a fresh one that
# could never match. A value-taking switch reads the following token.
function Get-GuardedInvocationIdentity {
    param([string[]]$Tokens)
    $t = @($Tokens)
    $runId = ''; $projFp = ''; $filePath = ''; $argsJson = ''
    for ($i = 0; $i -lt $t.Count - 1; $i++) {
        switch ($t[$i].ToLowerInvariant()) {
            '-runid' { $runId = $t[$i + 1] }
            '-projectfingerprint' { $projFp = $t[$i + 1] }
            '-filepath' { $filePath = $t[$i + 1] }
            '-argumentsjson' { $argsJson = $t[$i + 1] }
        }
    }
    $innerArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($argsJson)) {
        try {
            $parsed = $argsJson | ConvertFrom-Json
            if ($null -ne $parsed -and -not ($parsed -is [string])) { $innerArgs = @(@($parsed) | ForEach-Object { [string]$_ }) }
        }
        catch { }
    }
    $commandFp = ''
    if (-not [string]::IsNullOrWhiteSpace($filePath)) { $commandFp = Get-CommandFingerprint -ExecutablePath $filePath -ArgumentList $innerArgs }
    return [pscustomobject]@{ RunId = $runId; ProjectFingerprint = $projFp; CommandFingerprint = $commandFp }
}

# Parse a JSON UTC timestamp to a real UTC DateTime (same reasoning as
# Test-Completion-Check's ConvertTo-UtcTime: an Unspecified Kind is UTC here, and
# double-converting it would fabricate a many-hour drift).
function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { $p = $Value }
    else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $p = [datetime]::MinValue
        if (-not [datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$p)) { return $null }
    }
    if ($p.Kind -eq [System.DateTimeKind]::Utc) { return $p }
    if ($p.Kind -eq [System.DateTimeKind]::Local) { return $p.ToUniversalTime() }
    return [System.DateTime]::SpecifyKind($p, [System.DateTimeKind]::Utc)
}

# The exact run-identity gate, shared in spirit with Test-Completion-Check. A
# result is evidence for the current observation ONLY when its command and
# project fingerprints match the observed record AND the current state, its
# start is not before the observation, its end is not before its start, its
# required fields are present, and - when this hook controlled the runId - the
# runId matches. A fresh result for a different run/command/state is NOT evidence.
function Test-ResultMatchesObserved {
    param($Result, $Observed, [string]$CurrentStateFingerprint)
    if ($null -eq $Result -or $null -eq $Observed) { return $false }
    $rCmdFp = [string](Get-Field $Result 'commandFingerprint')
    $rProjFp = [string](Get-Field $Result 'projectFingerprint')
    $rRunId = [string](Get-Field $Result 'runId')
    $rStarted = ConvertTo-UtcDate (Get-Field $Result 'startedUtc')
    $rEnded = ConvertTo-UtcDate (Get-Field $Result 'endedUtc')
    if ([string]::IsNullOrWhiteSpace($rCmdFp) -or [string]::IsNullOrWhiteSpace($rProjFp) -or $null -eq $rStarted -or $null -eq $rEnded) { return $false }
    $oCmdFp = [string](Get-Field $Observed 'commandFingerprint')
    $oProjFp = [string](Get-Field $Observed 'projectFingerprint')
    if ([string]::IsNullOrWhiteSpace($oProjFp)) { $oProjFp = [string](Get-Field $Observed 'fingerprint') }
    $oRunId = [string](Get-Field $Observed 'runId')
    $oControlled = ((Get-Field $Observed 'runIdControlled') -eq $true)
    $oObserved = ConvertTo-UtcDate (Get-Field $Observed 'observedUtc')
    if ($rCmdFp -ne $oCmdFp) { return $false }
    if ($rProjFp -ne $oProjFp) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($CurrentStateFingerprint) -and $rProjFp -ne $CurrentStateFingerprint) { return $false }
    if ($null -ne $oObserved -and $rStarted -lt $oObserved.AddSeconds(-2)) { return $false }
    if ($rEnded -lt $rStarted.AddSeconds(-2)) { return $false }
    if ($oControlled -and $rRunId -ne $oRunId) { return $false }
    return $true
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

    # Direct PowerShell test-script execution, with no `pwsh -File` wrapper:
    # `.\scripts\Test-Wizard.ps1`, `./scripts/Run-Tests.ps1`, an absolute path
    # ending in the same, a quoted path (the tokenizer already unquoted it), and
    # the call-operator form `& ".\scripts\Test-RulesCheck.ps1"` (Split-Command-
    # Segments treats `&` as a separator, so that segment arrives here as just the
    # script path). Recognised ONLY when the leaf is EXACTLY run-tests.ps1 or
    # matches Test-<safe>.ps1 - Get-ProgramName keeps the .ps1 extension, so a
    # bare program named "test-foo" (no .ps1) and a path merely CONTAINING "test"
    # (generate-test-fixtures.ps1, contest.ps1, testdata\x.ps1) never match.
    # A .ps1 cannot be launched directly by ProcessStartInfo, so it is normalised
    # to `pwsh -NoLogo -NoProfile -File <script> <original args>`, exactly the
    # shape the guarded runner and the fingerprint both consume.
    if ($label -eq '') {
        $leaf = Get-ProgramName $tokens[0]
        if ($leaf -eq 'run-tests.ps1' -or $leaf -match '^test-[a-z0-9._-]+\.ps1$') {
            return [pscustomobject]@{
                Label     = $leaf
                FilePath  = 'pwsh'
                Arguments = @('-NoLogo', '-NoProfile', '-File', $tokens[0]) + $rest
            }
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
        [int]$MaxWorkers,
        [string]$ResultPath,
        [string]$RunId,
        [string]$ProjectFingerprint
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
    # The resolved worker ceiling, passed as DATA. The runner folds it through its
    # own budget (local formula + ambient HOOKMAKER_MAX_TEST_WORKERS) so it can only
    # tighten, then exports the result to the child. Omitted at 0 = no cap.
    if ($MaxWorkers -gt 0) { [void]$parts.Add('-MaxWorkers ' + $MaxWorkers) }
    # The run-identity contract: the runId this hook just observed and the
    # repository fingerprint, passed as DATA so the runner echoes them into its
    # result and the consumer can prove that result belongs to THIS observation.
    if (-not [string]::IsNullOrWhiteSpace($RunId)) { [void]$parts.Add('-RunId ' + $RunId) }
    if (-not [string]::IsNullOrWhiteSpace($ProjectFingerprint)) { [void]$parts.Add('-ProjectFingerprint ' + $ProjectFingerprint) }
    [void]$parts.Add('-ResultPath "' + $ResultPath + '"')
    return ($parts.ToArray() -join ' ')
}

# A candidate is the guarded runner ONLY when it carries the contract marker
# Run-Tests-Guarded.ps1 ships. This stops an unrelated script that merely shares
# the name from being handed to the model as the bounded runner. Bounded read
# (the real runner is tiny); an oversized file or a read failure is skipped.
$script:GuardedRunnerMarker = 'HookMaker-Guarded-Runner-Contract'
function Test-GuardedRunnerMarker {
    param([string]$Path)
    try {
        if ((Get-Item -LiteralPath $Path -Force).Length -gt 1MB) { return $false }
        return ([System.IO.File]::ReadAllText($Path)).Contains($script:GuardedRunnerMarker)
    }
    catch { return $false }
}

# The runner is located at runtime. PRECEDENCE (install-plan contract): the
# MANAGED runner shipped beside this hook wins - the $PSScriptRoot upward walk,
# depth 0 = <hookdir>\scripts\Run-Tests-Guarded.ps1. The project's own
# <ProjectRoot>\scripts\Run-Tests-Guarded.ps1 is only a FALLBACK, so a stale or
# foreign project copy can never shadow the shipped one. Every candidate must
# carry the contract marker or it is skipped. When none is found the gate
# DOWNGRADES to advice: a block whose replacement command does not exist would be
# worse than no block.
function Find-GuardedRunner {
    param([string]$ProjectRoot)
    $candidates = New-Object System.Collections.Generic.List[string]
    $walk = $PSScriptRoot
    for ($depth = 0; $depth -lt 5 -and -not [string]::IsNullOrWhiteSpace($walk); $depth++) {
        [void]$candidates.Add((Join-Path $walk 'scripts\Run-Tests-Guarded.ps1'))
        $walk = Split-Path -Parent $walk
    }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        [void]$candidates.Add((Join-Path $ProjectRoot 'scripts\Run-Tests-Guarded.ps1'))
    }
    foreach ($candidate in $candidates) {
        try {
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-GuardedRunnerMarker -Path $candidate)) { return $candidate }
        }
        catch { }
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
#
# The record now carries the full run-identity contract (schema 2): the runId
# minted (raw) or preserved (guarded), whether this hook CONTROLS that runId
# (a raw run whose replacement injects it -> yes; a guarded run typed directly
# without -RunId -> no, so the consumer binds on command+project+time instead),
# the command fingerprint the runner will independently recompute, and the
# repository fingerprint. This is what lets the consumer reject a stale result
# from an earlier run/command/state instead of trusting file age.
function Get-StateFingerprintFor {
    param([string]$ProjectRoot)
    $fingerprint = ''
    try { $fingerprint = [string](Get-RepoStateFingerprint -ProjectRoot $ProjectRoot) } catch { $fingerprint = '' }
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { $fingerprint = Get-ShortHash $ProjectRoot.ToLowerInvariant() }
    return $fingerprint
}
function Write-ObservedRecord {
    param(
        [string]$Path, [string]$ProjectRoot, [bool]$Guarded,
        [string]$RunId, [bool]$RunIdControlled, [string]$CommandFingerprint, [string]$ProjectFingerprint
    )
    if ([string]::IsNullOrWhiteSpace($ProjectFingerprint)) { $ProjectFingerprint = Get-StateFingerprintFor -ProjectRoot $ProjectRoot }
    try {
        Write-JsonFileAtomic -Path $Path -Value ([pscustomobject][ordered]@{
                schema             = 2
                observedUtc        = [DateTime]::UtcNow.ToString('o')
                fingerprint        = $ProjectFingerprint
                projectFingerprint = $ProjectFingerprint
                runId              = $RunId
                runIdControlled    = $RunIdControlled
                commandFingerprint = $CommandFingerprint
                guarded            = $Guarded
            })
    }
    catch { }    # coordination is best-effort: it must never break the gate
}

# ---- per-run state file addressing ----------------------------------------
# Every coordination file is TestRunGuard-<kind>-<projectKey>-<runId>.json.
function Get-PerRunStatePath {
    param([string]$StateDirectory, [string]$Kind, [string]$ProjectKey, [string]$RunId)
    return (Join-Path $StateDirectory ('TestRunGuard-' + $Kind + '-' + $ProjectKey + '-' + (Get-SafeRunId $RunId) + '.json'))
}

# All per-run files for one kind, plus a legacy non-suffixed file if a run from an
# older build is still in flight. Each entry carries the parsed document and the
# file's age in minutes (age is by file write time - the same signal the single-
# file path used, so a test that back-dates a result still reads as stale).
function Get-PerRunStateEntries {
    param([string]$StateDirectory, [string]$Kind, [string]$ProjectKey)
    $entries = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($StateDirectory) -or -not (Test-Path -LiteralPath $StateDirectory -PathType Container)) { return @() }
    $files = New-Object System.Collections.Generic.List[object]
    try { foreach ($f in @(Get-ChildItem -LiteralPath $StateDirectory -Filter ('TestRunGuard-' + $Kind + '-' + $ProjectKey + '-*.json') -File -ErrorAction SilentlyContinue)) { [void]$files.Add($f) } } catch { }
    $legacy = Join-Path $StateDirectory ('TestRunGuard-' + $Kind + '-' + $ProjectKey + '.json')
    try { if (Test-Path -LiteralPath $legacy -PathType Leaf) { [void]$files.Add((Get-Item -LiteralPath $legacy -Force)) } } catch { }
    foreach ($file in $files) {
        $doc = $null
        try { $doc = Read-JsonFile $file.FullName } catch { $doc = $null }
        if ($null -eq $doc) { continue }
        $age = [double]::MaxValue
        try { $age = ([DateTime]::UtcNow - $file.LastWriteTimeUtc).TotalMinutes } catch { }
        [void]$entries.Add([pscustomobject]@{ Doc = $doc; Path = $file.FullName; AgeMinutes = $age })
    }
    return @($entries.ToArray())
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
# A fixed literal delay at or above this many seconds in a DIRECT tool command is
# treated as a blind wait (0 disables the check). Short backoffs stay below it.
$maxBlindSleepSeconds = Get-IntSetting $config 'TEST_GUARD_MAX_BLIND_SLEEP_SECONDS' 30 0 86400
$advisoryOnly = Get-BoolSetting $config 'TEST_GUARD_ADVISORY_ONLY' $false
$extraFragments = @(Get-ListSetting $config 'TEST_GUARD_EXTRA_TEST_COMMANDS')
$neverGuard = @(Get-ListSetting $config 'TEST_GUARD_NEVER_GUARD')

$stateDirectory = Get-StateDirectory
$projectKey = Get-ShortHash ($projectRoot.ToLowerInvariant())
# result/observed are now PER-RUN (TestRunGuard-<kind>-<key>-<runId>.json) so two
# runs in one project never overwrite each other. The exact per-run path is built
# where the runId is known (PreToolUse) or discovered by enumeration (PostToolUse).
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
    # HM-06: a DIRECT ad hoc blind wait is caught before anything else - it is not a
    # test command, it is a timing anti-pattern in the tool command itself. On a
    # confirmed finding the command is DENIED with an exact safe pattern (a
    # deadline-bounded readiness check), or advised-not-blocked under
    # TEST_GUARD_ADVISORY_ONLY. Both emitters exit; nothing here re-parses a shell.
    $blindWait = Get-BlindWaitFinding -Tokens $tokens -MaxBlindSleepSeconds $maxBlindSleepSeconds
    if ($null -ne $blindWait) {
        $blindMsg = 'TEST RUN GUARD: ' + $blindWait.Reason + '. ' + $blindWait.SafePattern + $configNote
        if ($advisoryOnly) { Write-Advisory -EventName 'PreToolUse' -Message ('ADVISORY ONLY (TEST_GUARD_ADVISORY_ONLY=1) - ' + $blindMsg) }
        Write-Deny -Message $blindMsg
    }

    $stateFingerprint = Get-StateFingerprintFor -ProjectRoot $projectRoot
    # Every recognised test command is handed to Test-Completion-Check, whether
    # it is about to run guarded, run unguarded, or be blocked here. Silent -
    # this is a state handoff, not a finding. The observed record carries the run
    # identity so the consumer can bind a later result to THIS observation.
    $resultPath = ''
    if ($verdict.Kind -eq 'raw') {
        # A fresh, hook-controlled runId: it is injected into the replacement, so
        # only the result of THAT exact run can match. Both the observed record and
        # the -ResultPath handed to the runner are keyed by it, so concurrent runs
        # in one project never collide.
        $runId = [guid]::NewGuid().ToString('N')
        $observedPath = Get-PerRunStatePath -StateDirectory $stateDirectory -Kind 'observed' -ProjectKey $projectKey -RunId $runId
        $resultPath = Get-PerRunStatePath -StateDirectory $stateDirectory -Kind 'result' -ProjectKey $projectKey -RunId $runId
        $commandFp = Get-CommandFingerprint -ExecutablePath $verdict.Command.FilePath -ArgumentList $verdict.Command.Arguments
        Write-ObservedRecord -Path $observedPath -ProjectRoot $projectRoot -Guarded $false `
            -RunId $runId -RunIdControlled $true -CommandFingerprint $commandFp -ProjectFingerprint $stateFingerprint
    }
    elseif ($verdict.Kind -eq 'guarded') {
        # Already guarded. Recover the identity the invocation carries: if it was
        # OUR replacement it has -RunId/-ProjectFingerprint and the inner command,
        # so the observed record matches what the runner will write. A guarded
        # command typed directly (no -RunId) cannot be bound by runId - mark it
        # uncontrolled so the consumer binds on command+project+time instead.
        $identity = Get-GuardedInvocationIdentity -Tokens $tokens
        $runIdControlled = -not [string]::IsNullOrWhiteSpace($identity.RunId)
        $runId = if ($runIdControlled) { $identity.RunId } else { [guid]::NewGuid().ToString('N') }
        $observedPath = Get-PerRunStatePath -StateDirectory $stateDirectory -Kind 'observed' -ProjectKey $projectKey -RunId $runId
        $projFp = if (-not [string]::IsNullOrWhiteSpace($identity.ProjectFingerprint)) { $identity.ProjectFingerprint } else { $stateFingerprint }
        Write-ObservedRecord -Path $observedPath -ProjectRoot $projectRoot -Guarded $true `
            -RunId $runId -RunIdControlled $runIdControlled -CommandFingerprint $identity.CommandFingerprint -ProjectFingerprint $projFp
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
        -HeartbeatSeconds $heartbeatSeconds -MaxMemoryMB $maxMemoryMB -MaxWorkers $maxWorkers -ResultPath $resultPath `
        -RunId $runId -ProjectFingerprint $stateFingerprint

    # The cap now travels with the replacement: -MaxWorkers reaches the runner,
    # which exports the resolved ceiling as HOOKMAKER_MAX_TEST_WORKERS so an
    # env-aware runner (this repo's scripts\Run-Tests.ps1) clamps itself to it.
    # We do NOT rewrite the recognised command's own worker flag: every framework
    # spells it differently (pytest -n, jest --maxWorkers, vitest --maxThreads,
    # go -p, cargo -j, dotnet -m, -ThrottleLimit) and the command that actually
    # oversubscribes usually carries no worker flag at all - it auto-detects. So
    # for a framework that does NOT read the variable this stays advice; the note
    # tells the model to pass that framework's own flag.
    $workerNote = ''
    if ($maxWorkers -gt 0) {
        $workerNote = ' The runner caps env-aware test workers at ' + $maxWorkers +
        ' (exported as HOOKMAKER_MAX_TEST_WORKERS). For a framework that ignores that variable, pass its own' +
        ' worker flag at or below ' + $maxWorkers + '.'
    }

    # E-04: one concise line naming the deep-debug/test-policy requirements the
    # replacement already enforces, so the model can verify instead of re-derive.
    # Guidance only - the command guard above is unchanged.
    $ddNote = ' Deep-debug/test-policy bounds this replacement already covers: bounded runner, outer wall + idle' +
    ' ceilings, one shared worker ceiling, process-tree cleanup, real exit-code propagation, no ad hoc sleeps.' +
    ' Where the framework documents its OWN native timeout flag, pass that too - never a guessed one.'

    # E-04: maintained-textual-output advisory. Fires ONLY when the raw command
    # VISIBLY writes output to a file (a standalone top-level '>'/'>>' token with
    # a non-null target, or an Out-File/Set-Content/Tee-Object/tee token). The
    # advice names ONLY official documented syntax (PowerShell -Encoding utf8;
    # Python's PYTHONUTF8/PYTHONIOENCODING env vars) and never invents an
    # encoding flag for an arbitrary tool - file validation itself belongs to
    # Utf8-Encoding-Check, not this hook.
    $utf8Note = ''
    for ($ti = 0; $ti -lt $tokens.Count; $ti++) {
        $tok = [string]$tokens[$ti]
        $tokLower = $tok.ToLowerInvariant()
        $isFileRedirect = $false
        if (($tok -eq '>' -or $tok -eq '>>') -and $ti + 1 -lt $tokens.Count) {
            $target = ([string]$tokens[$ti + 1]).ToLowerInvariant()
            if ($target -ne '$null' -and $target -ne 'nul' -and $target -ne '/dev/null') { $isFileRedirect = $true }
        }
        elseif ($tokLower -in @('out-file', 'set-content', 'tee-object', 'tee')) { $isFileRedirect = $true }
        if ($isFileRedirect) {
            $utf8Note = ' This command also WRITES textual output to a file: if that file is maintained project text,' +
            ' make the encoding explicitly UTF-8 using the tool''s OFFICIAL syntax only (PowerShell: Out-File/' +
            'Set-Content -Encoding utf8; Python tools: PYTHONUTF8=1 or PYTHONIOENCODING=utf-8). Never invent an' +
            ' encoding flag a tool does not document; Utf8-Encoding-Check validates the files themselves.'
            break
        }
    }

    $message = 'TEST RUN GUARD: "' + $verdict.Command.Label + '" is a test command with no bounded runner around it. ' +
    'A raw run has no wall ceiling, no no-progress ceiling and no process-tree cleanup, so a hang cannot be ' +
    'detected and cannot be proven to have been cleaned up. Run this instead (arguments are passed as data - ' +
    'nothing is re-parsed by a shell):' + "`n`n" + $replacement + "`n`n" +
    'The runner propagates the real exit code (124 when it terminated the run) and writes its structured result ' +
    'to the -ResultPath above, which this hook reads on PostToolUse.' + $workerNote + $ddNote + $utf8Note + $configNote

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

# Discover THIS run's result among the PER-RUN files. What ran is what we see: a
# guarded invocation carries its runId (and inner command fingerprint); a raw
# command carries neither, so we bind through the observed record written for it
# at PreToolUse. Identity FIRST, age only after - a result whose runId/command/
# project fingerprint does not match the observation, or which started before it,
# is from a DIFFERENT run and is not evidence, however fresh its file is.
$stateFingerprint = Get-StateFingerprintFor -ProjectRoot $projectRoot
$thisRunId = ''
$thisCommandFp = ''
if ($verdict.Kind -eq 'guarded') {
    $identity = Get-GuardedInvocationIdentity -Tokens $tokens
    $thisRunId = [string]$identity.RunId
    $thisCommandFp = [string]$identity.CommandFingerprint
}
elseif ($verdict.Kind -eq 'raw') {
    $thisCommandFp = Get-CommandFingerprint -ExecutablePath $verdict.Command.FilePath -ArgumentList $verdict.Command.Arguments
}

$observedEntries = Get-PerRunStateEntries -StateDirectory $stateDirectory -Kind 'observed' -ProjectKey $projectKey
$resultEntries = Get-PerRunStateEntries -StateDirectory $stateDirectory -Kind 'result' -ProjectKey $projectKey

# The observed record for THIS run: an exact runId match (guarded with -RunId)
# first, else the newest current-state observation whose command matches.
$observed = $null
if ($thisRunId -ne '') {
    $byRun = @($observedEntries | Where-Object { [string](Get-Field $_.Doc 'runId') -eq $thisRunId })
    if ($byRun.Count -gt 0) { $observed = $byRun[0].Doc }
}
if ($null -eq $observed -and $thisCommandFp -ne '') {
    $byCmd = @($observedEntries | Where-Object {
            if (([string](Get-Field $_.Doc 'commandFingerprint')) -ne $thisCommandFp) { return $false }
            $oFp = [string](Get-Field $_.Doc 'projectFingerprint')
            if ([string]::IsNullOrWhiteSpace($oFp)) { $oFp = [string](Get-Field $_.Doc 'fingerprint') }
            return ($oFp -eq $stateFingerprint)
        } | Sort-Object { [string](Get-Field $_.Doc 'observedUtc') } -Descending)
    if ($byCmd.Count -gt 0) { $observed = $byCmd[0].Doc }
}

# The result: the one that matches the observation by identity; if none matches
# but a result exists for the SAME command, keep it so we can say DIFFERENT run
# rather than pretend nothing ran; with no observation at all fall back to the
# newest result (a legacy/unrecognised flow).
$result = $null
$resultAgeMinutes = [double]::MaxValue
if ($null -ne $observed) {
    $paired = @($resultEntries | Where-Object { Test-ResultMatchesObserved -Result $_.Doc -Observed $observed -CurrentStateFingerprint $stateFingerprint } | Sort-Object AgeMinutes)
    if ($paired.Count -gt 0) { $result = $paired[0].Doc; $resultAgeMinutes = $paired[0].AgeMinutes }
    elseif ($thisCommandFp -ne '') {
        $sameCmd = @($resultEntries | Where-Object { ([string](Get-Field $_.Doc 'commandFingerprint')) -eq $thisCommandFp } | Sort-Object AgeMinutes)
        if ($sameCmd.Count -gt 0) { $result = $sameCmd[0].Doc; $resultAgeMinutes = $sameCmd[0].AgeMinutes }
    }
}
else {
    $newest = @($resultEntries | Sort-Object AgeMinutes)
    if ($newest.Count -gt 0) { $result = $newest[0].Doc; $resultAgeMinutes = $newest[0].AgeMinutes }
}

$identityMatches = $true
if ($null -ne $observed) {
    $identityMatches = (Test-ResultMatchesObserved -Result $result -Observed $observed -CurrentStateFingerprint $stateFingerprint)
}
$isStale = ($null -eq $result -or -not $identityMatches -or $resultAgeMinutes -gt 60)

if ($isStale) {
    # NEVER claims the run was fine. It says exactly what is missing.
    $reason = if ($null -eq $result) { 'no guarded result document exists for it' }
    elseif (-not $identityMatches) { 'the only guarded result on record is for a DIFFERENT run, command, or repository state (its run identity does not match this observation), so it says nothing about how THIS run ended' }
    else { 'the guarded result document is stale (last written ' + [Math]::Round($resultAgeMinutes) + ' minutes ago)' }
    $message = 'TEST RUN GUARD: a test command ran, but ' + $reason + '. There is therefore NO evidence about how ' +
    'that run ended - do not report it as passing. Re-run it through scripts\Run-Tests-Guarded.ps1 (the Test-Run-Guard ' +
    'gate supplies the exact bounded command with a per-run -ResultPath) to get a verifiable result.' + $configNote
    if (Test-ShouldReport -StatePath $reportStatePath -Fingerprint (Get-ShortHash ('stale|' + $verdict.Kind + '|' + [string]$identityMatches + '|' + [Math]::Round($resultAgeMinutes / 10)))) {
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
