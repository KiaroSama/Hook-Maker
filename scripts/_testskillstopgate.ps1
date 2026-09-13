# Test-ContextHooks section: the Skills-Check Stop/SubagentStop gate.
#
# Its own file because _testcontextskills.ps1 had reached the size ceiling, and
# because this is one coherent subject: what the closing gate blocks on and what
# it deliberately does not. Dot-sourced from there, so it runs in the same scope
# and uses the same harness directly ($Work, Fire, Check, New-Proj, Write-Utf8,
# New-ToolTranscript, New-StopStdin, New-PromptStdin, New-ConfiguredSkillsHookCopy).
#
# The underscore prefix keeps it out of the runner's Test-*.ps1 glob, so it
# needs no ci.yml bucket entry of its own.

    Write-Host '--- Skills-Check: substantive work is accountable, a read-only session is not ---' -ForegroundColor Cyan
    $wkProj = New-Proj 'StopWork'
    New-Item -ItemType Directory -Path (Join-Path $wkProj '.claude\skills\gate-skill') -Force | Out-Null
    $wkHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    # A file-mutating tool call with no closing line. Before this gate existed the
    # cheapest route past the policy was to invoke no skill at all: the session
    # was then merely advised, however much it changed.
    $tWrote = New-ToolTranscript 'sk-wrote' 'Write' "Done."
    $r = Fire -HookPath $wkHook -Cwd $wkProj -RawStdin (New-StopStdin -Cwd $wkProj -Transcript $tWrote -SessionId 'sk-w1')
    Check 'a session that CHANGED FILES and reported no skill -> a real block decision' (
        $r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'changed files') $r.Out
    Check 'the block offers the honest escape, not just the compliant one' (
        $r.Out -match 'Skills used: none' -and $r.Out -match 'Both are valid answers') $r.Out
    $r2 = Fire -HookPath $wkHook -Cwd $wkProj -RawStdin (New-StopStdin -Cwd $wkProj -Transcript $tWrote -SessionId 'sk-w1')
    Check 'the SAME unchanged failure does not block twice in one session' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $tWroteOk = New-ToolTranscript 'sk-wrote-ok' 'Write' "Done.`nSkills used: none - a docs-only edit"
    $r = Fire -HookPath $wkHook -Cwd $wkProj -RawStdin (New-StopStdin -Cwd $wkProj -Transcript $tWroteOk -SessionId 'sk-w2')
    Check 'the same work WITH the line is silent - "none plus a reason" is a real answer' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # The boundary: reading and answering is not work this gate can judge.
    $tRead = New-ToolTranscript 'sk-read' 'Read' 'Done.'
    $r = Fire -HookPath $wkHook -Cwd $wkProj -RawStdin (New-StopStdin -Cwd $wkProj -Transcript $tRead -SessionId 'sk-w3')
    Check 'a READ-ONLY session is advised, never blocked' (
        $r.Out -match 'no skill was invoked this session' -and $r.Out -notmatch '"decision"') $r.Out
    $tBash = New-ToolTranscript 'sk-bash' 'Bash' 'Done.'
    $r = Fire -HookPath $wkHook -Cwd $wkProj -RawStdin (New-StopStdin -Cwd $wkProj -Transcript $tBash -SessionId 'sk-w4')
    Check 'a shell command is NOT assumed to have mutated anything (evidence, not suspicion)' (
        $r.Out -notmatch '"decision"') $r.Out

    Write-Host '--- Skills-Check: a shortlisted INSTALLED skill must be used or accounted for ---' -ForegroundColor Cyan
    $slProj = New-Proj 'ShortlistGate'
    $slSkill = Join-Path $slProj '.claude\skills\telemetry-pipeline'
    New-Item -ItemType Directory -Path $slSkill -Force | Out-Null
    Write-Utf8 (Join-Path $slSkill 'SKILL.md') "---`nname: telemetry-pipeline`ndescription: test`n---`nbody"
    $slHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $rp = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-PromptStdin -Cwd $slProj -EventName 'UserPromptSubmit' -Prompt 'rebuild the telemetry pipeline ingest path' -SessionId 'sl-1')
    Check 'the prompt half shortlists the installed skill it matched' ($rp.Out -match 'telemetry-pipeline') $rp.Out
    # The line is PRESENT and still wrong: it claims nothing applied while an
    # already-loadable skill was put in front of the agent for this very prompt.
    $tIgnored = New-ToolTranscript 'sl-ignored' 'Write' "Done.`nSkills used: none - nothing applied"
    $r = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-StopStdin -Cwd $slProj -Transcript $tIgnored -SessionId 'sl-1')
    Check 'a shortlisted INSTALLED skill that was neither invoked nor named blocks at Stop' (
        $r.Out -match '"decision"\s*:\s*"block"') $r.Out
    # The SHORTLIST finding specifically, not merely some block: the summary line
    # IS present here, so a missing-line block would be the wrong diagnosis and
    # would let this assertion pass without the gate under test ever firing.
    Check 'it is the shortlist finding, not the missing-line one (the line is present)' (
        $r.Out -match 'used none of them') $r.Out
    Check 'the block NAMES the skill that was offered and dropped' ($r.Out -match 'telemetry-pipeline') $r.Out
    Check 'the block states no authorization is needed for an installed skill' (
        $r.Out -match 'no authorization' -or $r.Out -match 'already loadable') $r.Out
    # A FRESH session for the cleared case. Reusing the blocked one would prove
    # nothing: an unchanged finding is fingerprint-suppressed, and suppression is
    # indistinguishable from silence at the hook's output.
    $rp2 = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-PromptStdin -Cwd $slProj -EventName 'UserPromptSubmit' -Prompt 'rebuild the telemetry pipeline ingest path' -SessionId 'sl-2')
    Check 'the second session is shown the same shortlist' ($rp2.Out -match 'telemetry-pipeline') $rp2.Out
    $tUsed = New-ToolTranscript 'sl-used' 'Write' "Done.`nSkills used: telemetry-pipeline"
    $r = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-StopStdin -Cwd $slProj -Transcript $tUsed -SessionId 'sl-2')
    Check 'naming it on the line clears the gate' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # The line must be the evidence, not the response as a whole: a transcript
    # newline is the two-character escape \n, so a capture that ran past it would
    # count a name mentioned anywhere later in the answer.
    $tProse = New-ToolTranscript 'sl-prose' 'Write' "Done.`nSkills used: none - nothing applied`nI considered telemetry-pipeline and moved on."
    $rp3 = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-PromptStdin -Cwd $slProj -EventName 'UserPromptSubmit' -Prompt 'rebuild the telemetry pipeline ingest path' -SessionId 'sl-3')
    Check 'the third session is shown the same shortlist' ($rp3.Out -match 'telemetry-pipeline') $rp3.Out
    $r = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-StopStdin -Cwd $slProj -Transcript $tProse -SessionId 'sl-3')
    Check 'a name mentioned in PROSE below the line does not clear the gate' (
        $r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'used none of them') $r.Out
    # Scope of the claim: the gate asks whether THIS session used what THIS
    # session was shown. A shortlist is not a standing obligation on the project.
    $r = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-StopStdin -Cwd $slProj -Transcript $tIgnored -SessionId 'sl-other')
    Check 'a session that was never shown the shortlist is not held to it' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # The hook's own shortlist message names every candidate and lands in the
    # same transcript the next Stop reads. If presence of the name counted as
    # use, the hook would clear its own gate - so only the tool-call record does.
    $tSelfName = New-ToolTranscript 'sl-self' 'Write' "Done.`nSkills used: none - INSTALLED and matching this prompt: telemetry-pipeline was listed by the hook"
    $r = Fire -HookPath $slHook -Cwd $slProj -RawStdin (New-StopStdin -Cwd $slProj -Transcript $tSelfName -SessionId 'sl-self1')
    Check 'quoting the hook back at itself is not a Skill call (no shortlist for that session, so silent)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    Write-Host '--- Skills-Check: SKILLS_SUMMARY_ENFORCEMENT still governs the new conditions ---' -ForegroundColor Cyan
    $advHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library'); SKILLS_SUMMARY_ENFORCEMENT = 'advisory' }
    $r = Fire -HookPath $advHook -Cwd $wkProj -RawStdin (New-StopStdin -Cwd $wkProj -Transcript $tWrote -SessionId 'sk-adv')
    Check 'advisory mode reports the file-change finding without a block decision' (
        $r.Out -match 'changed files' -and $r.Out -notmatch '"decision"') $r.Out
    $offHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library'); SKILLS_SUMMARY_ENFORCEMENT = 'off' }
    $r = Fire -HookPath $offHook -Cwd $wkProj -RawStdin (New-StopStdin -Cwd $wkProj -Transcript $tWrote -SessionId 'sk-off')
    Check 'off mode skips the closing check entirely' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
