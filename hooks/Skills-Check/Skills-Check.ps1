# SkillsCheck - the whole skill lifecycle, routed to the ACTIVE agent's skill
# locations (never both policies at once), across four events.
#
# THREE INSTALLED SOURCES, always enumerated together - a skill missed because
# its source was never scanned is the defect this hook exists to prevent:
#   GLOBAL  <home>\.claude\skills          (Codex: <home>\.agents\skills)
#   LOCAL   <project>\.claude\skills       (Codex: <project>\.agents\skills)
#   PLUGIN  <home>\.claude\plugins\cache\<marketplace>\<plugin>\<version>\skills\*
#           reported as "<plugin>:<skill>", which is how the client addresses it.
# Plus a FOURTH, uninstalled source: the external skill library named by
# SKILLS_DIR / AI_SKILLS_DIR (no built-in default),
# which is searched AGAINST THE CURRENT PROMPT and reported as ready-to-run
# import instructions.
#
# ROLE (global-hook-rules.md, "Hook Roles"): DETECTOR/ADVISORY on the pre-task
# events, GATE on Stop/SubagentStop. The hook NEVER copies, installs, refreshes,
# overwrites, enables or removes a skill and never writes inside the scanned
# repo: skill-policy.md makes installation an authorized operation, so discovery
# and an exact instruction are the most this hook may do. The .ai/SKILLS.md
# record is the agent's to update, not the hook's.
#
# The Stop gate is narrow on purpose. It blocks on one confirmed, reproducible
# condition: the session transcript shows a skill was actually INVOKED and the
# closing summary carries no line starting "Skills used:". Whether a skill
# SHOULD have been used is a judgement the hook cannot make, so that case stays
# a non-blocking advisory.
#
# WHY THE MATCH IS ANCHORED: this hook's own output lands in the transcript it
# later reads, so an unanchored search would be satisfied by the hook's own
# instruction text. The pattern requires the token at the START of a transcript
# line (a literal \n escape inside a JSONL string, or a real line break), and no
# line this hook emits ever starts with it.
#
# EVENTS:
# - SessionStart      routed inventory of all three installed sources (project
#                     and global skills deduped by the name: in their SKILL.md,
#                     plugin skills by plugin), plus the closing requirement.
# - UserPromptSubmit  prompt-matched shortlist: which INSTALLED skills to
#                     activate, and which LIBRARY skills to import (with the
#                     exact destination path). A standalone `::deep-debug`
#                     codeword instead surfaces the composite capability graph.
#                     Fingerprint-gated so unchanged guidance shows once.
# - Stop/SubagentStop verifies the "Skills used:" line. Honours stop_hook_active.
#
# Token- and time-efficient by design:
# - Silent when no skill source exists at all (checked once, all four events).
# - The two EXPENSIVE enumerations - the plugin cache glob and the ~1000-entry
#   library walk - are cached in a local index with a TTL, so a prompt costs a
#   single small file read instead of ~2 seconds of directory traversal. The
#   small curated project/global directories are always read live, because that
#   is where a stale answer would actually mislead.
# - The inventory names project/global skills in full but plugin skills only by
#   plugin and count: several hundred plugin skill names is a token bill, not
#   information, and the client already lists them.
#
# Optional .env next to this script (copy .env.example):
#   SKILLS_DIR                 skill library location (else AI_SKILLS_DIR, else
#                              the machine default from the Skill Policy).
#   GLOBAL_SKILLS_DIR          the client's global skills directory.
#   PLUGIN_SKILLS_ROOT         the plugin cache root.
#   LIBRARY_INDEX_TTL_MINUTES  index lifetime, default 1440 (one day).
#   SKILLS_SUMMARY_ENFORCEMENT block (default) | advisory | off

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop')) { exit 0 }

$closing = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')
# A Stop hook that re-fires on its own block is the classic hook loop; the
# client sets this flag on the re-entry and every Stop handler must honour it.
if ($closing) {
    # Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
    # for ANY gate's block, and exiting on it alone let one block silence the
    # other twelve on the same Stop.
    if (Test-StopStandDown -HookInput $hookInput -HookName 'Skills-Check') { exit 0 }
}

# ---- which client is running? (same signal the rest of the project uses) ----
$client = Get-HookClientId
# Policy selection is keyed on 'codex' POSITIVELY, not on "not claude", so any
# non-Codex client correctly lands on the non-Codex policy. That is exactly what
# the Skill Policy requires for a third client, and it is why this line needs no
# per-client special case - only the identity above had to stop guessing.
$policyFile = if ($client -eq 'codex') { 'skill-policy-codex-optimized.md' } else { 'skill-policy.md' }

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

$sessionId = [string](Get-Field $hookInput 'session_id')
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$projectKey = Get-ShortHash $cwd.ToLowerInvariant()

