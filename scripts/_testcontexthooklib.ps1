# Test-ContextHooks section: _hooklib: UTF-8 contract, client identity, Write-HookResult.
#
# Dot-sourced from Test-ContextHooks.ps1 INSIDE its try block, so it runs in
# that scope and uses its harness directly: $Work, $Fire, Check, New-Proj,
# Write-Utf8, Set-ClaudeProjectDir and the counters. Pure relocation - the
# lines below are byte-identical to the ones this file replaced, indentation
# included, so the move can be proved rather than reviewed line by line.
#
# The underscore prefix keeps it out of the runner's Test-*.ps1 glob, so it
# needs no ci.yml bucket entry of its own.

    # =====================================================================
    Write-Host '--- _hooklib: the UTF-8 stdin/stdout contract survives a non-UTF-8 console code page ---' -ForegroundColor Cyan
    # Regression: every shipped hook read stdin through [Console]::In, which
    # decodes with the CONSOLE code page rather than the UTF-8 the clients
    # actually send. A hook process with no attached console - a GUI-hosted
    # client, or any parent spawning it with CreateNoWindow + redirected pipes,
    # including this repo's own parallel test runner - falls back to the machine's
    # OEM page (measured: ibm437), so a prompt of 'معماری پروژه' arrived as
    # box-drawing characters and every non-ASCII prompt, path, and filename
    # silently missed its match. _hooklib now pins UTF-8 both ways at dot-source
    # time (the fix Cross-Project-.ai-Knowledge-Sync always had).
    #
    # The probe forces CP437 BEFORE dot-sourcing, so the hostile condition is
    # reproduced deterministically on any machine instead of depending on the
    # ambient console - this assertion goes red on a real regression even where
    # the console already happens to be UTF-8. It exercises the shared library
    # itself, so it stays true for all 24 hooks that dot-source it rather than
    # tracking one hook's wording.
    $utf8Probe = Join-Path $Work 'utf8-io-probe.ps1'
    $probeBody = @'
