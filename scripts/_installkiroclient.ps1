# The KIRO CLIENT INSTALL, split out of Install-Hook.ps1 (which had grown past
# the file-size review threshold) as a PURE relocation - the body below is
# byte-identical to what lived there.
#
# NOT THE SAME FILE AS _installkiro.ps1, and the two are easy to confuse:
#
#   _installkiro.ps1       PURE. Kiro's document format - building, validating,
#                          classifying and merging hook entries, plus the path
#                          and runtime-root derivations. It never touches the
#                          filesystem, which is what makes it unit-testable
#                          (Test-InstallKiro.ps1).
#   _installkiroclient.ps1 THIS FILE. The install FLOW that uses that format:
#                          the runtime rollback snapshot, the ordered commit of
#                          runtime then registration, the resource lock around
#                          the registration write, and the component/degradation
#                          reporting. Every filesystem write for Kiro is here.
#
# Dot-sourced by Install-Hook.ps1 at the POSITION the Kiro phase runs - after
# the Claude and Codex client blocks and before the native-git phase - not with
# the module group at the top. That is deliberate: unlike the other _install*
# modules this file is not only function definitions, it also carries the
# top-level `if ($InstallKiro)` block, so where it is dot-sourced IS when the
# Kiro install happens. The same convention the dot-sourced test scenario blocks
# use (see Test-InstallRegistry.ps1 and its _testinstallregistry*.ps1 files).
#
# It relies on the entry script's scope throughout: it reads $InstallKiro,
# $Events, $ScopeLabel, $FriendlyName, $RecordId, $RecordProjectRoot,
# $KiroTargetRoot, $SourceInfo and $script:EffectiveTimeout, and it assigns the
# $kiro* variables the install registry block below it records. Nothing here is
# callable on its own.

# ---- kiro runtime rollback -------------------------------------------------
# Copy-HookRuntime COMMITS the runtime: Install-PlannedRuntime stages the
# replacement in a sibling directory, hash-verifies it, moves the live directory
# aside, swaps the replacement in and then DROPS the set-aside copy. Past that
# point the target has already changed while the registration - the only thing
# that makes the runtime reachable - has not been written yet. A registration
# that is then refused or fails to write must leave the target exactly as it was
# found, and the runtime's own transaction has already closed.
#
# So the same mechanism is applied one level up: the hook's runtime directory is
# set aside BEFORE the install, restored if the registration never lands, and
# dropped once it does. COPIED rather than moved, so the previous runtime stays
# live while the replacement is staged - Install-PlannedRuntime's own move-aside
# window stays exactly as short as it already is.
#
# The set-aside directory deliberately reuses Install-PlannedRuntime's
# '.hookmaker-previous-<FriendlyName>-<token>' naming: its janitor sweeps
# abandoned directories with that prefix older than 30 minutes, so a process
# killed between the swap and the registration write is cleaned by the next
# install rather than leaving a directory nothing owns. The token makes it
# distinct from the one Install-PlannedRuntime creates for itself, and the
# 30-minute floor means it never deletes a concurrent install's live copy.
function New-KiroRuntimeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$HookDirectoryName
    )
    $hookDirectory = Join-Path $RuntimeRoot $HookDirectoryName
    # Every ancestor that does not exist yet is one this install is about to
    # create, so removing it again is part of "exactly as it was found". Deepest
    # first, which is also the only order they can be removed in.
    $createdDirectories = New-Object System.Collections.Generic.List[string]
    $ancestor = $RuntimeRoot
    while (-not [string]::IsNullOrWhiteSpace($ancestor) -and -not (Test-Path -LiteralPath $ancestor -PathType Container)) {
        [void]$createdDirectories.Add($ancestor)
        $ancestor = Split-Path -Parent $ancestor
    }
    $asideCopy = ''
    if (Test-Path -LiteralPath $hookDirectory -PathType Container) {
        $asideCopy = Join-Path $RuntimeRoot ('.hookmaker-previous-' + $HookDirectoryName + '-' +
            [guid]::NewGuid().ToString('N').Substring(0, 8))
        Copy-Item -LiteralPath $hookDirectory -Destination $asideCopy -Recurse -Force
    }
    return [pscustomobject]@{
        RuntimeRoot        = $RuntimeRoot
        HookDirectory      = $hookDirectory
        AsideCopy          = $asideCopy
        CreatedDirectories = @($createdDirectories.ToArray())
    }
}