# The exact wording the closing summary must carry. One definition, shared by
# the pre-task instruction, the closing block message and the detector.
$script:SkillsRequiredLine = 'Skills used: <skill names>   (or exactly "Skills used: none - <one-line reason>")'
$script:SkillsRequirement = 'CLOSING REQUIREMENT - end the final task summary with its own line starting "Skills used:" naming ONLY the exact skill names actually invoked or materially followed - never a skill that was merely installed, available, discovered, copied, considered, or read but not used, and never the whole library. If none were used, write "Skills used: none - <one-line reason>"; do not force a skill for trivial tasks merely to produce the line.'
# The import safety boundary, stated wherever an import is suggested. Copying a
# skill is an AUTHORIZED operation under the Skill Policy and this hook never
# performs one - so every place that names a copy command also names its rules.
$script:ImportGuidance = 'Import guidance: copy the minimal set (1-5) as real folders (never reparse points, junctions or shortcuts), exclude secrets/caches/VCS metadata, never overwrite a modified project skill silently, and record source/destination/hash/agent/reason in .ai/SKILLS.md.'

# ---- shared skill library (searched by prompt, never enumerated into output) --
$libraryDir = ''
if ($config.ContainsKey('SKILLS_DIR') -and $config['SKILLS_DIR'] -ne '') {
    $libraryDir = $config['SKILLS_DIR']
}
elseif ($env:AI_SKILLS_DIR) {
    $libraryDir = $env:AI_SKILLS_DIR
}
else {
    # NO default. The Skill Policy is explicit that an unset library location is
    # asked about, never guessed, and a hard-coded absolute path is both a guess
    # and one machine's disk layout baked into shipped source. Unset means there
    # is no library here, and the library half of this hook stays silent.
    $libraryDir = ''
}
$hasLibrary = Test-Path -LiteralPath $libraryDir -PathType Container

# ---- client-routed project + global skill directories ----
if ($client -eq 'codex') {
    $projectSkillsDir = Join-Path $cwd '.agents\skills'
}
else {
    $projectSkillsDir = Join-Path $cwd '.claude\skills'
}

# USERPROFILE first: Windows PowerShell 5.1 derives $HOME from HOMEDRIVE/HOMEPATH,
# which can disagree with the profile the user actually means.
$homeDir = [string]$env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = [string]$HOME }

$globalSkillsDirs = New-Object System.Collections.Generic.List[string]
if ($config.ContainsKey('GLOBAL_SKILLS_DIR') -and $config['GLOBAL_SKILLS_DIR'] -ne '') {
    [void]$globalSkillsDirs.Add($config['GLOBAL_SKILLS_DIR'])
}
else {
    if (-not [string]::IsNullOrWhiteSpace($homeDir)) {
        if ($client -eq 'codex') { [void]$globalSkillsDirs.Add((Join-Path $homeDir '.agents\skills')) }
        else { [void]$globalSkillsDirs.Add((Join-Path $homeDir '.claude\skills')) }
    }
    # Codex also has an admin location; absent on Windows -> filtered by Test-Path.
    if ($client -eq 'codex') { [void]$globalSkillsDirs.Add('/etc/codex/skills') }
}

# ---- plugin skill cache -----------------------------------------------------
# Claude Code installs a plugin as
# <root>\<marketplace>\<plugin>\<version>\skills\<skill>\, and addresses its
# skills as "<plugin>:<skill>". Codex documents no plugin cache, so the default
# is Claude's; an explicit PLUGIN_SKILLS_ROOT overrides it for any client (and
# keeps the test suite off the real machine's plugins).
$pluginRoot = ''
if ($config.ContainsKey('PLUGIN_SKILLS_ROOT') -and $config['PLUGIN_SKILLS_ROOT'] -ne '') {
    $pluginRoot = $config['PLUGIN_SKILLS_ROOT']
}
elseif ($client -ne 'codex' -and -not [string]::IsNullOrWhiteSpace($homeDir)) {
    $pluginRoot = Join-Path $homeDir '.claude\plugins\cache'
}
$hasPluginRoot = (-not [string]::IsNullOrWhiteSpace($pluginRoot)) -and (Test-Path -LiteralPath $pluginRoot -PathType Container)

$skillsRecord = Join-Path $cwd '.ai\SKILLS.md'
$hasRecord = Test-Path -LiteralPath $skillsRecord -PathType Leaf

# ---- enumerate the (small, curated) project + global skill folders ----
# Immediate children only; reparse points are skipped, never followed. These two
# sources are read LIVE on every event: they are tiny, and they are the ones a
# stale answer would actually mislead about.
$maxSkills = 200
$skillFolders = New-Object System.Collections.Generic.List[object]
$enumSources = New-Object System.Collections.Generic.List[object]
[void]$enumSources.Add([pscustomobject]@{ Label = 'project'; Dir = $projectSkillsDir })
foreach ($g in $globalSkillsDirs) { [void]$enumSources.Add([pscustomobject]@{ Label = 'global'; Dir = $g }) }
foreach ($src in $enumSources) {
    if ([string]::IsNullOrWhiteSpace($src.Dir) -or -not (Test-Path -LiteralPath $src.Dir -PathType Container)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $src.Dir -Directory -ErrorAction SilentlyContinue)) {
        if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) { continue }
        [void]$skillFolders.Add([pscustomobject]@{ Label = $src.Label; Path = $d.FullName; Leaf = $d.Name })
        if ($skillFolders.Count -ge $maxSkills) { break }
    }
    if ($skillFolders.Count -ge $maxSkills) { break }
}