Set-StrictMode -Version 2.0
# Hostile pre-condition: a non-UTF-8 console page, exactly what a console-less
# hook process inherits. _hooklib must override this, not inherit it.
try { [Console]::InputEncoding = [System.Text.Encoding]::GetEncoding(437) } catch { }
. (Join-Path '__LIBDIR__' '_hooklib.ps1')
$in = Read-HookInput
$prompt = ''
if ($null -ne $in) { $prompt = [string](Get-Field $in 'prompt') }
'CODEPOINTS=' + ((($prompt.ToCharArray() | ForEach-Object { [int]$_ }) -join ','))
'@
    Write-Utf8 $utf8Probe ($probeBody.Replace('__LIBDIR__', (Split-Path -Parent $HookLib)))

    # 'معماری' - the exact word the Graph-Read-Check relevance test uses.
    $persian = [string]::Join('', @(1605, 1593, 1605, 1575, 1585, 1740 | ForEach-Object { [char]$_ }))
    $expected = (($persian.ToCharArray() | ForEach-Object { [int]$_ }) -join ',')
    $probePayload = @{ session_id = 't'; hook_event_name = 'UserPromptSubmit'; prompt = $persian } | ConvertTo-Json -Compress

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoLogo', '-NoProfile', '-File', $utf8Probe)) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # No console for the child - the condition that exposed the defect.
    $psi.CreateNoWindow = $true
    $probeProc = [System.Diagnostics.Process]::Start($psi)
    # Write the payload as raw UTF-8 bytes and read the reply as raw bytes, so
    # THIS suite's own encoding can never mask or fake the hook's behavior.
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($probePayload)
    $probeProc.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
    $probeProc.StandardInput.BaseStream.Flush()
    $probeProc.StandardInput.Close()
    # Drain stderr asynchronously first: a full stderr pipe deadlocks a
    # synchronous stdout read (the _hooklib CopyTo lesson).
    $probeErrTask = $probeProc.StandardError.ReadToEndAsync()
    $probeOutBuffer = New-Object System.IO.MemoryStream
    $probeProc.StandardOutput.BaseStream.CopyTo($probeOutBuffer)
    [void]$probeProc.WaitForExit(60000)
    $probeErr = ''
    try { $probeErr = $probeErrTask.Result } catch { }
    $probeOut = ([System.Text.Encoding]::UTF8.GetString($probeOutBuffer.ToArray())).Trim()

    Check 'console-less hook process decodes a non-ASCII stdin payload as UTF-8, not the OEM code page' (
        $probeOut -match ('CODEPOINTS=' + [regex]::Escape($expected))) ($probeOut + ' | expected=' + $expected + ' | err=' + $probeErr)
    Check 'the probe hook still exits cleanly with nothing on stderr' (
        $probeProc.ExitCode -eq 0 -and $probeErr.Trim() -eq '') ('exit=' + $probeProc.ExitCode + ' err=' + $probeErr)

    Write-Host '--- _hooklib: client identity is explicit and never defaults a third client to Codex ---' -ForegroundColor Cyan
    # Hooks used to decide the client inline as "CLAUDE_PROJECT_DIR present ->
    # Claude, otherwise -> Codex". With a third client that silently hands Kiro
    # Codex's rules, skills, paths and output protocol. Get-HookClientId is the
    # one place that decision is made now.
    #
    # Dot-sourced into a child scope so the suite's own helpers are untouched.
    $cidOrigCpd = $env:CLAUDE_PROJECT_DIR
    try {
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
        Set-ClaudeProjectDir 'C:\some\project'
        $cidClaude = & { . $HookLib; Get-HookClientId }
        $cidKiroBeatsClaude = & { . $HookLib; Get-HookClientId -Explicit 'kiro' }
        Set-ClaudeProjectDir ''
        $cidLegacyCodex = & { . $HookLib; Get-HookClientId }
        $cidUnknownName = & { . $HookLib; Get-HookClientId -Explicit 'gemini' }
        $cidLooseCase = & { . $HookLib; Get-HookClientId -Explicit '  KIRO ' }
        $env:HOOKMAKER_CLIENT = 'kiro'
        $cidEnvMarker = & { . $HookLib; Get-HookClientId }
        $env:HOOKMAKER_CLIENT = 'nonsense'
        $cidBadEnvMarker = & { . $HookLib; Get-HookClientId }
        Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue

        Check 'CLAUDE_PROJECT_DIR present resolves to claude' ($cidClaude -eq 'claude') $cidClaude
        Check 'an explicit client id overrides CLAUDE_PROJECT_DIR' ($cidKiroBeatsClaude -eq 'kiro') $cidKiroBeatsClaude
        Check 'no signal at all still resolves to codex (existing installs unchanged)' ($cidLegacyCodex -eq 'codex') $cidLegacyCodex
        Check 'an UNRECOGNISED explicit client is unknown, never codex' ($cidUnknownName -eq 'unknown') $cidUnknownName
        Check 'an explicit client id tolerates case and surrounding space' ($cidLooseCase -eq 'kiro') $cidLooseCase
        Check 'HOOKMAKER_CLIENT identifies a client that passes no argument' ($cidEnvMarker -eq 'kiro') $cidEnvMarker
        Check 'an unrecognised HOOKMAKER_CLIENT is unknown, never codex' ($cidBadEnvMarker -eq 'unknown') $cidBadEnvMarker

        # An installed runtime is self-contained: the installer rewrites
        # _hooklib.ps1 into it but copies no sibling from scripts\, so the client
        # id list CANNOT be shared by dot-sourcing and is duplicated by force.
        # This is the assertion that keeps the two copies honest.
        $cidLibIds = & { . $HookLib; @($script:HookClientIds) -join ',' }
        $cidTableIds = & { . (Join-Path $ScriptRoot '_clientcapability.ps1'); @(Get-HookMakerClientIds) -join ',' }
        Check '_hooklib client ids match the canonical capability table exactly' (
            $cidLibIds -eq $cidTableIds) ('hooklib=' + $cidLibIds + ' table=' + $cidTableIds)

        # Same forced-mirror guard for the Kiro trigger list. This one is also a
        # TRUST BOUNDARY, not just a lookup: Read-HookInput accepts an
        # environment-supplied trigger only if it appears in this list, so a
        # drifted copy would either reject a real Kiro event or admit one the
        # capability table never sanctioned.
        $cidLibTriggers = & { . $HookLib; @($script:HookKiroTriggers) -join ',' }
        $cidTableTriggers = & {
            . (Join-Path $ScriptRoot '_clientcapability.ps1')
            @((Get-HookMakerClientCapability -ClientId 'kiro').supportedEvents) -join ','
        }
        Check '_hooklib Kiro triggers match the capability table supportedEvents exactly' (
            $cidLibTriggers -eq $cidTableTriggers) ('hooklib=' + $cidLibTriggers + ' table=' + $cidTableTriggers)
    }
    finally {
        Set-ClaudeProjectDir $cidOrigCpd
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
    }

    # =====================================================================
    Write-Host '--- _hooklib Read-HookInput: the Kiro normalizer ---' -ForegroundColor Cyan
    # Without this every hook is dead on arrival under Kiro IDE, which documents
    # NO stdin JSON: Read-HookInput returned $null and all 23 hooks took their
    # `if ($null -eq $hookInput) { exit 0 }` path. The Claude/Codex paths must
    # stay byte-identical, so they are asserted here too.
    $riOrigClient = $env:HOOKMAKER_CLIENT
    $riOrigTrigger = $env:HOOKMAKER_KIRO_TRIGGER
    $riOrigCpd = $env:CLAUDE_PROJECT_DIR
    try {
        Set-ClaudeProjectDir ''
        # _hooklib is loaded only inside child scopes here (deliberately - the
        # suite must not inherit its functions), so Get-Field is not in scope.
        # This reads the same way without pulling the library into the suite.
        function Get-RiField {
            param($Object, [string]$Name)
            if ($null -eq $Object) { return '' }
            $property = $Object.PSObject.Properties[$Name]
            if ($null -eq $property) { return '' }
            return [string]$property.Value
        }
        function Show-Ri {
            param($Object)
            if ($null -eq $Object) { return 'null' }
            return (($Object.PSObject.Properties | ForEach-Object { $_.Name + '=' + [string]$_.Value }) -join ';')
        }
        function Invoke-ReadHookInput {
            param([string]$Client, [string]$Trigger, [string]$Stdin)
            $env:HOOKMAKER_CLIENT = $Client
            $env:HOOKMAKER_KIRO_TRIGGER = $Trigger
            $previousIn = [Console]::In
            try {
                # stdin is redirected INSIDE the child scope, AFTER _hooklib is
                # dot-sourced. _hooklib pins Console input/output to UTF-8 at
                # dot-source time (the console-less mojibake fix), which replaces
                # any reader installed before it - so setting stdin first silently
                # dropped the payload and only the empty-stdin cases still looked
                # right. This is also the real order: library first, then input.
                return (& {
                        param($LibraryPath, $StdinText)
                        . $LibraryPath
                        [Console]::SetIn((New-Object System.IO.StringReader($StdinText)))
                        Read-HookInput
                    } $HookLib $Stdin)
            }
            finally { [Console]::SetIn($previousIn) }
        }

        $riCodex = Invoke-ReadHookInput -Client 'codex' -Trigger '' -Stdin ''
        Check 'codex with empty stdin still yields nothing, exactly as before' ($null -eq $riCodex) 'codex'
        $riClaude = Invoke-ReadHookInput -Client 'claude' -Trigger '' -Stdin ''
        Check 'claude with empty stdin still yields nothing, exactly as before' ($null -eq $riClaude) 'claude'
        $riClaudeJson = Invoke-ReadHookInput -Client 'claude' -Trigger '' -Stdin '{"hook_event_name":"Stop","session_id":"s1"}'
        Check 'a claude payload passes through untouched, session id included' (
            [string](Get-RiField $riClaudeJson 'hook_event_name') -ceq 'Stop' -and
            [string](Get-RiField $riClaudeJson 'session_id') -ceq 's1') (Show-Ri $riClaudeJson)

        $riKiro = Invoke-ReadHookInput -Client 'kiro' -Trigger 'PreToolUse' -Stdin ''
        Check 'kiro with empty stdin is normalized from the launcher trigger, not dropped' (
            $null -ne $riKiro -and [string](Get-RiField $riKiro 'hook_event_name') -ceq 'PreToolUse') (Show-Ri $riKiro)
        Check 'the normalized kiro input carries a cwd taken from the process' (
            -not [string]::IsNullOrWhiteSpace([string](Get-RiField $riKiro 'cwd'))) (Show-Ri $riKiro)
        # Protocol rule: never invent a persistent identity. An absent session id
        # disables session-keyed dedup; a fabricated one silently mispairs it.
        Check 'no session id is invented for kiro' (
            [string]::IsNullOrWhiteSpace([string](Get-RiField $riKiro 'session_id'))) (Show-Ri $riKiro)
        Check 'no stop_hook_active is fabricated, which would suppress the hook' (
            [string]::IsNullOrWhiteSpace([string](Get-RiField $riKiro 'stop_hook_active'))) (Show-Ri $riKiro)

        $riKiroNoTrigger = Invoke-ReadHookInput -Client 'kiro' -Trigger '' -Stdin ''
        Check 'kiro with no trigger yields nothing rather than guessing an event' ($null -eq $riKiroNoTrigger) 'no-trigger'
        # PostFileSave is a REAL Kiro trigger with no Hook Maker equivalent, so
        # it is the honest unknown-value case: the env is a trust boundary, and
        # anything that can set a variable must not choose a hook's code path.
        $riKiroUnknown = Invoke-ReadHookInput -Client 'kiro' -Trigger 'PostFileSave' -Stdin ''
        Check 'a trigger outside the capability table is refused, not passed through' ($null -eq $riKiroUnknown) 'PostFileSave'

        $riKiroPartial = Invoke-ReadHookInput -Client 'kiro' -Trigger 'Stop' -Stdin '{"cwd":"C:\\w"}'
        Check 'a kiro payload with no event name is completed from the launcher trigger' (
            [string](Get-RiField $riKiroPartial 'hook_event_name') -ceq 'Stop' -and
            [string](Get-RiField $riKiroPartial 'cwd') -ceq 'C:\w') (Show-Ri $riKiroPartial)
        # The payload no longer simply "wins": launcher and payload must AGREE on
        # which event fired, or the hook refuses (asserted in the refusal section
        # below). A different SPELLING of the same event is NOT a disagreement -
        # CLI v2 spelled every trigger camelCase and v3 does not re-publish its
        # casing - so it is resolved and normalized to the canonical name, which
        # is what keeps every hook's `-ceq 'PreToolUse'` branch working.
        $riKiroCasing = Invoke-ReadHookInput -Client 'kiro' -Trigger 'PreToolUse' -Stdin '{"hook_event_name":"preToolUse"}'
        Check 'a payload spelling the SAME event differently is normalized, never refused' (
            [string](Get-RiField $riKiroCasing 'hook_event_name') -ceq 'PreToolUse') (Show-Ri $riKiroCasing)
        $riKiroLooseLauncher = Invoke-ReadHookInput -Client 'kiro' -Trigger 'pretooluse' -Stdin ''
        Check 'the launcher trigger also resolves case-insensitively to the canonical event' (
            [string](Get-RiField $riKiroLooseLauncher 'hook_event_name') -ceq 'PreToolUse') (Show-Ri $riKiroLooseLauncher)

        # --- USER_PROMPT is the ONE input channel Kiro documents ---------------
        # Omitting it left every prompt-driven hook blind on Kiro IDE:
        # Rules-Check, Skills-Check and the ::deep-debug detection all read
        # 'prompt', so they ran and silently did nothing.
        $riOrigUserPrompt = $env:USER_PROMPT
        try {
            $env:USER_PROMPT = 'KIRO-PROMPT-TEXT'
            $riKiroPrompt = Invoke-ReadHookInput -Client 'kiro' -Trigger 'UserPromptSubmit' -Stdin ''
            Check 'kiro UserPromptSubmit carries the prompt from USER_PROMPT' (
                (Get-RiField $riKiroPrompt 'prompt') -ceq 'KIRO-PROMPT-TEXT') (Show-Ri $riKiroPrompt)
            # Scoped to the one trigger Kiro documents it for: a prompt left over
            # in the environment on SessionStart would be stale, and acting on a
            # stale prompt is worse than having none.
            $riKiroNoPrompt = Invoke-ReadHookInput -Client 'kiro' -Trigger 'SessionStart' -Stdin ''
            Check 'no prompt is attached on a trigger Kiro does not document it for' (
                [string]::IsNullOrEmpty((Get-RiField $riKiroNoPrompt 'prompt'))) (Show-Ri $riKiroNoPrompt)
            # Same precedence rule as the event name: the environment is the
            # fallback, never an override of what the client actually sent.
            $riPromptWins = Invoke-ReadHookInput -Client 'kiro' -Trigger 'UserPromptSubmit' -Stdin '{"prompt":"FROM-PAYLOAD"}'
            Check 'a real payload prompt WINS over the environment fallback' (
                (Get-RiField $riPromptWins 'prompt') -ceq 'FROM-PAYLOAD') (Show-Ri $riPromptWins)
            # USER_PROMPT is a Kiro-only channel; no other client may inherit it.
            $riCodexPrompt = Invoke-ReadHookInput -Client 'codex' -Trigger '' -Stdin '{"hook_event_name":"UserPromptSubmit"}'
            Check 'USER_PROMPT is never injected for a non-Kiro client' (
                [string]::IsNullOrEmpty((Get-RiField $riCodexPrompt 'prompt'))) (Show-Ri $riCodexPrompt)

            # Every other hook input arrives as client-framed stdin JSON; this one
            # is an environment variable nothing bounds. A pasted file would land
            # in memory whole, in a process that runs on every submission.
            $env:USER_PROMPT = ('x' * 70000)
            $riHuge = Invoke-ReadHookInput -Client 'kiro' -Trigger 'UserPromptSubmit' -Stdin ''
            $riHugePrompt = [string](Get-RiField $riHuge 'prompt')
            Check 'an oversized USER_PROMPT is bounded rather than taken whole' (
                $riHugePrompt.Length -lt 70000) ('len=' + [string]$riHugePrompt.Length)
            # Silent truncation would be worse than the unbounded read: a hook
            # matching on prompt text would see a prompt the user never typed.
            Check 'truncation is REPORTED in the prompt, never silent' (
                $riHugePrompt -match 'truncated at') ('tail=' + $riHugePrompt.Substring([Math]::Max(0, $riHugePrompt.Length - 60)))
        }
        finally {
            if ([string]::IsNullOrEmpty($riOrigUserPrompt)) {
                if (Test-Path Env:\USER_PROMPT) { Remove-Item Env:\USER_PROMPT -ErrorAction SilentlyContinue }
            }
            else { $env:USER_PROMPT = $riOrigUserPrompt }
        }

        # --- a payload event name that CONTRADICTS the launcher ---------------
        # The launcher argument is written by the INSTALLER into the .kiro\hooks
        # registration, so a real disagreement means the registration and the
        # client disagree about what fired - and NEITHER side can then be trusted
        # to choose the code path a hook takes.
        #
        # This used to let the payload win and record 'hookmaker_trigger_mismatch'
        # on the object. NOTHING read that field, so it was swallowing with extra
        # steps: a PreToolUse registration whose payload said Stop handed the hook
        # a Stop event, the hook ran its Stop branch, and nothing said so.
        #
        # The refusal is an EXIT CODE plus stderr, so these cases MUST run as real
        # child hook processes - an in-process call would take this suite down
        # along with the hook, and the exit code is itself the safety property
        # being asserted. Both hosts, because Claude launches powershell.exe (5.1)
        # and Codex pwsh 7, and cross-host differences are this repo's #1 shipped
        # bug source.
        $riProbe = Join-Path $Work 'kiro-normalize-probe.ps1'
        $riProbeBody = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path '__LIBDIR__' '_hooklib.ps1')
