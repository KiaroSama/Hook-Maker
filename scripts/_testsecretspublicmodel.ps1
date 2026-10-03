# Shared pure registry seam first; entry scenarios reuse the existing bounded
# Secrets harness. No private input, network, sleeps or per-variant workspace.
$config = @{ PUBLIC_CONFIG_KEYS = 'MODEL_1_ID,API_KEY' }
. (Join-Path (Split-Path -Parent $Hook) '_classify.ps1')
$modelValue = 'SyntheticPublicModelIdentifier2026'
$sourcePath = Join-Path $Work '.env'
$discoveredModel = @{ MODEL_1_ID = [pscustomobject]@{ Value = $modelValue; Source = '.env'; SourcePath = $sourcePath; Classification = 'PublicConfig' } }
$autoBlock = "## MODEL_1_ID`n- Purpose: TODO - describe what this secret is used for`n- Used by: (auto-detected from .env; update if used elsewhere)`n- Source: $sourcePath`n- Created: 2026-10-03 (auto-added by Secrets-Check)`n- Value: $modelValue`n`n"
$manualBlock = "## MANUAL_SECRET`n- Purpose: user-owned`n- Value: synthetic-retained-value`n"
$prefix = "# Secrets`n`nLocal-only registry.`n`n"
$cleaned = Remove-StalePublicConfigEntries ($prefix + $autoBlock + $manualBlock) $discoveredModel
Check 'model cleanup removes only the identical original generated public block' ($cleaned.Content -ceq ($prefix + $manualBlock) -and @($cleaned.Removed).Count -eq 1)
foreach ($variant in @('old-token', 'different-value', 'edited-purpose', 'extra-note', 'duplicate-value', 'missing-value', 'manual-marker', 'different-source')) {
    $block = switch ($variant) {
        'old-token' { $autoBlock.Replace($modelValue, 'ghp_SYNTHETICabcdefghijklmnopqrst2026') }
        'different-value' { $autoBlock.Replace($modelValue, 'OtherPublicModelIdentifier2026') }
        'edited-purpose' { $autoBlock.Replace('TODO - describe what this secret is used for', 'user description') }
        'extra-note' { $autoBlock + 'Keep this note.' }
        'duplicate-value' { $autoBlock + '- Value: another-value' }
        'missing-value' { $autoBlock.Replace('- Value: ' + $modelValue, '') }
        'manual-marker' { "## MODEL_1_ID`n- Purpose: user-owned (auto-added by Secrets-Check)`n- Value: $modelValue`n" }
        'different-source' { $autoBlock.Replace($sourcePath, 'other.env') }
    }
    $original = $prefix + $block + $manualBlock
    $result = Remove-StalePublicConfigEntries $original $discoveredModel
    Check ($variant + ' registry block is retained byte-for-byte') ($result.Content -ceq $original -and @($result.Removed).Count -eq 0)
}
Check 'exact model override corrects only the entropy guess' ((Get-KeyValueClassification MODEL_1_ID $modelValue) -eq 'PublicConfig')
Check 'an API_KEY listed as public remains Secret' ((Get-KeyValueClassification API_KEY 'synthetic-credential') -eq 'Secret')
foreach ($value in @('ghp_SYNTHETICabcdefghijklmnopqrst2026', 'Bearer synthetic-credential', '-----BEGIN PRIVATE KEY-----', 'https://user:syntheticpass@example.invalid', 'https://example.invalid?api_key=synthetic')) {
    Check 'definite credential value under model key outranks public override' ((Get-KeyValueClassification MODEL_1_ID $value) -eq 'Secret')
}
$secretKeyOverrides = @('MODEL_1_ID')
Check 'explicit secret model key beats the public override' ((Get-KeyValueClassification MODEL_1_ID $modelValue) -eq 'Secret')
$secretKeyOverrides = @(); $publicConfigKeyOverrides = @()
Check 'unconfigured model key remains conservative Secret' ((Get-KeyValueClassification MODEL_1_ID $modelValue) -eq 'Secret')
if ($PublicModelOnly) { return }

Write-Host '--- exact model configuration: Stop and native pre-push ---' -ForegroundColor Cyan
$modelHook = New-ConfiguredHookCopy @{ PUBLIC_CONFIG_KEYS = 'MODEL_1_ID,API_KEY'; COOLDOWN_MINUTES = '0' }
$modelRepo = New-GitProj 'PublicModelExample'
Write-Utf8 (Join-Path $modelRepo '.gitignore') ".env`nsecrets.md`n"
Write-Utf8 (Join-Path $modelRepo '.env') ("MODEL_1_ID=$modelValue`n")
Write-Utf8 (Join-Path $modelRepo 'example.json') ('{"model":"' + $modelValue + '"}')
Add-Commit $modelRepo 'public model example'
$registryPath = Join-Path $modelRepo 'secrets.md'
$modelBlock = $autoBlock.Replace($sourcePath, (Join-Path $modelRepo '.env'))
Write-Utf8 $registryPath ($prefix + $modelBlock + $manualBlock)
$r = Fire -Cwd $modelRepo -HookPath $modelHook -EventName Stop
Check 'Stop public model example does not block or report a value leak' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision"|appears in a git-tracked file' -and $r.Err -eq '')
Check 'Stop safely removes stale auto model and retains manual entry' ([IO.File]::ReadAllText($registryPath, [Text.Encoding]::UTF8) -ceq ($prefix + $manualBlock))
# Reset only this synthetic registry to exercise cleanup independently in native.
Write-Utf8 $registryPath ($prefix + $modelBlock + $manualBlock)
$r = FireGitPrePush -Cwd $modelRepo -HookPath $modelHook -StdinText (Get-RefUpdateLine -Repo $modelRepo)
Check 'native public outgoing model example passes with stale registry' ($r.Exit -eq 0 -and $r.Err -notmatch 'CRITICAL|incomplete')
Check 'native safely removes stale auto model and retains manual entry' ([IO.File]::ReadAllText($registryPath, [Text.Encoding]::UTF8) -ceq ($prefix + $manualBlock))
foreach ($credential in @(@{ Key = 'MODEL_1_ID'; Value = 'ghp_SYNTHETICabcdefghijklmnopqrst2026' }, @{ Key = 'API_KEY'; Value = 'synthetic-api-credential-2026' })) {
    # Each leak has its own repository/session gate; a previous Stop block must
    # not make the next negative control silently stand down.
    $modelRepo = New-GitProj ('CredentialModel-' + $credential.Key)
    Write-Utf8 (Join-Path $modelRepo '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $modelRepo '.env') ($credential.Key + '=' + $credential.Value + "`n")
    Write-Utf8 (Join-Path $modelRepo 'example.json') ('{"value":"' + $credential.Value + '"}')
    Add-Commit $modelRepo 'synthetic credential leak'
    $r = Fire -Cwd $modelRepo -HookPath $modelHook -EventName Stop
    Check ($credential.Key + ' public override cannot prevent Stop leak block') ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -notlike ('*' + $credential.Value + '*') -and $r.Err -eq '')
    $r = FireGitPrePush -Cwd $modelRepo -HookPath $modelHook -StdinText (Get-RefUpdateLine -Repo $modelRepo)
    Check ($credential.Key + ' public override cannot prevent native leak block') ($r.Exit -ne 0 -and $r.Err -match 'CRITICAL' -and $r.Err -notlike ('*' + $credential.Value + '*'))
}