# ---- the cached index of the two EXPENSIVE sources -------------------------
# Plugin cache glob (~1.2s) + library walk (~0.7s) on this machine. Re-running
# both on every prompt is exactly the "rescan an unchanged repository on every
# event" that global-hook-rules.md forbids, so the result is cached in a local
# index keyed by the source configuration and bounded by a TTL.
#
# Flat lines, not JSON: ~1200 entries parse in milliseconds this way, and the
# file is only ever produced and consumed here.
#   header  HookMakerSkillsIndex|1|<configHash>|<builtUtcTicks>
#   plugin  p|<plugin>|<skill folder>|<full path>
#   library l|<skill folder>|<full path>
$indexPath = Join-Path $stateDir ('SkillsCheck-index-' + $projectKey + '.txt')
$indexTtlMinutes = 1440
if ($config.ContainsKey('LIBRARY_INDEX_TTL_MINUTES')) {
    $parsed = 0
    if ([int]::TryParse([string]$config['LIBRARY_INDEX_TTL_MINUTES'], [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 525600) {
        $indexTtlMinutes = $parsed
    }
}
$indexConfigHash = Get-ShortHash (($libraryDir + '|' + $pluginRoot + '|' + $client).ToLowerInvariant())

# Reads the index when it is present, current and built from THIS configuration.
# Returns $null otherwise - a stale or foreign index is rebuilt, never trusted.
function Read-SkillIndex {
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($indexPath)
        if ($lines.Count -lt 1) { return $null }
        $head = $lines[0].Split('|')
        if ($head.Count -lt 4 -or $head[0] -ne 'HookMakerSkillsIndex' -or $head[1] -ne '1') { return $null }
        if ($head[2] -ne $indexConfigHash) { return $null }
        $ticks = 0L
        if (-not [int64]::TryParse($head[3], [ref]$ticks)) { return $null }
        if ($indexTtlMinutes -gt 0) {
            $age = ([DateTime]::UtcNow - [DateTime]::new($ticks, [DateTimeKind]::Utc)).TotalMinutes
            if ($age -lt 0 -or $age -gt $indexTtlMinutes) { return $null }
        }
        $plugin = New-Object System.Collections.Generic.List[object]
        $library = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $parts = $lines[$i].Split('|')
            if ($parts[0] -eq 'p' -and $parts.Count -ge 4) {
                [void]$plugin.Add([pscustomobject]@{ Plugin = $parts[1]; Leaf = $parts[2]; Path = $parts[3] })
            }
            elseif ($parts[0] -eq 'l' -and $parts.Count -ge 3) {
                [void]$library.Add([pscustomobject]@{ Leaf = $parts[1]; Path = $parts[2] })
            }
        }
        return [pscustomobject]@{ Plugin = $plugin; Library = $library }
    }
    catch { return $null }
}

# Walks both expensive sources and writes the index. Bounded on both sides; a
# source that is absent or unreadable simply contributes nothing, and the
# resulting partial coverage is reported rather than presented as complete.
function Build-SkillIndex {
    $plugin = New-Object System.Collections.Generic.List[object]
    $library = New-Object System.Collections.Generic.List[object]
    $maxPlugin = 600
    $maxLibrary = 4000

    if ($hasPluginRoot) {
        try {
            foreach ($skillsDir in @(Get-ChildItem -Path (Join-Path $pluginRoot '*\*\*\skills') -Directory -ErrorAction SilentlyContinue)) {
                # <root>\<marketplace>\<plugin>\<version>\skills -> the plugin
                # name is three levels up, which is the id the client prefixes.
                $pluginName = ''
                try { $pluginName = (Get-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $skillsDir.FullName))).Name } catch { $pluginName = '' }
                if ($pluginName -eq '') { continue }
                foreach ($d in @(Get-ChildItem -LiteralPath $skillsDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                    if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) { continue }
                    [void]$plugin.Add([pscustomobject]@{ Plugin = $pluginName; Leaf = $d.Name; Path = $d.FullName })
                    if ($plugin.Count -ge $maxPlugin) { break }
                }
                if ($plugin.Count -ge $maxPlugin) { break }
            }
        }
        catch { }
    }

    if ($hasLibrary) {
        # A skill is a directory holding SKILL.md. The library mixes flat skills
        # and category\skill layouts, so depth 2 covers both. -Recurse does not
        # follow reparse points, which is the containment guarantee wanted here.
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $libraryDir -Recurse -Depth 2 -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue)) {
                $dir = Split-Path -Parent $f.FullName
                [void]$library.Add([pscustomobject]@{ Leaf = (Split-Path -Leaf $dir); Path = $dir })
                if ($library.Count -ge $maxLibrary) { break }
            }
        }
        catch { }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('HookMakerSkillsIndex|1|' + $indexConfigHash + '|' + [DateTime]::UtcNow.Ticks)
    foreach ($p in $plugin) { [void]$lines.Add('p|' + $p.Plugin + '|' + $p.Leaf + '|' + $p.Path) }
    foreach ($l in $library) { [void]$lines.Add('l|' + $l.Leaf + '|' + $l.Path) }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $tmp = $indexPath + '.tmp'
        [System.IO.File]::WriteAllLines($tmp, [string[]]$lines.ToArray(), (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $indexPath -Force
    }
    catch { }
    return [pscustomobject]@{ Plugin = $plugin; Library = $library }
}

