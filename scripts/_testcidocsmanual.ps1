# Exact ancestor event/path/branch must be represented; workflow text alone is not proof.
$workflow = "on: [workflow_dispatch]`njobs:`n  test:`n    runs-on: windows-latest`n    steps: []"
$script:BaseSha = Commit-Fixture '.github/workflows/ci.yml' $workflow 'manual fixture'
$script:Case = 'manual-green'; $script:ManualFixture = $true
Check 'complete exact manual ancestor is eligible without push workflow' (Test-DocsAncestorGreen $repo 'owner/repo' $script:BaseSha 'main')
foreach ($case in @('manual-wrong-branch','manual-wrong-event','manual-wrong-path','check-incomplete','check-failed','failed','pending','wrong-repo','mismatch')) {
    $script:Case = $case
    Check ($case + ' never substitutes for complete manual ancestor evidence') (-not (Test-DocsAncestorGreen $repo 'owner/repo' $script:BaseSha 'main'))
}
$script:Case = 'manual-green'
$script:BaseSha = Commit-Fixture '.github/workflows/ci.yml' ($workflow.Replace('workflow_dispatch','workflow_call')) 'reusable fixture'
Check 'reusable child alone never establishes an initiating manual batch' (-not (Test-DocsAncestorGreen $repo 'owner/repo' $script:BaseSha 'main'))
$script:BaseSha = Commit-Fixture '.github/workflows/ci.yml' ($workflow.Replace('workflow_dispatch','workflow_dispatch, schedule')) 'unknown fixture'
Check 'unsupported automatic initiator keeps ancestor evidence unknown' (-not (Test-DocsAncestorGreen $repo 'owner/repo' $script:BaseSha 'main'))
$script:Case = 'green'