# Puts the runtime back the way New-KiroRuntimeSnapshot found it, and returns a
# sanitized note when it could not. Best-effort BY DESIGN: this runs while an
# install is already failing, so a cleanup error must be REPORTED alongside the
# real reason rather than replacing it with its own.
function Restore-KiroRuntimeSnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot) { return '' }
    try {
        if (Test-Path -LiteralPath $Snapshot.HookDirectory) {
            Remove-Item -LiteralPath $Snapshot.HookDirectory -Recurse -Force
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Snapshot.AsideCopy) -and
            (Test-Path -LiteralPath $Snapshot.AsideCopy)) {
            Move-Item -LiteralPath $Snapshot.AsideCopy -Destination $Snapshot.HookDirectory -Force
            return ''
        }
        # Nothing was here before, so the directories this install created on the
        # way in go too - but only while they are empty. A non-empty one holds
        # something this install did not put there (another hook's runtime), and
        # stopping at it also stops at every ancestor above it.
        foreach ($created in @($Snapshot.CreatedDirectories)) {
            if (-not (Test-Path -LiteralPath $created -PathType Container)) { continue }
            if (@(Get-ChildItem -LiteralPath $created -Force -ErrorAction SilentlyContinue).Count -gt 0) { break }
            Remove-Item -LiteralPath $created -Force
        }
        return ''
    }
    catch {
        return (' The previously installed Kiro runtime could not be fully restored at ' +
            [string]$Snapshot.HookDirectory + ': ' + [string]$_.Exception.Message)
    }
}

