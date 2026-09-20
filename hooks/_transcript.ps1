# _hooklib section: the Claude Code transcript reader.
#
# Dot-sourced by _hooklib.ps1. Owns no $script: state. Kept whole because the
# JSONL shape it parses - one JSON object per line, where a real newline in a
# message arrives as a two-character escape - is the single fact every
# anchored detector in the shipped hooks depends on.

# ---- Claude Code transcript --------------------------------------------------
# Parses the JSONL a Stop hook is handed in `transcript_path` into an ordered
# list of @{ Role; Text; SkillCalls }.
#
# WHAT IT DELIBERATELY DROPS: <system-reminder> blocks and <command-...> local
# command echoes are stripped from user text. Both are injected BY the client,
# not typed by the user, and both routinely quote a hook's own reminder text -
# so a hook matching its own words in a reminder would find "evidence" it
# planted itself.
#
# BOUNDED, and honest about it: reading stops after $MaxBytes and the result
# reports Partial = $true. A caller must never turn a partial read into a
# block or an all-clear - it saw only part of the session.
function Read-ClaudeTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxBytes = 20000000
    )
    $result = [pscustomobject]@{ Entries = @(); Partial = $false; Ok = $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    # The cap is in BYTES and is applied to the file's length BEFORE anything is
    # read. A 47 MB live transcript used to be parsed line by line up to the cap
    # at every Stop - about ten seconds - only to be reported Partial and
    # discarded. Over the cap the answer is already known: Partial, nothing read.
    try {
        if ((New-Object System.IO.FileInfo($Path)).Length -gt $MaxBytes) {
            return [pscustomobject]@{ Entries = @(); Partial = $true; Ok = $true }
        }
    }
    catch { return $result }
    $entries = New-Object System.Collections.Generic.List[object]
    $consumed = 0
    $partial = $false
    try {
        # Shared read: a live client is still appending to this file.
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding $false))
            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { break }
                    $consumed += $line.Length + 1
                    if ($consumed -gt $MaxBytes) { $partial = $true; break }
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $doc = $null
                    try { $doc = $line | ConvertFrom-Json } catch { continue }
                    if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['message'] -or $null -eq $doc.message) { continue }
                    $role = ''
                    if ($null -ne $doc.message.PSObject.Properties['role']) { $role = [string]$doc.message.role }
                    if ($role -ne 'user' -and $role -ne 'assistant') { continue }
                    $content = $null
                    if ($null -ne $doc.message.PSObject.Properties['content']) { $content = $doc.message.content }
                    $text = ''
                    $skills = New-Object System.Collections.Generic.List[string]
                    if ($content -is [string]) {
                        $text = [string]$content
                    }
                    elseif ($null -ne $content) {
                        foreach ($part in @($content)) {
                            if ($null -eq $part -or $null -eq $part.PSObject.Properties['type']) { continue }
                            $partType = [string]$part.type
                            if ($partType -eq 'text' -and $null -ne $part.PSObject.Properties['text']) {
                                $text = $text + "`n" + [string]$part.text
                            }
                            elseif ($partType -eq 'tool_use' -and $null -ne $part.PSObject.Properties['name'] -and [string]$part.name -eq 'Skill') {
                                if ($null -ne $part.PSObject.Properties['input'] -and $null -ne $part.input -and
                                    $null -ne $part.input.PSObject.Properties['skill']) {
                                    $skillName = [string]$part.input.skill
                                    if (-not [string]::IsNullOrWhiteSpace($skillName)) { [void]$skills.Add($skillName) }
                                }
                            }
                        }
                    }
                    if ($role -eq 'user' -and $text -ne '') {
                        $text = [System.Text.RegularExpressions.Regex]::Replace($text, '(?is)<system-reminder>.*?</system-reminder>', ' ')
                        $text = [System.Text.RegularExpressions.Regex]::Replace($text, '(?is)<command-[a-z-]+>.*?</command-[a-z-]+>', ' ')
                    }
                    [void]$entries.Add([pscustomobject]@{ Role = $role; Text = $text.Trim(); SkillCalls = @($skills.ToArray()) })
                }
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch {
        # Unreadable transcript is NOT an all-clear: Ok stays false.
        return $result
    }
    return [pscustomobject]@{ Entries = @($entries.ToArray()); Partial = $partial; Ok = $true }
}

# Friendly, hyphen-separated hook name. The shipped hook folders are already
# hyphenated (Cross-Project-.ai-Knowledge-Sync, Mcp-Usage-Check, ...), so this
# is a no-op for them; it still tidies a user's PascalCase custom-hook name
# (MyContextHook -> My-Context-Hook) for the menu + the installed copy folder.
function Get-HookFriendlyName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($Name, '([A-Z]+)([A-Z][a-z])', '$1-$2')
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($hyphenated, '([a-z0-9])([A-Z])', '$1-$2')
    return $hyphenated
}
