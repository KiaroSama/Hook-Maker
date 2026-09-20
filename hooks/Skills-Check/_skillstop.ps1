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

# Version 2 adds the ACCOUNTED half. The bump is deliberate: a runtime that
# predates it reads version 2 as unrecognised and returns nothing, which
# makes it advise where it would have blocked - the safe direction while a
# fleet is mixed. Reading a version-1 file the same way loses one session's
# offered set, which costs nothing.
$script:SkillShortlistVersion = '2'

# Accounted names share the file with offered ones and are marked with a
# leading '|'. A name can never collide with the marker because a name
# containing '|' is rejected on the way in.
$script:SkillAccountedMarker = '|'

# The installed names offered for this session, accumulated across prompts. A
# separate file per session: the answer is "did THIS session use what it was
# shown", and a previous session's shortlist is not evidence about this one.
function Get-SkillShortlistPath {
    param([string]$StateDir, [string]$ProjectKey, [string]$SessionId)
    return (Join-Path $StateDir ('SkillsCheck-shortlist-' + $ProjectKey + '-' + (Get-ShortHash ([string]$SessionId)) + '.txt'))
}

# One writer for both halves, so a session's offered and accounted sets cannot
# drift apart or be saved one without the other.
function Save-SkillSessionRecord {
    param([string]$Path, [string[]]$Offered, [string[]]$Accounted)
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add('HookMakerSkillsShortlist|' + $script:SkillShortlistVersion)
        foreach ($o in @($Offered)) { [void]$lines.Add([string]$o) }
        foreach ($a in @($Accounted)) { [void]$lines.Add($script:SkillAccountedMarker + [string]$a) }
        [System.IO.File]::WriteAllLines($Path, [string[]]$lines.ToArray(), (New-Object System.Text.UTF8Encoding $false))
    }
    catch { }
}

function Add-SkillNames {
    param([string[]]$Existing, [string[]]$Additions, [int]$Cap = 24)
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Existing)) { [void]$seen.Add([string]$e) }
    foreach ($n in @($Additions)) {
        $clean = ([string]$n).Trim()
        if ($clean -eq '' -or $clean.Contains('|')) { continue }
        if (@($seen | Where-Object { $_ -eq $clean }).Count -gt 0) { continue }
        [void]$seen.Add($clean)
        if ($seen.Count -ge $Cap) { break }
    }
    return @($seen.ToArray())
}

function Save-SkillShortlist {
    param([string]$Path, [string[]]$Names)
    if ($null -eq $Names -or $Names.Count -eq 0) { return }
    # Union with what is already there: a later prompt narrows the shortlist, it
    # does not retract what an earlier one put in front of the agent. What makes
    # that safe is the ACCOUNTED half - the union may grow, but the DEMAND is
    # offered minus accounted, so answering shrinks it and the gate terminates.
    Save-SkillSessionRecord -Path $Path -Offered (Add-SkillNames -Existing (Get-SkillShortlist $Path) -Additions $Names) -Accounted (Get-SkillAccounted $Path)
}

# Remember the answer. Without this the gate re-derived its demand from scratch
# every turn, so naming six merely surfaced the next six: a live session banked
# 51 offered names and faced nine more forced turns no matter what it said.
function Save-SkillAccounted {
    param([string]$Path, [string[]]$Names)
    if ($null -eq $Names -or @($Names).Count -eq 0) { return }
    Save-SkillSessionRecord -Path $Path -Offered (Get-SkillShortlist $Path) -Accounted (Add-SkillNames -Existing (Get-SkillAccounted $Path) -Additions $Names -Cap 64)
}

function Get-SkillShortlist {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
        if ($lines.Count -lt 1) { return @() }
        $head = $lines[0].Split('|')
        if ($head[0] -ne 'HookMakerSkillsShortlist' -or $head[1] -ne $script:SkillShortlistVersion) { return @() }
        return @($lines[1..($lines.Count - 1)] | Where-Object { $_ -ne '' -and -not $_.StartsWith($script:SkillAccountedMarker) })
    }
    catch { return @() }
}

