# Installation aliases, manifest namespaces and marketplace surfaces are separate.
function Get-ClaudePluginSurface {
    param([string]$Root, [string]$Key, $Partial)
    $alias = $Key.Split('@')[0]
    $answer = [pscustomobject]@{ Namespace = $alias; Declared = @(); Exclusive = $false; Known = $true; DefaultEnabled = $true }
    $path = Join-Path $Root '.claude-plugin/plugin.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $doc = Read-DiscoveryJson $path $Partial ($Key + ' manifest')
        $name = Get-Field $doc 'name'
        if ($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            $answer.Known = $false; $answer.Namespace = ''
            [void]$Partial.Add($Key + ' manifest namespace unknown')
        }
        else { $answer.Namespace = $name }
        if ($null -ne $doc) {
            $answer.Declared = @(Get-Field $doc 'skills')
            if ($null -ne $doc.PSObject.Properties['defaultEnabled']) {
                if ($doc.defaultEnabled -is [bool]) { $answer.DefaultEnabled = $doc.defaultEnabled }
                else { $answer.Known = $false; [void]$Partial.Add($Key + ' defaultEnabled malformed') }
            }
        }
    }
    # A bundled marketplace can narrow an alias to a published subset. Never
    # search arbitrary ancestors or unrelated cached marketplace versions.
    $marketPath = Join-Path $Root '.claude-plugin/marketplace.json'
    if (Test-Path -LiteralPath $marketPath -PathType Leaf) {
        $market = Read-DiscoveryJson $marketPath $Partial ($Key + ' marketplace')
        $parts = $Key.Split('@')
        $entries = @()
        if ($null -ne $market -and $parts.Count -eq 2 -and [string](Get-Field $market 'name') -ceq $parts[1]) {
            $entries = @(Get-Field $market 'plugins' | Where-Object { [string](Get-Field $_ 'name') -ceq $alias })
        }
        if ($entries.Count -gt 1 -or $null -eq $market) { $answer.Known = $false; [void]$Partial.Add($Key + ' marketplace surface ambiguous') }
        elseif ($entries.Count -eq 1) {
            $entry = $entries[0]
            if ($null -ne $entry.PSObject.Properties['skills']) {
                $answer.Exclusive = ([string](Get-Field $entry 'source') -in @('.','./'))
                if ($answer.Exclusive) { $answer.Declared = @($entry.skills) }
                else { $answer.Declared = @($answer.Declared) + @($entry.skills) }
                if ((Get-Field $entry 'strict') -eq $false -and (Test-Path -LiteralPath $path -PathType Leaf)) { $answer.Known = $false; [void]$Partial.Add($Key + ' conflicting manifests') }
            }
            if ($null -ne $entry.PSObject.Properties['defaultEnabled']) {
                if ($entry.defaultEnabled -is [bool]) { $answer.DefaultEnabled = $entry.defaultEnabled }
                else { $answer.Known = $false; [void]$Partial.Add($Key + ' marketplace defaultEnabled malformed') }
            }
        }
    }
    if ($answer.Declared.Count -gt 128) { $answer.Known = $false; $answer.Declared = @($answer.Declared | Select-Object -First 128); [void]$Partial.Add($Key + ' declaration ceiling reached') }
    foreach ($entry in $answer.Declared) {
        if ($null -ne $entry -and ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry))) {
            $answer.Known = $false; [void]$Partial.Add($Key + ' skill declaration malformed')
        }
    }
    return $answer
}

function Add-ClaudePluginSkill {
    param($Result, $Skill, [string]$Key, [bool]$Known)
    Set-ObjectProperty $Skill 'InstallationKey' $Key
    if (-not $Known) { $Skill.Invocation = ''; $Skill.Status = 'unknown' }
    $hash = Get-DiscoverySkillHash $Skill.Path
    Set-ObjectProperty $Skill 'DefinitionHash' $hash
    if ($hash -eq '') { $Skill.Status = 'unknown'; $Skill.Invocation = ''; [void]$Result.Partial.Add($Key + ' skill unreadable or over byte ceiling') }
    # Identical alias copies are one capability. Different providers/namespaces
    # stay distinct; conflicting definitions of one invocation cannot be offered.
    if ($Skill.Invocation -eq '' -or $hash -eq '') { Add-DiscoveredSkill $Result $Skill; return }
    if ($null -eq $Result.PSObject.Properties['InvocationDefinitions']) { Set-ObjectProperty $Result 'InvocationDefinitions' @{} }
    $candidates = if ($Result.InvocationDefinitions.ContainsKey($Skill.Invocation)) { @($Result.InvocationDefinitions[$Skill.Invocation].ToArray()) } else { @() }
    foreach ($existing in $candidates) {
        if ($existing.Source -ne 'claude-plugin' -or $Skill.Invocation -eq '' -or $existing.Invocation -cne $Skill.Invocation) { continue }
        $sameProvider = (([string]$existing.InstallationKey).Split(';')[0].Split('@')[-1] -ceq $Key.Split('@')[-1])
        if ($sameProvider -and $existing.DefinitionHash -eq $hash -and $existing.Status -eq $Skill.Status -and $existing.Explicit -eq $Skill.Explicit -and $existing.Version -eq $Skill.Version) {
            $keys = @(([string]$existing.InstallationKey).Split(';') + $Key | Select-Object -Unique)
            $existing.InstallationKey = $keys -join ';'
            return
        }
        $existing.Status = 'unknown'; $Skill.Status = 'unknown'
        [void]$Result.Partial.Add('Conflicting plugin definition/status/version: ' + $Skill.Invocation)
    }
    if (-not $Result.InvocationDefinitions.ContainsKey($Skill.Invocation)) { $Result.InvocationDefinitions[$Skill.Invocation] = New-Object 'System.Collections.Generic.List[object]' }
    [void]$Result.InvocationDefinitions[$Skill.Invocation].Add($Skill)
    Add-DiscoveredSkill $Result $Skill
}
