# ---------------------------------------------------------------------------
# Kiro ownership scenarios: client identity resolution, registration and
# runtime paths derived from the capability table (isolated, space-safe),
# entry identity that cannot be FORGED, and a foreign entry surviving a
# REAL write (merge -> serialize -> disk -> re-parse).
#
# Dot-sourced by Test-KiroIntegration.ps1 into ITS scope: Check, $Work,
# $managedId, $command, $capability, Write-Utf8/Read-Utf8/Compact and the
# saved environment all resolve there. This file REDIRECTS USERPROFILE and
# HOME to a fake home under the workspace; the entry file's finally
# restores them. Execution order across the companion files is
# load-bearing; none is a standalone suite. Body indentation is preserved
# from the entry file's try block (pure relocation).
# ---------------------------------------------------------------------------

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
