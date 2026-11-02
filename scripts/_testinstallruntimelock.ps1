# Shared installer seam: a denied directory rename must not split a live tree.
function Invoke-RuntimeLockRegression {
    param([string]$Root, [string]$Work)
    & {
        param($Root, $Work)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'scripts/_installplan.ps1')
        $runtimeRoot = Join-Path $Work 'locked runtime with spaces'
        if (Test-Path -LiteralPath $runtimeRoot) { throw 'Preserve existing lock fixture.' }
        $name = 'ZZZ-Transaction-Lock'
        $destination = Join-Path $runtimeRoot $name
        $original = [ordered]@{ 'entry.ps1' = 'old entry'; 'helper.ps1' = 'old helper'; 'zz-lock.txt' = 'old lock' }
        $plan = @($original.Keys | ForEach-Object {
            New-PlanArtifact -RelativePath ($name + '/' + $_) -Kind Generated -GeneratedContent $original[$_]
        })
        Install-PlannedRuntime -Plan $plan -RuntimeRoot $runtimeRoot -FriendlyName $name | Out-Null
        $config = Join-Path $destination '.env'
        [IO.File]::WriteAllText($config, 'FIXTURE_SETTING=preserved', [Text.UTF8Encoding]::new($false))
        $replacement = @($original.Keys | ForEach-Object {
            New-PlanArtifact -RelativePath ($name + '/' + $_) -Kind Generated -GeneratedContent ('new ' + $_)
        })
        $lock = $null
        $refused = $false
        try {
            # Deny delete sharing: Windows must refuse the parent rename. The
            # provider's copy/delete fallback used to move preceding files away.
            $lock = [IO.File]::Open((Join-Path $destination 'zz-lock.txt'), 'Open', 'Read', 'Read')
            try { Install-PlannedRuntime -Plan $replacement -RuntimeRoot $runtimeRoot -FriendlyName $name | Out-Null }
            catch { $refused = $true }
        }
        finally { if ($null -ne $lock) { $lock.Dispose() } }
        if (-not $refused) { throw 'Locked runtime replacement must report failure.' }
        foreach ($leaf in $original.Keys) {
            $path = Join-Path $destination $leaf
            if (-not [IO.File]::Exists($path) -or [IO.File]::ReadAllText($path) -cne $original[$leaf]) {
                throw ('Locked replacement split or changed the original runtime: ' + $leaf)
            }
        }
        if ([IO.File]::ReadAllText($config) -cne 'FIXTURE_SETTING=preserved') { throw 'Original configuration changed on refusal.' }
        if (@(Get-ChildItem -LiteralPath $destination -Force -Recurse -File).Count -ne 4) { throw 'Original runtime file set changed on refusal.' }
        if (@(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Force).Count -ne 1) { throw 'Locked refusal abandoned transaction directories.' }
        Install-PlannedRuntime -Plan $replacement -RuntimeRoot $runtimeRoot -FriendlyName $name | Out-Null
        foreach ($leaf in $original.Keys) {
            if ([IO.File]::ReadAllText((Join-Path $destination $leaf)) -cne ('new ' + $leaf)) { throw 'Unlocked replacement did not install the complete new runtime.' }
        }
        if ([IO.File]::ReadAllText($config) -cne 'FIXTURE_SETTING=preserved') { throw 'Unlocked replacement lost configuration.' }
        if (@(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Force).Count -ne 1) { throw 'Successful replacement abandoned transaction directories.' }
        Write-Output 'Runtime lock: refusal preserves all originals; release permits complete replacement.'
    } $Root $Work
}
