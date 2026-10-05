# Supported literal runner identity and binding preflight. No evaluation or state writes.
# Whitelisted syntax only. Never SafeGetValue/GetScriptBlock/Invoke: variables,
# interpolation, commands, casts and expressions are not literal argv evidence.
function Get-GuardedLiteralValue {
    param($Node, [int]$Depth = 0)
    $unknown = [pscustomobject]@{ Known = $false; Values = @() }
    if ($null -eq $Node -or $Depth -gt 32) { return $unknown }
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $Node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return [pscustomobject]@{ Known = $true; Values = @([string]$Node.Value) }
    }
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        if ($Node.NestedExpressions.Count -gt 0) { return $unknown }
        return [pscustomobject]@{ Known = $true; Values = @([string]$Node.Value) }
    }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $value = switch ($Node.VariablePath.UserPath.ToLowerInvariant()) { 'true' { 'True' } 'false' { 'False' } 'null' { '' } default { return $unknown } }
        return [pscustomobject]@{ Known = $true; Values = @([string]$value) }
    }
    $children = @()
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) { $children = @($Node.Elements) }
    elseif ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) { $children = @($Node.SubExpression.Statements) }
    elseif ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) { $children = @($Node.Pipeline) }
    elseif ($Node -is [System.Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1 -and
        $Node.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and $Node.PipelineElements[0].Redirections.Count -eq 0) {
        $children = @($Node.PipelineElements[0].Expression)
    }
    else { return $unknown }
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($child in $children) {
        $literal = Get-GuardedLiteralValue -Node $child -Depth ($Depth + 1)
        if (-not $literal.Known) { return $unknown }
        if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst] -and $literal.Values.Count -ne 1) { return $unknown }
        foreach ($value in $literal.Values) { [void]$values.Add([string]$value) }
        if ($values.Count -gt 4096) { return $unknown }
    }
    return [pscustomobject]@{ Known = $true; Values = @($values.ToArray()) }
}

