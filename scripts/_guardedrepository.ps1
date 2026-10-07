# Standalone repository binding preflight and approved child Git environment.
$repoLibRoot=$script:GuardedRunnerRoot
if(-not[IO.File]::Exists((Join-Path $repoLibRoot '_repositoryaccess.ps1'))){$repoLibRoot=Join-Path (Split-Path -Parent $repoLibRoot) 'hooks'}
foreach($leaf in @('_processlib.ps1','_repositoryaccess.ps1','_repositorytrust.ps1')) {
    if(-not[IO.File]::Exists((Join-Path $repoLibRoot $leaf))){throw ('Run-Tests-Guarded: missing repository validation companion '+$leaf)}
}
. (Join-Path $repoLibRoot '_processlib.ps1')
. (Join-Path $repoLibRoot '_repositoryaccess.ps1')
if([string]::IsNullOrWhiteSpace($WorkingDirectory)){$WorkingDirectory=(Get-Location).Path}
try {
    if(-not[IO.Path]::IsPathRooted($WorkingDirectory)){$WorkingDirectory=[IO.Path]::Combine((Get-Location).Path,$WorkingDirectory)}
    $WorkingDirectory=[IO.Path]::GetFullPath($WorkingDirectory).TrimEnd([char[]]@('\','/'))
    $script:GuardedRepositorySnapshot=Get-RepositoryAccessSnapshot $WorkingDirectory
} catch {throw 'Run-Tests-Guarded: repository validation failed before child or evidence creation.'}
if($script:GuardedRepositorySnapshot.State-eq'unavailable') {
    throw ('Run-Tests-Guarded: repository identity unavailable; diagnosis='+$script:GuardedRepositorySnapshot.Diagnosis+'. No child or evidence created.')
}
if($script:GuardedRepositorySnapshot.State-eq'available'-and$ProjectFingerprint-cne$script:GuardedRepositorySnapshot.Fingerprint) {
    throw 'Run-Tests-Guarded: supplied repository fingerprint is not the verified current state. No child or evidence created.'
}
$script:GuardedRepositoryEnvironment=$script:GuardedRepositorySnapshot.GitEnvironment
$script:Result.workingDirectory=$WorkingDirectory
$script:Result.repositoryState=$script:GuardedRepositorySnapshot.State
$script:Result.repositoryRoot=$script:GuardedRepositorySnapshot.RepositoryRoot

function Set-GuardedRepositoryEnvironment {
    param($StartInfo)
    $current=Get-RepositoryAccessSnapshot $script:Result.workingDirectory
    if($current.State-cne$script:GuardedRepositorySnapshot.State-or$current.Fingerprint-cne$script:GuardedRepositorySnapshot.Fingerprint){throw 'Repository state or approval changed before child startup.'}
    if($script:GuardedRepositoryEnvironment.Count-gt0-and$current.GitEnvironment.Count-eq0){throw 'Exact-root approval was revoked before child startup.'}
    foreach($key in $current.GitEnvironment.Keys){$StartInfo.EnvironmentVariables[$key]=[string]$current.GitEnvironment[$key]}
}
