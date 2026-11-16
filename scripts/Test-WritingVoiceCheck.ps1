# Offline test suite for Writing-Voice-Check (spec 038).
#
# The hook never loads a skill itself; what it decides is (1) which language the
# user typed, (2) whether the matching voice skill was loaded - by Skill call or
# by reading its SKILL.md - after the last compaction, and (3) whether this exact
# refusal was already given. Each decision is pinned here with real client
# record shapes.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-WritingVoiceCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Writing-Voice-Check\Writing-Voice-Check.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 600
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-voicetest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null

# The suite stays ASCII: non-Latin prompts are built from code points.
function New-Text { param([int[]]$Codes) return (-join @($Codes | ForEach-Object { [char]$_ })) }
$PersianPrompt = New-Text @(0x0644, 0x0637, 0x0641, 0x0627, 0x0020, 0x0627, 0x06CC, 0x0646, 0x0020, 0x0628, 0x0627, 0x06AF, 0x0020, 0x0631, 0x0627, 0x0020, 0x062F, 0x0631, 0x0633, 0x062A, 0x0020, 0x06A9, 0x0646)
$RussianPrompt = New-Text @(0x0438, 0x0441, 0x043F, 0x0440, 0x0430, 0x0432, 0x044C, 0x0020, 0x044D, 0x0442, 0x0443, 0x0020, 0x043E, 0x0448, 0x0438, 0x0431, 0x043A, 0x0443)
$EnglishPrompt = 'please fix this bug in the parser'
$OtherPrompt = New-Text @(0x4FEE, 0x590D, 0x8FD9, 0x4E2A, 0x9519, 0x8BEF)

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

function Fire {
    param([string]$Cwd, [string]$EventName = 'Stop', [string]$SessionId = 't', [string]$TranscriptPath = '',
        [string]$Prompt = '', [string]$Source = '', [string]$Exe = 'pwsh')
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($TranscriptPath -ne '') { $obj['transcript_path'] = $TranscriptPath }
    if ($Prompt -ne '') { $obj['prompt'] = $Prompt }
    if ($Source -ne '') { $obj['source'] = $Source }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    Write-Utf8 $inFile ($obj | ConvertTo-Json)
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $Hook + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"' }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
        Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $FakeLocalAppData }
    }
    $proc = Start-BoundedProcess @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Steps: 'prompt:<text>', 'skill:<key>', 'read:<path>', 'compact'.
