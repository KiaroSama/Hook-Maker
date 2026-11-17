# The Spec Kit CLASSIFICATION gate (steering V89, spec 041).
#
# The 3-file chain check in Speckit-Check.ps1 only proves a large change ran the
# chain. The classification rule is wider: every effectful turn states
# `Spec Kit: CHAIN (...)` or `Spec Kit: EXEMPT (question | review | small)`, and
# an EXEMPT line has to be true. This file judges only what the transcript can
# prove about the CURRENT turn - the edits after the newest typed prompt - so a
# correction turn with no new edits has no new duty and a finding refuses once.
#
# A separate file because Speckit-Check.ps1 must stay a readable Stop branch
# and the rule set here (sensitive paths, reason parsing) is its own concern.

# Paths that make a change non-SMALL on their own, whatever the file count:
# CI/release workflows, manifests and lockfiles, and rule/instruction files.
$script:SpecKitSensitivePath = '(?i)(^|[\\/])(' +
    '\.github[\\/]workflows[\\/][^\\/]+|' +
    'Cargo\.(toml|lock)|package(-lock)?\.json|pnpm-lock\.yaml|yarn\.lock|pyproject\.toml|poetry\.lock|uv\.lock|' +
    'requirements[^\\/]*\.txt|go\.(mod|sum)|pubspec\.(yaml|lock)|Package\.(swift|resolved)|packages\.lock\.json|' +
    '[^\\/]+\.csproj|pom\.xml|build\.gradle(\.kts)?|CMakeLists\.txt|' +
    'rules[\\/][^\\/]+\.md|CLAUDE\.md|AGENTS\.md|constitution\.md)$'

# A prompt the user did not type: a skill body, a hook refusal fed back, a
# compaction summary. Such text never starts a new turn.
function Test-SpecKitTypedPrompt {
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(?im)^[ \t-]*(?:SPECKIT CHECK|Speckit-Check:)') { return $false }
    if (Get-Command Test-InjectedPromptText -ErrorAction SilentlyContinue) { if (Test-InjectedPromptText -Text $Text) { return $false } }
    return $true
}

# Returns $null (no duty, or the line is consistent) or
# @{ Kind = missing|exempt|chain; Detail; EditCount; Fingerprint }.
function Get-SpecKitClassFinding {
    param([Parameter(Mandatory = $true)]$HookInput, [object[]]$Events, [Parameter(Mandatory = $true)][string]$Cwd)
    $root = [IO.Path]::GetFullPath($Cwd).TrimEnd('\', '/') + '\'
    $all = @($Events)
    $start = 0; $turnPrompt = ''
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i].Kind -eq 'prompt' -and (Test-SpecKitTypedPrompt -Text ([string]$all[$i].Value))) { $start = $i + 1; $turnPrompt = [string]$all[$i].Value }
    }
    $chainEvidence = $false
    $edited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $sensitive = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $all.Count; $i++) {
        $item = $all[$i]
        if ($item.Kind -eq 'skill' -and [string]$item.Value -match '(?i)(^|:)speckit-') { $chainEvidence = $true; continue }
        if ($item.Kind -ne 'write') { continue }
        $full = ''
        try { $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($item.Value)) { $item.Value } else { Join-Path $Cwd $item.Value })) } catch { continue }
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $full.Substring($root.Length)
        if ($relative -match '^(?i)(specs|\.specify)[\\/]') { $chainEvidence = $true; continue }
        if ($i -lt $start -or $relative -match '^(?i)(\.ai|\.claude|plans)[\\/]') { continue }
        if ($edited.Add($full) -and $relative -match $script:SpecKitSensitivePath) { [void]$sensitive.Add(($relative -replace '\\', '/')) }
    }
    if ($edited.Count -eq 0) { return $null }
    $closing = Get-TaskClosingEvidence -HookInput $HookInput
    if ($null -eq $closing -or -not $closing.Known) { return $null }
    $declaration = Test-ClosingDeclaration -Text ([string]$closing.Text) -LabelPattern 'Spec[ \t]*Kit' -AllowNoneWithReason $false
    $value = ([string]$declaration.Value).Trim()
    $kind = ''; $detail = ''
    if (-not $declaration.Present -or $value -notmatch '^(?i)(CHAIN|EXEMPT)\b') { $kind = 'missing' }
    elseif ($value -match '^(?i)CHAIN\b') { if (-not $chainEvidence) { $kind = 'chain' } }
    elseif ($value -match '(?i)\b(question|review)\b' -and $value -notmatch '(?i)\bsmall\b') { $kind = 'exempt'; $detail = 'it is a ' + $Matches[1].ToLowerInvariant() + ' turn that edited ' + [string]$edited.Count + ' project file(s)' }
    elseif ($edited.Count -ge 2) { $kind = 'exempt'; $detail = [string]$edited.Count + ' project files were edited' }
    elseif ($sensitive.Count -gt 0) { $kind = 'exempt'; $detail = $sensitive[0] + ' is CI, a manifest/lockfile or a rule file' }
    if ($kind -eq '') { return $null }
    $fingerprint = Get-ShortHash ([string](Get-Field $HookInput 'session_id') + '|' + (Get-ShortHash $turnPrompt) + '|' + $kind)
    return [pscustomobject]@{ Kind = $kind; Detail = $detail; EditCount = $edited.Count; Fingerprint = $fingerprint }
}
