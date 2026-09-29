# Offline test suite for scripts\Report-HookCost.ps1 - the read-only per-hook
# Stop cost report built from Claude Code's session transcripts.
#
# WHAT IT PINS. The statistics match the arithmetic (median = mean of the two
# middle values for an even count, p95 = nearest rank), a malformed line or a
# record without hookInfos is skipped while the rest still count, an entry
# without durationMs lands in the no-duration column, the registered timeout
# comes from the project's settings.local.json, the project folder lookup uses
# the client's sanitizing rule, a project with no transcript folder exits 0
# with a plain message, and no command string ever reaches the output.
#
# Cost: one workspace, a few small JSONL files, six short child runs of the
# script. No network, no sleep, nothing outside the workspace is written.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-ReportHookCost.ps1
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$Report = Join-Path $ScriptRoot 'Report-HookCost.ps1'

. (Join-Path $ScriptRoot '_testlib.ps1')

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

$Work = New-TestWorkspace -Prefix 'hookmaker-hookcost'
$PwshPath = (Get-Process -Id $PID).Path
$script:RunIndex = 0

function Invoke-Report {
    param([string[]]$Arguments)
    $script:RunIndex++
    $out = Join-Path $Work ('out-' + $script:RunIndex + '.txt')
    $err = Join-Path $Work ('err-' + $script:RunIndex + '.txt')
    $proc = Start-BoundedProcess -FilePath $PwshPath -ArgumentList (@('-NoLogo', '-NoProfile', '-File', $Report) + $Arguments) `
        -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutMs 60000
    $text = ''
    if (Test-Path -LiteralPath $out) { $text = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8) }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $text }
}

function New-HookInfo {
    param([string]$Hook, $DurationMs)
    $info = [ordered]@{ command = ('powershell.exe -NoLogo -NoProfile -File "C:\fixture tool\' + $Hook + '\' + $Hook + '.ps1"') }
    if ($null -ne $DurationMs) { $info.durationMs = $DurationMs }
    return $info
}

function ConvertTo-SummaryLine {
    param([object[]]$Infos)
    $record = [ordered]@{
        parentUuid = 'p'; isSidechain = $false; type = 'system'; subtype = 'stop_hook_summary'
        hookCount = @($Infos).Count; hookInfos = @($Infos); hookErrors = @()
    }
    return ($record | ConvertTo-Json -Depth 5 -Compress)
}

function Get-Row {
    param($Parsed, [string]$Hook)
    return @($Parsed.Rows | Where-Object { $_.Hook -eq $Hook }) | Select-Object -First 1
}

$savedUserProfile = $env:USERPROFILE
try {
    # --- fixture 1: five records, three hooks, known durations ---------------
    $a = @(1000, 2000, 3000, 4000, 5000)
    $b = @(100, 100, 200, 400, 60000)
    $c = @(10, 20, 30, 40)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('{"type":"user","message":"unrelated line"}')
    for ($i = 0; $i -lt 5; $i++) {
        $infos = @((New-HookInfo 'Hook-A' $a[$i]), (New-HookInfo 'Hook-B' $b[$i]))
        if ($i -lt 4) { $infos += (New-HookInfo 'Hook-C' $c[$i]) }
        [void]$lines.Add((ConvertTo-SummaryLine $infos))
    }
    $known = Join-Path $Work 'known.jsonl'
    Write-Utf8 -Path $known -Content (($lines.ToArray() -join "`n") + "`n")

    # A project whose installed registration gives Hook-B a 30 s Stop timeout
    # and a larger one on another event, which must lose to Stop.
    $project = Join-Path $Work 'fixture project'
    $settings = [ordered]@{
        hooks = [ordered]@{
            SessionStart = @(@{ hooks = @(@{ type = 'command'; command = (New-HookInfo 'Hook-B' $null).command; timeout = 90 }) })
            Stop         = @(@{ hooks = @(@{ type = 'command'; command = (New-HookInfo 'Hook-B' $null).command; timeout = 30 }) })
        }
    }
    Write-Utf8 -Path (Join-Path $project '.claude\settings.local.json') -Content ($settings | ConvertTo-Json -Depth 8)

    $run = Invoke-Report @('-TranscriptPath', $known, '-ProjectRoot', $project, '-Json')
    $parsed = $null
    try { $parsed = $run.Output | ConvertFrom-Json } catch { $parsed = $null }
    Check 'known durations: exit 0 and JSON output' ($run.ExitCode -eq 0 -and $null -ne $parsed) $run.Output
    if ($null -ne $parsed) {
        $rowA = Get-Row $parsed 'Hook-A'; $rowB = Get-Row $parsed 'Hook-B'; $rowC = Get-Row $parsed 'Hook-C'
        Check 'five records counted' ($parsed.RecordCount -eq 5) ([string]$parsed.RecordCount)
        Check 'odd count: median/p95/max of Hook-A match the arithmetic' (
            $rowA.Count -eq 5 -and $rowA.MedianMs -eq 3000 -and $rowA.P95Ms -eq 5000 -and $rowA.MaxMs -eq 5000) ($rowA | Out-String)
        Check 'even count: Hook-C median is the mean of the middle two, p95 is the nearest rank' (
            $rowC.Count -eq 4 -and $rowC.MedianMs -eq 25 -and $rowC.P95Ms -eq 40 -and $rowC.MaxMs -eq 40) ($rowC | Out-String)
        Check 'Stop registration timeout (30 s) wins and counts the one invocation past it' (
            $rowB.TimeoutSeconds -eq 30 -and $rowB.AtOrOverTimeout -eq 1 -and $rowB.MedianMs -eq 200) ($rowB | Out-String)
        Check 'a hook without a registration uses the 60 s default' ($rowA.TimeoutSeconds -eq 60 -and $rowA.AtOrOverTimeout -eq 0) ($rowA | Out-String)
        Check 'rows are sorted by median descending' ((@($parsed.Rows | ForEach-Object { $_.Hook }) -join ',') -eq 'Hook-A,Hook-B,Hook-C') ''
    }
    Check 'JSON output leaks no command string' (-not $run.Output.Contains('-File') -and -not $run.Output.Contains('powershell.exe')) ''

    $text = Invoke-Report @('-TranscriptPath', $known, '-ProjectRoot', $project)
    Check 'text output: a table row per hook and the caveat footer' (
        $text.ExitCode -eq 0 -and $text.Output -match '(?m)^Hook-A\s+5\s+0\s+3\.0s\s+5\.0s\s+5\.0s' -and
        $text.Output.Contains('undocumented client field')) $text.Output
    Check 'text output leaks no command string' (-not $text.Output.Contains('-File "') -and -not $text.Output.Contains('fixture tool')) ''

    # --- fixture 2: a malformed line and a record without hookInfos ----------
    $malformed = Join-Path $Work 'malformed.jsonl'
    Write-Utf8 -Path $malformed -Content ((@(
                (ConvertTo-SummaryLine @((New-HookInfo 'Hook-A' 1000))),
                '{"type":"system","subtype":"stop_hook_summary","hookInfos":[{"command":"broken',
                '{"type":"system","subtype":"stop_hook_summary","hookCount":0}',
                (ConvertTo-SummaryLine @((New-HookInfo 'Hook-A' 3000)))
            ) -join "`n") + "`n")
    $run = Invoke-Report @('-TranscriptPath', $malformed, '-ProjectRoot', $project, '-Json')
    $parsed = $null
    try { $parsed = $run.Output | ConvertFrom-Json } catch { $parsed = $null }
    $rowA = if ($null -ne $parsed) { Get-Row $parsed 'Hook-A' } else { $null }
    Check 'malformed line and hookInfos-less record are skipped, the rest counted' (
        $run.ExitCode -eq 0 -and $null -ne $rowA -and $parsed.RecordCount -eq 2 -and $parsed.SkippedLines -eq 2 -and
        $rowA.Count -eq 2 -and $rowA.MedianMs -eq 2000) $run.Output

    # --- fixture 3: entries without durationMs --------------------------------
    $noDuration = Join-Path $Work 'noduration.jsonl'
    Write-Utf8 -Path $noDuration -Content ((@(
                (ConvertTo-SummaryLine @((New-HookInfo 'Hook-A' 1500), (New-HookInfo 'Hook-B' $null))),
                (ConvertTo-SummaryLine @((New-HookInfo 'Hook-A' $null), (New-HookInfo 'Hook-B' $null))),
                (ConvertTo-SummaryLine @(@{ command = 'node C:\plugin\hook.js' }))
            ) -join "`n") + "`n")
    $run = Invoke-Report @('-TranscriptPath', $noDuration, '-ProjectRoot', $project, '-Json')
    $parsed = $null
    try { $parsed = $run.Output | ConvertFrom-Json } catch { $parsed = $null }
    if ($null -ne $parsed) {
        $rowA = Get-Row $parsed 'Hook-A'; $rowB = Get-Row $parsed 'Hook-B'; $other = Get-Row $parsed '(other)'
        Check 'an entry without durationMs is counted in the no-duration column' (
            $rowA.Count -eq 2 -and $rowA.NoDuration -eq 1 -and $rowA.MedianMs -eq 1500) ($rowA | Out-String)
        Check 'a hook with no duration at all still gets a row, with no statistics' (
            $rowB.Count -eq 2 -and $rowB.NoDuration -eq 2 -and $null -eq $rowB.MedianMs) ($rowB | Out-String)
        Check 'a command without -File is grouped under (other)' ($null -ne $other -and $other.Count -eq 1) ''
    }
    else { Check 'no-duration fixture produced JSON' $false $run.Output }

    # --- project folder lookup, isolated from the real profile ----------------
    $env:USERPROFILE = Join-Path $Work 'profile'
    $sanitized = $project -replace '[^A-Za-z0-9]', '-'
    $folder = Join-Path $env:USERPROFILE (Join-Path '.claude\projects' $sanitized)
    $older = Join-Path $folder 'older.jsonl'
    $newer = Join-Path $folder 'newer.jsonl'
    Write-Utf8 -Path $older -Content ((ConvertTo-SummaryLine @((New-HookInfo 'Hook-Old' 1000))) + "`n")
    Write-Utf8 -Path $newer -Content ((ConvertTo-SummaryLine @((New-HookInfo 'Hook-New' 1000))) + "`n")
    (Get-Item -LiteralPath $older).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-1)
    $run = Invoke-Report @('-ProjectRoot', $project, '-Newest', '1', '-Json')
    $parsed = $null
    try { $parsed = $run.Output | ConvertFrom-Json } catch { $parsed = $null }
    Check 'the project folder is found by the sanitizing rule and -Newest 1 reads only the newest file' (
        $null -ne $parsed -and $parsed.FilesRead -eq 1 -and $null -ne (Get-Row $parsed 'Hook-New') -and
        $null -eq (Get-Row $parsed 'Hook-Old')) $run.Output

    $missingRoot = Join-Path $Work 'no-such-project'
    $run = Invoke-Report @('-ProjectRoot', $missingRoot)
    Check 'a project without a transcript folder exits 0 with the plain message' (
        $run.ExitCode -eq 0 -and $run.Output.Contains('No transcript folder found for ' + $missingRoot)) $run.Output
}
finally {
    $env:USERPROFILE = $savedUserProfile
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace -Path @($Work))) { $script:Fail++ ; Write-Host '[FAIL] workspace cleanup left files behind' -ForegroundColor Red }
    }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
