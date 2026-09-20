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

# The schema this build understands, and the vocabularies it was written
# against. A NEWER installer is not an error and not a success either - it is
# unknown, and saying so is the point.
. (Join-Path $PSScriptRoot '_clientcapability.ps1')
$script:InstallResultSchema = 1
$script:InstallOverallValues = @('ok', 'partial', 'failed')
$script:InstallComponentStatuses = @('ok', 'failed', 'skipped', 'trackingFailed')

# Read a property WITHOUT throwing on a shape that does not have it.
#
# Direct access is not safe here: the document comes from another process, and
# under StrictMode a missing property on a malformed shape (an array, a bare
# string, a JSON scalar) throws instead of returning nothing - so a malformed
# result crashed the wizard rather than being reported as unknown.
function Get-ResultProperty {
    param($Document, [string]$Name, [switch]$PreserveCollection)
    if ($null -eq $Document) { return $null }
    try {
        if ($Document -is [System.Collections.IDictionary]) {
            if ($Document.Contains($Name)) { if ($PreserveCollection) { return ,$Document[$Name] }; return $Document[$Name] }
            return $null
        }
        $prop = $Document.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $null }
        if ($PreserveCollection) { return ,$prop.Value }
        return $prop.Value
    }
    catch { return $null }
}

# Is this document one this build can read AT ALL, and does it agree with
# itself? `{"overall":"ok"}` used to be accepted on the strength of that one
# field - no schema, no components, nothing to contradict it - and a document
# claiming overall=ok while carrying a failed component passed just as easily.
#
# Returns @{ Ok; Summary }. Ok=$false means the document is not usable as proof
# of anything; the caller reports 'unknown', never success.
function Test-InstallResultDocument {
    param($Document, [string[]]$RequiredComponents = @())
    if ($null -eq $Document) { return [pscustomobject]@{ Ok = $false; Summary = 'no structured result from the installer' } }
    if ($Document -is [string] -or $Document -is [System.Array] -or $Document -is [System.ValueType]) {
        return [pscustomobject]@{ Ok = $false; Summary = 'install result is not a result document' }
    }

    $schema = Get-ResultProperty -Document $Document -Name 'schema' -PreserveCollection
    if ($null -ne $schema -and $schema -isnot [int] -and $schema -isnot [long]) {
        return [pscustomobject]@{ Ok = $false; Summary = 'install result schema must be an integer' }
    }
    if ($null -eq $schema) { return [pscustomobject]@{ Ok = $false; Summary = 'install result carries no schema' } }
    $schemaNumber = 0
    if (-not [int]::TryParse([string]$schema, [ref]$schemaNumber)) {
        return [pscustomobject]@{ Ok = $false; Summary = ('install result schema is not a number: ' + [string]$schema) }
    }
    if ($schemaNumber -ne $script:InstallResultSchema) {
        # Deliberately not "corrupt": a newer installer is a real thing, and
        # guessing at its meaning is how an older wizard reports a green install
        # it never understood.
        return [pscustomobject]@{ Ok = $false; Summary = ('install result schema ' + $schemaNumber + ' is newer than this build understands (' + $script:InstallResultSchema + ')') }
    }

    $outcomeValue = Get-ResultProperty -Document $Document -Name 'overall' -PreserveCollection
    if ($outcomeValue -isnot [string]) { return [pscustomobject]@{ Ok = $false; Summary = 'install outcome must be a string' } }
    $overall = [string]$outcomeValue
    if ($script:InstallOverallValues -notcontains $overall) {
        return [pscustomobject]@{ Ok = $false; Summary = ('unrecognized install outcome: ' + $(if ([string]::IsNullOrWhiteSpace($overall)) { '(missing)' } else { $overall })) }
    }

    # Access the property without pipeline unrolling: one JSON object is not
    # a one-element JSON array, and an empty array must keep its provenance.
    $componentsRaw = if ($Document -is [System.Collections.IDictionary]) { ,$Document['components'] } else { $property = $Document.PSObject.Properties['components']; if ($null -ne $property) { ,$property.Value } }
    if ($componentsRaw -isnot [System.Array]) { return [pscustomobject]@{ Ok = $false; Summary = 'install result components must be an array' } }
    if ($null -eq $componentsRaw) { return [pscustomobject]@{ Ok = $false; Summary = 'install result lists no components' } }
    $components = @($componentsRaw)
    if ($components.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Summary = 'install result lists no components' } }

    $names = @()
    $seen = @{}
    foreach ($component in $components) {
        if ($component -isnot [System.Management.Automation.PSCustomObject] -and $component -isnot [System.Collections.IDictionary]) {
            return [pscustomobject]@{ Ok = $false; Summary = 'install result has a non-object component' }
        }
        if ((Get-ResultProperty $component 'component' -PreserveCollection) -isnot [string] -or (Get-ResultProperty $component 'status' -PreserveCollection) -isnot [string]) {
            return [pscustomobject]@{ Ok = $false; Summary = 'install component names and statuses must be strings' }
        }
        $name = [string](Get-ResultProperty -Document $component -Name 'component')
        $status = [string](Get-ResultProperty -Document $component -Name 'status')
        if ([string]::IsNullOrWhiteSpace($name)) { return [pscustomobject]@{ Ok = $false; Summary = 'install result has a component with no name' } }
        if ($script:InstallComponentStatuses -notcontains $status) {
            return [pscustomobject]@{ Ok = $false; Summary = ('install result component ' + $name + ' has an unrecognized status: ' + $(if ([string]::IsNullOrWhiteSpace($status)) { '(missing)' } else { $status })) }
        }
        if ((@(Get-HookMakerClientIds) + @('validation', 'nativeGit', 'registry', 'unknown')) -notcontains $name) {
            return [pscustomobject]@{ Ok = $false; Summary = ('unrecognized install component: ' + $name) }
        }
        if ($seen.ContainsKey($name)) { return [pscustomobject]@{ Ok = $false; Summary = ('duplicate install component: ' + $name) } }
        $seen[$name] = $true
        $names += $name
    }

    # AGREEMENT. `overall` is the installer's summary of the components, so a
    # summary its own components contradict proves the document wrong, not the
    # install good.
    $broken = @($components | Where-Object {
            $s = [string](Get-ResultProperty -Document $_ -Name 'status')
            $s -eq 'failed' -or $s -eq 'trackingFailed'
        })
    if ($overall -eq 'ok' -and $broken.Count -gt 0) {
        $brokenNames = @($broken | ForEach-Object { [string](Get-ResultProperty -Document $_ -Name 'component') })
        return [pscustomobject]@{ Ok = $false; Summary = ('install result claims ok while reporting failed component(s): ' + ($brokenNames -join ', ')) }
    }
    if ($overall -eq 'failed' -and $broken.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Summary = 'install result claims failed but reports no failed component' }
    }
    # postRegistrationError is a REASON, not a status, so a component can carry
    # it while still reading 'ok'. Get-PartialInstallVerdict already treats it as
    # a real problem on the partial path; an overall=ok document carrying one was
    # the only way it reached a caller unexamined.
    if ($overall -eq 'ok') {
        $postReg = @($components | Where-Object { [string](Get-ResultProperty -Document $_ -Name 'reason') -eq 'postRegistrationError' })
        if ($postReg.Count -gt 0) {
            $postRegNames = @($postReg | ForEach-Object { [string](Get-ResultProperty -Document $_ -Name 'component') })
            return [pscustomobject]@{ Ok = $false; Summary = ('install result claims ok while reporting a post-registration error on: ' + ($postRegNames -join ', ')) }
        }
    }

    # COVERAGE. A client that was asked for and is absent from the components is
    # not "installed by default" - nothing said anything about it at all.
    foreach ($required in @($RequiredComponents)) {
        # An EMPTY entry is not a requirement. PowerShell unrolls an empty array
        # on return, so "nothing was requested" arrives here as $null, and
        # @($null) is one $null element - which read as a requested client with
        # no name and failed every install that asked for no client in
        # particular.
        if ([string]::IsNullOrWhiteSpace([string]$required)) { continue }
        if ($names -notcontains $required) {
            return [pscustomobject]@{ Ok = $false; Summary = ('install result never mentions the requested client: ' + $required) }
        }
        # NAMED IS NOT INSTALLED. A requested client reported as 'skipped' was
        # deliberately not installed, and an overall=ok carrying it used to pass
        # coverage purely because the name appeared. The caller asked for that
        # client; a document saying "asked for, not done, all fine" disagrees
        # with itself exactly the way a failed component does.
        if ($overall -eq 'ok') {
            $requiredComponent = @($components | Where-Object { [string](Get-ResultProperty -Document $_ -Name 'component') -eq $required })[0]
            $requiredStatus = [string](Get-ResultProperty -Document $requiredComponent -Name 'status')
            if ($requiredStatus -ne 'ok') {
                return [pscustomobject]@{ Ok = $false; Summary = ('install result claims ok while the requested client ' + $required + ' is ' + $requiredStatus) }
            }
        }
    }
    return [pscustomobject]@{ Ok = $true; Summary = 'ok' }
}

