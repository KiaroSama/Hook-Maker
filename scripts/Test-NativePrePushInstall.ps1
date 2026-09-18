# Offline test suite for the NATIVE GIT pre-push integration installed
# alongside Ignore-Rules-Check: the managed wrapper and its companions, and the
# preservation of a user's own pre-push hook.
#
# Split out of Test-InstallRegistry.ps1 (install/update flows) because this is
# a distinct integration with its own substrate - real throwaway Git
# repositories - rather than another registry/settings concern.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-NativePrePushInstall.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$Setup = Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($InstallScript, $Setup, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-nativeprepush'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir
$SavedHookMakerLogDir = $env:HOOKMAKER_LOG_DIR
$env:HOOKMAKER_LOG_DIR = Join-Path $Work 'logs'

# The updater's legacy scan treats the current directory as one scope, so any
# spawned wizard must run somewhere with no .claude/.codex of its own - never
# this real checkout, which has real dogfooded installs.
$SafeCwd = Join-Path $Work 'safe-cwd'
New-Item -ItemType Directory -Path $SafeCwd -Force | Out-Null

function Invoke-Wizard {
    param([string[]]$Answers, [string]$Config, [hashtable]$ExtraEnv = @{})
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "in-$token.txt"; $outF = Join-Path $Work "out-$token.txt"; $errF = Join-Path $Work "err-$token.txt"
    [System.IO.File]::WriteAllText($inF, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    $argLine = '-NoLogo -NoProfile -File "' + $Setup + '" -ConfigPath "' + $Config + '"'
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine; RedirectStandardInput = $inF
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        WorkingDirectory = $SafeCwd
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $env = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
        foreach ($key in $ExtraEnv.Keys) { $env[$key] = $ExtraEnv[$key] }
        $startArgs.Environment = $env
    }
    $p = Start-BoundedProcess @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\[[0-9;]*m", ''); Err = $err }
}

# Shared helpers the moved blocks rely on. All test blocks in this file share
# ONE isolated registry (like a real machine accumulating installs), so any
# assertion that counts records MUST filter by friendlyName.
function Get-Registry { return Read-InstallRegistry -ToolRoot $ToolRoot }
function Get-RecordsFor {
    param([string]$FriendlyName)
    return @((Get-Registry).installs | Where-Object { [string]$_.friendlyName -eq $FriendlyName })
}

function New-Config {
    param([string]$Path)
    $config = [pscustomobject]@{ version = 1; profiles = @() }
    [System.IO.File]::WriteAllText($Path, ($config | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
}

try {
    # =====================================================================

    Write-Host '--- native pre-push companion is refreshed; a preserved previous hook stays intact ---' -ForegroundColor Cyan

    $prePushProj = New-Proj 'PrePushCompanionProj'

    & git -C $prePushProj init -q -b main

    & git -C $prePushProj config user.email 't@t'

    & git -C $prePushProj config user.name 't'

    $existingPrePushDir = Join-Path $prePushProj '.git\hooks'

    New-Item -ItemType Directory -Path $existingPrePushDir -Force | Out-Null

    Write-Utf8 (Join-Path $existingPrePushDir 'pre-push') "#!/bin/sh`necho user-own-pre-push-hook`n"

    $ignoreHook = Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1'

    & $InstallScript -CustomHook $ignoreHook -Events @('SessionStart', 'Stop') -TargetProject $prePushProj *> $null

    $prePushFile = Join-Path $existingPrePushDir 'pre-push'

    Check 'installing Ignore-Rules-Check preserves the existing pre-push hook as .hookmaker-existing' (Test-Path (Join-Path $existingPrePushDir 'pre-push.hookmaker-existing'))

    $companionSecretsScript = Join-Path $existingPrePushDir 'Hook-Maker\Secrets-Check\Secrets-Check.ps1'

    Check 'the pre-push managed companion (Secrets-Check) copy exists' (Test-Path $companionSecretsScript)

    # The installed companion is the source with its shared-library dot-source

    # rewritten to the private sibling copy, so the expected hash is the PLAN's

    # generated content - which also proves that transform is deterministic.

    $realSecretsHash = Get-PlanArtifactExpectedHash -Artifact (New-PlanArtifact -RelativePath 'expected' -Kind 'Generated' -GeneratedContent (Get-PrivateLibraryScriptContent -SourceScriptPath (Join-Path $RealHooksDir 'Secrets-Check\Secrets-Check.ps1')))

    Check 'the pre-push managed companion matches the current real Secrets-Check source' ((Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash -eq $realSecretsHash)

    # 30.md Part C: the chain gained a THIRD managed stage. Same plan-generated
    # hash proof as Secrets-Check, so the Utf8 companion is the canonical
    # private-library rewrite of the real hook source, not a raw copy.
    $companionUtf8Script = Join-Path $existingPrePushDir 'Hook-Maker\Utf8-Encoding-Check\Utf8-Encoding-Check.ps1'
    Check 'the pre-push managed companion (Utf8-Encoding-Check) copy exists' (Test-Path $companionUtf8Script)
    $realUtf8Hash = Get-PlanArtifactExpectedHash -Artifact (New-PlanArtifact -RelativePath 'expected' -Kind 'Generated' -GeneratedContent (Get-PrivateLibraryScriptContent -SourceScriptPath (Join-Path $RealHooksDir 'Utf8-Encoding-Check\Utf8-Encoding-Check.ps1')))
    Check 'the pre-push managed companion matches the current real Utf8-Encoding-Check source' ((Get-FileHash -LiteralPath $companionUtf8Script -Algorithm SHA256).Hash -eq $realUtf8Hash)

    $preservedPath = Join-Path $existingPrePushDir 'pre-push.hookmaker-existing'

    $preservedBytesBefore = [System.IO.File]::ReadAllBytes($preservedPath)



    $recPrePush = @(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $prePushProj })[0]

    Check 'the record tracks the native pre-push integration' ($null -ne $recPrePush.nativeGit -and $recPrePush.nativeGit.managed -eq $true)

    Check 'the native manifest includes the Secrets-Check companion source' (@($recPrePush.nativeGit.sourceManifest | Where-Object { $_.path -like 'secrets-check/*' }).Count -ge 1)

    Check 'the native manifest includes the Utf8-Encoding-Check companion source' (@($recPrePush.nativeGit.sourceManifest | Where-Object { $_.path -like 'utf8-encoding-check/*' }).Count -ge 1)
    Check 'the record lists BOTH chain companions' ((@($recPrePush.nativeGit.companions) -contains 'Secrets-Check') -and (@($recPrePush.nativeGit.companions) -contains 'Utf8-Encoding-Check'))

    Check 'the record notes that a previous user hook was preserved' ($recPrePush.nativeGit.previousHookPreserved -eq $true)

    Check 'a freshly installed native chain evaluates as current' ((Get-InstallIntegrity -Record $recPrePush -ToolRoot $ToolRoot).Status -eq 'current')



    # Deliberately make the INSTALLED companion stale while its SOURCE is

    # untouched - the exact case a source-hash-only updater reports as

    # "up to date" while the native chain silently runs old code.

    Add-Content -LiteralPath $companionSecretsScript -Value '# deliberately corrupted companion'

    $staleCompanionHash = (Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash

    Check 'the installed companion is genuinely stale before updating' ($staleCompanionHash -ne $realSecretsHash)

    $staleEval = Get-InstallIntegrity -Record $recPrePush -ToolRoot $ToolRoot

    Check 'a stale native companion is planned for update' ($staleEval.Status -eq 'update')

    Check 'a stale native companion is reported with a native reason' ($staleEval.Detail -match 'native' -and $staleEval.Detail -match 'secrets-check') $staleEval.Detail



    # Companion SOURCE drift: tamper the RECORDED hash (equivalent to the

    # source having changed since install) - proves the companion's source is

    # actually part of the tracked manifest, without mutating a shipped hook.

    $recSourceDrift = @(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $prePushProj })[0]

    foreach ($entry in @($recSourceDrift.nativeGit.sourceManifest)) {

        if ($entry.path -like 'secrets-check/*.ps1') { $entry.hash = 'DEADBEEF' }

    }

    $sourceDriftEval = Get-InstallIntegrity -Record $recSourceDrift -ToolRoot $ToolRoot

    Check 'companion SOURCE drift alone plans the parent hook for update' ($sourceDriftEval.Status -eq 'update')

    Check 'companion source drift names the companion' ($sourceDriftEval.Detail -match 'secrets-check') $sourceDriftEval.Detail



    # Something needs updating now, so ONE confirmation is asked.

    $cfgPrePush = Join-Path $Work 'cfg-prepush.json'; New-Config $cfgPrePush

    $rPrePushUpdate = Invoke-Wizard -Config $cfgPrePush -Answers @('1', '4', '', '0')

    Check 'exit 0 (updating Ignore-Rules-Check refreshes its pre-push chain)' ($rPrePushUpdate.Exit -eq 0) $rPrePushUpdate.Err

    Check 'the stale native companion is repaired back to the current source' ((Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash -eq $realSecretsHash)



    $wrapperBody = [System.IO.File]::ReadAllText($prePushFile)

    Check 'the preserved previous pre-push hook is byte-for-byte unchanged' (

        (Test-Path -LiteralPath $preservedPath) -and

        ([System.IO.File]::ReadAllBytes($preservedPath).Length -eq $preservedBytesBefore.Length) -and

        ([System.IO.File]::ReadAllText($preservedPath) -match 'user-own-pre-push-hook'))

    Check 'the pre-push wrapper still chains to the preserved previous hook' ($wrapperBody -match 'hookmaker-existing')

    Check 'the wrapper is not duplicated (one Hook Maker marker)' ((([regex]::Matches($wrapperBody, [regex]::Escape('# Hook Maker: Ignore-Rules-Check'))).Count) -eq 1)

    Check 'the wrapper runs Ignore-Rules-Check exactly once' ((([regex]::Matches($wrapperBody, [regex]::Escape('/Ignore-Rules-Check/Ignore-Rules-Check.ps1"'))).Count) -eq 1)

    Check 'the wrapper runs Secrets-Check exactly once' ((([regex]::Matches($wrapperBody, [regex]::Escape('/Secrets-Check/Secrets-Check.ps1"'))).Count) -eq 1)

    Check 'the wrapper runs Utf8-Encoding-Check exactly once' ((([regex]::Matches($wrapperBody, [regex]::Escape('/Utf8-Encoding-Check/Utf8-Encoding-Check.ps1"'))).Count) -eq 1)

    Check 'chain order is Ignore-Rules-Check then Secrets-Check then Utf8-Encoding-Check then the previous hook' (

        $wrapperBody.IndexOf('/Ignore-Rules-Check/Ignore-Rules-Check.ps1"') -lt $wrapperBody.IndexOf('/Secrets-Check/Secrets-Check.ps1"') -and

        $wrapperBody.IndexOf('/Secrets-Check/Secrets-Check.ps1"') -lt $wrapperBody.IndexOf('/Utf8-Encoding-Check/Utf8-Encoding-Check.ps1"') -and

        $wrapperBody.IndexOf('/Utf8-Encoding-Check/Utf8-Encoding-Check.ps1"') -lt $wrapperBody.IndexOf('hookmaker-existing'))

    Check 'stdin is still buffered once and replayed to every stage' (

        $wrapperBody -match 'STDIN_FILE' -and

        ((([regex]::Matches($wrapperBody, [regex]::Escape('< "$STDIN_FILE"'))).Count) -ge 4))

    Check 'fail-closed chaining (|| exit) is preserved' ($wrapperBody -match '\|\| exit')

    Check 'the native chain evaluates as current after repair' ((Get-InstallIntegrity -Record (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $prePushProj })[0]) -ToolRoot $ToolRoot).Status -eq 'current')



    # Second run: nothing left to do, so no confirmation is asked.

    $cfgPrePush2 = Join-Path $Work 'cfg-prepush-2.json'; New-Config $cfgPrePush2

    $rPrePush2 = Invoke-Wizard -Config $cfgPrePush2 -Answers @('1', '4', '0')

    Check 'the second native pre-push run is idempotent (up to date)' ($rPrePush2.Out -match 'Ignore-Rules-Check[\s\S]*?up to date') $rPrePush2.Out



    # =====================================================================

    # The preserved user pre-push hook is USER-OWNED: preserved as opaque

    # bytes, never parsed, rewritten, or regenerated. Compared by exact bytes

    # AND SHA-256, using content that is not valid UTF-8 text and has no

    # trailing newline - a text round-trip would corrupt either one.

    Write-Host '--- previous user pre-push hook: exact byte preservation ---' -ForegroundColor Cyan

    $byteRepo = Join-Path $Work 'byte-preserve-repo'

    New-Item -ItemType Directory -Path $byteRepo -Force | Out-Null

    Push-Location $byteRepo

    try {

        & git init --quiet 2>$null | Out-Null

        & git config user.email 'regtest@example.invalid' 2>$null | Out-Null

        & git config user.name 'Regtest' 2>$null | Out-Null

        Write-Utf8 (Join-Path $byteRepo 'readme.md') 'seed'

        & git add -A 2>$null | Out-Null

        & git commit -m seed --quiet 2>$null | Out-Null

    }

    finally { Pop-Location }

    $gitHooksDir = Join-Path $byteRepo '.git\hooks'

    New-Item -ItemType Directory -Path $gitHooksDir -Force | Out-Null

    # Deliberately NOT valid UTF-8, and deliberately no trailing newline.

    $userHookBytes = [byte[]]@(0x23, 0x21, 0x2F, 0x62, 0x69, 0x6E, 0x2F, 0x73, 0x68, 0x0A,

                               0x23, 0x20, 0xFF, 0xFE, 0x80, 0x81, 0x0A,

                               0x65, 0x78, 0x69, 0x74, 0x20, 0x30)

    $userHookPath = Join-Path $gitHooksDir 'pre-push'

    [System.IO.File]::WriteAllBytes($userHookPath, $userHookBytes)

    $userHookSha = (Get-FileHash -LiteralPath $userHookPath -Algorithm SHA256).Hash



    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1') -Events @('Stop') -TargetProject $byteRepo -ClaudeOnly *> $null

    $preservedPath = Join-Path $gitHooksDir 'pre-push.hookmaker-existing'

    Check 'the user pre-push hook is preserved as .hookmaker-existing' (Test-Path -LiteralPath $preservedPath)

    $preservedBytes = [System.IO.File]::ReadAllBytes($preservedPath)

    $bytesIdentical = ($preservedBytes.Length -eq $userHookBytes.Length)

    if ($bytesIdentical) {

        for ($bi = 0; $bi -lt $userHookBytes.Length; $bi++) {

            if ($preservedBytes[$bi] -ne $userHookBytes[$bi]) { $bytesIdentical = $false; break }

        }

    }

    Check 'the preserved hook is byte-for-byte identical (exact byte array)' $bytesIdentical

    Check 'the preserved hook SHA-256 is unchanged' ((Get-FileHash -LiteralPath $preservedPath -Algorithm SHA256).Hash -eq $userHookSha)

    Check 'non-UTF-8 bytes survived (no text round-trip)' (($preservedBytes -contains 0xFF) -and ($preservedBytes -contains 0xFE))

    Check 'the absent trailing newline survived' ($preservedBytes[$preservedBytes.Length - 1] -eq 0x30)



    # Reinstalling must not re-preserve, duplicate, or rewrite the user hook.

    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1') -Events @('Stop') -TargetProject $byteRepo -ClaudeOnly *> $null

    Check 'a reinstall leaves the preserved hook byte-identical' ((Get-FileHash -LiteralPath $preservedPath -Algorithm SHA256).Hash -eq $userHookSha)

    Check 'a reinstall creates no second preserved copy' (@(Get-ChildItem -LiteralPath $gitHooksDir -Filter 'pre-push.hookmaker-existing*' -Force).Count -eq 1)



    # Sticky state: if the preserved hook DISAPPEARS, that historical fact must

    # not be rewritten to "there never was one" - it stays a manual-repair item.

    $byteRecord = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs |

        Where-Object { $_.friendlyName -eq 'Ignore-Rules-Check' -and $_.targetProjectRoot -eq $byteRepo })[0]

    Check 'the record remembers a user hook was preserved' ($byteRecord.nativeGit.previousHookPreserved -eq $true)

    Remove-Item -LiteralPath $preservedPath -Force

    $stickyEval = Get-InstallIntegrity -Record $byteRecord -ToolRoot $ToolRoot

    Check 'a vanished preserved hook is never silently reported current' ($stickyEval.Status -ne 'current') $stickyEval.Detail

    Check 'it is reported as needing manual repair, not auto-fixed' ($stickyEval.Detail -match 'previously preserved user pre-push hook is missing') $stickyEval.Detail

    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1') -Events @('Stop') -TargetProject $byteRepo -ClaudeOnly *> $null

    $afterRepair = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs |

        Where-Object { $_.friendlyName -eq 'Ignore-Rules-Check' -and $_.targetProjectRoot -eq $byteRepo })[0]

    Check 'repair does NOT rewrite the historical flag to false' ($afterRepair.nativeGit.previousHookPreserved -eq $true)

    Check 'repair records that the preserved hook is missing' ($afterRepair.nativeGit.previousHookMissing -eq $true)

    Check 'repair never regenerates a user-owned hook' (-not (Test-Path -LiteralPath $preservedPath))

    # =====================================================================
    # 30.md Part D item 27: uninstalling the Utf8-Encoding-Check LIFECYCLE
    # record removes ITS stage from the managed chain - and nothing else.
    Write-Host '--- uninstalling Utf8-Encoding-Check removes only its chain stage ---' -ForegroundColor Cyan
    $stageRepo = Join-Path $Work 'chainstage-repo'
    New-Item -ItemType Directory -Path $stageRepo -Force | Out-Null
    Push-Location $stageRepo
    try {
        & git init --quiet 2>$null | Out-Null
        & git config user.email 'regtest@example.invalid' 2>$null | Out-Null
        & git config user.name 'Regtest' 2>$null | Out-Null
        Write-Utf8 (Join-Path $stageRepo 'readme.md') 'seed'
        & git add -A 2>$null | Out-Null
        & git commit -m seed --quiet 2>$null | Out-Null
    }
    finally { Pop-Location }
    $stageHooksDir = Join-Path $stageRepo '.git\hooks'
    New-Item -ItemType Directory -Path $stageHooksDir -Force | Out-Null
    Write-Utf8 (Join-Path $stageHooksDir 'pre-push') "#!/bin/sh`necho user-own-pre-push-hook`n"
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1') -Events @('Stop') -TargetProject $stageRepo -ClaudeOnly *> $null
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Utf8-Encoding-Check\Utf8-Encoding-Check.ps1') -Events @('SessionStart', 'Stop') -TargetProject $stageRepo -ClaudeOnly *> $null
    $stageWrapper = Join-Path $stageHooksDir 'pre-push'
    Check 'fixture: the chain wrapper carries the Utf8 stage before the uninstall' (([System.IO.File]::ReadAllText($stageWrapper)) -match 'Utf8-Encoding-Check')
    $stagePreserved = $stageWrapper + '.hookmaker-existing'
    $stagePreservedBytesBefore = [System.IO.File]::ReadAllBytes($stagePreserved)
    $utf8Rec = @(Get-RecordsFor 'Utf8-Encoding-Check' | Where-Object { $_.targetProjectRoot -eq $stageRepo })[0]

    # RED (historical, static): the pre-change executor had no chain-stage
    # concept at all, so uninstalling the Utf8 record provably left the stage
    # in the wrapper. Retires itself once HEAD contains the fix.
    $oldUninstallText = ((& git -C $ToolRoot show 'HEAD:scripts/Uninstall-Hook.ps1' 2>$null) -join "`n")
    if ([string]::IsNullOrWhiteSpace($oldUninstallText) -or $oldUninstallText -match 'Remove-CompanionChainStage') {
        Write-Host 'HEAD already contains the chain-stage removal; historical red-proof retired.' -ForegroundColor DarkGray
    }
    else {
        Check 'RED-PROOF: the PRE-FIX executor has no chain-stage removal (stage would remain)' ($oldUninstallText -notmatch 'chainStage')
    }

    $rStageUninstall = & (Join-Path $PSScriptRoot 'Uninstall-Hook.ps1') -RecordId ([string]$utf8Rec.id) -ToolRoot $ToolRoot *> $null
    $stageBodyAfter = [System.IO.File]::ReadAllText($stageWrapper)
    Check 'the Utf8 stage is gone from the wrapper' ($stageBodyAfter -notmatch 'Utf8-Encoding-Check')
    Check 'Ignore-Rules-Check still runs exactly once' ((([regex]::Matches($stageBodyAfter, [regex]::Escape('/Ignore-Rules-Check/Ignore-Rules-Check.ps1"'))).Count) -eq 1)
    Check 'Secrets-Check still runs exactly once' ((([regex]::Matches($stageBodyAfter, [regex]::Escape('/Secrets-Check/Secrets-Check.ps1"'))).Count) -eq 1)
    Check 'the preserved user hook is still chained' ($stageBodyAfter -match 'hookmaker-existing')
    Check 'the preserved user hook bytes are untouched' (@(Compare-Object $stagePreservedBytesBefore ([System.IO.File]::ReadAllBytes($stagePreserved))).Count -eq 0)
    $stageRuntimeRoot = Join-Path $stageHooksDir 'Hook-Maker'
    Check 'the Utf8 companion runtime dir is removed' (-not (Test-Path (Join-Path $stageRuntimeRoot 'Utf8-Encoding-Check')))
    Check 'the Secrets-Check companion runtime dir is preserved' (Test-Path (Join-Path $stageRuntimeRoot 'Secrets-Check\Secrets-Check.ps1'))
    $ignoreAfterStage = @(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $stageRepo })[0]
    Check 'the chain owner''s record no longer lists the Utf8 companion' (@($ignoreAfterStage.nativeGit.companions) -notcontains 'Utf8-Encoding-Check')
    Check 'the chain owner''s record still lists Secrets-Check' (@($ignoreAfterStage.nativeGit.companions) -contains 'Secrets-Check')
    Check 'the chain owner evaluates as CURRENT after the stage removal (stages/manifest/wrapper all consistent)' ((Get-InstallIntegrity -Record $ignoreAfterStage -ToolRoot $ToolRoot).Status -eq 'current')
    Check 'the Utf8 lifecycle record itself is gone' (@(Get-RecordsFor 'Utf8-Encoding-Check' | Where-Object { $_.targetProjectRoot -eq $stageRepo }).Count -eq 0)

    # =====================================================================
    # A target that is only a SUBDIRECTORY of a repository must never take
    # ownership of that repository's pre-push hook.
    #
    # `git rev-parse --git-path hooks` answers for the enclosing repo, so a
    # subdirectory install used to install into - and on uninstall DELETE - the
    # parent repository's real .git\hooks\pre-push. Observed for real: fixture
    # projects created under this tool's own state\ directory took ownership of
    # this repository's chain, and removing those records removed it.
    Write-Host '--- a subdirectory target never owns the enclosing repository''s pre-push ---' -ForegroundColor Cyan
    $outerRepo = New-Proj 'OuterRepoForSubdir'
    & git -C $outerRepo init -q -b main
    & git -C $outerRepo config user.email 't@t'
    & git -C $outerRepo config user.name 't'
    $outerHooks = Join-Path $outerRepo '.git\hooks'
    New-Item -ItemType Directory -Path $outerHooks -Force | Out-Null
    $outerPrePush = Join-Path $outerHooks 'pre-push'
    Write-Utf8 $outerPrePush "#!/bin/sh`necho outer-repo-own-pre-push`n"
    $outerBytesBefore = [System.IO.File]::ReadAllBytes($outerPrePush)

    $innerDir = Join-Path $outerRepo 'nested\project'
    New-Item -ItemType Directory -Path $innerDir -Force | Out-Null
    $subIgnoreHook = Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1'
    & $InstallScript -CustomHook $subIgnoreHook -Events @('SessionStart') -TargetProject $innerDir *> $null

    $subRecord = @(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $innerDir })[0]
    Check 'the subdirectory install still succeeds for the normal clients' ($null -ne $subRecord) 'no record written'
    Check 'it records NO native git chain (it is not the repository root)' (
        $null -eq $subRecord -or $null -eq $subRecord.PSObject.Properties['nativeGit'] -or $null -eq $subRecord.nativeGit) (
        'nativeGit present')
    Check 'the enclosing repository''s own pre-push is byte-for-byte untouched' (
        @(Compare-Object $outerBytesBefore ([System.IO.File]::ReadAllBytes($outerPrePush))).Count -eq 0)
    Check 'no managed chain runtime was written into the enclosing repository' (
        -not (Test-Path -LiteralPath (Join-Path $outerHooks 'Hook-Maker')))
    Check 'the enclosing repository''s hook was not displaced to .hookmaker-existing' (
        -not (Test-Path -LiteralPath (Join-Path $outerHooks 'pre-push.hookmaker-existing')))
    Check 'the subdirectory record evaluates as current (a chain-less install is not drift)' (
        $null -eq $subRecord -or (Get-InstallIntegrity -Record $subRecord -ToolRoot $ToolRoot).Status -eq 'current') (
        $(if ($null -eq $subRecord) { 'no record' } else { (Get-InstallIntegrity -Record $subRecord -ToolRoot $ToolRoot).Detail }))

    # The repository ROOT itself must still get its chain - the guard narrows
    # ownership, it does not remove the feature.
    & $InstallScript -CustomHook $subIgnoreHook -Events @('SessionStart') -TargetProject $outerRepo *> $null
    $rootRecord = @(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $outerRepo })[0]
    Check 'installing at the repository ROOT still installs the native chain' (
        $null -ne $rootRecord -and $null -ne $rootRecord.PSObject.Properties['nativeGit'] -and $null -ne $rootRecord.nativeGit)
    Check 'and the root install still preserves the user''s own pre-push bytes' (
        (Test-Path -LiteralPath (Join-Path $outerHooks 'pre-push.hookmaker-existing')) -and
        @(Compare-Object $outerBytesBefore ([System.IO.File]::ReadAllBytes((Join-Path $outerHooks 'pre-push.hookmaker-existing')))).Count -eq 0)
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    $env:HOOKMAKER_LOG_DIR = $SavedHookMakerLogDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

    # =====================================================================
    Write-Host '--- the project install follows the config its hooks are already in ---' -ForegroundColor Cyan
    # A fresh project gets settings.local.json: the registration holds a
    # machine-specific absolute path and must not enter a tracked file. But a
    # project whose Hook-Maker registrations already sit in settings.json used to
    # get a SECOND settings.local.json beside them, splitting one hook set across
    # two files - the same hook registered twice, /hooks showing duplicates, and
    # uninstall cleaning only one side.
    $freshProj = Join-Path $Work 'SettingsFresh'
    New-Item -ItemType Directory -Path $freshProj -Force | Out-Null
    & git -C $freshProj init -q *> $null
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Large-File-Check\Large-File-Check.ps1') -Events @('Stop') -TargetProject $freshProj -ClaudeOnly *> $null
    Check 'a FRESH project still installs into the untracked settings.local.json' (
        (Test-Path -LiteralPath (Join-Path $freshProj '.claude\settings.local.json') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $freshProj '.claude\settings.json') -PathType Leaf))

    $existingProj = Join-Path $Work 'SettingsExisting'
    New-Item -ItemType Directory -Path (Join-Path $existingProj '.claude') -Force | Out-Null
    & git -C $existingProj init -q *> $null
    $trackedSettings = Join-Path $existingProj '.claude\settings.json'
    Write-Utf8 $trackedSettings ('{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"powershell -File C:/x/Hook-Maker/Secrets-Check/Secrets-Check.ps1"}]}]},"someUserSetting":"must survive"}')
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Large-File-Check\Large-File-Check.ps1') -Events @('Stop') -TargetProject $existingProj -ClaudeOnly *> $null
    Check 'a project whose Hook-Maker hooks are in settings.json gets NO second config file' (
        -not (Test-Path -LiteralPath (Join-Path $existingProj '.claude\settings.local.json') -PathType Leaf))
    $existingDoc = $null
    try { $existingDoc = (Get-Content -LiteralPath $trackedSettings -Raw) | ConvertFrom-Json } catch { $existingDoc = $null }
    Check 'the new hook joined the SAME file, beside the one already there' (
        $null -ne $existingDoc -and @($existingDoc.hooks.Stop).Count -eq 2) (
        'entries=' + $(if ($null -eq $existingDoc) { 'unreadable' } else { [string]@($existingDoc.hooks.Stop).Count }))
    Check 'and the user''s unrelated setting in that file survived' (
        $null -ne $existingDoc -and [string]$existingDoc.someUserSetting -eq 'must survive')

    # NEGATIVE CONTROL: a project with only FOREIGN hooks in settings.json is not
    # this tool's file to write into - it keeps the untracked default.
    $foreignProj = Join-Path $Work 'SettingsForeign'
    New-Item -ItemType Directory -Path (Join-Path $foreignProj '.claude') -Force | Out-Null
    & git -C $foreignProj init -q *> $null
    Write-Utf8 (Join-Path $foreignProj '.claude\settings.json') ('{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"node C:/them/their-hook.js"}]}]}}')
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Large-File-Check\Large-File-Check.ps1') -Events @('Stop') -TargetProject $foreignProj -ClaudeOnly *> $null
    Check 'NEGATIVE CONTROL: a foreign-only settings.json is left alone, default still used' (
        Test-Path -LiteralPath (Join-Path $foreignProj '.claude\settings.local.json') -PathType Leaf)

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
