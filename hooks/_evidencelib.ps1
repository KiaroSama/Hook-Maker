# Closing-declaration evidence, shared by every hook that gates on one.
#
# A separate file rather than more of _stoplib.ps1: that file is past the size
# ceiling, and this is its own responsibility anyway - _stoplib owns the
# continuation LEDGER, this owns what a closing line has to look like before it
# counts as a claim. It is dot-sourced by _hooklib.ps1 as a sibling, exactly
# like _stoplib.ps1, and staged the same way by the install plan.
#
# THE DEFECT IT FIXES (L05): the three closing gates tested for a PREFIX and
# nothing else. `MCP used:` with nothing after it satisfied the gate. So did
# `Skills used: none` with no reason, and so did a line inside a fenced example
# the agent had written to SHOW the format rather than to make a claim. A prefix
# is a shape; a claim needs content, and these are not the same thing.

# Placeholders that are the shape of an answer without being one. Deliberately
# short and literal - this is not a natural-language check, it is a list of the
# tokens people actually leave behind.
$script:ClosingPlaceholders = @('tbd', 'todo', 'n/a', 'na', 'none yet', 'tbc', '...', '-', '--')

# A second label inside a complete quote or inline code span is prose.
function Test-AdditionalSummaryLabel {
    param([string]$Text, [string]$LabelPattern = 'DONE|REMAINING')
    $unquoted = $Text -replace '`[^`]*`|"[^"]*"|''[^'']*''|\u00ab[^\u00bb]*\u00bb', ' '
    return ($unquoted -match ('(?<!\w)(?:' + $LabelPattern + ')(?:\*{1,2}|_{1,2})?[ \t]*:'))
}

# The content of one closing declaration, or $null when the label is absent.
#
# Legacy declaration readers accept escaped newlines. Summary evidence comes
# from decoded assistant text; a literal escape is not a physical line break.
function Get-ClosingDeclarationLine {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$LabelPattern, [switch]$SummaryLabel)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $pattern = '^ {0,3}(?:[-*#]+[ \t]{0,4})?(?:\*\*)?' + $LabelPattern + '[ \t]*:(.*)$'
    if ($SummaryLabel) {
        $pattern = '^ {0,3}(?:[-+*#]+[ \t]+)?(?:\*{1,2}|_{1,2})?' + $LabelPattern + '(?:\*{1,2}|_{1,2})?[ \t]*(?::(.*)|$)$'
    }
    $fenceChar = ''; $fenceLength = 0
    $lineBreak = if ($SummaryLabel) { '\r?\n' } else { '(?:\r?\n|\\n)' }
    foreach ($raw in @($Text -split $lineBreak)) {
        $line = if ($SummaryLabel) { $raw -replace '^[\u200f\u2067]+|\u2069[ \t]*$', '' } else { $raw }
        # Quoted examples and indented code are not the assistant's declaration.
        if ($line -match '^[ \t]*>' -or ($SummaryLabel -and $line -match '^(?: {4}|\t)')) { continue }
        if ($line -match '^ {0,3}(`{3,}|~{3,})(.*)$') {
            $marker = $matches[1]; $rest = $matches[2]
            if ($fenceChar -eq '') { $fenceChar = $marker.Substring(0, 1); $fenceLength = $marker.Length }
            elseif ($marker.Substring(0, 1) -ceq $fenceChar -and $marker.Length -ge $fenceLength -and $rest.Trim() -eq '') { $fenceChar = ''; $fenceLength = 0 }
            continue
        }
        if ($fenceChar -ne '') { continue }
        if ($line -match $pattern) {
            $value = [string]$matches[1]
            if ($SummaryLabel -and (Test-AdditionalSummaryLabel -Text $value)) { continue }
            return $value
        }
    }
    return $null
}

