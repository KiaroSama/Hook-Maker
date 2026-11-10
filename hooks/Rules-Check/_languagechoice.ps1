# Prompt-only advisory. A language assessment never authorizes a migration.
function Get-LanguageDecisionCategory {
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt.Length -gt 32768) { return '' }
    $faNew = -join ([char[]]@(0x067E,0x0631,0x0648,0x0698,0x0647,0x0020,0x062C,0x062F,0x06CC,0x062F))
    $faLanguage = -join ([char[]]@(0x0627,0x0646,0x062A,0x062E,0x0627,0x0628,0x0020,0x0632,0x0628,0x0627,0x0646))
    $faMigration = -join ([char[]]@(0x0645,0x0647,0x0627,0x062C,0x0631,0x062A))
    if ($Prompt -match '(?i)\b(migrate|migration|rewrite)\b.{0,100}\b(language|rust|python|typescript|javascript|kotlin|swift|c#|c\+\+|golang)\b|\bport\b.{0,60}\b(?:from|to)\s+(?:rust|python|typescript|javascript|kotlin|swift|c#|c\+\+|golang)\b' -or $Prompt.Contains($faMigration)) { return 'migration' }
    if ($Prompt -match '(?i)\b(choose|select|pick|which|decide|switch)\b.{0,60}\b(language|stack|framework)\b|\b(language|stack|framework)\b.{0,60}\b(choose|select|pick|decide|switch)\b' -or $Prompt.Contains($faLanguage)) { return 'language' }
    if ($Prompt -match '(?i)\b(new|start|scaffold|initialize)\b.{0,40}\b(project|application|app|service|cli|website)\b' -or $Prompt.Contains($faNew)) { return 'new-project' }
    if ($Prompt -match '(?i)\b(design|choose|build|create|target|support)\b.{0,70}\b(native|cross-platform|tauri|android|ios|macos|windows gui|linux|web ui)\b') { return 'platform-boundary' }
    return ''
}

function Get-LanguageChoiceReminder {
    param($HookInput, [string]$Client, [string]$ProjectRoot, [string]$StateDir, $PolicyEntries)
    if ([string](Get-Field $HookInput 'hook_event_name') -ne 'UserPromptSubmit') { return '' }
    $category = Get-LanguageDecisionCategory ([string](Get-Field $HookInput 'prompt'))
    if ($category -eq '') { return '' }
    $policyState = @($PolicyEntries.Keys | Where-Object { [IO.Path]::GetFileName($_) -in @('global-architecture-rules.md','global-installed-skill-contracts.md','global-skill-routing.md') } | Sort-Object | ForEach-Object { $PolicyEntries[$_] }) -join '|'
    $note = 'LANGUAGE: BEFORE selection global-architecture-rules.md FULL. Narrow fix keeps stack; migration/runtime/framework: separate consent, then global-installed-skill-contracts.md FULL/translate-programming-language. No execution; technical English/reply user-language.'
    $path = Join-Path $StateDir ('RulesCheck-language-' + $Client + '-' + $category + '-' + (Get-ShortHash $ProjectRoot.ToLowerInvariant()) + '.json')
    $claim = Invoke-DeliveryClaim -Path $path -Identity (Get-DeliveryIdentity $HookInput) -Fingerprint (Get-ShortHash ($category + '|' + $policyState + '|' + $note))
    if (-not $claim.Ok) { return 'Language reminder reservation is unverified; no language decision or approval was recorded.' }
    if (-not $claim.Admitted) { return '' }
    return $note
}
