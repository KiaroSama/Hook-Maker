# Test-StopLedger.ps1 scenario block: RETENTION. A session silent for 14 days
# can no longer be continued, so its chains, entries and unresolved rows are
# retired inside the update lock; without it every session appended forever
# until the 4,096-entry / 2 MB bound turned every gate block into a refusal.
# The current session is never touched and no live chain is refunded.
#
# Dot-sourced by Test-StopLedger.ps1 into the caller's scope (uses its Check,
# New-StopInput and $Work) - not a standalone suite.

function New-RetentionLedger {
    param([string]$Project, [hashtable]$Sessions, [int]$EntriesPerSession = 1)
    # $Sessions: session id -> @{ Age = days; UnresolvedAge = days (optional); Blocks = n }
    $doc = New-StopLedgerDocument
    foreach ($s in $Sessions.Keys) {
        $spec = $Sessions[$s]
        $stamp = [DateTime]::UtcNow.AddDays(-[double]$spec.Age).ToString('o')
        $chainKey = 'claude|' + $s + '|main'
        $chainId = [guid]::NewGuid().ToString('N')
        $blocks = 1; if ($spec.ContainsKey('Blocks')) { $blocks = [int]$spec.Blocks }
        Set-ObjectProperty -Object $doc.chains -Name $chainKey -Value ([pscustomobject]@{ id = $chainId; blocks = $blocks; event = 'e'; eventUtc = $stamp; startedUtc = $stamp })
        for ($i = 0; $i -lt $EntriesPerSession; $i++) {
            Set-ObjectProperty -Object $doc.entries -Name ($chainKey + '|Gate' + $i) -Value ([pscustomobject]@{ chain = $chainId; hook = 'Gate'; event = 'e'; finding = ''; blockedUtc = $stamp })
        }
        $uStamp = $stamp
        if ($spec.ContainsKey('UnresolvedAge')) { $uStamp = [DateTime]::UtcNow.AddDays(-[double]$spec.UnresolvedAge).ToString('o') }
        Set-ObjectProperty -Object $doc.unresolved -Name ($chainKey + '|Gate0') -Value ([pscustomobject]@{ hook = 'Gate'; chain = $chainId; session = $s; reason = 'blocked'; lastUtc = $uStamp })
    }
    # Compact: Windows PowerShell 5.1 pretty-prints 4,096 entries past the 2 MB bound.
    $path = Get-StopLedgerPath -ProjectRoot $Project
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}
function Get-LedgerSessions {
    param([string]$Path)
    $doc = (Get-StopLedgerState -Path $Path).Doc
    return @($doc.chains.PSObject.Properties | ForEach-Object { @($_.Name -split '\|')[1] } | Sort-Object)
}

Write-Host '--- retention: chains of sessions silent for 14 days are retired ---' -ForegroundColor Cyan
$retPath = New-RetentionLedger -Project 'C:\proj\retain' -Sessions @{
    OLD1 = @{ Age = 30 }; OLD2 = @{ Age = 30 }; OLD3 = @{ Age = 40 }; OLD4 = @{ Age = 15 }; OLD5 = @{ Age = 90 }
    KEEPU = @{ Age = 30; UnresolvedAge = 1 }; NOW = @{ Age = 0; Blocks = 2 }
}
$upd = Invoke-StopLedgerUpdate -Path $retPath -CurrentSession 'NOW' -Mutate { param($l) 'ok' }
$after = (Get-StopLedgerState -Path $retPath).Doc
Check 'retention: the update itself succeeds' ($upd.Ok -eq $true) ([string]$upd.State)
Check 'retention: five silent sessions are gone, a recent one and the current one stay' (((Get-LedgerSessions $retPath) -join ',') -eq 'KEEPU,NOW') ((Get-LedgerSessions $retPath) -join ',')
Check 'retention: their entries went with them' (@($after.entries.PSObject.Properties | Where-Object { $_.Name -match '\|OLD\d\|' }).Count -eq 0)
Check 'retention: their unresolved rows went with them' (@($after.unresolved.PSObject.Properties | Where-Object { [string]$_.Value.session -like 'OLD*' }).Count -eq 0)
Check 'retention: the current chain keeps its spent blocks (no refund)' ([int]$after.chains.'claude|NOW|main'.blocks -eq 2)
Check 'retention: an old chain with a recent unresolved row is kept' ($null -ne $after.chains.PSObject.Properties['claude|KEEPU|main'])

# The current session is protected even when everything it holds is old.
$curPath = New-RetentionLedger -Project 'C:\proj\retain-current' -Sessions @{ LONG = @{ Age = 30; Blocks = 3 } }
$null = Invoke-StopLedgerUpdate -Path $curPath -CurrentSession 'LONG' -Mutate { param($l) 'ok' }
Check 'retention: the CURRENT session is never retired, however old its chain' (((Get-LedgerSessions $curPath) -join ',') -eq 'LONG')

# The real caller passes the session: a block in a new session retires a dead one.
$realPath = New-RetentionLedger -Project 'C:\proj\retain-real' -Sessions @{ DEAD = @{ Age = 20 } }
$null = Set-StopBlockMarker -HookInput (New-StopInput -Session 'LIVE' -Continuation $false -Cwd 'C:\proj\retain-real') -HookName 'Rules-Check'
Check 'retention: Set-StopBlockMarker retires the dead session and records the live one' (((Get-LedgerSessions $realPath) -join ',') -eq 'LIVE') ((Get-LedgerSessions $realPath) -join ',')

Write-Host '--- retention keeps a full ledger writable; the bound still holds for live data ---' -ForegroundColor Cyan
$capPath = New-RetentionLedger -Project 'C:\proj\retain-cap' -Sessions @{ ANCIENT = @{ Age = 60 } } -EntriesPerSession 4096
$grow = { param($l) Set-ObjectProperty -Object $l.entries -Name 'claude|FRESH|main|NewGate' -Value ([pscustomobject]@{ chain = 'c'; hook = 'NewGate'; event = 'e'; finding = ''; blockedUtc = [DateTime]::UtcNow.ToString('o') }); 'ok' }
# Negative control: with the old session protected nothing is retired, so the
# 4,097th entry is refused exactly as before - the bound itself is unchanged.
$refused = Invoke-StopLedgerUpdate -Path $capPath -CurrentSession 'ANCIENT' -Mutate $grow
Check 'capacity: without retention the 4,097th entry is refused (bound unchanged)' ($refused.Ok -eq $false -and $refused.State -eq 'mutation-invalid-or-capacity') ([string]$refused.State)
$accepted = Invoke-StopLedgerUpdate -Path $capPath -CurrentSession 'FRESH' -Mutate $grow
Check 'capacity: with the dead session retired the same mutation is accepted' ($accepted.Ok -eq $true) ([string]$accepted.State)
Check 'capacity: only the new entry remains' (@((Get-StopLedgerState -Path $capPath).Doc.entries.PSObject.Properties).Count -eq 1)
