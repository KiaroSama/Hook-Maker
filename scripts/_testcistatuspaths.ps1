# Test-CiStatusCheck.ps1 scenario block: a pushed commit that NO workflow can run
# for because every push workflow filters on paths the push did not touch. That
# shape gets a non-blocking "no-ci-for-ref" note (never green); every other
# zero-run shape keeps the block (a PR-only workflow, a branch filter, a filter
# this reader cannot read with certainty).
#
# Dot-sourced by Test-CiStatusCheck.ps1 into the caller's scope (uses its Fire,
# Check, Set-Mock, New-GitRepo, Get-HeadSha) - not a standalone suite.

    Write-Host '--- zero runs: a paths filter no pushed file satisfies is a note, not a block ---' -ForegroundColor Cyan
    function New-PathsRepo {
        param([string]$Name, [string]$Workflow, [string[]]$Touch)
        $repo = New-GitRepo $Name
        New-Item -ItemType Directory -Path (Join-Path $repo '.github\workflows') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo '.github\workflows\ci.yml'), $Workflow)
        foreach ($rel in $Touch) {
            $full = Join-Path $repo $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [System.IO.File]::WriteAllText($full, 'x')
        }
        & git -C $repo add -A
        & git -C $repo commit -q -m c2
        # The push: the remote-tracking ref moves from c1 to c2, as `git push` records it.
        & git -C $repo update-ref -m 'update by push' refs/remotes/origin/main (& git -C $repo rev-parse HEAD).Trim()
        return $repo
    }
    $srcOnly = "name: CI`non:`n  push:`n    paths:`n      - 'src/**'`njobs:`n  t:`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo`n"

    $docsRepo = New-PathsRepo 'ci-paths-docs' $srcOnly @('docs/x.md')
    Set-Mock -RunJson '[]' -ExpectedSha (Get-HeadSha $docsRepo)
    $r = Fire -HookPath $CiHook -Cwd $docsRepo -EventName 'Stop'
    Check 'paths filter unmatched by the push: a note, not a block' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision":"block"' -and $r.Out -match 'no workflow is configured to run') $r.Out
    Check 'the note never claims green' ($r.Out -match 'NOT a green result') $r.Out
    $r = Fire -HookPath $CiHook -Cwd $docsRepo -EventName 'Stop'
    Check 'the same commit stays quiet afterwards (recorded as no-ci-for-ref)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $srcRepo = New-PathsRepo 'ci-paths-src' $srcOnly @('docs/x.md', 'src/a.ts')
    Set-Mock -RunJson '[]' -ExpectedSha (Get-HeadSha $srcRepo)
    $r = Fire -HookPath $CiHook -Cwd $srcRepo -EventName 'Stop'
    Check 'a push that touches a filtered path still blocks while its run is missing' ($r.Out -match '"decision":"block"' -and $r.Out -match 'no runs are registered') $r.Out

    $prRepo = New-PathsRepo 'ci-paths-pr' "on:`n  push:`n    paths: ['src/**']`n  pull_request:`njobs: {}`n" @('docs/x.md')
    Set-Mock -RunJson '[]' -ExpectedSha (Get-HeadSha $prRepo)
    $r = Fire -HookPath $CiHook -Cwd $prRepo -EventName 'Stop'
    Check 'a workflow that also runs on pull_request keeps the block (open the PR)' ($r.Out -match '"decision":"block"') $r.Out

    $flowRepo = New-PathsRepo 'ci-paths-flow' "on: { push: { paths: ['src/**'] } }`njobs: {}`n" @('docs/x.md')
    Set-Mock -RunJson '[]' -ExpectedSha (Get-HeadSha $flowRepo)
    $r = Fire -HookPath $CiHook -Cwd $flowRepo -EventName 'Stop'
    Check 'a filter this reader cannot read with certainty keeps the block' ($r.Out -match '"decision":"block"') $r.Out
