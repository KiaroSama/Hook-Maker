# One mutation lifetime per install registry. Resource locks alone end before
# record publication and cannot exclude an installer recreating a removed hook.
# ponytail: registry-wide serialization; use ordered ownership-closure locks if
# concurrent management throughput becomes a measured requirement.
function Enter-InstallLifecycle {
    param([Parameter(Mandatory=$true)][string]$ToolRoot,
        [ValidateRange(0,120000)][int]$TimeoutMilliseconds = 0)
    $directory = Normalize-Path (Get-InstallStateDirectory $ToolRoot)
    $key = Get-RepositoryIdentityHash $directory.ToLowerInvariant()
    $mutex = New-Object Threading.Mutex($false,('Local\HookMaker-Lifecycle-'+$key))
    $held = $false
    try {
        try { $held = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another install or uninstall owns this registry; retry after it finishes.' }
    }
    catch { $mutex.Dispose(); throw }
    return $mutex
}
