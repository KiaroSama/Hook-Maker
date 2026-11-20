# Test-CiStatusCheck section: V94 standing order 4 - billing-blocked CI Stop gate.
# Dot-sourced from Test-CiStatusCheck.ps1 inside its try block ($Work, $CiHook,
# $ciBill, Fire, Check are in scope). Separate file so Test-CiStatusCheck.ps1
# stays below the 700-line write ceiling.

function New-BillTranscript {
    param([string]$Name, [string]$Text, [string[]]$Commands = @())
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($cmd in $Commands) {
        [void]$lines.Add((@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Bash'; input = @{ command = $cmd } }) } } | ConvertTo-Json -Depth 8 -Compress))
    }
    [void]$lines.Add((@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $Text }) } } | ConvertTo-Json -Depth 8 -Compress))
    $p = Join-Path $Work ($Name + '.jsonl')
    [System.IO.File]::WriteAllText($p, (($lines.ToArray() -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    return $p
}

$r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop' -Extra @{ session_id = 'bill-nolocal'; transcript_path = (New-BillTranscript 'bill-nolocal' "Pushed.`nCI is fine." @('pwsh -NoProfile -File scripts/Test-Engine.ps1')) }
Check '107 5b: billing block without "CI did not run; local run ..." line -> blocks once' ($r.Out -match '"decision":"block"' -and $r.Out -match 'CI did not run') $r.Out
$r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop' -Extra @{ session_id = 'bill-nolocal'; transcript_path = (New-BillTranscript 'bill-nolocal2' "Pushed.`nCI is fine." @('pwsh -NoProfile -File scripts/Test-Engine.ps1')) }
Check '107 5b: the same billing finding is not refused twice' ($r.Out -notmatch '"decision":"block"') $r.Out

$r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop' -Extra @{ session_id = 'bill-norun'; transcript_path = (New-BillTranscript 'bill-norun' "Pushed.`nCI did not run; local run passed.") }
Check '107 5b: billing block claiming local run passed with NO local command in transcript -> blocks once' ($r.Out -match '"decision":"block"' -and $r.Out -match 'Run the same tool locally') $r.Out

$r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop' -Extra @{ session_id = 'bill-gitonly'; transcript_path = (New-BillTranscript 'bill-gitonly' "Pushed.`nCI did not run; local run passed." @('git push origin main', 'gh run list')) }
Check '107 5b: git/gh shell calls alone do not count as a local verification run -> blocks once' ($r.Out -match '"decision":"block"') $r.Out

$r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop' -Extra @{ session_id = 'bill-local'; transcript_path = (New-BillTranscript 'bill-local' "Pushed.`nCI did not run; local run passed (pwsh scripts/Test-Engine.ps1)." @('pwsh -NoProfile -File scripts/Test-Engine.ps1')) }
Check '107 5b: billing block with local command AND local-run passed line -> no block' ($r.Out -notmatch '"decision":"block"') $r.Out

$r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop' -Extra @{ session_id = 'bill-local-fail'; transcript_path = (New-BillTranscript 'bill-local-fail' "Pushed.`nCI did not run; local run failed." @('pwsh -NoProfile -File scripts/Test-Engine.ps1')) }
Check '107 5b: billing block with local command AND local-run failed line -> no block' ($r.Out -notmatch '"decision":"block"') $r.Out
