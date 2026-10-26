# Settings preimages and atomic replacement for the selected uninstaller.
# Dot-sourced after the result and shared install helpers exist.
$script:UninstallTimestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

function Get-SettingsBackupPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stamp = $script:UninstallTimestamp
    $run = [string]$env:HOOKMAKER_BACKUP_RUN
    if (-not [string]::IsNullOrWhiteSpace($run)) {
        $safe = ($run -replace '[^A-Za-z0-9._-]', '')
        if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
        if ($safe -ne '') { $stamp = 'uninstall-' + $safe }
    }
    return ($Path + '.backup-' + $stamp)
}

function Backup-SettingsFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $backupPath = Get-SettingsBackupPath -Path $Path
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }
    # Preserve this operation's preimage; use the installer's existing retention.
    Remove-SupersededBackups -Path $Path -KeepPath $backupPath
}

function Write-SettingsFileAtomic {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('Cannot write settings: "' + $Path + '" exists but is not a file.')
    }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 50
    $temporaryPath = $Path + '.hookmaker-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $Utf8NoBom)
        $verify = [System.IO.File]::ReadAllText($temporaryPath, [System.Text.Encoding]::UTF8)
        $null = $verify | ConvertFrom-Json
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}
