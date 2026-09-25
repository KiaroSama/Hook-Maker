# Skills-Check - prompt matching for the UserPromptSubmit shortlist.
#
# Dot-sourced by Skills-Check.ps1 from inside its UserPromptSubmit branch,
# exactly where this block used to sit. Dot-sourcing runs in the CALLER scope,
# so $stop, $tokens, $installedMatches, $libraryMatches, $bySource,
# $topInstalled and $topLibrary land where they always did, in the same order.
#
# Definitions and pure statements only - no "exit" lives in this file. An exit
# inside a dot-sourced script ends only that script: the caller keeps running
# and the process exit code is never set, so a gate moved out of an entry point
# would print its refusal and then allow through what it meant to block. The
# half that emits and exits stays in Skills-Check.ps1.
#
# Reads from the caller: $prompt, $byName, $index, $installedNames.

# ---- prompt-matched shortlist across all four sources -------------------
# The whole point of this branch: turn "there are 1200 skills somewhere" into
# "these are the ones THIS prompt is about, and here is the exact command for
# the ones that are not installed yet".
$stop = @('the', 'and', 'this', 'that', 'with', 'from', 'into', 'have', 'been', 'what', 'when',
    'where', 'which', 'there', 'their', 'would', 'should', 'could', 'about', 'because',
    'while', 'these', 'those', 'then', 'than', 'them', 'they', 'your', 'yours', 'just',
    'also', 'only', 'very', 'much', 'many', 'more', 'most', 'some', 'each', 'other',
    'over', 'under', 'after', 'before', 'again', 'still', 'even', 'ever', 'never',
    'please', 'thanks', 'does', 'done', 'need', 'want', 'make', 'made', 'here', 'must',
    # Ordinary software English that happens to BE some skills' own words. One such token
    # used to qualify a skill outright, which is how design and presentation skills attached
    # to a TypeScript refactor. Raising the score floor was measured and rejected: at 3 it
    # drops a true single-word match (a perfect hit on 'codeql' scores only 2) while still
    # admitting a name that collects 4 from two incidental words. Genericness separates
    # them, not the total.
    'create', 'created', 'file', 'files', 'folder', 'generate', 'generated', 'design',
    'report', 'update', 'delete', 'write', 'read', 'list', 'check', 'build', 'code', 'data',
    'text', 'name', 'line', 'page', 'view', 'open', 'close', 'send', 'load', 'save', 'find',
    'search', 'project', 'directory', 'command', 'script', 'agent', 'tool', 'skill', 'used',
    'apply', 'work', 'task', 'step')
$tokens = New-Object System.Collections.Generic.List[string]
# This hook's shortlist returns to it AS PROMPT TEXT whenever the 'Skills used:' line it
# demands is quoted back - by the user, by a reply-quote, or by a client that echoes the
# previous turn - and the names it just demanded then score highest and are demanded again.
# A prompt with no ASCII makes that total: the split keeps only [a-z0-9], so the quoted
# English names are the ONLY tokens left. Same reasoning as WHY THE MATCH IS ANCHORED at
# the top of this file, applied to the prompt. $prompt stays whole for the other branches.
$promptForMatching = [regex]::Replace([string]$prompt, '(?im)^[ \t]*Skills used:.*$', ' ')
foreach ($t in @([regex]::Split($promptForMatching.ToLowerInvariant(), '[^a-z0-9]+'))) {
    if ($t.Length -lt 4 -or $t.Length -gt 32) { continue }
    if ($stop -contains $t) { continue }
    if ($tokens.Contains($t)) { continue }
    [void]$tokens.Add($t)
    if ($tokens.Count -ge 14) { break }
}

# Score one piece of text against the prompt tokens. A word-for-word hit is
# worth more than a partial one, and a partial hit needs 5+ characters so
# that "test" cannot drag in every name containing "latest".
function Get-PromptMatchScore {
    param([string]$Leaf)
    $normalized = ($Leaf -replace '[^A-Za-z0-9]+', ' ').ToLowerInvariant().Trim()
    if ($normalized -eq '') { return 0 }
    $words = @($normalized.Split(' ') | Where-Object { $_ -ne '' })
    $score = 0
    foreach ($t in $tokens) {
        if ($words -contains $t) { $score += 2; continue }
        # A partial hit must START a word. Plain Contains() matched a token
        # anywhere inside one, so "engineering" pulled up "glycoengineering"
        # and every such folder became a suggestion for unrelated prompts.
        if ($t.Length -ge 5) {
            foreach ($w in $words) { if ($w.StartsWith($t)) { $score += 1; break } }
        }
    }
    return $score
}

