from pathlib import Path
import re

root = Path('.')
def read(name):
    return (root / name).read_text(encoding='utf-8-sig')
def write(name, text):
    path = root / name
    old = path.read_bytes()
    newline = '\r\n' if b'\r\n' in old else '\n'
    prefix = b'\xef\xbb\xbf' if old.startswith(b'\xef\xbb\xbf') else b''
    path.write_bytes(prefix + text.replace('\r\n', '\n').replace('\n', newline).encode('utf-8'))
def function(text, name, body):
    start = re.search(r'^function ' + re.escape(name) + r' \{', text, re.M)
    assert start, name
    end = re.search(r'^}', text[start.end():], re.M)
    assert end, name
    return text[:start.start()] + body.rstrip() + text[start.end() + end.end():]

name = 'hooks/Session-Summary-Check/_generation.ps1'
s = read(name)
a = s.index('# 2. Readiness'); b = s.index('# THE ALLOWANCE', a)
s = s[:a] + '''# 2. A Stop event is not evidence that a summary exists, nor that every gate
#    passed. The observer requires eligible CURRENT assistant text. Only an
#    explicit ready record with evidence can support readiness; absent gate
#    observations stay unverified. Historical blocks are not current verdicts.
#    This store never authorizes skipping a gate or claims control of a UI.
#
''' + s[b:]
s = s.replace('''#    A design whose correctness depends on holding the final section back cannot
#    be built on either supported client, and this one does not pretend to.''', '''#    This passive observer does not own the client's output transport. A
#    display-level guarantee needs an output-owning integration, not this store.''')
s = function(s, 'Test-GenerationEntryShape', r'''function Test-GenerationEntryShape {
    param($Entry)
    if ($Entry -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation entry shape' }
    foreach ($name in @('taskId', 'actor', 'state', 'evidence', 'verdicts', 'publication', 'endedAt')) {
        if ($null -eq $Entry.PSObject.Properties[$name]) { throw 'missing generation field' }
    }
    Test-GenerationKeyShape -Value $Entry
    if ($Entry.state -isnot [string] -or $Entry.state -cnotin ($script:GenerationLiveStates + $script:GenerationTerminalStates)) { throw 'generation vocabulary' }
    if ($Entry.evidence -isnot [string] -or $Entry.evidence.Length -gt 4096) { throw 'generation evidence shape' }
    $terminal = $Entry.state -cin $script:GenerationTerminalStates
    if ($terminal) { Test-GenerationTimestamp $Entry.endedAt }
    elseif ($null -ne $Entry.endedAt -and $Entry.endedAt -cne '') { throw 'generation terminality' }
    if ($Entry.verdicts -isnot [System.Array] -or @($Entry.verdicts).Count -gt 64) { throw 'unbounded generation verdicts' }
    $seen = @{}
    foreach ($verdict in @($Entry.verdicts)) {
        if ($verdict -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation verdict shape' }
        foreach ($name in @('gate', 'affirmative', 'at')) {
            if ($null -eq $verdict.PSObject.Properties[$name]) { throw 'malformed generation verdict' }
        }
        if ($verdict.gate -isnot [string] -or $verdict.gate -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or $seen.ContainsKey($verdict.gate)) { throw 'generation verdict name' }
        if ($verdict.affirmative -isnot [bool]) { throw 'generation verdict boolean' }
        Test-GenerationTimestamp $verdict.at
        $seen[$verdict.gate] = $true
    }
    if ($null -ne $Entry.publication) {
        $pub = $Entry.publication
        if ($pub -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation publication shape' }
        foreach ($name in @('at', 'ready', 'failure', 'reported')) {
            if ($null -eq $pub.PSObject.Properties[$name]) { throw 'missing publication field' }
        }
        Test-GenerationTimestamp $pub.at
        if ($pub.ready -isnot [bool] -or $pub.reported -isnot [bool] -or $pub.failure -isnot [string] -or $pub.failure.Length -gt 8192) { throw 'generation publication fields' }
        if (($pub.ready -and $pub.failure -ne '') -or (-not $pub.ready -and [string]::IsNullOrWhiteSpace($pub.failure))) { throw 'generation publication verdict' }
    }
}

function Test-GenerationKeyShape {
    param($Value)
    foreach ($name in @('taskId', 'actor')) {
        if ($null -eq $Value.PSObject.Properties[$name] -or $Value.$name -isnot [string]) { throw 'generation key shape' }
    }
    if ($Value.taskId -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or $Value.actor.Length -gt 256) { throw 'generation identity' }
}

function Test-GenerationTimestamp {
    param($Value)
    # Older Core JSON decoders materialize ISO dates; Windows PowerShell keeps
    # strings. Both representations denote the same timestamp, not a boolean.
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw 'generation timestamp timezone' }
        return
    }
    $parsed = [DateTime]::MinValue
    if ($Value -isnot [string] -or -not [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -or $parsed.Kind -eq [DateTimeKind]::Unspecified) { throw 'generation timestamp' }
}''')
s = s.replace('        $doc = Read-JsonFile -Path $Path', '''        $raw = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $doc = $raw | ConvertFrom-Json -DateKind String }
        else { $doc = $raw | ConvertFrom-Json }''')