function Get-GuardedInvocationIdentity {
    param([string[]]$Tokens, $RawCommand = $null)
    $identity = [pscustomobject]@{
        RunId = ''; ProjectFingerprint = ''; CommandFingerprint = ''
        BindingKnown = $false; WorkingDirectory = ''; FingerprintStart = -1
        FingerprintLength = 0; InvocationEnd = -1; FingerprintIndex = -1
    }
    $parameters = @{}
    $names = @('runid', 'projectfingerprint', 'workingdirectory', 'filepath', 'arguments', 'argumentsjson')
    if ($RawCommand -is [string]) {
        if ($RawCommand.Length -gt 262144) { return $identity }
        $parseTokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($RawCommand, [ref]$parseTokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { return $identity }
        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($command in @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]}, $false))) {
            $elements = @($command.CommandElements)
            # The printed replacement repeats POSIX assignment words (CI=1 pwsh ...).
            $lead = 0; while ($lead -lt $elements.Count - 1 -and $elements[$lead].Extent.Text -match '^[A-Za-z_][A-Za-z0-9_]*=') { $lead++ }
            $program = if ($lead -gt 0) { $elements[$lead].Extent.Text.Trim([char[]]"`"'") } else { [string]$command.GetCommandName() }
            if ($program -eq '') { continue }
            if ((Get-ProgramName $program) -eq 'run-tests-guarded.ps1') {
                [void]$candidates.Add([pscustomobject]@{ Elements = $elements; Start = ($lead + 1) })
            }
            elseif ($script:PowerShellPrograms -contains (Get-ProgramName $program)) {
                for ($i = $lead + 1; $i -lt $elements.Count - 1; $i++) {
                    if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst] -or $elements[$i].ParameterName -ne 'File') { continue }
                    $target = Get-GuardedLiteralValue $elements[$i + 1]
                    if ($target.Known -and $target.Values.Count -eq 1 -and (Get-ProgramName $target.Values[0]) -eq 'run-tests-guarded.ps1') {
                        [void]$candidates.Add([pscustomobject]@{ Elements = $elements; Start = ($i + 2) })
                    }
                    break
                }
            }
        }
        if ($candidates.Count -ne 1) { return $identity }
        $elements = $candidates[0].Elements
        $identity.InvocationEnd = $elements[$elements.Count - 1].Extent.EndOffset
        for ($i = $candidates[0].Start; $i -lt $elements.Count; $i++) {
            $parameter = $elements[$i]
            if ($parameter -isnot [System.Management.Automation.Language.CommandParameterAst]) { return $identity }
            $name = $parameter.ParameterName.ToLowerInvariant()
            $valueNode = $parameter.Argument
            if ($null -eq $valueNode -and $i + 1 -lt $elements.Count -and $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { $valueNode = $elements[++$i] }
            if ($names -notcontains $name) {
                # PowerShell binds abbreviated parameters. Unsupported identity
                # abbreviations are unknown, never an omitted argument list.
                if (@($names | Where-Object { $_.StartsWith($name, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { return $identity }
                continue
            }
            if ($parameters.ContainsKey($name)) { return $identity }
            $parameters[$name] = Get-GuardedLiteralValue $valueNode
            if ($name -eq 'projectfingerprint') {
                $identity.FingerprintStart = $parameter.Extent.StartOffset
                $end = if ($null -ne $valueNode) { $valueNode.Extent.EndOffset } else { $parameter.Extent.EndOffset }
                $identity.FingerprintLength = $end - $identity.FingerprintStart
                # A switch with no value is a known unusable binding, not dynamic.
                if ($null -eq $valueNode) { $parameters[$name] = [pscustomobject]@{Known=$true; Values=@('')} }
            }
        }
    }
    else {
        # A real argv array needs no shell parsing. Without raw syntax, however,
        # -Arguments cannot be reconstructed by guessing where its array ends.
        $t = if ($null -ne $RawCommand) { @($RawCommand | ForEach-Object { [string]$_ }) } else { @($Tokens) }
        $start = 0
        if ($t.Count -gt 0 -and (Get-ProgramName $t[0]) -eq 'run-tests-guarded.ps1') { $start = 1 }
        elseif ($t.Count -gt 0 -and $script:PowerShellPrograms -contains (Get-ProgramName $t[0])) {
            for ($j = 1; $j -lt $t.Count - 1; $j++) {
                if ($t[$j] -eq '-File' -and (Get-ProgramName $t[$j + 1]) -eq 'run-tests-guarded.ps1') { $start = $j + 2; break }
            }
            if ($start -eq 0) { return $identity }
        }
        for ($i = $start; $i -lt $t.Count; $i++) {
            $name = $t[$i].TrimStart('-').ToLowerInvariant()
            if (-not $t[$i].StartsWith('-')) { continue }
            if ($names -notcontains $name) {
                if (@($names | Where-Object { $_.StartsWith($name, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { return $identity }
                continue
            }
            if ($parameters.ContainsKey($name)) { return $identity }
            $hasValue = ($i + 1 -lt $t.Count -and -not $t[$i + 1].StartsWith('-'))
            $known = ($name -ne 'arguments' -and ($hasValue -or $name -eq 'projectfingerprint'))
            $parameters[$name] = [pscustomobject]@{ Known = $known; Values = @($(if ($hasValue) { $t[$i + 1] } else { '' })) }
            if ($name -eq 'projectfingerprint') { $identity.FingerprintIndex = $i; $identity.FingerprintLength = [int]$hasValue }
            if ($hasValue) { $i++ }
        }
    }
    foreach ($pair in @(@('runid','RunId'), @('projectfingerprint','ProjectFingerprint'))) {
        if ($parameters.ContainsKey($pair[0])) {
            $literal = $parameters[$pair[0]]
            if ($literal.Known -and $literal.Values.Count -eq 1 -and (Test-LiteralIdentityToken $literal.Values[0])) { $identity.($pair[1]) = $literal.Values[0] }
        }
    }
    if (-not $parameters.ContainsKey('filepath')) { return $identity }
    $file = $parameters['filepath']
    if (-not $file.Known -or $file.Values.Count -ne 1 -or [string]::IsNullOrWhiteSpace($file.Values[0])) { return $identity }
    $innerArgs = @(); $jsonWins = $false
    if ($parameters.ContainsKey('argumentsjson')) {
        $json = $parameters['argumentsjson']
        if (-not $json.Known -or $json.Values.Count -ne 1) { return $identity }
        $argsJson = [string]$json.Values[0]
        if (-not [string]::IsNullOrWhiteSpace($argsJson)) {
            # Match the runner's textual array check and primitive conversion;
            # a single JSON string element must not be mistaken for a scalar.
            $jsonText = $argsJson.TrimStart([char[]]@(' ', "`t", "`r", "`n", [char]0xFEFF))
            if (-not $jsonText.StartsWith('[')) { return $identity }
            try { $parsed = $argsJson | ConvertFrom-Json -ErrorAction Stop } catch { return $identity }
            if ($null -eq $parsed) { $parsed = @() }
            foreach ($element in @($parsed)) {
                if ($null -ne $element -and (($element -is [System.Collections.IEnumerable] -and $element -isnot [string]) -or
                    $element.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject')) { return $identity }
            }
            $innerArgs = @(@($parsed) | ForEach-Object { [string]$_ })
            $jsonWins = $true
        }
    }
    if (-not $jsonWins -and $parameters.ContainsKey('arguments')) {
        if (-not $parameters['arguments'].Known) { return $identity }
        $innerArgs = @($parameters['arguments'].Values)
    }
    $identity.CommandFingerprint = Get-CommandFingerprint -ExecutablePath $file.Values[0] -ArgumentList $innerArgs
    foreach ($name in @('projectfingerprint', 'workingdirectory')) {
        if (-not $parameters.ContainsKey($name)) { continue }
        $literal = $parameters[$name]
        if (-not $literal.Known -or $literal.Values.Count -ne 1) { return $identity }
        if ($name -eq 'workingdirectory') { $identity.WorkingDirectory = [string]$literal.Values[0] }
    }
    $identity.BindingKnown = $true
    return $identity
}

function Get-GuardedBindingFinding {
    param($Identity, $RawCommand, [string]$ProjectRoot, [string]$CurrentFingerprint)
    if (-not $Identity.BindingKnown -or [string]::IsNullOrWhiteSpace($Identity.CommandFingerprint)) {
        return [pscustomobject]@{ Kind='unknown'; Message='TEST RUN GUARD: this guarded command uses a dynamic or unsupported identity/working-directory expression. No unmatchable observation was recorded. Use literal -FilePath, arguments, -WorkingDirectory and -ProjectFingerprint for correlated evidence.' }
    }
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $working = $Identity.WorkingDirectory
    if (-not [string]::IsNullOrWhiteSpace($working)) {
        try {
            if (-not [IO.Path]::IsPathRooted($working)) { $working = [IO.Path]::Combine($ProjectRoot, $working) }
            # Match the standalone runner: literal percent/dollar text is never expanded.
            $working = [IO.Path]::GetFullPath($working).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
        }
        catch { return [pscustomobject]@{Kind='unknown';Message='TEST RUN GUARD: literal -WorkingDirectory cannot be resolved. No observation was recorded; use an absolute literal project directory.'} }
        if (-not [string]::Equals($working, $ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{Kind='deny';Message=('TEST RUN GUARD: literal -WorkingDirectory differs from hook cwd. No observation was recorded. Run the unchanged invocation from a session whose cwd is that project, then use its current literal -ProjectFingerprint; this session cannot bind another project''s receipt. Current hook-cwd fingerprint: ' + $CurrentFingerprint + '. All caller options remain unchanged.')}
        }
    }
    if ($Identity.ProjectFingerprint -ceq $CurrentFingerprint) { return $null }
    $replacement = '-ProjectFingerprint ' + $CurrentFingerprint
    if ($RawCommand -is [string]) {
        if ($Identity.FingerprintStart -ge 0) {
            $correction = $RawCommand.Remove($Identity.FingerprintStart, $Identity.FingerprintLength).Insert($Identity.FingerprintStart, $replacement)
        }
        else { $correction = $RawCommand.Insert($Identity.InvocationEnd, (' ' + $replacement)) }
    }
    else {
        $corrected = New-Object System.Collections.Generic.List[string]
        foreach ($token in @($RawCommand)) { [void]$corrected.Add([string]$token) }
        if ($Identity.FingerprintIndex -ge 0) {
            if ($Identity.FingerprintLength -gt 0) { $corrected[$Identity.FingerprintIndex + 1] = $CurrentFingerprint }
            else { $corrected.Insert($Identity.FingerprintIndex + 1, $CurrentFingerprint) }
        }
        else { [void]$corrected.Add('-ProjectFingerprint'); [void]$corrected.Add($CurrentFingerprint) }
        $correction = ConvertTo-Json -InputObject ([string[]]$corrected.ToArray()) -Compress
    }
    return [pscustomobject]@{Kind='deny';Message=('TEST RUN GUARD: missing, blank, unusable or stale -ProjectFingerprint. Refused before execution and observation. Current literal fingerprint: ' + $CurrentFingerprint + '. Correct only this binding, preserving all other command/options:' + "`n`n" + $correction + "`n`n" + 'No tool input was rewritten and no permission was granted.')}
}
