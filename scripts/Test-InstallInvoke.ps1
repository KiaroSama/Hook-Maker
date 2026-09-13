# Offline test suite for scripts\_installinvoke.ps1 - the ONE path the wizard
# uses to invoke Install-Hook.ps1 and decide whether an install succeeded.
#
# What it pins (F10): the fresh and config-driven install flows used to capture
# the installer's console output and then print "+ installed" unconditionally.
# The installer reports a partial or failed outcome by writing `overall` into
# its RESULT DOCUMENT and returning normally - it does not throw and it does not
# exit non-zero - so "no exception" was never evidence of success. An install
# whose runtime and settings landed but whose registry tracking FAILED was being
# reported to the user as clean.
#
# The contract these assertions fix in place: success comes from a VALID
# structured result and nothing else. Missing, unreadable, unparseable or
# unrecognized output is 'unknown', and unknown is never success.
#
# Cost: every case runs a tiny stub .ps1 instead of a real installer - no client
# is touched, no registry is written, no project is modified. One workspace and
# one stub set are built once and shared by every case.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstallInvoke.ps1
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_testlib.ps1')
. (Join-Path $PSScriptRoot '_installinvoke.ps1')

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

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-invoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $Work -Force)

# Each stub is a real script the function invokes exactly as it invokes the
# installer: it accepts -ResultPath, writes (or refuses to write) a result
# document, and returns normally. NONE of them throws unless the case is about
# throwing, because a throwing installer was never the hard case.
function New-Stub {
    param([string]$Name, [string]$Body)
    $path = Join-Path $Work ($Name + '.ps1')
    $text = @'
param([string]$ResultPath, [string]$CustomHook, $Events, [string]$TargetProject, $Clients, [int]$Timeout)
Write-Output 'stub installer ran'
'@ + [Environment]::NewLine + $Body + [Environment]::NewLine
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function New-ResultStub {
    param([string]$Name, [string]$Json)
    return New-Stub -Name $Name -Body ('[System.IO.File]::WriteAllText($ResultPath, ' + "'" + ($Json -replace "'", "''") + "'" + ')')
}

$okJson = '{"overall":"ok","components":[{"component":"claude","status":"ok","reason":""}]}'
$degradedJson = '{"overall":"partial","components":[{"component":"claude","status":"ok","reason":"degraded"}]}'
$failedComponentJson = '{"overall":"partial","components":[{"component":"claude","status":"failed","reason":"settingsWriteFailed"}]}'
$trackingJson = '{"overall":"partial","components":[{"component":"registry","status":"trackingFailed","reason":"registryUnavailable"}]}'
$postRegJson = '{"overall":"partial","components":[{"component":"claude","status":"ok","reason":"postRegistrationError"}]}'
$hardFailJson = '{"overall":"failed","components":[{"component":"codex","status":"failed","reason":"settingsWriteFailed"}]}'
$unknownOverallJson = '{"overall":"something-new","components":[]}'
$emptyPartialJson = '{"overall":"partial","components":[]}'

# ---- the table: stub -> expected verdict -----------------------------------
# Ok is the only thing a caller is allowed to print a green line from.
$cases = @(
    @{ Name = 'ok'; Stub = (New-ResultStub 'ok' $okJson); ExpectOk = $true; ExpectStatus = 'ok' }
    @{ Name = 'partial with a degraded component is a real install'; Stub = (New-ResultStub 'degraded' $degradedJson); ExpectOk = $true; ExpectStatus = 'ok' }
    @{ Name = 'partial with a FAILED component is not success'; Stub = (New-ResultStub 'failedcomp' $failedComponentJson); ExpectOk = $false; ExpectStatus = 'failed' }
    @{ Name = 'trackingFailed is not success'; Stub = (New-ResultStub 'tracking' $trackingJson); ExpectOk = $false; ExpectStatus = 'failed' }
    @{ Name = 'postRegistrationError is not success'; Stub = (New-ResultStub 'postreg' $postRegJson); ExpectOk = $false; ExpectStatus = 'failed' }
    @{ Name = 'overall=failed is not success'; Stub = (New-ResultStub 'hardfail' $hardFailJson); ExpectOk = $false; ExpectStatus = 'failed' }
    @{ Name = 'partial with no recognizable reason is not success'; Stub = (New-ResultStub 'emptypartial' $emptyPartialJson); ExpectOk = $false; ExpectStatus = 'failed' }
    @{ Name = 'an unrecognized overall value is unknown, not ok'; Stub = (New-ResultStub 'unknownoverall' $unknownOverallJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'NO result document at all is unknown, not ok'; Stub = (New-Stub 'noresult' '# writes nothing at all'); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'malformed JSON is unknown, not ok'; Stub = (New-Stub 'malformed' '[System.IO.File]::WriteAllText($ResultPath, ''{not json'')'); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'an empty result file is unknown, not ok'; Stub = (New-Stub 'emptyfile' '[System.IO.File]::WriteAllText($ResultPath, [string]::Empty)'); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'a throwing installer is a failure, not unknown'; Stub = (New-Stub 'throws' "throw 'installer exploded'"); ExpectOk = $false; ExpectStatus = 'failed' }
)

foreach ($case in $cases) {
    $verdict = Invoke-HookInstaller -InstallScript $case.Stub -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work }
    Check ($case.Name + ' -> Ok=' + $case.ExpectOk) ($verdict.Ok -eq $case.ExpectOk) ('got Ok=' + $verdict.Ok + ' status=' + $verdict.Status + ' summary=' + $verdict.Summary)
    Check ($case.Name + ' -> Status=' + $case.ExpectStatus) ([string]$verdict.Status -eq $case.ExpectStatus) ('got ' + $verdict.Status)
    Check ($case.Name + ' -> Summary is never empty') (-not [string]::IsNullOrWhiteSpace([string]$verdict.Summary)) ''
}

# ---- the result file is OURS and is always cleaned up ----------------------
# A caller-supplied ResultPath would let one flow opt out of the very check this
# function exists to enforce, so it must be ignored rather than honoured.
$plantedPath = Join-Path $Work 'planted-result.json'
[System.IO.File]::WriteAllText($plantedPath, $hardFailJson, (New-Object System.Text.UTF8Encoding($false)))
$okStub = @($cases | Where-Object { $_.Name -eq 'ok' })[0]['Stub']
$verdict = Invoke-HookInstaller -InstallScript $okStub -InstallArgs @{ ResultPath = $plantedPath; CustomHook = 'x.ps1' }
Check 'a caller-supplied ResultPath cannot override the verdict' ($verdict.Ok -eq $true) ('status=' + $verdict.Status + ' summary=' + $verdict.Summary)
Check 'the planted file is left untouched (it was never used)' ([System.IO.File]::ReadAllText($plantedPath) -eq $hardFailJson) ''

$before = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'hookmaker-install-result-*.json' -File -ErrorAction SilentlyContinue).Count
$null = Invoke-HookInstaller -InstallScript $okStub -InstallArgs @{ CustomHook = 'x.ps1' }
$throwStub = @($cases | Where-Object { $_.Name -eq 'a throwing installer is a failure, not unknown' })[0]['Stub']
$null = Invoke-HookInstaller -InstallScript $throwStub -InstallArgs @{ CustomHook = 'x.ps1' }
$after = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'hookmaker-install-result-*.json' -File -ErrorAction SilentlyContinue).Count
Check 'no result document leaks, on the success OR the throwing path' ($after -le $before) ('before=' + $before + ' after=' + $after)

# ---- the installer's own output still reaches the caller for logging -------
$verdict = Invoke-HookInstaller -InstallScript $okStub -InstallArgs @{ CustomHook = 'x.ps1' }
Check 'the installer console output is returned for the log' ((@($verdict.Output) -join "`n") -match 'stub installer ran') ''

# ---- negative control: the table must be able to FAIL ----------------------
# Without this, a function that returned a constant $false Ok would satisfy nine
# of the twelve cases above and the suite would still look meaningful.
Check 'negative control: at least one case expects Ok=$true' ((@($cases | Where-Object { $_.ExpectOk }).Count) -ge 2) ''
Check 'negative control: at least one case expects Ok=$false' ((@($cases | Where-Object { -not $_.ExpectOk }).Count) -ge 8) ''

if (-not $KeepArtifacts) {
    if (-not (Remove-TestWorkspace -Path @($Work))) { $script:Fail++ ; Write-Host '[FAIL] workspace cleanup left files behind' -ForegroundColor Red }
}
else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
