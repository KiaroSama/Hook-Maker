# Test-Run-Guard\_visibility.ps1 - WOULD THIS TEST COMMAND OPEN A WINDOW?
#
# Silent Execution (global-test-rules.md, 2026-09-19): everything the agent
# starts runs out of the user's sight - no console window, no GUI window, no
# taskbar entry, no focus steal. Run-Tests-Guarded.ps1 already sets
# CreateNoWindow, so a guarded run is silent today. The gap this file closes is
# DETECTION: nothing told the agent that the INVOCATION it was about to use
# would pop a window regardless of what the runner does inside it.
#
# WHY A SEPARATE FILE. _commandanalysis.ps1 is 752 lines. The architecture rule
# closes a file at about 700 and forbids growing one past 800, so the third
# recognition concern gets its own file rather than being wedged into the two
# that are already there.
#
# THE BOUNDARY, unchanged from the rest of this hook: a command is refused only
# when the visible form is UNMISTAKABLE. Anything ambiguous produces nothing -
# no refusal, and no rewrite. The hook has never guessed a framework flag and
# does not start here.
#
# TOKENS, NEVER SUBSTRINGS. Every match below is against a whole token from the
# parsed command, so `pytest -k "start the server"` does not match the `start`
# launcher and `--filter=headless` does not match the headed flag. A substring
# search over the raw command line would fire on both.

# An explicitly headed flag. Each of these is a deliberate, single-purpose
# request for a visible browser - none of them has an innocent reading.
$script:VisibleHeadedTokens = @('--headed', '--no-headless', 'pwdebug=1', 'headless=0')

# Programs whose entire job is to open a new window for something else to run
# in. `start` and `cmd /c start` detach into a new console by definition.
$script:VisibleLauncherPrograms = @('start', 'wt', 'wt.exe', 'conhost', 'conhost.exe')

function Test-TokenIn {
    param([string]$Token, [string[]]$Set)
    $needle = ([string]$Token).Trim('"', "'").ToLowerInvariant()
    foreach ($item in @($Set)) { if ($needle -eq $item) { return $true } }
    return $false
}

# $null when nothing is unmistakably visible, otherwise a finding carrying the
# exact silent form to use instead, plus `InnerTokens`.
#
# WHY InnerTokens EXISTS, and it is the whole reason this is not a one-liner.
# A visible launcher HIDES the test from recognition: in `wt pwsh -File
# Run-Tests.ps1` the program token is `wt`, so `Get-RecognizedTestCommand`
# sees no test command and the caller's verdict is 'none'. Gating the refusal on
# that verdict alone means the check never fires on exactly the commands it
# exists for. So each launcher class also reports what it was launching, and the
# caller re-runs recognition on THAT. `Start-Process notepad.exe` strips to
# `notepad.exe`, which is not a test command, and is correctly left alone.
function Get-VisibleInvocationFinding {
    param([string[]]$Tokens)
    $tokens = @($Tokens)
    if ($tokens.Count -eq 0) { return $null }

    $lower = @($tokens | ForEach-Object { ([string]$_).Trim('"', "'").ToLowerInvariant() })

    # ---- class 1: Start-Process that neither waits nor suppresses the window.
    # -Wait alone is enough: a waited Start-Process is how the guarded runner
    # itself is launched in some fixtures, and it does not detach.
    $startProcessAt = -1
    for ($i = 0; $i -lt $lower.Count; $i++) {
        if ($lower[$i] -eq 'start-process') { $startProcessAt = $i; break }
    }
    if ($startProcessAt -ge 0) {
        $silent = $false
        for ($i = $startProcessAt + 1; $i -lt $lower.Count; $i++) {
            if ($lower[$i] -eq '-wait' -or $lower[$i] -eq '-nonewwindow') { $silent = $true; break }
            if ($lower[$i] -eq '-windowstyle' -and ($i + 1) -lt $lower.Count -and $lower[$i + 1] -eq 'hidden') { $silent = $true; break }
        }
        if (-not $silent) {
            # What it was launching, with Start-Process's OWN parameter names
            # dropped so the caller can ask whether THAT is a test command.
            $inner = New-Object System.Collections.Generic.List[string]
            for ($i = $startProcessAt + 1; $i -lt $tokens.Count; $i++) {
                if ($lower[$i] -eq '-filepath' -or $lower[$i] -eq '-argumentlist') { continue }
                [void]$inner.Add([string]$tokens[$i])
            }
            return [pscustomobject]@{
                Reason      = 'this starts the test with Start-Process and neither -Wait, -NoNewWindow nor -WindowStyle Hidden, so it detaches into a NEW WINDOW on the user''s screen - and a detached run is also unowned, so nothing reaps it'
                SafeForm    = 'Run it in the current session instead (no Start-Process at all), or if a separate process is genuinely needed add -Wait -NoNewWindow.'
                InnerTokens = $inner.ToArray()
            }
        }
    }

    # ---- class 2: an explicitly headed browser flag.
    foreach ($token in $lower) {
        if (Test-TokenIn -Token $token -Set $script:VisibleHeadedTokens) {
            # No launcher here: the caller's own recognition already saw the
            # program, so there is no inner command to hand back.
            return [pscustomobject]@{
                Reason      = ('this passes ' + $token + ', which asks for a VISIBLE browser window')
                SafeForm    = 'Drop the flag - headless is the default, and it is what the rule requires unless a human has to watch this run live.'
                InnerTokens = $null
            }
        }
    }

    # ---- class 3: a terminal host launched to hold the test.
    # Only the PROGRAM position counts. `cmd /c start ...` is the same thing
    # spelled through cmd, so the pair is checked explicitly.
    if (Test-TokenIn -Token $lower[0] -Set $script:VisibleLauncherPrograms) {
        $inner = @()
        if ($tokens.Count -gt 1) { $inner = @($tokens[1..($tokens.Count - 1)]) }
        return [pscustomobject]@{
            Reason      = ('this launches the test through ' + $lower[0] + ', a terminal host whose whole job is to open a new window')
            SafeForm    = 'Invoke the interpreter directly (pwsh / python / node) in the current session so the output is captured instead of displayed.'
            InnerTokens = $inner
        }
    }
    if (($lower[0] -eq 'cmd' -or $lower[0] -eq 'cmd.exe') -and $lower.Count -ge 3) {
        if (($lower[1] -eq '/c' -or $lower[1] -eq '/k') -and $lower[2] -eq 'start') {
            $inner = @()
            if ($tokens.Count -gt 3) { $inner = @($tokens[3..($tokens.Count - 1)]) }
            return [pscustomobject]@{
                Reason      = 'this launches the test through `cmd /c start`, which opens a new console window'
                SafeForm    = 'Invoke the interpreter directly (pwsh / python / node) in the current session so the output is captured instead of displayed.'
                InnerTokens = $inner
            }
        }
    }
    # -NoExit keeps a PowerShell window open after the run finishes, which is
    # only ever for a human to read - the definition of not silent.
    if (($lower[0] -eq 'powershell' -or $lower[0] -eq 'powershell.exe' -or $lower[0] -eq 'pwsh' -or $lower[0] -eq 'pwsh.exe')) {
        foreach ($token in $lower) {
            if ($token -eq '-noexit') {
                return [pscustomobject]@{
                    Reason      = 'this passes -NoExit, which holds a PowerShell window open after the run so a human can read it'
                    SafeForm    = 'Drop -NoExit and let the process exit; read the captured output instead.'
                    InnerTokens = $null
                }
            }
        }
    }

    return $null
}
