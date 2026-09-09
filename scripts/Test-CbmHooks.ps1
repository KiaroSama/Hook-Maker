# Offline suite for the two Codebase Memory hooks and the shared CBM helpers
# in _hooklib.ps1, plus the coordination guard that makes Graph-Read-Check
# yield to them.
#
# Everything runs against a FABRICATED cache directory: the hooks only ever
# look at <cache>\_config.db and <cache>\<project>.db, so a real Codebase
# Memory server is never needed - and must never be, or the suite would depend
# on whether the developer happens to have indexed this repo.
#
# Exit code is the number of failed assertions (0 = all passed).

[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$HooksRoot = Join-Path $ToolRoot 'hooks'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $ScriptRoot '_testlib.ps1')
. (Join-Path $HooksRoot '_hooklib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-cbm'

function Invoke-CbmHook {
    param(
        [Parameter(Mandatory = $true)][string]$HookRelativePath,
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [Parameter(Mandatory = $true)][string]$CacheDir
    )
    $json = ($Payload | ConvertTo-Json -Depth 8 -Compress)
    $previous = $env:CBM_CACHE_DIR
    $env:CBM_CACHE_DIR = $CacheDir
    try {
        $out = ($json | & pwsh -NoProfile -File (Join-Path $HooksRoot $HookRelativePath) 2>&1) -join "`n"
        return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
    }
    finally { $env:CBM_CACHE_DIR = $previous }
}

try {
    # =====================================================================
    Write-Host '--- the derived project name matches a real CBM database name ---' -ForegroundColor Cyan
    # Pinned to the sample verified on 2026-09-06 by indexing a real directory
    # and reading back the file CBM created. If CBM ever changes its
    # normalisation this assertion is the thing that notices.
    $verifiedRoot = 'C:\Users\example\AppData\Local\Temp\claude\G--Program-Files-Portable-Scripts-Hook-Maker\00000000-0000-4000-8000-000000000000\scratchpad\cbm name probe'
    $verifiedName = 'C-Users-example-AppData-Local-Temp-claude-G-Program-Files-Portable-Scripts-Hook-Maker-00000000-0000-4000-8000-000000000000-scratchpad-cbm-name-probe'
    Check 'cbm: the verified real-world sample is reproduced exactly' (
        (Get-CbmProjectName -ProjectRoot $verifiedRoot) -eq $verifiedName) (Get-CbmProjectName -ProjectRoot $verifiedRoot)
    Check 'cbm: a doubled separator collapses to ONE dash' (
        (Get-CbmProjectName -ProjectRoot 'G:\a--b') -eq 'G-a-b') (Get-CbmProjectName -ProjectRoot 'G:\a--b')
    Check 'cbm: a space becomes a dash' (
        (Get-CbmProjectName -ProjectRoot 'C:\my project') -eq 'C-my-project') (Get-CbmProjectName -ProjectRoot 'C:\my project')
    Check 'cbm: leading and trailing separators are trimmed' (
        (Get-CbmProjectName -ProjectRoot '\\srv\share\p\') -eq 'srv-share-p') (Get-CbmProjectName -ProjectRoot '\\srv\share\p\')

    # =====================================================================
    Write-Host '--- cache directory resolution: .env, then env var, then default ---' -ForegroundColor Cyan
    $previousEnv = $env:CBM_CACHE_DIR
    try {
        $env:CBM_CACHE_DIR = 'G:\from-env'
        Check 'cbm: .env wins over the environment variable' (
            (Get-CbmCacheDir -Config @{ 'CBM_CACHE_DIR' = 'G:\from-dotenv' }) -eq 'G:\from-dotenv') (Get-CbmCacheDir -Config @{ 'CBM_CACHE_DIR' = 'G:\from-dotenv' })
        Check 'cbm: an empty .env value falls through to the environment' (
            (Get-CbmCacheDir -Config @{ 'CBM_CACHE_DIR' = '  ' }) -eq 'G:\from-env') (Get-CbmCacheDir -Config @{ 'CBM_CACHE_DIR' = '  ' })
        $env:CBM_CACHE_DIR = ''
        # A fabricated client config, never the developer's own: the real
        # ~/.claude.json holds whichever MCP servers that machine happens to
        # have, so reading it here would make the result depend on the machine.
        $missingConfig = Join-Path $Work 'no-such-client-config.json'
        Check 'cbm: with nothing set anywhere it is the binary default under the profile' (
            (Get-CbmCacheDir -Config @{} -ClientConfigPaths @($missingConfig)) -eq (Join-Path $env:USERPROFILE '.cache\codebase-memory-mcp'))

        # The step that was missing entirely: CBM_CACHE_DIR is normally set only
        # inside the MCP server's own env block in the client config, so the
        # server has it and a hook process never does. Before this, the hook
        # watched the binary default while the server wrote somewhere else and
        # "no index yet" was reported for ever.
        $clientConfig = Join-Path $Work 'client-config.json'
        # Single-quoted here, so what lands in the file is exactly these bytes:
        # JSON "G:\\Server\\cache", i.e. the path G:\Server\cache once unescaped.
        Write-Utf8 $clientConfig '{"mcpServers":{"codebase-memory-mcp":{"command":"cbm.exe","env":{"CBM_CACHE_DIR":"G:\\Server\\cache"}}}}'
        Check 'cbm: the cache dir is read from the MCP server record in the client config' (
            (Get-CbmCacheDir -Config @{} -ClientConfigPaths @($clientConfig)) -eq 'G:\Server\cache') (Get-CbmCacheDir -Config @{} -ClientConfigPaths @($clientConfig))
        Check 'cbm: the .env override still beats the client config' (
            (Get-CbmCacheDir -Config @{ 'CBM_CACHE_DIR' = 'G:\from-dotenv' } -ClientConfigPaths @($clientConfig)) -eq 'G:\from-dotenv')
        $env:CBM_CACHE_DIR = 'G:\from-env'
        Check 'cbm: the environment variable still beats the client config' (
            (Get-CbmCacheDir -Config @{} -ClientConfigPaths @($clientConfig)) -eq 'G:\from-env')
        $env:CBM_CACHE_DIR = ''

        # A config with no CBM server at all must not hand back a stray match
        # from some other server's env block.
        $otherConfig = Join-Path $Work 'client-config-other.json'
        Write-Utf8 $otherConfig '{"mcpServers":{"something-else":{"env":{"SOME_TOKEN":"redacted"}}}}'
        Check 'cbm: a client config without the key falls through to the default' (
            (Get-CbmCacheDir -Config @{} -ClientConfigPaths @($otherConfig)) -eq (Join-Path $env:USERPROFILE '.cache\codebase-memory-mcp'))

        # The refusal advice has to name a command that actually RUNS. The CBM
        # binary is not on PATH in a normal install, so quoting the tool's own
        # "run codebase-memory-mcp allow-root ..." fails with "not recognized"
        # for everyone; the server record is where the real path lives.
        Check 'cbm: the server executable is read from the client config' (
            (Get-CbmServerCommandFromClientConfig -ConfigPaths @($clientConfig)) -eq 'cbm.exe') (Get-CbmServerCommandFromClientConfig -ConfigPaths @($clientConfig))
        Check 'cbm: no CBM server in the config yields no command, never another server''s' (
            (Get-CbmServerCommandFromClientConfig -ConfigPaths @($otherConfig)) -eq '') (Get-CbmServerCommandFromClientConfig -ConfigPaths @($otherConfig))
        # Anchored on the server NAME: a different server listed FIRST must not
        # have its command picked up for CBM.
        $twoServers = Join-Path $Work 'client-config-two.json'
        Write-Utf8 $twoServers '{"mcpServers":{"aaa-other":{"command":"wrong.exe"},"codebase-memory-mcp":{"command":"right.exe"}}}'
        Check 'cbm: the command is matched to the CBM server, not the first one listed' (
            (Get-CbmServerCommandFromClientConfig -ConfigPaths @($twoServers)) -eq 'right.exe') (Get-CbmServerCommandFromClientConfig -ConfigPaths @($twoServers))
    }
    finally { $env:CBM_CACHE_DIR = $previousEnv }

    $cache = Join-Path $Work 'cache'
    $proj = Join-Path $Work 'Proj'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    Check 'cbm: not installed until _config.db exists' (-not (Test-CbmInstalled -CacheDir $cache))
    [System.IO.File]::WriteAllText((Join-Path $cache '_config.db'), 'x')
    Check 'cbm: installed once _config.db exists' (Test-CbmInstalled -CacheDir $cache)
    Check 'cbm: a blank cache directory is never "installed"' (-not (Test-CbmInstalled -CacheDir ''))

    # =====================================================================
    Write-Host '--- Cbm-Read-Check ---' -ForegroundColor Cyan
    $emptyCache = Join-Path $Work 'no-cbm'
    New-Item -ItemType Directory -Path $emptyCache -Force | Out-Null
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'a1' } $emptyCache
    Check 'read: completely silent when Codebase Memory is not installed' ($r.Out.Trim() -eq '') $r.Out

    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'a2' } $cache
    # The hook emits JSON, so every backslash in the path arrives DOUBLED. A
    # test that searches for the plain spelling finds nothing and blames the
    # hook - this project has already lost time to exactly that mistake twice.
    $projInJson = [regex]::Escape($proj.Replace(([char]92).ToString(), ([char]92).ToString() + ([char]92).ToString()))
    Check 'read: an unindexed project is told to index once, with the real path' (
        $r.Out -match 'no Codebase Memory index yet' -and $r.Out -match 'index_repository' -and $r.Out -match $projInJson) $r.Out

    $dbPath = Get-CbmProjectDbPath -ProjectRoot $proj -CacheDir $cache
    [System.IO.File]::WriteAllText($dbPath, 'x')
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'a3' } $cache
    Check 'read: an indexed project is told to query before browsing' (
        $r.Out -match 'query the graph BEFORE browsing' -and $r.Out -match 'get_architecture' -and $r.Out -match 'search_graph') $r.Out
    Check 'read: it also says coverage is never proof' ($r.Out -match 'check_index_coverage') $r.Out

    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'a3' } $cache
    Check 'read: the same state does not repeat inside one session' ($r.Out.Trim() -eq '') $r.Out

    # Indexing DURING the session changes the state, so the follow-up note is
    # not suppressed by the earlier one. This is why the fingerprint carries
    # the index state and not just the session id.
    Remove-Item -LiteralPath $dbPath -Force
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'a3' } $cache
    Check 'read: a CHANGED index state speaks again in the same session' ($r.Out -match 'no Codebase Memory index yet') $r.Out
    [System.IO.File]::WriteAllText($dbPath, 'x')

    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = 'a4'; prompt = 'fix the typo in the readme' } $cache
    Check 'read: silent on a prompt that needs no codebase understanding' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = 'a5'; prompt = 'where is this helper used across the codebase' } $cache
    Check 'read: speaks on a structural prompt' ($r.Out -match 'CBM READ CHECK') $r.Out
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'Stop'; cwd = $proj; session_id = 'a6' } $cache
    Check 'read: ignores events it does not own' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-CbmHook 'Cbm-Read-Check\Cbm-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = (Join-Path $Work 'no-such-dir'); session_id = 'a7' } $cache
    Check 'read: silent when cwd does not exist' ($r.Out.Trim() -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Graph-Read-Check yields to Codebase Memory ---' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path (Join-Path $proj 'graphify-out') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $proj 'graphify-out\graph.json'), '{}')
    $r = Invoke-CbmHook 'Graph-Read-Check\Graph-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'g1' } $cache
    Check 'graph: silent when this project has a CBM index' ($r.Out.Trim() -eq '') $r.Out
    Remove-Item -LiteralPath $dbPath -Force
    $r = Invoke-CbmHook 'Graph-Read-Check\Graph-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'g2' } $cache
    Check 'graph: unchanged behaviour when there is no CBM index' ($r.Out -match 'GRAPH READ CHECK') $r.Out
    $r = Invoke-CbmHook 'Graph-Read-Check\Graph-Read-Check.ps1' @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = 'g3' } $emptyCache
    Check 'graph: unchanged behaviour when CBM is not installed at all' ($r.Out -match 'GRAPH READ CHECK') $r.Out
    [System.IO.File]::WriteAllText($dbPath, 'x')

    # =====================================================================
    Write-Host '--- Cbm-Update-Check ---' -ForegroundColor Cyan
    $r = Invoke-CbmHook 'Cbm-Update-Check\Cbm-Update-Check.ps1' @{ hook_event_name = 'Stop'; cwd = $proj; session_id = 'u1'; stop_hook_active = $true } $cache
    Check 'update: honours stop_hook_active (no hook loop)' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-CbmHook 'Cbm-Update-Check\Cbm-Update-Check.ps1' @{ hook_event_name = 'Stop'; cwd = $proj; session_id = 'u2' } $emptyCache
    Check 'update: silent when CBM is not installed' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-CbmHook 'Cbm-Update-Check\Cbm-Update-Check.ps1' @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = 'u3' } $cache
    Check 'update: ignores events it does not own' ($r.Out.Trim() -eq '') $r.Out

    # A project with no index is Cbm-Read-Check's message at the START of a
    # session, not this hook's at the end.
    Remove-Item -LiteralPath $dbPath -Force
    $r = Invoke-CbmHook 'Cbm-Update-Check\Cbm-Update-Check.ps1' @{ hook_event_name = 'Stop'; cwd = $proj; session_id = 'u4' } $cache
    Check 'update: silent when the project is not indexed' ($r.Out.Trim() -eq '') $r.Out
    [System.IO.File]::WriteAllText($dbPath, 'x')

    # A non-git directory has no "newest work" to compare against, so there is
    # nothing this hook can honestly say.
    $r = Invoke-CbmHook 'Cbm-Update-Check\Cbm-Update-Check.ps1' @{ hook_event_name = 'Stop'; cwd = $proj; session_id = 'u5' } $cache
    Check 'update: silent outside a git repository (no work time to compare)' ($r.Out.Trim() -eq '') $r.Out
}
finally {
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
