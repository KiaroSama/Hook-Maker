# Historical matched success is not fresh proof or an unfinished run. Uses the
# existing isolated completion harness, artificial ages and real hook entry.
# No process sentinels, clock waits, real state or installation changes.

function Write-SelectionPair {
    param($Copy, [string]$Root, [string]$Id, [string]$Command, [double]$Age = 0,
        [string]$Overall = 'ok', [string]$Reason = '', [object[]]$Leaked = @())
    Write-ObservedRecord -Copy $Copy -Root $Root -RunId $Id -CommandFingerprint $Command -AgeMinutes $Age
    Write-GuardedResult -Copy $Copy -Root $Root -RunId $Id -CommandFingerprint $Command -AgeMinutes $Age -Overall $Overall -TerminateReason $Reason -Leaked $Leaked
}

# Exercise literal selector permutations as well as entry-point file ordering.
# Load the real pure identity functions from the entry AST, never execute its Stop.
& {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Hook, [ref]$null, [ref]$null)
    foreach ($name in @('ConvertTo-UtcTime', 'Test-ResultMatchesObserved')) {
        $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    . (Join-Path (Split-Path -Parent $Hook) '_evidence.ps1')
    . (Join-Path (Split-Path -Parent $Hook) '_runclassify.ps1')
    $script:evidenceMinutes = 180
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'Selection-literal-order'
    $stateFingerprint = Get-Fingerprint $p
    $pairs = @()
    foreach ($id in @('old', 'fresh')) {
        $age = if ($id -eq 'old') { 600 } else { 0 }
        Write-SelectionPair $c $p $id ($id + '-command') -Age $age
        $obs = Get-Content -LiteralPath (Get-RunStateFile $c $p 'observed' $id) -Raw -Encoding UTF8 | ConvertFrom-Json
        $path = Get-RunStateFile $c $p 'result' $id
        $entry = [pscustomobject]@{ Path = $path; Doc = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
        $pairs += [pscustomobject]@{ Observed = $obs; ResultEntry = $entry; HasObserved = $true; Matches = $true }
    }
    foreach ($order in @(@(0, 1), @(1, 0))) {
        $chosen = Select-RepresentativeRun -Runs @($pairs[$order[0]], $pairs[$order[1]])
        Check ('literal selector order ' + ($order -join ',') + ' selects fresh proof') (
            $chosen.Rep.Class -eq 'clean' -and $chosen.Rep.Run.ResultEntry.Doc.runId -eq 'fresh')
    }
}

Write-Host '--- historical success versus fresh proof ---' -ForegroundColor Cyan
foreach ($codexShape in @($false, $true)) {
    $client = if ($codexShape) { 'Codex' } else { 'Claude' }
    $hostExe = if ($codexShape) { 'pwsh' } else { 'powershell.exe' }
    foreach ($reverse in @($false, $true)) {
        $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-' + $client + '-' + $reverse)
        # Reverse filenames AND creation order, so enumeration cannot decide which
        # receipt wins. Ages place both inside the 24h retention horizon.
        $oldId = if ($reverse) { 'z-old' } else { 'a-old' }
        $newId = if ($reverse) { 'a-new' } else { 'z-new' }
        if ($reverse) { Write-SelectionPair $c $p $newId 'fresh-command' }
        Write-SelectionPair $c $p $oldId 'historical-command' -Age 600
        if (-not $reverse) { Write-SelectionPair $c $p $newId 'fresh-command' }
        $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
        Check ($client + ': old paired success cannot defeat fresh different-command success (reverse=' + $reverse + ')') (
            $r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') $r.Out
    }
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-old-only-' + $client)
    Write-SelectionPair $c $p 'only-old' 'old-only' -Age 600
    $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    Check ($client + ': historical success alone remains STALE, never fresh proof') (
        $r.Exit -eq 0 -and $r.Out -match '"decision"\s*:\s*"block"' -and (Get-BlockReason $r.Out) -match 'STALE') $r.Out

    foreach ($bad in @('missing', 'mismatch', 'identity', 'old-identity', 'failed', 'old-failed', 'wallTimeout', 'idleTimeout', 'terminated', 'leak', 'old-leak')) {
        $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-' + $client + '-' + $bad)
        Write-SelectionPair $c $p 'fresh-good' 'good-command'
        $age = if ($bad -like 'old-*') { 600 } else { 5 }
        Write-ObservedRecord -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -AgeMinutes $age
        switch ($bad) {
            'missing' { }
            'mismatch' { Write-GuardedResult -Copy $c -Root $p -RunId 'wrong-run' -CommandFingerprint 'different-unsafe-command' -AgeMinutes $age }
            { $_ -in @('identity', 'old-identity') } {
                Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -ProjectFingerprint ' ' -AgeMinutes $age
            }
            { $_ -in @('failed', 'old-failed') } { Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -Overall 'failed' -ExitCode 1 -AgeMinutes $age }
            { $_ -in @('leak', 'old-leak') } { Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -Leaked @(424242) -AgeMinutes $age }
            default { Write-GuardedResult -Copy $c -Root $p -RunId 'unsafe' -CommandFingerprint 'different-unsafe-command' -Overall 'terminated' -ExitCode 124 -TerminateReason $bad -AgeMinutes $age }
        }
        $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
        Check ($client + ': fresh success never hides ' + $bad + ' of another command') (
            $r.Exit -eq 0 -and $r.Out -match '"decision"\s*:\s*"block"' -and $r.Err -eq '') $r.Out
    }

    # One-to-one assignment: same-time uncontrolled observations cannot both
    # consume one result. Existing supersede requires a STRICTLY later observation.
    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-one-to-one-' + $client)
    Write-ObservedRecord -Copy $c -Root $p -RunId 'one' -RunIdControlled $false
    $onePath = Get-RunStateFile -Copy $c -Root $p -Kind 'observed' -RunId 'one'
    $twoPath = Get-RunStateFile -Copy $c -Root $p -Kind 'observed' -RunId 'two'
    $doc = Get-Content -LiteralPath $onePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $doc.runId = 'two'
    Write-Utf8 $twoPath ($doc | ConvertTo-Json -Depth 6)
    Write-GuardedResult -Copy $c -Root $p -RunId 'one'
    $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    Check ($client + ': one success still cannot satisfy two concurrent observations') (
        $r.Exit -eq 0 -and $r.Out -match '"decision"\s*:\s*"block"') $r.Out

    $c = New-IsolatedHookCopy; $p = New-GitRepo ('Selection-same-command-' + $client)
    Write-ObservedRecord -Copy $c -Root $p -RunId 'orphan' -AgeMinutes 5
    Write-SelectionPair $c $p 'replacement' (Get-TestCommandFp $p)
    $r = Fire -Copy $c -Cwd $p -Codex:$codexShape -Exe $hostExe
    Check ($client + ': later own paired success still clears only its same-command orphan') (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
}
