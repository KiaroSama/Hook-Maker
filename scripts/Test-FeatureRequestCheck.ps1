# Offline suite for Feature-Request-Check: the prompt detector, the
# UserPromptSubmit advisory, the Stop gate, and the guard that stops the hook
# arming its own gate from the banner it emitted itself.
#
# Everything is FABRICATED - a workspace-local LOCALAPPDATA, workspace-local
# project directories, hand-built .jsonl transcripts. The hook only ever reads
# a transcript file and %LOCALAPPDATA%\HookMaker\state, so a real Claude
# session is never needed, and must never be: the suite would otherwise pass or
# fail on what the developer happened to do this morning.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-FeatureRequestCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$HooksRoot = Join-Path $ToolRoot 'hooks'
$Hook = Join-Path $HooksRoot 'Feature-Request-Check\Feature-Request-Check.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$EnvExample = Join-Path $HooksRoot 'Feature-Request-Check\.env.example'
foreach ($required in @($Hook, $HookLib, $EnvExample)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host ('Required file not found: ' + $required) -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $ScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-featurereq'
Write-Host ('Workspace: ' + $Work) -ForegroundColor DarkGray
$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null

# ---- Persian fixtures -------------------------------------------------------
# Built from CODE POINTS, never written as a literal. A .ps1 with no BOM is
# decoded with the ANSI code page by Windows PowerShell 5.1, so a Persian
# literal would arrive there as mojibake and every assertion below would go on
# passing while testing nothing. Code points decode identically on both hosts
# and keep this file ASCII, which is also what the repo expects of a .ps1.
function Get-Fa {
    param([int[]]$CodePoints)
    return [string]::Join('', @($CodePoints | ForEach-Object { [char]$_ }))
}
$FaFeature    = Get-Fa 1601, 1740, 1670, 1585                                      # ficher     - feature
$FaCapability = Get-Fa 1602, 1575, 1576, 1604, 1740, 1578                          # ghabeliyat - capability
$FaImplement  = Get-Fa 1662, 1740, 1575, 1583, 1607, 8204, 1587, 1575, 1586, 1740  # piade-sazi, ZWNJ inside
$FaAdd        = Get-Fa 1575, 1590, 1575, 1601, 1607, 32, 1705, 1606                # ezafe kon  - add
$FaBuild      = Get-Fa 1576, 1587, 1575, 1586                                      # besaz      - build
$FaBug        = Get-Fa 1576, 1575, 1711                                            # bag        - bug
$FaHello      = Get-Fa 1587, 1604, 1575, 1605                                      # salam      - hello

# ---- helpers ----------------------------------------------------------------
# Every non-ASCII character goes into the payload as a \uXXXX escape, so the
# stdin JSON is pure ASCII whatever host wrote it. Windows PowerShell 5.1 pipes
# and files default to encodings that would turn a Persian prompt into '?'
# before the hook ever read it - and the assertion would then be measuring this
# suite's encoding rather than the hook's detector.
function ConvertTo-AsciiJson {
    param([string]$Json)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Json.ToCharArray()) {
        if ([int]$ch -lt 128) { [void]$sb.Append($ch) }
        else { [void]$sb.Append('\u' + ('{0:x4}' -f [int]$ch)) }
    }
    return $sb.ToString()
}

