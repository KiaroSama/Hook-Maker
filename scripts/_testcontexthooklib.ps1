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

    Write-Host '--- _hooklib: client identity is explicit, never inferred inline ---' -ForegroundColor Cyan
    # Hooks used to decide the client inline as "CLAUDE_PROJECT_DIR present ->
    # Claude, otherwise -> Codex", which hands any client without that variable
    # Codex's rules, skills, paths and output protocol. Get-HookClientId is the
    # one place that decision is made now.
    #
    # Dot-sourced into a child scope so the suite's own helpers are untouched.
    $cidOrigCpd = $env:CLAUDE_PROJECT_DIR
    try {
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
        Set-ClaudeProjectDir 'C:\some\project'
        $cidClaude = & { . $HookLib; Get-HookClientId }
        # CLAUDE_PROJECT_DIR is set, so a default would be claude: codex here can
        # only have come from the explicit argument.
        $cidExplicitBeatsClaude = & { . $HookLib; Get-HookClientId -Explicit 'codex' }
        Set-ClaudeProjectDir ''
        $cidLegacyCodex = & { . $HookLib; Get-HookClientId }
        $cidUnknownName = & { . $HookLib; Get-HookClientId -Explicit 'gemini' }
        # No CLAUDE_PROJECT_DIR now, so a default would be codex: claude can only
        # have come from the trimmed, case-folded value.
        $cidLooseCase = & { . $HookLib; Get-HookClientId -Explicit '  CLAUDE ' }
        $env:HOOKMAKER_CLIENT = 'claude'
        $cidEnvMarker = & { . $HookLib; Get-HookClientId }
        $env:HOOKMAKER_CLIENT = 'nonsense'
        $cidBadEnvMarker = & { . $HookLib; Get-HookClientId }
        Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue

        Check 'CLAUDE_PROJECT_DIR present resolves to claude' ($cidClaude -eq 'claude') $cidClaude
        Check 'an explicit client id overrides CLAUDE_PROJECT_DIR' ($cidExplicitBeatsClaude -eq 'codex') $cidExplicitBeatsClaude
        Check 'no signal at all still resolves to codex (existing installs unchanged)' ($cidLegacyCodex -eq 'codex') $cidLegacyCodex
        Check 'an UNRECOGNISED explicit client is unknown, never codex' ($cidUnknownName -eq 'unknown') $cidUnknownName
        Check 'an explicit client id tolerates case and surrounding space' ($cidLooseCase -eq 'claude') $cidLooseCase
        Check 'HOOKMAKER_CLIENT identifies a client that passes no argument' ($cidEnvMarker -eq 'claude') $cidEnvMarker
        Check 'an unrecognised HOOKMAKER_CLIENT is unknown, never codex' ($cidBadEnvMarker -eq 'unknown') $cidBadEnvMarker

        # An installed runtime is self-contained: the installer rewrites
        # _hooklib.ps1 into it but copies no sibling from scripts\, so the client
        # id list CANNOT be shared by dot-sourcing and is duplicated by force.
        # This is the assertion that keeps the two copies honest.
        $cidLibIds = & { . $HookLib; @($script:HookClientIds) -join ',' }
        $cidTableIds = & { . (Join-Path $ScriptRoot '_clientcapability.ps1'); @(Get-HookMakerClientIds) -join ',' }
        Check '_hooklib client ids match the canonical capability table exactly' (
            $cidLibIds -eq $cidTableIds) ('hooklib=' + $cidLibIds + ' table=' + $cidTableIds)
    }
    finally {
        Set-ClaudeProjectDir $cidOrigCpd
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
    }

    # =====================================================================
    Write-Host '--- _hooklib Read-HookInput: the Claude/Codex paths ---' -ForegroundColor Cyan
    $riOrigClient = $env:HOOKMAKER_CLIENT
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
            param([string]$Client, [string]$Stdin)
            $env:HOOKMAKER_CLIENT = $Client
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

        $riCodex = Invoke-ReadHookInput -Client 'codex' -Stdin ''
        Check 'codex with empty stdin still yields nothing, exactly as before' ($null -eq $riCodex) 'codex'
        $riClaude = Invoke-ReadHookInput -Client 'claude' -Stdin ''
        Check 'claude with empty stdin still yields nothing, exactly as before' ($null -eq $riClaude) 'claude'
        $riClaudeJson = Invoke-ReadHookInput -Client 'claude' -Stdin '{"hook_event_name":"Stop","session_id":"s1"}'
        Check 'a claude payload passes through untouched, session id included' (
            [string](Get-RiField $riClaudeJson 'hook_event_name') -ceq 'Stop' -and
            [string](Get-RiField $riClaudeJson 'session_id') -ceq 's1') (Show-Ri $riClaudeJson)
    }
    finally {
        Set-ClaudeProjectDir $riOrigCpd
        if ([string]::IsNullOrEmpty($riOrigClient)) {
            if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
        }
        else { $env:HOOKMAKER_CLIENT = $riOrigClient }
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
        # allow is the same mechanism answering yes - it must never exit 2.
        $hrClaudeAllow = Invoke-HookResult -Call @{ kind = 'allow'; event = 'PreToolUse'; message = 'ALLOW-REASON'; client = 'claude' }
        Check 'claude allow keeps permissionDecision allow and exits 0' (
            $hrClaudeAllow.Out -match '"permissionDecision"\s*:\s*"allow"' -and
            $hrClaudeAllow.Result.ExitCode -eq 0) $hrClaudeAllow.Out
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
        # The gate is downgraded to the strongest advisory available and the
        # downgrade is REPORTED - that is what lets a caller record a degraded
        # gate instead of claiming one it never got.
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
    }
    finally {
        Set-ClaudeProjectDir $hrOrigCpd
    }