# SessionStart is the natural refresh point (once per session); every other
# event reuses the index and only rebuilds when it is missing or expired.
$index = Read-SkillIndex
if ($null -eq $index) { $index = Build-SkillIndex }

# Nothing to point at, for any event -> stay silent, zero tokens.
if (-not $hasLibrary -and -not $hasRecord -and $skillFolders.Count -eq 0 -and $index.Plugin.Count -eq 0) { exit 0 }

# ---- build the deduped project/global inventory (name: from SKILL.md) ------
# Dedup key: exact skill name (case-insensitive). A single name appearing in
# more than one source with DIFFERENT content (SKILL.md hash) is a conflict the
# agent must reconcile - never a silent overwrite.
$byName = @{}
$seenPaths = @{}
foreach ($fe in $skillFolders) {
    $canon = (Normalize-Path $fe.Path).ToLowerInvariant()
    if ($seenPaths.ContainsKey($canon)) { continue }
    $seenPaths[$canon] = $true
    $name = $fe.Leaf
    # ponytail: SKILL.md hash is the skill identity; deepen to a full-folder
    # hash only if SKILL.md-identical-but-body-different conflicts ever matter.
    $hash = 'no-skillmd'
    $skillMd = Join-Path $fe.Path 'SKILL.md'
    if (Test-Path -LiteralPath $skillMd -PathType Leaf) {
        try {
            $text = [System.IO.File]::ReadAllText($skillMd)
            if ($text.Length -gt 65536) { $text = $text.Substring(0, 65536) }
            $hash = Get-ShortHash $text
            if ($text -match '(?im)^\s*name\s*:\s*(.+?)\s*$') {
                $candidate = $Matches[1].Trim().Trim('"').Trim("'")
                if ($candidate -ne '') { $name = $candidate }
            }
        }
        catch { }
    }
    $key = $name.ToLowerInvariant()
    if (-not $byName.ContainsKey($key)) {
        $byName[$key] = [pscustomobject]@{
            Name    = $name
            Sources = (New-Object System.Collections.Generic.List[string])
            Hashes  = (New-Object System.Collections.Generic.List[string])
        }
    }
    $entry = $byName[$key]
    if (-not $entry.Sources.Contains($fe.Label)) { [void]$entry.Sources.Add($fe.Label) }
    if (-not $entry.Hashes.Contains($hash)) { [void]$entry.Hashes.Add($hash) }
}

$skillLines = New-Object System.Collections.Generic.List[string]
$conflictLines = New-Object System.Collections.Generic.List[string]
foreach ($key in @($byName.Keys | Sort-Object)) {
    $e = $byName[$key]
    [void]$skillLines.Add('- ' + $e.Name + ' [' + ((@($e.Sources) | Sort-Object) -join '+') + ']')
    if ($e.Hashes.Count -gt 1) {
        [void]$conflictLines.Add('CONFLICT (repair before use): "' + $e.Name + '" differs between ' + ((@($e.Sources) | Sort-Object) -join ' and ') + ' - do NOT overwrite silently; diff the two copies, reconcile, and record the chosen version in .ai/SKILLS.md.')
    }
}

# Plugin skills addressed the way the client addresses them, and the set of
# names already installed anywhere - used to keep an import suggestion from
# recommending something that is already available.
$pluginNames = @{}
$pluginsByPlugin = @{}
foreach ($p in $index.Plugin) {
    $full = $p.Plugin + ':' + $p.Leaf
    $pluginNames[$full.ToLowerInvariant()] = $true
    $pluginNames[([string]$p.Leaf).ToLowerInvariant()] = $true
    if (-not $pluginsByPlugin.ContainsKey($p.Plugin)) { $pluginsByPlugin[$p.Plugin] = 0 }
    $pluginsByPlugin[$p.Plugin] = $pluginsByPlugin[$p.Plugin] + 1
}
$installedNames = @{}
foreach ($key in $byName.Keys) { $installedNames[$key] = $true }
foreach ($key in $pluginNames.Keys) { $installedNames[$key] = $true }

# ---- bounded transcript probe ---------------------------------------------
# A private copy rather than a shared helper: hooks\_hooklib.ps1 is owned
# elsewhere in this change. Shared read (a live writer is never blocked),
# bounded tail; the text is only searched - never stored, printed or hashed.
# $null means UNKNOWN, which must never become an all-clear.
function Get-TranscriptTailText {
    param([string]$Path, [int]$TailBytes = 262144)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $take = [int][Math]::Min([int64]$TailBytes, $stream.Length)
            if ($take -le 0) { return $null }
            if ($stream.Length -gt $take) { [void]$stream.Seek(-$take, [System.IO.SeekOrigin]::End) }
            $buffer = New-Object byte[] $take
            # Read in a LOOP: a single Read may legally return fewer bytes than
            # asked for, and a short read would look like a missing summary line
            # - i.e. it would produce a FALSE BLOCK.
            $filled = 0
            while ($filled -lt $take) {
                $chunk = $stream.Read($buffer, $filled, $take - $filled)
                if ($chunk -le 0) { break }
                $filled += $chunk
            }
            if ($filled -le 0) { return $null }
            return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $filled)
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
}