# A skill is addressed by the name: in its SKILL.md, and what it is FOR is
# in the description. Scoring the folder alone missed every skill whose
# folder shares no token with the prompt, however exactly its description
# matched. The description is deliberately worth less than the name: it is
# long, so incidental words in it must not outrank a real name match.
function Get-SkillMatchScore {
    param([string]$Leaf, [string]$Name, [string]$Description)
    $score = Get-PromptMatchScore $Leaf
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $nameScore = Get-PromptMatchScore $Name
        if ($nameScore -gt $score) { $score = $nameScore }
    }
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        $descText = ($Description -replace '[^A-Za-z0-9]+', ' ').ToLowerInvariant().Trim()
        $descWords = @($descText.Split(' ') | Where-Object { $_ -ne '' })
        $hits = 0
        foreach ($t in $tokens) { if ($descWords -contains $t) { $hits++ } }
        if ($hits -gt 2) { $hits = 2 }
        $score += $hits
    }
    return $score
}

$installedMatches = New-Object System.Collections.Generic.List[object]
$libraryMatches = New-Object System.Collections.Generic.List[object]
if ($tokens.Count -gt 0) {
    foreach ($key in $byName.Keys) {
        $s = Get-PromptMatchScore $byName[$key].Name
        if ($s -gt 0) { [void]$installedMatches.Add([pscustomobject]@{ Name = $byName[$key].Name; Score = $s; Where = ((@($byName[$key].Sources) | Sort-Object) -join '+') }) }
    }
    # A description-only hit does NOT qualify an INSTALLED skill. One incidental
    # word in a long description used to admit one, which is how a statistics
    # skill and a design-tool skill attached to a prompt about a messaging
    # integration - and an installed skill that is offered must then be
    # ACCOUNTED FOR at Stop, so noise here costs the agent real turns.
    #
    # The LIBRARY loop below is deliberately NOT tightened the same way. A
    # library match is a suggestion to import, never gated (see the note at
    # the top of _skillstop.ps1), so finding one by its description costs
    # nothing and is the whole point: a skill whose folder shares no token
    # with the prompt is invisible without it. Accountability is what makes
    # the difference, not the scoring.
    foreach ($p in $index.Plugin) {
        # A disabled skill cannot be loaded and an explicit-only one is never
        # chosen by the model; shortlisting either would make the Stop gate
        # demand an invocation the client does not allow.
        if ($p.Status -eq 'disabled' -or $p.Explicit -eq '1') { continue }
        $identitySignal = [math]::Max((Get-PromptMatchScore $p.Leaf), (Get-PromptMatchScore $p.Name))
        if ($identitySignal -le 0) { continue }
        $s = Get-SkillMatchScore -Leaf $p.Leaf -Name $p.Name -Description $p.Description
        $exact = if ([string]::IsNullOrWhiteSpace([string]$p.Invocation)) { $p.Plugin + ':' + $p.Leaf } else { [string]$p.Invocation }
        $origin = if ($p.Source -eq 'claude-plugin' -or $p.Source -eq 'cache-walk' -or $p.Source -eq 'codex-plugin') { 'plugin' } else { [string]$p.Source }
        if ($s -gt 0) { [void]$installedMatches.Add([pscustomobject]@{ Name = $exact; Score = $s; Where = $origin; Path = $p.Path }) }
    }
    foreach ($l in $index.Library) {
        # Already available somewhere: importing it again is noise, and
        # suggesting an install the policy would have to authorize is worse.
        if ($installedNames.ContainsKey(([string]$l.Leaf).ToLowerInvariant())) { continue }
        $s = Get-SkillMatchScore -Leaf $l.Leaf -Name $l.Name -Description $l.Description
        if ($s -gt 0) { [void]$libraryMatches.Add([pscustomobject]@{ Name = $l.Leaf; Score = $s; Path = $l.Path }) }
    }
}
# Dozens tie at a low score, and settling that by name ranks a skill by where it falls in
# the alphabet - the whole reason unrelated plugin skills surfaced. Prefer what this
# project installed over what a plugin happens to ship.
$bySource = { if ($_.Where -match 'project') { 0 } elseif ($_.Where -match 'global') { 1 } else { 2 } }
$topInstalled = @($installedMatches | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = $bySource }, @{ Expression = 'Name' } | Select-Object -First 6)
$topLibrary = @($libraryMatches | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Name' } | Select-Object -First 5)
