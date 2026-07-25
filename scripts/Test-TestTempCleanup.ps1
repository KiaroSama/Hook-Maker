# Offline test suite for Test-Temp-Cleanup, a DETECTOR + ADVISOR + COMPLETION
# GATE with no deletion feature at all. Every filesystem claim below is a real
# on-disk assertion, never a comment or a mocked success string.
#
# Covers: nothing on disk is ever mutated (a real .pytest_cache created AFTER
# the baseline still exists after Stop; review artifacts, tracked/staged
# candidates, junction targets and .kiro all survive); .kiro is hard-pruned and
# never descended into; the AST of the hook contains no reachable project-
# mutation command and no mutating git subcommand; the report always instructs
# the agent to inspect before deleting; a missing baseline is conservative; the
# scan-entry ceiling yields `partial` and never `clean`; an unreadable directory
# yields the NAMED cause `directory-unreadable`; unknown git state is never
# called disposable; unchanged evidence is anti-loop suppressed while changed
# evidence re-reports; the Claude and Codex adapters carry the same semantic
# instruction; the result-category contract still matches Cloudflare-Deploy.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TestTempCleanup.ps1 [-KeepArtifacts]
#         ... -HookPathOverride <path>   run the same assertions against another
#                                        copy of the hook (used to prove the new
#                                        assertions go RED against the pre-change
#                                        file exported with `git show HEAD:...`).
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts, [string]$HookPathOverride)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HooksRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Test-Temp-Cleanup\Test-Temp-Cleanup.ps1'
if (-not [string]::IsNullOrWhiteSpace($HookPathOverride)) { $Hook = $HookPathOverride }
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$CloudflareHook = Join-Path $HooksRoot 'Cloudflare-Deploy\Cloudflare-Deploy.ps1'
$EnvExample = Join-Path $HooksRoot 'Test-Temp-Cleanup\.env.example'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Get-ShortHash / Normalize-Path / Get-Field, so the suite can locate and read
# the hook's own state files exactly the way its consumers do.
. $HookLib

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-cleanuptest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
function New-Dir { param([string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $Path }
function New-GitRepo {
    param([string]$Name)
    $p = New-Proj $Name
    & git -C $p init -q -b main
    & git -C $p config user.email 't@t'
    & git -C $p config user.name 't'
    return $p
}
function Add-Commit {
    param([string]$Repo, [string]$Message = 'c')
    & git -C $Repo add -A
    & git -C $Repo commit -q -m $Message
}
# A recognized disposable cache with real content on disk.
function New-Cache {
    param([string]$Root, [string]$Name = '.pytest_cache')
    $p = New-Dir (Join-Path $Root $Name)
    Write-Utf8 (Join-Path $p 'x.txt') 'cache-content'
    return $p
}

# Per-test isolated LOCALAPPDATA so baseline/result/state files never collide
# across test cases or with the real machine state.
function New-IsolatedHookCopy {
    param([hashtable]$EnvOverrides = @{})
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Test-Temp-Cleanup.ps1')
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($EnvOverrides.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
        Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Temp-Cleanup.ps1'); LocalAppData = $fakeLocal }
}

function Fire {
    param([string]$HookPath, [string]$Cwd, [string]$EventName, [string]$SessionId = 'sess1', [string]$LocalAppData, [switch]$StopHookActive, [switch]$NoClaudeProjectDir, [string]$Exe = 'pwsh')
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    # Env is handed over by INHERITANCE, not Start-Process -Environment: that
    # parameter does not exist on Windows PowerShell 5.1, so a -Environment-only
    # harness silently lets the child use the REAL %LOCALAPPDATA% and the
    # ambient CLAUDE_PROJECT_DIR on that host - state assertions then read
    # nothing and every "Codex" case is mis-detected. Set both here, restore in
    # finally, one code path for both hosts. Clearing CLAUDE_PROJECT_DIR matters:
    # this very test runner may itself have it set.
    $savedLocalAppData = $env:LOCALAPPDATA
    $savedProjectDir = $env:CLAUDE_PROJECT_DIR
    try {
        $env:LOCALAPPDATA = $LocalAppData
        $env:CLAUDE_PROJECT_DIR = if ($NoClaudeProjectDir) { '' } else { $Cwd }
        $proc = Start-Process @startArgs
    }
    finally {
        $env:LOCALAPPDATA = $savedLocalAppData
        $env:CLAUDE_PROJECT_DIR = $savedProjectDir
    }
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# The record the hook wrote to its shared coordination file - the exact document
# Cloudflare-Deploy and Test-Completion-Check read.
function Get-RecordedResult {
    param([string]$LocalAppData, [string]$Root)
    $key = Get-ShortHash ((Normalize-Path $Root).ToLowerInvariant())
    return (Read-JsonFile -Path (Join-Path $LocalAppData ('HookMaker\state\TestTempCleanup-result-' + $key + '.json')))
}
function Get-RecordedCategory {
    param([string]$LocalAppData, [string]$Root)
    $record = Get-RecordedResult $LocalAppData $Root
    if ($null -eq $record) { return '<none>' }
    return [string](Get-Field $record 'category')
}
# One candidate's reported line, matched by relative path. The hook's output is
# single-line JSON in which newlines are ESCAPED, so a candidate line must be
# matched field-by-field rather than with a [^\n] run.
function Get-CandidateLinePattern {
    param([string]$RelPath, [string]$Classification, [string]$GitState)
    return ([regex]::Escape($RelPath) + ' \| class=' + $Classification +
        ' \| type=[a-z-]+ \| at-session-start=[a-z]+ \| during-session=[a-z]+ \| git=' + $GitState)
}

# The six mandated instruction lines. Every client adapter must carry all of
# them, so their presence is the semantic contract (not the JSON envelope).
$InstructionFragments = @(
    'Inspect every candidate before deletion',
    'Do not rely on the directory name alone',
    'Never delete tracked, staged, linked, diagnostic, ambiguous, protected, or user-owned data',
    'Delete only project-local residue that you have independently confirmed is disposable',
    'this hook performs no deletion',
    'Leave uncertain candidates intact and report them'
)
function Test-HasFullInstruction {
    param([string]$Text)
    foreach ($fragment in $InstructionFragments) { if ($Text -notmatch [regex]::Escape($fragment)) { return $false } }
    return $true
}

try {
    # =====================================================================
    Write-Host '--- THE CORE GUARANTEE: a cache created after baseline is NOT deleted ---' -ForegroundColor Cyan
    $hc1 = New-IsolatedHookCopy
    $proj1 = New-GitRepo 'NoDelete'
    Write-Utf8 (Join-Path $proj1 'src.txt') 'code'
    Add-Commit $proj1 'init'
    $r = Fire -HookPath $hc1.Script -Cwd $proj1 -EventName 'SessionStart' -LocalAppData $hc1.LocalAppData
    Check 'SessionStart is silent when the scan is complete' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $cache1 = New-Cache $proj1
    Check 'the cache exists on disk right after SessionStart' (Test-Path -LiteralPath (Join-Path $cache1 'x.txt'))
    $r = Fire -HookPath $hc1.Script -Cwd $proj1 -EventName 'Stop' -LocalAppData $hc1.LocalAppData
    Check 'STRONGEST: a real .pytest_cache created after baseline STILL EXISTS after Stop' (Test-Path -LiteralPath $cache1)
    Check '... and its content is untouched, not truncated' (
        (Test-Path -LiteralPath (Join-Path $cache1 'x.txt')) -and
        ([System.IO.File]::ReadAllText((Join-Path $cache1 'x.txt')) -eq 'cache-content'))
    Check 'it is surfaced as likely-disposable, which is a description not an approval' ($r.Out -match 'class=likely-disposable') $r.Out
    Check 'the report tells the agent to inspect every candidate before deletion' ($r.Out -match 'Inspect every candidate before deletion') $r.Out
    Check 'the report carries the complete mandated instruction' (Test-HasFullInstruction $r.Out) $r.Out
    Check 'the report never claims the hook removed anything' ($r.Out -notmatch 'removed safe' -and $r.Out -notmatch 'verified by rescan') $r.Out
    Check 'the recorded category is review-required, not clean' ((Get-RecordedCategory $hc1.LocalAppData $proj1) -eq 'review-required') (Get-RecordedCategory $hc1.LocalAppData $proj1)
    Check 'bounded metadata only - no candidate file content appears in the report' ($r.Out -notmatch 'cache-content') $r.Out

    # =====================================================================
    Write-Host '--- review/diagnostic artifacts survive and are classified as such ---' -ForegroundColor Cyan
    $hc2 = New-IsolatedHookCopy
    $proj2 = New-GitRepo 'ReviewArtifacts'
    Add-Commit $proj2 'init'
    Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'SessionStart' -LocalAppData $hc2.LocalAppData | Out-Null
    $coverageDir = New-Dir (Join-Path $proj2 'coverage')
    Write-Utf8 (Join-Path $coverageDir 'lcov.info') 'data'
    $r = Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'Stop' -LocalAppData $hc2.LocalAppData
    Check 'a review artifact directory still exists after Stop' (Test-Path -LiteralPath (Join-Path $coverageDir 'lcov.info'))
    Check 'it is classified review-or-diagnostic, never likely-disposable' (
        $r.Out -match 'coverage \| class=review-or-diagnostic' -and $r.Out -notmatch 'coverage \| class=likely-disposable') $r.Out

    # =====================================================================
    Write-Host '--- tracked and staged candidates survive and are protected ---' -ForegroundColor Cyan
    $hc3 = New-IsolatedHookCopy
    $proj3 = New-GitRepo 'TrackedStaged'
    $trackedCache = New-Cache $proj3 '.pytest_cache'
    Add-Commit $proj3 'commit the cache so it is tracked'
    $stagedCache = New-Cache $proj3 '.mypy_cache'
    & git -C $proj3 add .mypy_cache
    Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'SessionStart' -LocalAppData $hc3.LocalAppData | Out-Null
    # One genuinely untracked candidate alongside them, so a report is emitted
    # and the protected classifications are observable in the same output.
    $untrackedCache = New-Cache $proj3 '.ruff_cache'
    $r = Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'Stop' -LocalAppData $hc3.LocalAppData
    Check 'a tracked candidate still exists' (Test-Path -LiteralPath (Join-Path $trackedCache 'x.txt'))
    Check 'a staged candidate still exists' (Test-Path -LiteralPath (Join-Path $stagedCache 'x.txt'))
    Check 'the untracked candidate still exists too' (Test-Path -LiteralPath (Join-Path $untrackedCache 'x.txt'))
    Check 'the tracked one is git=tracked and class=protected' (
        $r.Out -match (Get-CandidateLinePattern '.pytest_cache' 'protected' 'tracked')) $r.Out
    Check 'the staged one is git=staged and class=protected' (
        $r.Out -match (Get-CandidateLinePattern '.mypy_cache' 'protected' 'staged')) $r.Out
    Check 'only the untracked one is described as likely-disposable' (
        $r.Out -match (Get-CandidateLinePattern '.ruff_cache' 'likely-disposable' 'untracked') -and
        (([regex]::Matches($r.Out, 'class=likely-disposable')).Count -eq 1)) $r.Out

    # Protected-only: nothing to remediate, so the release gate still sees clean.
    $hc3b = New-IsolatedHookCopy
    $proj3b = New-GitRepo 'TrackedOnly'
    New-Cache $proj3b '.pytest_cache' | Out-Null
    Add-Commit $proj3b 'commit the cache so it is tracked'
    Fire -HookPath $hc3b.Script -Cwd $proj3b -EventName 'SessionStart' -LocalAppData $hc3b.LocalAppData | Out-Null
    $rProtectedOnly = Fire -HookPath $hc3b.Script -Cwd $proj3b -EventName 'Stop' -LocalAppData $hc3b.LocalAppData
    $recProtectedOnly = Get-RecordedResult $hc3b.LocalAppData $proj3b
    Check 'a protected-only project is silent and recorded clean' (
        $rProtectedOnly.Out -eq '' -and (Get-RecordedCategory $hc3b.LocalAppData $proj3b) -eq 'clean') $rProtectedOnly.Out
    Check 'the candidate was still seen and counted, just not review-requiring' (
        $null -ne $recProtectedOnly -and [int](Get-Field $recProtectedOnly 'candidateCount') -eq 1 -and
        [int](Get-Field $recProtectedOnly 'reviewCount') -eq 0)

    # =====================================================================
    Write-Host '--- junctions/reparse points: never followed, target untouched ---' -ForegroundColor Cyan
    $hc4 = New-IsolatedHookCopy
    $proj4 = New-GitRepo 'JunctionSafe'
    Add-Commit $proj4 'init'
    Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'SessionStart' -LocalAppData $hc4.LocalAppData | Out-Null
    $realOutside = New-Dir (Join-Path $Work 'OutsideRealCache')
    Write-Utf8 (Join-Path $realOutside 'guard.txt') 'do-not-delete'
    $junctionPath = Join-Path $proj4 '.pytest_cache'
    $junctionOk = $false
    try { & cmd /c mklink /J "$junctionPath" "$realOutside" *> $null; $junctionOk = (Test-Path -LiteralPath $junctionPath) } catch { }
    if ($junctionOk) {
        # A real untracked candidate alongside it, so a report is emitted and the
        # junction's classification is observable.
        New-Cache $proj4 '.ruff_cache' | Out-Null
        $r = Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'Stop' -LocalAppData $hc4.LocalAppData
        Check 'a junction named like a cache still exists' (Test-Path -LiteralPath $junctionPath)
        Check 'the real directory the junction points to is untouched' ([System.IO.File]::ReadAllText((Join-Path $realOutside 'guard.txt')) -eq 'do-not-delete')
        Check 'the junction is reported class=protected with link=reparse-point' (
            $r.Out -match ((Get-CandidateLinePattern '.pytest_cache' 'protected' '[a-z-]+') + ' \| link=reparse-point')) $r.Out
        Check 'the junction is never described as disposable' (
            $r.Out -notmatch '\.pytest_cache \| class=likely-disposable') $r.Out
    }
    else {
        Write-Host '  (skipped: could not create a test junction on this host)' -ForegroundColor DarkYellow
    }

    # =====================================================================
    Write-Host '--- .kiro is hard-pruned: never surfaced, never descended into ---' -ForegroundColor Cyan
    $hc5 = New-IsolatedHookCopy
    $proj5 = New-GitRepo 'KiroPruned'
    Add-Commit $proj5 'init'
    Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'SessionStart' -LocalAppData $hc5.LocalAppData | Out-Null
    $kiroDir = New-Dir (Join-Path $proj5 '.kiro')
    Write-Utf8 (Join-Path $kiroDir 'settings.json') '{}'
    $kiroNested = New-Cache (Join-Path $proj5 '.kiro') '.pytest_cache'
    $nodeNested = New-Cache (New-Dir (Join-Path $proj5 'node_modules')) '.pytest_cache'
    $r = Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'Stop' -LocalAppData $hc5.LocalAppData
    Check '.kiro itself is never surfaced as a candidate' ($r.Out -notmatch '\.kiro') $r.Out
    Check 'a cache nested inside .kiro is never discovered (not descended into)' ($r.Out -notmatch 'pytest_cache') $r.Out
    Check '.kiro and its nested cache still exist on disk' ((Test-Path -LiteralPath (Join-Path $kiroDir 'settings.json')) -and (Test-Path -LiteralPath $kiroNested))
    Check 'a cache nested inside node_modules is still never discovered either' ((Test-Path -LiteralPath $nodeNested) -and $r.Out -notmatch 'node_modules') $r.Out
    Check 'with only hard-pruned content present the state is clean and silent' (
        $r.Out -eq '' -and (Get-RecordedCategory $hc5.LocalAppData $proj5) -eq 'clean') ((Get-RecordedCategory $hc5.LocalAppData $proj5) + '|' + $r.Out)

    # =====================================================================
    Write-Host '--- STATIC: the hook AST contains no project-mutation primitive ---' -ForegroundColor Cyan
    # Parsed, not grepped: a COMMENT mentioning Remove-Item must not fail this,
    # and a real invocation must not slip through as a differently spelled string.
    $parseErrors = $null
    $hookAst = [System.Management.Automation.Language.Parser]::ParseFile($Hook, [ref]$null, [ref]$parseErrors)
    Check 'the hook parses with no errors' (@($parseErrors).Count -eq 0) (@($parseErrors) -join '; ')
    $commandAsts = @($hookAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
    $forbiddenCmdlets = @('Remove-Item', 'Move-Item', 'Rename-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Clear-Content')
    $mutating = New-Object System.Collections.Generic.List[string]
    foreach ($commandAst in $commandAsts) {
        $name = $commandAst.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($forbiddenCmdlets -contains $name) { [void]$mutating.Add($commandAst.Extent.StartLineNumber.ToString() + ':' + $name) }
    }
    Check 'no Remove/Move/Rename/Set-Content/Add-Content/Out-File invocation exists in reachable code' (
        $mutating.Count -eq 0) (($mutating.ToArray()) -join ', ')
    # The hook's header names those primitives verbatim while invoking none of
    # them. That makes the AST check self-proving: it passes with the literal
    # strings present in the file, so it cannot be a disguised text grep - and a
    # future rewrite into a text grep would fail here immediately.
    $hookRawText = [System.IO.File]::ReadAllText($Hook)
    Check 'the prohibited names DO appear verbatim in the file, proving the check is AST-based not textual' (
        $hookRawText -match 'Remove-Item' -and $hookRawText -match 'Out-File' -and $hookRawText -match 'git clean')
    Check 'the hook documents the prohibition in prose' ($hookRawText -match 'never deletes')
    $gitMutating = @('clean', 'reset', 'rm', 'add', 'restore', 'checkout', 'stash')
    $gitOffenders = New-Object System.Collections.Generic.List[string]
    foreach ($commandAst in $commandAsts) {
        $strings = @($commandAst.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            ForEach-Object { $_.Value })
        if ($strings -notcontains 'git') { continue }
        foreach ($value in $strings) {
            # Case-sensitive: git subcommands are lowercase, and a .NET member
            # named Add must never be mistaken for `git add`.
            if ($gitMutating -ccontains $value) { [void]$gitOffenders.Add($commandAst.Extent.StartLineNumber.ToString() + ':git ' + $value) }
        }
    }
    Check 'no git invocation uses clean/reset/rm/add/restore/checkout/stash' ($gitOffenders.Count -eq 0) (($gitOffenders.ToArray()) -join ', ')
    # State writes must be identifiable: the only write helper is
    # Write-JsonFileAtomic, and every -Path it receives is a variable (a
    # $stateDir-derived path), never a literal or a project path expression.
    $writeCalls = @($commandAsts | Where-Object { $_.GetCommandName() -eq 'Write-JsonFileAtomic' })
    Check 'the hook does write state through Write-JsonFileAtomic' ($writeCalls.Count -gt 0)
    $badPathArgs = New-Object System.Collections.Generic.List[string]
    foreach ($writeCall in $writeCalls) {
        $elements = @($writeCall.CommandElements)
        $found = $false
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($element.ParameterName -ne 'Path') { continue }
            $argument = if ($null -ne $element.Argument) { $element.Argument } elseif (($i + 1) -lt $elements.Count) { $elements[$i + 1] } else { $null }
            $found = $true
            if ($argument -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                [void]$badPathArgs.Add($writeCall.Extent.StartLineNumber.ToString() + ':non-variable -Path')
            }
        }
        if (-not $found) { [void]$badPathArgs.Add($writeCall.Extent.StartLineNumber.ToString() + ':no -Path') }
    }
    Check 'every state write targets a variable path, never a literal/project path' ($badPathArgs.Count -eq 0) (($badPathArgs.ToArray()) -join ', ')
    $localAppDataRefs = @($hookAst.FindAll({
        $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $args[0].VariablePath.UserPath -eq 'env:LOCALAPPDATA' }, $true))
    Check 'state lives under %LOCALAPPDATA%, i.e. Hook Maker private state' ($localAppDataRefs.Count -gt 0)

    # =====================================================================
    Write-Host '--- deletion settings are gone from the documented config ---' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $EnvExample -PathType Leaf) {
        $envText = [System.IO.File]::ReadAllText($EnvExample)
        $removedKeys = @('AUTO_DELETE_SAFE', 'DELETE_REVIEW_ARTIFACTS', 'DELETE_PREEXISTING_SAFE_CACHES', 'MAX_DELETE_PATHS', 'MAX_DELETE_BYTES', 'EXTRA_SAFE_PATTERNS', 'EXTRA_REVIEW_PATTERNS')
        $stillThere = @($removedKeys | Where-Object { $envText -match ('(?m)^\s*' + [regex]::Escape($_) + '\s*=') })
        Check 'every deletion-era setting is removed from .env.example' ($stillThere.Count -eq 0) ($stillThere -join ', ')
        $requiredKeys = @('EVENTS', 'CLIENTS', 'TARGET_PROJECTS', 'MAX_SCAN_ENTRIES', 'MAX_SCAN_DEPTH', 'MAX_FINDINGS', 'ENABLE_SUBAGENT_STOP', 'EXTRA_CANDIDATE_NAMES', 'EXTRA_REVIEW_NAMES')
        $missing = @($requiredKeys | Where-Object { $envText -notmatch ('(?m)^\s*' + [regex]::Escape($_) + '\s*=') })
        Check 'the final setting set is documented in .env.example' ($missing.Count -eq 0) ($missing -join ', ')
        $hookText = [System.IO.File]::ReadAllText($Hook)
        $readsRemoved = @($removedKeys | Where-Object { $hookText -match [regex]::Escape($_) })
        Check 'the hook itself no longer mentions any deletion setting' ($readsRemoved.Count -eq 0) ($readsRemoved -join ', ')
    }

    # =====================================================================
    Write-Host '--- SHARED CONTRACT: the category list matches Cloudflare-Deploy ---' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $CloudflareHook -PathType Leaf) {
        $expected = @('clean', 'review-required', 'residue-confirmed', 'partial', 'unknown')
        $hookText = [System.IO.File]::ReadAllText($Hook)
        $cfText = [System.IO.File]::ReadAllText($CloudflareHook)
        $listPattern = ($expected | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Check 'the producer declares the exact category list' ($hookText -match [regex]::Escape($listPattern)) $listPattern
        Check 'the consumer declares the identical category list' ($cfText -match [regex]::Escape($listPattern)) $listPattern
        Check 'the consumer treats only clean as release-ready' (
            $cfText -match [regex]::Escape("CleanupReleaseReadyCategories = @('clean')")) $cfText
        Check 'the old deletion-era categories are gone from the consumer' (
            $cfText -notmatch 'safe-cleaned' -and $cfText -notmatch 'review-only-preserved') $cfText
    }

    # =====================================================================
    Write-Host '--- missing baseline is conservative and deletes nothing ---' -ForegroundColor Cyan
    $hc6 = New-IsolatedHookCopy
    $proj6 = New-GitRepo 'MissingBaseline'
    Add-Commit $proj6 'init'
    $orphanCache = New-Cache $proj6
    $orphanTmp = New-Cache $proj6 '.test-tmp'
    # No SessionStart fired at all -> no baseline for this session.
    $r = Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'Stop' -LocalAppData $hc6.LocalAppData
    Check 'without a baseline NOTHING is deleted' ((Test-Path -LiteralPath $orphanCache) -and (Test-Path -LiteralPath $orphanTmp))
    Check 'without a baseline every candidate is ambiguous, never disposable' (
        $r.Out -match 'class=ambiguous' -and $r.Out -notmatch 'class=likely-disposable') $r.Out
    Check 'the named cause baseline-missing is reported' ($r.Out -match 'baseline-missing') $r.Out
    Check 'the recorded category is unknown, never clean' ((Get-RecordedCategory $hc6.LocalAppData $proj6) -eq 'unknown') (Get-RecordedCategory $hc6.LocalAppData $proj6)

    # =====================================================================
    Write-Host '--- MAX_SCAN_ENTRIES: partial, never clean (defect B-06) ---' -ForegroundColor Cyan
    $hc7 = New-IsolatedHookCopy -EnvOverrides @{ MAX_SCAN_ENTRIES = '1' }
    $proj7 = New-GitRepo 'ScanLimit'
    Write-Utf8 (Join-Path $proj7 'a.txt') 'a'
    Add-Commit $proj7 'init'
    $rStart = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'SessionStart' -LocalAppData $hc7.LocalAppData
    Check 'SessionStart is NOT silent when its own baseline scan was partial' (
        $rStart.Out -match 'PARTIAL' -and $rStart.Out -match 'max-scan-entries-reached') $rStart.Out
    $r = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'Stop' -LocalAppData $hc7.LocalAppData
    Check 'hitting the scan-entry ceiling records partial, NEVER clean' ((Get-RecordedCategory $hc7.LocalAppData $proj7) -eq 'partial') (Get-RecordedCategory $hc7.LocalAppData $proj7)
    Check 'the named cause max-scan-entries-reached is reported' ($r.Out -match 'max-scan-entries-reached') $r.Out
    Check 'partial coverage gates completion so clean cannot be claimed' (
        $r.Out -match '"decision":"block"' -and $r.Out -match 'cannot be reported as clean') $r.Out

    # =====================================================================
    Write-Host '--- an unreadable directory yields a NAMED partial cause ---' -ForegroundColor Cyan
    $hc8 = New-IsolatedHookCopy
    $proj8 = New-GitRepo 'UnreadableDir'
    Add-Commit $proj8 'init'
    Fire -HookPath $hc8.Script -Cwd $proj8 -EventName 'SessionStart' -LocalAppData $hc8.LocalAppData | Out-Null
    $blocked = New-Dir (Join-Path $proj8 'blockedtree')
    Write-Utf8 (Join-Path $blocked 'inner.txt') 'x'
    $denyRule = $null
    try {
        $acl = Get-Acl -LiteralPath $blocked
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'ListDirectory', 'Deny')
        $acl.AddAccessRule($denyRule)
        Set-Acl -LiteralPath $blocked -AclObject $acl
        # Prove the fixture really is unreadable before asserting on the hook.
        $reallyBlocked = $false
        try { Get-ChildItem -LiteralPath $blocked -Force -ErrorAction Stop | Out-Null } catch { $reallyBlocked = $true }
        Check 'the fixture directory really cannot be enumerated' $reallyBlocked
        $r = Fire -HookPath $hc8.Script -Cwd $proj8 -EventName 'Stop' -LocalAppData $hc8.LocalAppData
        Check 'a directory-read failure is reported as directory-unreadable, not swallowed' ($r.Out -match 'directory-unreadable') $r.Out
        Check 'a directory-read failure records partial, never clean' ((Get-RecordedCategory $hc8.LocalAppData $proj8) -eq 'partial') (Get-RecordedCategory $hc8.LocalAppData $proj8)
        Check 'the blocked directory is still on disk afterwards' (Test-Path -LiteralPath $blocked)
    }
    finally {
        if ($null -ne $denyRule) {
            try {
                $restore = Get-Acl -LiteralPath $blocked
                [void]$restore.RemoveAccessRule($denyRule)
                Set-Acl -LiteralPath $blocked -AclObject $restore
            }
            catch { Write-Host '  (warning: could not restore the test ACL)' -ForegroundColor DarkYellow }
        }
    }

    # =====================================================================
    Write-Host '--- unknown git state is never classified as disposable ---' -ForegroundColor Cyan
    $hc9 = New-IsolatedHookCopy
    # Deliberately NOT a git repository, so every candidate has unknown git state.
    $proj9 = New-Proj 'NoGitRepo'
    Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'SessionStart' -LocalAppData $hc9.LocalAppData | Out-Null
    $noGitCache = New-Cache $proj9
    $r = Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'Stop' -LocalAppData $hc9.LocalAppData
    Check 'a candidate with unknown git state still exists' (Test-Path -LiteralPath $noGitCache)
    Check 'it is classified unknown-git-state, never likely-disposable' (
        $r.Out -match 'class=unknown-git-state' -and $r.Out -notmatch 'class=likely-disposable') $r.Out
    Check 'git=unknown is reported explicitly, not downgraded to untracked' ($r.Out -match 'git=unknown') $r.Out
    Check 'the recorded category is unknown, never clean' ((Get-RecordedCategory $hc9.LocalAppData $proj9) -eq 'unknown') (Get-RecordedCategory $hc9.LocalAppData $proj9)

    # =====================================================================
    Write-Host '--- anti-loop: unchanged evidence suppressed, changed evidence re-reports ---' -ForegroundColor Cyan
    $hc10 = New-IsolatedHookCopy
    $proj10 = New-GitRepo 'AntiLoop'
    Add-Commit $proj10 'init'
    Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'SessionStart' -LocalAppData $hc10.LocalAppData | Out-Null
    $loopCache = New-Cache $proj10
    $r1 = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    Check 'the first Stop reports review-required' ($r1.Out -match 'need YOUR review') $r1.Out
    $r2 = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    Check 'a still-present previously surfaced candidate becomes residue-confirmed' (
        $r2.Out -match 'STILL PRESENT' -and (Get-RecordedCategory $hc10.LocalAppData $proj10) -eq 'residue-confirmed') $r2.Out
    Check 'residue-confirmed gates completion' ($r2.Out -match '"decision":"block"') $r2.Out
    Check 'residue-confirmed never claims the hook itself confirmed disposability' (
        $r2.Out -match 'has NOT itself confirmed any path is safe to delete') $r2.Out
    $r3 = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    Check 'the SAME unchanged evidence does not report again (no loop)' ($r3.Exit -eq 0 -and $r3.Out -eq '') $r3.Out
    Check 'the coordination record is still refreshed while suppressed' ((Get-RecordedCategory $hc10.LocalAppData $proj10) -eq 'residue-confirmed') (Get-RecordedCategory $hc10.LocalAppData $proj10)
    $newCache = New-Cache $proj10 '.ruff_cache'
    $r4 = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    Check 'materially CHANGED evidence re-reports despite the earlier fingerprint' (
        $r4.Out -ne '' -and $r4.Out -match 'ruff_cache') $r4.Out
    Check 'and still nothing was deleted across all four Stops' ((Test-Path -LiteralPath $loopCache) -and (Test-Path -LiteralPath $newCache))

    # =====================================================================
    Write-Host '--- client adapters carry the same semantic instruction ---' -ForegroundColor Cyan
    $hc11 = New-IsolatedHookCopy
    $proj11 = New-GitRepo 'ClaudeShape'
    Add-Commit $proj11 'init'
    Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'SessionStart' -LocalAppData $hc11.LocalAppData | Out-Null
    New-Cache $proj11 | Out-Null
    $rClaude = Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'Stop' -LocalAppData $hc11.LocalAppData
    Check 'Claude advisory uses hookSpecificOutput.additionalContext, not decision:block' (
        $rClaude.Out -match '"additionalContext"' -and $rClaude.Out -notmatch '"decision"') $rClaude.Out
    Check 'Claude advisory carries the full instruction' (Test-HasFullInstruction $rClaude.Out) $rClaude.Out

    $hc12 = New-IsolatedHookCopy
    $proj12 = New-GitRepo 'CodexShape'
    Add-Commit $proj12 'init'
    Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'SessionStart' -LocalAppData $hc12.LocalAppData -NoClaudeProjectDir | Out-Null
    New-Cache $proj12 | Out-Null
    $rCodex = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'Stop' -LocalAppData $hc12.LocalAppData -NoClaudeProjectDir
    Check 'Codex advisory uses systemMessage, not hookSpecificOutput/decision' (
        $rCodex.Out -match '"systemMessage"' -and $rCodex.Out -notmatch 'hookSpecificOutput' -and $rCodex.Out -notmatch '"decision"') $rCodex.Out
    Check 'Codex advisory carries the SAME full instruction' (Test-HasFullInstruction $rCodex.Out) $rCodex.Out
    # The gate shape is identical for both supported clients, so a blocking
    # message needs no per-client branch - proven by the residue block above.
    Check 'the blocking gate shape is client-independent (decision:block)' ($r2.Out -match '"decision":"block"') $r2.Out
    # TODO(kiro): a third client (Kiro) is being added to Hook Maker in a
    # separate workstream and its output protocol is not settled. No Kiro shape
    # is asserted here because inventing one would encode a guess. The semantic
    # contract is already covered host-independently by Test-HasFullInstruction:
    # when the Kiro branch lands, add one Fire case with its detection signal and
    # assert Test-HasFullInstruction on the result - nothing else should change.
    Check 'the semantic instruction is asserted independently of any JSON envelope (Kiro-ready)' (
        (Test-HasFullInstruction $rClaude.Out) -and (Test-HasFullInstruction $rCodex.Out))

    # =====================================================================
    Write-Host '--- stop_hook_active and SubagentStop-off guards ---' -ForegroundColor Cyan
    $hc13 = New-IsolatedHookCopy
    $proj13 = New-GitRepo 'Guards'
    Add-Commit $proj13 'init'
    Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'SessionStart' -LocalAppData $hc13.LocalAppData | Out-Null
    $guardCache = New-Cache $proj13
    $rGuard = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'Stop' -LocalAppData $hc13.LocalAppData -StopHookActive
    Check 'stop_hook_active short-circuits before any scan' ($rGuard.Exit -eq 0 -and $rGuard.Out -eq '' -and (Test-Path -LiteralPath $guardCache))
    $rSub = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'SubagentStop' -LocalAppData $hc13.LocalAppData
    Check 'SubagentStop is silent by default (ENABLE_SUBAGENT_STOP=false)' ($rSub.Exit -eq 0 -and $rSub.Out -eq '' -and (Test-Path -LiteralPath $guardCache))

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $hc14 = New-IsolatedHookCopy
    $proj14 = New-GitRepo 'Ps5'
    Add-Commit $proj14 'init'
    $r = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'SessionStart' -LocalAppData $hc14.LocalAppData -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 SessionStart runs cleanly and silently' ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') $r.Err
    $ps5Cache = New-Cache $proj14
    $r = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'Stop' -LocalAppData $hc14.LocalAppData -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 Stop reports cleanly with no stderr' ($r.Exit -eq 0 -and $r.Out -match 'TEST TEMP CLEANUP' -and $r.Err -eq '') $r.Err
    Check 'Windows PowerShell 5.1 carries the full instruction too' (Test-HasFullInstruction $r.Out) $r.Out
    Check 'Windows PowerShell 5.1 deleted nothing either' (Test-Path -LiteralPath $ps5Cache)
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
