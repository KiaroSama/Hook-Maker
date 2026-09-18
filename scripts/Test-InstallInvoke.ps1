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

# Every fixture carries its schema, because every real result does: the stubs
# used to model the `overall` field alone, which is precisely the trust the
# validator refuses now.
$okJson = '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok","reason":""},{"component":"codex","status":"ok","reason":""}]}'
$degradedJson = '{"schema":1,"overall":"partial","components":[{"component":"claude","status":"ok","reason":"degraded"},{"component":"codex","status":"ok","reason":""}]}'
$failedComponentJson = '{"schema":1,"overall":"partial","components":[{"component":"claude","status":"failed","reason":"settingsWriteFailed"},{"component":"codex","status":"ok","reason":""}]}'
$trackingJson = '{"schema":1,"overall":"partial","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"ok"},{"component":"registry","status":"trackingFailed","reason":"registryUnavailable"}]}'
$postRegJson = '{"schema":1,"overall":"partial","components":[{"component":"claude","status":"ok","reason":"postRegistrationError"},{"component":"codex","status":"ok","reason":""}]}'
$hardFailJson = '{"schema":1,"overall":"failed","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"failed","reason":"settingsWriteFailed"}]}'
$unknownOverallJson = '{"schema":1,"overall":"something-new","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"ok"}]}'
$emptyPartialJson = '{"schema":1,"overall":"partial","components":[{"component":"claude","status":"skipped","reason":"mystery"},{"component":"codex","status":"ok"}]}'

