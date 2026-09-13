# ---------------------------------------------------------------------------
# The ONE way the wizard invokes Install-Hook.ps1 and decides what actually
# happened.
#
# WHY THIS FILE EXISTS: three flows used to invoke the installer and only ONE
# of them read the structured result. The fresh and config-driven flows
# captured the installer's console output and then printed "+ installed"
# unconditionally, so an install whose runtime and settings landed but whose
# registry tracking FAILED was reported to the user as a clean success. The
# installer signals that by returning `overall = partial|failed` in its result
# document WITHOUT throwing, so "no exception" is not evidence and neither is
# console text.
#
# The rule this encodes: an install is successful only when a VALID structured
# result says so. Missing, unreadable or unparseable output is 'unknown', and
# unknown is never success.
#
# Loaded before Setup-SyncGroupRelocate.ps1 and Setup-SyncGroupInstallFlows.ps1
# because both call into it. Pure with respect to wizard UI: it writes no
# console output and owns no formatting, so the caller decides how a verdict is
# rendered.
# ---------------------------------------------------------------------------

# Classify an `overall = partial` install. Partial is the installer's way of
# saying "components disagreed", and the components are what decide whether a
# human needs to act.
function Get-PartialInstallVerdict {
    param($Components)
    $realProblems = @(@($Components) |
        Where-Object {
            [string]$_.status -eq 'failed' -or [string]$_.status -eq 'trackingFailed' -or
            [string]$_.reason -eq 'postRegistrationError'
        } | ForEach-Object { [string]$_.component + ' (' + [string]$_.reason + ')' })
    $capabilityOnly = @(@($Components) |
        Where-Object {
            [string]$_.reason -eq 'degraded' -and
            -not ([string]$_.status -eq 'failed' -or [string]$_.status -eq 'trackingFailed')
        } | ForEach-Object { [string]$_.component })

    if ($realProblems.Count -gt 0) {
        $notes = @($realProblems) + @($capabilityOnly | ForEach-Object { $_ + ' (degraded)' })
        return [pscustomobject]@{ IsFailure = $true; Summary = ('partial - ' + ($notes -join ', ')) }
    }
    if ($capabilityOnly.Count -gt 0) {
        # Installed, and honest about what the client cannot do.
        return [pscustomobject]@{ IsFailure = $false; Summary = ('ok (reduced capability: ' + ($capabilityOnly -join ', ') + ')') }
    }
    # 'partial' with nothing this function recognizes is NOT quietly a success:
    # an unknown reason is exactly the case that must reach a human.
    $unknown = @(@($Components) | Where-Object { [string]$_.status -ne 'ok' } |
        ForEach-Object { [string]$_.component + ' (' + [string]$_.reason + ')' })
    if ($unknown.Count -eq 0) { $unknown = @('reason not reported') }
    return [pscustomobject]@{ IsFailure = $true; Summary = ('partial - ' + ($unknown -join ', ')) }
}