s = s.replace("        if ($doc.client -notin @('claude', 'codex')) { throw 'generation client' }", "        if ($doc.client -isnot [string] -or $doc.client -cnotin @('claude', 'codex') -or $doc.sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($doc.sessionId)) { throw 'generation client or session' }")
s = s.replace('        foreach ($entry in @($doc.generations)) { Test-GenerationEntryShape -Entry $entry }', '''        $identities = @{}
        foreach ($entry in @($doc.generations)) {
            Test-GenerationEntryShape -Entry $entry
            $key = @($entry.taskId, $entry.actor) | ConvertTo-Json -Compress
            if ($identities.ContainsKey($key)) { throw 'duplicate generation identity' }
            $identities[$key] = $true
        }
        foreach ($stone in @($doc.tombstones)) {
            if ($stone -isnot [System.Management.Automation.PSCustomObject]) { throw 'tombstone shape' }
            Test-GenerationKeyShape $stone
            Test-GenerationTimestamp (Get-Field $stone 'endedAt')
            $key = @($stone.taskId, $stone.actor) | ConvertTo-Json -Compress
            if ($identities.ContainsKey($key)) { throw 'duplicate or resurrected tombstone' }
            $identities[$key] = $true
        }''')
s = s.replace('        $mutateResult = & $Mutate $doc $identity $Arguments', '''        # Recheck identity after the wait: do not attribute a delayed mutation to
        # a task that was replaced while another handler owned this store lock.
        $current = Get-GenerationIdentity $HookInput
        if ($null -eq $current -or $current.TaskId -cne $identity.TaskId -or $current.Actor -cne $identity.Actor) {
            return [pscustomobject]@{ Ok = $false; State = 'identity-changed'; Result = $null }
        }
        $before = $doc | ConvertTo-Json -Depth 10 -Compress
        $mutateResult = & $Mutate $doc $identity $Arguments
        $after = $doc | ConvertTo-Json -Depth 10 -Compress
        if ($before -ceq $after) { return [pscustomobject]@{ Ok = $true; State = 'ok'; Result = $mutateResult } }''')