# Is a declaration SUBSTANTIVE - does it actually claim something?
#
# Returns @{ Present; Value; Substantive; Reason }. Present says the label was
# found at all; Substantive says it carried a claim. A caller that only checks
# Present is back to the prefix test this exists to replace.
function Test-ClosingDeclaration {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$LabelPattern,
        # 'none' is a legitimate answer for these gates, but only WITH a reason -
        # "none" alone is indistinguishable from not having looked.
        [bool]$AllowNoneWithReason = $true
    )
    $value = Get-ClosingDeclarationLine -Text $Text -LabelPattern $LabelPattern
    if ($null -eq $value) {
        return [pscustomobject]@{ Present = $false; Value = ''; Substantive = $false; Reason = 'absent' }
    }
    $trimmed = ([string]$value).Trim().Trim('*').Trim()
    if ($trimmed -eq '') {
        return [pscustomobject]@{ Present = $true; Value = ''; Substantive = $false; Reason = 'empty' }
    }
    if ($script:ClosingPlaceholders -contains $trimmed.ToLowerInvariant()) {
        return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $false; Reason = 'placeholder' }
    }
    # A bracketed template ("<skill names>") is what the instruction itself shows.
    if ($trimmed -match '^<[^>]*>$') {
        return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $false; Reason = 'placeholder' }
    }
    if ($trimmed -match '^(?i)none\b') {
        $rest = $trimmed.Substring(4).Trim()
        # Any separator the instructions suggest, then a real reason.
        $rest = $rest.TrimStart([char[]]@('-', [char]0x2013, [char]0x2014, ':', ',', '.', ' '))
        if (-not $AllowNoneWithReason -or $rest.Length -lt 3 -or $script:ClosingPlaceholders -contains $rest.ToLowerInvariant()) {
            return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $false; Reason = 'none-without-reason' }
        }
    }
    return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $true; Reason = 'ok' }
}

# THE CLOSING EVIDENCE OF A TASK, not of one message (DD-13 live trace,
# 2026-09-30). The closing-line gates read only the newest answer, so once a
# task had published its wrap-up - declarations included - any later correction
# turn (a docs acknowledgement, say) was blocked again for lines the task had
# already given, and the agent was pushed to repeat them for unchanged work.
# A published wrap-up is kept per task; a later answer in the SAME task (the
# ledger's own published flag) is judged together with it. A new task never
# sees it: the flag is scoped to the task's event identity.
function Get-PublishedSummaryPath {
    param([Parameter(Mandatory = $true)]$HookInput)
    $ledger = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName 'summary-state'
    return (Join-Path (Split-Path -Parent $ledger) ('published-summary-' + (Get-ShortHash ([string]$keys.ChainKey)) + '.txt'))
}

function Get-TaskClosingEvidence {
    param([Parameter(Mandatory = $true)]$HookInput)
    $evidence = Get-ClosingAssistantText -HookInput $HookInput
    if (-not $evidence.Known) { return $evidence }
    try {
        $path = Get-PublishedSummaryPath -HookInput $HookInput
        if (Test-ClosingSummaryPublished -Text ([string]$evidence.Text)) {
            $text = [string]$evidence.Text
            if ($text.Length -gt 16384) { $text = $text.Substring($text.Length - 16384) }    # declarations close the answer
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
        }
        elseif ((Test-TaskSummaryAlreadyPublished -HookInput $HookInput) -and [IO.File]::Exists($path)) {
            $published = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            return [pscustomobject]@{ Text = ([string]$evidence.Text + "`n" + $published); Source = ($evidence.Source + '+published'); Known = $true }
        }
    }
    catch { }
    return $evidence
}

