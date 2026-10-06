# Test-ContextHooks section: Skills-Check per-skill discovery, catalogue drift,
# the fixed routing lines and the intake-aware Spec Kit line (order 55, steps
# 3/4/7).
#
# Fixtures only: every home, install record, manifest, Desktop root, Codex
# home and rules directory is built under $Work, so no count here depends on
# what the machine running the suite has installed. Dot-sourced by
# Test-ContextHooks.ps1 into its scope (uses $Work, Fire, Check, New-Proj,
# Write-Utf8, New-PromptStdin, New-ConfiguredSkillsHookCopy, Set-ClaudeProjectDir,
# Get-Context from _testcontextskills.ps1).

function Invoke-SkillSurfaceRegression {
    param([string]$Root)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skillindex.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skilldiscovery.ps1')
    $savedApp=$env:APPDATA; $savedLocal=$env:LOCALAPPDATA
    $homeDir=Join-Path $Work 'surface-home'; $cwd=$Work; $client='claude'; $config=@{}
    try {
        $env:APPDATA=Join-Path $Work 'surface-roaming'; $env:LOCALAPPDATA=Join-Path $Work 'surface-local'
        $newRoot=Join-Path $env:LOCALAPPDATA 'Claude-3p/local-agent-mode-sessions/skills-plugin'
        $folder=Join-Path $newRoot 'owner/session/skills/translate-programming-language'
        [void][IO.Directory]::CreateDirectory($folder)
        Write-Utf8 (Join-Path $folder 'SKILL.md') "---`nname: translate-programming-language`ndescription: fixture language port`n---`nbody"
        Write-Utf8 (Join-Path $newRoot 'owner/session/manifest.json') '{"skills":[{"name":"translate-programming-language","enabled":true}]}'
        $discovery=New-SkillDiscoveryConfig
        $answer=Invoke-SkillDiscovery $discovery
        Check 'current Local Desktop manual definition is discovered' (@($answer.Skills | Where-Object {$_.Invocation -eq 'anthropic-skills:translate-programming-language'}).Count -eq 1)
        $plugin=Join-Path $Work 'surface-plugin';[void][IO.Directory]::CreateDirectory((Join-Path $plugin '.claude-plugin'))
        [void][IO.Directory]::CreateDirectory((Join-Path $plugin 'skills/published'))
        Write-Utf8 (Join-Path $plugin 'skills/published/SKILL.md') "---`nname: published`ndescription: fixture`n---`nbody"
        Write-Utf8 (Join-Path $plugin '.claude-plugin/plugin.json') '{"name":"actual-namespace"}'
        $pluginsFile=Join-Path $Work 'surface-installed.json'
        Write-Utf8 $pluginsFile (@{plugins=@{'legacy-alias@market'=@(@{scope='user';installPath=$plugin;version='1';lastUpdated='2026-10-06T00:00:00Z'})}} | ConvertTo-Json -Depth 6)
        $discovery.PluginsFile=$pluginsFile
        $answer=Invoke-SkillDiscovery $discovery
        Check 'manifest namespace is not replaced by registration alias' (@($answer.Skills |Where-Object {$_.Invocation -eq 'actual-namespace:published'}).Count -eq 1 -and @($answer.Skills |Where-Object {$_.Invocation -eq 'legacy-alias:published'}).Count -eq 0)
        $stamp = Get-SkillSourceStamp $discovery
        Write-Utf8 (Join-Path $newRoot 'owner/session/manifest.json') '{"skills":[{"name":"translate-programming-language","enabled":false}]}'
        $answer = Invoke-SkillDiscovery $discovery
        Check 'nested Desktop toggle invalidates source stamp and disables definition' ((Get-SkillSourceStamp $discovery) -ne $stamp -and @($answer.Skills | Where-Object {$_.Source -eq 'claude-desktop' -and $_.Status -eq 'disabled'}).Count -eq 1)
        $legacy = Join-Path $env:APPDATA 'Claude/local-agent-mode-sessions/skills-plugin/owner/old'
        [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'skills/translate-programming-language'))
        Copy-Item -LiteralPath (Join-Path $folder 'SKILL.md') -Destination (Join-Path $legacy 'skills/translate-programming-language/SKILL.md')
        Write-Utf8 (Join-Path $legacy 'manifest.json') '{"skills":[{"name":"translate-programming-language","enabled":false}]}'
        $answer = Invoke-SkillDiscovery $discovery
        Check 'identical Desktop definitions across supported roots appear once' (@($answer.Skills | Where-Object {$_.Source -eq 'claude-desktop'}).Count -eq 1)
        $config = @{CLAUDE_DESKTOP_SKILLS_ROOT=(Join-Path $Work 'explicit-desktop')}
        $answer = Invoke-SkillDiscovery (New-SkillDiscoveryConfig)
        Check 'explicit Desktop override excludes default surfaces' (@($answer.Skills | Where-Object {$_.Source -eq 'claude-desktop'}).Count -eq 0)
        $config = @{}
        $answer = Invoke-SkillDiscovery $discovery
        $bad = Join-Path $newRoot 'bad/session'
        [void][IO.Directory]::CreateDirectory((Join-Path $bad 'skills/example'))
        Write-Utf8 (Join-Path $bad 'skills/example/SKILL.md') "---`nname: example`n---`nbody"
        Write-Utf8 (Join-Path $bad 'manifest.json') '{broken'
        $answer = Invoke-SkillDiscovery $discovery
        Check 'malformed Desktop manifest is partial and never loadable' ($answer.Partial.Count -gt 0 -and @($answer.Skills | Where-Object {$_.Name -eq 'example'}).Count -eq 0)

        # Published bundle shape: 21 root children, 19 internal definitions,
        # one ten-child alias and one full alias. No source repository crawl.
        for ($i=1; $i -le 21; $i++) {
            $child = Join-Path $plugin ('skills/child-' + $i)
            [void][IO.Directory]::CreateDirectory($child)
            Write-Utf8 (Join-Path $child 'SKILL.md') ("---`nname: child-"+$i+"`ndescription: fixture`n---`nbody")
        }
        Remove-Item -LiteralPath (Join-Path $plugin 'skills/published') -Recurse
        for ($i=1; $i -le 19; $i++) {
            $child = Join-Path $plugin ('.agents/skills/internal-' + $i)
            [void][IO.Directory]::CreateDirectory($child)
            Write-Utf8 (Join-Path $child 'SKILL.md') ("---`nname: internal-"+$i+"`n---`nbody")
        }
        Write-Utf8 (Join-Path $plugin '.claude-plugin/plugin.json') '{"name":"hyperframes"}'
        $selected = @(1..10 | ForEach-Object {'./skills/child-' + $_})
        Write-Utf8 (Join-Path $plugin '.claude-plugin/marketplace.json') (@{name='market';plugins=@(@{name='core-skills';source='./';skills=$selected},@{name='hyperframes';source='./'})} | ConvertTo-Json -Depth 5)
        $records = @{plugins=@{'core-skills@market'=@(@{scope='user';installPath=$plugin;version='1'});'hyperframes@market'=@(@{scope='user';installPath=$plugin;version='1'})}}
        Write-Utf8 $pluginsFile ($records | ConvertTo-Json -Depth 6)
        $answer = Invoke-SkillDiscovery $discovery
        $published = @($answer.Skills | Where-Object {$_.Source -eq 'claude-plugin'})
        Check 'aliases coalesce into exactly 21 published manifest invocations' ($published.Count -eq 21 -and @($published | Where-Object {$_.Invocation -like 'hyperframes:child-*'}).Count -eq 21 -and @($published | Where-Object {$_.Invocation -like 'core-skills:*' -or $_.Name -like 'internal-*'}).Count -eq 0)
        Check 'coalesced alias retains installation identity separately' (@($published | Where-Object {$_.Name -eq 'child-1' -and $_.InstallationKey -match 'core-skills@market' -and $_.InstallationKey -match 'hyperframes@market'}).Count -eq 1)
        $records.plugins.Remove('hyperframes@market')
        Write-Utf8 $pluginsFile ($records | ConvertTo-Json -Depth 6)
        $answer = Invoke-SkillDiscovery $discovery
        Check 'legacy declaration alone exposes only ten children' (@($answer.Skills | Where-Object {$_.Source -eq 'claude-plugin'}).Count -eq 10)
        Write-Utf8 (Join-Path $plugin '.claude-plugin/plugin.json') '{"name":"invalid:namespace"}'
        $answer = Invoke-SkillDiscovery $discovery
        Check 'invalid namespace remains unknown without guessed invocation' (@($answer.Skills | Where-Object {$_.Source -eq 'claude-plugin' -and ($_.Status -ne 'unknown' -or $_.Invocation -ne '')}).Count -eq 0 -and $answer.Partial.Count -gt 0)
        Write-Utf8 (Join-Path $newRoot 'owner/session/manifest.json') '{broken'
        Write-Utf8 (Join-Path $legacy 'manifest.json') '{"skills":[{"name":"translate-programming-language","enabled":true}]}'
        (Get-Item (Join-Path $newRoot 'owner/session/manifest.json')).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(1)
        $answer=Invoke-SkillDiscovery $discovery
        Check 'malformed newest Desktop cannot resurrect older enabled copy' (@($answer.Skills | Where-Object {$_.Source -eq 'claude-desktop' -and $_.Status -eq 'enabled'}).Count -eq 0)
        Write-Utf8 (Join-Path $newRoot 'owner/session/manifest.json') '{"skills":[{"name":"translate-programming-language","source":"manual-fixture","skillId":"id1","enabled":true}]}'
        Write-Utf8 (Join-Path $folder 'SKILL.md') "---`nname: translate-programming-language`n---`n[reference](references/missing.md)"
        $answer=Invoke-SkillDiscovery $discovery
        Check 'missing Desktop reference stays partial and unavailable to shortlist' (@($answer.Skills | Where-Object {$_.Source -eq 'claude-desktop' -and $_.ReferenceState -eq 'incomplete' -and $_.Status -eq 'unknown'}).Count -eq 1)
        $codex=Join-Path $Work 'surface-codex';[void][IO.Directory]::CreateDirectory((Join-Path $codex 'plugins/cache/mk/cplug/1/skills/child'))
        Write-Utf8 (Join-Path $codex 'plugins/cache/mk/cplug/1/skills/child/SKILL.md') "---`nname: codex-child`n---`nbody"
        Write-Utf8 (Join-Path $codex 'config.toml') "[plugins.`"cplug@mk`"]`nenabled = true"
        $discovery.Client='codex';$discovery.CodexHome=$codex;$discovery.CodexConfig=Join-Path $codex 'config.toml';$discovery.CodexSharedDir=''
        $answer=Invoke-SkillDiscovery $discovery
        Check 'Codex keeps actual installation key and bare invocation' (@($answer.Skills | Where-Object {$_.InstallationKey -eq 'cplug@mk' -and $_.Invocation -eq 'codex-child'}).Count -eq 1)
    }
    finally {$env:APPDATA=$savedApp; $env:LOCALAPPDATA=$savedLocal}
}

    Invoke-SkillSurfaceRegression (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot '_testskillproviders.ps1')
    Invoke-SkillProviderRegression (Split-Path -Parent $PSScriptRoot)
    $sdSavedClaudeDir = $env:CLAUDE_PROJECT_DIR
    # The two order-55 step-4a lines, copied from the ORDER, not from the hook:
    # the assertion must fail if the hook's wording drifts from what was asked.
    $sdRoutingA = '- Every visible skill has its own routing line in global-skill-routing.md; user-level, Desktop and Kiaro template skills are in global-skills-catalogue.md. Route by that line, not by the plugin name; where two skills share a job, the line names the default. global-skill-routing.md loads on demand, so read it in full before this work.'
    $sdRoutingB = '- Security work enters at the security-audit skill, never at a scanner. semgrep, codeql, SARIF, insecure-defaults and differential-review are evidence that workflow calls for. It runs in guidance mode by default and in full audit mode only on an explicit audit, pen-test, end-to-end review, or a request for report artifacts.'

    function New-SdSkill {
        param([string]$Dir, [string]$Name, [string]$Extra = '')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Write-Utf8 (Join-Path $Dir 'SKILL.md') ("---`nname: " + $Name + "`ndescription: fixture skill " + $Name + "`n" + $Extra + "---`nbody")
    }

    # ---- Claude fixture home ------------------------------------------------
    $sdClaude = Join-Path $Work 'sd-claude'
    $sdCache = Join-Path $sdClaude 'cache'
    $sdAlpha = Join-Path $sdCache 'alpha'
    New-SdSkill (Join-Path $sdAlpha 'skills\one') 'alpha-one'
    New-SdSkill (Join-Path $sdAlpha 'skills\two') 'alpha-two'
    New-SdSkill (Join-Path $sdAlpha 'skills\three') 'alpha-three' "disable-model-invocation: true`n"
    $sdSolo = Join-Path $sdCache 'solo'
    New-SdSkill $sdSolo 'solo-skill'
    $sdPicked = Join-Path $sdCache 'picked'
    New-SdSkill (Join-Path $sdPicked 'extra\pick-a') 'pick-a'
    New-SdSkill (Join-Path $sdPicked 'extra\pick-b') 'pick-b'
    New-Item -ItemType Directory -Path (Join-Path $sdPicked '.claude-plugin') -Force | Out-Null
    Write-Utf8 (Join-Path $sdPicked '.claude-plugin\plugin.json') (@{ name = 'picked'; skills = @('./extra/pick-a', './extra/pick-b', '../outside') } | ConvertTo-Json)
    $sdDup = Join-Path $sdCache 'dup'
    New-SdSkill (Join-Path $sdDup 'skills\alpha-one') 'alpha-one'
    $sdOff = Join-Path $sdCache 'off'
    New-SdSkill (Join-Path $sdOff 'skills\dormant-widget') 'dormant-widget'
    $sdRecords = [ordered]@{}
    foreach ($pair in @(@('alpha@m', $sdAlpha), @('solo@m', $sdSolo), @('picked@m', $sdPicked), @('dup@m', $sdDup), @('off@m', $sdOff), @('ghost@m', (Join-Path $sdCache 'ghost-missing')))) {
        $sdRecords[$pair[0]] = @(@{ scope = 'user'; installPath = $pair[1]; version = '1.0.0'; lastUpdated = '2026-09-01T00:00:00.000Z' })
    }
    $sdPluginsFile = Join-Path $sdClaude 'installed_plugins.json'
    Write-Utf8 $sdPluginsFile (@{ version = 2; plugins = $sdRecords } | ConvertTo-Json -Depth 6)
    $sdSettings = Join-Path $sdClaude 'settings.json'
    Write-Utf8 $sdSettings (@{ enabledPlugins = @{ 'off@m' = $false; 'alpha@m' = $true } } | ConvertTo-Json)
    $sdDesktop = Join-Path $sdClaude 'desktop'
    $sdDesktopSkills = Join-Path $sdDesktop 'u1\u2\skills'
    New-SdSkill (Join-Path $sdDesktopSkills 'docx') 'docx'
    New-SdSkill (Join-Path $sdDesktopSkills 'pptx') 'pptx'
    Write-Utf8 (Join-Path $sdDesktop 'u1\u2\manifest.json') (@{ skills = @(@{ name = 'docx'; enabled = $true }, @{ name = 'pptx'; enabled = $false }) } | ConvertTo-Json -Depth 4)
    # Deployed-rules fixture: every discovered enabled name is routed EXCEPT
    # pick-b; the plugin catalogue names one plugin the client no longer has.
    $sdRules = Join-Path $sdClaude 'rules'
    New-Item -ItemType Directory -Path (Join-Path $sdRules 'catalogue') -Force | Out-Null
    Write-Utf8 (Join-Path $sdRules 'global-skill-routing.md') "- ``alpha-one`` and ``alpha-two``; ``alpha-three``.`n- ``solo:solo-skill``, ``pick-a``.`n"
    Write-Utf8 (Join-Path $sdRules 'global-skills-catalogue.md') "| Desktop | ``docx``, ``pptx`` |`n"
    Write-Utf8 (Join-Path $sdRules 'catalogue\plugins-001.jsonl') ('{"client":"claude","key":"alpha@m"}' + "`n" + '{"client":"claude","key":"kdense@gone"}' + "`n" + '{"client":"codex","key":"only@codex"}' + "`n")
    $contractRows = @()
    foreach ($item in @(@('alpha@m',$sdAlpha,'one','alpha-one'),@('alpha@m',$sdAlpha,'two','alpha-two'),@('alpha@m',$sdAlpha,'three','alpha-three'),@('dup@m',$sdDup,'alpha-one','alpha-one'),@('solo@m',$sdSolo,'','solo-skill'),@('picked@m',$sdPicked,'../extra/pick-a','pick-a'),@('desktop:u1',(Split-Path -Parent $sdDesktopSkills),'docx','docx'))) {
        $definition = if ($item[0] -eq 'solo@m') {Join-Path $item[1] 'SKILL.md'} elseif ($item[0] -eq 'desktop:u1') {Join-Path $sdDesktopSkills 'docx/SKILL.md'} elseif ($item[0] -eq 'picked@m') {Join-Path $sdPicked 'extra/pick-a/SKILL.md'} else {Join-Path $item[1] ('skills/'+$item[2]+'/SKILL.md')}
        $contractRows += (@{name=$item[3];sources=@(@{client='claude';package=$item[0];path=$definition})} | ConvertTo-Json -Depth 5 -Compress)
    }
    Write-Utf8 (Join-Path $sdRules 'catalogue/skills-001.jsonl') ($contractRows -join "`n")

    $sdClaudeHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{
        SKILLS_DIR = (Join-Path $Work 'no-such-library'); PLUGIN_SKILLS_ROOT = ''
        CLAUDE_PLUGINS_FILE = $sdPluginsFile; CLAUDE_SETTINGS_FILES = $sdSettings
        CLAUDE_DESKTOP_SKILLS_ROOT = $sdDesktop; SKILL_RULES_DIR = $sdRules
    }
    Set-ClaudeProjectDir $Work

    # =====================================================================
    Write-Host '--- Skills-Check: per-skill discovery from Claude install records ---' -ForegroundColor Cyan
    $sdProj = New-Proj 'SkillDiscoveryClaude'
    $r = Fire -HookPath $sdClaudeHook -Cwd $sdProj -RawStdin (New-PromptStdin -Cwd $sdProj -EventName 'SessionStart' -Prompt '' -SessionId 'sd-c1')
    $ctx = Get-Context $r.Out
    Check 'Claude SessionStart uses the shared context shape' ($r.Out -match '"hookSpecificOutput"' -and $r.Out -match '"hookEventName":"SessionStart"') $r.Out
    # alpha 3 (nested + one explicit-only), solo 1 (root SKILL.md), picked 2
    # (declared folders), dup 1, off 1 (disabled plugin), Desktop 2 (one off).
    Check 'every individual skill is counted, not every package' ($ctx -match 'Plugin skills: 10 across 6 plugins') $ctx
    Check 'enabled, disabled and explicit-only stay distinct' ($ctx -match 'Of these: 8 enabled, 2 disabled \(not loadable\), 1 explicit-only') $ctx
    Check 'a declared path outside the plugin and a missing install path make the scan PARTIAL' (
        $ctx -match 'Skill discovery was PARTIAL' -and $ctx -match 'picked@m declares a path outside the plugin' -and $ctx -match 'ghost@m install path missing') $ctx
    Check '4a: the per-skill routing line is present verbatim at SessionStart' ($ctx.Contains($sdRoutingA)) $ctx
    Check '4a: the security-audit entry line is present verbatim at SessionStart' ($ctx.Contains($sdRoutingB)) $ctx
    Check 'uncatalogued detection names exactly the one missing skill' (
        $ctx -match 'UNCATALOGUED SKILLS \(advisory\): picked:pick-b - no current provider/source skill contract' -and $ctx -match 'the rules need an update') $ctx
    Check 'a catalogue plugin missing from the install records is reported as removed' (
        $ctx -match 'REMOVED PLUGINS \(advisory\): kdense@gone - the catalogue names a removed plugin; the rules need an update') $ctx
    Check 'the other client''s catalogue record is never reported' ($ctx -notmatch 'only@codex') $ctx
    Check 'a host-bundled skill is never reported in either direction' ($ctx -notmatch 'code-review' -and $ctx -notmatch 'security-review') $ctx
    Check 'drift is advisory, never a block' ($r.Out -notmatch '"decision"') $r.Out
    $r2 = Fire -HookPath $sdClaudeHook -Cwd $sdProj -RawStdin (New-PromptStdin -Cwd $sdProj -EventName 'SessionStart' -Prompt '' -SessionId 'sd-c1')
    $ctx2 = Get-Context $r2.Out
    Check 'an unchanged drift gap is not reported twice in one session' ($ctx2 -match 'SKILL POLICY CHECK' -and $ctx2 -notmatch 'UNCATALOGUED SKILLS') $ctx2
    Check 'the route line states the mid-task intake contract' (
        $ctx -match 'record the request delta with requirement IDs and acceptance criteria' -and $ctx -match 'spec, plan, tasks and skill selection' -and
        $ctx -match 'rerun the affected gates' -and $ctx -match 'only work that depends on the delta waits' -and $ctx -match 'Spec Kit routes every task') $ctx

    $malformedHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR=(Join-Path $Work 'none'); CLAUDE_PLUGINS_FILE=(Join-Path $Work 'none.json'); CLAUDE_DESKTOP_SKILLS_ROOT=(Join-Path $sdClaude 'bad-desktop') }
    $badSession=Join-Path $sdClaude 'bad-desktop/owner/session'
    New-SdSkill (Join-Path $badSession 'skills/unknown-child') 'unknown-child'
    Write-Utf8 (Join-Path $badSession 'manifest.json') '{broken'
    $badProject=New-Proj 'MalformedDesktop'
    $r=Fire -HookPath $malformedHook -Cwd $badProject -RawStdin (New-PromptStdin -Cwd $badProject -EventName 'UserPromptSubmit' -Prompt 'unknown-child' -SessionId 'sd-bad')
    Check 'empty malformed discovery emits partial at actual prompt without candidate' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -match 'Skill discovery was PARTIAL' -and $r.Out -notmatch 'anthropic-skills:unknown-child') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: the shortlist names exact invocations and skips what cannot run ---' -ForegroundColor Cyan
    $r = Fire -HookPath $sdClaudeHook -Cwd $sdProj -RawStdin (New-PromptStdin -Cwd $sdProj -EventName 'UserPromptSubmit' -Prompt 'alpha dormant solo pick tooling' -SessionId 'sd-c2')
    $ctx = Get-Context $r.Out
    Check 'two nested skills of one plugin are offered separately' ($ctx -match '- alpha:alpha-one \[plugin\]' -and $ctx -match '- alpha:alpha-two \[plugin\]') $ctx
    Check 'identical names from different providers stay distinct' ($ctx -match '- dup:alpha-one \[plugin\]') $ctx
    Check 'a root-SKILL.md plugin is addressed as <plugin>:<name>' ($ctx -match '- solo:solo-skill \[plugin\]') $ctx
    Check 'a declared individual skill folder is offered' ($ctx -match '- picked:pick-a \[plugin\]') $ctx
    Check 'each shortlisted skill names its SKILL.md procedure location' ($ctx -match ('alpha:alpha-one \[plugin\] -> ' + [regex]::Escape((Join-Path $sdAlpha 'skills\one\SKILL.md')))) $ctx
    Check 'an explicit-only skill is never shortlisted' ($ctx -notmatch 'alpha-three') $ctx
    Check 'a skill of a disabled plugin is never shortlisted' ($ctx -notmatch 'dormant-widget') $ctx
    Check 'the shortlist says it is not the full inventory' ($ctx -match 'not the full inventory') $ctx
    Check '4a: both routing lines are present verbatim at UserPromptSubmit' ($ctx.Contains($sdRoutingA) -and $ctx.Contains($sdRoutingB)) $ctx

    # ---- Codex fixture home -------------------------------------------------
    $sdCodex = Join-Path $Work 'sd-codex-home'
    $sdCodexCache = Join-Path $sdCodex 'plugins\cache\mk'
    New-Item -ItemType Directory -Path (Join-Path $sdCodexCache 'cplug\1.0.0\.codex-plugin') -Force | Out-Null
    Write-Utf8 (Join-Path $sdCodexCache 'cplug\1.0.0\.codex-plugin\plugin.json') '{"name":"cplug","skills":"./skills/"}'
    New-SdSkill (Join-Path $sdCodexCache 'cplug\1.0.0\skills\c-one') 'c-one'
    New-SdSkill (Join-Path $sdCodexCache 'cplug\1.0.0\skills\c-two') 'c-two'
    New-SdSkill (Join-Path $sdCodexCache 'coff\1.0.0\skills\c-old') 'c-old'
    New-SdSkill (Join-Path $sdCodexCache 'coff\2.0.0\skills\c-off') 'c-off'
    (Get-Item -LiteralPath (Join-Path $sdCodexCache 'coff\1.0.0')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)
    New-SdSkill (Join-Path $sdCodex 'skills\owned-helper') 'owned-helper'
    New-SdSkill (Join-Path $sdCodex 'skills\.system\sys-skill') 'sys-skill'
    New-SdSkill (Join-Path $sdCodex 'skills\gone') 'gone'
    New-SdSkill (Join-Path $sdCodex 'skills\quiet') 'quiet'
    New-Item -ItemType Directory -Path (Join-Path $sdCodex 'skills\quiet\agents') -Force | Out-Null
    Write-Utf8 (Join-Path $sdCodex 'skills\quiet\agents\openai.yaml') "policy:`n  allow_implicit_invocation: false`n"
    $sdShared = Join-Path $Work 'sd-shared\skills'
    New-SdSkill (Join-Path $sdShared 'shared-one') 'shared-one'
    $sdGonePath = (Join-Path $sdCodex 'skills\gone\SKILL.md').Replace('\', '\\')
    Write-Utf8 (Join-Path $sdCodex 'config.toml') ("[plugins.""cplug@mk""]`nenabled = true`n`n[plugins.""coff@mk""]`nenabled = false`n`n[[skills.config]]`npath = """ + $sdGonePath + """`nenabled = false`n")
    $sdCodexHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{
        SKILLS_DIR = (Join-Path $Work 'no-such-library'); PLUGIN_SKILLS_ROOT = ''
        CODEX_HOME_DIR = $sdCodex; CODEX_SHARED_SKILLS_DIR = $sdShared
        # The Claude fixture is configured too: a Codex run must not read it.
        CLAUDE_PLUGINS_FILE = $sdPluginsFile; CLAUDE_DESKTOP_SKILLS_ROOT = $sdDesktop
    }

    # =====================================================================
    Write-Host '--- Skills-Check: per-skill discovery on Codex uses Codex paths only ---' -ForegroundColor Cyan
    Set-ClaudeProjectDir ''
    $sdCodexProj = New-Proj 'SkillDiscoveryCodex'
    $r = Fire -HookPath $sdCodexHook -Cwd $sdCodexProj -RawStdin (New-PromptStdin -Cwd $sdCodexProj -EventName 'SessionStart' -Prompt '' -SessionId 'sd-x1')
    $ctx = Get-Context $r.Out
    Check 'Codex SessionStart uses the shared context shape' ($r.Out -match '"hookSpecificOutput"' -and $r.Out -match '"hookEventName":"SessionStart"') $r.Out
    # cplug 2 + coff 1 (newest version only) + own + .system + gone + quiet + shared.
    Check 'Codex plugins, its skills folder and the shared folder are all enumerated' ($ctx -match 'Plugin skills: 8 across 4 plugins') $ctx
    Check 'on Codex a disabled plugin, a config-disabled skill and an explicit-only skill stay distinct' (
        $ctx -match 'Of these: 6 enabled, 2 disabled \(not loadable\), 1 explicit-only') $ctx
    Check 'several cached versions are reported as a partial choice, not hidden' ($ctx -match 'coff@mk has 2 cached versions; newest used') $ctx
    Check 'a Codex run never reports Claude paths or Claude skills' ($ctx -notmatch 'alpha-one' -and $ctx -notmatch 'anthropic-skills' -and $ctx -notmatch 'sd-claude') $ctx
    Check 'missing rules are reported as NOT CHECKED, never as no drift' ($ctx -match 'Catalogue drift NOT CHECKED' -and $ctx -match 'not an all-clear') $ctx
    $r = Fire -HookPath $sdCodexHook -Cwd $sdCodexProj -RawStdin (New-PromptStdin -Cwd $sdCodexProj -EventName 'UserPromptSubmit' -Prompt 'quiet shared gone owned' -SessionId 'sd-x2')
    $ctx = Get-Context $r.Out
    Check 'Codex invocations are bare names' ($ctx -match '- shared-one \[codex-shared\]' -and $ctx -match '- owned-helper \[codex-skills\]') $ctx
    Check 'Codex explicit-only and config-disabled skills are never shortlisted' ($ctx -notmatch '- quiet ' -and $ctx -notmatch '- gone ') $ctx
    $r = Fire -HookPath $sdCodexHook -Cwd $sdCodexProj -RawStdin (New-StopStdin -Cwd $sdCodexProj -Transcript (Join-Path $Work 'no-such-transcript.jsonl') -SessionId 'sd-x3')
    Check 'Codex Stop keeps its established systemMessage shape' ($r.Out -match '"systemMessage"' -and $r.Out -notmatch '"hookSpecificOutput"') $r.Out

    Set-ClaudeProjectDir $sdSavedClaudeDir
