# Offline test suite for Docs-Freshness-Check - new hook, no prior coverage.
# Focused on the explicit safety/detection requirements, not an exhaustive
# per-language matrix: SessionStart baseline is silent; task-delta detection
# (committed + staged + working-tree, comment/blank-only changes excluded);
# ranked tracked-doc candidates; hard exclusions (private/generated/vendor/
# fixture/legal); the mandatory fingerprint-bound acknowledgement flow
# (Updated/NoUpdate, rejection of generic reasons and out-of-root/private/
# untracked paths, invalidation on a later non-doc change); stop_hook_active;
# PS 5.1 compatibility; self-contained installer copies; the hook never edits
# a doc file itself.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-DocsFreshnessCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Docs-Freshness-Check\Docs-Freshness-Check.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
foreach ($required in @($Hook, $HookLib, $InstallScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-docsfreshtest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
# Isolates Install-Hook.ps1's install registry away from this real checkout's
# own registry for the in-process & $InstallScript call below.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$env:HOOKMAKER_STATE_DIR = Join-Path $Work 'state'

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function New-GitRepo {
    param([string]$Name)
    $p = New-Proj $Name
    & git -C $p init -q -b main
    & git -C $p config user.email 't@t'
    & git -C $p config user.name 't'
    & git -C $p config core.autocrlf false
    return $p
}
function Add-Commit {
    param([string]$Repo, [string]$Message = 'c')
    & git -C $Repo add -A 2>$null | Out-Null
    & git -C $Repo commit -q -m $Message 2>$null | Out-Null
}

# Per-test isolated LOCALAPPDATA so baseline/ack state files never collide.
function New-IsolatedHookCopy {
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Docs-Freshness-Check.ps1')
    Copy-TestRuntimeLibraries -SourceHookLib $HookLib -Destination (Join-Path $Work '_hooklib.ps1')
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Docs-Freshness-Check.ps1'); LocalAppData = $fakeLocal }
}

function Fire {
    param([string]$HookPath, [string]$Cwd, [string]$EventName, [string]$SessionId = 'sess1', [string]$LocalAppData, [switch]$StopHookActive, [string]$Exe = 'pwsh', [string]$Prompt = '')
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($Prompt -ne '') { $obj['prompt'] = $Prompt }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData }
    }
    $proc = Start-BoundedProcess @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Direct CLI invocation of the -Acknowledge command mode (never via stdin).
function FireAck {
    param([string]$HookPath, [string]$ProjectRoot, [string]$Fingerprint, [string]$Result, [string]$Files = '', [string]$Reason = '', [string]$LocalAppData)
    $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '" -Acknowledge -ProjectRoot "' + $ProjectRoot + '" -ImpactFingerprint "' + $Fingerprint + '" -Result ' + $Result + ' -Files "' + $Files + '" -Reason "' + $Reason + '"'
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $Work ('ackout-' + $token + '.txt')
    $errFile = Join-Path $Work ('ackerr-' + $token + '.txt')
    $startArgs = @{
        FilePath = (Get-Process -Id $PID).Path; ArgumentList = $argLine
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData }
    }
    $proc = Start-BoundedProcess @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# The raw stdout is compressed JSON, so the reason text's own literal quotes
# are backslash-escaped ("...\"..." ) - decode via ConvertFrom-Json first
# rather than regexing the escaped raw text directly.
function Get-Fingerprint {
    param([string]$Text)
    try {
        $reason = [string]((($Text | ConvertFrom-Json)).reason)
        $m = [regex]::Match($reason, '-ImpactFingerprint "([a-f0-9]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    catch { }
    return ''
}

try {
    # =====================================================================
    Write-Host '--- SessionStart baseline is always silent ---' -ForegroundColor Cyan
    $hc1 = New-IsolatedHookCopy
    $proj1 = New-GitRepo 'Baseline'
    Write-Utf8 (Join-Path $proj1 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj1 'lib.ps1') "function Foo { `$x = 1 }`n"
    Add-Commit $proj1 'init'
    $r = Fire -HookPath $hc1.Script -Cwd $proj1 -EventName 'SessionStart' -LocalAppData $hc1.LocalAppData
    Check 'SessionStart is silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $baselineFile = @(Get-ChildItem -LiteralPath (Join-Path $hc1.LocalAppData 'HookMaker\state') -Filter 'DocsFreshnessCheck-baseline-*.json' -ErrorAction SilentlyContinue)
    Check 'a baseline state file was written' ($baselineFile.Count -eq 1)

    # =====================================================================
    Write-Host '--- SessionStart baseline: a non-ASCII tracked filename does not crash (PS 5.1 core.quotepath regression) ---' -ForegroundColor Cyan
    # Regression for: git's default core.quotepath=true quotes+escapes a non-ASCII
    # tracked name (e.g. "caf\303\251.md"), and [System.IO.Path]::GetExtension() on
    # that raw quoted string throws on PS 5.1 ('"' is an illegal path char),
    # aborting the whole SessionStart block before the baseline is ever written.
    # Fired under 5.1 specifically - that is where GetExtension throws.
    $hcUtf = New-IsolatedHookCopy
    $projUtf = New-GitRepo 'NonAsciiBaseline'
    Write-Utf8 (Join-Path $projUtf 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $projUtf 'café.md') "# Café notes`n"
    Add-Commit $projUtf 'init'
    $rUtf = Fire -HookPath $hcUtf.Script -Cwd $projUtf -EventName 'SessionStart' -LocalAppData $hcUtf.LocalAppData -Exe 'powershell.exe'
    Check '5.1 host: SessionStart with a non-ASCII tracked filename does not crash and stays silent' ($rUtf.Exit -eq 0 -and $rUtf.Out -eq '' -and $rUtf.Err -eq '') ($rUtf.Out + ' | err=' + $rUtf.Err)
    Check '5.1 host: a baseline state file was written despite the non-ASCII filename' (
        @(Get-ChildItem -LiteralPath (Join-Path $hcUtf.LocalAppData 'HookMaker\state') -Filter 'DocsFreshnessCheck-baseline-*.json' -ErrorAction SilentlyContinue).Count -eq 1)

    # Doc-classification content check (is café.md actually hashed into the
    # baseline, not silently dropped?) is run under the default pwsh host
    # instead of re-using the 5.1 firing above: a nested powershell.exe child
    # spawned from pwsh in this environment loses access to Get-FileHash
    # (Microsoft.PowerShell.Utility fails to resolve under the inherited
    # PSModulePath) - an unrelated host-nesting quirk, not a quotepath
    # regression, and pwsh-under-pwsh does not have it. The crash itself
    # (asserted above) happens before Get-FileHash is ever reached.
    $hcUtf2 = New-IsolatedHookCopy
    $projUtf2 = New-GitRepo 'NonAsciiBaselineContent'
    Write-Utf8 (Join-Path $projUtf2 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $projUtf2 'café.md') "# Café notes`n"
    Add-Commit $projUtf2 'init'
    $rUtf2 = Fire -HookPath $hcUtf2.Script -Cwd $projUtf2 -EventName 'SessionStart' -LocalAppData $hcUtf2.LocalAppData
    Check 'pwsh host: SessionStart with a non-ASCII tracked filename does not crash and stays silent' ($rUtf2.Exit -eq 0 -and $rUtf2.Out -eq '' -and $rUtf2.Err -eq '') ($rUtf2.Out + ' | err=' + $rUtf2.Err)
    $baselineFileUtf2 = @(Get-ChildItem -LiteralPath (Join-Path $hcUtf2.LocalAppData 'HookMaker\state') -Filter 'DocsFreshnessCheck-baseline-*.json' -ErrorAction SilentlyContinue)
    Check 'a baseline state file was written despite the non-ASCII filename' ($baselineFileUtf2.Count -eq 1)
    if ($baselineFileUtf2.Count -eq 1) {
        $baselineRawUtf2 = [System.IO.File]::ReadAllText($baselineFileUtf2[0].FullName)
        $baselineObjUtf2 = $baselineRawUtf2 | ConvertFrom-Json
        $docHashCountUtf2 = @($baselineObjUtf2.docHashes.PSObject.Properties).Count
        Check 'both tracked doc files are classified into the baseline (the non-ASCII one is not silently dropped)' ($docHashCountUtf2 -eq 2) ('docHashes count=' + $docHashCountUtf2)
        Check 'the non-ASCII filename is present in the baseline (not silently dropped)' ($baselineRawUtf2 -match 'caf') $baselineRawUtf2
    }

    # =====================================================================
    Write-Host '--- no git repository is silent ---' -ForegroundColor Cyan
    $hc2 = New-IsolatedHookCopy
    $proj2 = New-Proj 'NoGit'
    $r = Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'Stop' -LocalAppData $hc2.LocalAppData
    Check 'non-git directory Stop is silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- no meaningful change is silent ---' -ForegroundColor Cyan
    $hc3 = New-IsolatedHookCopy
    $proj3 = New-GitRepo 'NoChange'
    Write-Utf8 (Join-Path $proj3 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj3 'lib.ps1') "function Foo { `$x = 1 }`n"
    Add-Commit $proj3 'init'
    Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'SessionStart' -LocalAppData $hc3.LocalAppData | Out-Null
    $r = Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'Stop' -LocalAppData $hc3.LocalAppData
    Check 'no changes since baseline -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- comment/blank-only change is silent (internal refactor, unchanged contract) ---' -ForegroundColor Cyan
    $hc4 = New-IsolatedHookCopy
    $proj4 = New-GitRepo 'CommentOnly'
    Write-Utf8 (Join-Path $proj4 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj4 'lib.ps1') "# old comment`nfunction Foo { `$x = 1 }`n"
    Add-Commit $proj4 'init'
    Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'SessionStart' -LocalAppData $hc4.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj4 'lib.ps1') "# new comment, more detail`nfunction Foo { `$x = 1 }`n"
    $r = Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'Stop' -LocalAppData $hc4.LocalAppData
    Check 'a comment-only source change is silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- a real behavior/CLI/config/API code change triggers mandatory review ---' -ForegroundColor Cyan
    $hc5 = New-IsolatedHookCopy
    $proj5 = New-GitRepo 'RealChange'
    Write-Utf8 (Join-Path $proj5 'README.md') "# Proj`n`nSee CHANGELOG.md.`n"
    Write-Utf8 (Join-Path $proj5 'CHANGELOG.md') "# Changelog`n"
    New-Item -ItemType Directory -Path (Join-Path $proj5 'src') -Force | Out-Null
    Write-Utf8 (Join-Path $proj5 'src\cli.ps1') "function Invoke-Cli { param(`$Flag) return `$Flag }`n"
    Add-Commit $proj5 'init'
    Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'SessionStart' -LocalAppData $hc5.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj5 'src\cli.ps1') "function Invoke-Cli { param(`$Flag, `$NewFlag) return `$Flag + `$NewFlag }`n"
    $r = Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'Stop' -LocalAppData $hc5.LocalAppData
    Check 'a real CLI/behavior code change triggers decision:block' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the block reason names the changed file (relative path)' ($r.Out -match [regex]::Escape('src\cli.ps1') -or $r.Out -match [regex]::Escape('src/cli.ps1')) $r.Out
    Check 'candidate documentation includes ranked tracked README/CHANGELOG' ($r.Out -match 'README\.md' -and $r.Out -match 'CHANGELOG\.md') $r.Out
    Check 'the report gives an acknowledgement command with a real fingerprint' ((Get-Fingerprint $r.Out) -ne '') $r.Out
    Check 'output never contains the literal source file content' ($r.Out -notlike '*Invoke-Cli*') $r.Out
    # E-10: the review-topic list must name the doc-impact areas the UTF-8 hook
    # and ::deep-debug work introduced - alongside the pre-existing topics.
    Check 'E-10: review topics include menu numbering/labels (pre-existing, preserved)' ($r.Out -match 'menu numbering/labels') $r.Out
    Check 'E-10: review topics include the text-encoding policy and documented encoding exceptions' (
        $r.Out -match 'text-encoding policy' -and $r.Out -match 'encoding-exception formats') $r.Out
    Check 'E-10: review topics include hook install/update/status/uninstall + native chain order' (
        $r.Out -match 'hook install/update/status/uninstall behavior' -and $r.Out -match 'native Git hook chain order') $r.Out
    Check 'E-10: review topics include documented workflow boundaries (::deep-debug / final Ponytail pass)' (
        $r.Out -match '::deep-debug' -and $r.Out -match 'single final Ponytail pass') $r.Out
    Check 'E-10: internal-only changes still clear via -Result NoUpdate (no churn requirement)' ($r.Out -match '-Result NoUpdate') $r.Out

    # =====================================================================
    Write-Host '--- hard exclusions: private/generated/vendor/fixture/legal changes never trigger or appear as candidates ---' -ForegroundColor Cyan
    $hc6 = New-IsolatedHookCopy
    $proj6 = New-GitRepo 'Excluded'
    Write-Utf8 (Join-Path $proj6 'README.md') "# Proj`n"
    New-Item -ItemType Directory -Path (Join-Path $proj6 '.ai'), (Join-Path $proj6 'node_modules\pkg'), (Join-Path $proj6 'test\fixtures') -Force | Out-Null
    Write-Utf8 (Join-Path $proj6 '.ai\NOTES.md') "private notes`n"
    Write-Utf8 (Join-Path $proj6 'node_modules\pkg\index.js') "module.exports = 1;`n"
    Write-Utf8 (Join-Path $proj6 'test\fixtures\sample.md') "fixture doc`n"
    Write-Utf8 (Join-Path $proj6 'LICENSE.md') "MIT`n"
    Add-Commit $proj6 'init'
    Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'SessionStart' -LocalAppData $hc6.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj6 '.ai\NOTES.md') "private notes changed`n"
    Write-Utf8 (Join-Path $proj6 'node_modules\pkg\index.js') "module.exports = 2; /* real change */`n"
    Write-Utf8 (Join-Path $proj6 'test\fixtures\sample.md') "fixture doc changed`n"
    Write-Utf8 (Join-Path $proj6 'LICENSE.md') "MIT changed`n"
    $r = Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'Stop' -LocalAppData $hc6.LocalAppData
    Check 'changes confined to hard-excluded paths never trigger a review' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- output contains only relative paths, no file contents ---' -ForegroundColor Cyan
    $hc7 = New-IsolatedHookCopy
    $proj7 = New-GitRepo 'RelativeOnly'
    Write-Utf8 (Join-Path $proj7 'README.md') "# Proj`n"
    New-Item -ItemType Directory -Path (Join-Path $proj7 'app') -Force | Out-Null
    Write-Utf8 (Join-Path $proj7 'app\core.ps1') "`$secretLookingContent = 'do-not-print-this-marker'`n"
    Add-Commit $proj7 'init'
    Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'SessionStart' -LocalAppData $hc7.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj7 'app\core.ps1') "`$secretLookingContent = 'do-not-print-this-marker-CHANGED'`n"
    $r = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'Stop' -LocalAppData $hc7.LocalAppData
    Check 'block output never contains raw file content' ($r.Out -notlike '*do-not-print-this-marker*') $r.Out
    Check 'block output uses a project-relative path, not the absolute temp path' ($r.Out -notlike ('*' + $proj7 + '*')) $r.Out

    # =====================================================================
    Write-Host '--- committed-after-baseline, staged, and working-tree changes are all detected ---' -ForegroundColor Cyan
    $hc8 = New-IsolatedHookCopy
    $proj8 = New-GitRepo 'CommittedAfter'
    Write-Utf8 (Join-Path $proj8 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj8 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj8 'init'
    Fire -HookPath $hc8.Script -Cwd $proj8 -EventName 'SessionStart' -LocalAppData $hc8.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj8 'a.ps1') "function A { 2 }`n"
    Add-Commit $proj8 'a real change, committed before Stop'
    $r = Fire -HookPath $hc8.Script -Cwd $proj8 -EventName 'Stop' -LocalAppData $hc8.LocalAppData
    Check 'a change committed after SessionStart is still detected via the starting-HEAD range' ($r.Out -match '"decision":"block"') $r.Out

    $hc9 = New-IsolatedHookCopy
    $proj9 = New-GitRepo 'StagedAndWorktree'
    Write-Utf8 (Join-Path $proj9 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj9 'a.ps1') "function A { 1 }`n"
    Write-Utf8 (Join-Path $proj9 'b.ps1') "function B { 1 }`n"
    Add-Commit $proj9 'init'
    Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'SessionStart' -LocalAppData $hc9.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj9 'a.ps1') "function A { 2 }`n"
    & git -C $proj9 add a.ps1 2>$null | Out-Null
    Write-Utf8 (Join-Path $proj9 'b.ps1') "function B { 2 }`n"
    $r = Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'Stop' -LocalAppData $hc9.LocalAppData
    Check 'both a staged change and a working-tree-only change are detected together' ($r.Out -match '(a\.ps1|a/ps1)' -and $r.Out -match 'b\.ps1') $r.Out

    # =====================================================================
    Write-Host '--- acknowledgement: Updated with real reviewed files clears the block ---' -ForegroundColor Cyan
    $hc10 = New-IsolatedHookCopy
    $proj10 = New-GitRepo 'AckUpdated'
    Write-Utf8 (Join-Path $proj10 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj10 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj10 'init'
    Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'SessionStart' -LocalAppData $hc10.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj10 'a.ps1') "function A { 2 }`n"
    $rBlock = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    Check 'first Stop blocks' ($rBlock.Out -match '"decision":"block"') $rBlock.Out
    $fp1 = Get-Fingerprint $rBlock.Out
    Check 'a fingerprint was extracted from the block reason' ($fp1 -ne '')
    Write-Utf8 (Join-Path $proj10 'README.md') "# Proj`n`nUpdated for the new behavior.`n"
    $rAck = FireAck -HookPath $hc10.Script -ProjectRoot $proj10 -Fingerprint $fp1 -Result Updated -Files 'README.md' -Reason 'documented the new A() return value' -LocalAppData $hc10.LocalAppData
    Check 'a valid Updated acknowledgement succeeds' ($rAck.Exit -eq 0 -and $rAck.Out -like '*acknowledged*') ($rAck.Out + $rAck.Err)
    $rAfterAck = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    Check 'Stop is silent once acknowledged for the same fingerprint' ($rAfterAck.Exit -eq 0 -and $rAfterAck.Out -eq '') $rAfterAck.Out

    # =====================================================================
    Write-Host '--- acknowledgement: NoUpdate with a concrete reason clears the block ---' -ForegroundColor Cyan
    $hc11 = New-IsolatedHookCopy
    $proj11 = New-GitRepo 'AckNoUpdate'
    Write-Utf8 (Join-Path $proj11 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj11 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj11 'init'
    Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'SessionStart' -LocalAppData $hc11.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj11 'a.ps1') "function A { 2 } # internal-only tweak`n"
    $rBlock11 = Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'Stop' -LocalAppData $hc11.LocalAppData
    $fp11 = Get-Fingerprint $rBlock11.Out
    $rAck11 = FireAck -HookPath $hc11.Script -ProjectRoot $proj11 -Fingerprint $fp11 -Result NoUpdate -Reason 'internal-only change, no documented behavior affected' -LocalAppData $hc11.LocalAppData
    Check 'a valid NoUpdate acknowledgement with a concrete reason succeeds' ($rAck11.Exit -eq 0) ($rAck11.Out + $rAck11.Err)
    $rAfterAck11 = Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'Stop' -LocalAppData $hc11.LocalAppData
    Check 'Stop is silent after a valid NoUpdate acknowledgement' ($rAfterAck11.Exit -eq 0 -and $rAfterAck11.Out -eq '') $rAfterAck11.Out

    # =====================================================================
    Write-Host '--- acknowledgement rejection: empty/generic reasons ---' -ForegroundColor Cyan
    $hc12 = New-IsolatedHookCopy
    $proj12 = New-GitRepo 'AckGenericReason'
    Write-Utf8 (Join-Path $proj12 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj12 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj12 'init'
    Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'SessionStart' -LocalAppData $hc12.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj12 'a.ps1') "function A { 2 }`n"
    $rBlock12 = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'Stop' -LocalAppData $hc12.LocalAppData
    $fp12 = Get-Fingerprint $rBlock12.Out
    $rGeneric1 = FireAck -HookPath $hc12.Script -ProjectRoot $proj12 -Fingerprint $fp12 -Result NoUpdate -Reason 'none' -LocalAppData $hc12.LocalAppData
    Check 'a generic NoUpdate reason ("none") is rejected' ($rGeneric1.Exit -ne 0) ($rGeneric1.Out + $rGeneric1.Err)
    $rGeneric2 = FireAck -HookPath $hc12.Script -ProjectRoot $proj12 -Fingerprint $fp12 -Result NoUpdate -Reason '' -LocalAppData $hc12.LocalAppData
    Check 'an empty NoUpdate reason is rejected' ($rGeneric2.Exit -ne 0) ($rGeneric2.Out + $rGeneric2.Err)
    $rStillBlocked = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'Stop' -LocalAppData $hc12.LocalAppData
    Check 'an unchanged rejected review does not create repeated correction turns' (
        $rStillBlocked.Exit -eq 0 -and $rStillBlocked.Out -eq '' -and $rStillBlocked.Err -eq '') $rStillBlocked.Out
    Check 'a rejected acknowledgement writes no approval record' (
        @(Get-ChildItem -LiteralPath (Join-Path $hc12.LocalAppData 'HookMaker\state') -Filter 'DocsFreshnessCheck-ack-*.json').Count -eq 0)
    $null = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'UserPromptSubmit' -Prompt 'Recheck the rejected review' -LocalAppData $hc12.LocalAppData
    $rRecheck = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'Stop' -LocalAppData $hc12.LocalAppData -StopHookActive
    Check 'a genuine new task still blocks the identical unacknowledged documentation evidence' (
        $rRecheck.Out -match '"decision":"block"' -and (Get-Fingerprint $rRecheck.Out) -eq $fp12) $rRecheck.Out

    # =====================================================================
    Write-Host '--- acknowledgement rejection: out-of-root, private, and untracked paths ---' -ForegroundColor Cyan
    $hc13 = New-IsolatedHookCopy
    $proj13 = New-GitRepo 'AckBadPaths'
    Write-Utf8 (Join-Path $proj13 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj13 'a.ps1') "function A { 1 }`n"
    New-Item -ItemType Directory -Path (Join-Path $proj13 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj13 '.ai\NOTES.md') "private`n"
    Add-Commit $proj13 'init'
    Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'SessionStart' -LocalAppData $hc13.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj13 'a.ps1') "function A { 2 }`n"
    $rBlock13 = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'Stop' -LocalAppData $hc13.LocalAppData
    $fp13 = Get-Fingerprint $rBlock13.Out
    $outsidePath = (Join-Path $Work 'outside.md').Replace('\', '/')
    $rOutside = FireAck -HookPath $hc13.Script -ProjectRoot $proj13 -Fingerprint $fp13 -Result Updated -Files $outsidePath -Reason 'trying to escape the project root' -LocalAppData $hc13.LocalAppData
    Check 'an out-of-root acknowledged path is rejected' ($rOutside.Exit -ne 0) ($rOutside.Out + $rOutside.Err)
    $rPrivate = FireAck -HookPath $hc13.Script -ProjectRoot $proj13 -Fingerprint $fp13 -Result Updated -Files '.ai/NOTES.md' -Reason 'trying to acknowledge a private file' -LocalAppData $hc13.LocalAppData
    Check 'a private/excluded acknowledged path is rejected' ($rPrivate.Exit -ne 0) ($rPrivate.Out + $rPrivate.Err)
    $rUntracked = FireAck -HookPath $hc13.Script -ProjectRoot $proj13 -Fingerprint $fp13 -Result Updated -Files 'NEVER_EXISTED.md' -Reason 'acknowledging a file that does not exist' -LocalAppData $hc13.LocalAppData
    Check 'a non-existent/untracked acknowledged path is rejected' ($rUntracked.Exit -ne 0) ($rUntracked.Out + $rUntracked.Err)

    # =====================================================================
    Write-Host '--- acknowledgement rejection: stale/mismatched fingerprint ---' -ForegroundColor Cyan
    $hc14 = New-IsolatedHookCopy
    $proj14 = New-GitRepo 'AckStaleFingerprint'
    Write-Utf8 (Join-Path $proj14 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj14 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj14 'init'
    Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'SessionStart' -LocalAppData $hc14.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj14 'a.ps1') "function A { 2 }`n"
    $null = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'Stop' -LocalAppData $hc14.LocalAppData
    $wrongFp = 'a' * 10
    $rWrongFp = FireAck -HookPath $hc14.Script -ProjectRoot $proj14 -Fingerprint $wrongFp -Result Updated -Files 'README.md' -Reason 'acknowledging against a made-up fingerprint' -LocalAppData $hc14.LocalAppData
    $rAfterWrongFp = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'Stop' -LocalAppData $hc14.LocalAppData
    Check 'an unchanged mismatched review is deduplicated, not repeatedly emitted' (
        $rAfterWrongFp.Exit -eq 0 -and $rAfterWrongFp.Out -eq '' -and $rAfterWrongFp.Err -eq '') $rAfterWrongFp.Out
    $null = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'UserPromptSubmit' -Prompt 'Recheck the stale review' -LocalAppData $hc14.LocalAppData
    $rRecheck = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'Stop' -LocalAppData $hc14.LocalAppData -StopHookActive
    Check 'a mismatched approval still cannot clear the gate when the task is reevaluated' (
        $rRecheck.Out -match '"decision":"block"' -and (Get-Fingerprint $rRecheck.Out) -ne $wrongFp) $rRecheck.Out

    # =====================================================================
    Write-Host '--- a later non-document change invalidates a previous acknowledgement ---' -ForegroundColor Cyan
    $hc15 = New-IsolatedHookCopy
    $proj15 = New-GitRepo 'AckInvalidated'
    Write-Utf8 (Join-Path $proj15 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj15 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj15 'init'
    Fire -HookPath $hc15.Script -Cwd $proj15 -EventName 'SessionStart' -LocalAppData $hc15.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj15 'a.ps1') "function A { 2 }`n"
    $rBlock15 = Fire -HookPath $hc15.Script -Cwd $proj15 -EventName 'Stop' -LocalAppData $hc15.LocalAppData
    $fp15 = Get-Fingerprint $rBlock15.Out
    $rAck15 = FireAck -HookPath $hc15.Script -ProjectRoot $proj15 -Fingerprint $fp15 -Result Updated -Files 'README.md' -Reason 'documented the change' -LocalAppData $hc15.LocalAppData
    Check 'acknowledgement accepted' ($rAck15.Exit -eq 0) ($rAck15.Out + $rAck15.Err)
    $rQuietAfterAck = Fire -HookPath $hc15.Script -Cwd $proj15 -EventName 'Stop' -LocalAppData $hc15.LocalAppData
    Check 'silent immediately after acknowledgement' ($rQuietAfterAck.Exit -eq 0 -and $rQuietAfterAck.Out -eq '') $rQuietAfterAck.Out
    Write-Utf8 (Join-Path $proj15 'a.ps1') "function A { 3 }`n"
    $rInvalidated = Fire -HookPath $hc15.Script -Cwd $proj15 -EventName 'Stop' -LocalAppData $hc15.LocalAppData
    Check 'a further non-doc change invalidates the old acknowledgement and blocks again' ($rInvalidated.Out -match '"decision":"block"') $rInvalidated.Out

    # =====================================================================
    Write-Host '--- a documentation-only task never blocks (nothing to loop on) ---' -ForegroundColor Cyan
    $hc16 = New-IsolatedHookCopy
    $proj16 = New-GitRepo 'DocsOnlyTask'
    Write-Utf8 (Join-Path $proj16 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj16 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj16 'init'
    Fire -HookPath $hc16.Script -Cwd $proj16 -EventName 'SessionStart' -LocalAppData $hc16.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj16 'README.md') "# Proj`n`nExpanded docs, no code touched this task.`n"
    $r = Fire -HookPath $hc16.Script -Cwd $proj16 -EventName 'Stop' -LocalAppData $hc16.LocalAppData
    Check 'a documentation-only task is silent (no non-doc impact to review)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r2 = Fire -HookPath $hc16.Script -Cwd $proj16 -EventName 'Stop' -LocalAppData $hc16.LocalAppData
    Check 'repeating the same Stop stays silent (no loop)' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out

    # =====================================================================
    Write-Host '--- stop_hook_active is silent even with a pending review ---' -ForegroundColor Cyan
    $hc17 = New-IsolatedHookCopy
    $proj17 = New-GitRepo 'StopHookActive'
    Write-Utf8 (Join-Path $proj17 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj17 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj17 'init'
    Fire -HookPath $hc17.Script -Cwd $proj17 -EventName 'SessionStart' -LocalAppData $hc17.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj17 'a.ps1') "function A { 2 }`n"
    $r = Fire -HookPath $hc17.Script -Cwd $proj17 -EventName 'Stop' -StopHookActive -LocalAppData $hc17.LocalAppData
    # stop_hook_active means "a Stop gate blocked and the agent is coming
    # back" - NOT "YOU blocked". Thirteen gates share the one flag, so a gate
    # standing down on it alone went silent for somebody else's block, and
    # the next Stop ran with the secret-leak, UTF-8 and CI gates all muted.
    # Each gate now stands down only on its OWN re-entry, proven by a marker
    # it writes itself immediately before it blocks.
    Check 'stop_hook_active ALONE does not suppress the review request (another gate blocked, not this one)' ($r.Exit -eq 0 -and $r.Out -ne '') $r.Out

    # =====================================================================
    Write-Host '--- the hook never edits a doc file itself ---' -ForegroundColor Cyan
    $hc18 = New-IsolatedHookCopy
    $proj18 = New-GitRepo 'NeverEditsDocs'
    Write-Utf8 (Join-Path $proj18 'README.md') "# Proj original content`n"
    Write-Utf8 (Join-Path $proj18 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj18 'init'
    Fire -HookPath $hc18.Script -Cwd $proj18 -EventName 'SessionStart' -LocalAppData $hc18.LocalAppData | Out-Null
    Write-Utf8 (Join-Path $proj18 'a.ps1') "function A { 2 }`n"
    $readmeBefore = [System.IO.File]::ReadAllText((Join-Path $proj18 'README.md'))
    $null = Fire -HookPath $hc18.Script -Cwd $proj18 -EventName 'Stop' -LocalAppData $hc18.LocalAppData
    $readmeAfter = [System.IO.File]::ReadAllText((Join-Path $proj18 'README.md'))
    Check 'README.md is byte-for-byte unchanged after a Stop review request (the hook never writes docs itself)' ($readmeBefore -eq $readmeAfter)

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $hc19 = New-IsolatedHookCopy
    $proj19 = New-GitRepo 'Host51'
    Write-Utf8 (Join-Path $proj19 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $proj19 'a.ps1') "function A { 1 }`n"
    Add-Commit $proj19 'init'
    Fire -HookPath $hc19.Script -Cwd $proj19 -EventName 'SessionStart' -LocalAppData $hc19.LocalAppData -Exe 'powershell.exe' | Out-Null
    Write-Utf8 (Join-Path $proj19 'a.ps1') "function A { 2 }`n"
    $r = Fire -HookPath $hc19.Script -Cwd $proj19 -EventName 'Stop' -LocalAppData $hc19.LocalAppData -Exe 'powershell.exe'
    Check '5.1 host: detects the change and blocks' ($r.Exit -eq 0 -and $r.Out -match '"decision":"block"') $r.Out

    # =====================================================================
    Write-Host '--- Stop detection-error catch path: Codex gets systemMessage, not additionalContext ---' -ForegroundColor Cyan
    $hcErr = New-IsolatedHookCopy
    $projErr = New-GitRepo 'DetectionErrorCodex'
    Write-Utf8 (Join-Path $projErr 'README.md') "# Proj`n"
    Write-Utf8 (Join-Path $projErr 'a.ps1') "function A { 1 }`n"
    Add-Commit $projErr 'init'
    Fire -HookPath $hcErr.Script -Cwd $projErr -EventName 'SessionStart' -LocalAppData $hcErr.LocalAppData | Out-Null
    $baselineFileErr = @(Get-ChildItem -LiteralPath (Join-Path $hcErr.LocalAppData 'HookMaker\state') -Filter 'DocsFreshnessCheck-baseline-*.json' -ErrorAction SilentlyContinue)
    Check 'a baseline was written to corrupt for this test' ($baselineFileErr.Count -eq 1)
    # Corrupt the baseline state file directly - Read-JsonFile's ConvertFrom-Json then
    # throws (a realistic "detection error", e.g. a truncated/corrupted state write),
    # forcing the Stop handler's catch path exactly like a real detection failure would.
    if ($baselineFileErr.Count -eq 1) {
        [System.IO.File]::WriteAllText($baselineFileErr[0].FullName, '{ not valid json !!!', (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Utf8 (Join-Path $projErr 'a.ps1') "function A { 2 }`n"
    # Simulate the Codex client (no CLAUDE_PROJECT_DIR) regardless of the ambient
    # environment this suite happens to run under - restored in the finally below.
    $OrigClaudeProjectDirC2 = $env:CLAUDE_PROJECT_DIR
    if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    try {
        $rCodex = Fire -HookPath $hcErr.Script -Cwd $projErr -EventName 'Stop' -LocalAppData $hcErr.LocalAppData
    }
    finally {
        if ([string]::IsNullOrEmpty($OrigClaudeProjectDirC2)) {
            if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
        }
        else { $env:CLAUDE_PROJECT_DIR = $OrigClaudeProjectDirC2 }
    }
    $codexParsed = $null
    try { $codexParsed = $rCodex.Out | ConvertFrom-Json } catch { }
    Check 'Codex (no CLAUDE_PROJECT_DIR): the catch path exits cleanly (exit 0, no stderr)' ($rCodex.Exit -eq 0 -and $rCodex.Err -eq '') ($rCodex.Out + ' | err=' + $rCodex.Err)
    Check 'Codex (no CLAUDE_PROJECT_DIR): the detection-error warning is emitted as systemMessage' (
        $null -ne $codexParsed -and $null -ne $codexParsed.PSObject.Properties['systemMessage'] -and
        [string]$codexParsed.systemMessage -match 'DOCS FRESHNESS CHECK') $rCodex.Out
    Check 'Codex output never uses hookSpecificOutput.additionalContext for this warning' (
        $null -ne $codexParsed -and $null -eq $codexParsed.PSObject.Properties['hookSpecificOutput']) $rCodex.Out
    # Once per session: on Claude Code a Stop additionalContext re-invokes the
    # model, so a persistent detection error repeated on every Stop was a loop
    # with nothing to act on. The corrupt baseline is still in place here.
    $rAgain = Fire -HookPath $hcErr.Script -Cwd $projErr -EventName 'Stop' -LocalAppData $hcErr.LocalAppData
    Check 'the detection-error warning is NOT repeated to the same session (exit 0, silent)' ($rAgain.Exit -eq 0 -and $rAgain.Out -eq '') $rAgain.Out
    $rNew = Fire -HookPath $hcErr.Script -Cwd $projErr -EventName 'Stop' -SessionId 'sess2' -LocalAppData $hcErr.LocalAppData
    Check 'a NEW session is warned again' ($rNew.Out -match 'DOCS FRESHNESS CHECK') $rNew.Out

    # =====================================================================
    Write-Host '--- Install-Hook.ps1: self-contained Claude + Codex copies ---' -ForegroundColor Cyan
    $tgt = New-Proj 'Install'
    & $InstallScript -CustomHook $Hook -Events @('SessionStart', 'Stop') -TargetProject $tgt *> $null
    $claudeJson = ''
    if (Test-Path (Join-Path $tgt '.claude\settings.local.json')) { $claudeJson = [System.IO.File]::ReadAllText((Join-Path $tgt '.claude\settings.local.json')) }
    Check 'Claude gets a self-contained runtime copy' (
        ($claudeJson -like '*hooks\\Hook-Maker\\Docs-Freshness-Check\\Docs-Freshness-Check.ps1*') -and
        (Test-Path (Join-Path $tgt '.claude\hooks\Hook-Maker\Docs-Freshness-Check\Docs-Freshness-Check.ps1')) -and
        (Test-Path (Join-Path $tgt '.claude\hooks\Hook-Maker\Docs-Freshness-Check\_hooklib.ps1')))
    Check 'Claude command does not point back at the tool''s own hooks directory' ($claudeJson -notlike ('*' + ((Split-Path -Parent $PSScriptRoot) + '\hooks\').Replace('\', '\\') + '*'))
    $codexJson = ''
    if (Test-Path (Join-Path $tgt '.codex\hooks.json')) { $codexJson = [System.IO.File]::ReadAllText((Join-Path $tgt '.codex\hooks.json')) }
    Check 'Codex gets a self-contained runtime copy' (
        ($codexJson -like '*hooks\\Hook-Maker\\Docs-Freshness-Check\\Docs-Freshness-Check.ps1*') -and
        (Test-Path (Join-Path $tgt '.codex\hooks\Hook-Maker\Docs-Freshness-Check\Docs-Freshness-Check.ps1')))
    Check 'Codex command does not point back at the tool''s own hooks directory' ($codexJson -notlike ('*' + ((Split-Path -Parent $PSScriptRoot) + '\hooks\').Replace('\', '\\') + '*'))
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