# THE SESSION'S TOOL EVIDENCE, in order (spec 036). Read-ClaudeTranscript keeps
# only Skill calls, but the Spec Kit gate must count WRITTEN files and the rules
# gate must see which files were READ. One ordered list of
# @{ Kind = prompt|skill|read|write|synapse; Value } instead of a second private parser.
#
# CHEAP ON PURPOSE: only lines that can carry evidence are parsed. A tool result
# (the bulk of a transcript) carries "tool_use_id" and is skipped unparsed; so
# is client-injected text (isMeta skill bodies, the compaction summary), which
# routinely quotes request-shaped words the user never typed.
#
# Same honesty as Read-ClaudeTranscript: over $MaxBytes is Partial with nothing
# read, unreadable is Ok = $false. Neither may become a block or an all-clear.
function Get-TranscriptToolEvidence {
    param([AllowEmptyString()][string]$Path, [int]$MaxBytes = 20000000)
    $none = [pscustomobject]@{ Ok = $false; Partial = $false; Events = @() }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $none }
    try { if ((New-Object IO.FileInfo($Path)).Length -gt $MaxBytes) { return [pscustomobject]@{ Ok = $true; Partial = $true; Events = @() } } } catch { return $none }
    $events = New-Object System.Collections.Generic.List[object]
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding $false))
            while ($null -ne ($line = $reader.ReadLine())) {
                # A compaction boundary (spec 038): skills loaded before it are
                # gone from the model's context, so the voice gate counts after it.
                if ($line.Contains('"isCompactSummary":true')) { [void]$events.Add([pscustomobject]@{ Kind = 'compact'; Value = 'compact' }); continue }
                $isTool = $line.Contains('"tool_use"')
                $isPrompt = (-not $isTool) -and $line.Contains('"type":"user"') -and -not $line.Contains('"tool_use_id"') -and
                    -not $line.Contains('"isMeta":true') -and -not $line.Contains('"isCompactSummary":true')
                if (-not $isTool -and -not $isPrompt) { continue }
                $doc = $null
                try { $doc = $line | ConvertFrom-Json } catch { continue }
                $message = Get-Field $doc 'message'
                if ($null -eq $message) { continue }
                $content = Get-Field $message 'content'
                if ($isPrompt) {
                    $text = ''
                    if ($content -is [string]) { $text = $content }
                    else { foreach ($part in @($content)) { if ([string](Get-Field $part 'type') -eq 'text') { $text += "`n" + [string](Get-Field $part 'text') } } }
                    $text = [regex]::Replace($text, '(?is)<system-reminder>.*?</system-reminder>|<command-[a-z-]+>.*?</command-[a-z-]+>', ' ').Trim()
                    if ($text -ne '') { [void]$events.Add([pscustomobject]@{ Kind = 'prompt'; Value = $text }) }
                    continue
                }
                foreach ($part in @($content)) {
                    if ([string](Get-Field $part 'type') -ne 'tool_use') { continue }
                    $name = [string](Get-Field $part 'name'); $toolInput = Get-Field $part 'input'
                    if ($name -eq 'Skill') { $kind = 'skill'; $value = [string](Get-Field $toolInput 'skill') }
                    elseif ($name -eq 'Read') { $kind = 'read'; $value = [string](Get-Field $toolInput 'file_path') }
                    elseif ($name -in @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')) {
                        $kind = 'write'; $value = [string](Get-Field $toolInput 'file_path')
                        if ($value -eq '') { $value = [string](Get-Field $toolInput 'notebook_path') }
                    }
                    # Synapse memory calls (spec 037): Value is digest|retrieve|write.
                    elseif ($name -match '(?i)^mcp__[A-Za-z0-9_.\-]*synapse[A-Za-z0-9_.\-]*__memory_(digest|retrieve|write)$') { $kind = 'synapse'; $value = $Matches[1].ToLowerInvariant() }
                    # Spec 038: shell commands (graphify update) and Codebase Memory calls (index_repository).
                    elseif ($name -in @('Bash', 'PowerShell')) { $kind = 'shell'; $value = [string](Get-Field $toolInput 'command') }
                    elseif ($name -match '(?i)^mcp__[A-Za-z0-9_.\-]*codebase[-_]?memory[A-Za-z0-9_.\-]*__([A-Za-z0-9_]+)$') { $kind = 'cbm'; $value = $Matches[1].ToLowerInvariant() }
                    else { continue }
                    # Added: the text a write put in (new_string/content), capped; '' otherwise.
                    $added = ''
                    if ($kind -eq 'write') {
                        $added = [string](Get-Field $toolInput 'new_string'); if ($added -eq '') { $added = [string](Get-Field $toolInput 'content') }
                        if ($added.Length -gt 16000) { $added = $added.Substring(0, 16000) }
                    }
                    if ($value -ne '') { [void]$events.Add([pscustomobject]@{ Kind = $kind; Value = $value; Added = $added }) }
                }
            }
        }
        finally { $stream.Dispose() }
    }
    catch { return $none }
    return [pscustomobject]@{ Ok = $true; Partial = $false; Events = @($events.ToArray()) }
}

