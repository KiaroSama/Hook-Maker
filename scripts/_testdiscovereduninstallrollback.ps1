# Dot-sourced scenario block of Test-DiscoveredUninstall.ps1: failure
# injection and rollback proofs - an injected settings write failure restores
# every artifact byte-for-byte, an injected registry write failure rolls a
# native removal back, -WhatIf proves record-removal ordering, a record
# missing fingerprint context is refused by the SHARED validator, a partial
# match under the settings lock removes NOTHING, a second-client failure
# restores the already-published first client's file, and the ordinary
# multi-client removal still succeeds (over-rejection guard).
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-DiscoveredUninstall.ps1
# instead.

    # =======================================================================
    Write-Host '--- injected settings write failure rolls everything back ---' -ForegroundColor Cyan
    $p9 = New-Proj 'P9SettingsFail'
    $p9Mine = Join-Path $p9 '.claude\hooks\mine.ps1'
    Write-Utf8 $p9Mine "exit 0`n"
    $p9Settings = Join-Path $p9 '.claude\settings.local.json'
    Write-Utf8 $p9Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p9Mine) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p9Prints = Get-HandlerPrints -SettingsPath $p9Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-settingsfail' -HookType 'ClaudeRegistration' -TargetProjectRoot $p9 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p9Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p9Prints.Handler) -MatcherFingerprints @($p9Prints.Matcher) -ParsedTargets @($p9Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p9Mine -ReferencedBy @('disc-settingsfail'))))
    )
    $p9SettingsBytes = Get-BytesOrEmpty $p9Settings
    $p9MineBytes = Get-BytesOrEmpty $p9Mine
    # Injection: a read-only settings file makes the atomic publish fail AFTER
    # the runtime has already been staged aside - the exact window the rollback
    # exists for.
    Set-ItemProperty -LiteralPath $p9Settings -Name IsReadOnly -Value $true
    try {
        $r = Invoke-DiscoveredUninstall -RecordId 'disc-settingsfail'
        Check 'settings fail: the run does NOT report success' ($null -ne $r.Result -and [string]$r.Result.overall -ne 'ok') ($r.Out + $r.Err)
        Check 'settings fail: the runtime file was restored byte-for-byte' (Test-BytesEqual $p9MineBytes (Get-BytesOrEmpty $p9Mine))
        Check 'settings fail: the settings file is byte-for-byte unchanged' (Test-BytesEqual $p9SettingsBytes (Get-BytesOrEmpty $p9Settings))
        Check 'settings fail: the registry record is retained' ($null -ne (Get-RegistryRecord 'disc-settingsfail'))
    }
    finally {
        Set-ItemProperty -LiteralPath $p9Settings -Name IsReadOnly -Value $false
        Get-ChildItem -LiteralPath (Split-Path -Parent $p9Settings) -Filter '*.backup-*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # =======================================================================
    Write-Host '--- injected registry write failure rolls a native removal back ---' -ForegroundColor Cyan
    $repo4 = New-Proj 'Repo4RegFail'
    $repo4Hooks = Join-Path $repo4 '.git\hooks'
    New-Item -ItemType Directory -Path $repo4Hooks -Force | Out-Null
    $repo4Hook = Join-Path $repo4Hooks 'pre-commit'
    Write-Utf8 $repo4Hook "#!/bin/sh`necho external`n"
    $repo4Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo4; hooksPath = $repo4Hooks; hookName = 'pre-commit'; hookPath = $repo4Hook
        hookHash = (Get-FileSha256Hex -Path $repo4Hook); hookSize = 0; hookModifiedUtc = '2026-01-01T00:00:00.0000000Z'
        classification = 'externalNativeHook'; managedStages = @()
    }
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-regfail' -HookType 'NativeGitHook' -TargetProjectRoot $repo4 `
            -NativeGit $repo4Native -RemovalPolicy 'nativeFileOnly')
    )
    $repo4Bytes = Get-BytesOrEmpty $repo4Hook
    # Injection: hold the registry's own exclusive lock for the whole child run.
    # A read-only registry file would NOT do it - the atomic writer replaces the
    # file wholesale and overwrites the attribute - whereas an unavailable lock
    # is a real persistence failure, and it lands AFTER the native hook has
    # already been staged aside, which is the window the rollback exists for.
    $lockPath = Join-Path $IsolatedStateDir 'install-registry.lock'
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $r = Invoke-DiscoveredUninstall -RecordId 'disc-regfail'
        Check 'registry fail: the run does NOT report success' ($null -ne $r.Result -and [string]$r.Result.overall -ne 'ok') ($r.Out + $r.Err)
        Check 'registry fail: the native hook was restored byte-for-byte' (Test-BytesEqual $repo4Bytes (Get-BytesOrEmpty $repo4Hook))
    }
    finally {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    Check 'registry fail: the record is still tracked' ($null -ne (Get-RegistryRecord 'disc-regfail'))

    # =======================================================================
    Write-Host '--- the record is removed only AFTER the cleanup it authorized ---' -ForegroundColor Cyan
    # Proven by the -WhatIf path: every proof runs, the result says it WOULD
    # remove, and neither the artifact nor the record actually moves.
    $whatIfBytes = Get-BytesOrEmpty $repo4Hook
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-regfail' -WhatIf
    Check 'whatif: the run reports ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'whatif: the result is marked as a dry run' ($null -ne $r.Result -and $r.Result.dryRun -eq $true)
    Check 'whatif: the native hook is byte-for-byte unchanged' (Test-BytesEqual $whatIfBytes (Get-BytesOrEmpty $repo4Hook))
    Check 'whatif: the registry record still exists' ($null -ne (Get-RegistryRecord 'disc-regfail'))

    # A real run of the same record now succeeds, proving the ordering: the
    # record disappears only once the artifact it authorized really came off.
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-regfail'
    Check 'ordering: the real run reports ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'ordering: the artifact is gone' (-not (Test-Path -LiteralPath $repo4Hook))
    Check 'ordering: and only then is the record gone' ($null -eq (Get-RegistryRecord 'disc-regfail'))

    # =======================================================================
    # The SHARED validator in _installregistry.ps1 - not a local re-definition -
    # is what gates every mutation. A record missing its matcher-fingerprint or
    # event arrays is exactly the tampering a weaker local copy would wave
    # through: the later event/matcher context check only fires when the
    # corresponding persisted set is non-empty, so an absent set would silently
    # disable it right before a delete.
    Write-Host '--- a record missing fingerprint context is refused outright ---' -ForegroundColor Cyan
    foreach ($case in @(
        @{ Id = 'disc-nomatcher'; Field = 'matcherFingerprints'; Label = 'matcher fingerprints' },
        @{ Id = 'disc-noevents'; Field = 'events'; Label = 'events' }
    )) {
        $pv = New-Proj ('PV' + $case.Field)
        $pvMine = Join-Path $pv '.claude\hooks\mine.ps1'
        Write-Utf8 $pvMine "exit 0`n"
        $pvSettings = Join-Path $pv '.claude\settings.local.json'
        Write-Utf8 $pvSettings (([pscustomobject]@{
            hooks = [pscustomobject]@{
                SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                    [pscustomobject]@{ type = 'command'; command = (New-CommandFor $pvMine) }) })
            }
        }) | ConvertTo-Json -Depth 20)
        $pvPrints = Get-HandlerPrints -SettingsPath $pvSettings -EventName 'SessionStart'
        $pvEvidence = New-ClientEvidence -Client 'claude' -SettingsPath $pvSettings -Events @('SessionStart') `
            -HandlerFingerprints @($pvPrints.Handler) -MatcherFingerprints @($pvPrints.Matcher) -ParsedTargets @($pvMine)
        # Tampering: the whole field is stripped from the persisted evidence.
        $pvEvidence.PSObject.Properties.Remove($case.Field)
        Set-Registry @(
            (New-DiscoveredRecord -Id $case.Id -HookType 'ClaudeRegistration' -TargetProjectRoot $pv `
                -Clients @($pvEvidence) -RuntimeArtifacts @((New-RuntimeArtifact -Path $pvMine -ReferencedBy @($case.Id))))
        )
        $pvSettingsBytes = Get-BytesOrEmpty $pvSettings
        $pvMineBytes = Get-BytesOrEmpty $pvMine
        $r = Invoke-DiscoveredUninstall -RecordId $case.Id
        Check ('shared validator: a record with no ' + $case.Label + ' is refused as invalid') `
            ((Get-ComponentReason $r.Result 'registry') -eq 'recordInvalid') ($r.Out + $r.Err)
        Check ('shared validator: the refusal names the missing field ' + $case.Field) `
            ((Get-ComponentMessage $r.Result 'registry') -like ('*' + $case.Field + '*')) (Get-ComponentMessage $r.Result 'registry')
        Check ('shared validator: overall is manualRepair for a missing ' + $case.Label) `
            ($null -ne $r.Result -and [string]$r.Result.overall -eq 'manualRepair')
        Check ('shared validator: the settings file is byte-for-byte unchanged (' + $case.Field + ')') `
            (Test-BytesEqual $pvSettingsBytes (Get-BytesOrEmpty $pvSettings))
        Check ('shared validator: the runtime file is byte-for-byte unchanged (' + $case.Field + ')') `
            (Test-BytesEqual $pvMineBytes (Get-BytesOrEmpty $pvMine))
        Check ('shared validator: the record is retained (' + $case.Field + ')') ($null -ne (Get-RegistryRecord $case.Id))
    }

    # =======================================================================
    # PARTIAL removal must never read as success. The record owns two handlers;
    # one of them is edited in the window between the read-only verification
    # pass and the settings lock. Removing the one that still matches and
    # reporting ok would leave the edited one live while the runtime cleanup
    # proceeded on evidence that is provably stale.
    Write-Host '--- a partial match under the lock removes NOTHING ---' -ForegroundColor Cyan
    $p10 = New-Proj 'P10Partial'
    $p10A = Join-Path $p10 '.claude\hooks\a.ps1'
    $p10B = Join-Path $p10 '.claude\hooks\b.ps1'
    Write-Utf8 $p10A "exit 0`n"
    Write-Utf8 $p10B "exit 0`n"
    $p10Settings = Join-Path $p10 '.claude\settings.local.json'
    $p10Original = ([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p10A); timeout = 60 },
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p10B); timeout = 60 }) })
        }
    }) | ConvertTo-Json -Depth 20
    Write-Utf8 $p10Settings $p10Original
    $p10PrintsA = Get-HandlerPrints -SettingsPath $p10Settings -EventName 'SessionStart' -HandlerIndex 0
    $p10PrintsB = Get-HandlerPrints -SettingsPath $p10Settings -EventName 'SessionStart' -HandlerIndex 1
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-partial' -HookType 'ClaudeRegistration' -TargetProjectRoot $p10 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p10Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p10PrintsA.Handler, $p10PrintsB.Handler) `
                -MatcherFingerprints @($p10PrintsA.Matcher) -ParsedTargets @($p10A, $p10B))) `
            -RuntimeArtifacts @(
                (New-RuntimeArtifact -Path $p10A -ReferencedBy @('disc-partial')),
                (New-RuntimeArtifact -Path $p10B -ReferencedBy @('disc-partial'))))
    )
    $p10ABytes = Get-BytesOrEmpty $p10A
    $p10BBytes = Get-BytesOrEmpty $p10B
    # Injection: hold the child's own per-settings-file lock, wait for the child
    # to finish verifying and stage its runtime aside, edit ONE of the two
    # handlers, then release. The child then re-fingerprints under the lock and
    # finds one of its two verified identities gone.
    $p10LockPath = $p10Settings + '.hookmaker-lock'
    $p10Lock = [System.IO.File]::Open($p10LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $p10Staged = $false
    $p10EditedBytes = $null
    try {
        $r = Invoke-DiscoveredUninstall -RecordId 'disc-partial' -WhileRunning {
            $script:p10Staged = Wait-ForSetAside -Directory (Split-Path -Parent $p10A)
            Write-Utf8 $p10Settings ((([pscustomobject]@{
                hooks = [pscustomobject]@{
                    SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                        [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p10A); timeout = 60 },
                        [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p10B); timeout = 999 }) })
                }
            }) | ConvertTo-Json -Depth 20))
            $script:p10EditedBytes = Get-BytesOrEmpty $p10Settings
            $p10Lock.Dispose()
        }
    }
    finally {
        try { $p10Lock.Dispose() } catch { }
        Remove-Item -LiteralPath $p10LockPath -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Split-Path -Parent $p10Settings) -Filter '*.backup-*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Check 'partial: the injection really landed in the verification->lock window' $script:p10Staged
    Check 'partial: the run does NOT report success' ($null -ne $r.Result -and [string]$r.Result.overall -ne 'ok') ($r.Out + $r.Err)
    Check 'partial: the claude component reports a settings write failure' `
        ((Get-ComponentReason $r.Result 'claude') -eq 'settingsWriteFailed') (Get-ComponentReason $r.Result 'claude')
    Check 'partial: the failure names the exact mismatch, not a bare "changed"' `
        ((Get-ComponentMessage $r.Result 'claude') -like '*1 of 2 verified handler(s)*') (Get-ComponentMessage $r.Result 'claude')
    Check 'partial: the settings file is byte-for-byte what the injection left' `
        (Test-BytesEqual $script:p10EditedBytes (Get-BytesOrEmpty $p10Settings))
    $p10Live = [System.IO.File]::ReadAllText($p10Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'partial: BOTH handlers survive - not just the edited one' (@(@($p10Live.hooks.SessionStart)[0].hooks).Count -eq 2)
    Check 'partial: the first runtime file was restored byte-for-byte' (Test-BytesEqual $p10ABytes (Get-BytesOrEmpty $p10A))
    Check 'partial: the second runtime file was restored byte-for-byte' (Test-BytesEqual $p10BBytes (Get-BytesOrEmpty $p10B))
    Check 'partial: no set-aside was left behind' `
        (@(Get-ChildItem -LiteralPath (Split-Path -Parent $p10A) -Filter '*.hookmaker-disc-setaside-*' -File -ErrorAction SilentlyContinue).Count -eq 0)
    Check 'partial: the registry record is retained' ($null -ne (Get-RegistryRecord 'disc-partial'))

    # =======================================================================
    # Two clients, published as two separate files. The first write succeeds and
    # the second fails, so the first client's registration is already gone by
    # the time the failure is known - the case where "everything was restored"
    # used to be a false claim. Option (a) was implemented: every settings file
    # this run intends to write is copied aside up front and any published one
    # is put back, so the guarantee asserted here is byte-identity.
    Write-Host '--- a second-client failure restores the FIRST client''s file ---' -ForegroundColor Cyan
    $p11 = New-Proj 'P11MultiFail'
    $p11ClaudeTarget = Join-Path $p11 '.claude\hooks\claude.ps1'
    $p11CodexTarget = Join-Path $p11 '.codex\hooks\codex.ps1'
    Write-Utf8 $p11ClaudeTarget "exit 0`n"
    Write-Utf8 $p11CodexTarget "exit 0`n"
    $p11ClaudeSettings = Join-Path $p11 '.claude\settings.local.json'
    $p11CodexSettings = Join-Path $p11 '.codex\hooks.json'
    Write-Utf8 $p11ClaudeSettings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p11ClaudeTarget) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    Write-Utf8 $p11CodexSettings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            UserPromptSubmit = @([pscustomobject]@{ hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p11CodexTarget) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p11ClaudePrints = Get-HandlerPrints -SettingsPath $p11ClaudeSettings -EventName 'SessionStart'
    $p11CodexPrints = Get-HandlerPrints -SettingsPath $p11CodexSettings -EventName 'UserPromptSubmit'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-multifail' -HookType 'ClaudeRegistration' -TargetProjectRoot $p11 `
            -Clients @(
                (New-ClientEvidence -Client 'claude' -SettingsPath $p11ClaudeSettings -Events @('SessionStart') `
                    -HandlerFingerprints @($p11ClaudePrints.Handler) -MatcherFingerprints @($p11ClaudePrints.Matcher) -ParsedTargets @($p11ClaudeTarget)),
                (New-ClientEvidence -Client 'codex' -SettingsPath $p11CodexSettings -Events @('UserPromptSubmit') `
                    -HandlerFingerprints @($p11CodexPrints.Handler) -MatcherFingerprints @($p11CodexPrints.Matcher) -ParsedTargets @($p11CodexTarget))) `
            -RuntimeArtifacts @(
                (New-RuntimeArtifact -Path $p11ClaudeTarget -ReferencedBy @('disc-multifail')),
                (New-RuntimeArtifact -Path $p11CodexTarget -ReferencedBy @('disc-multifail'))))
    )
    $p11ClaudeBytes = Get-BytesOrEmpty $p11ClaudeSettings
    $p11CodexBytes = Get-BytesOrEmpty $p11CodexSettings
    $p11ClaudeTargetBytes = Get-BytesOrEmpty $p11ClaudeTarget
    # Injection: the SECOND client's file cannot be replaced, so its publish
    # fails after the first client's has already been committed.
    Set-ItemProperty -LiteralPath $p11CodexSettings -Name IsReadOnly -Value $true
    try {
        $r = Invoke-DiscoveredUninstall -RecordId 'disc-multifail'
        Check 'multi fail: the run does NOT report success' ($null -ne $r.Result -and [string]$r.Result.overall -ne 'ok') ($r.Out + $r.Err)
        Check 'multi fail: the codex component is the reported failure' `
            ((Get-ComponentReason $r.Result 'codex') -eq 'settingsWriteFailed') (Get-ComponentReason $r.Result 'codex')
        Check 'multi fail: the ALREADY-PUBLISHED claude settings file is byte-for-byte unchanged' `
            (Test-BytesEqual $p11ClaudeBytes (Get-BytesOrEmpty $p11ClaudeSettings))
        Check 'multi fail: the codex settings file is byte-for-byte unchanged' `
            (Test-BytesEqual $p11CodexBytes (Get-BytesOrEmpty $p11CodexSettings))
        Check 'multi fail: the staged runtime file was restored byte-for-byte' `
            (Test-BytesEqual $p11ClaudeTargetBytes (Get-BytesOrEmpty $p11ClaudeTarget))
        # The message may only claim a full restoration because one really
        # happened; if any restore had failed the run would report which client.
        Check 'multi fail: the report claims a full restoration and it is true' `
            ($r.Out -like '*Every artifact was restored; nothing was removed.*') $r.Out
        Check 'multi fail: no snapshot copy was left behind' `
            (@(Get-ChildItem -LiteralPath $p11 -Recurse -Filter '*.hookmaker-disc-snapshot-*' -File -ErrorAction SilentlyContinue).Count -eq 0)
        Check 'multi fail: the registry record is retained' ($null -ne (Get-RegistryRecord 'disc-multifail'))
    }
    finally {
        Set-ItemProperty -LiteralPath $p11CodexSettings -Name IsReadOnly -Value $false
        Get-ChildItem -LiteralPath $p11 -Recurse -Filter '*.backup-*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # =======================================================================
    # Over-rejection guard: the snapshot/rollback machinery and the exact-set
    # match must not break the ordinary multi-client removal they wrap.
    Write-Host '--- a normal multi-client discovered uninstall still succeeds ---' -ForegroundColor Cyan
    $p12 = New-Proj 'P12MultiOk'
    $p12ClaudeTarget = Join-Path $p12 '.claude\hooks\claude.ps1'
    $p12CodexTarget = Join-Path $p12 '.codex\hooks\codex.ps1'
    Write-Utf8 $p12ClaudeTarget "exit 0`n"
    Write-Utf8 $p12CodexTarget "exit 0`n"
    $p12ClaudeSettings = Join-Path $p12 '.claude\settings.local.json'
    $p12CodexSettings = Join-Path $p12 '.codex\hooks.json'
    Write-Utf8 $p12ClaudeSettings (([pscustomobject]@{
        permissions = [pscustomobject]@{ allow = @('Bash(git:*)') }
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p12ClaudeTarget) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    Write-Utf8 $p12CodexSettings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            UserPromptSubmit = @([pscustomobject]@{ hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p12CodexTarget) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p12ClaudePrints = Get-HandlerPrints -SettingsPath $p12ClaudeSettings -EventName 'SessionStart'
    $p12CodexPrints = Get-HandlerPrints -SettingsPath $p12CodexSettings -EventName 'UserPromptSubmit'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-multiok' -HookType 'ClaudeRegistration' -TargetProjectRoot $p12 `
            -Clients @(
                (New-ClientEvidence -Client 'claude' -SettingsPath $p12ClaudeSettings -Events @('SessionStart') `
                    -HandlerFingerprints @($p12ClaudePrints.Handler) -MatcherFingerprints @($p12ClaudePrints.Matcher) -ParsedTargets @($p12ClaudeTarget)),
                (New-ClientEvidence -Client 'codex' -SettingsPath $p12CodexSettings -Events @('UserPromptSubmit') `
                    -HandlerFingerprints @($p12CodexPrints.Handler) -MatcherFingerprints @($p12CodexPrints.Matcher) -ParsedTargets @($p12CodexTarget))) `
            -RuntimeArtifacts @(
                (New-RuntimeArtifact -Path $p12ClaudeTarget -ReferencedBy @('disc-multiok')),
                (New-RuntimeArtifact -Path $p12CodexTarget -ReferencedBy @('disc-multiok'))))
    )
    $p12ShapeBefore = Get-SettingsShapeExcept -Path $p12ClaudeSettings -ExceptEvent 'SessionStart'
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-multiok'
    Check 'multi ok: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'multi ok: the claude component is ok' ((Get-ComponentStatus $r.Result 'claude') -eq 'ok')
    Check 'multi ok: the codex component is ok' ((Get-ComponentStatus $r.Result 'codex') -eq 'ok')
    $p12ClaudeAfter = [System.IO.File]::ReadAllText($p12ClaudeSettings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $p12CodexAfter = [System.IO.File]::ReadAllText($p12CodexSettings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'multi ok: the claude registration is gone' ($null -eq $p12ClaudeAfter.hooks.PSObject.Properties['SessionStart'])
    Check 'multi ok: the codex registration is gone' ($null -eq $p12CodexAfter.hooks.PSObject.Properties['UserPromptSubmit'])
    Check 'multi ok: unrelated claude settings content is structurally identical' `
        ((Get-SettingsShapeExcept -Path $p12ClaudeSettings -ExceptEvent 'SessionStart') -eq $p12ShapeBefore)
    Check 'multi ok: both exclusive entrypoints were removed' `
        ((-not (Test-Path -LiteralPath $p12ClaudeTarget)) -and (-not (Test-Path -LiteralPath $p12CodexTarget)))
    Check 'multi ok: no snapshot copy was left behind' `
        (@(Get-ChildItem -LiteralPath $p12 -Recurse -Filter '*.hookmaker-disc-snapshot-*' -File -ErrorAction SilentlyContinue).Count -eq 0)
    Check 'multi ok: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-multiok'))
    Get-ChildItem -LiteralPath $p12 -Recurse -Filter '*.backup-*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
