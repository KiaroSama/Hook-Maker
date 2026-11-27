# Steering V103 cases for Test-CiStatusCheck.ps1: jq watcher text and the Gitleaks
# never-skipped rule. Dot-sourced inside that suite's try block; uses its Fire,
# Set-Mock, New-GitRepo, Get-HeadSha, Check, $CiHook and $MockDir.
Write-Host '--- CiStatusCheck V103: jq watcher and Gitleaks never skipped ---' -ForegroundColor Cyan

$v103Pend = New-GitRepo 'v103pend'
$v103PendSha = Get-HeadSha $v103Pend
Set-Mock -RunJson '[{"databaseId":71,"name":"CI","workflowName":"CI","status":"in_progress","conclusion":null}]' -ExpectedSha $v103PendSha
$r = Fire -HookPath $CiHook -Cwd $v103Pend -EventName 'Stop'
Check 'V103 Write-Block -Watch names installed jq (jq-1.8.2) and gh --jq' (
    $r.Out -match 'silent background watcher until ALL jobs finish' -and $r.Out -match 'jq-1\.8\.2' -and $r.Out -match 'gh --jq') $r.Out

$v103Skip = New-GitRepo 'v103skip'
$v103SkipSha = Get-HeadSha $v103Skip
Set-Mock -RunJson '[{"databaseId":72,"name":"Gitleaks","workflowName":"Gitleaks","status":"completed","conclusion":"skipped"}]' -ExpectedSha $v103SkipSha
$r = Fire -HookPath $CiHook -Cwd $v103Skip -EventName 'Stop'
Check 'V103 a skipped Gitleaks run is a failing workflow defect, never green' (
    $r.Out -match 'Gitleaks / Gitleaks secret scan \(push\) skipped' -and $r.Out -match 'workflow defect: must execute green on push, never skipped' -and $r.Out -match 'FAILED') $r.Out

$v103Defect = New-GitRepo 'v103defect'
[IO.File]::WriteAllText((Join-Path $v103Defect '.github/workflows/gitleaks.yml'), "name: Gitleaks`non:`n  push:`n  workflow_dispatch:`njobs:`n  gitleaks:`n    if: github.event_name != 'push' || github.ref_name == github.event.repository.default_branch`n    runs-on: ubuntu-24.04`n", [Text.UTF8Encoding]::new($false))
Set-Mock -RunJson '[{"databaseId":73,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha (Get-HeadSha $v103Defect)
$r = Fire -HookPath $CiHook -Cwd $v103Defect -EventName 'Stop'
Check 'V103 gitleaks.yml with a job-level if: is flagged as a failing defect' ($r.Out -match 'Gitleaks workflow defect' -and $r.Out -match '\.github/workflows/gitleaks\.yml' -and $r.Out -match 'job-level if:') $r.Out

$v103Paths = New-GitRepo 'v103paths'
[IO.File]::WriteAllText((Join-Path $v103Paths '.github/workflows/gitleaks.yml'), "name: Gitleaks`non:`n  push:`n    paths-ignore:`n      - 'docs/**'`n  workflow_dispatch:`njobs:`n  gitleaks:`n    runs-on: ubuntu-24.04`n", [Text.UTF8Encoding]::new($false))
Set-Mock -RunJson '[{"databaseId":74,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha (Get-HeadSha $v103Paths)
$r = Fire -HookPath $CiHook -Cwd $v103Paths -EventName 'Stop'
Check 'V103 gitleaks.yml with push paths-ignore is flagged as a failing defect' ($r.Out -match 'Gitleaks workflow defect' -and $r.Out -match 'paths:/paths-ignore:') $r.Out

# Pure parser: a clean file (like Hook Maker's own) yields no defect.
$v103Clean = Join-Path $Work 'v103clean'
[void][IO.Directory]::CreateDirectory((Join-Path $v103Clean '.github/workflows'))
[IO.File]::WriteAllText((Join-Path $v103Clean '.github/workflows/gitleaks.yml'), "name: Gitleaks`non:`n  push:`n  pull_request:`n    paths:`n      - 'src/**'`n  workflow_dispatch:`njobs:`n  gitleaks:`n    name: Gitleaks secret scan`n    runs-on: ubuntu-24.04`n    steps:`n      - if: always()`n        run: echo scan`n", [Text.UTF8Encoding]::new($false))
. (Join-Path (Split-Path -Parent $CiHook) '_cigitleaks.ps1')
Check 'V103 a clean gitleaks.yml has no skip defect' (@(Get-GitleaksWorkflowSkipDefects -ProjectRoot $v103Clean).Count -eq 0) ((@(Get-GitleaksWorkflowSkipDefects -ProjectRoot $v103Clean)) -join '; ')
Check 'V103 Test-IsGitleaksCheck matches workflow and check names' ((Test-IsGitleaksCheck 'Gitleaks secret scan') -and (Test-IsGitleaksCheck '.github/workflows/gitleaks.yml') -and -not (Test-IsGitleaksCheck 'CI')) ''
$realRoot = Split-Path -Parent $PSScriptRoot
Check 'V103 Hook Maker own gitleaks.yml has no skip defect' (@(Get-GitleaksWorkflowSkipDefects -ProjectRoot $realRoot).Count -eq 0) ((@(Get-GitleaksWorkflowSkipDefects -ProjectRoot $realRoot)) -join '; ')
