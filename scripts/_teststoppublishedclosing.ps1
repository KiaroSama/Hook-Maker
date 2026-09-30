# Test-StopLedger.ps1 scenario block (spec 017 T013, DD-13 live trace): the
# closing declarations of a task's PUBLISHED wrap-up count for a later
# correction turn of the same task, so a gate that blocks after the wrap-up
# (a docs acknowledgement, say) does not make Rules-Check, Mcp-Usage-Check and
# Skills-Check demand the same lines again for unchanged work. Another task
# never inherits them. Dot-sourced into Test-StopLedger.ps1 (uses its Check,
# New-StopInput and workspace with LOCALAPPDATA redirected).

$pubTranscript = Join-Path $Work 'published.jsonl'
function Write-PubAssistant {
    param([string]$Text, [switch]$Append)
    $line = (@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $Text }) } } | ConvertTo-Json -Depth 6 -Compress) + "`n"
    if ($Append) { [IO.File]::AppendAllText($pubTranscript, $line) } else { [IO.File]::WriteAllText($pubTranscript, $line) }
}
function New-PubInput {
    param([string]$Session, [bool]$Continuation)
    $o = New-StopInput -Session $Session -Continuation $Continuation -Cwd 'C:\proj\published'
    Add-Member -InputObject $o -NotePropertyName 'transcript_path' -NotePropertyValue $pubTranscript
    return $o
}
$labels = @('MCP[ \t]+used', 'Skills[ \t]+used', 'Rules[ \t]+applied')
function Test-AllDeclared {
    param([string]$Text)
    foreach ($label in $labels) { if (-not (Test-ClosingDeclaration -Text $Text -LabelPattern $label).Substantive) { return $false } }
    return $true
}

$wrap = "All green.`nMCP used: synapse`nSkills used: ponytail:ponytail-audit`nRules applied: global-test-rules.md`n`nDONE`n- shipped`nREMAINING`n- nothing"
$correction = 'Docs review acknowledged; the published summary still stands.'

# Before any wrap-up: a plain answer is judged on its own.
Write-PubAssistant $correction
$before = Get-TaskClosingEvidence -HookInput (New-PubInput -Session 'PUB' -Continuation $false)
Check 'published closing: before a wrap-up an answer without declarations stays without them' ($before.Known -and -not (Test-AllDeclared $before.Text)) ([string]$before.Text)

# The wrap-up turn: the answer itself is the evidence, and it is kept for the task.
Write-PubAssistant $wrap
$atWrap = Get-TaskClosingEvidence -HookInput (New-PubInput -Session 'PUB' -Continuation $false)
Check 'published closing: the wrap-up answer is its own evidence' ($atWrap.Known -and $atWrap.Text -ceq $wrap) ([string]$atWrap.Source)
# What a gate blocking after the wrap-up records (Get-StopFinalizationClause).
Set-TaskSummaryPublished -HookInput (New-PubInput -Session 'PUB' -Continuation $false)

# The correction turn of the SAME task: the published declarations count.
Write-PubAssistant $correction -Append
$after = Get-TaskClosingEvidence -HookInput (New-PubInput -Session 'PUB' -Continuation $true)
Check 'published closing: a correction turn of the same task carries the published declarations' (Test-AllDeclared $after.Text) ([string]$after.Source)
Check 'published closing: the correction answer itself is still in the evidence' ($after.Known -and ([string]$after.Text).StartsWith($correction)) ([string]$after.Text)

# Another task (another session) never inherits them.
$other = Get-TaskClosingEvidence -HookInput (New-PubInput -Session 'OTHER' -Continuation $false)
Check 'published closing: another task does not inherit a published wrap-up' ($other.Known -and -not (Test-AllDeclared $other.Text)) ([string]$other.Source)