function New-Proj {
    param([string]$Name)
    $p = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# One invocation of the hook, as a real child process reading real stdin.
#
# The environment is set on THIS process and inherited rather than passed with
# Start-Process -Environment: 5.1 has no -Environment parameter, and a suite
# that silently lost its fake LOCALAPPDATA there would start writing gate state
# into the developer's real one.
function Fire {
    param(
        [hashtable]$Payload,
        [string]$HookPath = '',
        [string]$Client = 'claude',
        [string]$Exe = 'pwsh'
    )
    if ($HookPath -eq '') { $HookPath = $Hook }
    $json = ConvertTo-AsciiJson ($Payload | ConvertTo-Json -Depth 8 -Compress)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $json, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' }
    $savedLocal = $env:LOCALAPPDATA
    $savedClient = $env:HOOKMAKER_CLIENT
    try {
        $env:LOCALAPPDATA = $FakeLocalAppData
        $env:HOOKMAKER_CLIENT = $Client
        $startArgs = @{
            FilePath               = $file
            ArgumentList           = $argLine
            RedirectStandardInput  = $inFile
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
            Wait                   = $true
            NoNewWindow            = $true
            PassThru               = $true
        }
        $proc = Start-BoundedProcess @startArgs
    }
    finally {
        $env:LOCALAPPDATA = $savedLocal
        $env:HOOKMAKER_CLIENT = $savedClient
    }
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# PARSE the emitted JSON, never regex it: every path inside arrives with its
# backslashes doubled, and this project has lost time to that twice already.
function Get-Message {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $doc = $null
    try { $doc = $Text | ConvertFrom-Json } catch { return '' }
    if ($null -eq $doc) { return '' }
    if ($null -ne $doc.PSObject.Properties['reason']) { return [string]$doc.reason }
    if ($null -ne $doc.PSObject.Properties['hookSpecificOutput'] -and $null -ne $doc.hookSpecificOutput) {
        return [string]$doc.hookSpecificOutput.additionalContext
    }
    if ($null -ne $doc.PSObject.Properties['systemMessage']) { return [string]$doc.systemMessage }
    return ''
}

function Test-Blocked {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $doc = $null
    try { $doc = $Text | ConvertFrom-Json } catch { return $false }
    if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['decision']) { return $false }
    return ([string]$doc.decision -eq 'block')
}

# A Claude transcript is JSONL: one {"message":{...}} object per line.
function New-UserEntry {
    param([string]$Text)
    return @{ type = 'user'; message = @{ role = 'user'; content = $Text } }
}
function New-SkillEntry {
    param([string]$Skill)
    return @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Skill'; input = @{ skill = $Skill } }) } }
}
function New-AssistantEntry {
    param([string]$Text)
    return @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $Text }) } }
}
function New-Transcript {
    param([string]$Name, [object[]]$Entries)
    $path = Join-Path $Work ($Name + '.jsonl')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Entries) { [void]$lines.Add(($e | ConvertTo-Json -Depth 8 -Compress)) }
    Write-Utf8 $path (($lines.ToArray() -join "`n") + "`n")
    return $path
}
function New-StopPayload {
    param(
        [string]$Cwd, [string]$Transcript = '', [string]$SessionId = 's1',
        [string]$EventName = 'Stop', [switch]$StopActive
    )
    $o = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($Transcript -ne '') { $o['transcript_path'] = $Transcript }
    if ($StopActive) { $o['stop_hook_active'] = $true }
    return $o
}

# A hook copy with its own .env, placed one level under $Work so the copy's
# '..\_hooklib.ps1' resolves to the library copy beside it. Never write a .env
# next to the shipped hook: the installer would package it.
function New-IsolatedHookCopy {
    param([string]$EnvContent = $null)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Feature-Request-Check.ps1')
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($null -ne $EnvContent) { Write-Utf8 (Join-Path $dir '.env') $EnvContent }
    return (Join-Path $dir 'Feature-Request-Check.ps1')
}

$FeaturePrompt = 'add a dark mode option to the settings page'
$Banner = 'FEATURE REQUEST CHECK - this prompt reads as a feature request, so run the mattpocock chain instead of coding straight from it:'