# ---- R09: a document that exists is not automatically a result -------------
$bareOkJson = '{"overall":"ok"}'
$noSchemaJson = '{"overall":"ok","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"ok"}]}'
$futureSchemaJson = '{"schema":99,"overall":"ok","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"ok"}]}'
$noComponentsJson = '{"schema":1,"overall":"ok","components":[]}'
$contradictoryJson = '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"ok"},{"component":"registry","status":"trackingFailed","reason":"registryUnavailable"}]}'
$failedNoComponentJson = '{"schema":1,"overall":"failed","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"ok"}]}'
$badStatusJson = '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"installed-probably"},{"component":"codex","status":"ok"}]}'
$namelessJson = '{"schema":1,"overall":"ok","components":[{"status":"ok"},{"component":"codex","status":"ok"}]}'
$arrayJson = '[{"schema":1,"overall":"ok"}]'
$scalarJson = '"ok"'

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
    # R09: every one of these WAS accepted, or threw, on the strength of a
    # single `overall` field. None of them is evidence of an install.
    @{ Name = 'a bare {overall:ok} with no schema and no components is unknown'; Stub = (New-ResultStub 'bareok' $bareOkJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'a schema-less document is unknown'; Stub = (New-ResultStub 'noschema' $noSchemaJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'a FUTURE schema is unknown, never read as green'; Stub = (New-ResultStub 'futureschema' $futureSchemaJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'ok with no components at all is unknown'; Stub = (New-ResultStub 'nocomponents' $noComponentsJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'ok CONTRADICTED by a failed component is unknown'; Stub = (New-ResultStub 'contradictory' $contradictoryJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'failed with no failed component is unknown'; Stub = (New-ResultStub 'failednocomp' $failedNoComponentJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'an unrecognized component status is unknown'; Stub = (New-ResultStub 'badstatus' $badStatusJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'a component with no name is unknown'; Stub = (New-ResultStub 'nameless' $namelessJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'a JSON ARRAY is unknown, and does not throw'; Stub = (New-ResultStub 'arraydoc' $arrayJson); ExpectOk = $false; ExpectStatus = 'unknown' }
    @{ Name = 'a bare JSON scalar is unknown, and does not throw'; Stub = (New-ResultStub 'scalardoc' $scalarJson); ExpectOk = $false; ExpectStatus = 'unknown' }
)

foreach ($case in $cases) {
    $verdict = Invoke-HookInstaller -InstallScript $case.Stub -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work }
    Check ($case.Name + ' -> Ok=' + $case.ExpectOk) ($verdict.Ok -eq $case.ExpectOk) ('got Ok=' + $verdict.Ok + ' status=' + $verdict.Status + ' summary=' + $verdict.Summary)
    Check ($case.Name + ' -> Status=' + $case.ExpectStatus) ([string]$verdict.Status -eq $case.ExpectStatus) ('got ' + $verdict.Status)
    Check ($case.Name + ' -> Summary is never empty') (-not [string]::IsNullOrWhiteSpace([string]$verdict.Summary)) ''
}

# ---- L09: requested clients come from the SAME resolver the installer uses -
# Legacy switches were the only form recognised, so the canonical -Clients array
# named a client nothing then checked for; and "no switch" was read as "nothing
# requested", although Install-Hook.ps1 defaults to claude+codex.
$clientCases = @(
    @{ Name = 'no switches -> the installer default, both clients'; Args = @{}; Expect = @('claude', 'codex') }
    @{ Name = 'legacy -ClaudeOnly'; Args = @{ ClaudeOnly = $true }; Expect = @('claude') }
    @{ Name = 'legacy -CodexOnly'; Args = @{ CodexOnly = $true }; Expect = @('codex') }
    @{ Name = 'canonical -Clients with one id'; Args = @{ Clients = @('codex') }; Expect = @('codex') }
    @{ Name = 'canonical -Clients with both'; Args = @{ Clients = @('claude', 'codex') }; Expect = @('claude', 'codex') }
    @{ Name = 'canonical -Clients is case- and space-tolerant'; Args = @{ Clients = @(' Claude ') }; Expect = @('claude') }
    @{ Name = 'duplicate ids collapse'; Args = @{ Clients = @('claude', 'claude') }; Expect = @('claude') }
)
foreach ($case in $clientCases) {
    $got = @(Get-RequestedInstallClients -InstallArgs $case.Args)
    Check ('requested clients: ' + $case.Name) (
        ((@($got) | Sort-Object) -join ',') -eq ((@($case.Expect) | Sort-Object) -join ',')) (
        'got [' + ($got -join ',') + '] want [' + ($case.Expect -join ',') + ']')
}

# A NAMED client is not an INSTALLED client.
$skippedClientJson = '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok"},{"component":"codex","status":"skipped","reason":"notSelected"}]}'
$skippedStub = New-ResultStub 'skippedclient' $skippedClientJson
$v = Invoke-HookInstaller -InstallScript $skippedStub -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work }
Check 'a requested client reported SKIPPED does not satisfy overall=ok' (
    -not $v.Ok -and [string]$v.Status -eq 'unknown') ('got ' + $v.Status + ': ' + $v.Summary)
Check 'and the summary names the client and its actual status' (
    $v.Summary -match 'codex' -and $v.Summary -match 'skipped') $v.Summary
$v = Invoke-HookInstaller -InstallScript $skippedStub -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work; ClaudeOnly = $true }
Check 'the same document IS fine when only claude was requested' ($v.Ok) ('got ' + $v.Status + ': ' + $v.Summary)

# postRegistrationError is a REASON, so it rode along inside an overall=ok.
$postRegOkJson = '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok","reason":"postRegistrationError"},{"component":"codex","status":"ok"}]}'
$v = Invoke-HookInstaller -InstallScript (New-ResultStub 'postregok' $postRegOkJson) -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work }
Check 'a post-registration error inside an overall=ok document is not success' (
    -not $v.Ok -and [string]$v.Status -eq 'unknown') ('got ' + $v.Status + ': ' + $v.Summary)

# ---- R09: a client that was ASKED FOR must appear in the result ------------
# Silence about a requested client is not 'installed by default'; nothing said
# anything about it at all. A client that was NOT asked for is a different
# matter - with neither switch the installer picks from what the machine has,
# so demanding both would fail a good install on a one-client box.
$codexOnlyResult = New-ResultStub 'codexonly' '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok"}]}'
$v = Invoke-HookInstaller -InstallScript $codexOnlyResult -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work; CodexOnly = $true }
Check 'a result that never mentions the REQUESTED client is unknown' (
    -not $v.Ok -and [string]$v.Status -eq 'unknown') ('got ' + $v.Status + ': ' + $v.Summary)
Check 'and the summary names the client it never heard about' ($v.Summary -match 'codex') $v.Summary
$v = Invoke-HookInstaller -InstallScript $codexOnlyResult -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work; ClaudeOnly = $true }
Check 'the same document IS accepted when claude is the requested client' ($v.Ok) ('got ' + $v.Status + ': ' + $v.Summary)
$v = Invoke-HookInstaller -InstallScript $codexOnlyResult -InstallArgs @{ CustomHook = 'x.ps1'; TargetProject = $Work }
# With NO switch the installer asks for BOTH clients, so a document naming only
# one is incomplete rather than fine. This assertion used to claim the opposite,
# which is exactly the reading L09 corrects: "no switch" is a real request.
Check 'with NO switch the default request is both, so a one-client result is incomplete' (
    -not $v.Ok -and $v.Summary -match 'codex') ('got ' + $v.Status + ': ' + $v.Summary)

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
