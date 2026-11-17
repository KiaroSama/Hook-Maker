# Test suite for link-aware project roots (spec 039).
#
# A project folder reached through a symbolic link or junction used to become a
# second registry root for the same physical folder: two records for one hook,
# two handler sets in one settings file, and a fleet compare that never agreed.
#
# WHAT IT PINS, against the REAL installer, uninstaller and fleet updater with an
# isolated registry (HOOKMAKER_STATE_DIR in the throwaway workspace):
#   * Resolve-RealDirectoryPath leaves a plain path alone, follows a junction,
#     a junction in a parent folder, keeps a missing tail as text, and follows a
#     broken junction to its recorded target without throwing;
#     Test-PathIsAliasOf tells a link from its own real folder;
#   * an install through a junction records the REAL root and writes handlers
#     that name the real path only;
#   * -ForgetAliasRecord refuses an alias record with no real counterpart;
#   * Update-Fleet announces an alias record on a dry run, and -Apply merges it:
#     one record at the real root, the runtime intact, no handler naming the
#     link, and the sync route repointed with the link kept as an alias;
#   * the runtime-sharer check sees the same folder through both spellings.
#
# -ResolverOnly runs just the resolver block. It needs nothing but
# _pathcanonical.ps1, so CI also runs it on Windows PowerShell 5.1, the host
# Claude's hooks use.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-AliasRoots.ps1 [-KeepArtifacts] [-ResolverOnly]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts, [switch]$ResolverOnly)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$UninstallScript = Join-Path $ScriptRoot 'Uninstall-Hook.ps1'
$Fleet = Join-Path $ScriptRoot 'Update-Fleet.ps1'

. (Join-Path $ScriptRoot '_testlib.ps1')
. (Join-Path $ScriptRoot '_pathcanonical.ps1')

$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray }
    }
}

function Test-SamePath { param([string]$A, [string]$B) return [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase) }

$Work = New-TestWorkspace -Prefix 'hookmaker-aliasroots'
$script:Links = New-Object System.Collections.Generic.List[string]
function New-TestJunction {
    param([string]$Path, [string]$Target)
    $null = New-Item -ItemType Junction -Path $Path -Target $Target
    [void]$script:Links.Add($Path)
    return $Path
}

$savedStateDir = $env:HOOKMAKER_STATE_DIR
$savedLogDir = $env:HOOKMAKER_LOG_DIR
$savedLocalAppData = $env:LOCALAPPDATA

