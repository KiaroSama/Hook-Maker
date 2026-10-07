# Path identity addresses coordination files, never proves repository state.
. (Join-Path $PSScriptRoot '_repositoryaccess.ps1')
function Get-RepositoryStateEvidence {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $root=Normalize-Path $ProjectRoot
    $key=Get-ShortHash $root.ToLowerInvariant()
    $snapshot=Get-RepositoryAccessSnapshot -ProjectRoot $root
    $binding=if($snapshot.State-eq'nonrepository'){$key}else{$snapshot.Fingerprint}
    return [pscustomobject]@{ProjectKey=$key;RepositoryStateFingerprint=$snapshot.Fingerprint;State=$snapshot.State;BindingFingerprint=$binding;Diagnosis=$snapshot.Diagnosis;RepositoryRoot=$snapshot.RepositoryRoot;GitEnvironment=$snapshot.GitEnvironment}
}
