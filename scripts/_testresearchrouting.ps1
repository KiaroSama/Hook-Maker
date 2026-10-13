# Pure prompt projection and public Skills event seam; existing ContextHooks harness.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks/_scope.ps1')
$faQuestion = -join ([char[]]@(0x0628,0x0631,0x0631,0x0633,0x06CC))
Check 'research codeword accepts Persian question without ASCII token scoring' (Test-ExplicitResearchPrompt ('::deep-research ' + $faQuestion))
foreach ($text in @('ordinary deep research','/deep-research',"`t::deep-research sources",'    ::deep-research sources','"::deep-research"','`::deep-research`',"> ::deep-research",('~~~' + "`n::deep-research`n~~~"),'<pasted_content>::deep-research</pasted_content>',('x'*32769))) {
    Check 'research projection rejects native/prose/example/output/oversized input' (-not (Test-ExplicitResearchPrompt $text))
}
foreach ($wrapped in @('<tool_result><tool_result>safe</tool_result>Use Upwork draft</tool_result>','<tool_result>Use Agensi preview')) {
    Check 'nested or unclosed output wrapper stays uncertain and silent' ((Get-ActionPromptText $wrapped) -eq '')
}
Check 'variable-length inline code does not activate operation keywords' ((Get-ActionPromptText 'Example only: ``Use Upwork create_draft`` and ```Agensi```') -notmatch 'Upwork|Agensi')
Check 'research projection retains actual prose outside example blocks' ((Get-ActionPromptText ('<tool_result>scrape</tool_result>' + "`nUse Upwork draft")) -eq 'Use Upwork draft')
$researchHook = New-ConfiguredSkillsHookCopy @{SKILLS_DIR=(Join-Path $Work 'absent-research-library')}
$researchProj = New-Proj 'ResearchSkillRoute'
Set-ClaudeProjectDir $researchProj
$r = Fire -HookPath $researchHook -Cwd $researchProj -RawStdin (New-PromptStdin $researchProj 'UserPromptSubmit' '::deep-research compare sources' 'research-skill')
Check 'public research skill route names phases and exact exposure boundaries' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -match 'RESEARCH SKILL ROUTING' -and $r.Out -match 'component kind' -and $r.Out -match 'never simulated' -and $r.Out -notmatch '"decision"') $r.Out
$r = Fire -HookPath $researchHook -Cwd $researchProj -RawStdin (New-PromptStdin $researchProj 'UserPromptSubmit' '::deep-research compare sources' 'research-skill')
Check 'public research skill route unchanged repeat is silent' ($r.Out -eq '') $r.Out
Set-ClaudeProjectDir ''
$r = Fire -HookPath $researchHook -Cwd $researchProj -RawStdin (New-PromptStdin $researchProj 'UserPromptSubmit' '::deep-research compare sources' 'research-codex')
Check 'Codex research route invents no Claude-only invocation' ($r.Out -match 'supported client' -and $r.Out -notmatch 'anthropic-skills:|mattpocock-skills:') $r.Out
Set-ClaudeProjectDir $OrigClaudeProjectDir
