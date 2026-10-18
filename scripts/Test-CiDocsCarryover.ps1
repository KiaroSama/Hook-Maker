# Focused docs-only carryover seam: real isolated git, bounded fake GitHub.
# One fixture shared across pure variants; no network, waits or real state edits.
param([switch]$KeepArtifacts, [switch]$LargeRepositoryOnly, [switch]$LockfileOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Pass = 0; $script:Fail = 0
$Work = New-TestWorkspace -Prefix 'hookmaker-docscarryover'
$HookRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
. (Join-Path $HookRoot '_hooklib.ps1')
. (Join-Path $HookRoot '_scope.ps1')
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
$script:Case = 'green'; $script:Calls = 0; $script:ManualFixture = $false
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
    if ($endpoint -match '/attempts/1/jobs') {
        return (@{total_count=1;jobs=@(@{id=12;check_run_url='https://api.github.com/repos/owner/repo/check-runs/2';run_id=1;run_attempt=1;head_sha=$script:BaseSha;name='test';status='completed';conclusion='success';completed_at='2026-10-17T09:00:00Z';steps=@(@{number=1;name='Validate';status='completed';conclusion='success';completed_at='2026-10-17T08:59:00Z'})})}|ConvertTo-Json -Depth 8 -Compress)
    }
    if ($endpoint -match '/actions/runs') {
        if ($endpoint -notmatch $script:BaseSha) { return '{"total_count":0,"workflow_runs":[]}' }
        $status = if ($script:Case -eq 'pending') { 'in_progress' } else { 'completed' }
        $conclusion = if ($script:Case -in @('failed', 'cancelled')) { $script:Case.Replace('failed', 'failure') } else { 'success' }
        $sha = if ($script:Case -eq 'mismatch') { 'a' * 40 } else { $script:BaseSha }
        $slug = if ($script:Case -eq 'wrong-repo') { 'other/repo' } else { 'owner/repo' }
        $count = if ($script:Case -eq 'incomplete') { 2 } else { 1 }
        $event = if ($script:ManualFixture -and $script:Case -ne 'manual-wrong-event') { 'workflow_dispatch' } else { 'push' }
        $branch = if ($script:Case -eq 'manual-wrong-branch') { 'other' } else { 'main' }
        $path = if ($script:Case -eq 'manual-wrong-path') { '.github/workflows/other.yml' } else { '.github/workflows/ci.yml' }
        return (@{ total_count = $count; workflow_runs = @(@{ id = 1; workflow_id=9;run_attempt=1;head_sha = $sha; head_repository = @{ full_name = $slug }; repository=@{full_name=$slug}; status = $status; conclusion = $conclusion; path = $path; event = $event; head_branch = $branch }) } | ConvertTo-Json -Depth 6 -Compress)
    }
    if ($endpoint -match '/check-runs') {
        $c = if ($script:Case -eq 'check-failed') { 'failure' } else { 'success' }
        $total = if ($script:Case -eq 'check-incomplete') { 2 } else { 1 }
        $commitSha=([regex]::Match($endpoint,'/commits/([a-f0-9]{40})/')).Groups[1].Value
        if($commitSha-cne$script:BaseSha){return '{"total_count":0,"check_runs":[]}'}
        return (@{ total_count = $total; check_runs = @(@{ id = 2; head_sha = $commitSha; status = 'completed'; conclusion = $c }) } | ConvertTo-Json -Depth 4 -Compress)
    }
    if ($endpoint -match '/status') {
        $c = if ($script:Case -eq 'status-pending') { 'pending' } else { 'success' }
        $statuses = if ($script:Case -eq 'empty-status') { @() } else { @(@{ state = $c; context = 'external' }) }
        $commitSha=([regex]::Match($endpoint,'/commits/([a-f0-9]{40})/')).Groups[1].Value
        if($commitSha-cne$script:BaseSha){$statuses=@()}
        return (@{ sha = $commitSha; total_count = @($statuses).Count; state = $c; statuses = @($statuses) } | ConvertTo-Json -Depth 4 -Compress)
    }
    $global:LASTEXITCODE = 1; return ''
}
try {
    & {param($Root,$Helper);. $Helper;Invoke-CiUpstreamRegression -HooksRoot $Root} $HookRoot (Join-Path $PSScriptRoot '_testciupstream.ps1')
    & {param($Root,$Helper);. $Helper;Invoke-CiClosureRegression -HooksRoot $Root} $HookRoot (Join-Path $PSScriptRoot '_testciclosure.ps1')
    . (Join-Path $PSScriptRoot '_testcidocslarge.ps1')
    if (-not $LockfileOnly) { Invoke-LargeDocsStopRegression -Workspace $Work -HooksRoot $HookRoot -SmokeOnly:$LargeRepositoryOnly }
    if ($LargeRepositoryOnly) {
        Write-Host ('Passed: ' + $script:Pass + ' Failed: ' + $script:Fail)
        exit $script:Fail
    }
    $repo = Join-Path $Work 'repo'; [void][IO.Directory]::CreateDirectory($repo)
    & git -C $repo init -qb main; & git -C $repo config user.name fixture; & git -C $repo config user.email fixture@example.invalid; & git -C $repo config core.autocrlf false
    if ($LockfileOnly) {
        . (Join-Path $PSScriptRoot '_testcidocslockfile.ps1')
        Write-Host ('Passed: ' + $script:Pass + ' Failed: ' + $script:Fail)
        exit $script:Fail
    }
    [void](Commit-Fixture '.github/workflows/ci.yml' "on: [push]`njobs:`n  test:`n    runs-on: windows-latest`n    steps:`n      - name: Validate`n        run: echo fixture" 'code')
    $script:BaseSha = ([string](& git -C $repo rev-parse HEAD)).Trim()
    & git -C $repo remote add origin https://github.com/owner/repo.git
    & git -C $repo config branch.main.remote origin
    & git -C $repo config branch.main.merge refs/heads/main
    & git -C $repo update-ref refs/remotes/origin/main $script:BaseSha
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
    $when = [DateTimeOffset]::UtcNow.ToString('o')
    $carryProof = @{schema=1;repository='owner/repo';sha=$sha;parent=$script:BaseSha;outcome='docs-only-carryover';observedUtc=$when;sourceFingerprint=('c'*64)}
    $stateLines = @($sha, 'verified', $when, 'docs-only-carryover', $script:BaseSha, ($carryProof|ConvertTo-Json -Compress))
    $publication = Join-Path $Work 'published.txt'
    Check 'first carryover atomically publishes complete state' (Write-CiStateAtomic $publication $stateLines)
    Check 'repeat carryover does not claim another notice' (-not (Write-CiStateAtomic $publication $stateLines))
    Check 'concurrent stale pending cannot overwrite carryover' (-not (Write-CiStateAtomic $publication @($sha, 'pending', [DateTime]::UtcNow.ToString('o'), '')))
    Check 'state still names exact ancestor, never final SHA ci-green' (([IO.File]::ReadAllLines($publication) -join '|') -ceq ($stateLines -join '|'))
    $oldProof=@{}+$carryProof; $oldProof.observedUtc=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
    $oldLines=@($sha,'verified',$oldProof.observedUtc,'docs-only-carryover',$script:BaseSha,($oldProof|ConvertTo-Json -Compress))
    [IO.File]::WriteAllLines($publication,$oldLines,[Text.Encoding]::UTF8)
    Check 'fresh revalidation deduplicates an older exact notice identity' (-not(Write-CiStateAtomic $publication $stateLines))
    Check 'stale carryover cannot indefinitely suppress pending revalidation' (Write-CiStateAtomic $publication @($sha,'pending',[DateTimeOffset]::UtcNow.ToString('o'),''))
    # Real simultaneous writers (two bounded, captured child processes) exercise
    # the mutex and atomic replace on both hosts; no synthetic concurrency claim.
    $emptyRulesProbe = Join-Path $Work 'empty-rules.ps1'
    $emptyRulesBody = '. ''' + (Join-Path $HookRoot '_hooklib.ps1').Replace("'", "''") + "'`n. '" + (Join-Path $HookRoot 'Ci-Status-Check\_docsonly.ps1').Replace("'", "''") + "'`n" +
        'function Invoke-GhBounded { param($ArgumentList) $global:LASTEXITCODE=0; if($ArgumentList[1] -match ''/rules/''){return ''[]''}; return ''{"name":"main","protected":false}'' }; if(-not(Test-NoRequiredStatusChecks owner/repo main)){exit 1}; Write-Host ''EmptyRulesAccepted'''
    [IO.File]::WriteAllText($emptyRulesProbe, $emptyRulesBody, (New-Object Text.UTF8Encoding $false))
    $emptyOut = Join-Path $Work 'empty-rules.out'; $emptyErr = Join-Path $Work 'empty-rules.err'
    $emptyProc = Start-BoundedProcess -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$emptyRulesProbe) -Wait -NoNewWindow -TimeoutMs 30000 -RedirectStandardOutput $emptyOut -RedirectStandardError $emptyErr
    Check '5.1 empty applied-rules array is flattened, not a malformed rule' ($emptyProc.ExitCode -eq 0 -and [IO.File]::ReadAllText($emptyOut).Contains('EmptyRulesAccepted') -and [IO.File]::ReadAllText($emptyErr) -eq '')
    $writer = Join-Path $Work 'writer.ps1'
    $module = Join-Path $HookRoot 'Ci-Status-Check\_cistate.ps1'
    $shared = Join-Path $HookRoot '_hooklib.ps1'
    $body = '. ''' + $shared.Replace("'", "''") + "'`n. '" + $module.Replace("'", "''") + "'`n" +
        '. ''' + (Join-Path $HookRoot 'Ci-Status-Check\_docsonly.ps1').Replace("'", "''") + "'`n" +
        'function Get-DocsOnlyCarryover { return [pscustomobject]@{ Parent=''' + $script:BaseSha + '''; Files=@(''README.md''); SourceFingerprint=(''c''*64) } }' + "`n" +
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
            Check ($hostExe + ': concurrent state complete and no temporary remains') ([IO.File]::ReadAllLines($path).Count -eq 6 -and @(Get-ChildItem $Work -Filter 'concurrent.txt.*.tmp').Count -eq 0)
        }
        finally { foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(10000) }; $child.Dispose() } }
    }
    & {
        param($hooks,$scripts)
        . (Join-Path $scripts '_testdocsreviewed.ps1')
        Invoke-DocsReviewedRegression -HooksRoot $hooks
    } $HookRoot $PSScriptRoot
    $safeFixture = $sha; $safeBase = $script:BaseSha
    . (Join-Path $PSScriptRoot '_testcidocsmanual.ps1')
    . (Join-Path $PSScriptRoot '_testcidocslockfile.ps1')
    & git -C $repo reset --hard $safeFixture *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Isolated fixture restoration failed' }
    $script:ManualFixture = $false; $script:Case = 'green'
    $script:BaseSha = $safeBase
    Check 'semantic consumer negative starts from eligible clean fixture' ($null -ne (Get-DocsOnlyCarryover $repo $safeFixture 'main' 'owner/repo' $state))
    $consumerSha = Commit-Fixture 'scripts/doctest.js' "readFileSync('README.md'); runExamples();"
    $script:BaseSha = $consumerSha
    $docs = Commit-Fixture 'README.md' 'changed consumed markdown'
    Check 'semantic Markdown consumer is not documentation exempt' ($null -eq (Get-DocsOnlyCarryover $repo $docs 'main' 'owner/repo' $state) -and $script:DocsCarryoverReason -match 'scripts/doctest\.js')
}
finally { if (-not $KeepArtifacts -and -not (Remove-TestWorkspace $Work)) { $script:Fail++ } }
Write-Host ('Passed: ' + $script:Pass + ' Failed: ' + $script:Fail)
exit $script:Fail