# Which transcript the FALLBACK reader should open when _stoplib.ps1 is absent.
# A subagent event must never be answered from the parent's transcript.
function Get-EvidenceTranscriptFallbackPath {
    param($HookInput)
    if ([string](Get-Field $HookInput 'hook_event_name') -eq 'SubagentStop') {
        return [string](Get-Field $HookInput 'agent_transcript_path')
    }
    return [string](Get-Field $HookInput 'transcript_path')
}


# ============================ CLOSING HALF ==================================
if ($closing) {
    $enforcement = 'block'
    if ($config.ContainsKey('SKILLS_SUMMARY_ENFORCEMENT')) {
        $raw = ([string]$config['SKILLS_SUMMARY_ENFORCEMENT']).Trim().ToLowerInvariant()
        if ($raw -eq 'block' -or $raw -eq 'advisory' -or $raw -eq 'off') { $enforcement = $raw }
    }
    if ($enforcement -eq 'off') { exit 0 }

    $gatePath = Join-Path $stateDir ('SkillsCheck-close-' + $projectKey + '.txt')
    function Test-ShouldReportClosing {
        param([string]$StateToken)
        $fp = Get-ShortHash ($sessionId + '|' + $eventName + '|' + $StateToken)
        try {
            if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
                if (([System.IO.File]::ReadAllText($gatePath)).Trim() -eq $fp) { return $false }
            }
        }
        catch { }
        try {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            [System.IO.File]::WriteAllText($gatePath, $fp, (New-Object System.Text.UTF8Encoding $false))
        }
        catch { }
        return $true
    }

    # EVIDENCE SOURCE (F03). The raw session tail is not this task's answer: a user
    # example, a previous task's line, or this hook's own injected text all live in
    # it, and the old regex also required a preceding newline so a valid line at the
    # very start of the response was missed. Get-ClosingAssistantText returns the
    # CURRENT final assistant response - from the event when the client supplies it,
    # otherwise the last assistant entry parsed out of the transcript (the CHILD
    # transcript for a subagent event). Unknown stays unknown.
    $evidence = $null
    if ($null -ne (Get-Command Get-ClosingAssistantText -ErrorAction SilentlyContinue)) {
        $evidence = Get-ClosingAssistantText -HookInput $hookInput
    }
    if ($null -ne $evidence -and $evidence.Known) { $tail = [string]$evidence.Text }
    else { $tail = Get-TranscriptTailText (Get-EvidenceTranscriptFallbackPath $hookInput) }
    if ($null -eq $tail) {
        # UNKNOWN - no transcript, unreadable, or a client that supplies none.
        if (-not (Test-ShouldReportClosing 'unverified')) { exit 0 }
        $note = @(
            'SKILL POLICY CHECK - the session transcript was not available to this hook, so skill use could NOT be verified (this is not an all-clear).',
            $script:SkillsRequirement
        ) -join "`n"
        $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $note
        exit $emit.ExitCode
    }

    # Anchored at the start of a transcript line so this hook's own instruction
    # text can never satisfy it.
    if ($tail -match '(?im)^[ \t]{0,8}(?:[-*>#]+[ \t]{0,4})?(?:\*\*)?Skills?[ \t]+used[ \t]*:') { exit 0 }

    # Was a skill actually invoked? The client's own tool-call record is the
    # evidence; a client whose transcript does not carry it yields no evidence,
    # and the branch below degrades to an advisory rather than guessing.
    $skillInvoked = ($tail -match '"name"[ \t]*:[ \t]*"Skill"')
    if ($skillInvoked) {
        if (-not (Test-ShouldReportClosing 'missing-after-invoke')) { exit 0 }
        $reason = @(
            'SKILL POLICY CHECK - this session invoked at least one skill and the closing summary does not report which.',
            # The example is deliberately kept INLINE and quoted rather than on a
            # line of its own: this message lands in the same transcript the next
            # Stop reads, and an example at the start of a line would satisfy the
            # detector - the hook would then clear its own block.
            'TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "Skills used:" and naming the exact skill name(s) invoked or materially followed - e.g. "Skills used: superpowers:systematic-debugging, powershell-windows".',
            'Name only skills that actually shaped the work; a skill that was opened and then not followed does not count.'
        ) -join "`n"
        if ($enforcement -eq 'advisory') {
            $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $reason
            exit $emit.ExitCode
        }
        # Record the block so THIS hook's own re-entry is recognised; another
        # gate's block must not mute it, and its own must not repeat.
        Set-StopBlockMarker -HookInput $hookInput -HookName 'Skills-Check'
        $emit = Write-HookResult -EventName $eventName -Kind 'block' -Reason $reason
        exit $emit.ExitCode
    }

    # No skill invoked: whether one was NEEDED is a judgement the hook cannot
    # make, so this never blocks.
    if (-not (Test-ShouldReportClosing 'none-invoked')) { exit 0 }
    $note = @(
        'SKILL POLICY CHECK - no skill was invoked this session.',
        'If the task touched a specialised domain (debugging, testing, security review, UI/UX, a specific stack) an installed skill probably applied and was skipped - a relevant INSTALLED skill may be activated without asking.',
        ('Either way the summary must carry the line: ' + $script:SkillsRequiredLine)
    ) -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $note
    exit $emit.ExitCode
}
# ========================== end CLOSING HALF ================================

