# Test-CloudflareDeploy.ps1 scenario block: MANAGED-OWNERSHIP EVIDENCE - the
# whole answer to "is Test-Temp-Cleanup actually installed for this project".
#
# Covers the positive chain on every client and scope, every negative case that
# must NOT count as evidence (heuristics, foreign runtimes, wrong scope, a
# non-Stop registration, an incomplete or self-contradicting manifest), the
# source-text contracts the chain depends on (declared category list, evaluation
# ordering, the limits the hook states instead of faking), the mirrors that keep
# the hook's copies of client paths and installer constants from rotting, and
# the two-sided producer/consumer metadata contract.
#
# Dot-sourced by Test-CloudflareDeploy.ps1 into the caller's scope (uses its
# harness, fixtures and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- managed ownership: every client, both scopes ---' -ForegroundColor Cyan
    # The gate must apply on EVERY supported client's REAL registration schema,
    # and only when the runtime behind it is ownership-proven. Kiro's
    # registration is a per-hook v1 file under .kiro\hooks - the same directory
    # its RUNTIME deliberately stays out of - and it registers kiro-launch.ps1,
    # not the hook script, so the ownership metadata is what says which file the
    # command must point at.
    foreach ($client in @('claude', 'codex', 'kiro')) {
        $gatedRepo = New-ReadyWorkersRepo ('CleanupOn-' + $client)
        New-ManagedCleanupInstall -Base $gatedRepo -Client $client | Out-Null
        Write-CleanupResult -Root $gatedRepo -Category 'review-required'
        $r = Fire -Cwd $gatedRepo
        Check ('a managed ' + $client + ' project install is detected: review-required -> silent') (
            $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

        $readyRepo = New-ReadyWorkersRepo ('CleanupOnReady-' + $client)
        New-ManagedCleanupInstall -Base $readyRepo -Client $client | Out-Null
        Write-CleanupResult -Root $readyRepo -Category 'clean'
        $r = Fire -Cwd $readyRepo
        Check ('a managed ' + $client + ' project install with a fresh clean shows the decision') (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out
    }

    # A non-rooted command path resolves against the scope base, the way a client
    # resolves it against the project - it must still count.
    $relativeCommand = New-ReadyWorkersRepo 'CleanupRelativeCommand'
    New-ManagedCleanupInstall -Base $relativeCommand -CommandForm 'relative' | Out-Null
    $r = Fire -Cwd $relativeCommand
    Check 'a RELATIVE command path into the managed runtime still proves the install (no record yet -> silent)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # A GLOBAL install lives in the user profile (the fake one Fire redirects
    # USERPROFILE to) and records no project key, because it serves every
    # project. Written and removed HERE so no other fixture inherits it.
    $globalRepo = New-ReadyWorkersRepo 'CleanupGlobalScope'
    New-ManagedCleanupInstall -Base $FakeUserProfile -Scope 'global' | Out-Null
    try {
        $r = Fire -Cwd $globalRepo
        Check 'a valid GLOBAL managed install applies the gate for a project with no local evidence at all' (
            $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

        $globalReady = New-ReadyWorkersRepo 'CleanupGlobalScopeReady'
        Write-CleanupResult -Root $globalReady -Category 'clean'
        $r = Fire -Cwd $globalReady
        Check 'the same global install with a fresh clean shows the decision' (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') $r.Out
        # NO "project doc claiming global scope, with a real global install
        # present" case here on purpose: with the gate already applying via the
        # global install, that assertion would read as silent whether the project
        # document was rejected or accepted - it cannot fail for its own reason.
        # The scope check is proven by the wrong-scope NEGATIVE below, where the
        # decision being shown is only possible if the mismatch was rejected.
    }
    finally {
        Remove-Item -LiteralPath (Join-Path $FakeUserProfile '.claude') -Recurse -Force -ErrorAction SilentlyContinue
    }

    # =====================================================================
    Write-Host '--- negative evidence: nothing heuristic proves an install ---' -ForegroundColor Cyan
    # EVERY case here must SHOW the deployment decision. That is the whole point
    # of the direction change: a negative SKIPS the cleanup gate, so the agent
    # still gets step 1's "no disposable test cache/temp residue" requirement.
    # The old direction applied the gate and then waited forever for a fresh
    # 'clean' nothing would ever write - a permanently dead reminder.
    #
    # A second project's key, computed the way the installer would compute it for
    # that project. Nothing is created there: the point is only that the key
    # belongs to a DIFFERENT root than the one the hook recomputes.
    $foreignProjectKey = Get-ShortHash (Normalize-Path (Join-Path $Work 'SomeOtherProject')).ToLowerInvariant()
    $negativeCases = @(
        [pscustomobject]@{
            Name  = 'a fingerprint-CURRENT coordination result ALONE'
            Why   = 'only the hook writes one, but a leftover state file is not an active install'
            Build = { param($Repo) Write-CleanupResult -Root $Repo -Category 'review-required' }
        }
        [pscustomobject]@{
            Name  = 'a fingerprint-current result plus a bare runtime DIRECTORY'
            Why   = 'a hand-made or half-deleted folder satisfies a listing while nothing there can run'
            Build = { param($Repo) New-CleanupMarker -Root $Repo | Out-Null; Write-CleanupResult -Root $Repo -Category 'clean' }
        }
        [pscustomobject]@{
            Name  = 'a runtime directory only, with no registration anywhere'
            Why   = 'the removers delete this directory on the same success path that retires the record'
            Build = { param($Repo) New-CleanupMarker -Root $Repo | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a STALE coordination record with no registration'
            Why   = 'a surviving stale record evidences an install that is GONE'
            Build = { param($Repo) Write-CleanupResult -Root $Repo -Category 'clean' -StaleFingerprint }
        }
        [pscustomobject]@{
            Name  = 'a MALFORMED registration document naming the hook'
            Why   = 'a document nobody can parse proves no active registration - this reverses the old conservative verdict'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'malformed' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a document that only NAME-DROPS the hook'
            Why   = 'no command, no runtime, so nothing would ever record a fresh clean'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'nameDrop' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a real managed command quoted in a NON-command field'
            Why   = 'only the handler''s own command fields count, never any string in the document'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'nonCommandField' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro action carrying the command under a non-command key'
            Why   = 'action.command is the only field a Kiro command action runs'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -CommandForm 'nonCommandField' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a FOREIGN Kiro entry holding a real managed command'
            Why   = 'the entry name must be the one the ownership metadata records; a neighbour cannot borrow it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -KiroEntryName 'someone-elses-hook-stop' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a real managed command in a Kiro file Hook Maker does not own'
            Why   = 'only .kiro\hooks\hookmaker-<slug>.json is ours; a shared/foreign document is never parsed for ownership'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -KiroFileName 'foreign-hook.json' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro document that is not the v1 shape'
            Why   = 'a legacy 0.x/.kiro.hook document is not something this hook can reason about'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -KiroVersion 'v0' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a runtime copied in by hand under a path carrying both magic segments'
            Why   = '\Hook-Maker\ + \Test-Temp-Cleanup\ in a path spelling is not containment under the client''s runtime root'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'outside' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a relative command path that escapes the runtime root with ..'
            Why   = 'the escaped target exists on disk, so only the containment check can reject it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -CommandForm 'escape' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata claiming the WRONG client'
            Why   = 'the metadata must agree with the document that referenced it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'claude' -Metadata @{ client = 'codex' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata claiming the WRONG scope'
            Why   = 'a project-scope document cannot be backed by a global-scope runtime record'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ scope = 'global' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata carrying ANOTHER project''s projectKey'
            Why   = 'THE check that catches a runtime copied in from a different project'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ projectKey = $foreignProjectKey } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with an EMPTY projectKey on a project install'
            Why   = 'only a global install is project-unbound'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ projectKey = '' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro install whose recordId disagrees with the entry''s own marker'
            Why   = 'recordId cannot be cross-checked against the tool-root registry, so it is proven against the entry that carries it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -Metadata @{ recordId = 'rec-someone-else' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with no recordId at all'
            Why   = 'an install with no managed identity is not a managed install'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ recordId = '<remove>' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with no registrationName'
            Why   = 'the metadata must say which registration it belongs to'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ registrationName = '<remove>' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro install whose registrationName prefix does not match the entry'
            Why   = 'metadata and the located entry must be the same registration'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -Metadata @{ registrationName = 'hookmaker-other-install-something' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro registrationName truncated to a prefix that would match anything managed'
            Why   = 'a startsWith test must not be satisfiable by degrading the recorded value'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -Metadata @{ registrationName = 'h' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Claude registrationName that is not the managed runtime segment pair'
            Why   = 'a handler entry has no name, so the recorded identity is the segment pair the installer writes'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ registrationName = 'Some-Other-Root/Test-Temp-Cleanup' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata with an unknown schemaVersion'
            Why   = 'a version this hook does not understand cannot be validated field by field'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ schemaVersion = 99 } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'ownership metadata naming a different hook'
            Why   = 'friendlyName must be this hook'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ friendlyName = 'Some-Other-Hook' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a registration whose command points somewhere the metadata does not name'
            Why   = 'the registered target must BE the recorded runtime script'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ runtimeScriptRelativePath = 'Test-Temp-Cleanup/some-other-script.ps1' } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'MISSING ownership metadata beside a live runtime'
            Why   = 'a runtime that cannot prove ownership is not evidence, however plausible its path'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -NoMetadata | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a MODIFIED manifest hash'
            Why   = 'the manifest must vouch for the bytes that would actually execute'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Metadata @{ runtimeManifest = @(@{ path = 'Test-Temp-Cleanup/Test-Temp-Cleanup.ps1'; sha256 = ('a' * 64) }) } | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest with no entry for the runtime script'
            Why   = 'an unlisted script is unverified, not verified-by-omission'
            # Every OTHER entry hashes correctly, so this can only fail on the
            # missing entry point - not on a bogus hash standing in for it.
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -ManifestOmitsRuntimeScript | Out-Null }
        }
        # ---- the registered EVENT, not merely a registration -----------------
        # Ownership proves WHOSE runtime it is; it says nothing about WHEN it
        # runs. A managed install on any non-Stop event never reaches the Stop
        # that writes the fresh 'clean' this gate waits for, so counting it as
        # installed parks the reminder behind a result that registration cannot
        # produce - the same permanently dead gate, reached from a new direction.
        [pscustomobject]@{
            Name  = 'a fully ownership-proven Claude install registered on SessionStart only'
            Why   = 'no Stop handler exists, so nothing will ever record a result for this gate to read'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -RegisteredEvent 'SessionStart' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a fully ownership-proven Kiro install whose only entry triggers on SessionStart'
            Why   = 'a Kiro file holds one entry PER trigger, so the file existing says nothing about Stop'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -RegisteredEvent 'SessionStart' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Claude registration under a lower-case "stop" key'
            Why   = 'the client matches the event key literally, so a mis-cased key fires nothing'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -RegisteredEvent 'stop' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro entry whose trigger is lower-case "stop"'
            Why   = 'KIRO_PROTOCOL.md records the triggers as confirmed exact casing'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -RegisteredEvent 'stop' | Out-Null }
        }
        # ---- the whole runtime, not just its entry point ---------------------
        # The registration names ONE file, but that file is a door, not the room:
        # Claude/Codex run <hook>.ps1 which dot-sources _hooklib.ps1, and Kiro
        # runs kiro-launch.ps1 which runs the hook which loads the same library.
        # Verifying only the named file left the entire body of executing code
        # unchecked.
        [pscustomobject]@{
            Name  = 'a library BEHIND an untouched Claude entry point, modified after the manifest'
            Why   = 'the registered script still hashes correctly; only whole-manifest verification sees this'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -TamperLibrary | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a library behind an untouched Kiro LAUNCHER, modified after the manifest'
            Why   = 'Kiro registers the launcher, so everything it goes on to run sits behind the one recorded path'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -TamperLibrary | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest entry whose path climbs out of the runtime root with ..'
            Why   = 'a manifest must not be able to vouch for a file outside the runtime it describes'
            Build = {
                param($Repo)
                New-ManagedCleanupInstall -Base $Repo -ManifestExtra @(@{ path = '../../../../elsewhere.ps1'; sha256 = ('c' * 64) }) | Out-Null
            }
        }
        # ---- the manifest must be COMPLETE, not merely internally correct -----
        # A manifest describes itself. Verifying every entry it lists says
        # nothing about what it left OUT, and an omitted dependency is not
        # merely unverified - it is never looked at. Every case below leaves the
        # remaining entries perfectly valid and sawRegistered true, so only a
        # completeness rule can reject them.
        [pscustomobject]@{
            Name  = 'a Claude manifest that simply OMITS _hooklib.ps1 while the file still sits there'
            Why   = 'the entry point dot-sources it, so dropping its entry hides the library from the check entirely'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -OmitFromManifest @('_hooklib.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro manifest that OMITS the main hook script behind the launcher'
            Why   = 'Kiro registers kiro-launch.ps1, so the hook it runs is exactly the part an omission can hide'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -OmitFromManifest @('Test-Temp-Cleanup.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a Kiro manifest that omits _hooklib.ps1 two levels behind the registration'
            Why   = 'launcher -> hook -> library: the deepest dependency is the easiest one to leave unlisted'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -Client 'kiro' -OmitFromManifest @('_hooklib.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a required dependency deleted from disk AND from the manifest'
            Why   = 'nothing on disk contradicts the manifest, so only a required set known independently catches it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -RemoveLeaf @('_hooklib.ps1') | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'an unlisted extra .ps1 sitting in the managed runtime directory'
            Why   = 'the entry point could load it and nothing verified it; no required-set check would look for it'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -UnlistedExtraFile | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest listing the same path twice, both entries hashing correctly'
            Why   = 'the installer never emits a duplicate; with a WRONG hash this would only prove the hash check'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -DuplicateEntry '_hooklib.ps1' | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a manifest longer than the writer can emit'
            Why   = 'a manifest past the install plan''s cap did not come from an install, and bounds a Stop hook''s hashing'
            Build = {
                param($Repo)
                $pad = @(1..65 | ForEach-Object { @{ path = ('Test-Temp-Cleanup/pad-' + $_ + '.ps1'); sha256 = ('d' * 64) } })
                New-ManagedCleanupInstall -Base $Repo -ManifestExtra $pad | Out-Null
            }
        }
        [pscustomobject]@{
            Name  = 'a runtime script MODIFIED after the manifest was written'
            Why   = 'this is the same check from the other side - the file changed, the recorded hash did not'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -TamperRuntime | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a registration whose runtime script is MISSING'
            Why   = 'nothing can fire, so nothing will ever record a fresh clean'
            Build = { param($Repo) New-ManagedCleanupInstall -Base $Repo -MissingRuntime | Out-Null }
        }
        [pscustomobject]@{
            Name  = 'a STALE registration left behind after uninstall'
            Why   = 'the uninstaller removes runtime + metadata; the registration alone is residue'
            Build = {
                param($Repo)
                New-ManagedCleanupInstall -Base $Repo | Out-Null
                Remove-Item -LiteralPath (Join-Path $Repo '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -Recurse -Force
            }
        }
    )
    $negativeIndex = 0
    foreach ($case in $negativeCases) {
        $negativeIndex++
        $negativeRepo = New-ReadyWorkersRepo ('CleanupNegative' + $negativeIndex)
        & $case.Build $negativeRepo
        $r = Fire -Cwd $negativeRepo
        Check ($case.Name + ' is NOT install evidence - gate skipped, decision SHOWN (' + $case.Why + ')') (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') ($r.Out + ' || ' + $r.Err)
    }

    # Two of the loop cases above deserve a note, because a reader will ask
    # whether they pass for the right reason: 'outside' and 'escape' both point a
    # command at a file that genuinely EXISTS on disk, so neither can be rejected
    # by a missing target. The red proof is the evidence - the pre-change hook
    # required Test-Path on the resolved target and ACCEPTED both, which is only
    # possible if the file was there. What rejects them now is containment.

    # A reparse-point escape is the one containment case '..' cannot express: the
    # command's target is lexically inside the runtime root, the file exists, the
    # metadata parses and the manifest hash matches - the runtime DIRECTORY is
    # just a junction to somewhere else, so the bytes that would execute are not
    # the ones the containment test approved. Junction creation needs no
    # elevation, but it needs a filesystem that supports it; if it is
    # unavailable the case is reported as skipped rather than counted as a pass.
    $junctionRepo = New-ReadyWorkersRepo 'CleanupReparseEscape'
    New-ManagedCleanupInstall -Base $junctionRepo | Out-Null
    $junctionHookDir = Join-Path $junctionRepo '.claude\hooks\Hook-Maker\Test-Temp-Cleanup'
    $junctionTarget = Join-Path $Work 'junction-target\Test-Temp-Cleanup'
    $junctionMade = $false
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $junctionTarget) -Force | Out-Null
        Move-Item -LiteralPath $junctionHookDir -Destination $junctionTarget
        New-Item -ItemType Junction -Path $junctionHookDir -Target $junctionTarget -ErrorAction Stop | Out-Null
        $junctionMade = $true
    }
    catch {
        Write-Host ('SKIPPED (junctions unavailable here): ' + $_.Exception.Message) -ForegroundColor Yellow
    }
    if ($junctionMade) {
        Check 'the junction fixture really is a reparse point holding the live runtime script' (
            (([System.IO.File]::GetAttributes($junctionHookDir)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
            (Test-Path -LiteralPath (Join-Path $junctionHookDir 'Test-Temp-Cleanup.ps1') -PathType Leaf))
        $r = Fire -Cwd $junctionRepo
        Check 'a REPARSE-POINT escape inside the runtime root is NOT install evidence - gate skipped, decision SHOWN' (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') ($r.Out + ' || ' + $r.Err)
    }

    # An UNREADABLE registration is the one negative that cannot be built from
    # file content: the document is a perfectly valid managed registration, held
    # open with FileShare.None for the duration of the Stop. Refusing to read is
    # no longer treated as proof of presence - the negative direction only costs
    # a shown decision, while the old direction silenced the reminder for as long
    # as the lock (or a corrupt file) lasted.
    $lockedRepo = New-ReadyWorkersRepo 'CleanupUnreadableRegistration'
    $lockedPath = New-ManagedCleanupInstall -Base $lockedRepo
    # THE CONTROL RUNS FIRST, and the order is not cosmetic. A silent Stop writes
    # no cooldown state, but a Stop that SHOWS the decision does - so firing the
    # locked case first would leave the "readable again" control inside the
    # cooldown window, where it would report silence for a reason that has nothing
    # to do with the gate and pass for the wrong reason.
    $r = Fire -Cwd $lockedRepo
    Check 'the control: this registration IS a valid managed install while readable (gate applies -> silent)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $lockedHandle = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $r = Fire -Cwd $lockedRepo
        Check 'the SAME registration held unreadable is NOT install evidence - gate skipped, decision SHOWN' (
            $r.Out -match 'CLOUDFLARE DEPLOY CHECK') ($r.Out + ' || ' + $r.Err)
    }
    finally { $lockedHandle.Dispose() }

    # =====================================================================
    Write-Host '--- the shared category contract is declared, not inferred ---' -ForegroundColor Cyan
    $cfText = [System.IO.File]::ReadAllText($Hook)
    $producerText = [System.IO.File]::ReadAllText((Join-Path $HooksRoot 'Test-Temp-Cleanup\Test-Temp-Cleanup.ps1'))
    $sharedList = "'clean', 'review-required', 'residue-confirmed', 'partial', 'unknown'"
    Check 'this consumer declares the full category list explicitly' ($cfText -match [regex]::Escape($sharedList)) $sharedList
    Check 'the producer declares the identical list (no silent drift)' ($producerText -match [regex]::Escape($sharedList)) $sharedList
    Check 'the consumer names the producer file in the contract comment' ($cfText -match 'Test-Temp-Cleanup\.ps1') $cfText
    Check 'only clean is treated as release-ready' ($cfText -match [regex]::Escape("CleanupReleaseReadyCategories = @('clean')")) $cfText
    Check 'the deletion-era categories are gone from this consumer' (
        $cfText -notmatch 'safe-cleaned' -and $cfText -notmatch 'review-only-preserved') $cfText
    Check 'the concurrency contract is still documented (no registration-order assumption)' (
        $cfText -match 'may run concurrently' -and $cfText -match 'never assumes') $cfText

    # =====================================================================
    Write-Host '--- ordering and structural honesty are stated in the code ---' -ForegroundColor Cyan
    # The order is a behaviour contract, not an implementation detail, so it is
    # asserted rather than left to be re-derived by the next reader.
    Check 'the hook states the ordering: prove the install BEFORE reading coordination state' (
        $cfText -match 'prove an ACTIVE MANAGED installation' -and
        $cfText -match 'only then read coordination state') $cfText
    Check 'the hook states that a coordination record is never installation evidence on its own' (
        $cfText -match 'NEVER installation evidence on its own') $cfText
    # Structural honesty: the registry cross-check is impossible from an
    # installed runtime, and the code must SAY so rather than fake one.
    Check 'the hook says why recordId is not cross-checked against the install registry' (
        $cfText -match 'install-registry\.json is unreachable' -and
        $cfText -match 'INTERNAL agreement only') $cfText
    Check 'the hook does not pretend to read the tool-root registry' (
        $cfText -notmatch 'Get-InstallRegistry' -and $cfText -notmatch 'Read-InstallRegistry') $cfText
    Check 'the retired recursive command-string walk is gone' (
        $cfText -notmatch 'Get-RegistrationCommandValues' -and
        $cfText -notmatch 'Test-CleanupCommandEvidence') $cfText

    # =====================================================================
    Write-Host '--- the client mirrors still equal the capability table ---' -ForegroundColor Cyan
    # An installed runtime is self-contained - the installer rewrites _hooklib.ps1
    # into it but copies no sibling out of scripts\ - so the per-client
    # registration locations AND runtime roots must be MIRRORED into the hook
    # rather than read from the table. That is only safe while something proves
    # each mirror still EQUALS the table: the previous runtime-root mirror went
    # stale the moment a third client was added, and a whole gate was skipped
    # silently. The runtime-root mirror is back (as a containment bound, never as
    # evidence), so it needs the same proof.
    $cfParseErrors = $null
    $cfAst = [System.Management.Automation.Language.Parser]::ParseFile($Hook, [ref]$null, [ref]$cfParseErrors)
    Check 'the hook parses with no errors' (@($cfParseErrors).Count -eq 0) (@($cfParseErrors) -join '; ')
    # Only path-shaped constants are compared: a hashtable literal's KEYS are
    # string constants too, and they are not what this mirrors.
    function Get-MirroredPaths {
        param([string]$VariableName)
        $assignments = @($cfAst.FindAll({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left.Extent.Text -eq $VariableName }, $true))
        if ($assignments.Count -ne 1) { return @('<expected exactly one assignment, found ' + $assignments.Count + '>') }
        return @($assignments[0].Right.FindAll({
            $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            ForEach-Object { $_.Value } | Where-Object { $_ -like '*\*' } | Sort-Object -Unique)
    }
    # Expected: every project+global registration FILE of every shared-settings
    # client, deduplicated (Codex uses one path for both scopes). Kiro is a
    # DIRECTORY of per-hook files and is mirrored separately.
    $tableRegs = @()
    $tableRuntimeRoots = @()
    foreach ($cfClientId in @(Get-HookMakerClientIds)) {
        $cfCap = Get-HookMakerClientCapability -ClientId $cfClientId
        $tableRuntimeRoots += @([string]$cfCap.runtimeRelativeRoot)
        if ([string]$cfCap.registrationKind -eq 'perHookFile') { continue }
        $tableRegs += @([string]$cfCap.projectRegistration, [string]$cfCap.globalRegistration)
    }
    $tableRegs = @($tableRegs | Sort-Object -Unique)
    $tableRuntimeRoots = @($tableRuntimeRoots | Sort-Object -Unique)
    $mirroredRegs = Get-MirroredPaths '$script:CleanupRegistrationFiles'
    Check 'the registration mirror equals the capability table exactly (no missing client, no stale extra)' (
        ($mirroredRegs -join '|') -eq ($tableRegs -join '|')) (
        'mirror=[' + ($mirroredRegs -join ', ') + '] table=[' + ($tableRegs -join ', ') + ']')
    $mirroredRuntimeRoots = Get-MirroredPaths '$script:CleanupRuntimeRoots'
    Check 'the RUNTIME-ROOT mirror equals the capability table exactly (the list that rotted last time)' (
        ($mirroredRuntimeRoots -join '|') -eq ($tableRuntimeRoots -join '|')) (
        'mirror=[' + ($mirroredRuntimeRoots -join ', ') + '] table=[' + ($tableRuntimeRoots -join ', ') + ']')
    $mirroredKiroDir = Get-MirroredPaths '$script:CleanupKiroRegistrationDir'
    Check 'the Kiro registration DIRECTORY mirror equals the table (per-hook files under .kiro\hooks)' (
        ($mirroredKiroDir -join '|') -eq [string](Get-HookMakerClientCapability -ClientId 'kiro').projectRegistration) (
        $mirroredKiroDir -join ', ')
    # The Kiro managed-FILENAME rule is owned by scripts\_installkiro.ps1
    # (Test-KiroManagedFileName), not by the capability table, so it is pinned
    # against that file directly.
    $kiroInstallText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '_installkiro.ps1'))
    $kiroFilePattern = '^hookmaker-[a-z0-9-]+\.json$'
    Check 'the Kiro managed-filename mirror equals the installer''s own ownership rule' (
        $cfText -match [regex]::Escape($kiroFilePattern) -and $kiroInstallText -match [regex]::Escape($kiroFilePattern)) $kiroFilePattern
    # The manifest-entry cap is a fourth mirror: the hook refuses a manifest
    # longer than the plan can emit, which is only meaningful while the two
    # numbers agree. Raise the writer's cap alone and the hook starts rejecting
    # real installs; lower it alone and the bound stops matching reality.
    $planText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '_installplan.ps1'))
    $writerCap = ([regex]::Match($planText, '\$script:RuntimeMetadataManifestCap\s*=\s*(\d+)')).Groups[1].Value
    $readerCap = ([regex]::Match($cfText, '\$script:CleanupManifestCap\s*=\s*(\d+)')).Groups[1].Value
    Check 'the manifest-entry cap mirror equals the install plan''s own writer cap' (
        $writerCap -ne '' -and $writerCap -eq $readerCap) ('writer=[' + $writerCap + '] reader=[' + $readerCap + ']')
    # A fifth mirror, and the one most likely to rot silently: the required
    # executables. If the plan starts staging a new shared artifact, a required
    # set frozen at today's two names would go on accepting a manifest that
    # omits the new one - the exact hole this check exists to close. So derive
    # what the plan ACTUALLY stages for any hook and require the hook's set to
    # match it.
    #
    # Three exclusions, each for a stated reason rather than to make the numbers
    # agree:
    #   '/'                            the fragment of the main-script expression
    #                                  ($FriendlyName + '/' + $FriendlyName +
    #                                  '.ps1'); the hook derives that name from
    #                                  its own hook-name constant.
    #   scripts/Run-Tests-Guarded.ps1  staged ONLY for Test-Run-Guard, so it is
    #                                  never part of a Test-Temp-Cleanup runtime.
    #   non-.ps1                       sync-hooks.json and SYNC-PROJECTS.txt are
    #                                  DATA staged only for the sync-engine
    #                                  hooks. This check - and the disk scan it
    #                                  backs - is deliberately about executables:
    #                                  what the entry point can LOAD. A data file
    #                                  is out of its scope, stated rather than
    #                                  silently dropped.
    $plannedLeaves = @([regex]::Matches($planText, '\$FriendlyName \+ ''/([^'']+)''') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -like '*.ps1' -and $_ -ne 'scripts/Run-Tests-Guarded.ps1' } | Sort-Object -Unique)
    $requiredAst = @($cfAst.FindAll({
                $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $args[0].Left.Extent.Text -eq '$script:CleanupRequiredRuntimeLeaves' }, $true))
    $requiredLeaves = @()
    if ($requiredAst.Count -eq 1) {
        $requiredLeaves = @($requiredAst[0].Right.FindAll({
                    $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            ForEach-Object { $_.Value } | Where-Object { $_ -like '*.ps1' } | Sort-Object -Unique)
    }
    Check 'the REQUIRED-executable mirror equals what the install plan actually stages for a hook' (
        $plannedLeaves.Count -gt 0 -and ($requiredLeaves -join '|') -eq ($plannedLeaves -join '|')) (
        'required=[' + ($requiredLeaves -join ', ') + '] planned=[' + ($plannedLeaves -join ', ') + ']')
    # ...and Kiro must require the launcher its registration names, which the
    # union above cannot show on its own.
    $kiroRequired = ''
    if ($requiredAst.Count -eq 1) {
        $kiroRequired = [string]($requiredAst[0].Right.Extent.Text -match "kiro'\s*=\s*@\([^)]*kiro-launch\.ps1")
    }
    Check 'the Kiro required set specifically includes kiro-launch.ps1' ($kiroRequired -eq 'True') $kiroRequired

    # =====================================================================
    Write-Host '--- the ownership-metadata contract has two sides that must agree ---' -ForegroundColor Cyan
    # THE PRODUCER of .hookmaker-runtime.json is the canonical install plan in
    # scripts\_installplan.ps1; THE CONSUMER is this hook. Nothing else connects
    # them - the file is written by the installer and read by a runtime that
    # cannot reach the installer - so the field names, the schema version and the
    # two registration-identity SHAPES are pinned here, in one place, exactly the
    # way the shared result-category list above is. This suite's own fixtures are
    # hand-built, so without this guard a rename on either side would leave the
    # fixtures green and every real install unrecognized.
    $planText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '_installplan.ps1'))
    Check 'both sides name the same metadata file' (
        $planText -match [regex]::Escape('.hookmaker-runtime.json') -and
        $cfText -match [regex]::Escape('.hookmaker-runtime.json')) '.hookmaker-runtime.json'
    Check 'both sides agree on schemaVersion 1' (
        $planText -match [regex]::Escape('RuntimeMetadataSchemaVersion = 1') -and
        $cfText -match [regex]::Escape("CleanupMetadataSchemaVersion = '1'")) 'schemaVersion 1'
    foreach ($metadataField in @('schemaVersion', 'recordId', 'friendlyName', 'client', 'scope',
            'projectKey', 'registrationName', 'runtimeScriptRelativePath', 'runtimeManifest')) {
        Check ('both sides use the field name "' + $metadataField + '"') (
            $planText -match [regex]::Escape('"' + $metadataField + '"') -and
            $cfText -match [regex]::Escape("'" + $metadataField + "'")) $metadataField
    }
    Check 'the producer records the Kiro registration identity as an entry-name PREFIX (not one entry name)' (
        $planText -match [regex]::Escape('(Get-KiroManagedNamePrefix -ManagedId $RecordId) + (ConvertTo-KiroSlug -Text $FriendlyName)')) $planText
    Check 'the producer records the Claude/Codex registration identity as the managed runtime segment pair' (
        $planText -match [regex]::Escape("('Hook-Maker/' + `$FriendlyName)")) $planText
    Check 'the producer hashes the project key with the same Normalize-Path/Get-ShortHash pair this consumer recomputes' (
        $planText -match [regex]::Escape('Get-ShortHash ((Normalize-Path $ProjectRoot).ToLowerInvariant())') -and
        $cfText -match [regex]::Escape('Get-ShortHash (Normalize-Path $Root).ToLowerInvariant()')) 'projectKey derivation'
    Check 'the producer records manifest hashes in lower-case hex (this consumer compares case-insensitively anyway)' (
        $planText -match 'ToLowerInvariant\(\)' -and $cfText -match [regex]::Escape('[0-9a-fA-F]{64}')) 'sha256 casing'

