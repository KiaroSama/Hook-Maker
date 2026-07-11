# GitSyncCheck - warns the agent when the current project is out of sync with
# its git remote (GitHub etc.). Intended for the SessionStart event.
#
# Behavior (silent unless something needs attention):
# - Not a git repository, or no remote configured -> exit silently.
# - Fetches the upstream quietly (skipped when offline; then compares against
#   the last known remote state).
# - Reports: uncommitted local changes, commits ahead of the remote (unpushed),
#   commits behind the remote (unpulled), or a missing upstream branch.
#
# Install via the Hook Maker menu: option 2 -> install existing hook -> SessionStart.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$hookInput = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $hookInput = $raw | ConvertFrom-Json
    }
}
catch { }
if ($null -eq $hookInput) {
    exit 0
}

$cwd = ''
if ($null -ne $hookInput.PSObject.Properties['cwd'] -and $null -ne $hookInput.cwd) {
    $cwd = [string]$hookInput.cwd
}
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    $output = & git -C $cwd @GitArgs 2>$null
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = @($output) }
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    exit 0
}

# Inside a git work tree with at least one remote?
$inRepo = Invoke-Git @('rev-parse', '--is-inside-work-tree')
if (-not $inRepo.Ok -or [string]$inRepo.Output[0] -ne 'true') {
    exit 0
}
$remotes = Invoke-Git @('remote')
if (-not $remotes.Ok -or @($remotes.Output | Where-Object { $_ }).Count -eq 0) {
    exit 0
}

$findings = New-Object System.Collections.Generic.List[string]

# Refresh remote refs; when offline, fall back to the last fetched state.
$fetch = Invoke-Git @('fetch', '--quiet')
if (-not $fetch.Ok) {
    [void]$findings.Add('The remote could not be fetched (offline?); comparison uses the last known remote state.')
}

# Uncommitted local changes (tracked + untracked).
$status = Invoke-Git @('status', '--porcelain')
if ($status.Ok) {
    $dirtyCount = @($status.Output | Where-Object { $_ }).Count
    if ($dirtyCount -gt 0) {
        [void]$findings.Add('There are ' + $dirtyCount + ' uncommitted change(s) in the working tree.')
    }
}

# Ahead/behind relative to the upstream branch.
$branch = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
$branchName = ''
if ($branch.Ok) {
    $branchName = [string]$branch.Output[0]
}
$upstream = Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
if ($upstream.Ok) {
    $upstreamName = [string]$upstream.Output[0]
    # Parentheses required: the array comma binds tighter than +, so an
    # unparenthesized concat would split into two separate git arguments.
    $counts = Invoke-Git @('rev-list', '--left-right', '--count', ($upstreamName + '...HEAD'))
    if ($counts.Ok -and $counts.Output.Count -gt 0) {
        $parts = ([string]$counts.Output[0]) -split '\s+'
        if ($parts.Count -ge 2) {
            $behind = [int]$parts[0]
            $ahead = [int]$parts[1]
            if ($behind -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $behind + ' commit(s) BEHIND ' + $upstreamName + ' (pull needed).')
            }
            if ($ahead -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $ahead + ' commit(s) AHEAD of ' + $upstreamName + ' (push needed).')
            }
        }
    }
}
elseif ($branchName -ne '' -and $branchName -ne 'HEAD') {
    [void]$findings.Add('Branch ' + $branchName + ' has no upstream branch configured (never pushed?).')
}

if ($findings.Count -eq 0) {
    exit 0
}

$eventName = 'SessionStart'
if ($null -ne $hookInput.PSObject.Properties['hook_event_name'] -and $null -ne $hookInput.hook_event_name) {
    $eventName = [string]$hookInput.hook_event_name
}
$message = "GIT SYNC STATUS (" + $cwd + "):`n- " + ($findings.ToArray() -join "`n- ")
@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
