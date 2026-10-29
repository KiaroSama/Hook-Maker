# Session evidence must not be replaced by another client or a resumed session.
function Read-CleanupBaseline {
    param([string]$Path)
    try { return (Read-JsonFile -Path $Path) }
    catch { return $null } # Unreadable or malformed evidence cannot prove absence.
}
$legacyBaselinePath = Join-Path $stateDir ('TestTempCleanup-baseline-' + $projectKey + '.json')
$baselinePath = $legacyBaselinePath
$hookStatePath = Join-Path $stateDir ('TestTempCleanup-state-' + $projectKey + '.json')
if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
    $sessionKey = Get-ShortHash $sessionId
    $baselinePath = Join-Path $stateDir ('TestTempCleanup-baseline-' + $projectKey + '-' + $sessionKey + '.json')
    $hookStatePath = Join-Path $stateDir ('TestTempCleanup-state-' + $projectKey + '-' + $sessionKey + '.json')
    # Legacy compatibility never imports another session or overwrites its bytes.
    if (-not (Test-Path -LiteralPath $baselinePath)) {
        $legacyBaseline = Read-CleanupBaseline $legacyBaselinePath
        if ($null -ne $legacyBaseline -and [string](Get-Field $legacyBaseline 'sessionId') -ceq $sessionId) {
            $baselinePath = $legacyBaselinePath
        }
    }
}

function Publish-CleanupBaseline {
    param($Value, [string]$Path)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        # Move without overwrite atomically admits one complete initial snapshot.
        # A competing or repeated start cannot replace evidence already published.
        try { [IO.File]::Move($temporary, $Path) }
        catch [IO.IOException] { if (-not [IO.File]::Exists($Path)) { throw } }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
