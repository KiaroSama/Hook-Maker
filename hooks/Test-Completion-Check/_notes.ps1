# Test-Completion-Check private sibling: the durable-note files and the incident
# tag helpers. Moved out of the entry script, which is over the size ceiling, as
# ONE responsibility. REQUIRED: dot-sourced unconditionally.

# The four durable-memory files a hang/timeout finding may legitimately be
# recorded in (AI Context Memory Policy). Any of them growing satisfies the
# requirement - the hook never dictates which one.
$script:NoteFiles = @('.ai\BUGS.md', '.ai\TESTING_NOTES.md', '.ai\COMMANDS.md', '.ai\LESSON.md')
# Net bytes a durable note must add before it counts. A bare acknowledgement
# ("done", "n/a", "fixed") cannot clear this; a real note trivially does.
$script:MinNoteBytes = 80
# Each incident's note must carry THIS exact tag line so one note can no longer
# resolve two distinct incidents by byte growth alone (a single 80-byte note used
# to clear every incident that shared its baseline). The block message tells the
# agent the exact string to write; resolution requires the marker AND the byte
# floor, so a bare tag with no substance still does not count.
$script:IncidentTagPrefix = 'Test incident: '
function Get-IncidentTag { param([string]$Key) return ($script:IncidentTagPrefix + $Key) }

# The stable incident identity of an ABANDONED active marker (a run whose owner
# died without recording a result). Derived only from fields the marker file
# already carries and never rewrites, so the same leftover hashes to the same key
# on every later Stop - which is what lets one tagged note resolve it for good
# instead of the finding re-appearing under a new identity each time. Namespaced
# by the 'abandoned|' prefix so it can never collide with a result incident key.
function Get-AbandonedIncidentKey {
    param($Doc)
    $rid = [string](Get-Field $Doc 'runId')
    $opid = [string](Get-Field $Doc 'ownerPid')
    $created = [string](Get-Field $Doc 'markerCreatedUtc')
    return (Get-ShortHash ('abandoned|' + $rid + '|' + $opid + '|' + $created))
}

function Get-NoteBytes {
    param([string]$Root)
    $total = 0L
    foreach ($relative in $script:NoteFiles) {
        $path = Join-Path $Root $relative
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) { $total += (Get-Item -LiteralPath $path -Force).Length }
        }
        catch { }
    }
    return $total
}

# Concatenated text of the four durable-note files (empty when none exist). Read
# so an incident's own tag can be searched for; a read failure yields '' rather
# than throwing, so a locked/absent file never crashes the gate.
function Get-NoteText {
    param([string]$Root)
    $sb = New-Object System.Text.StringBuilder
    foreach ($relative in $script:NoteFiles) {
        $path = Join-Path $Root $relative
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) { [void]$sb.AppendLine([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)) }
        }
        catch { }
    }
    return $sb.ToString()
}

# Is this incident's own tag ("Test incident: <key>") present in the .ai/ notes?
# Whitespace after the colon is tolerated; the key is regex-escaped so it matches
# literally. This is the per-incident marker that makes two notes genuinely
# required for two incidents.
function Test-NoteTagPresent {
    param([string]$Root, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    $text = Get-NoteText -Root $Root
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -match ('(?m)^[ \t]*Test incident:[ \t]*' + [regex]::Escape($Key) + '[ \t]*\r?$'))
}
