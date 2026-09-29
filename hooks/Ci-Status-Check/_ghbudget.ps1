# Ci-Status-Check private sibling: ONE GitHub budget per hook run.
#
# Every gh call is bounded by the REMAINING budget, never by its own fresh 20 s:
# three slow calls used to add up to the hook's registered 60 s timeout, the
# client killed it, and the gate emitted nothing at all on exactly the Stops
# where GitHub was slow. Dot-sourced by Ci-Status-Check.ps1 (definitions only;
# runs in the entry script's scope, which has _hooklib.ps1 loaded).

$script:GhDeadlineUtc = [DateTime]::MaxValue
$script:GhBudgetExhausted = $false
$script:GhAuthProjectKey = ''
$script:GhAuthSessionId = ''

function Initialize-GhBudget {
    param([int]$Seconds)
    if ($Seconds -lt 5) { $Seconds = 5 }
    if ($Seconds -gt 300) { $Seconds = 300 }
    $script:GhDeadlineUtc = [DateTime]::UtcNow.AddSeconds($Seconds)
    $script:GhBudgetExhausted = $false
}

function Get-GhRemainingSeconds {
    if ($script:GhDeadlineUtc -eq [DateTime]::MaxValue) { return [int]::MaxValue }
    return [int][Math]::Floor(($script:GhDeadlineUtc - [DateTime]::UtcNow).TotalSeconds)
}

# Same contract as Invoke-QuietCommand (output lines; $LASTEXITCODE set), with
# the timeout clamped to what is left. Over budget: no process is started,
# $LASTEXITCODE is 124 (the runner's own "terminated" code) and the flag is set
# so the caller can say "not verified" instead of guessing.
function Invoke-GhBounded {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    $remaining = Get-GhRemainingSeconds
    if ($remaining -lt 1) {
        $script:GhBudgetExhausted = $true
        $global:LASTEXITCODE = 124
        return @()
    }
    $timeout = [Math]::Min(20, $remaining)
    $out = Invoke-QuietCommand -FilePath gh -ArgumentList $ArgumentList -TimeoutSeconds $timeout
    if ($LASTEXITCODE -ne 0 -and (Get-GhRemainingSeconds) -lt 1) { $script:GhBudgetExhausted = $true }
    return $out
}

# gh auth status is a network round trip and its answer does not change within
# a session. Only a POSITIVE answer is cached, per (project, session), so fixing
# `gh auth login` mid-session takes effect at the next Stop.
function Test-GhAuthenticated {
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    $cachePath = Join-Path $stateDir ('CiStatusCheck-Auth-' + $script:GhAuthProjectKey + '.json')
    $cacheable = ($script:GhAuthSessionId -ne '' -and $script:GhAuthProjectKey -ne '')
    if ($cacheable) {
        try {
            $cached = Read-JsonFile $cachePath
            if ($null -ne $cached -and [string](Get-Field $cached 'sessionId') -eq $script:GhAuthSessionId -and [bool](Get-Field $cached 'ok')) { return $true }
        }
        catch { }
    }
    $null = Invoke-GhBounded -ArgumentList @('auth', 'status')
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok -and $cacheable) {
        try {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            Write-JsonFileAtomic -Path $cachePath -Value ([pscustomobject]@{ schema = 1; sessionId = $script:GhAuthSessionId; ok = $true; checkedUtc = [DateTime]::UtcNow.ToString('o') })
        }
        catch { }
    }
    return $ok
}

# One check-run's annotations, as a three-state verdict across every page up to
# the same strict bound:
#   'billing'      - carries GitHub's billing/payment failure annotation
#   'none'         - reached a terminating empty page with no failure annotation
#   'other'        - carries a failure annotation that is NOT billing
#   'unverifiable' - query error, unparseable page, or the page bound was hit
# Only 'billing' is positive evidence; 'other' and 'unverifiable' are treated as
# a genuine failure by the caller, so the function still fails CLOSED.
function Get-CheckRunBillingVerdict {
    param([string]$RepoSlug, [string]$CheckRunId, [int]$MaxPages, [int]$PerPage)
    $sawOtherFailure = $false
    for ($page = 1; $page -le $MaxPages; $page++) {
        $annJson = Invoke-GhBounded -ArgumentList @('api', ('repos/' + $RepoSlug + '/check-runs/' + $CheckRunId + '/annotations?per_page=' + $PerPage + '&page=' + $page))
        if ($LASTEXITCODE -ne 0) { return 'unverifiable' }       # query error - fail closed
        try { $annotations = @(((@($annJson) -join "`n") | ConvertFrom-Json)) }
        catch { return 'unverifiable' }                          # unparseable - fail closed
        if ($annotations.Count -eq 0) {
            if ($sawOtherFailure) { return 'other' }
            return 'none'                                        # no annotations at all - inconclusive, not disqualifying
        }
        foreach ($ann in $annotations) {
            if ($null -eq $ann) { continue }
            $level = ([string](Get-Field $ann 'annotation_level')).ToLowerInvariant()
            $message = [string](Get-Field $ann 'message')
            if ($level -eq 'failure' -and $message -match $script:BillingAnnotationPattern) { return 'billing' }
            if ($level -eq 'failure') { $sawOtherFailure = $true }
        }
    }
    return 'unverifiable'    # exceeded the page bound without a terminating empty page - fail closed
}
