# ---- structured outcome ----------------------------------------------------
# Component results are accumulated here and written to -ResultPath. States:
#   ok            - the component was applied and verified
#   failed        - the component could not be applied
#   skipped       - not applicable to this invocation (e.g. client not selected)
#   trackingFailed- runtime/settings succeeded but the registry write did not
$script:ComponentResults = New-Object System.Collections.Generic.List[object]
function Set-ComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'failed', 'skipped', 'trackingFailed')][string]$Status,
        [string]$ReasonCode = '',
        [string]$Message = ''
    )
    Write-ManagementComponentAudit -Component $Component -Status $Status -ReasonCode $ReasonCode
    # Sanitized message only: never raw file contents, .env values or stdin.
    $entry = [pscustomobject][ordered]@{
        component = $Component
        status    = $Status
        reason    = $ReasonCode
        message   = $Message
        atUtc     = [DateTime]::UtcNow.ToString('o')
    }
    for ($i = 0; $i -lt $script:ComponentResults.Count; $i++) {
        if ($script:ComponentResults[$i].component -eq $Component) { $script:ComponentResults[$i] = $entry; return }
    }
    [void]$script:ComponentResults.Add($entry)
}
function Write-InstallResult {
    param([string]$Overall)
    Write-ManagementAudit -Event 'install-outcome' -Data @{ overall = $Overall }
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        $document = [pscustomobject][ordered]@{
            schema     = 1
            overall    = $Overall
            components = @($script:ComponentResults.ToArray())
            atUtc      = [DateTime]::UtcNow.ToString('o')
        }
        $directory = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($ResultPath, ($document | ConvertTo-Json -Depth 20), ([System.Text.UTF8Encoding]::new($false)))
    }
    catch {
        # A result-file failure must never fail the install itself.
    }
}

# THE one definition of the overall verdict. It used to be computed inline at
# the very end, while the install RECORD hardcoded lastResult='ok' 50 lines
# earlier - so a partial or failed outcome still persisted a record claiming
# success. Two places deciding the same thing is how they disagree; there is
# now one, called by both.
#
# States:
#   ok      every component landed exactly what was asked for
#   partial something landed, but less than was asked for (a failed component
#           alongside a working one, a degraded client, or tracking that failed)
#   failed  nothing the caller asked for is installed
function Get-OverallInstallResult {
    $failed = @($script:ComponentResults | Where-Object { $_.status -eq 'failed' })
    $trackingFailed = @($script:ComponentResults | Where-Object { $_.status -eq 'trackingFailed' })
    # A component that landed with LESS than it was asked for is still 'ok' at
    # the component level - component statuses are exactly ok/failed/skipped/
    # trackingFailed, and 'partial' is the OVERALL result's vocabulary, not a
    # component's. That distinction is deliberate, so degradation is read off the
    # REASON CODE instead:
    #   degraded              installed, but with unsupported events dropped and/or
    #                         a gate the client can only ever run as advisory
    #   postRegistrationError the registration IS live, but a later step failed -
    #                         the one that must never read as a clean 'ok'
    $degraded = @($script:ComponentResults | Where-Object {
            $_.status -eq 'ok' -and @('degraded', 'postRegistrationError') -contains [string]$_.reason })
    # ONLY CLIENT components answer "did anything the caller asked for actually
    # land". 'registry' and 'nativeGit' are BOOKKEEPING, and counting them as
    # landed work inverted the verdict: a single-client install whose ONLY client
    # component FAILED still had an ok 'registry' component, so the total failure
    # was downgraded to 'partial' - telling the caller to keep an installation
    # that does not exist. The client set is derived from the capability table, never
    # a third hardcoded list beside the two this repo already keeps in sync.
    $clientIds = @(Get-HookMakerClientIds)
    $okClients = @($script:ComponentResults | Where-Object {
            $_.status -eq 'ok' -and @($clientIds) -contains [string]$_.component })
    # Components are INDEPENDENT, so a failure among them is only a total failure
    # when no client landed. A request for three clients where two are installed
    # and one is unsupported is 'partial' - reporting it 'failed' would tell the
    # caller to discard two working installations, and reporting it 'ok' would
    # claim an install that never happened. Both are wrong in opposite directions.
    if ($failed.Count -gt 0 -and $okClients.Count -eq 0) { return 'failed' }
    if ($failed.Count -gt 0 -or $trackingFailed.Count -gt 0 -or $degraded.Count -gt 0) { return 'partial' }
    return 'ok'
}
