# Reply language (plan 012 step 6e, steering V45, custom-instructions.md SS2):
# every message to the user is in the language of the user's OWN typed words.
#
# Dot-sourced by _evidencelib.ps1 (optional, like _gatereceipts.ps1); definitions
# only. It lives here rather than in _hooklib.ps1 because that file is past the
# 800-line ceiling.
#
# WHY A HOOK SAYS THIS AT ALL: in long sessions the reply flips to English right
# after a compaction summary, a skill load or a Stop-hook block, because each of
# those arrives as English user-role text. The rule alone did not hold them, so
# the language is recorded from the prompt the user actually TYPED and repeated
# at exactly those three moments.
#
# Detection is deliberately coarse: Arabic-script letters outnumbering Latin
# letters means Persian (the only non-Latin language this user writes in); only
# Latin letters means English; anything else - a Persian question full of code
# identifiers, a prompt with no letters - leaves the recorded state unchanged.
# Text the user did not type (a skill expansion, a compaction summary, a replayed
# hook block, a system notification) is never detected from.
#
# State: one tiny file per session under %LOCALAPPDATA%\HookMaker\state, keyed by
# a hash of the session id. Advisory only - nothing here ever blocks.

$script:ReplyLanguageLine = 'LANGUAGE: the user writes in Persian. Every message in this turn, progress notes included, is in Persian; code, commands, file contents and commit messages stay English.'
$script:ReplyLanguageMaxAgeDays = 7
# Text that reaches UserPromptSubmit without being the user's typing.
$script:InjectedPromptMarkers = @(
    'Base directory for this skill',
    '(Re-invocation of',
    'This session is being continued from a previous conversation',
    'Stop hook feedback:',
    '[HOOKMAKER-CORRECTION:',
    '<system-reminder>',
    '<task-notification>',
    '[SYSTEM NOTIFICATION'
)
$script:ArabicScriptLetter = '[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]'

function Test-InjectedPromptText {
    param([AllowEmptyString()][string]$Text)
    foreach ($marker in $script:InjectedPromptMarkers) {
        if ($Text.IndexOf($marker, [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

# 'persian', 'english', or '' when the text does not decide it.
function Get-TypedPromptLanguage {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or (Test-InjectedPromptText $Text)) { return '' }
    $arabic = 0
    foreach ($m in [regex]::Matches($Text, $script:ArabicScriptLetter)) {
        if ([char]::IsLetter([string]$m.Value, 0)) { $arabic++ }
    }
    $latin = [regex]::Matches($Text, '[A-Za-z]').Count
    if ($arabic -gt $latin) { return 'persian' }
    if ($arabic -eq 0 -and $latin -gt 0) { return 'english' }
    return ''
}

function Get-ReplyLanguageStatePath {
    param($HookInput)
    $sessionId = [string](Get-Field $HookInput 'session_id')
    if ([string]::IsNullOrWhiteSpace($sessionId) -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return '' }
    return (Join-Path $env:LOCALAPPDATA ('HookMaker\state\ReplyLanguage-' + (Get-ShortHash $sessionId) + '.txt'))
}

function Read-ReplyLanguage {
    param($HookInput)
    $path = Get-ReplyLanguageStatePath -HookInput $HookInput
    if ([string]::IsNullOrEmpty($path)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
        return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)).Trim()
    }
    catch { return '' }
}

# Records the language of the typed prompt (UserPromptSubmit) and returns the
# language now in force for the session.
function Update-ReplyLanguage {
    param($HookInput)
    $current = Read-ReplyLanguage -HookInput $HookInput
    $detected = Get-TypedPromptLanguage -Text ([string](Get-Field $HookInput 'prompt'))
    if ([string]::IsNullOrEmpty($detected) -or $detected -eq $current) { return $current }
    # English is the default: a file is written only to record Persian, or to
    # switch a session that had recorded it back.
    if ($detected -eq 'english' -and [string]::IsNullOrEmpty($current)) { return $detected }
    $path = Get-ReplyLanguageStatePath -HookInput $HookInput
    if ([string]::IsNullOrEmpty($path)) { return $detected }
    try {
        $dir = Split-Path -Parent $path
        [void][System.IO.Directory]::CreateDirectory($dir)
        $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $detected, (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $path -Force
        # Bounded housekeeping: one directory listing, old session files only.
        $cutoff = [DateTime]::UtcNow.AddDays(-$script:ReplyLanguageMaxAgeDays)
        foreach ($old in @(Get-ChildItem -LiteralPath $dir -Filter 'ReplyLanguage-*.txt' -File -ErrorAction SilentlyContinue)) {
            if ($old.LastWriteTimeUtc -lt $cutoff) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    catch { }
    return $detected
}

# The fixed LANGUAGE line when the session's language is not English, else ''.
function Get-ReplyLanguageLine {
    param($HookInput, [string]$Prefix = '')
    if ((Read-ReplyLanguage -HookInput $HookInput) -ne 'persian') { return '' }
    return ($Prefix + $script:ReplyLanguageLine)
}