# STRUCTURAL INDEX REFRESH DUTY (spec 038): the graph and CBM gates refuse what
# Speckit-Check refuses - a change request that edited 3+ project files - when
# no refresh ran AFTER the last of those edits. A refresh before the last edit
# leaves the index describing an older tree, so it does not count. Returns $null
# (no duty, satisfied, or reasoned `<Label>: not refreshed - <reason>` closing
# line) or @{ EditCount; FirstPrompt; Fingerprint }. Callers need _scope.ps1.
function Get-StructuralRefreshFinding {
    param(
        [Parameter(Mandatory = $true)]$HookInput, [object[]]$Events,
        [Parameter(Mandatory = $true)][string]$RefreshKind, [Parameter(Mandatory = $true)][string]$RefreshPattern,
        [Parameter(Mandatory = $true)][string]$ExemptLabel, [string]$OwnMessagePattern = '^$'
    )
    $cwd = [string](Get-Field $HookInput 'cwd')
    if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Get-Command Test-ProjectChangingPrompt -ErrorAction SilentlyContinue)) { return $null }
    $root = [IO.Path]::GetFullPath($cwd).TrimEnd('\', '/') + '\'
    $prompts = New-Object System.Collections.Generic.List[string]
    $edited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $index = 0; $lastEdit = -1; $lastRefresh = -1
    foreach ($item in @($Events)) {
        $index++
        if ($item.Kind -eq 'prompt') {
            # The gate's own refusal comes back as a prompt; it is not a request.
            if ($item.Value -notmatch $OwnMessagePattern -and (Test-ProjectChangingPrompt -Prompt $item.Value)) { [void]$prompts.Add($item.Value) }
        }
        elseif ($item.Kind -eq $RefreshKind -and $item.Value -match $RefreshPattern) { $lastRefresh = $index }
        elseif ($item.Kind -eq 'write') {
            $full = ''
            try { $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($item.Value)) { $item.Value } else { Join-Path $cwd $item.Value })) } catch { continue }
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($full.Substring($root.Length) -match '^(?i)(\.ai|\.claude|plans|specs|\.specify)[\\/]') { continue }
            [void]$edited.Add($full); $lastEdit = $index
        }
    }
    if ($prompts.Count -eq 0 -or $edited.Count -lt 3 -or $lastRefresh -gt $lastEdit) { return $null }
    $closing = Get-TaskClosingEvidence -HookInput $HookInput
    if ($null -ne $closing -and $closing.Known) {
        $declaration = Test-ClosingDeclaration -Text ([string]$closing.Text) -LabelPattern $ExemptLabel
        if ($declaration.Present -and ([string]$declaration.Value).Trim() -match '^(?i)not[ \t]+refreshed[ \t]*[-:][ \t]*(?<reason>.*\S.*)$' -and $Matches['reason'].Trim().Length -ge 6) { return $null }
    }
    $first = ([string]$prompts[0]) -replace '\s+', ' '
    if ($first.Length -gt 120) { $first = $first.Substring(0, 120) + '...' }
    $joined = (@($prompts | ForEach-Object { Get-ShortHash $_ } | Sort-Object) -join ',')
    return [pscustomobject]@{ EditCount = $edited.Count; FirstPrompt = $first; Fingerprint = (Get-ShortHash ([string](Get-Field $HookInput 'session_id') + '|' + $joined)) }
}

# Once per fingerprint: $true the first time (and records it), $false on repeat.
function Test-NewGateFingerprint {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Cwd, [Parameter(Mandatory = $true)][string]$Fingerprint)
    $dir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    $path = Join-Path $dir ($Name + '-gate-' + (Get-ShortHash $Cwd.ToLowerInvariant()) + '.txt')
    try { if ([IO.File]::Exists($path) -and ([IO.File]::ReadAllText($path).Trim()) -eq $Fingerprint) { return $false } } catch { }
    try { [void][IO.Directory]::CreateDirectory($dir); [IO.File]::WriteAllText($path, $Fingerprint) } catch { }
    return $true
}

# Explicit repository-state provenance for test observation and completion.
$repoStatePath = Join-Path $PSScriptRoot '_repostate.ps1'
if (Test-Path -LiteralPath $repoStatePath -PathType Leaf) { . $repoStatePath }

# Informational delivery is a separate transaction from Stop admission.
. (Join-Path $PSScriptRoot '_deliverylib.ps1')

# Gate receipts (spec 007 RD-4) load from here, optionally, because _hooklib.ps1
# is past the size ceiling. A runtime copied before the file existed has no
# Start-StopGateReceipt, and every gate checks for the command before using it.
$gateReceiptsPath = Join-Path $PSScriptRoot '_gatereceipts.ps1'
if (Test-Path -LiteralPath $gateReceiptsPath -PathType Leaf) { . $gateReceiptsPath }
# The reply-language state (steering V45), optional in the same way: a runtime
# copied before it existed simply adds no LANGUAGE line.
$replyLanguagePath = Join-Path $PSScriptRoot '_replylanguage.ps1'
if (Test-Path -LiteralPath $replyLanguagePath -PathType Leaf) { . $replyLanguagePath }
