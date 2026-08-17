# Test-Run-Guard: COMMAND ANALYSIS AND RUN IDENTITY.
#
# Everything this hook derives from a command STRING and nothing else - it reads
# no state, touches no disk beyond locating the guarded runner, and executes
# nothing. Tokenizing and segmenting a shell command, naming its program,
# spotting a blind fixed wait, deciding whether a segment is already guarded,
# recognizing a test command, reaching a verdict, building the exact safe
# replacement invocation, and the run-identity fingerprints that both this hook
# and Run-Tests-Guarded.ps1 must derive identically.
#
# Kept together because they form one pipeline over the same input and because
# separating "parse" from "decide" would split a contract that is only correct
# as a whole. The state layer, the two event handlers and the output shapes stay
# in Test-Run-Guard.ps1.
#
# Dot-sourced by Test-Run-Guard.ps1 via $PSScriptRoot, which resolves the same
# way in this repository and in an installed runtime directory.

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
#
# Redirections end the command's ARGUMENTS exactly as a pipe does, and they were
# missing: '|' was recognised but '2>&1' was not, so
#   python -m pytest tests/x.py -q 2>&1 | tail -3
# produced ["-m","pytest","tests/x.py","-q","2>&1"] and the replacement this hook
# prints died with `file or directory not found: 2>&1`. Every redirection form
# leaked the same way, operand included: '>' out.txt, '2>' err.txt, '>>' log.txt.
# The runner captures both streams itself, so a shell redirection has nothing to
# express here anyway - dropping it is what makes the suggestion runnable.
# Reported from real use.
$script:SeparatorTokens = @('&&', '||', ';', '|', '&', "`n",
    '>', '>>', '<', '2>', '2>>', '2>&1', '1>', '1>>', '&>', '&>>', '>&', '3>', '*>', '*>&1')

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
# An identity token is only usable if it was LITERALLY readable in the command.
#
# The command arrives as text, before any shell has expanded it, so `-RunId
# "$RUNID"` yields the four characters '$RUNID' - not the value. Recording that
# as the run's identity claims a control this hook never had: the runner receives
# the expanded GUID and writes it into the result, so observation and result can
# never pair, and the completion gate stays unsatisfiable for ever.
#
# Real ids are hex/GUID-shaped. Anything carrying a shell's expansion syntax
# ($, %, backtick, parentheses) fails this and is treated as absent, which makes
# the run UNCONTROLLED - and an uncontrolled run is matched on its command
# fingerprint instead, which is exactly the honest fallback.
function Test-LiteralIdentityToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match '^[A-Za-z0-9._-]+$')
}

function Get-GuardedInvocationIdentity {
    param([string[]]$Tokens)
    $t = @($Tokens)
    $runId = ''; $projFp = ''; $filePath = ''; $argsJson = ''
    for ($i = 0; $i -lt $t.Count - 1; $i++) {
        switch ($t[$i].ToLowerInvariant()) {
            '-runid' { if (Test-LiteralIdentityToken $t[$i + 1]) { $runId = $t[$i + 1] } }
            '-projectfingerprint' { if (Test-LiteralIdentityToken $t[$i + 1]) { $projFp = $t[$i + 1] } }
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
# The guarded runner counts as INVOKED, never merely MENTIONED.
#
# This used to scan every token, so `grep -n "x" scripts\Run-Tests-Guarded.ps1`
# - which only reads the file - was indistinguishable from actually running it.
# The segment was then recorded as an observed guarded run, and because no run
# ever happened, no result document could ever appear: Test-Completion-Check
# blocked with "a test command was observed ... but no guarded result document
# exists for it", and nothing the agent did could clear it except an unrelated
# real test run. Reading a file about the runner is not a test run.
#
# An invocation is the runner as the segment's own program, or as the -File
# target of a PowerShell host. Anything else is an argument to some other
# program. '-file' is matched EXACTLY, the same spelling Get-RecognizedTestCommand
# below requires: these two must agree about what a -File target is, and no
# caller here writes the abbreviated form.
function Test-SegmentIsGuarded {
    param([string[]]$Tokens)
    $tokens = @($Tokens)
    if ($tokens.Count -eq 0) { return $false }
    if ((Get-ProgramName $tokens[0]) -eq 'run-tests-guarded.ps1') { return $true }
    if ($script:PowerShellPrograms -contains (Get-ProgramName $tokens[0])) {
        for ($i = 1; $i -lt $tokens.Count - 1; $i++) {
            if ($tokens[$i].ToLowerInvariant() -ne '-file') { continue }
            if ((Get-ProgramName $tokens[$i + 1]) -eq 'run-tests-guarded.ps1') { return $true }
        }
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
    # -InputObject with a typed [string[]], NOT a piped unary comma.
    #
    # The comma form was host-dependent, and this hook runs under whichever host
    # the client registered - by default powershell.exe, i.e. 5.1:
    #   pwsh 7 : , @('-m','pytest') | ConvertTo-Json  ->  ["-m","pytest"]
    #   5.1    : same expression                      ->  {"value":["-m","pytest"],"Count":2}
    # 5.1 wraps the comma-built array in a PSObject and serializes the WRAPPER's
    # value/Count properties. The runner then refuses its own suggested command
    # with "-ArgumentsJson must be a JSON ARRAY" - so on a 5.1-hosted install the
    # replacement this hook prints could never work, for any argument count.
    #
    # -InputObject passes the array as ONE argument, so nothing enumerates and no
    # wrapper is introduced; the [string[]] cast keeps a single element an array.
    # Verified on both hosts for 0, 1, 2 and space-bearing arguments.
    $json = ConvertTo-Json -InputObject ([string[]]@($Arguments)) -Compress
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