try {
    # ---- resolver ----------------------------------------------------------------
    # The workspace itself may sit under a linked folder on some hosts, so every
    # expectation is built from the resolved workspace, not its plain text.
    $base = Resolve-RealDirectoryPath $Work
    $real = Join-Path $base 'real proj'
    New-Item -ItemType Directory -Path (Join-Path $real 'sub') -Force | Out-Null
    $link = New-TestJunction -Path (Join-Path $base 'link proj') -Target $real
    $outer = Join-Path $base 'outer'
    New-Item -ItemType Directory -Path $outer -Force | Out-Null
    $parentLink = New-TestJunction -Path (Join-Path $base 'parent link') -Target $outer
    New-Item -ItemType Directory -Path (Join-Path $outer 'inner') -Force | Out-Null

    Check 'a plain folder resolves to itself' (Test-SamePath (Resolve-RealDirectoryPath $real) $real)
    Check 'a trailing separator is trimmed' (Test-SamePath (Resolve-RealDirectoryPath ($real + '\')) $real)
    Check 'a junction resolves to its target' (Test-SamePath (Resolve-RealDirectoryPath $link) $real) (Resolve-RealDirectoryPath $link)
    Check 'a folder below a junction resolves under the target' (
        Test-SamePath (Resolve-RealDirectoryPath (Join-Path $link 'sub')) (Join-Path $real 'sub'))
    Check 'a junction in a parent folder resolves' (
        Test-SamePath (Resolve-RealDirectoryPath (Join-Path $parentLink 'inner')) (Join-Path $outer 'inner'))
    Check 'a missing tail below a junction is kept as text' (
        Test-SamePath (Resolve-RealDirectoryPath (Join-Path $link 'no\such')) (Join-Path $real 'no\such'))
    Check 'an empty path is returned unchanged' ((Resolve-RealDirectoryPath '') -eq '')

    $gone = Join-Path $base 'gone target'
    New-Item -ItemType Directory -Path $gone -Force | Out-Null
    $broken = New-TestJunction -Path (Join-Path $base 'broken link') -Target $gone
    Remove-Item -LiteralPath $gone -Force
    $brokenResolved = $null
    $brokenError = ''
    try { $brokenResolved = Resolve-RealDirectoryPath $broken } catch { $brokenError = $_.Exception.Message }
    Check 'a broken junction does not throw and names its recorded target' ($brokenError -eq '' -and (Test-SamePath $brokenResolved $gone)) (
        [string]$brokenResolved + ' ' + $brokenError)

    Check 'Test-PathIsAliasOf: a link is an alias of its target' (Test-PathIsAliasOf -Path $link -RealPath $real)
    Check 'Test-PathIsAliasOf: a real folder is not an alias of itself' (-not (Test-PathIsAliasOf -Path $real -RealPath $real))
    Check 'Test-PathIsAliasOf: a link is not an alias of an unrelated folder' (-not (Test-PathIsAliasOf -Path $link -RealPath $outer))

    # -ResolverOnly stops here; the rest needs the installer libraries.
    if (-not $ResolverOnly) {

        # ---- installer, uninstaller and fleet -----------------------------------------
        . (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
        . (Join-Path $ScriptRoot '_installplan.ps1')
        . (Join-Path $ScriptRoot '_installlib.ps1')
        . (Join-Path $ScriptRoot '_uninstallownership.ps1')

        $env:HOOKMAKER_STATE_DIR = Join-Path $Work 'state'
        $env:HOOKMAKER_LOG_DIR = Join-Path $Work 'logs'
        # Hook coordination state lives under %LOCALAPPDATA%; keep it in the workspace.
        $env:LOCALAPPDATA = Join-Path $Work '_fakelocal'
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
        $PwshPath = (Get-Process -Id $PID).Path
        $SafeCwd = Join-Path $Work 'safe-cwd'
        New-Item -ItemType Directory -Path $SafeCwd -Force | Out-Null
        $script:RunIndex = 0

        $sourceDir = Join-Path $Work 'sources'
        $alpha = Join-Path $sourceDir 'Alias-Alpha.ps1'
        $beta = Join-Path $sourceDir 'Alias-Beta.ps1'
        Write-Utf8 -Path $alpha -Content "exit 0`n"
        Write-Utf8 -Path $beta -Content "exit 0`n"
        foreach ($source in @($alpha, $beta)) {
            & $InstallScript -CustomHook $source -Events @('Stop') -TargetProject $link -Clients @('claude') *> $null
        }

        $settingsPath = Join-Path $real '.claude\settings.local.json'
        $alphaRuntime = Join-Path $real '.claude\hooks\Hook-Maker\Alias-Alpha\Alias-Alpha.ps1'
        $installs = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs)
        Check 'an install through a junction records the real root' (
            $installs.Count -eq 2 -and @($installs | Where-Object { Test-SamePath ([string]$_.targetProjectRoot) $real }).Count -eq 2) (
            (@($installs | ForEach-Object { [string]$_.targetProjectRoot }) -join '; '))
        $settingsText = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8)
        $realJson = $real.Replace('\', '\\')
        $linkJson = $link.Replace('\', '\\')
        Check 'its handlers name the real path, never the link' (
            $settingsText.IndexOf($realJson, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $settingsText.IndexOf($linkJson, [StringComparison]::OrdinalIgnoreCase) -lt 0)

        # Reproduce the state an older installer left: Alpha tracked under the LINK
        # root only, its handlers naming the link. The record is the real one with
        # every path respelled, and the id the installer derives for that root.
        $registry = Read-InstallRegistry -ToolRoot $ToolRoot
        $realAlpha = @($registry.installs | Where-Object { [string]$_.friendlyName -eq 'Alias-Alpha' })[0]
        $aliasAlpha = ($realAlpha | ConvertTo-Json -Depth 20).Replace($realJson, $linkJson) | ConvertFrom-Json
        $aliasId = Get-InstallRecordId -FriendlyName 'Alias-Alpha' -ScopeKey ($link.ToLowerInvariant()) -ProfileId ([string]$realAlpha.profile)
        Set-ObjectProperty -Object $aliasAlpha -Name 'id' -Value $aliasId
        $registry.installs = @(@($registry.installs | Where-Object { [string]$_.id -ne [string]$realAlpha.id }) + @($aliasAlpha))
        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registry
        $alphaDirJson = (Join-Path $real '.claude\hooks\Hook-Maker\Alias-Alpha').Replace('\', '\\')
        $linkAlphaDirJson = (Join-Path $link '.claude\hooks\Hook-Maker\Alias-Alpha').Replace('\', '\\')
        $settingsText = [regex]::Replace($settingsText, [regex]::Escape($alphaDirJson), $linkAlphaDirJson.Replace('$', '$$'), 'IgnoreCase')
        [IO.File]::WriteAllText($settingsPath, $settingsText, (New-Object Text.UTF8Encoding($false)))
        Check 'fixture: the alias record and its link-named handler are in place' (
            $aliasId -ne [string]$realAlpha.id -and $settingsText.IndexOf($linkJson, [StringComparison]::OrdinalIgnoreCase) -ge 0)

        # ---- refusal: no real counterpart yet ------------------------------------------
        $refusalPath = Join-Path $Work 'forget-refused.json'
        & $UninstallScript -RecordId $aliasId -ResultPath $refusalPath -ForgetAliasRecord *> $null
        $refusal = Get-Content -LiteralPath $refusalPath -Raw -Encoding utf8 | ConvertFrom-Json
        $refusalRegistry = @($refusal.components | Where-Object { $_.component -eq 'registry' })
        Check '-ForgetAliasRecord refuses an alias with no record at the real folder' (
            [string]$refusal.overall -eq 'manualRepair' -and $refusalRegistry.Count -eq 1 -and [string]$refusalRegistry[0].reason -eq 'aliasNotProven') (
            [string]$refusal.overall)
        Check 'the refusal left the alias record in the registry' (
            @((Read-InstallRegistry -ToolRoot $ToolRoot).installs | Where-Object { [string]$_.id -eq $aliasId }).Count -eq 1)

        # ---- fleet: dry run announces, -Apply merges -------------------------------------
        $dest = Join-Path $base 'sync dest'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $configPath = Join-Path $Work 'sync-hooks.json'
        $config = [ordered]@{ profiles = @([ordered]@{ id = 'alias-test'; name = 'alias test'; enabled = $true
                    routes = @([ordered]@{ source = [ordered]@{ root = $link }; destination = [ordered]@{ root = $dest } }) }) }
        Write-Utf8 -Path $configPath -Content ($config | ConvertTo-Json -Depth 10)

        function Invoke-Fleet {
            param([string[]]$Arguments = @())
            $script:RunIndex++
            $log = Join-Path $Work ('fleet-' + $script:RunIndex + '.log')
            $out = Join-Path $Work ('fleet-' + $script:RunIndex + '.out')
            $err = Join-Path $Work ('fleet-' + $script:RunIndex + '.err')
            $proc = Start-BoundedProcess -FilePath $PwshPath -WorkingDirectory $SafeCwd `
                -ArgumentList (@('-NoLogo', '-NoProfile', '-File', $Fleet, '-LogPath', $log, '-ConfigPath', $configPath) + $Arguments) `
                -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutMs 300000
            $read = { param($p) if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } else { '' } }
            return [pscustomobject]@{ Exit = $proc.ExitCode; Out = (& $read $out); Err = (& $read $err) }
        }

        $run = Invoke-Fleet @('-WhatIf')
        Check 'a dry run announces the alias merge' ($run.Out.Contains('ALIAS would merge 1 record(s): ' + $link + ' -> ' + $real)) ($run.Out + $run.Err)
        Check 'the dry run kept the alias record' (
            @((Read-InstallRegistry -ToolRoot $ToolRoot).installs | Where-Object { [string]$_.id -eq $aliasId }).Count -eq 1)

        $run = Invoke-Fleet @('-Apply')
        Check '-Apply merges the alias' ($run.Exit -eq 0 -and $run.Out.Contains('ALIAS merged 1 record(s): ' + $link + ' -> ' + $real)) (
            'exit=' + $run.Exit + ' ' + $run.Out + $run.Err)
        $after = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs)
        $alphaRecords = @($after | Where-Object { [string]$_.friendlyName -eq 'Alias-Alpha' })
        Check 'one Alpha record remains, at the real root' (
            $alphaRecords.Count -eq 1 -and (Test-SamePath ([string]$alphaRecords[0].targetProjectRoot) $real)) (
            (@($alphaRecords | ForEach-Object { [string]$_.id + '=' + [string]$_.targetProjectRoot }) -join '; '))
        Check 'no record names the link root any more' (@($after | Where-Object { Test-SamePath ([string]$_.targetProjectRoot) $link }).Count -eq 0)
        Check 'the shared runtime is intact' (Test-Path -LiteralPath $alphaRuntime -PathType Leaf)
        $settingsText = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8)
        $alphaHandlers = [regex]::Matches($settingsText, 'Alias-Alpha\.ps1', 'IgnoreCase').Count
        Check 'no handler names the link, and Alpha is registered once' (
            $settingsText.IndexOf($linkJson, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $alphaHandlers -eq 1) ('alpha handlers=' + $alphaHandlers)
        $savedConfig = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $sourceEnd = $savedConfig.profiles[0].routes[0].source
        $aliases = @()
        if ($null -ne $sourceEnd.PSObject.Properties['aliases']) { $aliases = @($sourceEnd.aliases) }
        Check 'the sync route names the real root and keeps the link as an alias' (
            (Test-SamePath ([string]$sourceEnd.root) $real) -and @($aliases | Where-Object { Test-SamePath ([string]$_) $link }).Count -eq 1) (
            ($sourceEnd | ConvertTo-Json -Compress))

        $run = Invoke-Fleet @('-WhatIf')
        Check 'a second dry run has nothing left to merge' ($run.Exit -eq 0 -and -not $run.Out.Contains('ALIAS ')) $run.Out

        # ---- sharer: the same folder through both spellings ----------------------------
        $hookDirReal = Join-Path $real '.claude\hooks\Hook-Maker\Alias-Alpha'
        $linkRecord = [pscustomobject]@{ id = 'link-record'; clients = [pscustomobject]@{
                claude = [pscustomobject]@{ installed = $true; runtimeScript = (Join-Path $link '.claude\hooks\Hook-Maker\Alias-Alpha\Alias-Alpha.ps1') } } }
        $realRecord = [pscustomobject]@{ id = 'real-record'; clients = [pscustomobject]@{
                claude = [pscustomobject]@{ installed = $true; runtimeScript = $alphaRuntime } } }
        Check 'a record under the link shares the runtime of a real-root install' (
            (Get-RuntimeSharerRecordId -Installs @($linkRecord) -RecordId 'real-record' -Client 'claude' -CanonicalHookDir $hookDirReal) -eq 'link-record')
        Check 'a record under the real root shares the runtime of a link-root install' (
            (Get-RuntimeSharerRecordId -Installs @($realRecord) -RecordId 'link-record' -Client 'claude' `
                -CanonicalHookDir (Join-Path $link '.claude\hooks\Hook-Maker\Alias-Alpha')) -eq 'real-record')
        Check 'an unrelated folder is not a sharer' (
            (Get-RuntimeSharerRecordId -Installs @($linkRecord) -RecordId 'real-record' -Client 'claude' `
                -CanonicalHookDir (Join-Path $outer '.claude\hooks\Hook-Maker\Alias-Alpha')) -eq '')
    }
}
catch {
    $script:Fail++
    Write-Host ('[FAIL] unexpected error: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    $env:HOOKMAKER_STATE_DIR = $savedStateDir
    $env:HOOKMAKER_LOG_DIR = $savedLogDir
    $env:LOCALAPPDATA = $savedLocalAppData
    # Delete the links themselves first: a recursive delete must never walk
    # through a junction into the folder it points at.
    foreach ($path in @($script:Links)) {
        try { if (Test-Path -LiteralPath $path) { [IO.Directory]::Delete($path) } } catch { Write-Host ('Could not delete link ' + $path) -ForegroundColor Yellow }
    }
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace -Path @($Work))) { $script:Fail++; Write-Host '[FAIL] workspace cleanup' -ForegroundColor Red }
    }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail)
exit $script:Fail
