# Offline test suite for the Kiro CONTRACTS that span more than one module:
# the client/event capability table (scripts\_clientcapability.ps1), the
# registration writer (scripts\_installkiro.ps1) and the shared output adapter
# (hooks\_hooklib.ps1).
#
# Test-InstallKiro.ps1 already covers the writer's own unit behaviour (schema,
# rejections, path shapes, merge) and Test-ContextHooks.ps1 covers
# Write-HookResult through real child hook processes. This suite deliberately
# does NOT repeat either; it covers what neither reaches:
#
#   * EVERY logical event, exhaustively. For each one Kiro must either map it
#     to a documented physical trigger or NAME it unsupported - never a silent
#     drop, never a remap onto Stop. The capability table had no test at all.
#   * The SINGLE-trigger document, where `hooks` must still be a JSON array.
#     That is the exact case _installkiro's `return ,$value` comma wrapper
#     exists for, and the one a two-trigger fixture cannot reach.
#   * Write-HookResult for kiro across all twelve logical events in ONE pass,
#     so a downgrade that fakes a gate is caught on every event rather than on
#     the three spot-checked elsewhere.
#   * Entry-identity FORGERY: a name that merely contains the managed id, an id
#     not terminated by the anchor dash, another installation's marker, and an
#     entry with no identity fields at all (a StrictMode crash risk).
#   * A foreign entry surviving a real WRITE - Merge -> ConvertTo-KiroHookJson
#     -> disk -> re-parse. In-memory preservation is already proven; this is
#     the link a serializer -Depth regression would break, and the one that
#     would silently destroy a user's nested agent action.
#
# Everything runs in-process against isolated temp roots. USERPROFILE / HOME /
# CLAUDE_PROJECT_DIR / HOOKMAKER_CLIENT are redirected for the whole run and
# restored in the finally block, so no real user profile, real .kiro directory
# or real hooks tree is ever read or written.
#
# In-process is also what keeps the output assertions stable: pwsh 7 randomises
# plain-hashtable key order PER PROCESS, so comparing emitted JSON across a
# process boundary flakes. Every byte comparison here happens under one seed.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-KiroIntegration.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$KiroModule = Join-Path $ScriptRoot '_installkiro.ps1'
$CapabilityModule = Join-Path $ScriptRoot '_clientcapability.ps1'
$HookLib = Join-Path $ToolRoot 'hooks\_hooklib.ps1'
foreach ($required in @($KiroModule, $CapabilityModule, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
. $KiroModule    # dot-sources _clientcapability.ps1 itself
. $HookLib

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-kirointeg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
function Read-Utf8 { param([string]$Path) return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function Compact { param($Value) return ($Value | ConvertTo-Json -Depth 20 -Compress) }
function Get-Rejection { param([scriptblock]$Action) try { & $Action; return '' } catch { return [string]$_.Exception.Message } }

# Runs Write-HookResult with stdout AND stderr captured inside THIS process.
# Both channels matter: kiro puts advisory/context text on stdout and a real
# block's reason on stderr, and "nothing was emitted anywhere" is itself an
# assertable outcome for a degraded Stop gate.
function Invoke-KiroResult {
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Client = 'kiro'
    )
    $outWriter = New-Object System.IO.StringWriter
    $errWriter = New-Object System.IO.StringWriter
    $previousOut = [Console]::Out
    $previousError = [Console]::Error
    $outcome = $null
    try {
        [Console]::SetOut($outWriter)
        [Console]::SetError($errWriter)
        $outcome = Write-HookResult -EventName $EventName -Kind $Kind -Message $Text -Reason $Text -Client $Client
    }
    finally {
        [Console]::SetOut($previousOut)
        [Console]::SetError($previousError)
    }
    return [pscustomobject]@{
        Out            = $outWriter.ToString().Trim()
        Err            = $errWriter.ToString().Trim()
        Emitted        = [bool]$outcome.Emitted
        Shape          = [string]$outcome.Shape
        ExitCode       = [int]$outcome.ExitCode
        Degraded       = [bool]$outcome.Degraded
        DegradedReason = [string]$outcome.DegradedReason
    }
}

$SavedUserProfile = $env:USERPROFILE
$SavedHome = $env:HOME
$SavedClaudeProjectDir = $env:CLAUDE_PROJECT_DIR
$SavedHookMakerClient = $env:HOOKMAKER_CLIENT

try {
    $managedId = 'a1b2c3d4e5'
    $otherId = 'f9f9f9f9'
    $command = 'pwsh -NoLogo -NoProfile -File "C:\Proj\.kiro\hook-runtime\Hook-Maker\X\X.ps1" -Trigger Stop'

    # A hook must never inherit an ambient client signal from the machine that
    # happens to be running the suite.
    if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
    if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }

    $capability = Get-HookMakerClientCapability -ClientId 'kiro'
    $logicalEvents = @(Get-HookMakerLogicalEvents)
    $supportedEvents = @($capability.supportedEvents)
    # The ten triggers .ai\KIRO_PROTOCOL.md marks CONFIRMED, exact casing. A
    # physical name outside this set is a name Kiro never documented.
    $protocolTriggers = @(
        'SessionStart', 'Stop', 'PreToolUse', 'PostToolUse', 'PreTaskExec', 'PostTaskExec',
        'UserPromptSubmit', 'PostFileCreate', 'PostFileSave', 'PostFileDelete'
    )

    # =====================================================================
    Write-Host '--- capability table: the supported set is exactly the five Kiro documents ---' -ForegroundColor Cyan

    Check 'the capability table lists exactly the five documented Kiro events' (
        ((@($supportedEvents) | Sort-Object) -join ',') -ceq 'PostToolUse,PreToolUse,SessionStart,Stop,UserPromptSubmit') (
        (@($supportedEvents) -join ','))
    Check 'every supported event is a real Hook Maker logical event' (
        @($supportedEvents | Where-Object { $null -eq (Resolve-HookMakerLogicalEvent -Name $_) }).Count -eq 0) (
        (@($supportedEvents) -join ','))

    # Nested Where-Object would shadow $_, so the map is walked with an explicit
    # loop and each violation is collected by name for the failure preview.
    $mapKeys = @($capability.physicalEventMap.Keys)
    $unmapped = @()
    $mappedButUnsupported = @()
    $undocumentedPhysical = @()
    $stopRemaps = @()
    foreach ($supportedEvent in $supportedEvents) {
        if (-not $capability.physicalEventMap.ContainsKey($supportedEvent)) { $unmapped += $supportedEvent }
    }
    foreach ($mapKey in $mapKeys) {
        $physicalName = [string]$capability.physicalEventMap[$mapKey]
        if (@($supportedEvents | Where-Object { $_ -ceq $mapKey }).Count -eq 0) { $mappedButUnsupported += $mapKey }
        if (@($protocolTriggers | Where-Object { $_ -ceq $physicalName }).Count -eq 0) {
            $undocumentedPhysical += ($mapKey + '->' + $physicalName)
        }
        if ($physicalName -ceq 'Stop' -and $mapKey -cne 'Stop') { $stopRemaps += ($mapKey + '->' + $physicalName) }
    }
    Check 'every supported event has an explicit physical mapping (the table never leans on an implicit identity)' (
        $unmapped.Count -eq 0) ('unmapped: ' + ($unmapped -join ','))
    Check 'the physical map never maps an event Kiro does not support' (
        $mappedButUnsupported.Count -eq 0) ('mapped but unsupported: ' + ($mappedButUnsupported -join ','))
    Check 'every physical trigger is one the protocol confirms, in exact casing' (
        $undocumentedPhysical.Count -eq 0) ('undocumented: ' + ($undocumentedPhysical -join ','))
    Check 'only Stop maps to the Stop trigger - nothing else is remapped onto it' (
        $stopRemaps.Count -eq 0) ('remapped onto Stop: ' + ($stopRemaps -join ','))

    Check 'every block-capable Kiro event is also a SUPPORTED event' (
        @($capability.blockCapableEvents | Where-Object { @($supportedEvents) -notcontains $_ }).Count -eq 0) (
        (@($capability.blockCapableEvents) -join ','))
    Check 'Stop is absent from the Kiro block-capable set' (
        @($capability.blockCapableEvents | Where-Object { $_ -ceq 'Stop' }).Count -eq 0) (
        (@($capability.blockCapableEvents) -join ','))

    Check 'Kiro is the perHookFile client; Claude and Codex stay sharedSettingsFile' (
        [string]$capability.registrationKind -ceq 'perHookFile' -and
        [string](Get-HookMakerClientCapability -ClientId 'claude').registrationKind -ceq 'sharedSettingsFile' -and
        [string](Get-HookMakerClientCapability -ClientId 'codex').registrationKind -ceq 'sharedSettingsFile') (
        [string]$capability.registrationKind)
    # The load-bearing separation, asserted from the TABLE rather than from a
    # composed path: .kiro\hooks is Kiro's hook-config discovery root, so a
    # runtime tree rooted inside it would be scanned as configuration.
    Check 'the runtime root is not inside the registration root (Kiro would scan a .ps1 tree there as config)' (
        -not ([string]$capability.runtimeRelativeRoot).StartsWith([string]$capability.projectRegistration + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
        -not ([string]$capability.runtimeRelativeRoot).StartsWith([string]$capability.globalRegistration + '\', [System.StringComparison]::OrdinalIgnoreCase)) (
        [string]$capability.runtimeRelativeRoot)

    Check "the legacy 'Both' selection still means Claude + Codex and never installs Kiro" (
        ((Resolve-HookMakerClientSet -Value 'Both') -join ',') -eq 'claude,codex') (
        ((Resolve-HookMakerClientSet -Value 'Both') -join ','))
    Check "'All' is the selection that includes Kiro" (
        @(Resolve-HookMakerClientSet -Value 'All') -contains 'kiro') (
        ((Resolve-HookMakerClientSet -Value 'All') -join ','))

    # =====================================================================
    Write-Host '--- every logical event is mapped or NAMED unsupported: never dropped, never remapped ---' -ForegroundColor Cyan

    foreach ($logical in $logicalEvents) {
        $isSupported = (@($supportedEvents | Where-Object { $_ -ceq $logical }).Count -gt 0)
        $document = $null
        $rejection = ''
        try {
            $document = New-KiroHookDocument -FriendlyName 'Cap Probe' -Command $command `
                -Triggers @($logical) -TimeoutSeconds 30 -ManagedId $managedId
        }
        catch { $rejection = [string]$_.Exception.Message }

        if ($isSupported) {
            $entries = @()
            if ($null -ne $document) { $entries = @($document.hooks) }
            $physical = [string]$capability.physicalEventMap[$logical]
            Check ($logical + ': maps to the physical trigger the table names, exact casing') (
                $entries.Count -eq 1 -and [string]$entries[0].trigger -ceq $physical) ($rejection + (Compact $document))
            Check ($logical + ': is never remapped onto Stop') (
                $entries.Count -eq 1 -and (([string]$entries[0].trigger -ceq 'Stop') -eq ($logical -ceq 'Stop'))) (
                $rejection + (Compact $document))
            # The single-trigger case: `hooks` must STILL be an array, both as
            # a live object and in the JSON that reaches disk.
            $singleJson = ''
            if ($null -ne $document) { $singleJson = ConvertTo-KiroHookJson -Document $document }
            $singleReparsed = $null
            if ($singleJson -ne '') { $singleReparsed = ($singleJson | ConvertFrom-Json) }
            Check ($logical + ': a ONE-trigger document still serialises hooks as an array') (
                $null -ne $singleReparsed -and $singleReparsed.hooks -is [System.Array] -and
                @($singleReparsed.hooks).Count -eq 1 -and $singleJson -match '"hooks"\s*:\s*\[') $singleJson
        }
        else {
            Check ($logical + ': is rejected BY NAME, never silently dropped') (
                $null -eq $document -and $rejection -match 'trigger-unsupported-by-kiro' -and
                $rejection -match [regex]::Escape($logical)) $rejection
            Check ($logical + ': the rejection states it is never remapped onto Stop') (
                $rejection -match 'never remapped onto Stop') $rejection
        }
    }

    # =====================================================================
    Write-Host '--- the event PLAN reports a degraded install rather than a partial success ---' -ForegroundColor Cyan

    $fullPlan = Resolve-HookMakerEventPlan -Events $logicalEvents -ClientIds @('kiro')
    $kiroPlan = @($fullPlan.perClient)[0]
    Check 'a plan holding an unsupported event is reported DEGRADED, not ok' ([bool]$fullPlan.degraded) (
        [string]$fullPlan.degraded)
    Check 'the plan supports exactly the five documented events' (
        ((@($kiroPlan.supported) | Sort-Object) -join ',') -ceq 'PostToolUse,PreToolUse,SessionStart,Stop,UserPromptSubmit') (
        (@($kiroPlan.supported) -join ','))
    Check 'every requested event is accounted for - none vanishes between supported and unsupported' (
        (@($kiroPlan.supported).Count + @($kiroPlan.unsupported).Count) -eq $logicalEvents.Count) (
        'supported=' + @($kiroPlan.supported).Count + ' unsupported=' + @($kiroPlan.unsupported).Count + ' input=' + $logicalEvents.Count)
    Check 'the seven undocumented events are all named in the unsupported list' (
        @($logicalEvents | Where-Object { @($supportedEvents) -notcontains $_ } |
            Where-Object { @($kiroPlan.unsupported) -notcontains $_ }).Count -eq 0) (
        (@($kiroPlan.unsupported) -join ','))
    Check 'the plan carries one logical->physical pair per supported event and never a Stop remap' (
        @($kiroPlan.physical).Count -eq @($kiroPlan.supported).Count -and
        @($kiroPlan.physical | Where-Object { [string]$_.physical -ceq 'Stop' -and [string]$_.logical -cne 'Stop' }).Count -eq 0) (
        (@($kiroPlan.physical | ForEach-Object { [string]$_.logical + '->' + [string]$_.physical }) -join ','))

    $okPlan = Resolve-HookMakerEventPlan -Events @('SessionStart', 'PreToolUse', 'Stop') -ClientIds @('kiro')
    Check 'a plan of only supported events is NOT degraded' (-not [bool]$okPlan.degraded) ([string]$okPlan.degraded)
    $mixedPlan = Resolve-HookMakerEventPlan -Events @('SessionStart', 'PreCompact') -ClientIds @('kiro')
    Check 'one unsupported event is enough to degrade the whole plan' ([bool]$mixedPlan.degraded) (
        [string]$mixedPlan.degraded)

    # =====================================================================
    Write-Host '--- Write-HookResult: a block Kiro cannot enforce is downgraded on EVERY event ---' -ForegroundColor Cyan

    Check 'Test-HookMakerEventBlocking says Kiro Stop CANNOT block' (
        -not (Test-HookMakerEventBlocking -ClientId 'kiro' -EventName 'Stop')) 'Stop'

    foreach ($logical in $logicalEvents) {
        $blockable = Test-HookMakerEventBlocking -ClientId 'kiro' -EventName $logical
        $result = Invoke-KiroResult -EventName $logical -Kind 'block' -Text ('GATE-' + $logical)
        if ($blockable) {
            Check ('block on Kiro ' + $logical + ': a REAL gate - exit 2, reason on stderr, not degraded') (
                $result.Emitted -and $result.Shape -eq 'kiroExit2Stderr' -and $result.ExitCode -eq 2 -and
                -not $result.Degraded -and $result.Err -match ('GATE-' + $logical) -and $result.Out -eq '') (
                'out=[' + $result.Out + '] err=[' + $result.Err + '] shape=' + $result.Shape)
        }
        else {
            # The property is "never a FAKE gate", not "silent". Kiro discards
            # stdout off its two context triggers, but a non-zero exit other
            # than 2 surfaces stderr as a warning - so a downgraded gate now
            # tells the user why it did not hold instead of vanishing. What must
            # never happen is it being mistaken for enforcement: that is exit 2
            # / kiroExit2Stderr, which is still asserted against.
            Check ('block on Kiro ' + $logical + ': downgraded and REPORTED, never a fake gate') (
                $result.ExitCode -ne 2 -and $result.Shape -ne 'kiroExit2Stderr' -and
                $result.Out -notmatch '"?decision"?\s*:' -and
                $result.Degraded -and $result.DegradedReason -match 'NOT an enforced gate') (
                'out=[' + $result.Out + '] err=[' + $result.Err + '] reason=' + $result.DegradedReason)
        }
    }

    $stopBlock = Invoke-KiroResult -EventName 'Stop' -Kind 'block' -Text 'STOP-GATE-TEXT'
    # This asserted total silence, which is what let the message-dropping defect
    # ship: Kiro discards stdout on Stop, but stderr with a non-2 exit reaches
    # the user. A failed gate that says nothing is worse than one that explains
    # itself. Both degradations are still required to be reported.
    Check 'a Kiro Stop block warns on stderr and reports BOTH degradations' (
        $stopBlock.Out -eq '' -and $stopBlock.Err -match 'STOP-GATE-TEXT' -and
        $stopBlock.Shape -eq 'kiroStderrWarning' -and
        $stopBlock.DegradedReason -match 'no block mechanism on Stop' -and
        $stopBlock.DegradedReason -match 'discards hook stdout') (
        'out=[' + $stopBlock.Out + '] err=[' + $stopBlock.Err + '] reason=' + $stopBlock.DegradedReason)
    # THE safety line: Stop is not block-capable on either Kiro surface, so this
    # must never carry Kiro's refusal code however it is surfaced.
    Check 'a Kiro Stop block never exits with Kiro''s refusal code' (
        $stopBlock.ExitCode -ne 2) ([string]$stopBlock.ExitCode)

    # =====================================================================
    Write-Host '--- Write-HookResult: Kiro context lands only where the protocol documents it ---' -ForegroundColor Cyan

    $wronglyEmitted = @()
    $wronglySilent = @()
    $wrongShape = @()
    $unreported = @()
    foreach ($logical in $logicalEvents) {
        $result = Invoke-KiroResult -EventName $logical -Kind 'context' -Text ('CTX-' + $logical)
        $shouldEmit = ($logical -ceq 'SessionStart' -or $logical -ceq 'UserPromptSubmit')
        # "Emitted" now means "reached the user somehow", and off the two context
        # triggers that is the stderr warning channel. What distinguishes the
        # two cases is the CHANNEL, not whether anything came out: only
        # SessionStart/UserPromptSubmit put text on STDOUT, which is the only
        # thing Kiro injects into model context.
        if ($result.Out -ne '' -and -not $shouldEmit) { $wronglyEmitted += $logical }
        if ($result.Out -eq '' -and $shouldEmit) { $wronglySilent += $logical }
        if ($shouldEmit) {
            # Plain stdout + exit 0. Never a Claude/Codex JSON envelope: Kiro
            # reads stdout as literal context, so an envelope would be shown to
            # the model as raw JSON.
            if ($result.Shape -ne 'kiroStdout' -or $result.Out -cne ('CTX-' + $logical) -or
                $result.Out -match 'hookSpecificOutput' -or $result.Out -match 'systemMessage' -or
                $result.ExitCode -ne 0 -or $result.Degraded) {
                $wrongShape += ($logical + '=[' + $result.Out + ']/' + $result.Shape)
            }
        }
        # Off those triggers the text must still be REPORTED as degraded and go
        # to stderr, never to stdout - and never with the refusal code.
        elseif (-not ($result.Out -eq '' -and $result.Err -match ('CTX-' + $logical) -and
                $result.ExitCode -ne 2 -and $result.Degraded -and
                $result.DegradedReason -match 'discards hook stdout')) {
            $unreported += ($logical + '=[' + $result.Out + ']/' + $result.DegradedReason)
        }
    }
    Check 'Kiro context is emitted on SessionStart and UserPromptSubmit' ($wronglySilent.Count -eq 0) (
        'silent on: ' + ($wronglySilent -join ','))
    Check 'Kiro context reaches STDOUT on NO other trigger' ($wronglyEmitted.Count -eq 0) (
        'wrongly emitted on: ' + ($wronglyEmitted -join ','))
    Check 'an emitted Kiro context is bare stdout, never a Claude/Codex JSON envelope' ($wrongShape.Count -eq 0) (
        ($wrongShape -join ' | '))
    Check 'a stdout-discarded Kiro context still reaches the user on stderr, reported as degraded' (
        $unreported.Count -eq 0) (($unreported -join ' | '))

    # =====================================================================
    Write-Host '--- client identity: explicit wins, unknown stays unknown, no-signal stays codex ---' -ForegroundColor Cyan

    $env:CLAUDE_PROJECT_DIR = Join-Path $Work 'ClaudeSignal'
    Check 'an explicit kiro id wins even with CLAUDE_PROJECT_DIR set' (
        (Get-HookClientId -Explicit 'kiro') -eq 'kiro') (Get-HookClientId -Explicit 'kiro')
    Check 'an unrecognised explicit id is unknown, never a confident guess' (
        (Get-HookClientId -Explicit 'gemini') -eq 'unknown') (Get-HookClientId -Explicit 'gemini')
    Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
    Check 'no signal at all still resolves to codex (the deliberate legacy default)' (
        (Get-HookClientId) -eq 'codex') (Get-HookClientId)
    Check 'an unknown client emits no output shape at all and says why' (
        (Invoke-KiroResult -EventName 'SessionStart' -Kind 'context' -Text 'X' -Client 'gemini').Out -eq '' -and
        (Invoke-KiroResult -EventName 'SessionStart' -Kind 'context' -Text 'X' -Client 'gemini').DegradedReason -match 'client is unknown') (
        (Invoke-KiroResult -EventName 'SessionStart' -Kind 'context' -Text 'X' -Client 'gemini').DegradedReason)

    # =====================================================================
    Write-Host '--- paths: derived from the capability table, isolated, and space-safe ---' -ForegroundColor Cyan

    # A root WITH A SPACE, because every real Windows install has one.
    $projectRoot = Join-Path $Work 'My Project'
    $fakeHome = Join-Path $Work 'Fake Home'
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
    $env:USERPROFILE = $fakeHome
    $env:HOME = $fakeHome

    $projectRegistration = Get-KiroRegistrationPath -Scope 'project' -FriendlyName 'Secrets Check' `
        -StableId 'A1B2C3D4E5F6G7' -TargetProjectRoot $projectRoot
    $globalRegistration = Get-KiroRegistrationPath -Scope 'global' -FriendlyName 'Secrets Check' -StableId 'A1B2C3D4E5F6G7'
    $projectRuntime = Get-KiroRuntimeRoot -Scope 'project' -TargetProjectRoot $projectRoot
    $globalRuntime = Get-KiroRuntimeRoot -Scope 'global'

    Check 'the project registration directory is exactly the capability table path under the project root' (
        (Split-Path -Parent $projectRegistration) -eq (Join-Path $projectRoot ([string]$capability.projectRegistration))) (
        $projectRegistration)
    Check 'the global registration directory is exactly the capability table path under the home root' (
        (Split-Path -Parent $globalRegistration) -eq (Join-Path $fakeHome ([string]$capability.globalRegistration))) (
        $globalRegistration)
    Check 'a project root containing a space produces a usable path, not a truncated one' (
        $projectRegistration.Contains('My Project') -and (Test-KiroManagedFileName -Path $projectRegistration)) (
        $projectRegistration)
    Check 'the global path follows the redirected home and never the real user profile' (
        $globalRegistration.StartsWith($fakeHome, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $globalRegistration.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) (
        $globalRegistration)
    Check 'the project runtime root is NOT inside the registration directory' (
        -not $projectRuntime.StartsWith((Split-Path -Parent $projectRegistration) + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
        $projectRuntime -eq (Join-Path $projectRoot ([string]$capability.runtimeRelativeRoot))) $projectRuntime
    Check 'the global runtime root is NOT inside the registration directory' (
        -not $globalRuntime.StartsWith((Split-Path -Parent $globalRegistration) + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
        $globalRuntime -eq (Join-Path $fakeHome ([string]$capability.runtimeRelativeRoot))) $globalRuntime
    Check 'neither registration path is a .hook or .kiro.hook file' (
        $projectRegistration.EndsWith('.json') -and $globalRegistration.EndsWith('.json') -and
        $projectRegistration -notmatch '\.kiro\.hook' -and $globalRegistration -notmatch '\.kiro\.hook') $projectRegistration
    Check 'a generic shared hooks.json name is refused as unmanaged' (
        -not (Test-KiroManagedFileName -Path (Join-Path (Split-Path -Parent $projectRegistration) 'hooks.json'))) 'hooks.json'

    # =====================================================================
    Write-Host '--- ownership identity cannot be FORGED by a lookalike name or marker ---' -ForegroundColor Cyan

    # The module anchors the id immediately after the fixed 'hookmaker-' prefix
    # and terminates it with a dash, so neither a longer id nor a name that
    # merely contains the id can claim ownership.
    $forgeries = @(
        @{ Why = 'a name that merely CONTAINS the managed id'; Name = 'not-hookmaker-a1b2c3d4e5-secrets-check-stop' },
        @{ Why = 'an id that is a PREFIX of a longer id'; Name = 'hookmaker-a1b2c3d4e5f0-secrets-check-stop' },
        @{ Why = 'the prefix without the managed id at all'; Name = 'hookmaker-secrets-check-stop' },
        @{ Why = "another installation's entry name"; Name = 'hookmaker-f9f9f9f9-secrets-check-stop' }
    )
    foreach ($forgery in $forgeries) {
        $entry = [pscustomobject]@{ name = [string]$forgery['Name']; description = 'no marker here' }
        Check ('forgery refused: ' + [string]$forgery['Why']) (
            -not (Test-KiroManagedEntry -Entry $entry -ManagedId $managedId)) ([string]$forgery['Name'])
    }
    Check 'our real entry name IS proven ours' (
        Test-KiroManagedEntry -Entry ([pscustomobject]@{ name = 'hookmaker-a1b2c3d4e5-secrets-check-stop' }) -ManagedId $managedId) 'name proof'
    Check 'the description marker alone also proves ownership, case-insensitively' (
        Test-KiroManagedEntry -Entry ([pscustomobject]@{ name = 'a-name-a-user-typed'; description = 'x [HOOKMAKER:A1B2C3D4E5] y' }) -ManagedId $managedId) 'marker proof'
    Check "another installation's marker never proves OUR ownership" (
        -not (Test-KiroManagedEntry -Entry ([pscustomobject]@{ name = 'x'; description = '[hookmaker:f9f9f9f9]' }) -ManagedId $managedId)) 'other marker'
    # A hand-assembled hashtable entry is a supported input shape; a parsed
    # entry missing both identity fields must be foreign rather than a
    # StrictMode property-not-found crash on somebody's hand-edited file.
    Check 'a hashtable entry is classified by the same identity rule as a parsed object' (
        (Test-KiroManagedEntry -Entry @{ name = 'hookmaker-a1b2c3d4e5-x-stop' } -ManagedId $managedId) -and
        -not (Test-KiroManagedEntry -Entry @{ name = 'someone-else' } -ManagedId $managedId)) 'hashtable entry'
    Check 'an entry with no name and no description is foreign, never a StrictMode crash' (
        -not (Test-KiroManagedEntry -Entry ([pscustomobject]@{ trigger = 'Stop' }) -ManagedId $managedId) -and
        -not (Test-KiroManagedEntry -Entry @{ trigger = 'Stop' } -ManagedId $managedId)) 'no identity fields'

    $hooksDir = Join-Path $projectRoot ([string]$capability.projectRegistration)
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    $forgedPath = Join-Path $hooksDir 'hookmaker-secrets-check-a1b2c3d4e5f6.json'
    Write-Utf8 -Path $forgedPath -Content ('{
  "version": "v1",
  "hooks": [
    { "name": "not-hookmaker-a1b2c3d4e5-x", "trigger": "Stop", "action": { "type": "command", "command": "theirs" } },
    { "name": "hookmaker-a1b2c3d4e5f0-y", "description": "[hookmaker:a1b2c3d4e5f0]", "trigger": "PreToolUse", "action": { "type": "command", "command": "also theirs" } }
  ]
}')
    $forgedCheck = Test-KiroManagedFile -Path $forgedPath -ManagedId $managedId
    Check 'a perfectly-named file whose entries only LOOK like ours is FOREIGN' (
        $forgedCheck.Reason -eq 'foreign' -and -not $forgedCheck.Ok -and
        @($forgedCheck.ManagedEntries).Count -eq 0 -and @($forgedCheck.ForeignEntries).Count -eq 2) (
        $forgedCheck.Reason + '/' + @($forgedCheck.ManagedEntries).Count + '/' + @($forgedCheck.ForeignEntries).Count)

    $forgedDocument = (Read-Utf8 -Path $forgedPath | ConvertFrom-Json)
    $forgedBefore = Compact $forgedDocument
    $newEntries = New-KiroHookDocument -FriendlyName 'Secrets Check' -Command $command -Triggers @('Stop') `
        -TimeoutSeconds 45 -ManagedId $managedId
    $refused = Merge-KiroManagedEntries -ExistingDocument $forgedDocument -ManagedEntries @($newEntries.hooks) -ManagedId $managedId
    Check 'unproven ownership returns not-Ok with no document to write' (
        -not $refused.Ok -and $refused.Reason -eq 'foreign' -and $null -eq $refused.Document) ([string]$refused.Reason)
    Check 'a refused merge mutates nothing in memory' ((Compact $forgedDocument) -ceq $forgedBefore) (Compact $forgedDocument)
    Check 'a refused merge leaves the file on disk byte-identical' ((Read-Utf8 -Path $forgedPath) -match 'also theirs') $forgedPath

    # =====================================================================
    Write-Host '--- a foreign entry survives a REAL write: merge -> serialize -> disk -> re-parse ---' -ForegroundColor Cyan

    # In-memory preservation is proven elsewhere. This proves the whole chain,
    # which is where a serializer -Depth regression would silently flatten a
    # user's nested action into the string "System.Management.Automation.PSCustomObject".
    $mixedPath = Join-Path $hooksDir 'hookmaker-roundtrip-abcdef123456.json'
    Write-Utf8 -Path $mixedPath -Content ('{
  "version": "v1",
  "hooks": [
    { "name": "user-lint", "description": "mine", "trigger": "PostFileSave", "matcher": "\\.ts$", "action": { "type": "command", "command": "npm run lint" }, "timeout": 15, "enabled": false },
    { "name": "hookmaker-a1b2c3d4e5-roundtrip-stop", "description": "old text [hookmaker:a1b2c3d4e5]", "trigger": "Stop", "action": { "type": "command", "command": "OLD-COMMAND" }, "timeout": 10, "enabled": true },
    { "name": "user-review", "description": "also mine", "trigger": "PostTaskExec", "action": { "type": "agent", "prompt": "review the diff" }, "enabled": true }
  ]
}')
    $beforeDocument = (Read-Utf8 -Path $mixedPath | ConvertFrom-Json)
    $beforeEntries = @($beforeDocument.hooks)
    $foreignBefore = @((Compact $beforeEntries[0]), (Compact $beforeEntries[2]))

    $replacement = New-KiroHookDocument -FriendlyName 'Roundtrip' -Command 'NEW-COMMAND' -Triggers @('Stop') `
        -TimeoutSeconds 90 -ManagedId $managedId
    $mergeResult = Merge-KiroManagedEntries -ExistingDocument $beforeDocument -ManagedEntries @($replacement.hooks) -ManagedId $managedId
    Check 'the mixed managed file merges rather than being refused' ($mergeResult.Ok -and $mergeResult.Reason -eq 'merged') (
        [string]$mergeResult.Reason)

    Write-Utf8 -Path $mixedPath -Content (ConvertTo-KiroHookJson -Document $mergeResult.Document)
    $afterDocument = (Read-Utf8 -Path $mixedPath | ConvertFrom-Json)
    $afterEntries = @($afterDocument.hooks)

    Check 'the written document still holds all three entries in their original order' (
        $afterEntries.Count -eq 3 -and [string]$afterEntries[0].name -eq 'user-lint' -and
        [string]$afterEntries[1].name -eq 'hookmaker-a1b2c3d4e5-roundtrip-stop' -and
        [string]$afterEntries[2].name -eq 'user-review') (Compact $afterDocument)
    Check 'foreign entry 1 is byte-identical after the disk round trip' (
        (Compact $afterEntries[0]) -ceq $foreignBefore[0]) (Compact $afterEntries[0])
    Check 'foreign entry 2 is byte-identical after the disk round trip' (
        (Compact $afterEntries[2]) -ceq $foreignBefore[1]) (Compact $afterEntries[2])
    Check 'the foreign disabled state, matcher, command and timeout all survive the write' (
        [bool]$afterEntries[0].enabled -eq $false -and [string]$afterEntries[0].matcher -ceq '\.ts$' -and
        [string]$afterEntries[0].action.command -ceq 'npm run lint' -and [int]$afterEntries[0].timeout -eq 15) (
        Compact $afterEntries[0])
    Check 'the foreign nested agent action survives serialization instead of being flattened' (
        [string]$afterEntries[2].action.type -ceq 'agent' -and
        [string]$afterEntries[2].action.prompt -ceq 'review the diff' -and
        (Read-Utf8 -Path $mixedPath) -notmatch 'System\.Management\.Automation\.PSCustomObject') (
        Compact $afterEntries[2])
    Check 'our own entry IS updated in place, with the new command and timeout' (
        [string]$afterEntries[1].action.command -ceq 'NEW-COMMAND' -and [int]$afterEntries[1].timeout -eq 90) (
        Compact $afterEntries[1])
    Check 'the written document is still proven ours and still reports both foreign entries' (
        (Test-KiroManagedFile -Path $mixedPath -ManagedId $managedId).Ok -and
        @((Test-KiroManagedFile -Path $mixedPath -ManagedId $managedId).ForeignEntries).Count -eq 2) (
        (Test-KiroManagedFile -Path $mixedPath -ManagedId $managedId).Reason)

    $bytes = [System.IO.File]::ReadAllBytes($mixedPath)
    Check 'the written document carries no UTF-8 BOM' (
        -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'bom'
    Check 'no .hook or .kiro.hook file was produced anywhere in the workspace' (
        @(Get-ChildItem -LiteralPath $Work -Recurse -Force -File | Where-Object { $_.Name -match '\.hook$' }).Count -eq 0) $Work

    # ---- Install-Hook.ps1 wiring ------------------------------------------
    # Everything above proves the MODULE. These prove the module is actually
    # reached: before this wiring existed the installer recorded kiro as a
    # failed component and wrote nothing at all, and every test above still
    # passed. Assertions here are on observable end state - files, command
    # lines and a real launcher execution - not on status strings.
    Write-Host ''
    Write-Host '--- Install-Hook.ps1: Kiro is actually installed, not just modelled ---' -ForegroundColor Cyan

    $InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
    $SavedStateDir = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = Join-Path $Work 'wiring-state'
    $realHook = Join-Path $ToolRoot 'hooks\Rules-Check\Rules-Check.ps1'
    try {
        $wireProject = Join-Path $Work 'Wire Project'
        New-Item -ItemType Directory -Path $wireProject -Force | Out-Null
        $wireResult = Join-Path $Work 'wire-result.json'
        # PreCompact is deliberate: Kiro documents no trigger for it, so it must
        # be REPORTED, never dropped in silence and never remapped onto Stop.
        & $InstallScript -CustomHook $realHook -TargetProject $wireProject `
            -Clients kiro -Events SessionStart, Stop, PreToolUse, PreCompact -ResultPath $wireResult | Out-Null

        $wireHooksDir = Join-Path $wireProject '.kiro\hooks'
        $registered = @(Get-ChildItem -LiteralPath $wireHooksDir -Filter 'hookmaker-*.json' -File -ErrorAction SilentlyContinue)
        Check 'installing for kiro writes exactly one managed registration file' (
            $registered.Count -eq 1) ("count=" + $registered.Count)

        $wireDocument = $null
        if ($registered.Count -eq 1) { $wireDocument = ((Read-Utf8 -Path $registered[0].FullName | ConvertFrom-Json)) }
        $wireEntries = @()
        if ($null -ne $wireDocument) { $wireEntries = @($wireDocument.hooks) }
        Check 'only the three Kiro-supported triggers are registered, and PreCompact is not among them' (
            $wireEntries.Count -eq 3 -and
            @($wireEntries | Where-Object { [string]$_.trigger -ceq 'PreCompact' }).Count -eq 0) (
            (@($wireEntries | ForEach-Object { [string]$_.trigger }) -join ','))
        Check 'the unsupported event was NOT silently remapped onto a supported trigger' (
            @($wireEntries | ForEach-Object { [string]$_.trigger } | Sort-Object -Unique).Count -eq 3) (
            (@($wireEntries | ForEach-Object { [string]$_.trigger }) -join ','))

        # The whole reason the launcher exists: Kiro IDE documents no stdin
        # JSON, so an entry whose command omits -Trigger leaves the hook unable
        # to tell which event fired. One shared command line for three entries
        # is the exact defect this asserts against.
        $triggerArguments = @($wireEntries | ForEach-Object {
                if ([string]$_.action.command -match '-Trigger\s+(\w+)\s*$') { $Matches[1] } else { 'MISSING' }
            })
        Check 'every registered entry carries its OWN -Trigger matching its trigger' (
            @($wireEntries | Where-Object {
                    [string]$_.action.command -match ('-Trigger\s+' + [regex]::Escape([string]$_.trigger) + '\s*$')
                }).Count -eq 3) ($triggerArguments -join ',')

        $wireLauncher = Join-Path $wireProject '.kiro\hook-runtime\Hook-Maker\Rules-Check\kiro-launch.ps1'
        Check 'the generated launcher exists in the Kiro runtime root' (Test-Path -LiteralPath $wireLauncher -PathType Leaf) $wireLauncher
        Check 'the Kiro runtime is NOT written under .kiro\hooks, which Kiro scans as config' (
            @(Get-ChildItem -LiteralPath $wireHooksDir -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0) $wireHooksDir

        # Executes the launcher for real. Identity travels in the environment
        # because only 2 of the shipped hooks accept a -Client parameter, so an
        # argument would break the other 21 - this proves the env route works
        # and that the trailing hook arguments still arrive intact.
        $probeTarget = Join-Path $wireProject '.kiro\hook-runtime\Hook-Maker\Rules-Check\Rules-Check.ps1'
        $savedProbe = Read-Utf8 -Path $probeTarget
        Write-Utf8 -Path $probeTarget -Content 'Write-Host ("client=" + $env:HOOKMAKER_CLIENT + ";trigger=" + $env:HOOKMAKER_KIRO_TRIGGER + ";args=" + ($args -join " "))'
        $launcherOutput = (& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $wireLauncher -Trigger PreToolUse -ConfigPath 'C:\x.json' 2>&1 | Out-String).Trim()
        Write-Utf8 -Path $probeTarget -Content $savedProbe
        Check 'the launcher gives the hook a kiro identity Kiro itself never supplies' (
            $launcherOutput -match 'client=kiro') $launcherOutput
        Check 'the launcher passes the physical trigger through to the hook' (
            $launcherOutput -match 'trigger=PreToolUse') $launcherOutput
        Check 'the launcher forwards the remaining hook arguments untouched' (
            $launcherOutput -match '-ConfigPath C:\\x\.json') $launcherOutput

        $wireRecordJson = ''
        $wireRegistryFile = Join-Path $env:HOOKMAKER_STATE_DIR 'install-registry.json'
        if (Test-Path -LiteralPath $wireRegistryFile -PathType Leaf) { $wireRecordJson = Read-Utf8 -Path $wireRegistryFile }
        Check 'the install record carries the per-hook-file fields uninstall needs to prove ownership' (
            $wireRecordJson -match '"registrationKind"\s*:\s*"perHookFile"' -and
            $wireRecordJson -match '"managedEntryNames"' -and
            $wireRecordJson -match '"degradedReasons"') ('len=' + $wireRecordJson.Length)
        Check 'the permanently non-blocking Kiro Stop is recorded as degraded, not sold as a gate' (
            $wireRecordJson -match 'degraded-stop-gate') ('len=' + $wireRecordJson.Length)

        # This install dropped PreCompact and installed a Stop that can only ever
        # advise, so calling the whole run 'ok' overstates what landed. The
        # degradation is deliberately NOT expressed as a component status:
        # component statuses are exactly ok/failed/skipped/trackingFailed and
        # 'partial' is the OVERALL vocabulary, so the reason code is what the
        # overall rule has to read.
        $wireResultDocument = ((Read-Utf8 -Path $wireResult | ConvertFrom-Json))
        Check 'a Kiro install that dropped an event and can only advise at Stop does NOT report overall ok' (
            [string]$wireResultDocument.overall -ceq 'partial') ([string]$wireResultDocument.overall)
        Check 'the degradation travels in the reason code, with the component status still in its own vocabulary' (
            @($wireResultDocument.components | Where-Object {
                    [string]$_.component -ceq 'kiro' -and [string]$_.status -ceq 'ok' -and [string]$_.reason -ceq 'degraded'
                }).Count -eq 1) (Compact $wireResultDocument.components)

        # A trigger EXISTING is not the same as the hook being able to work on
        # it. Test-Run-Guard reads tool_input, which Kiro IDE does not publish
        # for a shell-command hook, so registering it on PreToolUse produces a
        # hook that fires and immediately exits. That must be NAMED, not left
        # for the user to discover from a hook that silently does nothing.
        $inputProject = Join-Path $Work 'Input Requirement Project'
        New-Item -ItemType Directory -Path $inputProject -Force | Out-Null
        $inputResult = Join-Path $Work 'input-result.json'
        & $InstallScript -CustomHook (Join-Path $ToolRoot 'hooks\Test-Run-Guard\Test-Run-Guard.ps1') `
            -TargetProject $inputProject -Clients kiro -Events PreToolUse -ResultPath $inputResult | Out-Null
        $inputDocument = ((Read-Utf8 -Path $inputResult | ConvertFrom-Json))
        $inputKiro = @($inputDocument.components | Where-Object { [string]$_.component -ceq 'kiro' })
        Check 'a hook needing input Kiro cannot supply is reported by NAME, not silently registered' (
            $inputKiro.Count -eq 1 -and
            [string]$inputKiro[0].message -match 'input-unavailable' -and
            [string]$inputKiro[0].message -match 'tool_input') (Compact $inputDocument.components)
        # The requirement is read from the hook's OWN AST, so it names only the
        # fields that hook actually reads - it is not a blanket per-event
        # warning. Rules-Check on SessionStart reads session_id (which Kiro does
        # not supply, so its dedup degrades) but never touches tool_input, and
        # the message must reflect exactly that. A blanket flag would list
        # fields the hook never uses and train the reader to ignore it.
        $quietProject = Join-Path $Work 'Field Accurate Project'
        New-Item -ItemType Directory -Path $quietProject -Force | Out-Null
        $quietResult = Join-Path $Work 'quiet-result.json'
        & $InstallScript -CustomHook (Join-Path $ToolRoot 'hooks\Rules-Check\Rules-Check.ps1') `
            -TargetProject $quietProject -Clients kiro -Events SessionStart -ResultPath $quietResult | Out-Null
        $quietDocument = ((Read-Utf8 -Path $quietResult | ConvertFrom-Json))
        $quietKiro = @($quietDocument.components | Where-Object { [string]$_.component -ceq 'kiro' })
        Check 'the report names only the fields THAT hook reads, never a blanket per-event warning' (
            $quietKiro.Count -eq 1 -and
            [string]$quietKiro[0].message -match 'session_id' -and
            [string]$quietKiro[0].message -notmatch 'tool_input' -and
            [string]$quietKiro[0].message -notmatch 'tool_name') (Compact $quietDocument.components)

        # A foreign document sitting at the exact path we would write must be
        # refused outright. Overwriting it would destroy hooks another tool or
        # the user owns - and the file content is asserted byte-identical.
        $foreignProject = Join-Path $Work 'Foreign Project'
        New-Item -ItemType Directory -Path (Join-Path $foreignProject '.kiro\hooks') -Force | Out-Null
        $foreignResult = Join-Path $Work 'foreign-result.json'
        & $InstallScript -CustomHook $realHook -TargetProject $foreignProject `
            -Clients kiro -Events SessionStart -ResultPath $foreignResult | Out-Null
        $claimedPath = @(Get-ChildItem -LiteralPath (Join-Path $foreignProject '.kiro\hooks') -Filter 'hookmaker-*.json' -File)[0].FullName
        $foreignBody = '{"version":"v1","hooks":[{"name":"someone-elses","trigger":"Stop","action":{"type":"command","command":"echo hi"}}]}'
        Write-Utf8 -Path $claimedPath -Content $foreignBody
        # The runtime is deleted first so its ABSENCE afterwards is proof the
        # refused install never re-created it. Copy-HookRuntime used to run
        # BEFORE the registration path was proven ours, so a refusal left a
        # complete runtime tree on disk that no install record accounted for -
        # invisible to update and to uninstall alike.
        $foreignRuntimeRoot = Join-Path $foreignProject '.kiro\hook-runtime'
        Remove-Item -LiteralPath $foreignRuntimeRoot -Recurse -Force
        $refusedResult = Join-Path $Work 'refused-result.json'
        & $InstallScript -CustomHook $realHook -TargetProject $foreignProject `
            -Clients kiro -Events SessionStart -ResultPath $refusedResult | Out-Null
        Check 'a foreign document at our own path is left byte-identical, never overwritten' (
            (Read-Utf8 -Path $claimedPath) -ceq $foreignBody) (Read-Utf8 -Path $claimedPath)
        Check 'a refused registration leaves no orphan runtime behind' (
            -not (Test-Path -LiteralPath $foreignRuntimeRoot)) $foreignRuntimeRoot
        $refusedDocument = ((Read-Utf8 -Path $refusedResult | ConvertFrom-Json))
        Check 'refusing a foreign file fails the kiro component instead of reporting an install' (
            @($refusedDocument.components | Where-Object {
                    [string]$_.component -ceq 'kiro' -and [string]$_.status -ceq 'failed'
                }).Count -eq 1) (Compact $refusedDocument.components)
        # Kiro was the ONLY client asked for and it failed, so nothing the caller
        # requested is installed. This read 'partial' because the overall rule
        # counted EVERY ok component - and the bookkeeping 'registry' component
        # is ok here, since tracking a failed install is itself a success. A
        # total failure that reports partial success tells the caller to keep an
        # installation that does not exist.
        Check 'a Kiro-only install whose only client FAILED reports overall failed, never partial' (
            [string]$refusedDocument.overall -ceq 'failed') (
            [string]$refusedDocument.overall + ' | ' + (Compact $refusedDocument.components))

        # A file that EXISTS but will not parse is NOT "no file yet". Swallowing
        # the parse error into $null handed Merge-KiroManagedEntries the same
        # input an absent file produces, so it built a fresh document and wrote
        # it straight over the user's content - the one refusal in this module
        # that destroyed data instead of preserving it.
        $corruptProject = Join-Path $Work 'Corrupt Project'
        New-Item -ItemType Directory -Path (Join-Path $corruptProject '.kiro\hooks') -Force | Out-Null
        & $InstallScript -CustomHook $realHook -TargetProject $corruptProject `
            -Clients kiro -Events SessionStart -ResultPath (Join-Path $Work 'corrupt-claim-result.json') | Out-Null
        $corruptPath = @(Get-ChildItem -LiteralPath (Join-Path $corruptProject '.kiro\hooks') -Filter 'hookmaker-*.json' -File)[0].FullName
        # Truncated mid-object: exactly what a crashed or interrupted writer
        # leaves behind, and indistinguishable from valid JSON by its filename.
        $corruptBody = '{"version":"v1","hooks":[{"name":"half-written",'
        Write-Utf8 -Path $corruptPath -Content $corruptBody
        $corruptRuntimeRoot = Join-Path $corruptProject '.kiro\hook-runtime'
        Remove-Item -LiteralPath $corruptRuntimeRoot -Recurse -Force
        $corruptResult = Join-Path $Work 'corrupt-result.json'
        & $InstallScript -CustomHook $realHook -TargetProject $corruptProject `
            -Clients kiro -Events SessionStart -ResultPath $corruptResult | Out-Null
        Check 'an unparseable document at our own path is left byte-identical, never overwritten' (
            (Read-Utf8 -Path $corruptPath) -ceq $corruptBody) (Read-Utf8 -Path $corruptPath)
        $corruptDocument = ((Read-Utf8 -Path $corruptResult | ConvertFrom-Json))
        Check 'an unparseable registration file fails the kiro component and names invalid-json' (
            @($corruptDocument.components | Where-Object {
                    [string]$_.component -ceq 'kiro' -and [string]$_.status -ceq 'failed' -and
                    [string]$_.message -match 'invalid-json'
                }).Count -eq 1) (Compact $corruptDocument.components)
        Check 'refusing an unparseable file leaves no orphan runtime behind' (
            -not (Test-Path -LiteralPath $corruptRuntimeRoot)) $corruptRuntimeRoot

        # ---- the registration WRITE fails, after the runtime is committed ----
        # Every refusal above is decided by the pre-flight, BEFORE Copy-HookRuntime
        # runs, so proving "no orphan runtime" there only proves the runtime was
        # never staged. This is the other half: the write itself fails once the
        # runtime is already live on disk and its own transaction has closed.
        # Nothing in Install-Hook.ps1 rolled that back, so a failed registration
        # left a changed target - the very thing "nothing was changed" claims.
        #
        # The failure is injected by marking the registration file READ-ONLY:
        # ownership still classifies it as ours, the merge still succeeds, and
        # Write-JsonFile's File.Replace is what throws. That is a genuine
        # post-staging I/O failure, not a mocked one.
        $writeFailProject = Join-Path $Work 'Write Fail Project'
        New-Item -ItemType Directory -Path $writeFailProject -Force | Out-Null
        & $InstallScript -CustomHook $realHook -TargetProject $writeFailProject `
            -Clients kiro -Events SessionStart -ResultPath (Join-Path $Work 'writefail-claim.json') | Out-Null
        $writeFailPath = @(Get-ChildItem -LiteralPath (Join-Path $writeFailProject '.kiro\hooks') -Filter 'hookmaker-*.json' -File)[0].FullName
        $writeFailRuntimeDir = Join-Path $writeFailProject '.kiro\hook-runtime\Hook-Maker\Rules-Check'
        # A file only the PREVIOUS runtime has. Copy-HookRuntime replaces the
        # whole directory by swapping in a staged tree, so this cannot survive
        # unless the previous runtime was genuinely put back - which "a runtime
        # exists here" would not have distinguished, since a fresh one does too.
        $writeFailSentinel = Join-Path $writeFailRuntimeDir 'previous-runtime-marker.txt'
        Write-Utf8 -Path $writeFailSentinel -Content 'PREVIOUS RUNTIME'
        (Get-Item -LiteralPath $writeFailPath).Attributes = 'ReadOnly'
        $writeFailResult = Join-Path $Work 'writefail-result.json'
        & $InstallScript -CustomHook $realHook -TargetProject $writeFailProject `
            -Clients kiro -Events SessionStart -ResultPath $writeFailResult | Out-Null
        (Get-Item -LiteralPath $writeFailPath).Attributes = 'Normal'
        $writeFailDocument = ((Read-Utf8 -Path $writeFailResult | ConvertFrom-Json))
        Check 'a registration write that fails after staging is reported as a failed kiro component' (
            @($writeFailDocument.components | Where-Object {
                    [string]$_.component -ceq 'kiro' -and [string]$_.status -ceq 'failed'
                }).Count -eq 1) (Compact $writeFailDocument.components)
        Check 'a registration write that fails after staging RESTORES the previous runtime' (
            (Test-Path -LiteralPath $writeFailSentinel -PathType Leaf) -and
            (Read-Utf8 -Path $writeFailSentinel) -ceq 'PREVIOUS RUNTIME') $writeFailSentinel
        # The set-aside copy is a rollback target, not a deliverable. Left in the
        # runtime root it would be exactly the kind of unaccounted-for directory
        # that made the updater reinstall Kiro forever.
        Check 'the rollback leaves no set-aside runtime copy behind' (
            @(Get-ChildItem -LiteralPath (Join-Path $writeFailProject '.kiro\hook-runtime\Hook-Maker') `
                    -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '.hookmaker-*' }).Count -eq 0) (
            (@(Get-ChildItem -LiteralPath (Join-Path $writeFailProject '.kiro\hook-runtime\Hook-Maker') -Directory -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Name }) -join ','))

        # The same failure with NOTHING to restore: the runtime this install
        # created must go, along with the directories it created on the way in.
        $freshFailProject = Join-Path $Work 'Fresh Fail Project'
        New-Item -ItemType Directory -Path $freshFailProject -Force | Out-Null
        & $InstallScript -CustomHook $realHook -TargetProject $freshFailProject `
            -Clients kiro -Events SessionStart -ResultPath (Join-Path $Work 'freshfail-claim.json') | Out-Null
        $freshFailPath = @(Get-ChildItem -LiteralPath (Join-Path $freshFailProject '.kiro\hooks') -Filter 'hookmaker-*.json' -File)[0].FullName
        $freshFailRuntimeRoot = Join-Path $freshFailProject '.kiro\hook-runtime'
        Remove-Item -LiteralPath $freshFailRuntimeRoot -Recurse -Force
        # Still ours (an empty managed document), so the write is reached rather
        # than refused up front - only File.Replace fails.
        Write-Utf8 -Path $freshFailPath -Content '{"version":"v1","hooks":[]}'
        (Get-Item -LiteralPath $freshFailPath).Attributes = 'ReadOnly'
        & $InstallScript -CustomHook $realHook -TargetProject $freshFailProject `
            -Clients kiro -Events SessionStart -ResultPath (Join-Path $Work 'freshfail-result.json') | Out-Null
        (Get-Item -LiteralPath $freshFailPath).Attributes = 'Normal'
        Check 'a registration write that fails after staging leaves no live runtime behind' (
            -not (Test-Path -LiteralPath $freshFailRuntimeRoot)) $freshFailRuntimeRoot
        Check 'the registration file a failed write touched is left byte-identical' (
            (Read-Utf8 -Path $freshFailPath) -ceq '{"version":"v1","hooks":[]}') (Read-Utf8 -Path $freshFailPath)

        # The reason a kiro failure must never throw: the menu has no
        # Claude+Codex entry, so 'All clients' is the only way to install two
        # clients in one pass, and a throw would take both down with it.
        $allProject = Join-Path $Work 'All Project'
        New-Item -ItemType Directory -Path $allProject -Force | Out-Null
        $allResult = Join-Path $Work 'all-result.json'
        & $InstallScript -CustomHook $realHook -TargetProject $allProject `
            -Clients claude, codex, kiro -Events SessionStart -ResultPath $allResult | Out-Null
        Check 'all three clients install in a single pass' (
            (Test-Path -LiteralPath (Join-Path $allProject '.claude\settings.local.json')) -and
            (Test-Path -LiteralPath (Join-Path $allProject '.codex\hooks.json')) -and
            @(Get-ChildItem -LiteralPath (Join-Path $allProject '.kiro\hooks') -Filter 'hookmaker-*.json' -File -ErrorAction SilentlyContinue).Count -eq 1) $allProject
    }
    finally {
        if ([string]::IsNullOrEmpty($SavedStateDir)) {
            if (Test-Path Env:\HOOKMAKER_STATE_DIR) { Remove-Item Env:\HOOKMAKER_STATE_DIR -ErrorAction SilentlyContinue }
        }
        else { $env:HOOKMAKER_STATE_DIR = $SavedStateDir }
    }
}
finally {
    $env:USERPROFILE = $SavedUserProfile
    $env:HOME = $SavedHome
    if ([string]::IsNullOrEmpty($SavedClaudeProjectDir)) {
        if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    }
    else { $env:CLAUDE_PROJECT_DIR = $SavedClaudeProjectDir }
    if ([string]::IsNullOrEmpty($SavedHookMakerClient)) {
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
    }
    else { $env:HOOKMAKER_CLIENT = $SavedHookMakerClient }
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
