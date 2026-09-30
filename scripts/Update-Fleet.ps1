# ---------------------------------------------------------------------------
# Update-Fleet.ps1 - the non-interactive form of the wizard's "Update installed
# hooks" (menu 32), for refreshing every tracked registration across the fleet.
#
# CONTRACT
#   * Same evaluation as menu 32: Get-UpdateEvaluationPlan over the managed
#     registry records. Same installer invocation: Invoke-HookInstallForTargets
#     (Invoke-HookInstaller for a global record), judged by the installer's
#     structured result document, never by console text.
#   * Each registration is repaired with its OWN identity: the recorded events
#     per client (Resolve-UpdateEventsForClient, which also applies a proven
#     retired-default migration), its scope, and - for an Engine record -
#     -Profile/-ConfigPath instead of -CustomHook (an Engine record reinstalled
#     as a custom hook loses its routing and then exits 0 in silence).
#   * State comes from the registry and the INSTALLED FILES only. A registration
#     the evaluation calls current but whose runtime lacks any -Marker is stale.
#     No bookkeeping file is written, so re-running after an interruption is
#     the resume: the markers and the evaluation decide what is left.
#   * Never installs a hook that was never installed. Never prompts. Never
#     touches a project it cannot reach: that is reported as unreachable, not
#     as a failure.
#
# PARAMETERS
#   -WhatIf        Dry run (the default when neither -WhatIf nor -Apply is given):
#                  print the counts, change nothing.
#   -Apply         Reinstall every stale or pending-migration registration.
#   -OnlyProject   A project root or folder name; only its registrations.
#   -Marker        '<file>[:<pattern>]', repeatable. The file is relative to the
#                  hook's runtime directory; a registration is current only when
#                  every marker file exists and contains its pattern.
#   -Compare       Read-only byte compare of every managed runtime against its
#                  source (after -Apply, with -WhatIf, or alone).
#   -ConfigPath    The sync-group config whose routes follow a relocated project
#                  (default: sync-hooks.json in the tool root).
#   -LogPath       Default logs\Update-Fleet_<UTC>.log under the tool root
#                  (HOOKMAKER_LOG_DIR overrides the directory). One line per
#                  registration, flushed as it is written.
#
# EXIT CODE: the number of failed registrations, plus the number of
# registrations -Compare found different or missing files in. 1 when the
# registry is unusable or -OnlyProject matches nothing.
#
# Usage:
#   pwsh -NoProfile -File .\scripts\Update-Fleet.ps1 [-WhatIf] [-OnlyProject <name>] [-Marker _commandtokens.ps1]
#   pwsh -NoProfile -File .\scripts\Update-Fleet.ps1 -Apply [-Compare]
# ---------------------------------------------------------------------------