# Run the installer once and return a verdict derived from its RESULT DOCUMENT.
#
# Returns an object with:
#   Ok       - $true only for a real success (possibly with reduced capability)
#   Status   - 'ok' | 'failed' | 'unknown'
#   Summary  - one short human-readable line, always populated
#   Result   - the parsed result object, or $null when there was none
#   Output   - the installer's captured console/stream output, for the log
#
# The temporary result file is created by THIS function and removed in finally,
# so no caller can leak one or read a stale document from an earlier run.
function Invoke-HookInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$InstallScript,
        [Parameter(Mandatory = $true)][hashtable]$InstallArgs
    )

    # A caller-supplied ResultPath would let one flow silently opt out of the
    # very check this function exists to enforce, so the path is always ours.
    # NOT named $args: that is an automatic variable holding this function's own
    # unbound arguments, and splatting @args would then be ambiguous to read.
    $installerArgs = @{}
    foreach ($key in $InstallArgs.Keys) {
        if ([string]$key -eq 'ResultPath') { continue }
        $installerArgs[$key] = $InstallArgs[$key]
    }
    $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-install-result-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
    $installerArgs['ResultPath'] = $resultFile

    $output = @()
    $result = $null
    try {
        try {
            $output = @(& $InstallScript @installerArgs *>&1)
        }
        catch {
            return [pscustomobject]@{
                Ok      = $false
                Status  = 'failed'
                Summary = $_.Exception.Message
                Result  = $null
                Output  = $output
            }
        }

        if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
            try { $result = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { $result = $null }
        }
    }
    finally {
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    }

    # NO structured result is 'unknown', never success. The installer exiting
    # quietly with nothing to say is exactly the shape a stubbed or crashed
    # installer has, and it is the case this whole function was added for.
    if ($null -eq $result) {
        return [pscustomobject]@{
            Ok      = $false
            Status  = 'unknown'
            Summary = 'no structured result from the installer'
            Result  = $null
            Output  = $output
        }
    }

    $overall = [string]$result.overall
    if ($overall -eq 'failed') {
        $failedNames = @(@($result.components) | Where-Object { [string]$_.status -eq 'failed' } | ForEach-Object { [string]$_.component })
        $detail = if ($failedNames.Count -gt 0) { ' (' + ($failedNames -join ', ') + ')' } else { '' }
        return [pscustomobject]@{
            Ok      = $false
            Status  = 'failed'
            Summary = ('failed' + $detail)
            Result  = $result
            Output  = $output
        }
    }
    if ($overall -eq 'partial') {
        $verdict = Get-PartialInstallVerdict -Components $result.components
        return [pscustomobject]@{
            Ok      = (-not $verdict.IsFailure)
            Status  = $(if ($verdict.IsFailure) { 'failed' } else { 'ok' })
            Summary = $verdict.Summary
            Result  = $result
            Output  = $output
        }
    }
    if ($overall -eq 'ok') {
        return [pscustomobject]@{ Ok = $true; Status = 'ok'; Summary = 'ok'; Result = $result; Output = $output }
    }

    # A result document that exists but carries an overall value this build does
    # not know is unknown, not ok - a newer installer must not be read as green
    # by an older wizard.
    return [pscustomobject]@{
        Ok      = $false
        Status  = 'unknown'
        Summary = ('unrecognized install outcome: ' + $(if ([string]::IsNullOrWhiteSpace($overall)) { '(missing)' } else { $overall }))
        Result  = $result
        Output  = $output
    }
}

# Install ONE hook into a list of target projects, judging each by its own
# structured result.
#
# Exists because the fresh and config-driven flows were byte-for-byte the same
# loop: merge the client/timeout splat hashtables into the base arguments, call
# the installer, log its output, count what landed. Keeping one copy is what
# stops the two flows drifting apart again - drifting apart is exactly how one
# of them ended up without result validation in the first place.
#
# Renders nothing. Returns the per-target verdicts and lets the caller decide
# how a wizard screen presents them.
function Invoke-HookInstallForTargets {
    param(
        [Parameter(Mandatory = $true)][string]$InstallScript,
        [Parameter(Mandatory = $true)]$Targets,
        [Parameter(Mandatory = $true)][hashtable]$BaseArgs,
        [hashtable[]]$ExtraArgs = @()
    )
    $results = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[string]
    $installed = 0
    foreach ($target in @($Targets)) {
        $installerArgs = @{}
        foreach ($key in @($BaseArgs.Keys)) { $installerArgs[$key] = $BaseArgs[$key] }
        foreach ($extra in @($ExtraArgs)) {
            if ($null -eq $extra) { continue }
            foreach ($key in @($extra.Keys)) { $installerArgs[$key] = $extra[$key] }
        }
        $installerArgs['TargetProject'] = $target.Root
        $verdict = Invoke-HookInstaller -InstallScript $InstallScript -InstallArgs $installerArgs
        if ($verdict.Ok) { $installed++ }
        else { [void]$failures.Add([string]$target.Name + ': ' + [string]$verdict.Summary) }
        [void]$results.Add([pscustomobject]@{ Target = $target; Verdict = $verdict })
    }
    return [pscustomobject]@{
        Results        = @($results.ToArray())
        InstalledCount = $installed
        Failures       = @($failures.ToArray())
    }
}
