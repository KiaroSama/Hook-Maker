# Writing-Voice-Check - every human-readable reply is shaped by the voice skill
# of its language (global-writing-voice-rules.md): Persian -> `persian`,
# Russian -> `great-russian`, English -> `humanizer:humanizer`.
#
# ROLE: ADVISORY on SessionStart/UserPromptSubmit, GATE (blocks once) on Stop
# (global-hook-rules.md SS Hook Roles; spec 038). A hook cannot load a skill, so
# the duty is stated up front and then judged from what the COMPLETE transcript
# proves - a client-recorded Skill call (or a Read of the skill body, the route
# for clients without skill keys), never prose:
#   - the newest typed prompt decides the reply language (the reply follows the
#     user's typed language, never a skill/hook/summary language);
#   - a mapped language with no load of its skill after the last compaction
#     boundary is refused once. A load before a compaction is gone from the
#     model's context, which is why the rules say "load it again".
# Never refused: SubagentStop, no/partial/unreadable transcript, no typed
# prompt, or a language with no mapped skill. HOOK_ENFORCEMENT=advisory|off
# softens or disables the refusal like every other gate.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')
# Written prose and commit/PR text (spec 041): advisory.
. (Join-Path $PSScriptRoot '_voicefiles.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop')) { exit 0 }

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$sessionId = [string](Get-Field $hookInput 'session_id')
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$voiceMap = @{
    persian = @{ Name = 'Persian'; Key = 'anthropic-skills:persian'; Body = '(?i)[\\/]persian[\\/]SKILL\.md$' }
    russian = @{ Name = 'Russian'; Key = 'anthropic-skills:great-russian'; Body = '(?i)[\\/]great-russian[\\/]SKILL\.md$' }
    english = @{ Name = 'English'; Key = 'humanizer:humanizer'; Body = '(?i)[\\/]humanizer[\\/](?:.*[\\/])?SKILL\.md$' }
}

# The script that dominates the typed text decides; a mixed or empty prompt
# returns '' so the previous decision stands. Russian lives here rather than in
# _replylanguage.ps1, whose consumers only know Persian and English.
function Get-VoiceLanguage {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if ($Text -match '(?im)^[ \t-]*(?:WRITING VOICE CHECK|VOICE:|WRITING VOICE:)') { return '' }
    if ((Get-Command Test-InjectedPromptText -ErrorAction SilentlyContinue) -and (Test-InjectedPromptText $Text)) { return '' }
    $arabic = [regex]::Matches($Text, '[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]').Count
    $cyrillic = [regex]::Matches($Text, '[\u0400-\u04FF]').Count
    $latin = [regex]::Matches($Text, '[A-Za-z]').Count
    if ($arabic -gt $latin -and $arabic -gt $cyrillic) { return 'persian' }
    if ($cyrillic -gt $latin -and $cyrillic -gt $arabic) { return 'russian' }
    if ($arabic -eq 0 -and $cyrillic -eq 0 -and $latin -gt 0) { return 'english' }
    return ''
}

