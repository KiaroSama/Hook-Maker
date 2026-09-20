# Test-ContextHooks section: the Skills-Check UserPromptSubmit SHORTLIST matcher.
#
# Its own file because _testcontextskills.ps1 sits at the size ceiling, and
# because this is one question: given a prompt, which skills does the hook
# offer? Dot-sourced by Test-ContextHooks.ps1 into the caller's scope (uses its
# harness: $Work, Fire, Check, New-Proj, New-PromptStdin, New-ConfiguredSkillsHookCopy).
#
# Two defects motivated it, both reported from a TypeScript repository that was
# offered Figma and machine-learning skills for roughly forty turns:
#   1. the hook's own 'Skills used:' line, quoted back in a later prompt, fed
#      its own matcher - so the names it had just demanded were demanded again;
#   2. one incidental English token qualified a skill outright, and a low-score
#      tie was then settled alphabetically.

    # =====================================================================
    Write-Host '--- Skills-Check: the prompt shortlist does not feed itself ---' -ForegroundColor Cyan
    Set-ClaudeProjectDir $Work
    $spProj = New-Proj 'SkillsPromptMatch'
    # Three project skills chosen for what their NAMES are made of: one built
    # from ordinary English ('create', 'file'), one single distinctive word, and
    # one two-word tool name. The library and global sources are pointed at an
    # absent path so this is deterministic whatever the host has installed.
    foreach ($skill in @('figma-create-new-file', 'codeql', 'powershell-windows')) {
        New-Item -ItemType Directory -Path (Join-Path $spProj ('.claude\skills\' + $skill)) -Force | Out-Null
    }
    $spHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    function Invoke-Prompt {
        param([string]$Text, [string]$SessionId)
        return (Fire -HookPath $spHook -Cwd $spProj -RawStdin (New-PromptStdin -Cwd $spProj -EventName 'UserPromptSubmit' -Prompt $Text -SessionId $SessionId))
    }

    # The guard first: tightening must not cost a genuine match. A single-word
    # skill name scores only 2 on a perfect hit, which is why a raised score
    # floor was rejected in favour of judging the WORDS.
    $spGood = Invoke-Prompt -Text 'run codeql on this repo' -SessionId 'sp-codeql'
    Check 'a prompt that names a skill''s subject still offers it' (
        $spGood.Out -match 'codeql') $spGood.Out
    $spGood2 = Invoke-Prompt -Text 'write a powershell windows hook for this' -SessionId 'sp-pwsh'
    Check 'a two-word tool name is still offered' (
        $spGood2.Out -match 'powershell-windows') $spGood2.Out

    # Defect 2: ordinary English that happens to be a skill's own words.
    $spGeneric = Invoke-Prompt -Text 'create a new file and generate the report' -SessionId 'sp-generic'
    Check 'ordinary English words do not qualify a skill' (
        $spGeneric.Out -notmatch 'figma-create-new-file') $spGeneric.Out

    # Defect 1: the accountability line the hook itself demands, quoted back.
    # Before the repair the quoted names scored highest and were re-offered.
    $spEcho = Invoke-Prompt -Text 'Skills used: none - figma-create-new-file, codeql do not apply' -SessionId 'sp-echo'
    Check 'a quoted "Skills used:" line offers nothing back' (
        $spEcho.Out -notmatch 'figma-create-new-file' -and $spEcho.Out -notmatch 'codeql') $spEcho.Out

    # The same, with a non-Latin prompt around it - the total case. The token
    # split keeps only [a-z0-9], so without the strip the quoted English names
    # are the ONLY tokens in the entire prompt and the loop can never end.
    $spFarsi = [string]::Join('', [char[]]@(0x0627, 0x06CC, 0x0646, 0x0631, 0x0627, 0x0020, 0x062F, 0x0631, 0x0633, 0x062A, 0x0020, 0x06A9, 0x0646))
    $spMixed = Invoke-Prompt -Text ($spFarsi + [char]10 + 'Skills used: none - figma-create-new-file, codeql do not apply') -SessionId 'sp-mixed'
    Check 'a non-Latin prompt quoting that line offers nothing either' (
        $spMixed.Out -notmatch 'figma-create-new-file' -and $spMixed.Out -notmatch 'codeql') $spMixed.Out

    # And the line is stripped, not the whole prompt: real subject matter that
    # sits beside a quoted accountability line must still be matched.
    $spBoth = Invoke-Prompt -Text ('Skills used: none - figma-create-new-file do not apply' + [char]10 + 'now run codeql') -SessionId 'sp-both'
    Check 'only the accountability line is removed, not the rest of the prompt' (
        $spBoth.Out -match 'codeql' -and $spBoth.Out -notmatch 'figma-create-new-file') $spBoth.Out