if ($eventName -eq 'UserPromptSubmit') {
    $sig = ''
    foreach ($key in @($byName.Keys | Sort-Object)) {
        $sig += $key + ':' + ((@($byName[$key].Hashes) | Sort-Object) -join ',') + ';'
    }

    # ---- standalone ::deep-debug codeword -> phase-routed capability graph ----
    # CODEWORDS.md: only a standalone ::-prefixed token activates the composite
    # workflow; ordinary prose "deep debug" falls through to the generic nudge.
    $prompt = [string](Get-Field $hookInput 'prompt')
    if ($prompt -match '(?i)(^|\s)::deep-debug([\s.,;:!?]|$)') {
        # Fingerprint = session + client + installed skill set: unchanged
        # guidance shows once per session; a skill-set change re-reports at once.
        $ddFingerprint = Get-ShortHash ($sessionId + '|deepdebug|' + $client + '|' + $sig)
        $ddStatePath = Join-Path $stateDir ('SkillsCheck-deepdebug-' + $projectKey + '.txt')
        if (Test-Path -LiteralPath $ddStatePath -PathType Leaf) {
            try {
                if (([System.IO.File]::ReadAllText($ddStatePath)).Trim() -eq $ddFingerprint) { exit 0 }
            }
            catch { }
        }
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($ddStatePath, $ddFingerprint)

        # Only the NATIVE invocation references differ per client; the graph and
        # the skill identities (exact name: in each installed SKILL.md) are the
        # same. Neither client's syntax is authoritative for the other, and the
        # references stay plain text - this hook never executes them.
        if ($client -eq 'codex') {
            $goalRef = 'the client-native goal command (this client''s own syntax, never another client''s slash form)'
            $ponytailRef = 'the verified installed ponytail-audit capability via this client''s supported invocation'
        }
        else {
            $goalRef = 'native /goal'
            $ponytailRef = 'native /ponytail:ponytail-audit'
        }

        # Core capabilities every ::deep-debug pass relies on: report what the
        # enumerated sources do NOT show instead of silently skipping it. The
        # scan now covers project, global AND plugin skills, so absence here is
        # a much stronger signal than it used to be - but it is still bounded
        # coverage, so it means "verify elsewhere / report as missing", never a
        # silent all-clear and never an install.
        $notVisible = New-Object System.Collections.Generic.List[string]
        foreach ($cap in @('systematic-debugging', 'test-driven-development', 'requesting-code-review', 'verification-before-completion')) {
            $found = $false
            foreach ($key in $byName.Keys) {
                if ($key -eq $cap -or $key.EndsWith(':' + $cap)) { $found = $true; break }
            }
            if (-not $found) {
                foreach ($key in $pluginNames.Keys) {
                    if ($key -eq $cap -or $key.EndsWith(':' + $cap)) { $found = $true; break }
                }
            }
            if (-not $found) { [void]$notVisible.Add($cap) }
        }

        $dd = New-Object System.Collections.Generic.List[string]
        [void]$dd.Add('SKILL POLICY CHECK (' + $client + ') - ::deep-debug capability routing. Activate by PHASE, never everything at once; skill identity is the exact name: in each installed SKILL.md (never a folder, plugin, marketplace, or category label). Inspect installed/loadable skills FIRST; never silently install/copy/refresh/overwrite/remove/enable a skill.')
        [void]$dd.Add('- Goal/orchestration: ' + $goalRef + ' first; ::multi-agent is a codeword dependency, not a skill; superpowers:dispatching-parallel-agents for independent discovery/debug workstreams; superpowers:subagent-driven-development for a prepared plan with substantially independent tasks. Flatten dependencies once, deduplicate, detect cycles - never recursive re-runs, never nested agent trees.')
        [void]$dd.Add('- Understanding/planning: audit-context-building for medium/large/unfamiliar/architecture-heavy/security-heavy scope; Graphify only under its own policy; superpowers:brainstorming only for genuine behavior/design ambiguity; superpowers:writing-plans only when a complex repair lacks an executable plan.')
        [void]$dd.Add('- Known bug: systematic-debugging, test-driven-development, verification-before-completion; runtime evidence -> CHOOSE debugging-code (DAP) OR debug-live (trusted DebugMCP/VS Code), not normally both for one question.')
        [void]$dd.Add('- Existing plan: executing-plans (only when a real plan exists), test-driven-development, requesting-code-review, verification-before-completion.')
        [void]$dd.Add('- Security-sensitive: smallest applicable subset of differential-review, insecure-defaults, requesting-code-review, verification-before-completion, semgrep and/or codeql, sarif-parsing (when SARIF output exists), fp-check before treating automated findings as confirmed, variant-analysis after a proven root cause, supply-chain-risk-auditor (dependency/supply-chain scope), c-review (C/C++ only), rust-review (Rust only). "static-analysis" is a plugin/category LABEL, not an invokable skill, unless an installed SKILL.md declares that exact name:. Active security testing still requires ownership/authorization and matching scope.')
        [void]$dd.Add('- Test strengthening: property-based-testing only where a meaningful invariant exists (round trips, validators, state machines, path containment, idempotency, boundaries) - never manufacture low-value properties to claim skill use.')
        [void]$dd.Add('- Finalization: superpowers:using-git-worktrees only when authorized isolation materially reduces collision risk; after integration requesting-code-review + verification-before-completion; superpowers:finishing-a-development-branch only when work really occurred on an independent branch and all checks are green; THEN run ' + $ponytailRef + ' exactly ONCE - afterwards only safe accepted simplifications + targeted tests + final verification, never a second pass.')
        if ($notVisible.Count -gt 0) {
            [void]$dd.Add('- NOT VISIBLE in the enumerated project/global/plugin skill sources: ' + ($notVisible.ToArray() -join ', ') + '. Verify each is installed/loadable elsewhere before relying on it; a genuinely missing required capability must be REPORTED as missing and the workflow marked blocked/partial - never silently skipped.')

        }
        [void]$dd.Add('- Select only the task-relevant subset; keep Claude and Codex invocation syntax separate - neither client''s syntax is authoritative for the other. This hook routes only: it never executes a skill, slash command, or codeword.')
        [void]$dd.Add($script:SkillsRequirement)
        $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($dd.ToArray() -join "`n")
        exit $emit.ExitCode
    }

    # ---- prompt-matched shortlist across all four sources -------------------
    # The whole point of this branch: turn "there are 1200 skills somewhere" into
    # "these are the ones THIS prompt is about, and here is the exact command for
    # the ones that are not installed yet".
    $stop = @('the', 'and', 'this', 'that', 'with', 'from', 'into', 'have', 'been', 'what', 'when',
        'where', 'which', 'there', 'their', 'would', 'should', 'could', 'about', 'because',
        'while', 'these', 'those', 'then', 'than', 'them', 'they', 'your', 'yours', 'just',
        'also', 'only', 'very', 'much', 'many', 'more', 'most', 'some', 'each', 'other',
        'over', 'under', 'after', 'before', 'again', 'still', 'even', 'ever', 'never',
        'please', 'thanks', 'does', 'done', 'need', 'want', 'make', 'made', 'here', 'must')
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($t in @([regex]::Split($prompt.ToLowerInvariant(), '[^a-z0-9]+'))) {
        if ($t.Length -lt 4 -or $t.Length -gt 32) { continue }
        if ($stop -contains $t) { continue }
        if ($tokens.Contains($t)) { continue }
        [void]$tokens.Add($t)
        if ($tokens.Count -ge 14) { break }
    }

    # Score one skill folder name against the prompt tokens. A word-for-word hit
    # is worth more than a substring hit, and a substring hit needs 5+ characters
    # so that "test" cannot drag in every name containing "latest".
    function Get-PromptMatchScore {
        param([string]$Leaf)
        $normalized = ($Leaf -replace '[^A-Za-z0-9]+', ' ').ToLowerInvariant().Trim()
        if ($normalized -eq '') { return 0 }
        $words = @($normalized.Split(' ') | Where-Object { $_ -ne '' })
        $score = 0
        foreach ($t in $tokens) {
            if ($words -contains $t) { $score += 2; continue }
            if ($t.Length -ge 5 -and $normalized.Contains($t)) { $score += 1 }
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
        foreach ($p in $index.Plugin) {
            $s = Get-PromptMatchScore $p.Leaf
            if ($s -gt 0) { [void]$installedMatches.Add([pscustomobject]@{ Name = ($p.Plugin + ':' + $p.Leaf); Score = $s; Where = 'plugin' }) }
        }
        foreach ($l in $index.Library) {
            # Already available somewhere: importing it again is noise, and
            # suggesting an install the policy would have to authorize is worse.
            if ($installedNames.ContainsKey(([string]$l.Leaf).ToLowerInvariant())) { continue }
            $s = Get-PromptMatchScore $l.Leaf
            if ($s -gt 0) { [void]$libraryMatches.Add([pscustomobject]@{ Name = $l.Leaf; Score = $s; Path = $l.Path }) }
        }
    }
    $topInstalled = @($installedMatches | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Name' } | Select-Object -First 6)
    $topLibrary = @($libraryMatches | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Name' } | Select-Object -First 5)

    # Fingerprint = session + client + everything the message would say. An
    # unchanged answer shows once; a new prompt with different matches, or a
    # changed skill set, re-reports immediately.
    $matchSig = (@($topInstalled | ForEach-Object { $_.Name + '@' + $_.Score }) -join ',') + '#' +
                (@($topLibrary | ForEach-Object { $_.Name + '@' + $_.Score }) -join ',')
    $fingerprint = Get-ShortHash ($sessionId + '|' + $client + '|' + $hasLibrary + '|' + $libraryDir + '|' + $hasRecord + '|' + $sig + '|' + $matchSig)
    $statePath = Join-Path $stateDir ('SkillsCheck-prompt-' + $projectKey + '.txt')
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 }
        }
        catch { }
    }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($statePath, $fingerprint)

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('SKILL POLICY CHECK (' + $client + ') - decide NOW whether a skill materially helps this task; skip only for trivial edits. Sources searched: project, global, plugin, and the shared library.')
    if ($topInstalled.Count -gt 0) {
        [void]$lines.Add('INSTALLED and matching this prompt - activate the relevant ones by the exact name: in their SKILL.md (no authorization needed, they are already loadable):')
        foreach ($m in $topInstalled) { [void]$lines.Add('- ' + $m.Name + ' [' + $m.Where + ']') }
    }
    if ($topLibrary.Count -gt 0) {
        [void]$lines.Add('IN THE LIBRARY but NOT installed - these match this prompt. Importing a skill is an AUTHORIZED operation under ' + $policyFile + ': ask the user first, then run the exact command, then record source/destination/date/reason in .ai/SKILLS.md. This hook never copies anything itself.')
        [void]$lines.Add('Destination for this project: ' + $projectSkillsDir)
        foreach ($m in $topLibrary) {
            [void]$lines.Add('- ' + $m.Name + '   ->   Copy-Item -LiteralPath "' + $m.Path + '" -Destination "' + $projectSkillsDir + '" -Recurse -Force')
        }
        [void]$lines.Add('(Create the destination first if it is missing: New-Item -ItemType Directory -Path "' + $projectSkillsDir + '" -Force. Activate by the name: inside the copied SKILL.md, which may differ from the folder name.)')
        [void]$lines.Add($script:ImportGuidance)
    }
    if ($topInstalled.Count -eq 0 -and $topLibrary.Count -eq 0) {
        [void]$lines.Add('No skill name matched this prompt in any of the four sources. That is a name-level match only, not proof that no skill applies - if the task is clearly specialised, look through the sources yourself before deciding.')
        if ($hasLibrary) { [void]$lines.Add('Library: ' + $libraryDir) }
    }
    [void]$lines.Add($script:SkillsRequirement)
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($lines.ToArray() -join "`n")
    exit $emit.ExitCode
}