# ---- SessionStart: the mapping, and a reload duty after compact/resume -------
if ($eventName -eq 'SessionStart') {
    $note = 'WRITING VOICE: match OUTPUT language voice skill (incl. comments/docstrings): Persian -> `anthropic-skills:persian`, Russian -> `anthropic-skills:great-russian`, English -> `humanizer:humanizer` (global-writing-voice-rules.md FULL). Load before first sentence; Stop blocks missing load.'
    $source = [string](Get-Field $hookInput 'source')
    if ($source -in @('compact', 'resume')) { $note += ' Session ' + $(if ($source -eq 'compact') { 'compacted' } else { 'resumed' }) + ': reload voice skill now.' }
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# ---- UserPromptSubmit: name the skill once per session and language ---------
if ($eventName -eq 'UserPromptSubmit') {
    if ($config.ContainsKey('PROMPT_REMINDER') -and [string]$config['PROMPT_REMINDER'] -eq '0') { exit 0 }
    if ($sessionId -eq '') { exit 0 }
    $prompt = [string](Get-Field $hookInput 'prompt')
    $language = Get-VoiceLanguage $prompt
    if ($language -eq '') { exit 0 }
    $seenPath = Join-Path $stateDir ('WritingVoiceCheck-seen-' + (Get-ShortHash $sessionId) + '.txt')
    $seen = ''
    try { if ([IO.File]::Exists($seenPath)) { $seen = [IO.File]::ReadAllText($seenPath) } } catch { }
    if ((',' + $seen + ',').Contains(',' + $language + ',')) { exit 0 }
    try { [void][IO.Directory]::CreateDirectory($stateDir); [IO.File]::WriteAllText($seenPath, ($(if ($seen -eq '') { $language } else { $seen.Trim() + ',' + $language }))) }
    catch { exit 0 }    # an unrecordable once-marker must not become a per-prompt note
    $entry = $voiceMap[$language]
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ('VOICE: reply in ' + $entry.Name + ' -> Skill `' + $entry.Key + '` before the first sentence (once per session, again after compaction).')
    exit $emit.ExitCode
}

# ---- Stop: the reply language's skill must be loaded since the last compaction
$gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Writing-Voice-Check' } else { $null }
try {
    if ((Get-Command Test-StopStandDown -ErrorAction SilentlyContinue) -and (Test-StopStandDown -HookInput $hookInput -HookName 'Writing-Voice-Check')) { exit 0 }
    if (-not $script:EvidenceLibReady) { exit 0 }
    $maxBytes = 20000000
    if ($config.ContainsKey('MAX_TRANSCRIPT_BYTES')) {
        $parsed = 0
        if ([int]::TryParse([string]$config['MAX_TRANSCRIPT_BYTES'], [ref]$parsed) -and $parsed -ge 100000) { $maxBytes = $parsed }
    }
    $evidence = Get-TranscriptToolEvidence -Path ([string](Get-Field $hookInput 'transcript_path')) -MaxBytes $maxBytes
    # Partial means the load may sit in the unread part: unknown, silent.
    if (-not $evidence.Ok -or $evidence.Partial) { exit 0 }

    $language = ''; $compactions = 0
    $loaded = @{ persian = $false; russian = $false; english = $false }
    $artifacts = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($evidence.Events)) {
        if ($item.Kind -eq 'prompt') { $detected = Get-VoiceLanguage ([string]$item.Value); if ($detected -ne '') { $language = $detected } }
        elseif ($item.Kind -eq 'compact') { $compactions++; foreach ($k in @($loaded.Keys)) { $loaded[$k] = $false }; $artifacts.Clear() }
        elseif ($item.Kind -eq 'write' -or ($item.Kind -eq 'shell' -and [string]$item.Value -match $script:VoiceCommitPattern)) { [void]$artifacts.Add($item) }
        elseif ($item.Kind -eq 'skill' -or $item.Kind -eq 'read') {
            foreach ($k in $voiceMap.Keys) {
                $entry = $voiceMap[$k]; $value = [string]$item.Value
                if ($item.Kind -eq 'skill') {
                    # The bare key or any plugin-qualified form of it (humanizer, humanizer:humanizer).
                    $bare = ($entry.Key -split ':')[-1]
                    if ($value -ieq $entry.Key -or $value -ieq $bare -or $value -match ('(?i):' + [regex]::Escape($bare) + '$')) { $loaded[$k] = $true }
                }
                elseif ($value -match $entry.Body) { $loaded[$k] = $true }
            }
        }
    }

    # Written-text languages: agent-private folders are not judged; the reply
    # language is the gate's, so it is not repeated here.
    $artifactNote = ''
    $cwdText = [string](Get-Field $hookInput 'cwd')
    if (Get-Command Get-VoiceArtifactLanguages -ErrorAction SilentlyContinue) {
        $public = @($artifacts | Where-Object { $_.Kind -ne 'write' -or [string]$_.Value -notmatch '(?i)(^|[\\/])(\.ai|\.claude|\.codex|\.agents|plans)[\\/]' })
        $missingLangs = @(Get-VoiceArtifactLanguages -Artifacts $public -Loaded $loaded -Detect ${function:Get-VoiceLanguage} -Cwd $cwdText | Where-Object { $_ -ne $language })
        if ($missingLangs.Count -gt 0 -and (Test-NewGateFingerprint -Name 'WritingVoiceFiles' -Cwd $cwdText -Fingerprint (Get-ShortHash ($sessionId + '|' + ($missingLangs -join ',') + '|' + [string]$compactions)))) {
            $artifactNote = 'VOICE (written text, incl. code comments/docstrings/help): ' + (@($missingLangs | ForEach-Object { $voiceMap[$_].Name + ' -> Skill `' + $voiceMap[$_].Key + '`' }) -join '; ') + ' not loaded since ' + $(if ($compactions -gt 0) { 'the last compaction' } else { 'start' }) + ', but files/commit/PR text in that language were written. Load it and re-check that text.'
        }
    }
    # Router standing order (V94): comment/doc prose added to CODE files is a
    # gate - blocks once when its voice skill was not loaded or omitted from Skills used:.
    if (Get-Command Get-VoiceCommentProse -ErrorAction SilentlyContinue) {
        $codeWrites = @($artifacts | Where-Object { $_.Kind -eq 'write' -and [string]$_.Value -match $script:VoiceCodeFile })
        $allCommentLangs = @(Get-VoiceArtifactLanguages -Artifacts $codeWrites -Loaded $loaded -Detect ${function:Get-VoiceLanguage} -Cwd $cwdText -All)
        $skillsValue = $null
        if ($allCommentLangs.Count -gt 0 -and (Get-Command Get-TaskClosingEvidence -ErrorAction SilentlyContinue)) {
            $closingEv = Get-TaskClosingEvidence -HookInput $hookInput
            if ($null -ne $closingEv -and $closingEv.Known) {
                $skillsDecl = Test-ClosingDeclaration -Text ([string]$closingEv.Text) -LabelPattern 'Skills[ \t]+used'
                if ($skillsDecl.Present) { $skillsValue = [string]$skillsDecl.Value }
            }
        }
        $commentLangs = @($allCommentLangs | Where-Object {
            $bare = ($voiceMap[$_].Key -split ':')[-1]
            (-not $loaded[$_]) -or ($null -ne $skillsValue -and $skillsValue -notmatch ('(?i)\b' + [regex]::Escape($bare) + '\b'))
        })
        if ($commentLangs.Count -gt 0) {
            $cfp = Get-ShortHash ($sessionId + '|comments|' + ($commentLangs -join ',') + '|' + [string]$compactions + '|' + [string]($null -ne $skillsValue))
            if (Test-NewGateFingerprint -Name 'WritingVoiceComments' -Cwd $cwdText -Fingerprint $cfp) {
                $keys = (@($commentLangs | ForEach-Object { $voiceMap[$_].Name + ' -> Skill `' + $voiceMap[$_].Key + '`' }) -join '; ')
                $cmsg = 'WRITING VOICE CHECK: code comments/docstrings/help text were added in ' + $keys + ' with no load or "Skills used:" entry since ' + $(if ($compactions -gt 0) { 'the last compaction' } else { 'start' }) + '. Load it, re-check those comments, and list it in "Skills used:".'
                exit (Write-StopBlockResult -HookInput $hookInput -HookName 'Writing-Voice-Check' -FindingFingerprint $cfp -EventName $eventName -Message $cmsg -Condition 'required-workflow').ExitCode
            }
        }
    }
    if ($language -eq '' -or $loaded[$language]) {
        if ($artifactNote -ne '') { exit (Write-HookResult -EventName $eventName -Kind 'advisory' -Message $artifactNote).ExitCode }
        exit 0
    }

    # Once per (session, language, compaction count): a new compaction re-arms it.
    $fingerprint = Get-ShortHash ($sessionId + '|' + $language + '|' + [string]$compactions)
    if (-not (Test-NewGateFingerprint -Name 'WritingVoiceCheck' -Cwd ([string](Get-Field $hookInput 'cwd')) -Fingerprint $fingerprint)) {
        if ($artifactNote -ne '') { exit (Write-HookResult -EventName $eventName -Kind 'advisory' -Message $artifactNote).ExitCode }
        exit 0
    }
    $entry = $voiceMap[$language]
    $since = if ($compactions -gt 0) { 'the last compaction' } else { 'start' }
    $blockMessage = @(
        ('WRITING VOICE CHECK: replies are ' + $entry.Name + '; no `' + $entry.Key + '` load since ' + $since + '.'),
        ('Load Skill `' + $entry.Key + '` (or read its SKILL.md), then re-check the reply against it (global-writing-voice-rules.md).')
    ) -join "`n"
    if ($artifactNote -ne '') { $blockMessage += "`n" + $artifactNote }
    $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Writing-Voice-Check' -FindingFingerprint $fingerprint -EventName $eventName -Message $blockMessage -Condition 'required-workflow'
    exit $emit.ExitCode
}
catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
