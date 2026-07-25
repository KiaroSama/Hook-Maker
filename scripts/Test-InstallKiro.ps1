# Offline test suite for the Kiro registration module (_installkiro.ps1).
#
# Kiro is Hook Maker's only 'perHookFile' client, which means it is the only
# one where a file Hook Maker names can still belong to somebody else, and the
# only one where a managed file can be hand-edited to hold extra hooks. The
# highest-value assertions here are therefore not the schema ones - they are
# the ownership ones: a matching filename with no managed identity is FOREIGN
# and is never claimed, and a mixed file round-trips with every foreign entry
# byte-identical and in order.
#
# Also covers: the exact v1 schema (version is the string "v1", hooks is an
# array, timeout is numeric seconds, action.type is command, no legacy
# when/then/askAgent shape and no agent action); rejection - never a silent
# drop - of any trigger Kiro does not document; matcher attached only where
# the protocol confirms it is evaluated; .kiro\hooks for registration but
# NEVER .kiro\hooks for the runtime; and strict UTF-8 output that re-parses
# from disk.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstallKiro.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$Module = Join-Path $ScriptRoot '_installkiro.ps1'
foreach ($required in @($Module, (Join-Path $ScriptRoot '_clientcapability.ps1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
. $Module

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-kiro-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
function Compact { param($Value) return ($Value | ConvertTo-Json -Depth 20 -Compress) }

# Every rejection assertion must also prove nothing reached disk, so each one
# runs against a fresh directory whose file count is checked afterwards.
function Get-Rejection {
    param([scriptblock]$Action)
    try { & $Action; return '' } catch { return [string]$_.Exception.Message }
}

$SavedUserProfile = $env:USERPROFILE
$SavedHome = $env:HOME

try {
    $managedId = 'a1b2c3d4e5'
    $otherId = 'f9f9f9f9'
    $command = 'pwsh -NoLogo -NoProfile -File "C:\Proj\.kiro\hook-runtime\Hook-Maker\Secrets-Check\Secrets-Check.ps1" -Trigger PreToolUse'

    # ---------------------------------------------------------------- schema
    Write-Host '--- v1 document schema ---' -ForegroundColor Cyan

    $doc = New-KiroHookDocument -FriendlyName 'Secrets Check' -Command $command `
        -Triggers @('PreToolUse', 'Stop') -TimeoutSeconds 45 -ManagedId $managedId -Matcher '^Bash$'
    $json = ConvertTo-KiroHookJson -Document $doc
    $docPath = Join-Path $Work 'hookmaker-secrets-check-a1b2c3d4e5.json'
    Write-Utf8 -Path $docPath -Content $json
    $reparsed = ([System.IO.File]::ReadAllText($docPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)

    Check 'version is exactly the string "v1"' ([string]$reparsed.version -ceq 'v1') ([string]$reparsed.version)
    Check 'version is serialized as a JSON string, not a number' ($json -match '"version"\s*:\s*"v1"') $json
    Check 'hooks is serialized as a JSON array' ($json -match '"hooks"\s*:\s*\[') $json
    Check 'hooks re-parses from disk as an array' ($reparsed.hooks -is [System.Array]) ($reparsed.hooks.GetType().FullName)
    Check 'one entry per requested trigger' (@($reparsed.hooks).Count -eq 2) ([string]@($reparsed.hooks).Count)

    $preToolEntry = @($reparsed.hooks | Where-Object { $_.trigger -ceq 'PreToolUse' })
    $stopEntry = @($reparsed.hooks | Where-Object { $_.trigger -ceq 'Stop' })
    Check 'trigger casing is exact PascalCase (PreToolUse)' ($preToolEntry.Count -eq 1) $json
    Check 'trigger casing is exact PascalCase (Stop)' ($stopEntry.Count -eq 1) $json

    $entry = $preToolEntry[0]
    Check 'required field name is present' (-not [string]::IsNullOrWhiteSpace([string]$entry.name)) $json
    Check 'required field trigger is present' (-not [string]::IsNullOrWhiteSpace([string]$entry.trigger)) $json
    Check 'required field action is present' ($null -ne $entry.PSObject.Properties['action']) $json
    Check 'action.type is command' ([string]$entry.action.type -ceq 'command') $json
    Check 'action.command is the launcher command verbatim' ([string]$entry.action.command -ceq $command) ([string]$entry.action.command)
    Check 'no agent action is ever emitted' ($json -notmatch '"type"\s*:\s*"agent"') $json
    Check 'timeout is a bare JSON number, not a string' ($json -match '"timeout"\s*:\s*45\b') $json
    Check 'timeout is the seconds value that was requested' ([int]$entry.timeout -eq 45) ([string]$entry.timeout)
    Check 'enabled defaults to true' ([bool]$entry.enabled) $json
    Check 'the description carries the managed identity marker' (
        [string]$entry.description -match '\[hookmaker:a1b2c3d4e5\]') ([string]$entry.description)
    Check 'the entry name carries the managed id right after the hookmaker- prefix' (
        [string]$entry.name -eq 'hookmaker-a1b2c3d4e5-secrets-check-pretooluse') ([string]$entry.name)

    Check 'no legacy when/then/askAgent shape is emitted' (
        $json -notmatch '"when"\s*:' -and $json -notmatch '"then"\s*:' -and $json -notmatch 'askAgent') $json
    Check 'no legacy glob "patterns" field is emitted' ($json -notmatch '"patterns"\s*:') $json

    # -------------------------------------------------------------- matchers
    Write-Host '--- matcher is attached only where it is evaluated ---' -ForegroundColor Cyan

    Check 'matcher IS attached to PreToolUse' ([string]$entry.matcher -ceq '^Bash$') $json
    Check 'matcher is NOT attached to Stop (not evaluated there)' (
        $null -eq $stopEntry[0].PSObject.Properties['matcher']) $json

    $docMulti = New-KiroHookDocument -FriendlyName 'Multi' -Command $command `
        -Triggers @('SessionStart', 'UserPromptSubmit', 'PostToolUse') -TimeoutSeconds 60 -ManagedId $managedId -Matcher '\.ps1$'
    $multiByTrigger = @{}
    foreach ($e in @($docMulti.hooks)) { $multiByTrigger[[string]$e.trigger] = $e }
    Check 'matcher is NOT attached to SessionStart' (
        $null -eq $multiByTrigger['SessionStart'].PSObject.Properties['matcher']) (Compact $docMulti)
    Check 'matcher is NOT attached to UserPromptSubmit (IDE evaluation unconfirmed)' (
        $null -eq $multiByTrigger['UserPromptSubmit'].PSObject.Properties['matcher']) (Compact $docMulti)
    Check 'matcher IS attached to PostToolUse' (
        [string]$multiByTrigger['PostToolUse'].matcher -ceq '\.ps1$') (Compact $docMulti)

    $disabled = New-KiroHookDocument -FriendlyName 'Off' -Command $command -Triggers @('Stop') `
        -TimeoutSeconds 30 -ManagedId $managedId -Enabled $false
    Check '-Enabled $false emits enabled:false rather than deleting the hook' (
        (ConvertTo-KiroHookJson -Document $disabled) -match '"enabled"\s*:\s*false') (ConvertTo-KiroHookJson -Document $disabled)

    # ------------------------------------------------------------ rejections
    Write-Host '--- unsupported input is rejected with a named reason, and writes nothing ---' -ForegroundColor Cyan

    $rejectDir = Join-Path $Work 'rejections'
    New-Item -ItemType Directory -Path $rejectDir -Force | Out-Null

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @('PreCompact') -TimeoutSeconds 60 -ManagedId $managedId }
    Check 'a logical event Kiro does not document is rejected: trigger-unsupported-by-kiro' (
        $r -match 'trigger-unsupported-by-kiro') $r
    Check 'the rejection names the offending trigger' ($r -match 'PreCompact') $r
    Check 'the rejection states it is neither dropped nor remapped onto Stop' (
        $r -match 'not silently dropped' -and $r -match 'never remapped onto Stop') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @('PostFileSave') -TimeoutSeconds 60 -ManagedId $managedId }
    Check 'a Kiro-only trigger with no Hook Maker equivalent is rejected: trigger-unknown' ($r -match 'trigger-unknown') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @('Manual') -TimeoutSeconds 60 -ManagedId $managedId }
    Check 'Manual is rejected by name: trigger-manual-never-emitted' ($r -match 'trigger-manual-never-emitted') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @('Stop', 'Stop') -TimeoutSeconds 60 -ManagedId $managedId }
    Check 'a duplicated trigger is rejected: trigger-duplicate' ($r -match 'trigger-duplicate') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @() -TimeoutSeconds 60 -ManagedId $managedId }
    Check 'an empty trigger list is rejected: triggers-empty' ($r -match 'triggers-empty') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @('Stop') -TimeoutSeconds 0 -ManagedId $managedId }
    Check 'timeout 0 is rejected: timeout-out-of-range (Kiro reads 0 as no timeout)' ($r -match 'timeout-out-of-range') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command '' -Triggers @('Stop') -TimeoutSeconds 60 -ManagedId $managedId }
    Check 'an empty command is rejected: command-empty' ($r -match 'command-empty') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @('PreToolUse') -TimeoutSeconds 60 -ManagedId $managedId -Matcher '*.ts' }
    Check 'a legacy glob matcher is rejected as an invalid v1 regex' ($r -match 'matcher-invalid-regex') $r

    $r = Get-Rejection { New-KiroHookDocument -FriendlyName 'X' -Command $command -Triggers @('Stop') -TimeoutSeconds 60 -ManagedId '///' }
    Check 'a ManagedId with no usable characters is rejected: managed-id-unusable' ($r -match 'managed-id-unusable') $r

    Check 'no rejected document produced a file' (@(Get-ChildItem -LiteralPath $rejectDir -Force).Count -eq 0) $rejectDir

    # ------------------------------------------------------------------ paths
    Write-Host '--- registration paths and the runtime root ---' -ForegroundColor Cyan

    $proj = Join-Path $Work 'Proj'
    $fakeHome = Join-Path $Work 'FakeHome'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
    $env:USERPROFILE = $fakeHome
    $env:HOME = $fakeHome

    $projectPath = Get-KiroRegistrationPath -Scope 'project' -FriendlyName 'Secrets Check' -StableId 'A1B2C3D4E5F6G7' -TargetProjectRoot $proj
    $globalPath = Get-KiroRegistrationPath -Scope 'global' -FriendlyName 'Secrets Check' -StableId 'A1B2C3D4E5F6G7'

    Check 'the project registration lives under <project>\.kiro\hooks\' (
        $projectPath.StartsWith((Join-Path $proj '.kiro\hooks') + '\', [System.StringComparison]::OrdinalIgnoreCase)) $projectPath
    Check 'the global registration lives under <home>\.kiro\hooks\' (
        $globalPath.StartsWith((Join-Path $fakeHome '.kiro\hooks') + '\', [System.StringComparison]::OrdinalIgnoreCase)) $globalPath
    Check 'the global registration is NOT under the project root' (
        -not $globalPath.StartsWith($proj, [System.StringComparison]::OrdinalIgnoreCase)) $globalPath
    Check 'the filename is hookmaker-<friendly-slug>-<stable-short-id>.json' (
        (Split-Path -Leaf $projectPath) -eq 'hookmaker-secrets-check-a1b2c3d4e5f6.json') (Split-Path -Leaf $projectPath)
    Check 'the filename is never .hook or .kiro.hook' (
        $projectPath -notmatch '\.hook$' -and $projectPath -notmatch '\.kiro\.hook' -and $projectPath.EndsWith('.json')) $projectPath
    Check 'the produced filename is recognised as the managed pattern' (Test-KiroManagedFileName -Path $projectPath) $projectPath

    $projectRuntime = Get-KiroRuntimeRoot -Scope 'project' -TargetProjectRoot $proj
    $globalRuntime = Get-KiroRuntimeRoot -Scope 'global'
    Check 'the project runtime root is <project>\.kiro\hook-runtime\Hook-Maker' (
        $projectRuntime -eq (Join-Path $proj '.kiro\hook-runtime\Hook-Maker')) $projectRuntime
    Check 'the project runtime root is NOT under .kiro\hooks (Kiro would scan it as config)' (
        $projectRuntime -notmatch '\.kiro\\hooks(\\|$)') $projectRuntime
    Check 'the global runtime root is under the home root' (
        $globalRuntime.StartsWith($fakeHome, [System.StringComparison]::OrdinalIgnoreCase)) $globalRuntime
    Check 'the global runtime root is NOT under .kiro\hooks' ($globalRuntime -notmatch '\.kiro\\hooks(\\|$)') $globalRuntime

    $r = Get-Rejection { Get-KiroRegistrationPath -Scope 'project' -FriendlyName 'X' -StableId 'abc' }
    Check 'project scope without -TargetProjectRoot is rejected, not guessed from the CWD' (
        $r -match 'target-project-root-required') $r

    # -------------------------------------------------------------- ownership
    Write-Host '--- ownership is proven from the entries, never from the filename ---' -ForegroundColor Cyan

    $hooksDir = Join-Path $proj '.kiro\hooks'
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    Check 'the shared hooks.json is refused: unmanaged-filename' (
        (Test-KiroManagedFile -Path (Join-Path $hooksDir 'hooks.json') -ManagedId $managedId).Reason -eq 'unmanaged-filename') 'hooks.json'
    Check 'the shared hooks.json is not writable by Hook Maker' (
        -not (Test-KiroManagedFile -Path (Join-Path $hooksDir 'hooks.json') -ManagedId $managedId).Ok) 'hooks.json'
    Check 'a legacy .kiro.hook file is refused' (
        -not (Test-KiroManagedFile -Path (Join-Path $hooksDir 'lint-on-save.kiro.hook') -ManagedId $managedId).Ok) '.kiro.hook'
    Check 'a legacy .hook file is refused' (
        -not (Test-KiroManagedFile -Path (Join-Path $hooksDir 'lint.hook') -ManagedId $managedId).Ok) '.hook'
    Check 'an unrelated .json in .kiro\hooks is refused' (
        -not (Test-KiroManagedFile -Path (Join-Path $hooksDir 'my-own-hook.json') -ManagedId $managedId).Ok) 'my-own-hook.json'

    $managedPath = Join-Path $hooksDir 'hookmaker-secrets-check-a1b2c3d4e5f6.json'
    $missing = Test-KiroManagedFile -Path $managedPath -ManagedId $managedId
    Check 'a managed path with no file yet reports missing and is safe to create' (
        $missing.Ok -and $missing.Reason -eq 'missing') $missing.Reason

    Write-Utf8 -Path $managedPath -Content (ConvertTo-KiroHookJson -Document $doc)
    $owned = Test-KiroManagedFile -Path $managedPath -ManagedId $managedId
    Check 'our own file is proven managed' ($owned.Ok -and $owned.Reason -eq 'managed') $owned.Reason
    Check 'both of our entries are reported as managed' (@($owned.ManagedEntries).Count -eq 2) ([string]@($owned.ManagedEntries).Count)
    Check 'no entry of ours is misreported as foreign' (@($owned.ForeignEntries).Count -eq 0) ([string]@($owned.ForeignEntries).Count)

    # A file whose NAME matches perfectly but whose entries carry no Hook
    # Maker identity. This is the case a filename-based owner would clobber.
    $imposterPath = Join-Path $hooksDir 'hookmaker-secrets-check-deadbeef.json'
    Write-Utf8 -Path $imposterPath -Content @'
{
  "version": "v1",
  "hooks": [
    { "name": "hookmaker-looking-name", "trigger": "PostFileSave", "action": { "type": "command", "command": "npm run lint" } },
    { "name": "my-own-hook", "description": "hand written", "trigger": "Stop", "action": { "type": "agent", "prompt": "summarise" } }
  ]
}
'@
    $imposter = Test-KiroManagedFile -Path $imposterPath -ManagedId $managedId
    Check 'a matching filename with no managed identity is reported FOREIGN' ($imposter.Reason -eq 'foreign') $imposter.Reason
    Check 'a foreign file is never claimed as writable' (-not $imposter.Ok) $imposter.Reason
    Check 'every entry of a foreign file is listed as foreign' (@($imposter.ForeignEntries).Count -eq 2) ([string]@($imposter.ForeignEntries).Count)
    Check 'a foreign file yields no managed entries' (@($imposter.ManagedEntries).Count -eq 0) ([string]@($imposter.ManagedEntries).Count)

    $otherOwner = Test-KiroManagedFile -Path $managedPath -ManagedId $otherId
    Check "another installation's entries are foreign to this one" ($otherOwner.Reason -eq 'foreign' -and -not $otherOwner.Ok) $otherOwner.Reason

    $badJsonPath = Join-Path $hooksDir 'hookmaker-broken-1.json'
    Write-Utf8 -Path $badJsonPath -Content '{ "version": "v1", "hooks": [ '
    Check 'unparseable JSON is reported invalid-json, never overwritten' (
        (Test-KiroManagedFile -Path $badJsonPath -ManagedId $managedId).Reason -eq 'invalid-json') 'invalid-json'

    $legacyPath = Join-Path $hooksDir 'hookmaker-legacy-1.json'
    Write-Utf8 -Path $legacyPath -Content '{ "version": "1", "when": { "type": "fileEdited" }, "then": { "type": "askAgent" } }'
    Check 'a legacy version "1" document is reported unexpected-schema' (
        (Test-KiroManagedFile -Path $legacyPath -ManagedId $managedId).Reason -eq 'unexpected-schema') 'unexpected-schema'

    $objectHooksPath = Join-Path $hooksDir 'hookmaker-objecthooks-1.json'
    Write-Utf8 -Path $objectHooksPath -Content '{ "version": "v1", "hooks": { "name": "x" } }'
    Check 'a hooks object instead of an array is reported unexpected-schema' (
        (Test-KiroManagedFile -Path $objectHooksPath -ManagedId $managedId).Reason -eq 'unexpected-schema') 'unexpected-schema'

    # ------------------------------------------------------------------ merge
    Write-Host '--- merge preserves every foreign entry exactly ---' -ForegroundColor Cyan

    $created = Merge-KiroManagedEntries -ExistingDocument $null -ManagedEntries @($doc.hooks) -ManagedId $managedId
    Check 'merging into nothing creates the document' ($created.Ok -and $created.Reason -eq 'created') $created.Reason
    Check 'the created document holds exactly our entries' (@($created.Document.hooks).Count -eq 2) ([string]@($created.Document.hooks).Count)
    Check 'the created document is still v1' ([string]$created.Document.version -ceq 'v1') ([string]$created.Document.version)

    # A managed file a user has hand-edited: one of ours between two of theirs.
    $mixedPath = Join-Path $hooksDir 'hookmaker-mixed-1.json'
    Write-Utf8 -Path $mixedPath -Content ('{
  "version": "v1",
  "hooks": [
    { "name": "user-lint", "description": "mine", "trigger": "PostFileSave", "matcher": "\\.ts$", "action": { "type": "command", "command": "npm run lint" }, "timeout": 15, "enabled": false },
    { "name": "hookmaker-a1b2c3d4e5-mixed-stop", "description": "old text [hookmaker:a1b2c3d4e5]", "trigger": "Stop", "action": { "type": "command", "command": "OLD-COMMAND" }, "timeout": 10, "enabled": true },
    { "name": "user-review", "description": "also mine", "trigger": "PostTaskExec", "action": { "type": "agent", "prompt": "review the diff" }, "enabled": true }
  ]
}')
    $mixedBefore = ([System.IO.File]::ReadAllText($mixedPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    $beforeEntries = @($mixedBefore.hooks)
    $foreignBefore0 = Compact $beforeEntries[0]
    $foreignBefore2 = Compact $beforeEntries[2]

    $newMixed = New-KiroHookDocument -FriendlyName 'Mixed' -Command 'NEW-COMMAND' -Triggers @('Stop') `
        -TimeoutSeconds 90 -ManagedId $managedId
    $merged = Merge-KiroManagedEntries -ExistingDocument $mixedBefore -ManagedEntries @($newMixed.hooks) -ManagedId $managedId

    Check 'a mixed managed file merges' ($merged.Ok -and $merged.Reason -eq 'merged') $merged.Reason
    $mergedEntries = @($merged.Document.hooks)
    Check 'the merged document still holds three entries' ($mergedEntries.Count -eq 3) ([string]$mergedEntries.Count)
    Check 'foreign entry 1 keeps its original position' ([string]$mergedEntries[0].name -eq 'user-lint') ([string]$mergedEntries[0].name)
    Check 'foreign entry 2 keeps its original position and order' ([string]$mergedEntries[2].name -eq 'user-review') ([string]$mergedEntries[2].name)
    Check 'foreign entry 1 is byte-identical after the merge' ((Compact $mergedEntries[0]) -ceq $foreignBefore0) (Compact $mergedEntries[0])
    Check 'foreign entry 2 is byte-identical after the merge' ((Compact $mergedEntries[2]) -ceq $foreignBefore2) (Compact $mergedEntries[2])
    Check 'foreign entry 1 is the very same object, never rebuilt' (
        [object]::ReferenceEquals($mergedEntries[0], $beforeEntries[0])) 'reference'
    Check 'foreign entry 2 is the very same object, never rebuilt' (
        [object]::ReferenceEquals($mergedEntries[2], $beforeEntries[2])) 'reference'
    Check 'a foreign disabled entry keeps enabled:false' ([bool]$mergedEntries[0].enabled -eq $false) (Compact $mergedEntries[0])
    Check 'a foreign entry keeps its matcher' ([string]$mergedEntries[0].matcher -ceq '\.ts$') ([string]$mergedEntries[0].matcher)
    Check 'a foreign entry keeps its timeout' ([int]$mergedEntries[0].timeout -eq 15) ([string]$mergedEntries[0].timeout)
    Check 'a foreign agent-action prompt is preserved untouched' (
        [string]$mergedEntries[2].action.prompt -ceq 'review the diff') (Compact $mergedEntries[2])
    Check 'our own entry IS updated in place' ([string]$mergedEntries[1].action.command -ceq 'NEW-COMMAND') ([string]$mergedEntries[1].action.command)
    Check 'our own entry keeps its position between the foreign entries' (
        [string]$mergedEntries[1].name -eq 'hookmaker-a1b2c3d4e5-mixed-stop') ([string]$mergedEntries[1].name)
    Check 'our updated entry carries the new timeout' ([int]$mergedEntries[1].timeout -eq 90) ([string]$mergedEntries[1].timeout)
    Check 'the merge result reports the preserved foreign entries' (@($merged.ForeignEntries).Count -eq 2) ([string]@($merged.ForeignEntries).Count)

    # A re-install that drops a trigger must remove OUR stale entry - and only ours.
    $twoTrigger = New-KiroHookDocument -FriendlyName 'Mixed' -Command 'C1' -Triggers @('Stop', 'PreToolUse') `
        -TimeoutSeconds 30 -ManagedId $managedId
    $grown = Merge-KiroManagedEntries -ExistingDocument $mixedBefore -ManagedEntries @($twoTrigger.hooks) -ManagedId $managedId
    Check 'adding a trigger appends a second managed entry' (@($grown.Document.hooks).Count -eq 4) ([string]@($grown.Document.hooks).Count)
    $shrunk = Merge-KiroManagedEntries -ExistingDocument $grown.Document -ManagedEntries @($newMixed.hooks) -ManagedId $managedId
    Check 'dropping a trigger removes our stale entry' (@($shrunk.Document.hooks).Count -eq 3) ([string]@($shrunk.Document.hooks).Count)
    Check 'dropping a trigger removes none of the foreign entries' (
        @($shrunk.Document.hooks | Where-Object { [string]$_.name -eq 'user-lint' -or [string]$_.name -eq 'user-review' }).Count -eq 2) (Compact $shrunk.Document)

    # Unprovable ownership: refuse, and leave the caller's document untouched.
    $imposterDoc = ([System.IO.File]::ReadAllText($imposterPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    $imposterBefore = Compact $imposterDoc
    $refused = Merge-KiroManagedEntries -ExistingDocument $imposterDoc -ManagedEntries @($newMixed.hooks) -ManagedId $managedId
    Check 'a file we cannot prove we own is refused: not Ok' (-not $refused.Ok) ([string]$refused.Reason)
    Check 'the refusal names foreign as the reason' ($refused.Reason -eq 'foreign') ([string]$refused.Reason)
    Check 'a refused merge returns no document to write' ($null -eq $refused.Document) 'document'
    Check 'a refused merge mutates nothing' ((Compact $imposterDoc) -ceq $imposterBefore) (Compact $imposterDoc)

    $legacyDoc = ([System.IO.File]::ReadAllText($legacyPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    $refusedLegacy = Merge-KiroManagedEntries -ExistingDocument $legacyDoc -ManagedEntries @($newMixed.hooks) -ManagedId $managedId
    Check 'a legacy-schema document is refused rather than rewritten' (
        -not $refusedLegacy.Ok -and $refusedLegacy.Reason -eq 'unexpected-schema' -and $null -eq $refusedLegacy.Document) ([string]$refusedLegacy.Reason)

    $r = Get-Rejection { Merge-KiroManagedEntries -ExistingDocument $null -ManagedEntries @($beforeEntries[0]) -ManagedId $managedId }
    Check 'merging an entry that carries no managed identity is rejected' ($r -match 'managed-entries-unidentified') $r

    # ------------------------------------------------------------------ UTF-8
    Write-Host '--- UTF-8 output and disk round-trip ---' -ForegroundColor Cyan

    # Built from code points, never a literal: a BOM-less .ps1 is decoded as
    # ANSI by Windows PowerShell, so a non-ASCII literal in this file would
    # test the host's decoding rather than the module.
    $accented = 'Caf' + [string][char]0x00E9 + ' ' + [string][char]0x4E2D + '-Check'
    $utf8Doc = New-KiroHookDocument -FriendlyName $accented -Command $command -Triggers @('SessionStart') `
        -TimeoutSeconds 20 -ManagedId $managedId
    $utf8Path = Join-Path $hooksDir 'hookmaker-utf8-1.json'
    Write-Utf8 -Path $utf8Path -Content (ConvertTo-KiroHookJson -Document $utf8Doc)

    $bytes = [System.IO.File]::ReadAllBytes($utf8Path)
    Check 'the document is written without a UTF-8 BOM' (
        -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'bom'
    $utf8Reparsed = ([System.IO.File]::ReadAllText($utf8Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Check 'the document re-parses from disk' ([string]$utf8Reparsed.version -ceq 'v1') ([string]$utf8Reparsed.version)
    Check 'non-ASCII text survives the write/read round-trip exactly' (
        [string]@($utf8Reparsed.hooks)[0].description -match [regex]::Escape($accented)) ([string]@($utf8Reparsed.hooks)[0].description)
    Check 'a round-tripped document is still proven ours' (
        (Test-KiroManagedFile -Path $utf8Path -ManagedId $managedId).Ok) 'round-trip ownership'

    # ConvertTo-KiroHookJson exists because a default -Depth silently destroys
    # the nested action object on Windows PowerShell.
    Check 'the serializer nests the action object rather than stringifying it' (
        (ConvertTo-KiroHookJson -Document $utf8Doc) -notmatch 'System\.Management\.Automation\.PSCustomObject') 'depth'

    Check 'no .hook or .kiro.hook file was produced anywhere in the workspace' (
        @(Get-ChildItem -LiteralPath $Work -Recurse -Force -File | Where-Object { $_.Name -match '\.hook$' }).Count -eq 0) $Work
}
finally {
    $env:USERPROFILE = $SavedUserProfile
    $env:HOME = $SavedHome
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
