# Provider catalogue seam; dot-sourced by the existing context suite.
function Invoke-SkillProviderRegression {
    param([string]$Root)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skillindex.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skilldiscovery.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skilldrift.ps1')
    $client='claude'; $config=@{}; $homeDir=$Work; $cwd=$Work
    $rules=Join-Path $Work 'provider-rules'; $folder=Join-Path $Work 'new-provider/skills/shared-name'
    [void][IO.Directory]::CreateDirectory((Join-Path $rules 'catalogue'))
    [void][IO.Directory]::CreateDirectory($folder)
    Write-Utf8 (Join-Path $folder 'SKILL.md') "---`nname: shared-name`ndescription: fixture`n---`nnew provider body"
    Write-Utf8 (Join-Path $rules 'global-skill-routing.md') '- `old-provider:shared-name`, `shared-name`.'
    $skill=New-DiscoveredSkill 'new-provider' $folder 'claude-plugin' '1.0.0' $true 'claude'
    Set-ObjectProperty $skill 'InstallationKey' 'new-provider@market'
    Set-ObjectProperty $skill 'DefinitionHash' (Get-DiscoverySkillHash $folder)
    $pluginList=New-Object 'System.Collections.Generic.List[object]';[void]$pluginList.Add($skill)
    $index=[pscustomobject]@{Plugin=$pluginList;InstallKeys=@('new-provider@market');InstallKnown=$true}
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Write-Utf8 (Join-Path $rules 'global-research-workflows.md') '- `companion-only-research`.'
    Write-Utf8 (Join-Path $rules 'global-connected-skill-contracts.md') '- `companion-only-setup`.'
    $hints = Get-CataloguedSkillNames $rules
    Check 'new companion routes reachable as bounded compatibility hints' ($hints.Contains('companion-only-research') -and $hints.Contains('companion-only-setup'))
    Check 'another provider route and bare prose do not cover installed plugin' ($drift.Missing -contains 'new-provider:shared-name')
    $row=@{name='shared-name';provider='old-provider@market';sha256=$skill.DefinitionHash;sources=@(@{client='claude';package='old-provider@market';path=(Join-Path $folder 'SKILL.md');invocation='old-provider:shared-name';version='1.0.0';status='registered/enabled'})}
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Check 'equal bytes still do not merge provider contracts' ($drift.Missing -contains 'new-provider:shared-name')
    $row.provider='new-provider@market';$row.sources[0].package='new-provider@market';$row.sources[0].invocation='new-provider:shared-name'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Check 'exact current structured skill contract covers its provider' ($drift.Missing.Count -eq 0)
    $row.sha256='0'*64
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Check 'stale contract hash cannot claim provider coverage' ($drift.Missing -contains 'new-provider:shared-name')
    $row.sha256=$skill.DefinitionHash;$row.category='command'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Check 'same job command is not a SKILL contract' ($drift.Missing -contains 'new-provider:shared-name')
    $row.category='agent'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Check 'same job agent name is not a SKILL contract' ($drift.Missing -contains 'new-provider:shared-name')
    $row.category='skill';$row.sources[0].version='2.0.0'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Check 'explicit stale package version is not current coverage' ($drift.Missing -contains 'new-provider:shared-name')
    $row.sources[0].version='1.0.0'
    $row.sources[0].invocation='shared-name';$row.sources[0].package='claude-user-standalone';$row.provider='claude-user-standalone'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @('shared-name') -Index $index
    Check 'bare user load contract never proves qualified plugin load' ($drift.Missing -contains 'new-provider:shared-name')
    $bare=New-DiscoveredSkill '' $folder 'user-global' '' $true 'claude'
    $row.sources[0].version='byte-match checked 2026-10-06'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $emptyIndex=[pscustomobject]@{Plugin=@();InstallKeys=@();InstallKnown=$false}
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @() -Index $emptyIndex -Definitions @($bare)
    Check 'bare user source retains its own exact contract' ($drift.Missing.Count -eq 0)
    Write-Utf8 (Join-Path $rules 'catalogue/skills-002.jsonl') '{malformed'
    $drift=Get-SkillCatalogueDrift -RulesDir $rules -DiscoveredNames @() -Index $emptyIndex -Definitions @($bare)
    Check 'unreadable catalogue scope stays explicitly partial' ($drift.Partial.Count -gt 0)
    $large=Join-Path $Work 'large-provider';[void][IO.Directory]::CreateDirectory((Join-Path $large '.claude-plugin'))
    Write-Utf8 (Join-Path $large '.claude-plugin/plugin.json') '{"name":"large-provider"}'
    foreach ($name in @('a-first','b-second','z-selected-child')) {
        $child=Join-Path $large ('skills/'+$name);[void][IO.Directory]::CreateDirectory($child)
        Write-Utf8 (Join-Path $child 'SKILL.md') ("---`nname: "+$name+"`n---`nbody")
    }
    $registry=Join-Path $Work 'large-registry.json'
    Write-Utf8 $registry (@{plugins=@{'large-provider@market'=@(@{scope='user';installPath=$large;version='1'})}} | ConvertTo-Json -Depth 6)
    $hookInput=[pscustomobject]@{prompt='Use z-selected-child'}
    $discovery=New-SkillDiscoveryConfig;$discovery.PluginsFile=$registry;$discovery.DesktopRoots=@()
    $savedCeiling=$script:DiscoveryMaxSkills
    try {
        $script:DiscoveryMaxSkills=2
        $answer=Invoke-SkillDiscovery $discovery
        Check 'exact selected child gets slot before capped remainder' (@($answer.Skills | Where-Object {$_.Invocation -eq 'large-provider:z-selected-child'}).Count -eq 1 -and $answer.Skills.Count -eq 2 -and $answer.Partial.Count -gt 0)
    }
    finally {$script:DiscoveryMaxSkills=$savedCeiling}
    Check 'relevant candidate list uses safe bounded literal folder names' (@(Get-DiscoveryRelevantNames 'Use ../outside and z-selected-child').Count -le 16 -and @($discovery.RelevantNames) -contains 'z-selected-child')
    $long = 'ordinary words one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen use large-provider:z-selected-child'
    Check 'qualified selected child survives ordinary long preamble' (@(Get-DiscoveryRelevantNames $long) -contains 'z-selected-child')
    . (Join-Path $Root 'hooks/Skills-Check/_skillstop.ps1')
    $unused=Get-UnusedShortlistedSkills -Shortlist @('new-provider:shared-name') -Accounted @() -RawTranscript '{"name":"Skill","input":{"skill":"shared-name"}}' -UsedLine ''
    Check 'bare Skill call does not satisfy qualified provider usage' ($unused.Total -eq 1)
    $unused=Get-UnusedShortlistedSkills -Shortlist @('new-provider:shared-name') -Accounted @() -RawTranscript '{"name":"Skill","input":{"skill":"new-provider:shared-name"}}' -UsedLine ''
    Check 'exact qualified Skill call accounts for that provider' ($unused.Total -eq 0)
    $row.provider='new-provider@market';$row.sources[0].package='new-provider@market';$row.sources[0].invocation='new-provider:shared-name';$row.sources[0].version='1'
    $skill.Version='2'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    $drift=Get-SkillCatalogueDrift $rules @('shared-name') $index
    Check 'single-part package versions are compared exactly' ($drift.Missing -contains 'new-provider:shared-name')
    $row.sources[0].version='2'
    Write-Utf8 (Join-Path $rules 'catalogue/skills-001.jsonl') ($row | ConvertTo-Json -Depth 6 -Compress)
    Write-Utf8 (Join-Path $folder 'SKILL.md') "---`nname: shared-name`n---`nchanged bytes"
    $drift=Get-SkillCatalogueDrift $rules @('shared-name') $index
    Check 'cached old definition hash cannot cover changed body' ($drift.Missing -contains 'new-provider:shared-name')
    $indexPath=Join-Path $Work 'warm-index.txt';$indexConfigHash='fixture';$indexTtlMinutes=1440
    Write-Utf8 $indexPath ('HookMakerSkillsIndex|'+$script:SkillIndexVersion+'|fixture|'+[DateTime]::UtcNow.Ticks+"`np|new-provider|shared-name|shared-name|fixture|"+$folder+'|claude-plugin|2|enabled|0|new-provider:shared-name|new-provider@market|'+$skill.DefinitionHash)
    Check 'warm index invalidates on body change without manifest edit' ($null -eq (Read-SkillIndex))
    $skillDiscovery=$discovery;$stateDir=Join-Path $Work 'index-state';$hasLibrary=$false;$libraryDir='';$hasPluginRoot=$true;$pluginRoot=Join-Path $Work 'override-cache'
    $cacheSkill=Join-Path $pluginRoot 'market/alias/1/skills/off-child';[void][IO.Directory]::CreateDirectory($cacheSkill)
    Write-Utf8 (Join-Path $cacheSkill 'SKILL.md') "---`nname: off-child`n---`nbody"
    $pluginInstall=Split-Path -Parent (Split-Path -Parent $cacheSkill)
    $settings=Join-Path $Work 'disabled-settings.json';Write-Utf8 $settings '{"enabledPlugins":{"alias@market":false}}'
    Write-Utf8 $registry (@{plugins=@{'alias@market'=@(@{scope='user';installPath=$pluginInstall;version='1'})}}|ConvertTo-Json -Depth 6)
    $skillDiscovery.SettingsFiles=@($settings);$skillDiscovery.RelevantNames=@();$indexPath=Join-Path $stateDir 'index.txt'
    $built=Build-SkillIndex
    Check 'authoritative disabled install replaces enabled override cache row' (@($built.Plugin | Where-Object {$_.Name -eq 'off-child' -and $_.Status -eq 'disabled'}).Count -eq 1 -and @($built.Plugin | Where-Object {$_.Status -eq 'enabled'}).Count -eq 0)
    Invoke-SkillEvidenceRegression $Root
}

