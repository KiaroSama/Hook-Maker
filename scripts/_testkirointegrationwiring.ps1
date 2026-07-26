# ---------------------------------------------------------------------------
# Install-Hook.ps1 wiring for Kiro: proves the module is actually REACHED.
# Real installs into workspace projects assert registration files,
# per-entry -Trigger commands, a real launcher execution, install-record
# fields, result verdicts and evidence wording, foreign/corrupt-document
# refusals, the post-staging write-failure rollback, and the
# all-three-clients single pass.
#
# Dot-sourced by Test-KiroIntegration.ps1 into ITS scope: Check, $Work,
# $ScriptRoot, $ToolRoot, Write-Utf8/Read-Utf8/Compact and the redirected
# environment all resolve there. Owns its own inner try/finally that saves
# and restores HOOKMAKER_STATE_DIR. Execution order across the companion
# files is load-bearing; none is a standalone suite. Body indentation is
# preserved from the entry file's try block (pure relocation).
# ---------------------------------------------------------------------------

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
        Check 'a hook needing input Kiro may not supply is reported by NAME, not silently registered' (
            $inputKiro.Count -eq 1 -and
            [string]$inputKiro[0].message -match 'input-unverified' -and
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

        # ---- the evidence behind that report must not overstate itself ------
        # ONE kiro client covers TWO surfaces with different evidence. Kiro IDE
        # documents its whole input surface as USER_PROMPT/UserPromptSubmit and
        # nothing else, so a field's absence there is documented. Kiro CLI v3
        # DOES send stdin JSON (this table's own inputProtocol says so) but does
        # not publish its field names - CRITICAL UNKNOWN 4 in
        # .ai/KIRO_PROTOCOL.md. Recording the second as a flat "unavailable" is
        # an unverified fact presented as a confirmed one, and the installer
        # then repeats it to the user as fact.
        #
        # The degradation itself must NOT soften: an unverified field still
        # degrades. Only the CLAIM is corrected.
        foreach ($evidenceCase in @(
                @{ Label = 'a field the hook reads on PreToolUse'; Kiro = $inputKiro; Doc = $inputDocument },
                @{ Label = 'a field the hook reads on SessionStart'; Kiro = $quietKiro; Doc = $quietDocument })) {
            $evidenceMessage = [string]@($evidenceCase.Kiro)[0].message
            Check ('the reason for ' + $evidenceCase.Label + ' never states the field is confirmed unavailable') (
                $evidenceMessage -notmatch 'input-unavailable') $evidenceMessage
            Check ('the reason for ' + $evidenceCase.Label + ' names Kiro IDE as the surface the absence is documented on') (
                $evidenceMessage -match 'Kiro IDE') $evidenceMessage
            Check ('the reason for ' + $evidenceCase.Label + ' says CLI v3 is UNVERIFIED rather than absent') (
                $evidenceMessage -match 'unverified' -and $evidenceMessage -match 'CLI v3') $evidenceMessage
        }
        # Conservative behaviour is unchanged: the component is still degraded,
        # so correcting the wording cannot be mistaken for silently accepting
        # the field as present.
        Check 'an unverified input field still DEGRADES the component rather than passing clean' (
            @($inputDocument.components | Where-Object {
                    [string]$_.component -ceq 'kiro' -and [string]$_.status -ceq 'ok' -and [string]$_.reason -ceq 'degraded'
                }).Count -eq 1) (Compact $inputDocument.components)

        # The table is the source of the claim, so the claim is asserted there
        # too - a corrected message built from a table that still says
        # "unavailable" would drift back the moment anyone else reads the table.
        $evidenceCapability = Get-HookMakerClientCapability -ClientId 'kiro'
        Check 'the capability table no longer carries a flat unavailableInputFields assertion' (
            -not $evidenceCapability.Contains('unavailableInputFields')) (
            (@($evidenceCapability.Keys) -join ','))
        Check 'the table records those fields as UNVERIFIED, keyed by the same logical events' (
            $evidenceCapability.Contains('unverifiedInputFields') -and
            $evidenceCapability.unverifiedInputFields.ContainsKey('PreToolUse') -and
            @($evidenceCapability.unverifiedInputFields['PreToolUse']) -contains 'tool_input') (
            (@($evidenceCapability.Keys) -join ','))
        # The detail is read through Contains first: Check evaluates its detail
        # argument EAGERLY, so reading a missing key directly would crash the
        # suite under StrictMode instead of failing this assertion cleanly.
        $evidenceNote = if ($evidenceCapability.Contains('unverifiedInputFieldsNote')) {
            [string]$evidenceCapability.unverifiedInputFieldsNote
        }
        else { '<absent>' }
        Check 'the table states the two-surface evidence once, in the words the installer reports' (
            $evidenceNote -match 'Kiro IDE' -and
            $evidenceNote -match 'unverified on Kiro CLI v3') $evidenceNote

        # C-05: the two surfaces are STRUCTURED evidence, not just a sentence.
        # One client id ('kiro' stays singular - records and menu unchanged),
        # but each surface records its own evidence kind: the IDE's silence is
        # documented-absent, CLI v3's fields are unverified (it DOES send stdin
        # JSON; the names are simply unpublished). The note above must AGREE
        # with these structures - that agreement is what stops the sentence and
        # the data drifting apart the way the old flat wording did.
        Check 'the kiro entry records its two surfaces with DIFFERENT evidence kinds' (
            $evidenceCapability.Contains('surfaces') -and
            $evidenceCapability.surfaces.ContainsKey('kiro-ide') -and
            $evidenceCapability.surfaces.ContainsKey('kiro-cli-v3') -and
            [string]$evidenceCapability.surfaces['kiro-ide'].inputEvidence -eq 'documented-absent' -and
            [string]$evidenceCapability.surfaces['kiro-cli-v3'].inputEvidence -eq 'unverified') (
            (@($evidenceCapability.Keys) -join ','))
        Check 'the surfaces agree with the table: only CLI v3 claims stdin JSON, matching inputProtocol' (
            $evidenceCapability.Contains('surfaces') -and
            $evidenceCapability.surfaces['kiro-ide'].stdinJson -eq $false -and
            $evidenceCapability.surfaces['kiro-cli-v3'].stdinJson -eq $true) 'surface stdinJson flags'
        if ($evidenceCapability.Contains('surfaces')) {
            $surfaceIde = [string]$evidenceCapability.surfaces['kiro-ide'].displayName
            $surfaceCli = [string]$evidenceCapability.surfaces['kiro-cli-v3'].displayName
            Check 'the note names BOTH surface displayNames, so sentence and structure cannot drift' (
                $evidenceNote -match [regex]::Escape($surfaceIde) -and
                $evidenceNote -match [regex]::Escape($surfaceCli)) ($evidenceNote + ' vs ' + $surfaceIde + '/' + $surfaceCli)
        }

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
