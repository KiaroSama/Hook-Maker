# The Stop/SubagentStop decision for Skills-Check.
#
# A sibling, not inline: the hook file had reached the size ceiling, and this is
# a separate responsibility anyway - the hook gathers evidence and emits, this
# file decides what the evidence means.
#
# WHAT CHANGED WHEN THIS MOVED: the gate fired on exactly one condition - a
# `Skill` tool call with no `Skills used:` line. Two real gaps followed from
# that. A session that edited files all the way through without invoking any
# skill was only advised, so the cheapest way past the policy was to use no
# skill at all. And a skill this hook had already shortlisted for the prompt
# could be offered, ignored, and never mentioned, which is the exact failure the
# shortlist exists to prevent. Both are gated here now.
#
# WHAT IS DELIBERATELY NOT GATED: library matches. Importing one is an
# authorized operation the user must approve, so blocking on an un-imported
# suggestion would force an authorization that was never given. Only skills that
# were ALREADY INSTALLED - loadable without asking anyone - are accountable.

$script:SkillShortlistVersion = '1'

# The installed names offered for this session, accumulated across prompts. A
# separate file per session: the answer is "did THIS session use what it was
# shown", and a previous session's shortlist is not evidence about this one.
function Get-SkillShortlistPath {
    param([string]$StateDir, [string]$ProjectKey, [string]$SessionId)
    return (Join-Path $StateDir ('SkillsCheck-shortlist-' + $ProjectKey + '-' + (Get-ShortHash ([string]$SessionId)) + '.txt'))
}

function Save-SkillShortlist {
    param([string]$Path, [string[]]$Names)
    if ($null -eq $Names -or $Names.Count -eq 0) { return }
    # Union with what is already there: a later prompt narrows the shortlist, it
    # does not retract what an earlier one put in front of the agent.
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($existing in @(Get-SkillShortlist $Path)) { [void]$seen.Add($existing) }
    foreach ($n in $Names) {
        $clean = ([string]$n).Trim()
        if ($clean -eq '' -or $clean.Contains('|')) { continue }
        if (@($seen | Where-Object { $_ -eq $clean }).Count -gt 0) { continue }
        [void]$seen.Add($clean)
        if ($seen.Count -ge 24) { break }
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        $lines = @('HookMakerSkillsShortlist|' + $script:SkillShortlistVersion) + $seen.ToArray()
        [System.IO.File]::WriteAllLines($Path, [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))
    }
    catch { }
}

function Get-SkillShortlist {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
        if ($lines.Count -lt 1) { return @() }
        $head = $lines[0].Split('|')
        if ($head[0] -ne 'HookMakerSkillsShortlist' -or $head[1] -ne $script:SkillShortlistVersion) { return @() }
        return @($lines[1..($lines.Count - 1)] | Where-Object { $_ -ne '' })
    }
    catch { return @() }
}

# The client's own record of a file-mutating tool call. Prose that merely NAMES
# a tool is not a call, so the match is anchored to the tool_use record's own
# "name" field. Bash is excluded on purpose: it mutates only sometimes, and this
# gate must fire on evidence rather than on what a command might have done.
#
# Bounded by the transcript tail the caller passes, so a very long session can
# push its early edits out of view. That direction is the safe one - it advises
# where it would have blocked, never the reverse.
function Test-SubstantiveWork {
    param([string]$RawTranscript)
    if ([string]::IsNullOrWhiteSpace($RawTranscript)) { return $false }
    return ($RawTranscript -match '"name"[ \t]*:[ \t]*"(Write|Edit|MultiEdit|NotebookEdit)"')
}

# The content of the "Skills used:" line itself, or $null when there is none.
# Not the whole response: a skill named in passing somewhere in the prose is not
# a claim that it was used, and treating it as one would clear the gate by
# accident.
#
# A LINE BREAK HERE IS TWO CHARACTERS, not one. The evidence comes out of a
# JSONL transcript where a newline inside a message is the escape \n, so a
# pattern anchored on ^ alone matches only the first line of the response and
# silently sees no summary at all. Both forms start a line, and both end one -
# a capture that ran past the escape would swallow the rest of the response and
# count a skill named anywhere in it.
function Get-SkillsUsedLine {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '(?im)(?:^|\\n)[ \t]{0,8}(?:[-*>#]+[ \t]{0,4})?(?:\*\*)?Skills?[ \t]+used[ \t]*:((?:(?!\\n)[^\r\n])*)')
    if (-not $m.Success) { return $null }
    return [string]$m.Groups[1].Value
}

