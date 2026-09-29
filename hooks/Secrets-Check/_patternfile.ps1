# Secrets-Check private sibling: a secret VALUE never goes on a child process's
# command line. Command lines are visible to every process of the user and land
# in process-creation audit logs (Sysmon, event 4688, EDR); `git grep -f` reads
# the pattern from a file instead. Dot-sourced by Secrets-Check.ps1.

# Same contract as Invoke-QuietCommand (output lines, $LASTEXITCODE set).
# $GrepOptions go after `grep` (e.g. '-Il','-F' or '--cached','-Il','-F');
# $Trailing after the pattern file ('--' for a pathspec boundary, or the
# revision batch of the outgoing scan, which must stay revisions).
function Invoke-GitGrepWithValue {
    param(
        [Parameter(Mandatory = $true)][string]$Cwd,
        [Parameter(Mandatory = $true)][string]$Value,
        [string[]]$GrepOptions = @(),
        [string[]]$Trailing = @()
    )
    # One pattern per line, exactly as git reads a multi-line -e value. An empty
    # line would match EVERY file, so blank lines are dropped.
    $lines = @($Value -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { $global:LASTEXITCODE = 1; return @() }
    # Under the user's own local state (default ACL: this user only), never in
    # the project or the shared temp directory; removed in finally.
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $patternPath = Join-Path $stateDir ('SecretsCheck-pattern-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [System.IO.File]::WriteAllText($patternPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        return (Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $Cwd, 'grep') + @($GrepOptions) + @('-f', $patternPath) + @($Trailing)))
    }
    finally {
        try { [System.IO.File]::Delete($patternPath) } catch { }
    }
}