# The half of the record that says which offered names have already been
# answered for - by being invoked, or by being named in a closing line.
function Get-SkillAccounted {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
        if ($lines.Count -lt 1) { return @() }
        $head = $lines[0].Split('|')
        if ($head[0] -ne 'HookMakerSkillsShortlist' -or $head[1] -ne $script:SkillShortlistVersion) { return @() }
        return @($lines[1..($lines.Count - 1)] | Where-Object { $_.StartsWith($script:SkillAccountedMarker) } | ForEach-Object { $_.Substring(1) } | Where-Object { $_ -ne '' })
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
    param([string[]]$Shortlist, [string[]]$Accounted, [string]$RawTranscript, [string]$UsedLine)
    # Returns the OUTSTANDING set, the names answered for on THIS turn (which the
    # caller persists), and the total before the display limit. The total is what
    # makes the demand honest: a block that shows six of fifty-one and never says
    # so reads as endless even when it is not.
    $missing = New-Object System.Collections.Generic.List[string]
    $answered = New-Object System.Collections.Generic.List[string]
    $total = 0
    $alreadyAccounted = @($Accounted)
    foreach ($name in @($Shortlist)) {
        $n = ([string]$name).Trim()
        if ($n -eq '') { continue }
        # Answered in an earlier turn: the question was put and it was answered,
        # so it is not put again.
        if (@($alreadyAccounted | Where-Object { $_ -eq $n }).Count -gt 0) { continue }
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
        if ($RawTranscript -match ('"skill"[ \t]*:[ \t]*"(?:[^"]*\b)?(?:' + $full + '|' + $short + ')"')) { [void]$answered.Add($n); continue }
        if (-not [string]::IsNullOrWhiteSpace($UsedLine)) {
            if ($UsedLine -match ('(?i)(?:' + $full + '|' + $short + ')')) { [void]$answered.Add($n); continue }
        }
        $total++
        # The lead is capped for readability; the FULL outstanding list travels
        # with it, so one closing line can still cover everything at once.
        if ($missing.Count -lt 6) { [void]$missing.Add($n) }
    }
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Shortlist)) {
        $n = ([string]$name).Trim()
        if ($n -eq '') { continue }
        if (@($alreadyAccounted | Where-Object { $_ -eq $n }).Count -gt 0) { continue }
        if (@($answered | Where-Object { $_ -eq $n }).Count -gt 0) { continue }
        [void]$all.Add($n)
    }
    return [pscustomobject]@{ Names = @($missing); All = @($all.ToArray()); Total = $total; Answered = @($answered.ToArray()) }
}

# The whole closing decision. Returns Kind (silent | advisory | block), the
# fingerprint Token that decides whether an unchanged finding repeats, and the
# message text. The caller owns enforcement downgrades and emission.
function Get-SkillClosingDecision {
    param(
        [string]$ClosingText,
        [string]$RawTranscript,
        [string[]]$Shortlist,
        [string[]]$Accounted,
        [bool]$SkillInvoked
    )
    $usedLine = Get-SkillsUsedLine $ClosingText
    $unused = @()
    $outstandingAll = @()
    $answeredNow = @()
    $outstandingTotal = 0
    if (@($Shortlist).Count -gt 0) {
        $o = Get-UnusedShortlistedSkills -Shortlist $Shortlist -Accounted $Accounted -RawTranscript $RawTranscript -UsedLine ([string]$usedLine)
        $unused = @($o.Names)
        $outstandingAll = @($o.All)
        $outstandingTotal = [int]$o.Total
        $answeredNow = @($o.Answered)
    }
    $named = (@($unused) -join ', ')
    $namedAll = (@($outstandingAll) -join ', ')
    # Say how big the obligation really is. Six shown out of fifty-one, with no
    # count, is what made a finite demand look infinite.
    $scale = ''
    if ($outstandingTotal -gt @($unused).Count) {
        $scale = ' (' + $outstandingTotal + ' outstanding in total, all of them here: ' + $namedAll + ')'
    }

    if ($null -ne $usedLine) {
        if (@($unused).Count -eq 0) { return [pscustomobject]@{ Kind = 'silent'; Token = 'accounted'; Text = ''; Answered = $answeredNow } }
        return [pscustomobject]@{
            Kind  = 'block'
            Answered = $answeredNow
            Token = ('shortlisted-unused|' + $named)
            Text  = (@(
                    ('SKILL POLICY CHECK - this session was shown INSTALLED skills matching the prompt and used none of them: ' + $named + '.' + $scale),
                    'They need no authorization - they are already loadable, and the policy is that a step a skill covers runs THROUGH that skill rather than by hand.',
                    ('TO CLEAR THIS: either invoke the relevant one(s) by their exact name and then report them, or keep the "Skills used:" line and say in it why each was not applicable - e.g. "Skills used: none - ' + $named + ' does not cover a docs-only edit". Naming EVERY outstanding skill in that one line clears this in a single turn; each name is remembered, so nothing already answered is asked again.')
                ) -join "`n")
        }
    }

    if ($SkillInvoked) {
        return [pscustomobject]@{
            Kind  = 'block'
            Answered = $answeredNow
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
            [void]$lines.Add('INSTALLED skills matching this prompt were offered and none was used: ' + $named + '.' + $scale + ' They need no authorization.')
        }
        [void]$lines.Add('TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "Skills used:" and naming what was used - or exactly "Skills used: none - <one-line reason>" when nothing applied. Both are valid answers; omitting the line is not.')
        return [pscustomobject]@{ Kind = 'block'; Answered = $answeredNow; Token = ('missing-after-work|' + $named); Text = (($lines.ToArray()) -join "`n") }
    }

    # Nothing was invoked and nothing was written: this session read and
    # answered. Whether a skill was NEEDED is not a judgement the hook can make
    # from that, so it advises and never blocks.
    return [pscustomobject]@{
        Kind  = 'advisory'
        Answered = $answeredNow
        Token = 'none-invoked'
        Text  = (@(
                'SKILL POLICY CHECK - no skill was invoked this session.',
                'If the task touched a specialised domain (debugging, testing, security review, UI/UX, a specific stack) an installed skill probably applied and was skipped - a relevant INSTALLED skill may be activated without asking.',
                ('Either way the summary must carry the line: ' + $script:SkillsRequiredLine)
            ) -join "`n")
    }
}