try {
    # =====================================================================
    Write-Host ''
    Write-Host '--- the detector, tested against the LIVE hook source ---' -ForegroundColor Cyan
    # The pattern block and Test-FeatureRequestPrompt are cut out of the
    # shipped file between two stable markers and dot-sourced. Transcribing the
    # regexes into this file would keep passing while the hook drifted; this
    # cannot, and it fails loudly if either marker ever disappears.
    $HookText = [System.IO.File]::ReadAllText($Hook)
    $startIndex = $HookText.IndexOf('# ---- feature detection')
    $endIndex = $HookText.IndexOf('$hookInput = Read-HookInput')
    if ($startIndex -lt 0 -or $endIndex -le $startIndex) {
        Write-Host 'Could not cut the detector block out of the hook: its markers changed.' -ForegroundColor Red
        exit 1
    }
    $detectorProbe = Join-Path $Work 'detector-probe.ps1'
    Write-Utf8 $detectorProbe $HookText.Substring($startIndex, $endIndex - $startIndex)
    . $detectorProbe
    Check 'detector: the block really was extracted (all three patterns + the function)' (
        -not [string]::IsNullOrWhiteSpace($script:FeatureBugPattern) -and
        -not [string]::IsNullOrWhiteSpace($script:FeatureExplicitPattern) -and
        -not [string]::IsNullOrWhiteSpace($script:FeatureVerbPattern) -and
        $null -ne (Get-Command Test-FeatureRequestPrompt -ErrorAction SilentlyContinue))

    # --- the explicit pattern: decisive on its own ---
    Check 'explicit: "feature request" is a feature request' (
        Test-FeatureRequestPrompt -Prompt 'here is a feature request for the export panel')
    Check 'explicit: "as a user" is a feature request' (
        Test-FeatureRequestPrompt -Prompt 'as a user I want to see running totals')
    Check 'explicit: "should be able to" is a feature request' (
        Test-FeatureRequestPrompt -Prompt 'the reviewer should be able to sort by date')
    Check 'explicit: "new capability" is a feature request' (
        Test-FeatureRequestPrompt -Prompt 'we need a new capability for bulk edits')
    Check 'explicit: "make it possible" is a feature request' (
        Test-FeatureRequestPrompt -Prompt 'make it possible to re-run one ticket')
    # The header promises this precedence: a feature that is broken is still
    # about a feature, so the explicit phrase must beat bug vocabulary.
    Check 'explicit: it OUTRANKS bug vocabulary ("the feature request is broken")' (
        Test-FeatureRequestPrompt -Prompt 'the feature request is broken')

    # --- the verb path: verb + object, inside 60 characters ---
    Check 'verb: "add ... option" is a feature request' (
        Test-FeatureRequestPrompt -Prompt $FeaturePrompt)
    Check 'verb: "implement ... endpoint" is a feature request' (
        Test-FeatureRequestPrompt -Prompt 'implement the export endpoint for reports')
    Check 'verb: "create ... dashboard" is a feature request' (
        Test-FeatureRequestPrompt -Prompt 'create a dashboard for the queue depth')
    # The 60-character window is the whole reason looking for a common verb is
    # safe at all. Same verb, same object, only the distance differs.
    Check 'verb: an object inside the 60-character window matches' (
        Test-FeatureRequestPrompt -Prompt 'add a button')
    Check 'verb: an object BEYOND the 60-character window does not' (
        -not (Test-FeatureRequestPrompt -Prompt ('add ' + ('waffle ' * 12) + 'button')))

    # --- the FALSE cases, which are what keep the gate usable ---
    Check 'false: a lone verb with no object word is not a feature request' (
        -not (Test-FeatureRequestPrompt -Prompt 'add a comment explaining why'))
    Check 'false: an ordinary question is not a feature request' (
        -not (Test-FeatureRequestPrompt -Prompt 'what does this function do'))
    Check 'false: a bug report is not a feature request' (
        -not (Test-FeatureRequestPrompt -Prompt 'the build fails with a stack trace'))
    Check 'false: an empty prompt is not a feature request' (
        -not (Test-FeatureRequestPrompt -Prompt ''))
    Check 'false: a whitespace-only prompt is not a feature request' (
        -not (Test-FeatureRequestPrompt -Prompt "  `t "))
    # THE pair that proves the bug vocabulary is load-bearing rather than
    # decorative: one sentence, one word of difference.
    Check 'suppression control: the sentence alone IS a feature request' (
        Test-FeatureRequestPrompt -Prompt 'add a retry option to the login page')
    Check 'suppression: bug vocabulary in the same sentence kills the verb path' (
        -not (Test-FeatureRequestPrompt -Prompt 'fix the crash and add a retry option to the login page'))

    # =====================================================================
    Write-Host ''
    Write-Host '--- the detector in Persian (the hook ships both languages) ---' -ForegroundColor Cyan
    Check 'fa explicit: ficher (feature)' (
        Test-FeatureRequestPrompt -Prompt $FaFeature)
    Check 'fa explicit: ghabeliyat (capability)' (
        Test-FeatureRequestPrompt -Prompt $FaCapability)
    Check 'fa explicit: piade-sazi, with the ZWNJ its pattern allows' (
        Test-FeatureRequestPrompt -Prompt $FaImplement)
    Check 'fa verb: ezafe kon (add)' (
        Test-FeatureRequestPrompt -Prompt $FaAdd)
    Check 'fa verb: besaz (build)' (
        Test-FeatureRequestPrompt -Prompt $FaBuild)
    Check 'fa suppression: bag (bug) in the same prompt kills the Persian verb path' (
        -not (Test-FeatureRequestPrompt -Prompt ($FaBug + ' ' + $FaAdd)))
    Check 'fa false: ordinary Persian matches nothing' (
        -not (Test-FeatureRequestPrompt -Prompt $FaHello))

    # =====================================================================
    Write-Host ''
    Write-Host '--- UserPromptSubmit: the advisory half ---' -ForegroundColor Cyan
    $projAdvise = New-Proj 'Advise'
    $r = Fire (@{ session_id = 'u1'; cwd = $projAdvise; hook_event_name = 'UserPromptSubmit'; prompt = $FeaturePrompt })
    $msg = Get-Message $r.Out
    Check 'advisory: a feature prompt gets the chain note' (
        $r.Exit -eq 0 -and $r.Err -eq '' -and $msg -match 'FEATURE REQUEST CHECK') ($r.Out + $r.Err)
    Check 'advisory: it names grilling and domain-modeling, not just "a skill"' (
        $msg -match 'grilling' -and $msg -match 'domain-modeling') $msg
    Check 'advisory: "not a feature" is offered as a complete answer' (
        $msg -match '(?i)Not a feature') $msg
    Check 'advisory: UserPromptSubmit NEVER emits decision:block' (
        -not (Test-Blocked $r.Out)) $r.Out
    $rSame = Fire (@{ session_id = 'u1'; cwd = $projAdvise; hook_event_name = 'UserPromptSubmit'; prompt = $FeaturePrompt })
    Check 'advisory: the same prompt is not repeated' ($rSame.Out -eq '') $rSame.Out
    $rNew = Fire (@{ session_id = 'u1'; cwd = $projAdvise; hook_event_name = 'UserPromptSubmit'; prompt = 'implement the export endpoint for reports' })
    Check 'advisory: a DIFFERENT feature prompt speaks again' (
        (Get-Message $rNew.Out) -match 'FEATURE REQUEST CHECK') $rNew.Out
    $rQuiet = Fire (@{ session_id = 'u2'; cwd = (New-Proj 'AdviseQuiet'); hook_event_name = 'UserPromptSubmit'; prompt = 'what does this function do' })
    Check 'advisory: an ordinary prompt is silent' (
        $rQuiet.Exit -eq 0 -and $rQuiet.Out -eq '') ($rQuiet.Out + $rQuiet.Err)
    $rBug = Fire (@{ session_id = 'u3'; cwd = (New-Proj 'AdviseBug'); hook_event_name = 'UserPromptSubmit'; prompt = 'fix the crash on the login page' })
    Check 'advisory: a bug report is silent' (
        $rBug.Exit -eq 0 -and $rBug.Out -eq '') ($rBug.Out + $rBug.Err)

    # =====================================================================
    Write-Host ''
    Write-Host '--- Stop: the byte cap is applied before the transcript is read ---' -ForegroundColor Cyan
    # The cap is documented in BYTES. Persian letters are one UTF-16 character
    # but two UTF-8 bytes, so a transcript padded with them can be over the
    # byte cap while under the reader's old character count - exactly the
    # case the length pre-check decides differently from a line-by-line read.
    $capHook = New-IsolatedHookCopy "MAX_TRANSCRIPT_BYTES=100000`n"
    $capUserLine = (New-UserEntry $FeaturePrompt) | ConvertTo-Json -Depth 8 -Compress
    $padOver = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"' + [string]::new([char]0x0641, 60000) + '"}]}}'
    $tOver = Join-Path $Work 'cap-over.jsonl'
    Write-Utf8 $tOver ($capUserLine + "`n" + $padOver + "`n")
    $overBytes = (New-Object System.IO.FileInfo($tOver)).Length
    Check 'cap fixture: the over-cap transcript is really more than 100000 bytes' ($overBytes -gt 100000) ('bytes=' + $overBytes)
    $rOver = Fire (New-StopPayload -Cwd (New-Proj 'CapOver') -Transcript $tOver -SessionId 'cap-over') -HookPath $capHook
    Check 'cap: a transcript over the byte cap is PARTIAL - the gate stays silent' (
        $rOver.Exit -eq 0 -and $rOver.Out -eq '' -and $rOver.Err -eq '') ($rOver.Out + $rOver.Err)
    $padUnder = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"' + [string]::new([char]0x0641, 40000) + '"}]}}'
    $tUnder = Join-Path $Work 'cap-under.jsonl'
    Write-Utf8 $tUnder ($capUserLine + "`n" + $padUnder + "`n")
    $rUnder = Fire (New-StopPayload -Cwd (New-Proj 'CapUnder') -Transcript $tUnder -SessionId 'cap-under') -HookPath $capHook
    Check 'cap: a transcript under the byte cap is still evaluated - the gate blocks' (Test-Blocked $rUnder.Out) ($rUnder.Out + $rUnder.Err)

    # =====================================================================
    Write-Host ''
    Write-Host '--- Stop: the gate, and the evidence it refuses to invent ---' -ForegroundColor Cyan
    $tFeature = New-Transcript 'feature-no-chain' @(
        (New-UserEntry $FeaturePrompt),
        (New-AssistantEntry 'edited three files and ran the tests')
    )
    $projGate = New-Proj 'Gate'
    $rBlock = Fire (New-StopPayload -Cwd $projGate -Transcript $tFeature -SessionId 'g1')
    $blockMsg = Get-Message $rBlock.Out
    Check 'gate: a feature prompt with no grilling call BLOCKS' (
        (Test-Blocked $rBlock.Out) -and $rBlock.Exit -eq 0) ($rBlock.Out + $rBlock.Err)
    Check 'gate: the block quotes the prompt it actually found (its evidence)' (
        $blockMsg -match 'dark mode option') $blockMsg
    Check 'gate: the block names the missing Skill call by name' (
        $blockMsg -match 'grilling') $blockMsg
    Check 'gate: the block states BOTH ways out, so it is clearable' (
        $blockMsg -match '(?i)run it now' -and $blockMsg -match '(?i)why this was not a feature') $blockMsg

    $tRan = New-Transcript 'feature-chain-ran' @(
        (New-UserEntry $FeaturePrompt),
        (New-SkillEntry 'grilling'),
        (New-SkillEntry 'domain-modeling'),
        (New-AssistantEntry 'wrote the spec')
    )
    $rRan = Fire (New-StopPayload -Cwd (New-Proj 'GateRan') -Transcript $tRan -SessionId 'g2')
    Check 'gate: the COMPLETE chain (grilling + domain-modeling) keeps it silent' (
        $rRan.Exit -eq 0 -and $rRan.Out -eq '') ($rRan.Out + $rRan.Err)

    # The hook accepts the plugin-qualified spelling as well as the bare one;
    # in a real Claude session it is the qualified one that appears.
    $tQualified = New-Transcript 'feature-chain-qualified' @(
        (New-UserEntry $FeaturePrompt),
        (New-SkillEntry 'mattpocock-skills:grilling'),
        (New-SkillEntry 'mattpocock-skills:domain-modeling')
    )
    $rQualified = Fire (New-StopPayload -Cwd (New-Proj 'GateQualified') -Transcript $tQualified -SessionId 'g3')
    Check 'gate: the plugin-qualified spelling counts for both halves' (
        $rQualified.Exit -eq 0 -and $rQualified.Out -eq '') ($rQualified.Out + $rQualified.Err)

    # HALF a chain is not the chain: either half alone still blocks, and the
    # block names the one that is missing so the reply does not have to guess.
    $tOther = New-Transcript 'feature-other-skill' @(
        (New-UserEntry $FeaturePrompt),
        (New-SkillEntry 'domain-modeling')
    )
    $rOther = Fire (New-StopPayload -Cwd (New-Proj 'GateOther') -Transcript $tOther -SessionId 'g4')
    Check 'gate: domain-modeling WITHOUT grilling still blocks' (
        Test-Blocked $rOther.Out) ($rOther.Out + $rOther.Err)
    Check 'gate: that block names the missing half (grilling), not the one that ran' (
        (Get-Message $rOther.Out) -match 'no Skill call to "grilling"') $rOther.Out

    # The mirror case: grilling ran, domain-modeling did not.
    $tHalf = New-Transcript 'feature-half-chain' @(
        (New-UserEntry $FeaturePrompt),
        (New-SkillEntry 'grilling')
    )
    $rHalf = Fire (New-StopPayload -Cwd (New-Proj 'GateHalf') -Transcript $tHalf -SessionId 'g4b')
    Check 'gate: grilling WITHOUT domain-modeling still blocks' (
        Test-Blocked $rHalf.Out) ($rHalf.Out + $rHalf.Err)
    Check 'gate: that block names domain-modeling as the missing half' (
        (Get-Message $rHalf.Out) -match 'no Skill call to "domain-modeling"') $rHalf.Out
    Check 'gate: the block states the chain ORDER, not just the two names' (
        (Get-Message $rHalf.Out) -match 'IN ORDER' -and
        (Get-Message $rHalf.Out) -match 'then to-spec, then to-tickets') $rHalf.Out

    $tNone = New-Transcript 'no-feature' @(
        (New-UserEntry 'fix the crash on the login page'),
        (New-UserEntry 'what does this function do')
    )
    $rNone = Fire (New-StopPayload -Cwd (New-Proj 'GateNone') -Transcript $tNone -SessionId 'g5')
    Check 'gate: no feature prompt in the session, no block' (
        $rNone.Exit -eq 0 -and $rNone.Out -eq '') ($rNone.Out + $rNone.Err)

    # No transcript is NO EVIDENCE, in either direction - never an all-clear
    # and never a violation. Codex does not supply one at all.
    $rNoTranscript = Fire (New-StopPayload -Cwd (New-Proj 'GateNoTranscript') -SessionId 'g6')
    Check 'gate: no transcript_path at all is silent, not a block' (
        $rNoTranscript.Exit -eq 0 -and $rNoTranscript.Out -eq '') ($rNoTranscript.Out + $rNoTranscript.Err)
    $rMissing = Fire (New-StopPayload -Cwd (New-Proj 'GateMissing') -Transcript (Join-Path $Work 'no-such-transcript.jsonl') -SessionId 'g7')
    Check 'gate: a transcript path that does not exist is silent too' (
        $rMissing.Exit -eq 0 -and $rMissing.Out -eq '') ($rMissing.Out + $rMissing.Err)

    $rIgnored = Fire (New-StopPayload -Cwd (New-Proj 'GateEvent') -Transcript $tFeature -SessionId 'g8' -EventName 'PreToolUse')
    Check 'gate: an event this hook does not own is ignored' (
        $rIgnored.Exit -eq 0 -and $rIgnored.Out -eq '') ($rIgnored.Out + $rIgnored.Err)

    # =====================================================================
    Write-Host ''
    Write-Host '--- Stop: it blocks ONCE, and a new request re-arms it ---' -ForegroundColor Cyan
    $projOnce = New-Proj 'GateOnce'
    $rFirst = Fire (New-StopPayload -Cwd $projOnce -Transcript $tFeature -SessionId 'once')
    Check 'once: the first Stop blocks' (Test-Blocked $rFirst.Out) $rFirst.Out
    $rSecond = Fire (New-StopPayload -Cwd $projOnce -Transcript $tFeature -SessionId 'once')
    Check 'once: the SAME unfinished business does not block twice' (
        $rSecond.Exit -eq 0 -and $rSecond.Out -eq '') ($rSecond.Out + $rSecond.Err)
    $tSecondFeature = New-Transcript 'feature-second' @(
        (New-UserEntry $FeaturePrompt),
        (New-UserEntry 'implement the export endpoint for reports')
    )
    $rReArmed = Fire (New-StopPayload -Cwd $projOnce -Transcript $tSecondFeature -SessionId 'once')
    Check 'once: a NEW feature prompt re-arms the gate' (
        Test-Blocked $rReArmed.Out) ($rReArmed.Out + $rReArmed.Err)

    # stop_hook_active is set by ANY gate's block on the same Stop, so exiting
    # on the flag alone would let one hook mute all the others. Standing down
    # is owed only to this hook's OWN recorded block.
    $projLoop = New-Proj 'GateLoop'
    $rLoopFirst = Fire (New-StopPayload -Cwd $projLoop -Transcript $tFeature -SessionId 'loop')
    Check 'loop: the block is emitted and its marker recorded' (Test-Blocked $rLoopFirst.Out) $rLoopFirst.Out
    $rLoopBack = Fire (New-StopPayload -Cwd $projLoop -Transcript $tFeature -SessionId 'loop' -StopActive)
    Check 'loop: its own re-entry stands down (no hook loop)' (
        $rLoopBack.Exit -eq 0 -and $rLoopBack.Out -eq '') ($rLoopBack.Out + $rLoopBack.Err)
    $rOtherGate = Fire (New-StopPayload -Cwd (New-Proj 'GateOtherBlock') -Transcript $tFeature -SessionId 'someone-else' -StopActive)
    Check 'loop: ANOTHER gate''s block does not mute this one' (
        Test-Blocked $rOtherGate.Out) ($rOtherGate.Out + $rOtherGate.Err)

    # =====================================================================
    Write-Host ''
    Write-Host '--- the self-banner guard: evidence it planted itself ---' -ForegroundColor Cyan
    # The advisory this hook emits says "this prompt reads as a feature
    # request", which matches the very pattern the Stop half searches for, and
    # injected hook context can land inside a user turn. Without the guard the
    # hook arms its own gate in every session it once spoke in.
    $tBannerOnly = New-Transcript 'banner-only' @(
        (New-UserEntry $Banner),
        (New-AssistantEntry 'renamed a variable')
    )
    $rBannerOnly = Fire (New-StopPayload -Cwd (New-Proj 'BannerOnly') -Transcript $tBannerOnly -SessionId 'b1')
    Check 'banner: its own advisory is NOT counted as a user feature request' (
        $rBannerOnly.Exit -eq 0 -and $rBannerOnly.Out -eq '') ($rBannerOnly.Out + $rBannerOnly.Err)
    Check 'banner: the control - that same text DOES match the detector' (
        Test-FeatureRequestPrompt -Prompt $Banner)

    # The anchor allows leading whitespace, and it is multiline: a banner that
    # arrives indented, or after another line of injected context, is still the
    # hook's own voice.
    $tBannerIndented = New-Transcript 'banner-indented' @(
        (New-UserEntry ("`t  " + $Banner))
    )
    $rBannerIndented = Fire (New-StopPayload -Cwd (New-Proj 'BannerIndented') -Transcript $tBannerIndented -SessionId 'b2')
    Check 'banner: an indented banner is still recognised as its own' (
        $rBannerIndented.Exit -eq 0 -and $rBannerIndented.Out -eq '') ($rBannerIndented.Out + $rBannerIndented.Err)

    # Narrowness in the other direction: the guard skips an ENTRY, not the
    # scan. A real request in the same session still arms the gate.
    $tBannerPlusReal = New-Transcript 'banner-plus-real' @(
        (New-UserEntry $Banner),
        (New-UserEntry $FeaturePrompt)
    )
    $rBannerPlusReal = Fire (New-StopPayload -Cwd (New-Proj 'BannerPlusReal') -Transcript $tBannerPlusReal -SessionId 'b3')
    Check 'banner: a real request alongside the banner still blocks' (
        Test-Blocked $rBannerPlusReal.Out) ($rBannerPlusReal.Out + $rBannerPlusReal.Err)
    Check 'banner: and the block quotes the REAL prompt, not the banner' (
        (Get-Message $rBannerPlusReal.Out) -match 'dark mode option') (Get-Message $rBannerPlusReal.Out)

    # Anchored at the start of a line: a user talking ABOUT the banner mid
    # sentence is a user, and is counted.
    $tBannerQuoted = New-Transcript 'banner-quoted' @(
        (New-UserEntry 'why did the FEATURE REQUEST CHECK banner fire for that feature request?')
    )
    $rBannerQuoted = Fire (New-StopPayload -Cwd (New-Proj 'BannerQuoted') -Transcript $tBannerQuoted -SessionId 'b4')
    Check 'banner: the guard is anchored - a mid-sentence mention is still the user' (
        Test-Blocked $rBannerQuoted.Out) ($rBannerQuoted.Out + $rBannerQuoted.Err)

    # =====================================================================
    Write-Host ''
    Write-Host '--- Persian end to end, through the transcript reader ---' -ForegroundColor Cyan
    # The transcript is read with an explicit UTF-8 decoder, so this path is
    # the one place a Persian request can be driven through the whole hook
    # without the console encoding of either process getting a vote.
    $tFaFeature = New-Transcript 'fa-feature' @(
        (New-UserEntry ($FaFeature + ' ' + $FaAdd)),
        (New-AssistantEntry 'started coding')
    )
    $rFa = Fire (New-StopPayload -Cwd (New-Proj 'FaGate') -Transcript $tFaFeature -SessionId 'fa1')
    Check 'fa: a Persian feature request arms the gate end to end' (
        Test-Blocked $rFa.Out) ($rFa.Out + $rFa.Err)
    $tFaBug = New-Transcript 'fa-bug' @(
        (New-UserEntry ($FaBug + ' ' + $FaAdd))
    )
    $rFaBug = Fire (New-StopPayload -Cwd (New-Proj 'FaBug') -Transcript $tFaBug -SessionId 'fa2')
    Check 'fa: a Persian bug report does not' (
        $rFaBug.Exit -eq 0 -and $rFaBug.Out -eq '') ($rFaBug.Out + $rFaBug.Err)

    # =====================================================================
    Write-Host ''
    Write-Host '--- a PARTIAL transcript read never produces a block ---' -ForegroundColor Cyan
    # It saw part of the session and cannot know what the rest holds. The
    # ceiling is lowered through an isolated copy's own .env, never by writing
    # one next to the shipped hook.
    $partialHook = New-IsolatedHookCopy 'MAX_TRANSCRIPT_BYTES=100000'
    $padding = New-Object System.Collections.Generic.List[object]
    [void]$padding.Add((New-UserEntry $FeaturePrompt))
    for ($i = 0; $i -lt 120; $i++) { [void]$padding.Add((New-AssistantEntry ('x' * 1200))) }
    $tPartial = New-Transcript 'partial' $padding.ToArray()
    $rPartial = Fire (New-StopPayload -Cwd (New-Proj 'Partial') -Transcript $tPartial -SessionId 'p1') -HookPath $partialHook
    Check 'partial: a truncated read stays silent even with an unanswered request' (
        $rPartial.Exit -eq 0 -and $rPartial.Out -eq '') ($rPartial.Out + $rPartial.Err)
    # Control: the same hook copy, the same feature prompt, a transcript that
    # fits - so the silence above is the PARTIAL flag and not the copy itself.
    $rFits = Fire (New-StopPayload -Cwd (New-Proj 'PartialControl') -Transcript $tFeature -SessionId 'p2') -HookPath $partialHook
    Check 'partial control: the same copy still blocks on a transcript that fits' (
        Test-Blocked $rFits.Out) ($rFits.Out + $rFits.Err)

    # =====================================================================
    Write-Host ''
    Write-Host '--- the shipped source contract ---' -ForegroundColor Cyan
    # Persian lives in the hook as \uXXXX escapes that the .NET regex engine
    # decodes. The moment a real Persian character is pasted in, the file stops
    # reading identically on 5.1 and pwsh 7 - so ASCII is an assertion, not a
    # style preference.
    $nonAscii = @([regex]::Matches($HookText, '[^\x00-\x7F]'))
    Check 'source: the shipped hook is pure ASCII (Persian stays \uXXXX)' (
        $nonAscii.Count -eq 0) ([string]$nonAscii.Count)
    $exampleText = [System.IO.File]::ReadAllText($EnvExample)
    $declared = @([regex]::Matches($exampleText, '(?m)^([A-Z0-9_]+)=') | ForEach-Object { $_.Groups[1].Value })
    Check '.env.example documents MAX_TRANSCRIPT_BYTES' (
        $declared -contains 'MAX_TRANSCRIPT_BYTES') ($declared -join ',')
    $undocumented = @($declared | Where-Object { $HookText -notmatch [regex]::Escape($_) })
    Check '.env.example declares only keys the hook actually reads' (
        $undocumented.Count -eq 0) ($undocumented -join ',')

    # =====================================================================
    Write-Host ''
    Write-Host '--- Windows PowerShell 5.1 runs it identically ---' -ForegroundColor Cyan
    $r51Block = Fire (New-StopPayload -Cwd (New-Proj 'Ps51Gate') -Transcript $tFeature -SessionId 'w1') -Exe 'powershell'
    Check '5.1: the Stop gate blocks the same way' (
        (Test-Blocked $r51Block.Out) -and $r51Block.Exit -eq 0) ($r51Block.Out + $r51Block.Err)
    $r51Quiet = Fire (New-StopPayload -Cwd (New-Proj 'Ps51Quiet') -Transcript $tRan -SessionId 'w2') -Exe 'powershell'
    Check '5.1: a chain that ran is silent there too' (
        $r51Quiet.Exit -eq 0 -and $r51Quiet.Out -eq '') ($r51Quiet.Out + $r51Quiet.Err)
    $r51Banner = Fire (New-StopPayload -Cwd (New-Proj 'Ps51Banner') -Transcript $tBannerOnly -SessionId 'w3') -Exe 'powershell'
    Check '5.1: the self-banner guard holds there too' (
        $r51Banner.Exit -eq 0 -and $r51Banner.Out -eq '') ($r51Banner.Out + $r51Banner.Err)
}
finally {
    if ($KeepArtifacts) {
        Write-Host ('Artifacts kept at: ' + $Work) -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