param(
    [switch]$WhatIf,
    [switch]$Apply,
    [string]$OnlyProject = '',
    [string[]]$Marker = @(),
    [switch]$Compare,
    [string]$LogPath = '',
    [string]$ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'

if ($WhatIf -and $Apply) {
    Write-Host 'Choose one of -WhatIf and -Apply.' -ForegroundColor Red
    exit 1
}
$evaluate = $Apply -or $WhatIf -or -not $Compare

# ---- library load order: the wizard's own (Setup-SyncGroup.ps1) ------------
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')
. (Join-Path $ScriptRoot '_clientcapability.ps1')
. (Join-Path $ScriptRoot '_installinvoke.ps1')
. (Join-Path $ScriptRoot '_installevaluate.ps1')
# The event-migration destination is Get-HookRecommendedEvents, which lives only
# in the wizard; without it every retired binding reads "destination unknown"
# and is never moved. Load its metadata table, then the function itself by AST
# (dot-sourcing the wizard would start its menu).
. (Join-Path $ScriptRoot 'Setup-SyncGroupPresentation.ps1')
$wizardAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'), [ref]$null, [ref]$null)
$resolverAst = $wizardAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-HookRecommendedEvents' }, $true) |
    Select-Object -First 1
if ($null -eq $resolverAst) { throw 'Get-HookRecommendedEvents was not found in Setup-SyncGroup.ps1.' }
. ([scriptblock]::Create($resolverAst.Extent.Text))
. (Join-Path $ScriptRoot '_updatefleetmarkers.ps1')
. (Join-Path $ScriptRoot '_updatefleetcompare.ps1')
. (Join-Path $ScriptRoot 'Setup-SyncGroupRelocate.ps1')

# ---- logging -----------------------------------------------------------------
$script:FleetLogPath = $null
function Initialize-FleetLog {
    param([string]$Requested)
    try {
        $path = $Requested
        if ([string]::IsNullOrWhiteSpace($path)) {
            $directory = Join-Path $ToolRoot 'logs'
            if (-not [string]::IsNullOrWhiteSpace($env:HOOKMAKER_LOG_DIR)) { $directory = $env:HOOKMAKER_LOG_DIR }
            $base = Join-Path $directory ('Update-Fleet_' + [DateTime]::UtcNow.ToString('yyyy-MM-dd_HH-mm-ss') + '_UTC')
            $path = $base + '.log'
            $suffix = 1
            while (Test-Path -LiteralPath $path) { $path = $base + '_' + $suffix + '.log'; $suffix++ }
        }
        $path = [System.IO.Path]::GetFullPath($path)
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::AppendAllText($path, '', $Utf8NoBom)
        $script:FleetLogPath = $path
    }
    catch {
        $script:FleetLogPath = $null
        Write-Host ('Warning: file logging is unavailable: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# AppendAllText opens and closes the file per line, so an interrupted run
# leaves every line written so far on disk.
function Write-FleetLog {
    param([string]$Level, [string]$Component, [string]$Message)
    if ($null -eq $script:FleetLogPath) { return }
    $line = '[' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC] [' + $Level + '] [' + $Component + '] ' + $Message
    try { [System.IO.File]::AppendAllText($script:FleetLogPath, $line + "`r`n", $Utf8NoBom) } catch { }
}

function Get-RegistrationLabel {
    param($Registration)
    return ($Registration.Project + '/' + $Registration.Hook + '/' + $Registration.Client)
}

# One stale registration through the shared installer path, then an independent
# re-read of the record: the installer saying ok is not proof the runtime is now
# current. Returns '' on success, otherwise the failure reason.
function Invoke-FleetRepair {
    param($Registration, [object[]]$Markers)
    $record = $Registration.Record
    $client = $Registration.Client
    $events = @()
    if ($null -ne $Registration.EventPlan) { $events = @($Registration.EventPlan.Events) }
    if ($events.Count -eq 0) { return 'no events resolved for this client' }

    $baseArgs = @{ Events = $events; Clients = @($client) }
    if ((Get-FleetRecordField $record 'hookType') -eq 'Engine') {
        $baseArgs['Profile'] = Get-FleetRecordField $record 'profile'
        $baseArgs['ConfigPath'] = Get-FleetRecordField $record 'configPath'
    }
    else { $baseArgs['CustomHook'] = Get-FleetRecordField $record 'sourceScript' }

    $verdict = $null
    if ((Get-FleetRecordField $record 'scope') -eq 'global') {
        $verdict = Invoke-HookInstaller -InstallScript $InstallScript -InstallArgs $baseArgs
    }
    else {
        $target = [pscustomobject]@{ Root = (Get-FleetRecordField $record 'targetProjectRoot'); Name = $Registration.Project }
        $outcome = Invoke-HookInstallForTargets -InstallScript $InstallScript -Targets @($target) -BaseArgs $baseArgs
        $verdict = @($outcome.Results)[0].Verdict
    }
    foreach ($line in @($verdict.Output)) { Write-FleetLog 'DEBUG' 'INSTALL' ([string]$line) }
    if (-not $verdict.Ok) { return ('installer: ' + [string]$verdict.Summary) }

    $fresh = Get-InstallRecordById -ToolRoot $ToolRoot -Id (Get-FleetRecordField $record 'id')
    if ($null -eq $fresh) { return 'post-update verification: the installation is no longer tracked' }
    $integrity = Get-InstallIntegrity -Record $fresh -ToolRoot $ToolRoot
    $bad = @(@($integrity.Components) | Where-Object {
            ([string]$_.Name -eq 'source' -or [string]$_.Name -eq $client) -and [string]$_.Status -ne 'current' })
    if ($bad.Count -gt 0) { return ('post-update verification: ' + [string]$bad[0].Name + ': ' + [string]$bad[0].Detail) }
    $subrecord = Get-ClientSubrecord -Record $fresh -Client $client
    $runtimeDir = if ($null -ne $subrecord) { Split-Path -Parent ([string]$subrecord.runtimeScript) } else { '' }
    $missing = Get-MissingFleetMarker -RuntimeDir $runtimeDir -Markers $Markers
    if ($missing -ne '') { return ('post-update verification: marker still missing: ' + $missing) }
    return ''
}

# ---- run ---------------------------------------------------------------------
$markers = @()
try { $markers = @($Marker | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-FleetMarker -Spec $_ }) }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }

Initialize-FleetLog -Requested $LogPath
$mode = if ($Apply) { 'apply' } elseif ($evaluate) { 'dry run' } else { 'compare only' }
Write-FleetLog 'INFO' 'FLEET' ('Update-Fleet started: mode=' + $mode + ' onlyProject=' + $OnlyProject + ' markers=' + (@($markers | ForEach-Object { $_.Spec }) -join ',') + ' compare=' + [bool]$Compare + ' pid=' + $PID + ' toolRoot=' + $ToolRoot)

$registryState = Read-InstallRegistryState -ToolRoot $ToolRoot
if ([string]$registryState.State -eq 'corrupt') {
    Write-Host ('The install registry cannot be used: ' + $registryState.Reason) -ForegroundColor Red
    Write-FleetLog 'ERROR' 'FLEET' ('Registry unusable: ' + $registryState.Reason)
    exit 1
}
# Moved projects first: a record whose folder was renamed or moved is repaired
# (announced without -Apply) before evaluation, so it is judged at its new path
# instead of reported unreachable for ever. The folder is proven by the record
# ids its runtime metadata carries; ambiguous or not found changes nothing.
if ($evaluate) {
    $relocationRows = @(Invoke-FleetRelocations -ToolRoot $ToolRoot -ConfigPath $(if ($ConfigPath -ne '') { $ConfigPath } else { Join-Path $ToolRoot 'sync-hooks.json' }) `
            -InstallScript $InstallScript -UninstallScript (Join-Path $ScriptRoot 'Uninstall-Hook.ps1') -Apply:$Apply -OnlyProject $OnlyProject `
            -Log { param($Level, $Message) Write-FleetLog $Level 'RELOCATE' $Message })
    foreach ($line in @(Format-FleetRelocationLines -Rows $relocationRows)) { Write-Host $line; Write-FleetLog 'INFO' 'RELOCATE' $line }
}
$records = @(@((Read-InstallRegistry -ToolRoot $ToolRoot).installs) | Where-Object {
        $null -ne $_ -and (Test-IsManagedRecord $_) -and (Test-FleetProjectSelected -Record $_ -OnlyProject $OnlyProject) })
if ($OnlyProject -ne '' -and $records.Count -eq 0) {
    Write-Host ('No tracked registration belongs to -OnlyProject ' + $OnlyProject) -ForegroundColor Red
    Write-FleetLog 'ERROR' 'FLEET' ('-OnlyProject matched nothing: ' + $OnlyProject)
    exit 1
}

$failed = 0
if ($evaluate) {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $plan = @(Get-UpdateEvaluationPlan -Records $records -ToolRoot $ToolRoot)
    $registrations = @(Get-FleetRegistrations -Plan $plan -Markers $markers)
    Write-FleetLog 'INFO' 'EVAL' ('Evaluated ' + $records.Count + ' record(s) into ' + $registrations.Count + ' registration(s) in ' + $timer.Elapsed.TotalSeconds.ToString('N1') + 's')

    $counts = [ordered]@{ 'current' = 0; 'stale' = 0; 'pending-migration' = 0; 'unreachable' = 0; 'skipped' = 0 }
    foreach ($registration in $registrations) { $counts[$registration.State]++ }
    $countLine = (@($counts.Keys | ForEach-Object { $_ + '=' + $counts[$_] }) -join ' ')
    Write-FleetLog 'INFO' 'EVAL' ('Counts: ' + $countLine)

    $updated = 0
    foreach ($registration in $registrations) {
        $label = Get-RegistrationLabel $registration
        switch ($registration.State) {
            'current' { Write-FleetLog 'INFO' 'FLEET' ('ok | ' + $label) }
            'unreachable' { Write-FleetLog 'INFO' 'FLEET' ('unreachable | ' + $label + ' | ' + $registration.Detail) }
            'skipped' { Write-FleetLog 'WARNING' 'FLEET' ('skipped | ' + $label + ' | ' + $registration.Detail) }
            default {
                if (-not $Apply) {
                    Write-FleetLog 'INFO' 'FLEET' ($registration.State + ' | ' + $label + ' | ' + $registration.Detail)
                    continue
                }
                $reason = ''
                try { $reason = Invoke-FleetRepair -Registration $registration -Markers $markers }
                catch { $reason = $_.Exception.Message }
                if ($reason -eq '') {
                    $updated++
                    Write-FleetLog 'INFO' 'APPLY' ('updated | ' + $label)
                    Write-Host ('  updated  ' + $label)
                }
                else {
                    $failed++
                    Write-FleetLog 'ERROR' 'APPLY' ('failed ' + $reason + ' | ' + $label)
                    Write-Host ('  FAILED   ' + $label + ': ' + $reason) -ForegroundColor Red
                }
            }
        }
    }

    Write-Host ''
    Write-Host ('Update-Fleet (' + $mode + '): ' + $registrations.Count + ' registration(s) in ' + $records.Count + ' record(s)')
    foreach ($key in $counts.Keys) { Write-Host (('  {0,-18}: {1}' -f $key, $counts[$key])) }
    if ($Apply) {
        Write-Host (('  {0,-18}: {1}' -f 'updated now', $updated))
        Write-Host (('  {0,-18}: {1}' -f 'failed', $failed))
    }
    else {
        $pending = @($registrations | Where-Object { $_.State -eq 'stale' -or $_.State -eq 'pending-migration' })
        foreach ($registration in ($pending | Select-Object -First 40)) {
            Write-Host ('    ' + (Get-RegistrationLabel $registration) + ' [' + $registration.State + '] ' + $registration.Detail)
        }
        if ($pending.Count -gt 40) { Write-Host ('    ... and ' + ($pending.Count - 40) + ' more (see the log)') }
    }
    Write-Host ('COUNTS ' + $countLine)
    Write-FleetLog 'INFO' 'FLEET' ('Evaluation phase done: updated=' + $updated + ' failed=' + $failed)
}

$mismatched = 0
if ($Compare) {
    # After -Apply the records changed on disk; read them again.
    if ($Apply) {
        $records = @(@((Read-InstallRegistry -ToolRoot $ToolRoot).installs) | Where-Object {
                $null -ne $_ -and (Test-IsManagedRecord $_) -and (Test-FleetProjectSelected -Record $_ -OnlyProject $OnlyProject) })
    }
    $comparison = Invoke-FleetCompare -Records $records -ToolRoot $ToolRoot
    Write-Host ''
    Write-Host 'Content compare (installed runtime vs source):'
    foreach ($row in @($comparison.Projects)) {
        if ($row.Missing -eq 0 -and $row.Different -eq 0 -and $row.Errors -eq 0) { continue }
        Write-Host (('  {0}: missing={1} different={2} errors={3}' -f $row.Project, $row.Missing, $row.Different, $row.Errors))
        Write-FleetLog 'WARNING' 'COMPARE' (('{0}: files={1} missing={2} different={3} errors={4}' -f $row.Project, $row.Files, $row.Missing, $row.Different, $row.Errors))
    }
    $t = $comparison.Totals
    $compareLine = ('COMPARE projects={0} registrations={1} files={2} missing={3} different={4} errors={5} unreachable={6}' -f
        @($comparison.Projects).Count, $t.Registrations, $t.Files, $t.Missing, $t.Different, $t.Errors, $t.Unreachable)
    Write-Host $compareLine
    Write-FleetLog 'INFO' 'COMPARE' $compareLine
    $mismatched = $t.Mismatched
}

if ($null -ne $script:FleetLogPath) { Write-Host ('Log: ' + $script:FleetLogPath) }
Write-FleetLog 'INFO' 'FLEET' ('Update-Fleet finished: failed=' + $failed + ' mismatched=' + $mismatched)
exit ($failed + $mismatched)