# ---- SessionStart: compact routed inventory of all three installed sources --
$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('SKILL POLICY CHECK (' + $client + ') - before working, decide whether a skill materially helps this task (skip trivial edits). A relevant INSTALLED skill may be activated without asking; installing, copying, updating or removing one may not.')
if ($skillLines.Count -gt 0) {
    [void]$lines.Add('Project + global skills (deduped by name:):')
    foreach ($sl in $skillLines) { [void]$lines.Add($sl) }
    foreach ($cl in $conflictLines) { [void]$lines.Add($cl) }
}
else {
    [void]$lines.Add('Project skills (' + $projectSkillsDir + '): none installed.')
}
if ($index.Plugin.Count -gt 0) {
    # Named by plugin, not by skill: several hundred skill names would be a token
    # bill rather than information, and the client already lists them. The
    # per-prompt shortlist above is where individual plugin skills surface.
    $pluginSummary = @($pluginsByPlugin.Keys | Sort-Object | ForEach-Object { $_ + ' (' + $pluginsByPlugin[$_] + ')' })
    $shown = @($pluginSummary | Select-Object -First 24)
    $suffix = ''
    if ($pluginSummary.Count -gt $shown.Count) { $suffix = ', +' + ($pluginSummary.Count - $shown.Count) + ' more plugins' }
    [void]$lines.Add('Plugin skills: ' + $index.Plugin.Count + ' across ' + $pluginsByPlugin.Count + ' plugins - ' + ($shown -join ', ') + $suffix + '. Address these as <plugin>:<skill>.')
}
elseif ($hasPluginRoot) {
    [void]$lines.Add('Plugin skills: none found under ' + $pluginRoot + '.')
}
[void]$lines.Add('- Activate the relevant ones by the exact name: in each SKILL.md - never by folder, plugin, marketplace or category label.')
if ($hasRecord) {
    [void]$lines.Add('- Read .ai/SKILLS.md for the active-skill record; keep it updated (local-only, secret-free) when skills change.')
}
if ($hasLibrary) {
    [void]$lines.Add('- Skill library: ' + $libraryDir + ' (' + $index.Library.Count + ' skills indexed). It is searched against each prompt; a match that is not installed is reported with the exact import command into ' + $projectSkillsDir + '. Importing is an authorized operation - ask first, never copy silently.')
    [void]$lines.Add('- ' + $script:ImportGuidance)
}
[void]$lines.Add('- Select only the minimal relevant set (1-5). Follows ' + $policyFile + '.')
[void]$lines.Add($script:SkillsRequirement)

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($lines.ToArray() -join "`n")
exit $emit.ExitCode