# Which clients this invocation asked for, derived the SAME way
# Install-Hook.ps1 derives them. Two earlier readings were wrong in the same
# direction: recognising only the legacy -ClaudeOnly/-CodexOnly switches missed
# the canonical -Clients array entirely, and treating "no switch" as "nothing
# requested" missed the installer's own documented default.
#
# The installer resolves clients from the REQUEST, never from what happens to be
# on the machine ($InstallClaude = $resolvedClients -contains 'claude'), so the
# default genuinely asks for both and records a component for each. A coverage
# check that demands nothing is a coverage check that cannot fail.
function Get-RequestedInstallClients {
    param([hashtable]$InstallArgs)
    if ($null -eq $InstallArgs) { return @('claude', 'codex') }
    if ($InstallArgs.ContainsKey('Clients')) {
        $named = @(@($InstallArgs['Clients']) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ -ne '' })
        # An explicitly empty -Clients is a caller error the installer throws
        # on; reporting no requirement here would hide it behind a green result.
        if ($named.Count -gt 0) { return @($named | Select-Object -Unique) }
        return @('claude', 'codex')
    }
    $claudeOnly = ($InstallArgs.ContainsKey('ClaudeOnly') -and [bool]$InstallArgs['ClaudeOnly'])
    $codexOnly = ($InstallArgs.ContainsKey('CodexOnly') -and [bool]$InstallArgs['CodexOnly'])
    if ($claudeOnly -and -not $codexOnly) { return @('claude') }
    if ($codexOnly -and -not $claudeOnly) { return @('codex') }
    return @('claude', 'codex')
}

