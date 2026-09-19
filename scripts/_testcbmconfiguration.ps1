# CMM configuration/advice regressions. Only fabricated profiles and cache files
# are used; source helpers and hook entry points run without a CMM service.
Write-Host '--- matching CMM records, Codex TOML and recovery advice ---' -ForegroundColor Cyan
$savedCbmEnvironment = @{}
foreach ($key in @('USERPROFILE', 'CODEX_HOME', 'LOCALAPPDATA', 'HOOKMAKER_CLIENT', 'CBM_CACHE_DIR', 'CBM_RUNTIME_DIR')) {
    $savedCbmEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $env:USERPROFILE = Join-Path $Work 'profile'
    $env:CODEX_HOME = Join-Path $Work 'codex home'
    $env:LOCALAPPDATA = Join-Path $Work 'local'
    $env:CBM_CACHE_DIR = ''; $env:CBM_RUNTIME_DIR = ''; $env:HOOKMAKER_CLIENT = 'codex'
    $cacheValue = Join-Path $Work ('service space ' + [char]0x0645 + '\cache')
    $runtimeValue = Join-Path $Work "service's runtime"
    $tempValue = Join-Path $Work 'service temp $()'
    $commandValue = Join-Path $Work "service's bin\codebase-memory-mcp.exe"
    $server = @{ command = $commandValue; args = @('--label', "literal 'argument' `$()")
        env = @{ CBM_CACHE_DIR = $cacheValue; CBM_RUNTIME_DIR = $runtimeValue; TEMP = $tempValue; TMP = $tempValue } }
    $jsonPath = Join-Path $Work 'matching.json'
    Write-Utf8 $jsonPath (@{mcpServers=@{ 'codebase-memory-mcp'=$server }} | ConvertTo-Json -Depth 8)
    $wrongPath = Join-Path $Work 'wrong-first.json'
    Write-Utf8 $wrongPath ('{"mcpServers":{"aaa-other":{"env":{"CBM_CACHE_DIR":"C:\\wrong-server"}},"codebase-memory-mcp":' +
        ($server | ConvertTo-Json -Depth 5 -Compress) + '}}')
    Check 'CMM cache belongs to the selected server, never its earlier neighbor' (
        (Get-CbmCacheDirFromClientConfig -ConfigPaths @($wrongPath)) -eq $cacheValue)
    Write-Utf8 $wrongPath '{"mcpServers":{"aaa-other":{"env":{"CBM_CACHE_DIR":"C:\\wrong-server"}}}}'
    Check 'an unrelated server cannot supply a CMM cache' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($wrongPath)) -eq '')
    Write-Utf8 $wrongPath '{"mcpServers":{"codebase-memory-mcp":{"env":{}},"next":{"command":"wrong.exe"}}}'
    Check 'a missing CMM command cannot consume the next server command' ((Get-CbmServerCommandFromClientConfig -ConfigPaths @($wrongPath)) -eq '')

    $badPath = Join-Path $Work 'malformed.json'
    Write-Utf8 $badPath '{"mcpServers":{"codebase-memory-mcp":{"command":"wrong.exe","env":{"CBM_CACHE_DIR":"C:\\wrong"}}}'
    Check 'malformed JSON supplies neither cache nor executable' (
        (Get-CbmCacheDirFromClientConfig -ConfigPaths @($badPath)) -eq '' -and
        (Get-CbmServerCommandFromClientConfig -ConfigPaths @($badPath)) -eq '')
    $locked = [System.IO.File]::Open($jsonPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { Check 'an unreadable client config degrades without a value' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($jsonPath)) -eq '') }
    finally { $locked.Dispose() }
    $casePath = Join-Path $Work 'case-distinct.json'
    Write-Utf8 $casePath ('{"projects":{"C:/Repo":{},"c:/Repo":{}},"mcpServers":{"codebase-memory-mcp":' + ($server | ConvertTo-Json -Depth 5 -Compress) + '}}')
    Check 'case-distinct unrelated JSON keys do not hide the CMM record' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($casePath)) -eq $cacheValue)
    $invalidUtf8 = Join-Path $Work 'invalid-utf8.json'
    [System.IO.File]::WriteAllBytes($invalidUtf8, [byte[]]@(123, 255, 125))
    Check 'invalid UTF-8 is rejected without returning fabricated paths' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($invalidUtf8)) -eq '')

    # Claude resolves the same server as local > project > user. Local keys
    # identify the project path, including equivalent Windows spellings.
    $env:HOOKMAKER_CLIENT = 'claude'
    $claudeProject = Join-Path $Work ('claude project ' + [char]0x0645)
    $claudeProfilePath = Join-Path $env:USERPROFILE '.claude.json'
    $claudeProjectPath = Join-Path $claudeProject '.mcp.json'
    $localKey = $claudeProject.Replace('\', '/').ToUpperInvariant() + '/'
    $userServer = @{command='user-cmm.exe';env=@{CBM_CACHE_DIR='C:\user-cache';CBM_RUNTIME_DIR='C:\user-runtime'}}
    $projectServer = @{command='project-cmm.exe';env=@{CBM_CACHE_DIR='C:\project-cache'}}
    $localServer = @{command='local-cmm.exe';args=@('--local');env=@{CBM_CACHE_DIR='C:\local-cache';TEMP='C:\local-temp'}}
    $claudeProfile = @{mcpServers=@{'codebase-memory-mcp'=$userServer};projects=@{
        ($claudeProject + '-other')=@{mcpServers=@{'codebase-memory-mcp'=@{enabled=$false;env=@{CBM_CACHE_DIR='C:\unrelated-cache'}}}}
        $localKey=@{mcpServers=@{'codebase-memory-mcp'=$localServer}}
    }}
    try {
        Write-Utf8 $claudeProjectPath (@{mcpServers=@{'codebase-memory-mcp'=$projectServer}} | ConvertTo-Json -Depth 8)
        Write-Utf8 $claudeProfilePath ($claudeProfile | ConvertTo-Json -Depth 10)
        $selected = Get-CbmServerConfig -ProjectRoot $claudeProject
        Check 'Claude local scope overrides both project and user with one complete record' (
            $null -ne $selected -and $selected.Command -eq 'local-cmm.exe' -and
            @($selected.Arguments).Count -eq 1 -and $selected.Arguments[0] -eq '--local' -and
            $selected.Environment['CBM_CACHE_DIR'] -eq 'C:\local-cache' -and
            $selected.Environment['TEMP'] -eq 'C:\local-temp' -and -not $selected.Environment.ContainsKey('CBM_RUNTIME_DIR'))
        $selected = Get-CbmServerConfig -ConfigPaths @($claudeProfilePath) -ProjectRoot ($claudeProject + '\.')
        Check 'Claude local project keys match normalized case, slash and trailing-separator variants' (
            $null -ne $selected -and $selected.Command -eq 'local-cmm.exe')
        $claudeProfile.Remove('mcpServers')
        Write-Utf8 $claudeProfilePath ($claudeProfile | ConvertTo-Json -Depth 10)
        $selected = Get-CbmServerConfig -ConfigPaths @($claudeProfilePath) -ProjectRoot $claudeProject
        Check 'Claude local-only profiles resolve without a top-level mcpServers map' (
            $null -ne $selected -and $selected.Environment['CBM_CACHE_DIR'] -eq 'C:\local-cache')
        $claudeProfile.mcpServers = @{'codebase-memory-mcp'=$userServer}
        $localServer.enabled = $false
        Write-Utf8 $claudeProfilePath ($claudeProfile | ConvertTo-Json -Depth 10)
        Check 'a disabled Claude local record cannot fall through or be re-enabled by a cache override' (
            (Get-CbmCacheDir -Config @{CBM_CACHE_DIR='C:\override'} -ProjectRoot $claudeProject) -eq '')
        $claudeProfile.projects.Remove($localKey)
        Write-Utf8 $claudeProfilePath ($claudeProfile | ConvertTo-Json -Depth 10)
        $selected = Get-CbmServerConfig -ProjectRoot $claudeProject
        Check 'Claude project scope overrides user scope and ignores another project disable' (
            $null -ne $selected -and -not $selected.Disabled -and $selected.Command -eq 'project-cmm.exe' -and
            $selected.Environment['CBM_CACHE_DIR'] -eq 'C:\project-cache')
        $projectServer.enabled = $false
        Write-Utf8 $claudeProjectPath (@{mcpServers=@{'codebase-memory-mcp'=$projectServer}} | ConvertTo-Json -Depth 8)
        Check 'a disabled Claude project record cannot fall through to its enabled user record' (
            (Get-CbmCacheDir -Config @{} -ProjectRoot $claudeProject) -eq '')
        Remove-Item -LiteralPath $claudeProjectPath -Force
        $selected = Get-CbmServerConfig -ProjectRoot $claudeProject
        Check 'Claude user scope remains the fallback when the matching local and project records are absent' (
            $null -ne $selected -and $selected.Environment['CBM_CACHE_DIR'] -eq 'C:\user-cache')
        $claudeProfile.Remove('mcpServers')
        Write-Utf8 $claudeProfilePath ($claudeProfile | ConvertTo-Json -Depth 10)
        Check 'an unrelated Claude project supplies neither a CMM record nor its environment' (
            $null -eq (Get-CbmServerConfig -ConfigPaths @($claudeProfilePath) -ProjectRoot $claudeProject))
    }
    finally {
        foreach ($path in @($claudeProfilePath, $claudeProjectPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        $env:HOOKMAKER_CLIENT = 'codex'
    }

    $tomlPath = Join-Path $env:CODEX_HOME 'config.toml'
    $toml = @'
[mcp_servers.aaa-other]
command = 'wrong.exe'
[mcp_servers.aaa-other.env]
CBM_CACHE_DIR = 'C:\wrong-server'
[mcp_servers."codebase-memory-mcp"]
enabled = true
command = __COMMAND__
args = [
  '--label', # preserved literal argument
  "literal 'argument' $()",
]
[mcp_servers."codebase-memory-mcp".env]
CBM_CACHE_DIR = __CACHE__
CBM_RUNTIME_DIR = __RUNTIME__
TEMP = __TEMP__
TMP = __TEMP__
'@
    foreach ($pair in @(@('__COMMAND__', $commandValue), @('__CACHE__', $cacheValue), @('__RUNTIME__', $runtimeValue), @('__TEMP__', $tempValue))) {
        $toml = $toml.Replace($pair[0], ($pair[1] | ConvertTo-Json -Compress))
    }
    Write-Utf8 $tomlPath $toml
    Check 'Codex TOML resolves the matching cache with spaces and Unicode' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($tomlPath)) -eq $cacheValue)
    Check 'Codex TOML resolves its own executable' ((Get-CbmServerCommandFromClientConfig -ConfigPaths @($tomlPath)) -eq $commandValue)
    Check 'a Codex-only machine discovers config.toml without Claude JSON' ((Get-CbmCacheDir -Config @{}) -eq $cacheValue)
    $overrideProj = Join-Path $Work 'project override'
    Write-Utf8 (Join-Path $overrideProj '.codex\config.toml') "[mcp_servers.codebase-memory-mcp]`ncommand = 'codebase-memory-mcp.exe'`n[mcp_servers.codebase-memory-mcp.env]`nCBM_CACHE_DIR = 'C:\project-cache'`n"
    Check 'a project-scoped Codex CMM record overrides its user-level record' ((Get-CbmCacheDir -Config @{} -ProjectRoot $overrideProj) -eq 'C:\project-cache')
    $inlineToml = Join-Path $Work 'inline.toml'
    Write-Utf8 $inlineToml "[mcp_servers.codebase-memory-mcp]`ncommand = 'codebase-memory-mcp.exe'`nenv = { CBM_CACHE_DIR = 'C:\inline cache', TEMP = 'C:\inline temp' }`n"
    Check 'Codex inline environment tables stay attached to the CMM record' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($inlineToml)) -eq 'C:\inline cache')
    $env:CBM_CACHE_DIR = 'C:\process-override'
    Check 'process cache override still beats a configured CMM server' ((Get-CbmCacheDir -Config @{}) -eq 'C:\process-override')
    Check 'hook cache override still beats both process and configured server' ((Get-CbmCacheDir -Config @{CBM_CACHE_DIR='C:\hook-override'}) -eq 'C:\hook-override')
    $env:CBM_CACHE_DIR = ''
    $env:CBM_RUNTIME_DIR = 'C:\runtime-override'
    $resolvedService = Get-CbmServiceConfig -Config @{} -ClientConfigPaths @($jsonPath)
    Check 'an explicit process runtime override wins over the server record' ($resolvedService.Environment['CBM_RUNTIME_DIR'] -eq 'C:\runtime-override')
    $resolvedService = Get-CbmServiceConfig -Config @{CBM_RUNTIME_DIR='C:\hook-runtime';TEMP='C:\hook-temp'} -ClientConfigPaths @($jsonPath)
    Check 'hook runtime and temp overrides remain authoritative' (
        $resolvedService.Environment['CBM_RUNTIME_DIR'] -eq 'C:\hook-runtime' -and $resolvedService.Environment['TEMP'] -eq 'C:\hook-temp')
    $env:CBM_RUNTIME_DIR = ''
    $literalPath = Join-Path $Work 'literal.toml'
    Write-Utf8 $literalPath "[mcp_servers.codebase-memory-mcp]`ncommand = 'C:\literal path\codebase-memory-mcp.exe'`n[mcp_servers.codebase-memory-mcp.env]`nCBM_CACHE_DIR = 'C:\literal path\cache'`n"
    Check 'TOML literal Windows paths keep their backslashes' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($literalPath)) -eq 'C:\literal path\cache')
    Write-Utf8 $literalPath '[mcp_servers.codebase-memory-mcp.env'
    Check 'malformed TOML degrades without borrowing other values' ((Get-CbmCacheDirFromClientConfig -ConfigPaths @($literalPath)) -eq '')

    Write-Utf8 (Join-Path $cacheValue '_config.db') 'fixture'
    Write-Utf8 $commandValue 'NON-EXECUTABLE FIXTURE: hooks must never launch CMM.'
    $configuredProj = Join-Path $Work 'configured project'
    New-Item -ItemType Directory -Path $configuredProj -Force | Out-Null
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{hook_event_name='SessionStart';cwd=$configuredProj;session_id='configured-cmm'} ''
    $message = ''
    try { $message = [string](($r.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext) } catch { }
    Check 'Codex-only hooks find the configured service and remain non-blocking' ($r.Exit -eq 0 -and $message -match 'CBM READ CHECK') $r.Out
    foreach ($key in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) {
        $expected = "`$env:" + $key + " = '" + ([string]$server.env[$key]).Replace("'", "''") + "'"
        Check ('CLI advice preserves the configured ' + $key) ($message.Contains($expected))
    }
    Check 'CLI advice quotes the executable and configured argument as PowerShell literals' (
        $message.Contains("& '" + $commandValue.Replace("'", "''") + "'") -and
        $message.Contains("'literal ''argument'' `$()'"))
    Check 'recovery distinguishes approval, slash mismatch, sandbox denial and private ancestors' (
        $message -match 'absent approval' -and $message -match 'separator-sensitive' -and
        $message -match 'OS/sandbox' -and $message -match 'cache-private')
    Check 'guidance contains no unconditional restart or STOP claim' (
        $message -ne '' -and $message -notmatch 'Then STOP|restart is required|server only reads.*start')
    Check 'index guidance includes persistence' ($message -match 'persistence=true')
    $resolvedService = Get-CbmServiceConfig -Config @{} -ClientConfigPaths @($jsonPath)
    $cliAdvice = Get-CbmCliAdvice -Service $resolvedService -Arguments @('allow-root', '--list')
    $tokens = $null; $parseErrors = $null
    $adviceAst = [System.Management.Automation.Language.Parser]::ParseInput($cliAdvice, [ref]$tokens, [ref]$parseErrors)
    Check 'quoted advice parses without any interpolated subexpression' (
        $parseErrors.Count -eq 0 -and @($adviceAst.FindAll({param($n) $n -is [System.Management.Automation.Language.SubExpressionAst]}, $true)).Count -eq 0)
    $resolvedService.Arguments = @('--token', 'synthetic-sensitive-fixture')
    Check 'credential-like configured arguments are withheld from CLI advice' ((Get-CbmCliAdvice -Service $resolvedService -Arguments @('allow-root', '--list')) -eq '')
    $resolvedService.Arguments = @('server-script')
    foreach ($unknownProgram in @('python.exe', 'node.exe', 'custom-cmm.exe')) {
        $resolvedService.Command = $unknownProgram
        Check ('unknown ' + $unknownProgram + ' dispatch is not treated as the raw CMM CLI') (
            (Get-CbmCliAdvice -Service $resolvedService -Arguments @('allow-root', '--list')) -eq '')
    }
    $badEnabledPath = Join-Path $Work 'bad-enabled.toml'
    foreach ($badEnabled in @('"false"', '0', 'TRUE')) {
        Write-Utf8 $badEnabledPath ("[mcp_servers.codebase-memory-mcp]`ncommand = 'codebase-memory-mcp.exe'`nenabled = " + $badEnabled + "`n")
        Check ('TOML enabled rejects the non-boolean value ' + $badEnabled) (
            $null -eq (Get-CbmServerConfig -ConfigPaths @($badEnabledPath)))
    }

    Write-Utf8 (Get-CbmProjectDbPath -ProjectRoot $configuredProj -CacheDir $cacheValue) 'fixture'
    Write-Utf8 (Join-Path $configuredProj 'graphify-out\graph.json') '{}'
    & git -C $configuredProj init -q
    & git -C $configuredProj config user.email 'test@example.invalid'
    & git -C $configuredProj config user.name 'Test'
    Write-Utf8 (Join-Path $configuredProj 'app.txt') 'fixture'
    & git -C $configuredProj add app.txt
    & git -C $configuredProj commit -q -m fixture
    [System.IO.File]::SetLastWriteTimeUtc((Join-Path $configuredProj 'graphify-out\graph.json'), [DateTime]::UtcNow.AddHours(-1))
    [System.IO.File]::SetLastWriteTimeUtc((Get-CbmProjectDbPath -ProjectRoot $configuredProj -CacheDir $cacheValue), [DateTime]::UtcNow.AddHours(-1))
    $r = Invoke-CbmHook 'Cbm-Update-Check\Cbm-Update-Check.ps1' @{hook_event_name='Stop';cwd=$configuredProj;session_id='configured-update'} ''
    Check 'CMM freshness checks use the configured Codex cache and stay advisory' (
        $r.Exit -eq 0 -and $r.Out -match 'CBM UPDATE CHECK' -and $r.Out -notmatch '"decision":"block"') $r.Out
    foreach ($hookName in @('Graph-Read-Check', 'Graph-Update-Check')) {
        $event = if ($hookName -eq 'Graph-Read-Check') {'SessionStart'} else {'Stop'}
        $r = Invoke-CbmHook ($hookName + '\' + $hookName + '.ps1') @{hook_event_name=$event;cwd=$configuredProj;session_id=$hookName} ''
        Check ($hookName + ' still speaks beside the Codex-configured CMM index') (
            $r.Exit -eq 0 -and $r.Out -match ($hookName.Replace('-', ' ').ToUpperInvariant())) $r.Out
    }
    Write-Utf8 (Join-Path $configuredProj '.codex\config.toml') "[mcp_servers.codebase-memory-mcp]`nenabled = false`n"
    Check 'a disabled project CMM record cannot fall back to the enabled global record' (
        (Get-CbmCacheDir -Config @{} -ProjectRoot $configuredProj) -eq '')
    Check 'a cache override cannot re-enable an explicitly disabled CMM server' (
        (Get-CbmCacheDir -Config @{CBM_CACHE_DIR=$cacheValue} -ProjectRoot $configuredProj) -eq '')
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{hook_event_name='SessionStart';cwd=$configuredProj;session_id='disabled-read'} ''
    Check 'explicitly disabled CMM produces no read advice' ($r.Exit -eq 0 -and $r.Out.Trim() -eq '') $r.Out
    $cooldownPath = Join-Path $env:LOCALAPPDATA ('HookMaker\state\CbmUpdateCheck-' + (Get-ShortHash $configuredProj.ToLowerInvariant()) + '.txt')
    Write-Utf8 $cooldownPath ([DateTime]::UtcNow.AddHours(-2).ToString('o'))
    $r = Invoke-CbmHook 'Cbm-Update-Check\Cbm-Update-Check.ps1' @{hook_event_name='Stop';cwd=$configuredProj;session_id='disabled-update'} ''
    Check 'explicitly disabled CMM produces no freshness advice' ($r.Exit -eq 0 -and $r.Out.Trim() -eq '') $r.Out
    # Graph-Update-Check emitted in the loop above (every project keeps BOTH
    # graphs), so its per-project cooldown would mute the case below. Age it,
    # the same way the Cbm-Update-Check case above does.
    Write-Utf8 (Join-Path $env:LOCALAPPDATA ('HookMaker\state\GraphUpdateCheck-' + (Get-ShortHash $configuredProj.ToLowerInvariant()) + '.txt')) ([DateTime]::UtcNow.AddHours(-2).ToString('o'))
    foreach ($hookName in @('Graph-Read-Check', 'Graph-Update-Check')) {
        $event = if ($hookName -eq 'Graph-Read-Check') {'SessionStart'} else {'Stop'}
        $r = Invoke-CbmHook ($hookName + '\' + $hookName + '.ps1') @{hook_event_name=$event;cwd=$configuredProj;session_id=('disabled-' + $hookName)} ''
        Check ($hookName + ' remains active when the project disables CMM') (
            $r.Exit -eq 0 -and $r.Out -match ($hookName.Replace('-', ' ').ToUpperInvariant())) $r.Out
    }
    Check 'the configured CMM executable fixture was never changed' (
        [System.IO.File]::ReadAllText($commandValue, [System.Text.Encoding]::UTF8) -eq 'NON-EXECUTABLE FIXTURE: hooks must never launch CMM.')
    $tokens = $null; $parseErrors = $null
    $libraryAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $HooksRoot '_hooklib.ps1'), [ref]$tokens, [ref]$parseErrors)
    $executionCalls = @($libraryAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match 'Cbm'}, $true) |
        ForEach-Object { $_.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
            ($n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -or $n.GetCommandName() -in @('Start-Process','Invoke-QuietCommand','Invoke-Expression'))}, $true) })
    Check 'CMM configuration helpers never execute commands or the CMM service' ($executionCalls.Count -eq 0)
}
finally {
    foreach ($key in $savedCbmEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedCbmEnvironment[$key]) }
}