s = s.replace("            'generation retired' { 'retired'; break }", "            'generation retired' { 'retired'; break }\n            'generation terminal' { 'terminal'; break }\n            'generation invalid transition' { 'invalid-transition'; break }")
s = s.replace('    # Collection runs HERE and nowhere else:', "    if (Test-GenerationRetired -Doc $Doc -TaskId $Identity.TaskId -Actor $Identity.Actor) { throw 'generation retired' }\n    # Collection runs HERE and nowhere else:")
s = function(s, 'Remove-TerminalGenerations', '''function Remove-TerminalGenerations {
    param($Doc)
    $kept = New-Object System.Collections.ArrayList
    $stones = New-Object System.Collections.ArrayList
    foreach ($stone in @($Doc.tombstones)) { [void]$stones.Add($stone) }
    $collected = 0
    foreach ($entry in @($Doc.generations)) {
        # Terminality alone is not disposal authority. An unresolved verdict or
        # an unreported/unknown publication must remain available for review.
        $eligible = $entry.state -ceq 'finalized' -and $null -ne $entry.publication -and
            $entry.publication.ready -is [bool] -and $entry.publication.ready -and
            @($entry.verdicts | Where-Object { -not $_.affirmative }).Count -eq 0
        if ($eligible -and $stones.Count -lt $script:GenerationMaxTombstones) {
            [void]$stones.Add([pscustomobject][ordered]@{ taskId = $entry.taskId; actor = $entry.actor; endedAt = $entry.endedAt })
            $collected++
        }
        else { [void]$kept.Add($entry) }
    }
    # Never rotate away replay protection to make room. With no trustworthy
    # client replay horizon, capacity is an explicit refusal, not eviction.
    $Doc.generations = @($kept.ToArray())
    $Doc.tombstones = @($stones.ToArray())
    return $collected
}''')
s = s.replace("    if ($state.State -ne 'valid') { return $null }", "    if ($state.State -ne 'valid' -or $state.Doc.sessionId -cne $identity.Scope.Session -or $state.Doc.client -cne $identity.Scope.Client) { return $null }")
s = s.replace('        $entry.state = $opt.Target', '''        if ($entry.state -cin $script:GenerationTerminalStates) {
            if ($entry.state -cne $opt.Target -or ($opt.Evidence -ne '' -and $entry.evidence -cne $opt.Evidence)) { throw 'generation terminal' }
            return $entry.state
        }
        if ($opt.Target -ceq 'finalized' -and ($null -eq $entry.publication -or -not $entry.publication.ready -or
            @($entry.verdicts | Where-Object { -not $_.affirmative }).Count -gt 0)) { throw 'generation invalid transition' }
        $entry.state = $opt.Target''')
s = s.replace("    $safe = [System.Text.RegularExpressions.Regex]::Replace($Gate, '[^A-Za-z0-9-]+', '')\n    if ($safe -eq '')", "    $safe = $Gate\n    if ($safe -cnotmatch '^[A-Za-z0-9-]{1,64}$')")
s = s.replace('        $kept = @(@($entry.verdicts) | Where-Object', "        if ($entry.state -cin $script:GenerationTerminalStates) { throw 'generation terminal' }\n        $kept = @(@($entry.verdicts) | Where-Object")
s = function(s, 'Test-GenerationReady', '''function Get-GenerationReadiness {
    param($Entry, [string[]]$Objections = @(), [string]$Evidence = '')
    $missing = New-Object System.Collections.ArrayList
    if ($null -eq $Entry) { return [pscustomobject]@{ Ready = $false; Missing = @('generation-unknown'); Evidence = '' } }
    if ($Entry.state -cnotin @('ready', 'finalized') -or [string]::IsNullOrWhiteSpace($Entry.evidence)) {
        [void]$missing.Add('validation-not-recorded')
    }
    foreach ($name in @($Objections)) {
        if ($name -cmatch '^[A-Za-z0-9._:-]{1,128}$') { [void]$missing.Add($name) }
        else { [void]$missing.Add('unverified-objection') }
    }
    foreach ($verdict in @($Entry.verdicts)) {
        if (-not $verdict.affirmative) { [void]$missing.Add($verdict.gate) }
    }
    if ($Evidence -ne '' -and $Entry.evidence -cne $Evidence) { [void]$missing.Add('evidence-moved') }
    $unique = @($missing | Sort-Object -Unique)
    return [pscustomobject]@{ Ready = ($unique.Count -eq 0); Missing = $unique; Evidence = $Entry.evidence }
}

function Test-GenerationReady {
    param([Parameter(Mandatory = $true)]$HookInput, [string[]]$Objections = @(), [AllowEmptyString()][string]$Evidence = '')
    return (Get-GenerationReadiness -Entry (Get-GenerationRecord $HookInput) -Objections $Objections -Evidence $Evidence)
}''')
s = s.replace('''        # Exactly once per generation. A duplicate or delayed handler resolves
        # to the record the first one committed instead of writing a second,
        # which is what stops one generation producing two summaries.''', '''        # At most one OBSERVATION record per generation. Repeated callback
        # delivery resolves to the first record; this does not prevent an agent
        # from displaying a second summary outside this observer's control.''')
