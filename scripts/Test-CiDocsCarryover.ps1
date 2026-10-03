# Focused docs-only carryover seam: real isolated git, bounded fake GitHub.
# One fixture shared across pure variants; no network, waits or real state edits.
param([switch]$KeepArtifacts)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Pass = 0; $script:Fail = 0
$Work = New-TestWorkspace -Prefix 'hookmaker-docscarryover'
$HookRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
. (Join-Path $HookRoot '_hooklib.ps1')
. (Join-Path $HookRoot 'Ci-Status-Check\_pathsfilter.ps1')
. (Join-Path $HookRoot 'Ci-Status-Check\_docsonly.ps1')
function Commit-Fixture {
    param([string]$Path, [string]$Text, [string]$Message = 'docs [skip ci]')
    $full = Join-Path $repo $Path
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
    [IO.File]::WriteAllText($full, $Text, (New-Object Text.UTF8Encoding $false))
    & git -C $repo add .; & git -C $repo commit -qm $Message
    return ([string](& git -C $repo rev-parse HEAD)).Trim()
}
$script:Case = 'green'; $script:Calls = 0
function Get-GhRemainingSeconds { return 30 }
function Invoke-GhBounded {
    param([string[]]$ArgumentList)
    $script:Calls++; $global:LASTEXITCODE = 0
    $endpoint = $ArgumentList[1]
    if ($script:Case -eq 'api-fail') { $global:LASTEXITCODE = 1; return '' }
    if ($endpoint -match '/rules/branches/') {
        if ($script:Case -eq 'rules-fail') { $global:LASTEXITCODE = 1; return '' }
        if ($script:Case -eq 'rules-required') { return '[{"type":"required_status_checks"}]' }
        if ($script:Case -eq 'rules-malformed') { return '{}' }
        return '[]'
    }
    if ($endpoint -match '/branches/') {
        if ($script:Case -eq 'protection-fail') { $global:LASTEXITCODE = 1; return '' }
        if ($script:Case -eq 'protected') { return '{"name":"main","protected":true,"protection":{"required_status_checks":{"contexts":["CI"],"enforcement_level":"everyone"}}}' }
        if ($script:Case -eq 'protection-malformed') { return '{}' }
        return '{"name":"main","protected":false}'
    }
    if ($endpoint -match '/actions/runs') {
        if ($endpoint -notmatch $script:BaseSha) { return '{"total_count":0,"workflow_runs":[]}' }
        $status = if ($script:Case -eq 'pending') { 'in_progress' } else { 'completed' }
        $conclusion = if ($script:Case -in @('failed', 'cancelled')) { $script:Case.Replace('failed', 'failure') } else { 'success' }
        $sha = if ($script:Case -eq 'mismatch') { 'a' * 40 } else { $script:BaseSha }
        $slug = if ($script:Case -eq 'wrong-repo') { 'other/repo' } else { 'owner/repo' }
        $count = if ($script:Case -eq 'incomplete') { 2 } else { 1 }
        return (@{ total_count = $count; workflow_runs = @(@{ id = 1; head_sha = $sha; head_repository = @{ full_name = $slug }; status = $status; conclusion = $conclusion; path = '.github/workflows/ci.yml'; event = 'push' }) } | ConvertTo-Json -Depth 6 -Compress)
    }
    if ($endpoint -match '/check-runs') {
        $c = if ($script:Case -eq 'check-failed') { 'failure' } else { 'success' }
        $total = if ($script:Case -eq 'check-incomplete') { 2 } else { 1 }
        return (@{ total_count = $total; check_runs = @(@{ id = 2; head_sha = $script:BaseSha; status = 'completed'; conclusion = $c }) } | ConvertTo-Json -Depth 4 -Compress)
    }
    if ($endpoint -match '/status') {
        $c = if ($script:Case -eq 'status-pending') { 'pending' } else { 'success' }
        $statuses = if ($script:Case -eq 'empty-status') { @() } else { @(@{ state = $c; context = 'external' }) }
        return (@{ sha = $script:BaseSha; total_count = @($statuses).Count; state = $c; statuses = @($statuses) } | ConvertTo-Json -Depth 4 -Compress)
    }
    $global:LASTEXITCODE = 1; return ''
}
try {
    $repo = Join-Path $Work 'repo'; [void][IO.Directory]::CreateDirectory($repo)
    & git -C $repo init -qb main; & git -C $repo config user.name fixture; & git -C $repo config user.email fixture@example.invalid; & git -C $repo config core.autocrlf false
    [void](Commit-Fixture '.github/workflows/ci.yml' "on: [push]`njobs:`n  test:`n    runs-on: windows-latest`n    steps: []" 'code')
    $script:BaseSha = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $sha = Commit-Fixture 'README.md' 'docs'
    $state = Join-Path $Work 'state.txt'
    foreach ($cache in @('missing', 'stale', 'overwritten', 'unrelated')) {
        if (Test-Path $state) { Remove-Item -LiteralPath $state }
        if ($cache -eq 'stale') { [IO.File]::WriteAllLines($state, @($script:BaseSha, 'verified', '2000-01-01T00:00:00Z', 'ci-green')) }
        if ($cache -eq 'overwritten') { [IO.File]::WriteAllLines($state, @($sha, 'pending', [DateTime]::UtcNow.ToString('o'), '')) }
        if ($cache -eq 'unrelated') { [IO.File]::WriteAllLines($state, @(('f' * 40), 'verified', [DateTime]::UtcNow.ToString('o'), 'ci-green')) }
        $script:Calls = 0
        $carry = Get-DocsOnlyCarryover $repo $sha 'main' 'owner/repo' $state
        Check ($cache + ' cache independently verifies exact green ancestor') ($null -ne $carry -and $carry.Parent -eq $script:BaseSha -and $script:Calls -gt 2)
    }
    $sha = Commit-Fixture 'docs/guide.md' 'second documentation commit'
    $carry = Get-DocsOnlyCarryover $repo $sha 'main' 'owner/repo' $state
    Check 'multi-commit docs chain names the tested ancestor' ($null -ne $carry -and $carry.Parent -eq $script:BaseSha)
    $script:Case = 'empty-status'
    Check 'empty legacy statuses is complete, not a missing API field' ($null -ne (Get-DocsOnlyCarryover $repo $sha 'main' 'owner/repo' $state))
    foreach ($case in @('failed', 'pending', 'cancelled', 'mismatch', 'wrong-repo', 'incomplete', 'check-failed', 'check-incomplete', 'status-pending', 'api-fail', 'protected', 'protection-fail', 'rules-fail', 'rules-required', 'protection-malformed', 'rules-malformed')) {
        $script:Case = $case
        Check ($case + ' never grants carryover') ($null -eq (Get-DocsOnlyCarryover $repo $sha 'main' 'owner/repo' $state))
    }
    $script:Case = 'green'
    foreach ($path in @('tool.ps1', 'config.json', '.github/workflows/other.yml', 'examples/readme.md', 'tests/snapshot.md')) {
        $badSha = Commit-Fixture $path 'not prose'
        Check ($path + ' mixed into chain stays blocked') ($null -eq (Get-DocsOnlyCarryover $repo $badSha 'main' 'owner/repo' $state))
        & git -C $repo revert --no-edit HEAD *> $null
        $reverted = ([string](& git -C $repo rev-parse HEAD)).Trim()
        Check ($path + ' later reverted remains in unsafe chain') ($null -eq (Get-DocsOnlyCarryover $repo $reverted 'main' 'owner/repo' $state))
        # Only isolated fixture history is reset; no user repository/ref touched.
        & git -C $repo reset --hard $sha *> $null
    }
    . (Join-Path $HookRoot 'Ci-Status-Check\_cistate.ps1')
    $stateLines = @($sha, 'verified', [DateTime]::UtcNow.ToString('o'), 'docs-only-carryover', $script:BaseSha)
    $publication = Join-Path $Work 'published.txt'
    Check 'first carryover atomically publishes complete state' (Write-CiStateAtomic $publication $stateLines)
    Check 'repeat carryover does not claim another notice' (-not (Write-CiStateAtomic $publication $stateLines))
    Check 'concurrent stale pending cannot overwrite carryover' (-not (Write-CiStateAtomic $publication @($sha, 'pending', [DateTime]::UtcNow.ToString('o'), '')))
    Check 'state still names exact ancestor, never final SHA ci-green' (([IO.File]::ReadAllLines($publication) -join '|') -ceq ($stateLines -join '|'))
    # Real simultaneous writers (two bounded, captured child processes) exercise
    # the mutex and atomic replace on both hosts; no synthetic concurrency claim.
    $writer = Join-Path $Work 'writer.ps1'
    $module = Join-Path $HookRoot 'Ci-Status-Check\_cistate.ps1'
    $shared = Join-Path $HookRoot '_hooklib.ps1'
    $body = '. ''' + $shared.Replace("'", "''") + "'`n. '" + $module.Replace("'", "''") + "'`n" +
        '. ''' + (Join-Path $HookRoot 'Ci-Status-Check\_docsonly.ps1').Replace("'", "''") + "'`n" +
        'function Get-DocsOnlyCarryover { return [pscustomobject]@{ Parent=''' + $script:BaseSha + '''; Files=@(''README.md'') } }' + "`n" +
        'Invoke-DocsOnlyCarryover -ProjectRoot ''' + $repo.Replace("'", "''") + ''' -Sha ''' + $sha + ''' -Branch main -RepoSlug owner/repo -StatePath ''' +
        (Join-Path $Work 'concurrent.txt').Replace("'", "''") + ''' -EventName Stop'
    [IO.File]::WriteAllText($writer, $body, (New-Object Text.UTF8Encoding $false))
    foreach ($hostExe in @('pwsh', 'powershell.exe')) {
        $path = Join-Path $Work 'concurrent.txt'; if (Test-Path $path) { Remove-Item -LiteralPath $path }
        $children = @()
        try {
            foreach ($n in @(1, 2)) {
                $outPath = Join-Path $Work ($hostExe + $n + '.out'); $errPath = Join-Path $Work ($hostExe + $n + '.err')
                $children += Start-Process -FilePath $hostExe -ArgumentList ('-NoLogo -NoProfile -NonInteractive -File "' + $writer + '"') -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
            }
            foreach ($child in $children) { if (-not $child.WaitForExit(30000)) { throw 'bounded state writer timed out' } }
            $outputs = @(1, 2 | ForEach-Object { [IO.File]::ReadAllText((Join-Path $Work ($hostExe + $_ + '.out')), [Text.Encoding]::UTF8).Trim() })
            Check ($hostExe + ': concurrent Stop emits one non-blocking systemMessage') (
                @($outputs | Where-Object { $_ -match 'systemMessage' -and $_ -notmatch '"decision"' }).Count -eq 1 -and
                @($outputs | Where-Object { $_ -eq '' }).Count -eq 1)
            Check ($hostExe + ': concurrent state complete and no temporary remains') ([IO.File]::ReadAllLines($path).Count -eq 5 -and @(Get-ChildItem $Work -Filter 'concurrent.txt.*.tmp').Count -eq 0)
        }
        finally { foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(10000) }; $child.Dispose() } }
    }
    $consumerSha = Commit-Fixture 'scripts/doctest.js' "readFileSync('README.md'); runExamples();"
    $script:BaseSha = $consumerSha
    $docs = Commit-Fixture 'README.md' 'changed consumed markdown'
    Check 'semantic Markdown consumer is not documentation exempt' ($null -eq (Get-DocsOnlyCarryover $repo $docs 'main' 'owner/repo' $state))
}
finally { if (-not $KeepArtifacts -and -not (Remove-TestWorkspace $Work)) { $script:Fail++ } }
Write-Host ('Passed: ' + $script:Pass + ' Failed: ' + $script:Fail)
exit $script:Fail