# Classify an `overall = partial` install. Partial is the installer's way of
# saying "components disagreed", and the components are what decide whether a
# human needs to act.
function Get-PartialInstallVerdict {
    param($Components, [string[]]$RequiredComponents = @())
    foreach ($required in @($RequiredComponents)) {
        $matching = @($Components | Where-Object { (Get-ResultProperty $_ 'component') -eq $required })
        if ($matching.Count -ne 1 -or (Get-ResultProperty $matching[0] 'status') -ne 'ok') {
            return [pscustomobject]@{ IsFailure = $true; Summary = ('partial - requested client not installed: ' + $required) }
        }
    }
    # Every field read through Get-ResultProperty, never a direct $_.reason.
    # The document comes from another process and a component is not obliged to
    # carry every optional field; under StrictMode a direct access on one that
    # does not THROWS, which turned a readable-but-sparse result into a crashed
    # wizard instead of the 'unknown' it should report.
    $realProblems = @(@($Components) |
        Where-Object {
            $s = [string](Get-ResultProperty -Document $_ -Name 'status')
            $r = [string](Get-ResultProperty -Document $_ -Name 'reason')
            $s -eq 'failed' -or $s -eq 'trackingFailed' -or $r -eq 'postRegistrationError' -or
            ($s -eq 'skipped' -and $r -notin @('notApplicable', 'notSelected', 'notInstalled'))
        } | ForEach-Object {
            [string](Get-ResultProperty -Document $_ -Name 'component') + ' (' +
            [string](Get-ResultProperty -Document $_ -Name 'reason') + ')' })
    $capabilityOnly = @(@($Components) |
        Where-Object {
            $s = [string](Get-ResultProperty -Document $_ -Name 'status')
            [string](Get-ResultProperty -Document $_ -Name 'reason') -eq 'degraded' -and
            $s -eq 'ok'
        } | ForEach-Object { [string](Get-ResultProperty -Document $_ -Name 'component') })

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
    $unknown = @(@($Components) | Where-Object { [string](Get-ResultProperty -Document $_ -Name 'status') -ne 'ok' } |
        ForEach-Object {
            [string](Get-ResultProperty -Document $_ -Name 'component') + ' (' +
            [string](Get-ResultProperty -Document $_ -Name 'reason') + ')' })
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
    #
    # A result that EXISTS still has to be a result: readable schema, a known
    # outcome, components that exist, carry known statuses and do not contradict
    # the outcome, and coverage of every client this invocation asked for. Trust
    # used to stop at the `overall` field, so `{"overall":"ok"}` was a green
    # install and a malformed shape threw instead of reporting unknown.
    $validation = Test-InstallResultDocument -Document $result -RequiredComponents (Get-RequestedInstallClients -InstallArgs $InstallArgs)
    if (-not $validation.Ok) {
        return [pscustomobject]@{
            Ok      = $false
            Status  = 'unknown'
            Summary = [string]$validation.Summary
            Result  = $result
            Output  = $output
        }
    }

    $overall = [string](Get-ResultProperty -Document $result -Name 'overall')
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
        $verdict = Get-PartialInstallVerdict -Components $result.components -RequiredComponents (Get-RequestedInstallClients -InstallArgs $InstallArgs)
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

    # Unreachable while validation runs first - an unknown `overall` is refused
    # up there, with the schema and the components. Kept as the fail-closed
    # floor: if validation is ever narrowed, the fallthrough is still 'unknown'
    # rather than an implicit success.
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
