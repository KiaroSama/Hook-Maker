# Path identity addresses coordination files; it never proves repository state.
# Git refusal (including dubious ownership) must not turn into trusted path state.
function Get-RepositoryStateEvidence {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $root = Normalize-Path $ProjectRoot
    $key = Get-ShortHash $root.ToLowerInvariant()
    $fingerprint = ''
    try { $fingerprint = [string](Get-RepoStateFingerprint -ProjectRoot $root) } catch { }
    if (-not [string]::IsNullOrWhiteSpace($fingerprint)) {
        return [pscustomobject]@{ ProjectKey = $key; RepositoryStateFingerprint = $fingerprint; State = 'available'; BindingFingerprint = $fingerprint }
    }
    # A nested directory belongs to its ancestor repository even when Git refuses
    # to read it. .git may be a worktree file, not just a directory.
    $candidate = $root
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-Path -LiteralPath (Join-Path $candidate '.git')) {
            return [pscustomobject]@{ ProjectKey = $key; RepositoryStateFingerprint = ''; State = 'unavailable'; BindingFingerprint = '' }
        }
        $parent = Split-Path -Parent $candidate
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
    # Compatibility for deliberately non-Git standalone workspaces. This binding
    # identifies a workspace only, explicitly degraded, never CURRENT repo proof.
    return [pscustomobject]@{ ProjectKey = $key; RepositoryStateFingerprint = ''; State = 'nonrepository'; BindingFingerprint = $key }
}
