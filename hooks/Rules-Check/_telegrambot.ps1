# Prompt/manifest advisory for Telegram bot projects. Silent unless a real signal exists.
# Dot-sourced; definitions only, no exit.
$script:TelegramBotPromptPattern = '(?i)telegram\s+bot|bot-clone|setMyCommands|BotCommandScopeChat|/language[^\r\n]{0,40}\bbot\b|telegram[^\r\n]{0,40}log\s+channel|sub-?user\s+bot'
$script:TelegramBotDependencyPattern = '(?i)teloxide|telegraf|grammy|aiogram|python-telegram-bot|pyTelegramBotAPI|node-telegram-bot-api|Telegram\.Bot|telebot|BotCommandScopeChat|setMyCommands'
$script:TelegramBotNote = 'TELEGRAM BOT: every bot role (admin/user/sub-user/sibling) exposes /language, immediately localizes setMyCommands (BotCommandScopeChat) + menus, keeps identical menus across roles, and keeps Telegram log channels English-only.'

function Test-TelegramBotPrompt {
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt.Length -gt 32768) { return $false }
    return ($Prompt -match $script:TelegramBotPromptPattern)
}

# Bounded: root manifests only, 64 KB each, no recursion.
function Test-TelegramBotManifest {
    param([string]$ProjectRoot)
    if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return $false }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('Cargo.toml', 'package.json', 'pyproject.toml', 'requirements.txt', 'go.mod')) {
        $f = Join-Path $ProjectRoot $name
        if (Test-Path -LiteralPath $f -PathType Leaf) { [void]$files.Add($f) }
    }
    try {
        foreach ($f in @([IO.Directory]::GetFiles($ProjectRoot, '*.csproj') | Select-Object -First 5)) { [void]$files.Add($f) }
    }
    catch { }
    foreach ($f in $files) {
        try {
            $fs = [IO.File]::Open($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $buf = New-Object byte[] 65536
                $n = $fs.Read($buf, 0, $buf.Length)
            }
            finally { $fs.Dispose() }
            if ($n -gt 0 -and ([Text.Encoding]::UTF8.GetString($buf, 0, $n) -match $script:TelegramBotDependencyPattern)) { return $true }
        }
        catch { }
    }
    return $false
}

function Test-TelegramBotContext {
    param([string]$Prompt, [string]$ProjectRoot)
    if (Test-TelegramBotPrompt $Prompt) { return $true }
    return (Test-TelegramBotManifest $ProjectRoot)
}

function Get-TelegramBotReminder {
    param($HookInput, [string]$Client, [string]$ProjectRoot, [string]$StateDir)
    if ([string](Get-Field $HookInput 'hook_event_name') -ne 'UserPromptSubmit') { return '' }
    if (-not (Test-TelegramBotContext -Prompt ([string](Get-Field $HookInput 'prompt')) -ProjectRoot $ProjectRoot)) { return '' }
    $path = Join-Path $StateDir ('RulesCheck-telegram-' + $Client + '-' + (Get-ShortHash $ProjectRoot.ToLowerInvariant()) + '.json')
    $claim = Invoke-DeliveryClaim -Path $path -Identity (Get-DeliveryIdentity $HookInput) -Fingerprint (Get-ShortHash $script:TelegramBotNote)
    if (-not $claim.Ok -or -not $claim.Admitted) { return '' }
    return $script:TelegramBotNote
}