# A shortlisted skill is accounted for when the client recorded a Skill call for
# it, or when the closing line names it. Anything else is a skill that was put
# in front of the agent and silently dropped.
function Get-UnusedShortlistedSkills {
    param([string[]]$Shortlist, [string]$RawTranscript, [string]$UsedLine)
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Shortlist)) {
        $n = ([string]$name).Trim()
        if ($n -eq '') { continue }
        # Plugin skills are addressed <plugin>:<skill>; either spelling counts,
        # because both name the same skill and the agent may write either.
        $leaf = $n
        $colon = $n.LastIndexOf(':')
        if ($colon -ge 0 -and $colon -lt ($n.Length - 1)) { $leaf = $n.Substring($colon + 1) }
        $full = [regex]::Escape($n)
        $short = [regex]::Escape($leaf)
        # The tool INPUT field, not just any occurrence of the name: this hook's
        # own shortlist message lands in the same transcript and names every
        # candidate, so a bare substring search would clear the gate itself.
        if ($RawTranscript -match ('"skill"[ \t]*:[ \t]*"(?:[^"]*\b)?(?:' + $full + '|' + $short + ')"')) { continue }
        if (-not [string]::IsNullOrWhiteSpace($UsedLine)) {
            if ($UsedLine -match ('(?i)(?:' + $full + '|' + $short + ')')) { continue }
        }
        [void]$missing.Add($n)
        if ($missing.Count -ge 6) { break }
    }
    return @($missing)
}

# The whole closing decision. Returns Kind (silent | advisory | block), the
# fingerprint Token that decides whether an unchanged finding repeats, and the
# message text. The caller owns enforcement downgrades and emission.
function Get-SkillClosingDecision {
    param(
        [string]$ClosingText,
        [string]$RawTranscript,
        [string[]]$Shortlist,
        [bool]$SkillInvoked
    )
    $usedLine = Get-SkillsUsedLine $ClosingText
    $unused = @()
    if (@($Shortlist).Count -gt 0) {
        $unused = Get-UnusedShortlistedSkills -Shortlist $Shortlist -RawTranscript $RawTranscript -UsedLine ([string]$usedLine)
    }
    $named = (@($unused) -join ', ')

    if ($null -ne $usedLine) {
        if (@($unused).Count -eq 0) { return [pscustomobject]@{ Kind = 'silent'; Token = 'accounted'; Text = '' } }
        return [pscustomobject]@{
            Kind  = 'block'
            Token = ('shortlisted-unused|' + $named)
            Text  = (@(
                    ('SKILL POLICY CHECK - this session was shown INSTALLED skills matching the prompt and used none of them: ' + $named + '.'),
                    'They need no authorization - they are already loadable, and the policy is that a step a skill covers runs THROUGH that skill rather than by hand.',
                    ('TO CLEAR THIS: either invoke the relevant one(s) by their exact name and then report them, or keep the "Skills used:" line and say in it why each was not applicable - e.g. "Skills used: none - ' + $named + ' does not cover a docs-only edit".')
                ) -join "`n")
        }
    }

    if ($SkillInvoked) {
        return [pscustomobject]@{
            Kind  = 'block'
            Token = 'missing-after-invoke'
            Text  = (@(
                    'SKILL POLICY CHECK - this session invoked at least one skill and the closing summary does not report which.',
                    # The example stays INLINE and quoted rather than on a line of
                    # its own: this message lands in the same transcript the next
                    # Stop reads, and an example at the start of a line would
                    # satisfy the detector - the hook would clear its own block.
                    'TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "Skills used:" and naming the exact skill name(s) invoked or materially followed - e.g. "Skills used: superpowers:systematic-debugging, powershell-windows".',
                    'Name only skills that actually shaped the work; a skill that was opened and then not followed does not count.'
                ) -join "`n")
        }
    }

    if (Test-SubstantiveWork $RawTranscript) {
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add('SKILL POLICY CHECK - this session changed files and the closing summary carries no "Skills used:" line.')
        if (@($unused).Count -gt 0) {
            [void]$lines.Add('INSTALLED skills matching this prompt were offered and none was used: ' + $named + '. They need no authorization.')
        }
        [void]$lines.Add('TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "Skills used:" and naming what was used - or exactly "Skills used: none - <one-line reason>" when nothing applied. Both are valid answers; omitting the line is not.')
        return [pscustomobject]@{ Kind = 'block'; Token = ('missing-after-work|' + $named); Text = (($lines.ToArray()) -join "`n") }
    }

    # Nothing was invoked and nothing was written: this session read and
    # answered. Whether a skill was NEEDED is not a judgement the hook can make
    # from that, so it advises and never blocks.
    return [pscustomobject]@{
        Kind  = 'advisory'
        Token = 'none-invoked'
        Text  = (@(
                'SKILL POLICY CHECK - no skill was invoked this session.',
                'If the task touched a specialised domain (debugging, testing, security review, UI/UX, a specific stack) an installed skill probably applied and was skipped - a relevant INSTALLED skill may be activated without asking.',
                ('Either way the summary must carry the line: ' + $script:SkillsRequiredLine)
            ) -join "`n")
    }
}
