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
    foreach ($skill in @('sample-create-new-file', 'codeql', 'powershell-windows')) {
        New-Item -ItemType Directory -Path (Join-Path $spProj ('.claude\skills\' + $skill)) -Force | Out-Null
    }
    $spHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    function Invoke-Prompt {
        param([string]$Text, [string]$SessionId)
        return (Fire -HookPath $spHook -Cwd $spProj -RawStdin (New-PromptStdin -Cwd $spProj -EventName 'UserPromptSubmit' -Prompt $Text -SessionId $SessionId))
    }

    # 'codeql' is matched as a SHORTLIST ENTRY ('- codeql [source]'), not as a bare word: the
    # fixed security-routing line every advisory now carries names codeql as a scanner, so a
    # bare-word check would pass for the wrong reason and a bare -notmatch could never pass.
    $spCodeqlOffered = '- codeql \['
    # The guard first: tightening must not cost a genuine match. A single-word
    # skill name scores only 2 on a perfect hit, which is why a raised score
    # floor was rejected in favour of judging the WORDS.
    $spGood = Invoke-Prompt -Text 'run codeql on this repo' -SessionId 'sp-codeql'
    Check 'a prompt that names a skill''s subject still offers it' (
        $spGood.Out -match $spCodeqlOffered) $spGood.Out
    $spGood2 = Invoke-Prompt -Text 'write a powershell windows hook for this' -SessionId 'sp-pwsh'
    Check 'a two-word tool name is still offered' (
        $spGood2.Out -match 'powershell-windows') $spGood2.Out

    # Defect 2: ordinary English that happens to be a skill's own words.
    $spGeneric = Invoke-Prompt -Text 'create a new file and generate the report' -SessionId 'sp-generic'
    Check 'ordinary English words do not qualify a skill' (
        $spGeneric.Out -notmatch 'sample-create-new-file') $spGeneric.Out

    # Defect 1: the accountability line the hook itself demands, quoted back.
    # Before the repair the quoted names scored highest and were re-offered.
    $spEcho = Invoke-Prompt -Text 'Skills used: none - sample-create-new-file, codeql do not apply' -SessionId 'sp-echo'
    Check 'a quoted "Skills used:" line offers nothing back' (
        $spEcho.Out -notmatch 'sample-create-new-file' -and $spEcho.Out -notmatch $spCodeqlOffered) $spEcho.Out

    # The same, with a non-Latin prompt around it - the total case. The token
    # split keeps only [a-z0-9], so without the strip the quoted English names
    # are the ONLY tokens in the entire prompt and the loop can never end.
    $spFarsi = [string]::Join('', [char[]]@(0x0627, 0x06CC, 0x0646, 0x0631, 0x0627, 0x0020, 0x062F, 0x0631, 0x0633, 0x062A, 0x0020, 0x06A9, 0x0646))
    $spMixed = Invoke-Prompt -Text ($spFarsi + [char]10 + 'Skills used: none - sample-create-new-file, codeql do not apply') -SessionId 'sp-mixed'
    Check 'a non-Latin prompt quoting that line offers nothing either' (
        $spMixed.Out -notmatch 'sample-create-new-file' -and $spMixed.Out -notmatch $spCodeqlOffered) $spMixed.Out

    # And the line is stripped, not the whole prompt: real subject matter that
    # sits beside a quoted accountability line must still be matched.
    $spBoth = Invoke-Prompt -Text ('Skills used: none - sample-create-new-file do not apply' + [char]10 + 'now run codeql') -SessionId 'sp-both'
    Check 'only the accountability line is removed, not the rest of the prompt' (
        $spBoth.Out -match $spCodeqlOffered -and $spBoth.Out -notmatch 'sample-create-new-file') $spBoth.Out

    # =====================================================================
    Write-Host '--- Skills-Check V103: new/updated plugin skills match prompts ---' -ForegroundColor Cyan
    $v103Cache = New-PluginCache 'v103-plugin-cache' @{
        'revayat-scientific' = @('revayat-scientific')
        'revayat-subtitle'   = @('revayat-subtitle-sync')
        'telegram-operator'  = @('bot-clone')
    }
    $v103Reg = Join-Path $Work 'v103-installed.json'
    Write-Utf8 $v103Reg (@{
        plugins = @{
            'revayat-scientific@revayat-scientific-skill' = @(@{ scope = 'user'; installPath = (Join-Path $v103Cache 'market/revayat-scientific/1.0.0'); version = '2.2.3' })
            'revayat-subtitle@revayat-subtitle-skill'     = @(@{ scope = 'user'; installPath = (Join-Path $v103Cache 'market/revayat-subtitle/1.0.0'); version = '3.0.3' })
            'telegram-operator@telegram-operator'         = @(@{ scope = 'user'; installPath = (Join-Path $v103Cache 'market/telegram-operator/1.0.0'); version = '1.6.0' })
        }
    } | ConvertTo-Json -Depth 6)
    $v103Hook = New-ConfiguredSkillsHookCopy -EnvOverrides @{
        SKILLS_DIR = (Join-Path $Work 'no-such-library')
        GLOBAL_SKILLS_DIR = (Join-Path $Work 'no-such-global')
        PLUGIN_SKILLS_ROOT = $v103Cache
        CLAUDE_PLUGINS_FILE = $v103Reg
    }
    $v103Proj = New-Proj 'SkillsV103'
    foreach ($case in @(
        @{ Id = 'sci'; Prompt = 'use revayat scientific to translate this paper'; Want = 'revayat-scientific:revayat-scientific' },
        @{ Id = 'sub'; Prompt = 'run revayat subtitle sync on this episode'; Want = 'revayat-subtitle:revayat-subtitle-sync' },
        @{ Id = 'bot'; Prompt = 'use bot-clone to clone the telegram bot'; Want = 'telegram-operator:bot-clone' }
    )) {
        $rV103 = Fire -HookPath $v103Hook -Cwd $v103Proj -RawStdin (New-PromptStdin -Cwd $v103Proj -EventName 'UserPromptSubmit' -Prompt $case.Prompt -SessionId ('v103-' + $case.Id))
        Check ('V103 prompt offers ' + $case.Want) ($rV103.Out -match [regex]::Escape($case.Want)) $rV103.Out
    }

    # =====================================================================
    Write-Host '--- Skills-Check V95: rust-anything vs translate-programming-language & .disabled-by-policy ---' -ForegroundColor Cyan
    $v95Cache = New-PluginCache 'v95-plugin-cache' @{
        'rust-anything'    = @('rust-anything')
        'anthropic-skills' = @('translate-programming-language')
        'ecc'              = @('terminal-ops')
    }
    $eccVerRoot = Join-Path $v95Cache 'market/ecc/1.0.0'
    foreach ($disabledRel in @('.disabled-by-policy/skills/ecc-blocked-alpha', 'skills/.disabled-by-policy/ecc-blocked-beta')) {
        $dPath = Join-Path $eccVerRoot $disabledRel
        New-Item -ItemType Directory -Path $dPath -Force | Out-Null
        Write-Utf8 (Join-Path $dPath 'SKILL.md') "---`nname: ecc-blocked-alpha`ndescription: blocked ecc skill`n---`nbody"
    }
    $v95Reg = Join-Path $Work 'v95-installed.json'
    Write-Utf8 $v95Reg (@{
        plugins = @{
            'rust-anything@rust-anything' = @(@{ scope = 'user'; installPath = (Join-Path $v95Cache 'market/rust-anything/1.0.0'); version = '2.1.0' })
            'anthropic-skills@desktop'    = @(@{ scope = 'user'; installPath = (Join-Path $v95Cache 'market/anthropic-skills/1.0.0'); version = '1.0.0' })
            'ecc@ecc'                     = @(@{ scope = 'user'; installPath = $eccVerRoot; version = '2.2.3' })
        }
    } | ConvertTo-Json -Depth 6)
    $v95Hook = New-ConfiguredSkillsHookCopy -EnvOverrides @{
        SKILLS_DIR = (Join-Path $Work 'no-such-library')
        GLOBAL_SKILLS_DIR = (Join-Path $Work 'no-such-global')
        PLUGIN_SKILLS_ROOT = $v95Cache
        CLAUDE_PLUGINS_FILE = $v95Reg
    }
    $v95Proj = New-Proj 'SkillsV95Port'
    $rRustPort = Fire -HookPath $v95Hook -Cwd $v95Proj -RawStdin (New-PromptStdin -Cwd $v95Proj -EventName 'UserPromptSubmit' -Prompt 'translate src/parser.py to Rust' -SessionId 'v95-rust-en')
    Check 'V95 1b: Rust-target port offers rust-anything:rust-anything and excludes translate-programming-language' (
        $rRustPort.Out -match 'rust-anything:rust-anything' -and $rRustPort.Out -notmatch 'translate-programming-language') $rRustPort.Out
    $faBaznevisi = (-join [char[]]@(0x0628,0x0627,0x0632,0x0646,0x0648,0x06CC,0x0633,0x06CC)) + ' ' + (-join [char[]]@(0x0628,0x0647)) + ' ' + (-join [char[]]@(0x0631,0x0627,0x0633,0x062A))
    $rRustFa = Fire -HookPath $v95Hook -Cwd $v95Proj -RawStdin (New-PromptStdin -Cwd $v95Proj -EventName 'UserPromptSubmit' -Prompt $faBaznevisi -SessionId 'v95-rust-fa')
    Check 'V95 1b: Persian Rust-target port offers rust-anything:rust-anything' (
        $rRustFa.Out -match 'rust-anything:rust-anything' -and $rRustFa.Out -notmatch 'translate-programming-language') $rRustFa.Out
    $rGoPort = Fire -HookPath $v95Hook -Cwd $v95Proj -RawStdin (New-PromptStdin -Cwd $v95Proj -EventName 'UserPromptSubmit' -Prompt 'port src/parser.py to Go' -SessionId 'v95-go')
    Check 'V95 1b: non-Rust-target port offers translate-programming-language and excludes rust-anything' (
        $rGoPort.Out -match 'anthropic-skills:translate-programming-language' -and $rGoPort.Out -notmatch 'rust-anything:rust-anything') $rGoPort.Out
    $rDisabled = Fire -HookPath $v95Hook -Cwd $v95Proj -RawStdin (New-PromptStdin -Cwd $v95Proj -EventName 'UserPromptSubmit' -Prompt 'run ecc-blocked-alpha and ecc-blocked-beta' -SessionId 'v95-disabled')
    Check 'V95 Step 2: skills inside .disabled-by-policy are excluded from discovery and shortlist' (
        $rDisabled.Out -notmatch 'ecc-blocked-alpha' -and $rDisabled.Out -notmatch 'ecc-blocked-beta') $rDisabled.Out
    $tRaSkillStop = Join-Path $Work 'v95-ra-skill.jsonl'
    Write-Utf8 $tRaSkillStop ((@(
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = 'Skill'; input = @{ skill = 'rust-anything:rust-anything' } }) } } | ConvertTo-Json -Compress -Depth 8),
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "Done.`nSkills used: rust-anything:rust-anything" }) } } | ConvertTo-Json -Compress -Depth 8)
    ) -join "`n") + "`n")
    $rRaStop = Fire -HookPath $v95Hook -Cwd $v95Proj -RawStdin (New-StopStdin -Cwd $v95Proj -Transcript $tRaSkillStop -SessionId 'v95-rust-en')
    Check 'V95 1b: Skill(skill="rust-anything:rust-anything") satisfies Stop in Claude' ($rRaStop.Out -notmatch '"decision"') $rRaStop.Out
    $tRaCodexRead = Join-Path $Work 'v95-ra-codex-read.jsonl'
    Write-Utf8 $tRaCodexRead ((@(
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = 'Read'; input = @{ file_path = 'C:\Users\dev\.claude\plugins\cache\rust-anything\rust-anything\2.1.0\skills\rust-anything\SKILL.md' } }) } } | ConvertTo-Json -Compress -Depth 8),
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "Done.`nSkills used: rust-anything" }) } } | ConvertTo-Json -Compress -Depth 8)
    ) -join "`n") + "`n")
    $prevClient = $env:HOOKMAKER_CLIENT
    try {
        $env:HOOKMAKER_CLIENT = 'codex'
        Set-ClaudeProjectDir $null
        $null = Fire -HookPath $v95Hook -Cwd $v95Proj -RawStdin (New-PromptStdin -Cwd $v95Proj -EventName 'UserPromptSubmit' -Prompt 'port src/parser.py to Rust' -SessionId 'v95-rust-codex')
        $rRaCodexStop = Fire -HookPath $v95Hook -Cwd $v95Proj -RawStdin (New-StopStdin -Cwd $v95Proj -Transcript $tRaCodexRead -SessionId 'v95-rust-codex')
        Check 'V95 1b: by-path Read of skills/rust-anything/SKILL.md satisfies Stop on non-Claude clients' ($rRaCodexStop.Out -notmatch '"decision"') $rRaCodexStop.Out
    }
    finally {
        if ($null -eq $prevClient) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue } else { $env:HOOKMAKER_CLIENT = $prevClient }
        Set-ClaudeProjectDir $Work
    }