s = s.replace('        $named = @(@($opt.Missing) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })', '''        if ($entry.state -cin $script:GenerationTerminalStates) { throw 'generation terminal' }
        # The caller's earlier read is advisory. A verdict can arrive before
        # this lock is acquired; derive the committed decision under this lock.
        $check = Get-GenerationReadiness -Entry $entry -Objections $opt.Missing
        $confirmedReady = $opt.Ready -and $check.Ready
        $named = @($check.Missing)
        if (@($opt.Missing).Count -gt 0) { $named = @($named | Where-Object { $_ -ne 'validation-not-recorded' }) }
        if (-not $opt.Ready -and $named.Count -eq 0) { $named = @('readiness-unverified') }''')
s = s.replace('ready = $opt.Ready; failure = $(if ($opt.Ready)', 'ready = $confirmedReady; failure = $(if ($confirmedReady)')
s = s.replace('        if ($opt.Ready) {', '        if ($confirmedReady) {')
s = s.replace('        foreach ($entry in @($doc.generations)) {\n            if ($null -eq $entry.publication)', '        foreach ($entry in @($doc.generations)) {\n            if ($entry.actor -cne $identity.Actor) { continue }\n            if ($null -eq $entry.publication)')
s = s.replace("Reason = 'nothing terminal to collect'", "Reason = 'no safely collectable record or tombstone capacity exhausted'")
s += r'''

function Test-GenerationSummaryText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 1048576) { return $false }
    $done = '(?:DONE|\u0686\u06cc\s+\u0634\u062f|\u0627\u0646\u062c\u0627\u0645[\s\u200c-]*\u0634\u062f\u0647)'
    $remaining = '(?:REMAINING|\u0686\u06cc\s+\u0645\u0648\u0646\u062f|\u0628\u0627\u0642\u06cc[\s\u200c-]*\u0645\u0627\u0646\u062f\u0647)'
    $prefix = '^ {0,3}(?:[-*#]+[ \t]*)?'
    $suffix = '(?:[ \t]*\*{1,2})?[ \t]*(?::|[-\u2013\u2014]|$)[ \t]*(.*)$'
    $section = ''; $doneBody = $false; $remainingBody = $false
    $fence = ''; $fenceLength = 0
    foreach ($raw in @($Text -split '\r?\n')) {
        $line = $raw -replace '[\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]', ''
        if ($line -match '^[ \t]*>' -or $line -match '^(?: {4}|\t)') { continue }
        if ($line -match '^ {0,3}(`{3,}|~{3,})(.*)$') {
            $marker = $Matches[1]; $rest = $Matches[2]
            if ($fence -eq '') { $fence = $marker.Substring(0, 1); $fenceLength = $marker.Length }
            elseif ($marker.StartsWith($fence) -and $marker.Length -ge $fenceLength -and $rest.Trim() -eq '') { $fence = ''; $fenceLength = 0 }
            continue
        }
        if ($fence -ne '') { continue }
        if ($line -match ($prefix + $done + $suffix)) { $section = 'done'; $line = $Matches[1] }
        elseif ($line -match ($prefix + $remaining + $suffix)) {
            if ($section -eq '' -or -not $doneBody) { return $false }
            $section = 'remaining'; $line = $Matches[1]
        }
        $body = $line.Trim().Trim('*', '-', '#', ' ').Trim()
        if ($body -eq '' -or $body -match '^(?:<[^>]*>|TBD|TODO|\.\.\.)$') { continue }
        if ($section -eq 'done') { $doneBody = $true }
        elseif ($section -eq 'remaining') { $remainingBody = $true }
    }
    return ($doneBody -and $remainingBody)
}

function Observe-GenerationSummary {
    param([Parameter(Mandatory = $true)]$HookInput)
    # Stop timing is not content evidence. The shared reader enforces current
    # role and child provenance and never borrows a parent's last response.
    $closing = Get-ClosingAssistantText -HookInput $HookInput
    if (-not $closing.Known -or -not (Test-GenerationSummaryText $closing.Text)) { return }
    # This observer has no complete affirmative gate manifest. Absence of old
    # objections is not proof of readiness, and old blocks are only history.
    $null = Publish-GenerationSummary -HookInput $HookInput -Ready $false -Missing @('readiness-unverified')
}
'''
write(name, s)
name = 'hooks/Session-Summary-Check/Session-Summary-Check.ps1'; s = read(name)
s = s.replace('''# Stop and SubagentStop are silent. A registration that still names them (an
# installation predating this change) runs the hook and gets nothing, which
# is exactly right for a Stop advisory with nothing to act on. Nothing here
# keys on stop_hook_active: that flag belongs to the gates.''', '''# Stop and SubagentStop are registered silent observers. They record only a
# genuine current summary, never infer publication from the event name. Nothing
# here keys on stop_hook_active: that flag belongs to the gates.''')
s = s.replace('''# moment at which the summary has actually been published, so it is the only
# moment at which that fact can be recorded. It is written here and NAMED later,''', '''# event where a completed response can be inspected. The response must actually
# contain a summary; the event name is not that proof. It is NAMED later,''')
s = s.replace('    if ($null -ne (Get-Command Publish-GenerationSummary -ErrorAction SilentlyContinue)) {', '    if ($null -ne (Get-Command Observe-GenerationSummary -ErrorAction SilentlyContinue)) {')
a = s.index('            $stopBlocked ='); b = s.index('\n        }', a)
s = s[:a] + '            Observe-GenerationSummary -HookInput $hookInput' + s[b:]
s = s.replace("'NOTED ONCE, NO ACTION NEEDED: the previous wrap-up went out while ' + $pastFailure + ' was still open.'", "'NOTED ONCE, NO ACTION NEEDED: a wrap-up was observed, but its readiness was not verified (' + $pastFailure + ').'")
write(name, s)
name = 'scripts/Setup-SyncGroupPresentation.ps1'; s = read(name)
old = "'Session-Summary-Check'            = @{ Order = 28; When = 'pre'; Text = 'asks the closing reply for a done / still-open summary'; Events = @('SessionStart', 'UserPromptSubmit'); Timeout = 10 }"
assert old in s
s = s.replace(old, old.replace("@('SessionStart', 'UserPromptSubmit')", "@('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop')"))
s = s.replace('    # shipped with twice. See the hook header.', '    # shipped with twice. Stop events now OBSERVE only and return no output.\n    # Recording must be registered too; the pre-task timing tag names speech.')
write(name, s)
name = 'scripts/_installeventmigration.ps1'; s = read(name)
old = "        Reason  = 'the retired shipped default; the hook exits 0 on every event other than SessionStart and UserPromptSubmit, so this binding delivers nothing'\n    }"
assert old in s
s = s.replace(old, "        Reason  = 'the retired closing-only default; it never delivers the pre-task summary requirement'\n    }\n    [pscustomobject]@{\n        Version = 2\n        Hook    = 'Session-Summary-Check'\n        From    = @('SessionStart', 'UserPromptSubmit')\n        Reason  = 'the prior shipped default delivered policy but never invoked the silent publication observer'\n    }")
write(name, s)
name = 'scripts/Test-Generation.ps1'; s = read(name)
s = s.replace('        verdicts = @(); publication = $null; endedAt = $endedAt', "        verdicts = @(); publication = $(if ($State -eq 'finalized') { [pscustomobject]@{ at = $endedAt; ready = $true; failure = ''; reported = $false } } else { $null }); endedAt = $endedAt")
s = s.replace("    $null = Set-GenerationState -HookInput $child -State 'finalized'", "    $null = Set-GenerationState -HookInput $child -State 'ready' -Evidence 'child-proof'\n    $null = Publish-GenerationSummary -HookInput $child -Ready $true")
s = s.replace("'ancient-done' -State 'unverified'", "'ancient-done' -State 'finalized'")
s = s.replace("param([string]$Event, [string]$Session, [string]$Prompt = 'next prompt')", "param([string]$Event, [string]$Session, [string]$Prompt = 'next prompt', [string]$Answer = '')")
s = s.replace('$payload = [ordered]@{ session_id = $Session; cwd = $Work; hook_event_name = $Event; prompt = $Prompt }', '$payload = [ordered]@{ session_id = $Session; cwd = $Work; hook_event_name = $Event; prompt = $Prompt; last_assistant_message = $Answer }')
s = s.replace("    Check 'T032 the hook wrote a publication record at Stop'", "    Check 'T032 an empty Stop does not invent a publication' ($null -eq $wireRecord -or $null -eq $wireRecord.publication)\n    $summaryRun = Invoke-SummaryHook -Event 'Stop' -Session $wireSession -Answer \"DONE: verified work`nREMAINING: none\"\n    Check 'T032 a real summary observation remains silent' ($summaryRun.ExitCode -eq 0 -and $summaryRun.Text -eq '')\n    $wireRecord = Get-GenerationRecord -HookInput $wireInput\n    Check 'T032 the hook wrote a publication record only for observed summary text'")
write(name, s)
name = 'hooks/Session-Summary-Check/.env.example'
write(name, read(name) + '''
# Recommended registration: SessionStart, UserPromptSubmit, Stop, SubagentStop.
# Only the first two emit instructions. Closing events inspect current assistant
# text silently; absence of a real summary creates no publication. This observer
# does not certify all required gates or control the client's display.
''')
name = 'CONTEXT.md'; s = read(name)
s = s.replace('''The state a generation reaches when its summary has been published for it. It is one of the two ways
to become **terminal**; the other is ending unverified. Finalized says only that the summary was
published, never that it was published against settled evidence — a summary published while a gate
was still open is finalized too, and carries the record of that failure with it.''', '''The state recorded when a summary publication has an explicit ready record and no recorded
unresolved verdict. Observing summary text alone does not establish this state. An unverified
publication is a different fact from verified finalization, and neither is a claim that the store
controls what the client displays.''')
s = s.replace('Removing terminal generations from the store so new work can be recorded.', 'Compacting eligible verified terminal generations into retained tombstones so new work can be recorded.')
write(name, s)
for name, description in {
    'docs/HOOKS.md': "| `Session-Summary-Check` | pre-task instructions (SessionStart, UserPromptSubmit); silent observation (Stop, SubagentStop) | Requests one final DONE / REMAINING section after the other closing declarations. A Stop is not publication proof: only substantive current assistant summary text outside quotes/code/templates is recorded, using the shared child-aware evidence reader. Unknown evidence does not borrow a parent or older answer. Closing observation emits nothing and cannot certify that all gates ran. Readiness requires explicit evidence; historical gate markers remain history, not current blockers. Default installs register the silent events, and exact old defaults have versioned migration without overriding custom bindings. Only verified finalized records without negative verdicts compact into retained tombstones; active, unverified, unresolved and unreported-warning records survive. Terminal records cannot reopen, late verdicts cannot resurrect retired identities, and capacity cannot evict replay protection. These are store guarantees, not final-display control. The original last-visible-summary requirement needs an output-owning integration with affirmative gate completion. See the generation observation audit document. |",
    'docs/HOOKS-FA.md': '| `Session-Summary-Check` | دستور پیش از کار؛ مشاهدهٔ بی‌صدا در Stop و SubagentStop | یک جمع‌بندی نهایی DONE / REMAINING پس از سایر تأییدهای پایانی می‌خواهد. صرف وقوع Stop یا پاسخ معمولی، خالی، مثال نقل‌شده، بلوک کد، قالب پرنشده یا متن والد به‌جای زیرایجنت، انتشار محسوب نمی‌شود. فقط متن معتبر و جاری جمع‌بندی ثبت می‌شود، بدون خروجی در Stop. نبود اعتراض اثبات اجرای همهٔ بررسی‌ها نیست و سابقهٔ مانع نباید مانع جاری محسوب شود. نصب پیش‌فرض رویدادهای مشاهده را نیز ثبت می‌کند؛ مهاجرت فقط برای پیش‌فرض قدیمیِ اثبات‌شده است، نه تنظیمات سفارشی. پاک‌سازی فقط رکورد نهایی تأییدشده و بدون مانع را به نشان بازنشستگی تبدیل می‌کند. رکورد فعال، حل‌نشده، نامشخص یا هشدار گزارش‌نشده حفظ می‌شود؛ رکورد نهایی دوباره فعال نمی‌شود و نشان بازنشستگی برای ایجاد ظرفیت دور ریخته نمی‌شود. این تضمین‌ها دربارهٔ ثبت مشاهدات هستند، نه کنترل آخرین خروجی قابل‌نمایش؛ شرط سخت‌گیرانه نیازمند کنترل مسیر خروجی کلاینت و تأیید مثبت همهٔ بررسی‌های لازم است. |'
}.items():
    s = read(name); lines = s.splitlines()
    found = [i for i, line in enumerate(lines) if line.startswith('| `Session-Summary-Check` |')]
    assert len(found) == 1, name
    lines[found[0]] = description
    write(name, '\n'.join(lines) + '\n')