function New-VoiceTranscript {
    param([string]$Name, [string[]]$Steps)
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($Steps)) {
        if ($s -like 'prompt:*') { $doc = @{ type = 'user'; message = @{ role = 'user'; content = $s.Substring(7) } } }
        elseif ($s -eq 'compact') { $doc = @{ type = 'user'; isCompactSummary = $true; message = @{ role = 'user'; content = 'This session is being continued from a previous conversation.' } } }
        elseif ($s -like 'skill:*') { $doc = @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Skill'; input = @{ skill = $s.Substring(6) } }) } } }
        else { $doc = @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Read'; input = @{ file_path = $s.Substring(5) } }) } } }
        [void]$entries.Add(($doc | ConvertTo-Json -Depth 8 -Compress))
    }
    [void]$entries.Add((@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = 'Done.' }) } } | ConvertTo-Json -Depth 8 -Compress))
    $path = Join-Path $Work ($Name + '.jsonl')
    [System.IO.File]::WriteAllText($path, (($entries.ToArray() -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

$blockPattern = '"decision"\s*:\s*"block"'
try {
    Write-Host ''
    Write-Host '--- SessionStart: the mapping, and a reload duty after compaction/resume ---' -ForegroundColor Cyan
    $p = New-Proj 'Start'
    $rStart = Fire -Cwd $p -EventName 'SessionStart' -SessionId 's1' -Source 'startup'
    Check 'start: names all three skills' ($rStart.Exit -eq 0 -and $rStart.Out -match 'WRITING VOICE' -and $rStart.Out -match '`persian`' -and $rStart.Out -match '`great-russian`' -and $rStart.Out -match '`humanizer:humanizer`') ($rStart.Out + $rStart.Err)
    Check 'start: a fresh session carries no reload line' ($rStart.Out -notmatch 'reload the skill now') $rStart.Out
    $rCompact = Fire -Cwd $p -EventName 'SessionStart' -SessionId 's1' -Source 'compact'
    Check 'start: source=compact adds the reload duty' ($rCompact.Out -match 'compacted: earlier loads are gone, reload the skill now') $rCompact.Out
    $rResume = Fire -Cwd $p -EventName 'SessionStart' -SessionId 's1' -Source 'resume'
    Check 'start: source=resume adds the reload duty' ($rResume.Out -match 'resumed: earlier loads are gone') $rResume.Out

    Write-Host ''
    Write-Host '--- UserPromptSubmit: once per session and language ---' -ForegroundColor Cyan
    $rFa = Fire -Cwd $p -EventName 'UserPromptSubmit' -SessionId 'u1' -Prompt $PersianPrompt
    Check 'prompt: Persian -> Skill persian' ($rFa.Out -match 'VOICE: reply in Persian -> Skill `persian`') ($rFa.Out + $rFa.Err)
    $rFa2 = Fire -Cwd $p -EventName 'UserPromptSubmit' -SessionId 'u1' -Prompt $PersianPrompt
    Check 'prompt: the same language is not repeated in a session' ($rFa2.Exit -eq 0 -and $rFa2.Out -eq '') $rFa2.Out
    $rRu = Fire -Cwd $p -EventName 'UserPromptSubmit' -SessionId 'u1' -Prompt $RussianPrompt
    Check 'prompt: a new language in the same session is named once' ($rRu.Out -match 'Russian -> Skill `great-russian`') $rRu.Out
    $rEn = Fire -Cwd $p -EventName 'UserPromptSubmit' -SessionId 'u2' -Prompt $EnglishPrompt
    Check 'prompt: English -> humanizer' ($rEn.Out -match 'English -> Skill `humanizer:humanizer`') $rEn.Out
    $rOther = Fire -Cwd $p -EventName 'UserPromptSubmit' -SessionId 'u3' -Prompt $OtherPrompt
    Check 'prompt: an unmapped language is silent' ($rOther.Exit -eq 0 -and $rOther.Out -eq '') $rOther.Out

    Write-Host ''
    Write-Host '--- Stop gate over the complete transcript ---' -ForegroundColor Cyan
    $g = New-Proj 'GateFa'
    $rNo = Fire -Cwd $g -SessionId 'g-fa' -TranscriptPath (New-VoiceTranscript 'g-fa' @("prompt:$PersianPrompt"))
    Check 'gate: Persian replies, no persian load -> blocked' ($rNo.Out -match $blockPattern -and $rNo.Out -match 'WRITING VOICE CHECK: replies are Persian; no `persian` load since start') ($rNo.Out + $rNo.Err)
    $rNoAgain = Fire -Cwd $g -SessionId 'g-fa' -TranscriptPath (New-VoiceTranscript 'g-fa2' @("prompt:$PersianPrompt"))
    Check 'gate: the unchanged finding is not refused twice' ($rNoAgain.Out -notmatch $blockPattern) $rNoAgain.Out
    $rOk = Fire -Cwd (New-Proj 'GateFaOk') -SessionId 'g-fa-ok' -TranscriptPath (New-VoiceTranscript 'g-fa-ok' @("prompt:$PersianPrompt", 'skill:persian'))
    Check 'gate: Persian with Skill persian -> silent' ($rOk.Exit -eq 0 -and $rOk.Out -eq '') ($rOk.Out + $rOk.Err)
    $rWrong = Fire -Cwd (New-Proj 'GateWrong') -SessionId 'g-wrong' -TranscriptPath (New-VoiceTranscript 'g-wrong' @("prompt:$PersianPrompt", 'skill:humanizer:humanizer'))
    Check 'gate: the wrong language''s skill does not clear it' ($rWrong.Out -match 'no `persian` load') $rWrong.Out
    $rRuNo = Fire -Cwd (New-Proj 'GateRu') -SessionId 'g-ru' -TranscriptPath (New-VoiceTranscript 'g-ru' @("prompt:$RussianPrompt"))
    Check 'gate: Russian without great-russian -> blocked' ($rRuNo.Out -match 'replies are Russian; no `great-russian` load') $rRuNo.Out
    $rEnOk = Fire -Cwd (New-Proj 'GateEn') -SessionId 'g-en' -TranscriptPath (New-VoiceTranscript 'g-en' @("prompt:$EnglishPrompt", 'skill:humanizer:humanizer'))
    Check 'gate: English with humanizer:humanizer -> silent' ($rEnOk.Out -eq '') $rEnOk.Out
    $rEnNo = Fire -Cwd (New-Proj 'GateEnNo') -SessionId 'g-en-no' -TranscriptPath (New-VoiceTranscript 'g-en-no' @("prompt:$EnglishPrompt"))
    Check 'gate: English without humanizer -> blocked' ($rEnNo.Out -match 'no `humanizer:humanizer` load') $rEnNo.Out
    $rLatest = Fire -Cwd (New-Proj 'GateLatest') -SessionId 'g-latest' -TranscriptPath (New-VoiceTranscript 'g-latest' @("prompt:$EnglishPrompt", 'skill:humanizer:humanizer', "prompt:$PersianPrompt"))
    Check 'gate: the newest typed prompt decides the language' ($rLatest.Out -match 'replies are Persian') $rLatest.Out

    $rCompactGate = Fire -Cwd (New-Proj 'GateCompact') -SessionId 'g-c' -TranscriptPath (New-VoiceTranscript 'g-c' @("prompt:$PersianPrompt", 'skill:persian', 'compact', "prompt:$PersianPrompt"))
    Check 'gate: a load before the last compaction does not count' ($rCompactGate.Out -match 'since the last compaction') $rCompactGate.Out
    $rReload = Fire -Cwd (New-Proj 'GateReload') -SessionId 'g-r' -TranscriptPath (New-VoiceTranscript 'g-r' @("prompt:$PersianPrompt", 'compact', 'skill:persian'))
    Check 'gate: a reload after the compaction clears it' ($rReload.Out -eq '') $rReload.Out
    $rCompactOnly = Fire -Cwd (New-Proj 'GateSummaryText') -SessionId 'g-s' -TranscriptPath (New-VoiceTranscript 'g-s' @('compact', "prompt:$EnglishPrompt", 'skill:humanizer:humanizer'))
    Check 'gate: the English compaction summary is not a typed prompt' ($rCompactOnly.Out -eq '') $rCompactOnly.Out

    $body = 'C:\Users\x\AppData\Local\skills-plugin\a\b\skills\persian\SKILL.md'
    $rBody = Fire -Cwd (New-Proj 'GateBody') -SessionId 'g-b' -TranscriptPath (New-VoiceTranscript 'g-b' @("prompt:$PersianPrompt", "read:$body"))
    Check 'gate: reading the skill body counts as a load (Codex route)' ($rBody.Out -eq '') $rBody.Out
    $hBody = 'C:\Users\x\.claude\plugins\cache\humanizer\humanizer\1.2.0\SKILL.md'
    $rHBody = Fire -Cwd (New-Proj 'GateHBody') -SessionId 'g-hb' -TranscriptPath (New-VoiceTranscript 'g-hb' @("prompt:$EnglishPrompt", "read:$hBody"))
    Check 'gate: a humanizer SKILL.md read counts for English' ($rHBody.Out -eq '') $rHBody.Out

    $rUnmapped = Fire -Cwd (New-Proj 'GateOther') -SessionId 'g-o' -TranscriptPath (New-VoiceTranscript 'g-o' @("prompt:$OtherPrompt"))
    Check 'gate: an unmapped language is never refused' ($rUnmapped.Exit -eq 0 -and $rUnmapped.Out -eq '') $rUnmapped.Out
    $rSub = Fire -Cwd (New-Proj 'GateSub') -EventName 'SubagentStop' -SessionId 'g-sub' -TranscriptPath (New-VoiceTranscript 'g-sub' @("prompt:$PersianPrompt"))
    Check 'gate: SubagentStop is never refused' ($rSub.Exit -eq 0 -and $rSub.Out -eq '') $rSub.Out
    $rNone = Fire -Cwd (New-Proj 'GateNone') -SessionId 'g-n'
    Check 'gate: no transcript is unknown evidence - silent' ($rNone.Exit -eq 0 -and $rNone.Out -eq '') $rNone.Out
    $rOwn = Fire -Cwd (New-Proj 'GateOwn') -SessionId 'g-own' -TranscriptPath (New-VoiceTranscript 'g-own' @("prompt:$PersianPrompt", 'skill:persian', "prompt:WRITING VOICE CHECK: replies are English; no load"))
    Check 'gate: the hook''s own refusal is not a typed English prompt' ($rOwn.Out -eq '') $rOwn.Out

    Write-Host ''
    Write-Host '--- the shipped .env.example documents only what the hook reads ---' -ForegroundColor Cyan
    $examplePath = Join-Path (Split-Path -Parent $Hook) '.env.example'
    Check '.env.example ships beside the hook' (Test-Path -LiteralPath $examplePath -PathType Leaf)
    $exampleText = [System.IO.File]::ReadAllText($examplePath)
    $declared = @([regex]::Matches($exampleText, '(?m)^([A-Z0-9_]+)=') | ForEach-Object { $_.Groups[1].Value })
    $hookText = [System.IO.File]::ReadAllText($Hook)
    $undocumented = @($declared | Where-Object { $hookText -notmatch [regex]::Escape($_) })
    Check 'every key in .env.example is one the hook reads' ($declared.Count -gt 0 -and $undocumented.Count -eq 0) ($undocumented -join ',')

    Write-Host ''
    Write-Host '--- Windows PowerShell 5.1 runs it identically ---' -ForegroundColor Cyan
    $r51 = Fire -Cwd (New-Proj 'Ps51') -SessionId 'g-51' -TranscriptPath (New-VoiceTranscript 'g-51' @("prompt:$RussianPrompt")) -Exe 'powershell'
    Check '5.1: Russian detection and the refusal hold there too' ($r51.Out -match 'replies are Russian') ($r51.Out + $r51.Err)
}
finally {
    if ($KeepArtifacts) { Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray }
    elseif (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