# ---- kiro -----------------------------------------------------------------
# Kiro is registrationKind 'perHookFile': one JSON document per hook under
# .kiro\hooks, NOT a shared settings file. So there is no Add-HookGroup /
# Remove-StaleHandlers path here - ownership is proved per ENTRY by the marker
# _installkiro.ps1 embeds, and foreign entries in the same document are carried
# across by reference and never rewritten.
#
# Every failure below fails ONE component and lets the other clients finish.
# Nothing here throws, because a Kiro problem must not discard a completed
# Claude or Codex install.
$kiroRegistrationPath = ''
$kiroManagedNames = @()
$kiroSupported = @()
$kiroUnsupported = @()
$kiroDegraded = @()
$kiroRuntime = $null
$kiroCommands = $null
# Initialized before the lock so a refusal inside it cannot leave this unset -
# reading an unassigned variable throws under StrictMode.
$script:KiroWrittenNames = @()
$script:KiroRegistrationWritten = $false
# Set the moment before the runtime is committed; read by the catch to undo it.
$script:KiroRuntimeSnapshot = $null
if ($InstallKiro) {
    $script:CurrentPhase = 'kiro'
    try {
        $kiroCapability = Get-HookMakerClientCapability -ClientId 'kiro'
        # Kiro documents 5 of the 12 logical events. An unsupported event is
        # reported by NAME rather than dropped silently, and is never remapped
        # onto a different trigger - a hook the user believes gates Stop, but
        # which was quietly moved to SessionStart, is worse than one that
        # openly did not install.
        foreach ($requested in @($Events)) {
            if (@($kiroCapability.supportedEvents | Where-Object { $_ -ceq $requested }).Count -gt 0) {
                $kiroSupported += $requested
            }
            else { $kiroUnsupported += $requested }
        }
        # Kiro cannot hard-block at Stop on EITHER targeted surface (see
        # .ai/KIRO_PROTOCOL.md). This is permanent for Kiro, not conditional, so
        # it is recorded as a degraded reason rather than presented as a gate.
        if (@($kiroSupported | Where-Object { $_ -ceq 'Stop' }).Count -gt 0) {
            $kiroDegraded += 'degraded-stop-gate'
        }

        # A trigger EXISTING is not the same as this hook being able to do its
        # job on it. Kiro fires PreToolUse/PostToolUse, but Kiro IDE publishes no
        # tool_name/tool_input for a shell-command hook - so a hook that reads
        # the tool payload registers fine and then exits immediately. Present,
        # registered, and useless, with nothing saying so.
        #
        # The required fields are read from the HOOK'S OWN SOURCE rather than a
        # hand-kept table: every hook reads its input through
        # `Get-Field $hookInput '<name>'`, so the AST already states what it
        # needs. A maintained list would drift from the code, which is the exact
        # failure this repo keeps hitting - here it cannot, because the list IS
        # the code.
        try {
            $kiroHookAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $SourceInfo.ScriptPath, [ref]$null, [ref]$null)
            $kiroReadFields = @($kiroHookAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Get-Field'
                    }, $true) | ForEach-Object {
                    $lastArg = @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] })
                    if ($lastArg.Count -gt 0) { [string]$lastArg[-1].Value }
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

            $kiroMissingByEvent = @()
            foreach ($supportedEvent in @($kiroSupported)) {
                if (-not $kiroCapability.unverifiedInputFields.ContainsKey($supportedEvent)) { continue }
                $missingHere = @(@($kiroCapability.unverifiedInputFields[$supportedEvent]) |
                    Where-Object { @($kiroReadFields | Where-Object { $_ -ceq $PSItem }).Count -gt 0 })
                if ($missingHere.Count -gt 0) {
                    $kiroMissingByEvent += ($supportedEvent + ' needs ' + ($missingHere -join '/'))
                }
            }
            if ($kiroMissingByEvent.Count -gt 0) {
                # Reported as UNVERIFIED, never as a confirmed absence, and the
                # qualifier is taken verbatim from the capability table so the
                # claim and its evidence cannot drift apart. One kiro id spans
                # Kiro IDE (where the docs describe the absence) and Kiro CLI v3
                # (which does send stdin JSON but publishes no field names), so
                # "Kiro cannot supply X" would state as fact something only half
                # of that pair supports.
                #
                # It still DEGRADES. The conservative outcome is unchanged -
                # a hook that may be unable to read its input is reported either
                # way; only the strength of the claim is corrected.
                $kiroDegraded += ('input-unverified (' + [string]$kiroCapability.unverifiedInputFieldsNote +
                    '): ' + ($kiroMissingByEvent -join '; '))
            }
        }
        catch {
            # Never fail an install because the source could not be parsed for
            # ADVISORY metadata - the registration itself is unaffected.
            $kiroDegraded += 'input-availability-unchecked'
        }

        if ($kiroSupported.Count -eq 0) {
            Set-ComponentResult -Component 'kiro' -Status 'failed' -ReasonCode 'noSupportedEvents' `
                -Message ('None of the requested events (' + (@($Events) -join ', ') +
                    ') has a documented Kiro trigger. Supported: ' + (@($kiroCapability.supportedEvents) -join ', ') + '.')
            Write-Host ('Kiro skipped - no requested event has a documented Kiro trigger. Supported: ' +
                (@($kiroCapability.supportedEvents) -join ', ') + '.')
        }
        else {
            # PRE-FLIGHT BEFORE THE RUNTIME IS COMMITTED. Copy-HookRuntime used
            # to run first, so a registration refused below left an installed
            # runtime on disk that no record accounted for - an orphan neither
            # update nor uninstall could ever see. The path is proven
            # writable-and-ours here, while nothing has been written yet.
            #
            # Test-KiroManagedFile is the ONE place that question is decided
            # (_installkiro.ps1), so this cannot drift from the writer's own
            # notion of ownership. It is unlocked and therefore ADVISORY: the
            # authoritative verdict is re-taken inside the lock below.
            $kiroRegistrationPath = Get-KiroRegistrationPath -Scope $ScopeLabel -FriendlyName $FriendlyName `
                -StableId $RecordId -TargetProjectRoot $KiroTargetRoot
            $kiroPreflight = Test-KiroManagedFile -Path $kiroRegistrationPath -ManagedId $RecordId
            if (-not $kiroPreflight.Ok) {
                throw ('Kiro registration file ' + $kiroRegistrationPath + ' is not safe to write (' +
                    $kiroPreflight.Reason + '). Nothing was changed.')
            }

            $kiroRuntimeRoot = Get-KiroRuntimeRoot -Scope $ScopeLabel -TargetProjectRoot $KiroTargetRoot
            # RuntimeRootOverride, because Kiro's runtime must NOT live under
            # .kiro\hooks: that directory is Kiro's hook-config discovery root,
            # so a copied .ps1 tree inside it would be scanned as configuration.
            # -IncludeKiroLauncher: the launcher is part of the PLAN, so it is
            # staged transactionally, hash-verified and recorded in the install
            # manifest. Writing it here afterwards (the first version of this)
            # left a real file no artifact accounted for, so every later
            # evaluation reported "unexpected managed file" and the updater
            # reinstalled Kiro forever. See Get-ManagedInstallPlan.
            #
            # THE NEXT LINE COMMITS THE RUNTIME. The pre-flight above is
            # unlocked, and the authoritative ownership verdict is not re-taken
            # until inside the lock below, so both a registration file that
            # changed in between and a registration WRITE that fails leave a
            # committed runtime behind. Neither can be rolled back by the
            # runtime's own transaction, which has already closed - so the
            # target's previous state is captured here and restored by the
            # catch when the registration does not land.
            #
            # THE PROCESS-KILL WINDOW IS DELIBERATELY LEFT OPEN. The catch below
            # covers every EXCEPTION between this line and the registration
            # write, but a `kill -9` or a power loss in between runs no catch,
            # so a first-time install can leave a runtime with no registration
            # and no record. Measured cost of that residue, not estimated:
            #
            #   * .kiro\hooks - the directory Kiro actually scans as config -
            #     holds ZERO files, so Kiro never loads, parses or executes it.
            #     That is the whole reason runtimeRelativeRoot is
            #     .kiro\hook-runtime and not .kiro\hooks.
            #   * Get-HookStatus reports 0 logical hooks for the project, so it
            #     is not even a false positive in status.
            #   * ~61 KB, and reinstalling the same hook overwrites it.
            #
            # A durable mark/sweep journal was evaluated against that and
            # REJECTED. Its own unmark is not atomic with the registration
            # write, so the identical kill one step later leaves a marker
            # pointing at a LIVE, REGISTERED runtime; to avoid deleting that,
            # the sweep must cross-check .kiro\hooks and the registry - i.e. the
            # general transaction manager, arrived at by necessity. And it would
            # buy a directory DELETE, whose worst case is destroying a user's
            # directory, to reclaim 61 KB of inert files that nothing reads.
            # Wrong trade. The current commit ORDER is what actually contains
            # this: runtime first means a crash strands something inert, while
            # registration first would strand a registered hook whose runtime is
            # missing - visible, and failing on every trigger. Do not "fix" this
            # by swapping the order.
            $script:KiroRuntimeSnapshot = New-KiroRuntimeSnapshot -RuntimeRoot $kiroRuntimeRoot -HookDirectoryName $FriendlyName
            $kiroRuntime = Copy-HookRuntime -ClientDir $kiroRuntimeRoot -RuntimeRootOverride $kiroRuntimeRoot -IncludeKiroLauncher `
                -RuntimeIdentity (New-RuntimeIdentity -Client 'kiro' -Scope $ScopeLabel -RecordId $RecordId -ProjectRoot $RecordProjectRoot)
            $kiroLauncherPath = Join-Path (Split-Path -Parent $kiroRuntime.Script) 'kiro-launch.ps1'
            if (-not (Test-Path -LiteralPath $kiroLauncherPath -PathType Leaf)) {
                throw ('The Kiro launcher was not produced by the install plan at ' + $kiroLauncherPath +
                    '. Nothing was registered.')
            }

            # Built from the launcher, not the hook script, and carrying the
            # same -ConfigPath/-Profile suffix the other clients use.
            $kiroLauncherRuntime = [pscustomobject]@{
                Script = $kiroLauncherPath
                Config = $kiroRuntime.Config
                Plan   = $kiroRuntime.Plan
            }
            $kiroCommands = New-HookCommands -Runtime $kiroLauncherRuntime

            Invoke-WithResourceLock -ResourcePath $kiroRegistrationPath -Action {
                # THE authoritative ownership verdict, re-taken under the lock
                # because the pre-flight above necessarily ran unlocked and
                # before the runtime was staged.
                #
                # It also separates the two states a bare try/catch used to
                # collapse into one. A file that is ABSENT ('missing') is a
                # fresh install; a file that is PRESENT but will not parse
                # ('invalid-json') is somebody's content in an unknown state,
                # and swallowing that parse error into $null told
                # Merge-KiroManagedEntries "no file yet" - which wrote a fresh
                # document straight over it. A parse failure is a REFUSAL.
                $kiroOwnership = Test-KiroManagedFile -Path $kiroRegistrationPath -ManagedId $RecordId
                if (-not $kiroOwnership.Ok) {
                    throw ('Kiro registration file ' + $kiroRegistrationPath + ' is not safe to write (' +
                        $kiroOwnership.Reason + '). Nothing was changed.')
                }
                $existingDocument = $null
                if ($kiroOwnership.Reason -cne 'missing') {
                    # Parsed here rather than reusing the classifier's entries
                    # because Merge-KiroManagedEntries takes the whole document.
                    # NOT wrapped in try/catch: it just parsed cleanly a moment
                    # ago under this lock, so a failure now is a real anomaly
                    # that must surface as a refusal, never as "no file yet".
                    #
                    # Extra parentheses are load-bearing: @($x | ConvertFrom-Json)
                    # yields ONE opaque Object[] on Windows PowerShell 5.1
                    # whose PSObject.Properties is empty, so every field
                    # read below would silently return $null.
                    $raw = [System.IO.File]::ReadAllText($kiroRegistrationPath, [System.Text.Encoding]::UTF8)
                    $existingDocument = (($raw | ConvertFrom-Json))
                }

                # ONE ENTRY AT A TIME, because each entry needs its OWN command:
                # KIRO_PROTOCOL requires the physical trigger to be passed
                # explicitly, and Kiro IDE documents no stdin JSON at all, so a
                # hook that is registered on three triggers with one shared
                # command line has no way to tell which one fired. Building the
                # whole document in a single call would produce exactly that.
                $builtEntries = @()
                foreach ($logicalEvent in @($kiroSupported)) {
                    $physicalTrigger = $logicalEvent
                    if ($kiroCapability.physicalEventMap.ContainsKey($logicalEvent)) {
                        $physicalTrigger = [string]$kiroCapability.physicalEventMap[$logicalEvent]
                    }
                    # -Trigger is a declared launcher parameter, so it is consumed
                    # there and the -ConfigPath/-Profile suffix still reaches the
                    # hook through @args untouched.
                    $perTriggerCommand = $kiroCommands.Windows + ' -Trigger ' + $physicalTrigger
                    $builtDocument = New-KiroHookDocument -FriendlyName $FriendlyName -Command $perTriggerCommand `
                        -Triggers @($logicalEvent) -TimeoutSeconds $script:EffectiveTimeout -ManagedId $RecordId
                    $builtEntries += @($builtDocument.hooks)
                }
                $merged = Merge-KiroManagedEntries -ExistingDocument $existingDocument `
                    -ManagedEntries @($builtEntries) -ManagedId $RecordId
                if (-not $merged.Ok) {
                    # 'foreign' / 'unexpected-schema': the file at our path holds
                    # entries that are not ours. Refuse it rather than overwrite
                    # someone else's registrations.
                    throw ('Kiro registration file ' + $kiroRegistrationPath + ' is not safe to write (' +
                        $merged.Reason + '). Nothing was changed.')
                }
                Backup-File $kiroRegistrationPath
                Write-JsonFile -Value $merged.Document -Path $kiroRegistrationPath
                $script:KiroWrittenNames = @($merged.ManagedEntries | ForEach-Object { [string]$_.name })
                # Set LAST, and only inside the lock: past this line the
                # registration file exists on disk, so no later failure may be
                # reported as 'registrationRefused' - that would tell a user
                # nothing was installed while their .kiro\hooks entry is live.
                $script:KiroRegistrationWritten = $true
            }
            $kiroManagedNames = @($script:KiroWrittenNames)
            # The registration is live, so the runtime it points at is the one
            # that must survive: the set-aside copy is no longer a rollback
            # target, it is clutter. Dropped best-effort - failing an install
            # that fully succeeded because a temporary directory would not
            # delete would be the wrong trade. Nulled so nothing below can
            # restore a superseded runtime over the live one.
            if (-not [string]::IsNullOrWhiteSpace([string]$script:KiroRuntimeSnapshot.AsideCopy)) {
                Remove-Item -LiteralPath $script:KiroRuntimeSnapshot.AsideCopy -Recurse -Force -ErrorAction SilentlyContinue
            }
            $script:KiroRuntimeSnapshot = $null

            # 'ok' with recorded degradation, NOT a 'partial' component status.
            # The component genuinely succeeded for every trigger Kiro supports;
            # what was reduced is captured durably in the record's
            # unsupportedEvents/degradedReasons, and 'partial' is the OVERALL
            # result's vocabulary, not a component's.
            $kiroNotes = @()
            if ($kiroUnsupported.Count -gt 0) { $kiroNotes += ('no Kiro trigger for: ' + ($kiroUnsupported -join ', ')) }
            if ($kiroDegraded.Count -gt 0) { $kiroNotes += ($kiroDegraded -join ', ') }
            if ($kiroNotes.Count -gt 0) {
                Set-ComponentResult -Component 'kiro' -Status 'ok' -ReasonCode 'degraded' `
                    -Message ('Kiro installed with reduced capability - ' + ($kiroNotes -join '; ') + '.')
                Write-Host ('Kiro hook (' + $ScopeLabel + ') installed with reduced capability: ' + ($kiroNotes -join '; ') + '.')
            }
            else {
                Set-ComponentResult -Component 'kiro' -Status 'ok'
            }
            Write-Host "Kiro hook ($ScopeLabel) registered in: $kiroRegistrationPath"
            Write-Host "Kiro runtime copy: $($kiroRuntime.Script)"
        }
    }
    catch {
        # Includes every New-KiroRejection this module raises (unknown trigger,
        # invalid matcher regex, unusable name, foreign file). The reason text
        # is preserved verbatim: it names the exact thing to fix.
        #
        # The two cases are reported differently ON PURPOSE. Before the write,
        # nothing was installed and 'registrationRefused' is the truth. AFTER
        # the write the registration is live, so reporting a refusal would send
        # the user looking for a hook that is in fact registered - it is
        # 'postRegistrationError' instead, and it names the file to inspect.
        if ($script:KiroRegistrationWritten) {
            Set-ComponentResult -Component 'kiro' -Status 'ok' -ReasonCode 'postRegistrationError' `
                -Message ('Kiro was registered in ' + $kiroRegistrationPath +
                    ', but a later step failed: ' + [string]$_.Exception.Message)
            Write-Host ('WARNING: Kiro was registered in ' + $kiroRegistrationPath +
                ', but a later step failed: ' + [string]$_.Exception.Message)
        }
        else {
            # Nothing was registered, so the runtime this install may already
            # have committed is unreachable and accounted for by no record -
            # exactly the orphan the pre-flight was added to prevent, reached
            # by the two paths the pre-flight cannot cover (a registration file
            # that changed before the lock, and a write that fails). Undone
            # here, and a rollback that could not complete is APPENDED to the
            # reason rather than swallowed: a half-restored runtime the user is
            # never told about is worse than the failure that caused it.
            #
            # Guarded on KiroRegistrationWritten because a POST-registration
            # failure must KEEP the runtime - the live .kiro\hooks entry points
            # straight at it.
            $kiroRollbackNote = Restore-KiroRuntimeSnapshot -Snapshot $script:KiroRuntimeSnapshot
            $script:KiroRuntimeSnapshot = $null
            Set-ComponentResult -Component 'kiro' -Status 'failed' -ReasonCode 'registrationRefused' `
                -Message ([string]$_.Exception.Message + $kiroRollbackNote)
            Write-Host ('Kiro registration refused: ' + [string]$_.Exception.Message + $kiroRollbackNote)
        }
    }
}