$in = Read-HookInput
$ev = ''
$pr = ''
if ($null -ne $in) {
    $ev = [string](Get-Field $in 'hook_event_name')
    $pr = [string](Get-Field $in 'prompt')
}
$enc = [System.Text.Encoding]::UTF8
# An unpaired surrogate is not encodable as UTF-8 - GetBytes turns it into
# U+FFFD - so a failed round trip IS the split-surrogate detector.
$utf8Ok = ($enc.GetString($enc.GetBytes($pr)) -ceq $pr)
$marker = "`n[hook-maker: prompt truncated at"
$body = $pr
$cut = $pr.IndexOf($marker)
if ($cut -ge 0) { $body = $pr.Substring(0, $cut) }
[Console]::Out.WriteLine('RAN;EVENT=' + $ev + ';BODYBYTES=' + $enc.GetByteCount($body) +
    ';CHARS=' + $pr.Length + ';UTF8OK=' + $utf8Ok + ';TRUNC=' + ($cut -ge 0))
'@
        Write-Utf8 $riProbe ($riProbeBody.Replace('__LIBDIR__', (Split-Path -Parent $HookLib)))

        # The enclosing finally blocks restore all three variables, so these are
        # set and left for the next call rather than saved per invocation.
        function Invoke-KiroProbe {
            param([string]$Client, [string]$Trigger, [string]$Stdin, [string]$UserPrompt = '', [string]$Exe = 'pwsh')
            $env:HOOKMAKER_CLIENT = $Client
            $env:HOOKMAKER_KIRO_TRIGGER = $Trigger
            $env:USER_PROMPT = $UserPrompt
            return (Fire -HookPath $riProbe -Cwd $Work -RawStdin $Stdin -Exe $Exe)
        }
        function Get-RiPart {
            param([string]$Text, [string]$Key)
            $m = [regex]::Match($Text, ';' + $Key + '=([^;]*)')
            if ($m.Success) { return $m.Groups[1].Value }
            return ''
        }

        try {
            foreach ($riExe in @('pwsh', 'powershell.exe')) {
                $riTag = $(if ($riExe -eq 'pwsh') { 'pwsh 7' } else { '5.1' })

                $riMismatch = Invoke-KiroProbe -Client 'kiro' -Trigger 'PreToolUse' -Stdin '{"hook_event_name":"Stop"}' -Exe $riExe
                Check ($riTag + ': a contradicting payload REFUSES to run and says so on stderr') (
                    $riMismatch.Out -notmatch 'RAN' -and $riMismatch.Exit -ne 0 -and
                    $riMismatch.Err -match 'PreToolUse' -and $riMismatch.Err -match 'Stop') (
                    'exit=' + $riMismatch.Exit + ' out=[' + $riMismatch.Out + '] err=[' + $riMismatch.Err + ']')
                # THE safety line. Kiro's exit-code table: stdout is added to
                # context only on SessionStart/UserPromptSubmit (so a stdout
                # refusal would be silent on exactly the PreToolUse/PostToolUse/
                # Stop events where a wrong branch does damage), 2 BLOCKS, and any
                # other non-zero exit shows stderr to the user and proceeds. A
                # configuration fault is the USER's to repair, not the agent's to
                # be blocked by - and Kiro cannot block at Stop at all.
                Check ($riTag + ': the refusal never uses exit 2, Kiro''s block code') (
                    $riMismatch.Exit -ne 2) ([string]$riMismatch.Exit)
                # A real Kiro trigger with no Hook Maker equivalent is a genuine
                # disagreement too, not a spelling difference. The old code passed
                # it straight through as the hook's event name - an event name
                # arriving from stdin that is not even a Hook Maker logical event.
                $riUnknownPayload = Invoke-KiroProbe -Client 'kiro' -Trigger 'PreToolUse' -Stdin '{"hook_event_name":"PostFileSave"}' -Exe $riExe
                Check ($riTag + ': an unresolvable payload event is refused, never passed through') (
                    $riUnknownPayload.Out -notmatch 'RAN' -and $riUnknownPayload.Exit -ne 0 -and
                    $riUnknownPayload.Exit -ne 2) ('exit=' + $riUnknownPayload.Exit + ' out=[' + $riUnknownPayload.Out + ']')
                # Same event, different spelling: must RUN, and canonically.
                $riCasing = Invoke-KiroProbe -Client 'kiro' -Trigger 'PreToolUse' -Stdin '{"hook_event_name":"preToolUse"}' -Exe $riExe
                Check ($riTag + ': a casing-only difference runs and normalizes, so CLI v3 is not broken') (
                    $riCasing.Exit -eq 0 -and (Get-RiPart $riCasing.Out 'EVENT') -ceq 'PreToolUse') (
                    'exit=' + $riCasing.Exit + ' out=[' + $riCasing.Out + ']')
                # Agreement and fill-in stay ordinary, non-refusing paths.
                $riAgree = Invoke-KiroProbe -Client 'kiro' -Trigger 'Stop' -Stdin '{"hook_event_name":"Stop"}' -Exe $riExe
                Check ($riTag + ': an agreeing payload runs normally') (
                    $riAgree.Exit -eq 0 -and (Get-RiPart $riAgree.Out 'EVENT') -ceq 'Stop') (
                    'exit=' + $riAgree.Exit + ' out=[' + $riAgree.Out + ']')
                $riFilled = Invoke-KiroProbe -Client 'kiro' -Trigger 'Stop' -Stdin '{"cwd":"C:\\w"}' -Exe $riExe
                Check ($riTag + ': completing a MISSING event name is not a contradiction') (
                    $riFilled.Exit -eq 0 -and (Get-RiPart $riFilled.Out 'EVENT') -ceq 'Stop') (
                    'exit=' + $riFilled.Exit + ' out=[' + $riFilled.Out + ']')
                # Claude and Codex must be byte-identical to before, even with a
                # stray Kiro trigger sitting in the environment.
                foreach ($riOther in @('claude', 'codex')) {
                    $riOtherResult = Invoke-KiroProbe -Client $riOther -Trigger 'PreToolUse' -Stdin '{"hook_event_name":"Stop"}' -Exe $riExe
                    Check ($riTag + ': ' + $riOther + ' is untouched by a contradicting Kiro trigger') (
                        $riOtherResult.Exit -eq 0 -and (Get-RiPart $riOtherResult.Out 'EVENT') -ceq 'Stop' -and
                        $riOtherResult.Err -eq '') (
                        'exit=' + $riOtherResult.Exit + ' out=[' + $riOtherResult.Out + '] err=[' + $riOtherResult.Err + ']')
                }

                # --- the prompt cap is UTF-8 BYTES, and never splits a pair ----
                # 40000 CJK characters are 120000 UTF-8 bytes but only 40000
                # CHARACTERS, so the old character cap admitted ~3x the bound it
                # documented and did not truncate this at all.
                $riCjk = ([string][char]0x4E00) * 40000
                $riCjkResult = Invoke-KiroProbe -Client 'kiro' -Trigger 'UserPromptSubmit' -Stdin '' -UserPrompt $riCjk -Exe $riExe
                Check ($riTag + ': the prompt cap bounds UTF-8 BYTES, not characters') (
                    (Get-RiPart $riCjkResult.Out 'TRUNC') -eq 'True' -and
                    [int](Get-RiPart $riCjkResult.Out 'BODYBYTES') -le 65536) ('out=[' + $riCjkResult.Out + ']')
                # An astral character straddling the limit: .Substring() cuts
                # between the two halves of the surrogate pair, and the leftover
                # unpaired surrogate is not encodable as UTF-8 at all.
                $riSurrogate = ('x' * 65535) + [string]::Concat([char]0xD83D, [char]0xDE00)
                $riSurrogateResult = Invoke-KiroProbe -Client 'kiro' -Trigger 'UserPromptSubmit' -Stdin '' -UserPrompt $riSurrogate -Exe $riExe
                Check ($riTag + ': truncation never splits a surrogate pair, so the result stays valid UTF-8') (
                    (Get-RiPart $riSurrogateResult.Out 'UTF8OK') -eq 'True' -and
                    (Get-RiPart $riSurrogateResult.Out 'TRUNC') -eq 'True' -and
                    [int](Get-RiPart $riSurrogateResult.Out 'BODYBYTES') -le 65536) ('out=[' + $riSurrogateResult.Out + ']')

                # --- the byte bound covers EVERY prompt channel, not just env ---
                # CLI v3 sends stdin JSON, and "payload wins" used to mean the
                # payload's prompt escaped the cap entirely: the documented 64 KB
                # bound applied only to the channel that happened to be smaller.
                $riPayloadPromptJson = '{"hook_event_name":"UserPromptSubmit","prompt":"' + ('A' * 70000) + '"}'
                $riPayloadBig = Invoke-KiroProbe -Client 'kiro' -Trigger 'UserPromptSubmit' -Stdin $riPayloadPromptJson -Exe $riExe
                Check ($riTag + ': an oversized PAYLOAD prompt is bounded by the same cap as USER_PROMPT') (
                    $riPayloadBig.Exit -eq 0 -and
                    (Get-RiPart $riPayloadBig.Out 'TRUNC') -eq 'True' -and
                    [int](Get-RiPart $riPayloadBig.Out 'BODYBYTES') -le 65536) ('out=[' + $riPayloadBig.Out + ']')

                # --- no launcher trigger is not a free pass for the payload ----
                # This used to `return $parsed` unvalidated, so the payload could
                # name ANY string as the event and the hook ran that branch. Now
                # the payload's event is held to the SAME trust list the launcher
                # argument is: resolvable -> runs canonically; anything else ->
                # visible refusal, because with neither side trusted there is no
                # identity for the invocation at all.
                $riNoTrigValid = Invoke-KiroProbe -Client 'kiro' -Trigger '' -Stdin '{"hook_event_name":"stop"}' -Exe $riExe
                Check ($riTag + ': no trigger + a payload event INSIDE the trust list runs, normalized') (
                    $riNoTrigValid.Exit -eq 0 -and (Get-RiPart $riNoTrigValid.Out 'EVENT') -ceq 'Stop') (
                    'exit=' + $riNoTrigValid.Exit + ' out=[' + $riNoTrigValid.Out + ']')
                $riNoTrigBogus = Invoke-KiroProbe -Client 'kiro' -Trigger '' -Stdin '{"hook_event_name":"PostFileSave"}' -Exe $riExe
                Check ($riTag + ': no trigger + a payload event OUTSIDE the trust list is refused visibly') (
                    $riNoTrigBogus.Out -notmatch 'RAN' -and $riNoTrigBogus.Exit -ne 0 -and $riNoTrigBogus.Exit -ne 2 -and
                    $riNoTrigBogus.Err -match 'PostFileSave') (
                    'exit=' + $riNoTrigBogus.Exit + ' out=[' + $riNoTrigBogus.Out + '] err=[' + $riNoTrigBogus.Err + ']')

                # --- corrupt stdin is not the same thing as empty stdin --------
                # Non-empty-but-unparseable used to collapse into the SAME $null
                # an empty IDE stdin produces, and the synthesize branch then
                # built a healthy-looking event from it - corrupt input laundered
                # into a normal invocation. It refuses visibly now, on Kiro only.
                $riCorrupt = Invoke-KiroProbe -Client 'kiro' -Trigger 'SessionStart' -Stdin '{not json!!' -Exe $riExe
                Check ($riTag + ': corrupt stdin JSON on Kiro refuses visibly instead of synthesizing an event') (
                    $riCorrupt.Out -notmatch 'RAN' -and $riCorrupt.Exit -ne 0 -and $riCorrupt.Exit -ne 2 -and
                    $riCorrupt.Err -match 'JSON') (
                    'exit=' + $riCorrupt.Exit + ' out=[' + $riCorrupt.Out + '] err=[' + $riCorrupt.Err + ']')
                foreach ($riOtherCorrupt in @('claude', 'codex')) {
                    $riOtherCorruptResult = Invoke-KiroProbe -Client $riOtherCorrupt -Trigger '' -Stdin '{not json!!' -Exe $riExe
                    Check ($riTag + ': corrupt stdin on ' + $riOtherCorrupt + ' stays the silent no-op it always was') (
                        $riOtherCorruptResult.Exit -eq 0 -and (Get-RiPart $riOtherCorruptResult.Out 'EVENT') -ceq '' -and
                        $riOtherCorruptResult.Err -eq '') (
                        'exit=' + $riOtherCorruptResult.Exit + ' err=[' + $riOtherCorruptResult.Err + ']')
                }

                # --- the refusal diagnostic is itself bounded and single-line --
                # The payload event name is untrusted text headed for a
                # user-visible warning: unbounded, a 5 KB name with embedded
                # newlines flooded the diagnostic and let payload text pose as
                # additional diagnostic lines.
                $riNoisyEvent = '{"hook_event_name":"Stop\nFAKE-DIAGNOSTIC-LINE' + ('X' * 5000) + '"}'
                $riNoise = Invoke-KiroProbe -Client 'kiro' -Trigger 'PreToolUse' -Stdin $riNoisyEvent -Exe $riExe
                $riNoiseLines = @($riNoise.Err -split "`r?`n" | Where-Object { $_ -ne '' })
                Check ($riTag + ': a hostile event name cannot flood or line-break the refusal diagnostic') (
                    $riNoise.Exit -ne 0 -and $riNoise.Exit -ne 2 -and
                    $riNoiseLines.Count -eq 1 -and $riNoiseLines[0].Length -lt 600) (
                    'exit=' + $riNoise.Exit + ' errLines=' + $riNoiseLines.Count + ' len=' + $(if ($riNoiseLines.Count -gt 0) { $riNoiseLines[0].Length } else { 0 }))

                # --- a leading BOM is transport, not payload -------------------
                # A .NET Framework parent's StreamWriter emits the encoding
                # preamble into a redirected child stdin, and 5.1's
                # ConvertFrom-Json throws on the resulting leading U+FEFF while
                # pwsh 7 tolerates it - so without the trim the SAME healthy
                # payload parsed on one host and read as corrupt on the other.
                $riBomPayload = [string][char]0xFEFF + '{"hook_event_name":"Stop"}'
                $riBom = Invoke-KiroProbe -Client 'kiro' -Trigger 'Stop' -Stdin $riBomPayload -Exe $riExe
                Check ($riTag + ': a BOM-prefixed healthy payload runs normally on both hosts') (
                    $riBom.Exit -eq 0 -and (Get-RiPart $riBom.Out 'EVENT') -ceq 'Stop') (
                    'exit=' + $riBom.Exit + ' out=[' + $riBom.Out + '] err=[' + $riBom.Err + ']')
            }
        }
        finally {
            if ([string]::IsNullOrEmpty($riOrigUserPrompt)) {
                if (Test-Path Env:\USER_PROMPT) { Remove-Item Env:\USER_PROMPT -ErrorAction SilentlyContinue }
            }
            else { $env:USER_PROMPT = $riOrigUserPrompt }
        }
    }
    finally {
        Set-ClaudeProjectDir $riOrigCpd
        if ([string]::IsNullOrEmpty($riOrigClient)) {
            if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
        }
        else { $env:HOOKMAKER_CLIENT = $riOrigClient }
        if ([string]::IsNullOrEmpty($riOrigTrigger)) {
            if (Test-Path Env:\HOOKMAKER_KIRO_TRIGGER) { Remove-Item Env:\HOOKMAKER_KIRO_TRIGGER -ErrorAction SilentlyContinue }
        }
        else { $env:HOOKMAKER_KIRO_TRIGGER = $riOrigTrigger }
    }

    # =====================================================================
    Write-Host '--- _hooklib Write-HookResult: one adapter, client-shaped output, honest degradation ---' -ForegroundColor Cyan
    # ~62 open-coded emission sites across the shipped hooks each re-derive the
    # client shape by hand, and ~15 emit hookSpecificOutput with no client branch
    # at all - already mis-shaped for Codex. Write-HookResult is the one place a
    # SEMANTIC result becomes a client shape. Nothing calls it yet, so these
    # assertions are the whole contract: byte-identical Claude/Codex output
    # against REAL captured hook emissions, and a degradation report a caller can
    # record instead of claiming enforcement it did not get.
    $hrOrigCpd = $env:CLAUDE_PROJECT_DIR
    try {
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }

        # BYTE-COMPATIBILITY (real emission site 1 of 4): Mcp-Usage-Check's
        # SessionStart context - one of the ~15 unbranched hookSpecificOutput
        # sites, so this pins the shape the adapter must keep for Claude. On the
        # 5.1 host for the deterministic-hashing reason described at the probe.
        $hrRealMcp = Fire -HookPath $McpHook -Cwd $plain -Exe 'powershell.exe'
        $hrMcpDoc = $null
        try { $hrMcpDoc = $hrRealMcp.Out | ConvertFrom-Json } catch { }
        $hrMcpMsg = if ($null -ne $hrMcpDoc -and $null -ne $hrMcpDoc.PSObject.Properties['hookSpecificOutput']) { [string]$hrMcpDoc.hookSpecificOutput.additionalContext } else { '' }
        $hrMcpAdapted = Invoke-HookResult -Call @{ kind = 'context'; event = 'SessionStart'; message = $hrMcpMsg; client = 'claude' } -Exe 'powershell.exe'
        Check '5.1 host: Write-HookResult reproduces a real SessionStart claude context byte-for-byte' (
            $hrMcpMsg -ne '' -and $hrMcpAdapted.Out -ceq $hrRealMcp.Out -and
            $hrMcpAdapted.Result.Shape -eq 'claudeContext' -and $hrMcpAdapted.Result.Degraded -eq $false) (
            'hook=[' + $hrRealMcp.Out + '] adapter=[' + $hrMcpAdapted.Out + ']')

        # Same-process construct proof, on BOTH hosts: the adapter's bytes must
        # equal the shipped literal's bytes for every shape. This is what makes
        # the byte-compatibility claim hold on pwsh 7, where cross-process key
        # order is randomised and literal equality is therefore impossible.
        $hrShape7 = Test-HookResultConstruct -Exe 'pwsh'
        Check 'pwsh 7: the adapter emits the shipped literal byte-for-byte for every shape (same process)' (
            $hrShape7 -eq '') $hrShape7
        $hrShape51 = Test-HookResultConstruct -Exe 'powershell.exe'
        Check '5.1: the adapter emits the shipped literal byte-for-byte for every shape (same process)' (
            $hrShape51 -eq '') $hrShape51

        # --- silent writes nothing at all ---
        $hrSilent = Invoke-HookResult -Call @{ kind = 'silent'; event = 'Stop'; message = 'never-emitted'; client = 'claude' }
        Check 'silent emits nothing on stdout or stderr and reports nothing degraded' (
            $hrSilent.Out -eq '' -and $hrSilent.Err -eq '' -and $hrSilent.Result.Emitted -eq $false -and
            $hrSilent.Result.Shape -eq 'none' -and $hrSilent.Result.Degraded -eq $false) ($hrSilent.Out + ' | ' + $hrSilent.Err)

        # --- an unknown client is never guessed at ---
        # --- Codex systemMessage is STOP-SCOPED, not a Codex-wide shape -------
        # This was untested, and the adapter had it wrong: a bare else gave Codex
        # systemMessage on EVERY event. Wiring the shipped hooks onto it would
        # have silently rewritten ~47 pre-task Codex emissions and dropped the
        # event name. Codex does not document additionalContext for Stop, but it
        # honours it everywhere else - so both ends of that rule are asserted.
        foreach ($hrPreTaskEvent in @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse')) {
            $hrCodexPre = Invoke-HookResult -Call @{ kind = 'context'; event = $hrPreTaskEvent; message = 'codex-pre'; client = 'codex' }
            Check ("codex " + $hrPreTaskEvent + ' keeps hookSpecificOutput.additionalContext, carrying the event name') (
                $hrCodexPre.Result.Shape -eq 'codexContext' -and
                $hrCodexPre.Out -match '"additionalContext"\s*:\s*"codex-pre"' -and
                $hrCodexPre.Out -match ('"hookEventName"\s*:\s*"' + $hrPreTaskEvent + '"') -and
                $hrCodexPre.Out -notmatch 'systemMessage') $hrCodexPre.Out
        }
        foreach ($hrStopEvent in @('Stop', 'SubagentStop')) {
            $hrCodexStop = Invoke-HookResult -Call @{ kind = 'context'; event = $hrStopEvent; message = 'codex-stop'; client = 'codex' }
            Check ("codex " + $hrStopEvent + ' uses systemMessage, the only field Codex documents there') (
                $hrCodexStop.Result.Shape -eq 'codexSystemMessage' -and
                $hrCodexStop.Out -match '"systemMessage"\s*:\s*"codex-stop"' -and
                $hrCodexStop.Out -notmatch 'hookSpecificOutput') $hrCodexStop.Out
            # Claude keeps additionalContext on Stop - it IS documented there as
            # model-visible, so the two clients legitimately diverge on Stop.
            $hrClaudeStop = Invoke-HookResult -Call @{ kind = 'context'; event = $hrStopEvent; message = 'claude-stop'; client = 'claude' }
            Check ("claude " + $hrStopEvent + ' still uses additionalContext, so the clients diverge only on Stop') (
                $hrClaudeStop.Result.Shape -eq 'claudeContext' -and
                $hrClaudeStop.Out -match '"additionalContext"\s*:\s*"claude-stop"') $hrClaudeStop.Out
        }

        # --- the PreToolUse permission mechanism is NOT block/advisory --------
        # A Claude tool call is refused with permissionDecision, not
        # decision:block; Codex has no permissionDecision and refuses by exiting
        # 2. Folding these into 'block' would emit a shape that refuses nothing.
        $hrClaudeDeny = Invoke-HookResult -Call @{ kind = 'deny'; event = 'PreToolUse'; reason = 'DENY-REASON'; client = 'claude' }
        Check 'claude deny is permissionDecision, never decision:block' (
            $hrClaudeDeny.Result.Shape -eq 'claudePermissiondeny' -and
            $hrClaudeDeny.Out -match '"permissionDecision"\s*:\s*"deny"' -and
            $hrClaudeDeny.Out -match '"permissionDecisionReason"\s*:\s*"DENY-REASON"' -and
            $hrClaudeDeny.Out -notmatch '"decision"' -and
            $hrClaudeDeny.Result.ExitCode -eq 0) $hrClaudeDeny.Out
        $hrCodexDeny = Invoke-HookResult -Call @{ kind = 'deny'; event = 'PreToolUse'; reason = 'DENY-REASON'; client = 'codex' }
        Check 'codex deny is systemMessage plus exit 2, which is how Codex refuses' (
            $hrCodexDeny.Result.Shape -eq 'codexPermissiondeny' -and
            $hrCodexDeny.Out -match '"systemMessage"' -and $hrCodexDeny.Out -notmatch 'permissionDecision' -and
            $hrCodexDeny.Result.ExitCode -eq 2 -and $hrCodexDeny.Err -match 'DENY-REASON') (
            $hrCodexDeny.Out + ' | err=' + $hrCodexDeny.Err)
        $hrKiroDeny = Invoke-HookResult -Call @{ kind = 'deny'; event = 'PreToolUse'; reason = 'DENY-REASON'; client = 'kiro' }
        Check 'kiro deny on a block-capable trigger is exit 2 + stderr, with nothing on stdout' (
            $hrKiroDeny.Result.Shape -eq 'kiroExit2Stderr' -and $hrKiroDeny.Result.ExitCode -eq 2 -and
            $hrKiroDeny.Out -eq '' -and $hrKiroDeny.Err -match 'DENY-REASON') (
            $hrKiroDeny.Out + ' | err=' + $hrKiroDeny.Err)
        # Kiro cannot refuse at Stop on either surface Hook Maker targets, so a
        # deny there must never be emitted as if it were enforced.
        $hrKiroDenyStop = Invoke-HookResult -Call @{ kind = 'deny'; event = 'Stop'; reason = 'DENY-REASON'; client = 'kiro' }
        Check 'a kiro deny on a non-block-capable event is never emitted as a gate' (
            $hrKiroDenyStop.Result.ExitCode -ne 2 -and $hrKiroDenyStop.Result.Degraded -eq $true) (
            $hrKiroDenyStop.Out + ' | ' + [string]$hrKiroDenyStop.Result.DegradedReason)
        # allow is the same mechanism answering yes - it must never exit 2.
        $hrClaudeAllow = Invoke-HookResult -Call @{ kind = 'allow'; event = 'PreToolUse'; message = 'ALLOW-REASON'; client = 'claude' }
        Check 'claude allow keeps permissionDecision allow and exits 0' (
            $hrClaudeAllow.Out -match '"permissionDecision"\s*:\s*"allow"' -and
            $hrClaudeAllow.Result.ExitCode -eq 0) $hrClaudeAllow.Out
        # This branch emitted NOTHING AT ALL, which silently deleted every
        # PreToolUse advisory on Kiro: an allow is not block-capable and
        # PreToolUse is not a context trigger, so it fell straight through.
        # Test-Run-Guard routes its PreToolUse advisories through 'allow', so
        # TEST_GUARD_ADVISORY_ONLY announced advisory mode to nobody.
        $hrKiroAllow = Invoke-HookResult -Call @{ kind = 'allow'; event = 'PreToolUse'; message = 'ALLOW-REASON'; client = 'kiro' }
        Check 'a kiro allow REACHES the user instead of vanishing' (
            $hrKiroAllow.Result.Emitted -eq $true -and $hrKiroAllow.Err -match 'ALLOW-REASON' -and
            $hrKiroAllow.Result.Shape -eq 'kiroStderrWarning') (
            $hrKiroAllow.Out + ' | err=' + $hrKiroAllow.Err)
        # THE safety line: an approval carrying Kiro's refusal code would enforce
        # the exact opposite of what it says.
        Check 'a kiro allow never exits 2 - an approval must not read as a refusal' (
            $hrKiroAllow.Result.ExitCode -ne 2) ([string]$hrKiroAllow.Result.ExitCode)
        # The early-return path has its own unknown/blank guards; without them it
        # would fall through to the Codex arm and refuse on a guessed shape.
        $hrDenyUnknown = Invoke-HookResult -Call @{ kind = 'deny'; event = 'PreToolUse'; reason = 'DENY-REASON'; client = 'gemini' }
        Check 'an unknown client is never refused on a guessed shape' (
            $hrDenyUnknown.Result.Emitted -eq $false -and $hrDenyUnknown.Result.ExitCode -eq 0 -and
            $hrDenyUnknown.Result.DegradedReason -match 'client is unknown') (
            $hrDenyUnknown.Out + ' | ' + [string]$hrDenyUnknown.Result.DegradedReason)

        $hrUnknown = Invoke-HookResult -Call @{ kind = 'context'; event = 'SessionStart'; message = 'never-emitted'; client = 'gemini' }
        Check 'an unknown client emits NOTHING and reports it, never a guessed shape' (
            $hrUnknown.Out -eq '' -and $hrUnknown.Result.Emitted -eq $false -and $hrUnknown.Result.Shape -eq 'none' -and
            $hrUnknown.Result.Degraded -eq $true -and $hrUnknown.Result.DegradedReason -match 'client is unknown') (
            $hrUnknown.Out + ' | ' + [string]$hrUnknown.Result.DegradedReason)

        # --- a block on a non-block-capable event is downgraded, never faked ---
        # Kiro Stop cannot block on either surface Hook Maker targets, so the
        # gate is downgraded to the strongest advisory available and BOTH facts
        # are reported - that is what lets a caller record degraded-stop-gate
        # instead of claiming a gate it never got.
        #
        # These two assertions previously required TOTAL silence here. That was
        # wrong and it hid a real defect: Kiro discards stdout on Stop, but a
        # non-zero exit other than 2 surfaces stderr to the user. Demanding
        # silence meant a failed gate told the user nothing at all. What must
        # actually be guaranteed is that it is not mistaken for a gate - so the
        # exit code, not the presence of output, is the safety property.
        $hrKiroStopBlock = Invoke-HookResult -Call @{ kind = 'block'; event = 'Stop'; reason = 'KIRO-STOP-GATE'; client = 'kiro' }
        Check 'a block on Kiro Stop is DOWNGRADED to a warning, never a fake block' (
            $hrKiroStopBlock.Out -eq '' -and $hrKiroStopBlock.Out -notmatch 'decision' -and
            $hrKiroStopBlock.Err -match 'KIRO-STOP-GATE' -and
            $hrKiroStopBlock.Result.Shape -eq 'kiroStderrWarning') (
            $hrKiroStopBlock.Out + ' | ' + $hrKiroStopBlock.Err)
        # THE safety property: 2 is Kiro's refusal code. A downgraded gate that
        # exited 2 would enforce exactly the block we just proved Kiro cannot do.
        Check 'the downgraded gate never exits with Kiro''s refusal code' (
            $hrKiroStopBlock.Result.ExitCode -ne 2) ([string]$hrKiroStopBlock.Result.ExitCode)
        Check 'the downgrade REPORTS Degraded with both reasons (no block mechanism, stdout discarded)' (
            $hrKiroStopBlock.Result.Degraded -eq $true -and
            $hrKiroStopBlock.Result.DegradedReason -match 'no block mechanism on Stop' -and
            $hrKiroStopBlock.Result.DegradedReason -match 'NOT an enforced gate' -and
            $hrKiroStopBlock.Result.DegradedReason -match 'discards hook stdout') ([string]$hrKiroStopBlock.Result.DegradedReason)

        # --- a block on a block-capable Kiro event is a REAL block ---
        $hrKiroRealBlock = Invoke-HookResult -Call @{ kind = 'block'; event = 'UserPromptSubmit'; reason = 'KIRO-REAL-GATE'; client = 'kiro' }
        Check 'a block on a block-capable Kiro event is exit 2 + stderr, and is NOT degraded' (
            $hrKiroRealBlock.Out -eq '' -and $hrKiroRealBlock.Err -match 'KIRO-REAL-GATE' -and
            $hrKiroRealBlock.Result.Emitted -eq $true -and $hrKiroRealBlock.Result.Shape -eq 'kiroExit2Stderr' -and
            $hrKiroRealBlock.Result.ExitCode -eq 2 -and $hrKiroRealBlock.Result.Degraded -eq $false) (
            $hrKiroRealBlock.Out + ' | ' + $hrKiroRealBlock.Err)

        # --- Kiro context lands only where Kiro documents it ---
        $hrKiroCtx = Invoke-HookResult -Call @{ kind = 'context'; event = 'SessionStart'; message = 'KIRO-CTX-TEXT'; client = 'kiro' }
        Check 'Kiro context on a documented trigger is plain stdout, never a Claude/Codex JSON shape' (
            $hrKiroCtx.Out -ceq 'KIRO-CTX-TEXT' -and $hrKiroCtx.Result.Shape -eq 'kiroStdout' -and
            $hrKiroCtx.Result.Emitted -eq $true -and $hrKiroCtx.Result.Degraded -eq $false) $hrKiroCtx.Out
        # Changed deliberately, not silently. This used to assert TOTAL silence
        # off Kiro's two context triggers, and that pinned a real defect: Kiro
        # discards stdout there, but a non-zero exit code other than 2 surfaces
        # stderr to the user and lets execution continue. Asserting silence meant
        # every Stop and PostToolUse message was thrown away on Kiro and the test
        # certified it. The message now reaches the user via that channel.
        $hrKiroCtxIgnored = Invoke-HookResult -Call @{ kind = 'context'; event = 'PostToolUse'; message = 'KIRO-IGNORED'; client = 'kiro' }
        Check 'Kiro off its context triggers warns on stderr instead of vanishing' (
            $hrKiroCtxIgnored.Out -eq '' -and $hrKiroCtxIgnored.Err -match 'KIRO-IGNORED' -and
            $hrKiroCtxIgnored.Result.Shape -eq 'kiroStderrWarning' -and
            $hrKiroCtxIgnored.Result.Emitted -eq $true) (
            $hrKiroCtxIgnored.Out + ' | err=' + $hrKiroCtxIgnored.Err)
        # Exit 1, never 2: 2 is Kiro's refusal code, so reusing it here would
        # turn a non-blocking notice into a block on a block-capable trigger.
        Check 'the Kiro warning uses exit 1, never the refusal code 2' (
            $hrKiroCtxIgnored.Result.ExitCode -eq 1) ([string]$hrKiroCtxIgnored.Result.ExitCode)
        # It must still be reported as WEAKER than the context channel: this
        # reaches the user, not the model. Calling it parity would be a lie.
        Check 'the stderr warning is still reported as degraded, not as context parity' (
            $hrKiroCtxIgnored.Result.Degraded -eq $true -and
            $hrKiroCtxIgnored.Result.DegradedReason -match 'NOT injected into model context') (
            [string]$hrKiroCtxIgnored.Result.DegradedReason)

        # --- the same downgrade rule applies to Claude, not just Kiro ---
        $hrClaudeSsBlock = Invoke-HookResult -Call @{ kind = 'block'; event = 'SessionStart'; reason = 'CLAUDE-SS-GATE'; client = 'claude' }
        Check 'a block on Claude SessionStart downgrades to the advisory shape and reports it' (
            $hrClaudeSsBlock.Out -notmatch '"decision"' -and $hrClaudeSsBlock.Out -match 'additionalContext' -and
            $hrClaudeSsBlock.Result.Shape -eq 'claudeContext' -and $hrClaudeSsBlock.Result.Degraded -eq $true) $hrClaudeSsBlock.Out

        # --- the forced mirror of the canonical blocking table stays honest ---
        # _hooklib cannot dot-source scripts\_clientcapability.ps1 (an installed
        # runtime is self-contained), so blockCapableEvents is duplicated by
        # force - the same pattern as $script:HookClientIds. This is the guard.
        $hrMirrorDiff = & {
            . $HookLib
            . (Join-Path $ScriptRoot '_clientcapability.ps1')
            $bad = @()
            foreach ($clientId in @(Get-HookMakerClientIds)) {
                if (-not $script:HookBlockCapableEvents.ContainsKey($clientId)) { $bad += ($clientId + '/<missing>'); continue }
                foreach ($logical in @(Get-HookMakerLogicalEvents)) {
                    $fromTable = Test-HookMakerEventBlocking -ClientId $clientId -EventName $logical
                    $fromMirror = (@($script:HookBlockCapableEvents[$clientId] | Where-Object { $_ -ceq $logical }).Count -gt 0)
                    if ($fromTable -ne $fromMirror) { $bad += ($clientId + '/' + $logical) }
                }
            }
            ($bad -join ',')
        }
        Check '_hooklib block-capability mirror decides identically to Test-HookMakerEventBlocking for every client x event' (
            $hrMirrorDiff -eq '') ('mismatches=' + $hrMirrorDiff)
        $hrMirrorShape = & {
            . $HookLib
            . (Join-Path $ScriptRoot '_clientcapability.ps1')
            $keys = (@($script:HookBlockCapableEvents.Keys) | Sort-Object) -join ','
            $bogus = @()
            foreach ($clientId in @($script:HookBlockCapableEvents.Keys)) {
                foreach ($name in @($script:HookBlockCapableEvents[$clientId])) {
                    if ($null -eq (Resolve-HookMakerLogicalEvent -Name $name)) { $bogus += ($clientId + '/' + $name) }
                }
            }
            $keys + '|' + ((@(Get-HookMakerClientIds) | Sort-Object) -join ',') + '|' + ($bogus -join ',')
        }
        $hrMirrorParts = $hrMirrorShape.Split('|')
        Check 'the mirror covers exactly the canonical clients and names no unknown event' (
            $hrMirrorParts[0] -eq $hrMirrorParts[1] -and $hrMirrorParts[2] -eq '') $hrMirrorShape

        # Kiro's context-capable triggers come from .ai/KIRO_PROTOCOL.md (exit 0:
        # stdout is added to context ONLY on SessionStart and UserPromptSubmit).
        # There is no canonical table to mirror, so this pins the constant.
        $hrKiroCtxEvents = & { . $HookLib; @($script:HookKiroContextEvents) -join ',' }
        Check 'Kiro context triggers stay exactly the two the protocol documents' (
            $hrKiroCtxEvents -eq 'SessionStart,UserPromptSubmit') $hrKiroCtxEvents
    }
    finally {
        Set-ClaudeProjectDir $hrOrigCpd
    }
