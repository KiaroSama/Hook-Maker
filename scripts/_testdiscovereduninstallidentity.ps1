# Dot-sourced scenario block of Test-DiscoveredUninstall.ps1: exact-identity
# removal and preservation proofs - exact Claude/Codex handler fingerprint
# removal (and only that), a CHANGED handler blocking everything with zero
# mutation, same-basename-different-path survival, shared/out-of-boundary/
# non-entrypoint/tool-root runtime targets preserved while the registration
# still comes off, exact external native Git hook removal, drifted native
# evidence retained, wrapper delegation to the managed uninstaller, and the
# managed-record routing refusal.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-DiscoveredUninstall.ps1
# instead.

    # =======================================================================
    Write-Host '--- exact Claude handler fingerprint removal ---' -ForegroundColor Cyan
    $p1 = New-Proj 'P1Claude'
    $p1Mine = Join-Path $p1 '.claude\hooks\mine.ps1'
    $p1Foreign = Join-Path $p1 '.claude\hooks\foreign.ps1'
    Write-Utf8 $p1Mine "exit 0`n"
    Write-Utf8 $p1Foreign "exit 0`n"
    $p1Settings = Join-Path $p1 '.claude\settings.local.json'
    $p1Doc = [pscustomobject]@{
        permissions = [pscustomobject]@{ allow = @('Bash(git:*)') }
        hooks = [pscustomobject]@{
            SessionStart = @(
                [pscustomobject]@{ matcher = 'startup|resume'; hooks = @(
                    [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p1Mine); timeout = 60 },
                    [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p1Foreign); timeout = 30 }
                ) }
            )
            Stop = @([pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = 'echo done' }) })
        }
        someOtherTool = [pscustomobject]@{ keep = $true }
    }
    Write-Utf8 $p1Settings ($p1Doc | ConvertTo-Json -Depth 20)
    $p1Prints = Get-HandlerPrints -SettingsPath $p1Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-claude-1' -HookType 'ClaudeRegistration' -TargetProjectRoot $p1 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p1Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p1Prints.Handler) -MatcherFingerprints @($p1Prints.Matcher) -ParsedTargets @($p1Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p1Mine -ReferencedBy @('disc-claude-1'))))
    )
    $p1ShapeBefore = Get-SettingsShapeExcept -Path $p1Settings -ExceptEvent 'SessionStart'
    $p1ForeignBytes = Get-BytesOrEmpty $p1Foreign

    $r = Invoke-DiscoveredUninstall -RecordId 'disc-claude-1'
    Check 'claude: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'claude: the claude component is ok' ((Get-ComponentStatus $r.Result 'claude') -eq 'ok')
    $p1After = [System.IO.File]::ReadAllText($p1Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $p1Remaining = @(@($p1After.hooks.SessionStart)[0].hooks)
    Check 'claude: exactly one handler remains in the matcher group' ($p1Remaining.Count -eq 1)
    Check 'claude: the surviving handler is the FOREIGN one' ([string]$p1Remaining[0].command -eq (New-CommandFor $p1Foreign)) ([string]$p1Remaining[0].command)
    Check 'claude: the foreign handler kept its own timeout field' ([int]$p1Remaining[0].timeout -eq 30)
    Check 'claude: every unrelated part of the settings file is structurally identical' `
        ((Get-SettingsShapeExcept -Path $p1Settings -ExceptEvent 'SessionStart') -eq $p1ShapeBefore)
    Check 'claude: the foreign runtime file is byte-for-byte unchanged' (Test-BytesEqual $p1ForeignBytes (Get-BytesOrEmpty $p1Foreign))
    # Exclusive, verified, inside .claude\hooks -> this one IS removable.
    Check 'claude: the exclusive verified entrypoint under .claude\hooks was removed' (-not (Test-Path -LiteralPath $p1Mine))
    Check 'claude: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-claude-1'))

    # =======================================================================
    Write-Host '--- exact Codex handler fingerprint removal ---' -ForegroundColor Cyan
    $p2 = New-Proj 'P2Codex'
    $p2Mine = Join-Path $p2 '.codex\hooks\mine.ps1'
    Write-Utf8 $p2Mine "exit 0`n"
    $p2Settings = Join-Path $p2 '.codex\hooks.json'
    Write-Utf8 $p2Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            UserPromptSubmit = @([pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = (New-CommandFor $p2Mine) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p2Prints = Get-HandlerPrints -SettingsPath $p2Settings -EventName 'UserPromptSubmit'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-codex-1' -HookType 'CodexRegistration' -TargetProjectRoot $p2 `
            -Clients @((New-ClientEvidence -Client 'codex' -SettingsPath $p2Settings -Events @('UserPromptSubmit') `
                -HandlerFingerprints @($p2Prints.Handler) -MatcherFingerprints @($p2Prints.Matcher) -ParsedTargets @($p2Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p2Mine -ReferencedBy @('disc-codex-1'))))
    )
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-codex-1'
    Check 'codex: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    $p2After = [System.IO.File]::ReadAllText($p2Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'codex: the emptied event key was pruned' ($null -eq $p2After.hooks.PSObject.Properties['UserPromptSubmit'])
    Check 'codex: the exclusive verified entrypoint under .codex\hooks was removed' (-not (Test-Path -LiteralPath $p2Mine))
    Check 'codex: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-codex-1'))

    # =======================================================================
    Write-Host '--- a CHANGED handler fingerprint blocks everything ---' -ForegroundColor Cyan
    $p3 = New-Proj 'P3Changed'
    $p3Mine = Join-Path $p3 '.claude\hooks\mine.ps1'
    Write-Utf8 $p3Mine "exit 0`n"
    $p3Settings = Join-Path $p3 '.claude\settings.local.json'
    Write-Utf8 $p3Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p3Mine); timeout = 60 }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p3Prints = Get-HandlerPrints -SettingsPath $p3Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-changed' -HookType 'ClaudeRegistration' -TargetProjectRoot $p3 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p3Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p3Prints.Handler) -MatcherFingerprints @($p3Prints.Matcher) -ParsedTargets @($p3Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p3Mine -ReferencedBy @('disc-changed'))))
    )
    # The handler is edited AFTER the record was written - exactly the drift the
    # remover must refuse to act on.
    Write-Utf8 $p3Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p3Mine); timeout = 120 }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p3SettingsBytes = Get-BytesOrEmpty $p3Settings
    $p3MineBytes = Get-BytesOrEmpty $p3Mine

    $r = Invoke-DiscoveredUninstall -RecordId 'disc-changed'
    Check 'changed: the run reports manualRepair' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'manualRepair') ($r.Out + $r.Err)
    Check 'changed: the claude component reports evidenceChanged' ((Get-ComponentReason $r.Result 'claude') -eq 'evidenceChanged')
    Check 'changed: the settings file is byte-for-byte unchanged' (Test-BytesEqual $p3SettingsBytes (Get-BytesOrEmpty $p3Settings))
    Check 'changed: the runtime file is byte-for-byte unchanged' (Test-BytesEqual $p3MineBytes (Get-BytesOrEmpty $p3Mine))
    $p3Record = Get-RegistryRecord 'disc-changed'
    Check 'changed: the registry record is retained' ($null -ne $p3Record)
    Check 'changed: the retained record is flagged for manual repair' ($null -ne $p3Record -and $p3Record.needsManualRepair -eq $true)

    # =======================================================================
    Write-Host '--- the same basename at a different path survives ---' -ForegroundColor Cyan
    $p4 = New-Proj 'P4Basename'
    $p4Mine = Join-Path $p4 '.claude\hooks\check.ps1'
    $p4Other = Join-Path $p4 '.claude\hooks\sub\check.ps1'
    Write-Utf8 $p4Mine "exit 0`n"
    Write-Utf8 $p4Other "exit 1`n"
    $p4Settings = Join-Path $p4 '.claude\settings.local.json'
    Write-Utf8 $p4Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p4Mine) },
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p4Other) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p4Prints = Get-HandlerPrints -SettingsPath $p4Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-basename' -HookType 'ClaudeRegistration' -TargetProjectRoot $p4 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p4Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p4Prints.Handler) -MatcherFingerprints @($p4Prints.Matcher) -ParsedTargets @($p4Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p4Mine -ReferencedBy @('disc-basename'))))
    )
    $p4OtherBytes = Get-BytesOrEmpty $p4Other
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-basename'
    Check 'basename: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    $p4After = [System.IO.File]::ReadAllText($p4Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $p4Remaining = @(@($p4After.hooks.SessionStart)[0].hooks)
    Check 'basename: the same-named handler at the other path survives' `
        ($p4Remaining.Count -eq 1 -and [string]$p4Remaining[0].command -eq (New-CommandFor $p4Other)) ([string]$p4Remaining[0].command)
    Check 'basename: the same-named file at the other path is byte-for-byte unchanged' (Test-BytesEqual $p4OtherBytes (Get-BytesOrEmpty $p4Other))
    Check 'basename: only the recorded target was removed' (-not (Test-Path -LiteralPath $p4Mine))

    # =======================================================================
    Write-Host '--- a shared runtime target is preserved ---' -ForegroundColor Cyan
    $p5 = New-Proj 'P5Shared'
    $p5Shared = Join-Path $p5 '.claude\hooks\shared.ps1'
    Write-Utf8 $p5Shared "exit 0`n"
    $p5Settings = Join-Path $p5 '.claude\settings.local.json'
    Write-Utf8 $p5Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p5Shared); timeout = 60 },
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p5Shared); timeout = 90 }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p5Prints = Get-HandlerPrints -SettingsPath $p5Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-shared' -HookType 'ClaudeRegistration' -TargetProjectRoot $p5 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p5Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p5Prints.Handler) -MatcherFingerprints @($p5Prints.Matcher) -ParsedTargets @($p5Shared))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p5Shared -ReferencedBy @('disc-shared'))))
    )
    $p5SharedBytes = Get-BytesOrEmpty $p5Shared
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-shared'
    Check 'shared: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'shared: the runtime component reports registration removed, runtime preserved' `
        ((Get-ComponentReason $r.Result 'runtime') -eq 'registrationRemovedRuntimePreserved') (Get-ComponentReason $r.Result 'runtime')
    Check 'shared: the still-referenced runtime file is byte-for-byte unchanged' (Test-BytesEqual $p5SharedBytes (Get-BytesOrEmpty $p5Shared))
    $p5After = [System.IO.File]::ReadAllText($p5Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'shared: the other registration of the same file survives' (@(@($p5After.hooks.SessionStart)[0].hooks).Count -eq 1)

    # =======================================================================
    Write-Host '--- a target outside any recognized hook root is registration-only ---' -ForegroundColor Cyan
    $p6 = New-Proj 'P6Outside'
    $p6Outside = Join-Path $p6 'tools\outside.ps1'
    Write-Utf8 $p6Outside "exit 0`n"
    $p6Settings = Join-Path $p6 '.claude\settings.local.json'
    Write-Utf8 $p6Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p6Outside) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p6Prints = Get-HandlerPrints -SettingsPath $p6Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-outside' -HookType 'ClaudeRegistration' -TargetProjectRoot $p6 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p6Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p6Prints.Handler) -MatcherFingerprints @($p6Prints.Matcher) -ParsedTargets @($p6Outside))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p6Outside -ReferencedBy @('disc-outside'))))
    )
    $p6OutsideBytes = Get-BytesOrEmpty $p6Outside
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-outside'
    Check 'outside: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'outside: the registration was removed but the runtime preserved' `
        ((Get-ComponentReason $r.Result 'runtime') -eq 'registrationRemovedRuntimePreserved')
    Check 'outside: the out-of-boundary file is byte-for-byte unchanged' (Test-BytesEqual $p6OutsideBytes (Get-BytesOrEmpty $p6Outside))
    $p6After = [System.IO.File]::ReadAllText($p6Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'outside: the registration really is gone' ($null -eq $p6After.hooks.PSObject.Properties['SessionStart'])
    Check 'outside: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-outside'))

    # =======================================================================
    Write-Host '--- an orphan helper is never deleted ---' -ForegroundColor Cyan
    $p7 = New-Proj 'P7Orphan'
    $p7Entry = Join-Path $p7 '.claude\hooks\entry.ps1'
    $p7Helper = Join-Path $p7 '.claude\hooks\helper.ps1'
    Write-Utf8 $p7Entry "exit 0`n"
    Write-Utf8 $p7Helper "exit 0`n"
    $p7Settings = Join-Path $p7 '.claude\settings.local.json'
    Write-Utf8 $p7Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p7Entry) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p7Prints = Get-HandlerPrints -SettingsPath $p7Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-orphan' -HookType 'ClaudeRegistration' -TargetProjectRoot $p7 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p7Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p7Prints.Handler) -MatcherFingerprints @($p7Prints.Matcher) -ParsedTargets @($p7Entry, $p7Helper))) `
            -RuntimeArtifacts @(
                (New-RuntimeArtifact -Path $p7Entry -ReferencedBy @('disc-orphan')),
                (New-RuntimeArtifact -Path $p7Helper -Kind 'helper' -Classification 'orphanRuntimeCandidate' -ReferencedBy @('disc-orphan'))
            ))
    )
    $p7HelperBytes = Get-BytesOrEmpty $p7Helper
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-orphan'
    Check 'orphan: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'orphan: the proven entrypoint was removed' (-not (Test-Path -LiteralPath $p7Entry))
    Check 'orphan: the non-entrypoint helper is byte-for-byte unchanged' (Test-BytesEqual $p7HelperBytes (Get-BytesOrEmpty $p7Helper))

    # =======================================================================
    Write-Host '--- Hook Maker tool-root sources are never removable ---' -ForegroundColor Cyan
    $p8 = New-Proj 'P8ToolRoot'
    $toolSource = Join-Path $FakeToolRoot 'hooks\Shipped\Shipped.ps1'
    Write-Utf8 $toolSource "exit 0`n"
    $p8Settings = Join-Path $p8 '.claude\settings.local.json'
    Write-Utf8 $p8Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $toolSource) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p8Prints = Get-HandlerPrints -SettingsPath $p8Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-toolroot' -HookType 'ClaudeRegistration' -TargetProjectRoot $p8 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p8Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p8Prints.Handler) -MatcherFingerprints @($p8Prints.Matcher) -ParsedTargets @($toolSource))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $toolSource -ReferencedBy @('disc-toolroot'))))
    )
    $toolSourceBytes = Get-BytesOrEmpty $toolSource
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-toolroot'
    Check 'toolroot: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'toolroot: the shipped source under <ToolRoot>\hooks is byte-for-byte unchanged' (Test-BytesEqual $toolSourceBytes (Get-BytesOrEmpty $toolSource))
    Check 'toolroot: the runtime was preserved, not deleted' ((Get-ComponentReason $r.Result 'runtime') -eq 'registrationRemovedRuntimePreserved')

    # =======================================================================
    Write-Host '--- an exact external native Git hook is removable ---' -ForegroundColor Cyan
    $repo1 = New-Proj 'Repo1Native'
    $repo1Hooks = Join-Path $repo1 '.git\hooks'
    New-Item -ItemType Directory -Path $repo1Hooks -Force | Out-Null
    $repo1Hook = Join-Path $repo1Hooks 'pre-commit'
    $repo1Sample = Join-Path $repo1Hooks 'pre-push.sample'
    Write-Utf8 $repo1Hook "#!/bin/sh`necho external`n"
    Write-Utf8 $repo1Sample "#!/bin/sh`nexit 0`n"
    $repo1SampleBytes = Get-BytesOrEmpty $repo1Sample
    $repo1Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo1; hooksPath = $repo1Hooks; hookName = 'pre-commit'; hookPath = $repo1Hook
        hookHash = (Get-FileSha256Hex -Path $repo1Hook); hookSize = 0; hookModifiedUtc = '2026-01-01T00:00:00.0000000Z'
        classification = 'externalNativeHook'; managedStages = @()
    }
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-native-ok' -HookType 'NativeGitHook' -TargetProjectRoot $repo1 `
            -NativeGit $repo1Native -RemovalPolicy 'nativeFileOnly')
    )
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-native-ok'
    Check 'native ok: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'native ok: the external hook file was removed' (-not (Test-Path -LiteralPath $repo1Hook))
    Check 'native ok: the .sample hook beside it is byte-for-byte unchanged' (Test-BytesEqual $repo1SampleBytes (Get-BytesOrEmpty $repo1Sample))
    Check 'native ok: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-native-ok'))

    # =======================================================================
    Write-Host '--- a native hook changed since discovery survives ---' -ForegroundColor Cyan
    $repo2 = New-Proj 'Repo2Changed'
    $repo2Hooks = Join-Path $repo2 '.git\hooks'
    New-Item -ItemType Directory -Path $repo2Hooks -Force | Out-Null
    $repo2Hook = Join-Path $repo2Hooks 'pre-commit'
    Write-Utf8 $repo2Hook "#!/bin/sh`necho original`n"
    $repo2Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo2; hooksPath = $repo2Hooks; hookName = 'pre-commit'; hookPath = $repo2Hook
        hookHash = (Get-FileSha256Hex -Path $repo2Hook); hookSize = 0; hookModifiedUtc = '2026-01-01T00:00:00.0000000Z'
        classification = 'externalNativeHook'; managedStages = @()
    }
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-native-changed' -HookType 'NativeGitHook' -TargetProjectRoot $repo2 `
            -NativeGit $repo2Native -RemovalPolicy 'nativeFileOnly')
    )
    # Edited after the record was written.
    Write-Utf8 $repo2Hook "#!/bin/sh`necho edited by the user`n"
    $repo2Bytes = Get-BytesOrEmpty $repo2Hook
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-native-changed'
    Check 'native changed: the run reports manualRepair' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'manualRepair') ($r.Out + $r.Err)
    Check 'native changed: the hook file is byte-for-byte unchanged' (Test-BytesEqual $repo2Bytes (Get-BytesOrEmpty $repo2Hook))
    Check 'native changed: the registry record is retained' ($null -ne (Get-RegistryRecord 'disc-native-changed'))

    # =======================================================================
    Write-Host '--- a Hook Maker wrapper routes through the managed uninstaller ---' -ForegroundColor Cyan
    $repo3 = New-Proj 'Repo3Wrapper'
    $repo3Hooks = Join-Path $repo3 '.git\hooks'
    New-Item -ItemType Directory -Path $repo3Hooks -Force | Out-Null
    $repo3Hook = Join-Path $repo3Hooks 'pre-push'
    # A wrapper carrying the marker but WITHOUT the exact managed content the
    # managed record would rebuild: the managed uninstaller must refuse it, and
    # the point of the assertion is that the refusal comes from THAT script.
    Write-Utf8 $repo3Hook ("#!/bin/sh`n" + $script:PrePushMarker + "`necho hand edited`n")
    $repo3Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo3; hooksPath = $repo3Hooks; hookName = 'pre-push'; hookPath = $repo3Hook
        hookHash = (Get-FileSha256Hex -Path $repo3Hook); hookSize = 0; hookModifiedUtc = '2026-01-01T00:00:00.0000000Z'
        classification = 'hookMakerWrapper'; managedStages = @()
    }
    $managedRecord = [pscustomobject][ordered]@{
        id = 'managed-wrapper-1'; schema = 3; recordType = 'managed'; origin = 'hookMaker'
        friendlyName = 'ZZZ-Disc-Wrapper'; hookType = 'CustomHook'; scope = 'project'
        targetProjectRoot = $repo3; profile = ''; sourceScript = (Join-Path $FakeToolRoot 'hooks\ZZZ-Disc-Wrapper\ZZZ-Disc-Wrapper.ps1')
        toolRoot = $FakeToolRoot; clients = [pscustomobject]@{}; sourceManifest = @(); needsManualRepair = $false
        nativeGit = [pscustomobject][ordered]@{
            managed = $true; wrapperPath = $repo3Hook; hooksPath = $repo3Hooks
            runtimeRoot = (Join-Path $repo3 '.git\hooks\Hook-Maker'); expectedStages = @()
            previousHookPath = ''; previousHookPreserved = $false
        }
    }
    Set-Registry @(
        $managedRecord,
        (New-DiscoveredRecord -Id 'disc-wrapper' -HookType 'NativeGitHook' -TargetProjectRoot $repo3 `
            -NativeGit $repo3Native -RemovalPolicy 'nativeFileOnly')
    )
    $repo3Bytes = Get-BytesOrEmpty $repo3Hook
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-wrapper'
    Check 'wrapper: the native component was delegated to the managed uninstaller' `
        ((Get-ComponentReason $r.Result 'nativeGit') -eq 'delegatedToManagedUninstaller') (Get-ComponentReason $r.Result 'nativeGit')
    Check 'wrapper: the discovered remover did not delete the wrapper itself' (Test-BytesEqual $repo3Bytes (Get-BytesOrEmpty $repo3Hook))
    Check 'wrapper: the discovered record is retained while the managed uninstall is unresolved' ($null -ne (Get-RegistryRecord 'disc-wrapper'))
    Check 'wrapper: the managed record was left for its own uninstaller to resolve' ($null -ne (Get-RegistryRecord 'managed-wrapper-1'))

    # =======================================================================
    Write-Host '--- a managed record is never routed into this script ---' -ForegroundColor Cyan
    $r = Invoke-DiscoveredUninstall -RecordId 'managed-wrapper-1'
    Check 'managed: the run refuses with manualRepair' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'manualRepair') ($r.Out + $r.Err)
    Check 'managed: the refusal names the wrong record type' ((Get-ComponentReason $r.Result 'registry') -eq 'wrongRecordType')
    Check 'managed: the managed record is untouched' ($null -ne (Get-RegistryRecord 'managed-wrapper-1'))
