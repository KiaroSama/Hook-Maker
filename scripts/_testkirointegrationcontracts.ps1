# ---------------------------------------------------------------------------
# Kiro contract scenarios: the client/event capability table, every logical
# event mapped or NAMED unsupported (never dropped, never remapped onto
# Stop), the event PLAN's degraded reporting, and Write-HookResult's
# per-event output shape (real gates, downgraded gates, context channels).
#
# Dot-sourced by Test-KiroIntegration.ps1 into ITS scope: Check, the
# $script: counters, $managedId, $command, $capability, $logicalEvents,
# $supportedEvents, $protocolTriggers, Invoke-KiroResult, Compact and
# Get-Rejection all resolve there. Execution order across the companion
# files is load-bearing; none is a standalone suite. Body indentation is
# preserved from the entry file's try block (pure relocation).
# ---------------------------------------------------------------------------

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