# Pure shared seams: no hook child, network, real home or installed-client probe.
function Invoke-SkillEvidenceRegression {
    param([string]$Root)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skillindex.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skilldiscovery.ps1')
    . (Join-Path $Root 'hooks/Skills-Check/_skillstop.ps1')
    $client='claude';$config=@{};$homeDir=$Work;$cwd=$Work;$hookInput=[pscustomobject]@{prompt='telemetry'}
    $stateDir=Join-Path $Work 'evidence-state';$indexPath=Join-Path $stateDir 'index.txt';$indexConfigHash='fixture';$indexTtlMinutes=0
    [void][IO.Directory]::CreateDirectory($stateDir)
    Write-Utf8 $indexPath ('HookMakerSkillsIndex|4|fixture|'+[DateTime]::UtcNow.Ticks+"`np|old|telemetry|telemetry|fixture|missing|cache-walk||enabled|0|old:telemetry")
    Check 'V72 invalidates formerly enabled cache-only index rows' ($null -eq (Read-SkillIndex))
    $hasLibrary=$false;$libraryDir='';$hasPluginRoot=$true;$pluginRoot=Join-Path $Work 'evidence-cache'
    $folder=Join-Path $pluginRoot 'market/cache-alias/1/skills/telemetry';[void][IO.Directory]::CreateDirectory($folder)
    Write-Utf8 (Join-Path $folder 'SKILL.md') "---`nname: telemetry`n---`nbody"
    $skillDiscovery=New-SkillDiscoveryConfig
    $skillDiscovery.PluginsFile=Join-Path $Work 'absent-registry';$skillDiscovery.DesktopRoots=@()
    $built=Build-SkillIndex
    $cached=@($built.Plugin | Where-Object {$_.Source -eq 'cache-walk'})
    Check 'cache-only definition remains unknown without an invented invocation' ($cached.Count -eq 1 -and $cached[0].Status -eq 'unknown' -and $cached[0].Invocation -eq '')
    $eligible=Get-Command Test-SkillCandidate -ErrorAction SilentlyContinue
    Check 'candidate predicate exists for both shortlist and availability' ($null -ne $eligible)
    if ($null -ne $eligible) {
        foreach ($case in @(@('enabled','0','actual:telemetry',$true),@('disabled','0','actual:telemetry',$false),@('unknown','0','actual:telemetry',$false),@('enabled','1','actual:telemetry',$false),@('enabled','0','',$false))) {
            $row=[pscustomobject]@{Status=$case[0];Explicit=$case[1];Invocation=$case[2]}
            Check ('candidate eligibility '+($case[0..2]-join '/')) ((Test-SkillCandidate $row) -eq $case[3])
        }
    }
    $installedReader=Get-Command Get-InstalledSkillNames -ErrorAction SilentlyContinue
    Check 'installed-name suppression is independent of candidate eligibility' ($null -ne $installedReader)
    if ($null -ne $installedReader) {
        foreach ($case in @(@('disabled','0'),@('enabled','1'),@('unknown','0'))) {
            $definition=[pscustomobject]@{Source='claude-plugin';Status=$case[0];Explicit=$case[1];Invocation='actual:telemetry';Name='telemetry';Leaf='folder-name'}
            $names=Get-InstalledSkillNames (@($definition)+@($cached))
            Check ('authoritative duplicate import suppressed '+($case-join '/')) ($names.ContainsKey('actual:telemetry') -and $names.ContainsKey('telemetry') -and $names.ContainsKey('folder-name'))
        }
        Check 'cache-only unknown does not suppress authorized library import' ((Get-InstalledSkillNames @($cached)).Count -eq 0)
    }
    $known=New-DiscoveredSkill 'actual' $folder 'claude-plugin' '2.3' $true 'claude'
    Set-ObjectProperty $known InstallationKey 'registered-alias@market'
    $index=[pscustomobject]@{Plugin=@($known)+@($cached);Library=@()};$byName=@{};$installedNames=@{};$prompt='telemetry'
    . (Join-Path $Root 'hooks/Skills-Check/_promptmatch.ps1')
    Check 'shortlist excludes cache-only and preserves exact source provider version' ($topInstalled.Count -eq 1 -and $topInstalled[0].Name -ceq 'actual:telemetry' -and $topInstalled[0].Where -ceq 'claude-plugin' -and [string](Get-Field $topInstalled[0] 'InstallationKey') -ceq 'registered-alias@market' -and [string](Get-Field $topInstalled[0] 'Version') -ceq '2.3')
    foreach ($line in @('old:telemetry','actual:telemetry-extra','actual:telemetry:child','prefix-actual:telemetry','none - old:telemetry unavailable')) {
        $answer=Get-UnusedShortlistedSkills @('actual:telemetry') @() '' $line
        Check ('foreign or partial key not credited: '+$line) ($answer.Total -eq 1)
    }
    foreach ($line in @('actual:telemetry','none - actual:telemetry: failed','none - actual:telemetry unavailable','none - actual:telemetry unsupported','none - telemetry: unrelated')) {
        $answer=Get-UnusedShortlistedSkills @('actual:telemetry') @() '' $line
        Check ('exact key or unique explicit skip credited: '+$line) ($answer.Total -eq 0)
    }
    $answer=Get-UnusedShortlistedSkills @('actual:telemetry','other:telemetry') @() '' 'none - telemetry unrelated'
    Check 'ambiguous bare skip cannot credit two providers' ($answer.Total -eq 2)
    $answer=Get-UnusedShortlistedSkills @('actual:telemetry') @() '' 'telemetry'
    Check 'bare usage claim never credits qualified provider' ($answer.Total -eq 1)
    $answer=Get-UnusedShortlistedSkills @('telemetry') @() '' 'telemetry'
    Check 'local and Codex bare keys retain accounting' ($answer.Total -eq 0)
    $decision=Get-SkillClosingDecision 'Skills used: none - unrelated' '' @('actual:telemetry') @() $false
    Check 'accounting guidance distinguishes evidence and never assumes loadability' ($decision.Text -notmatch 'Loadable:|They need no authorization' -and $decision.Text -match 'call!=loaded/executed/verified' -and $decision.Text -match 'failed/unavailable/unsupported')
    . (Join-Path $Root 'scripts/_guidanceinventory.ps1')
    $authored=(@(Get-HookGuidanceInventory (Join-Path $Root 'hooks')) | Measure-Object Characters -Sum).Sum
    Check 'V72 preserves fixed half-baseline guidance ceiling' ($authored -le 58360) $authored
}
