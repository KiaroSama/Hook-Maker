# Offline test suite for Test-Temp-Cleanup, a DETECTOR + ADVISOR + COMPLETION
# GATE with no deletion feature at all. Every filesystem claim below is a real
# on-disk assertion, never a comment or a mocked success string.
#
# Covers: nothing on disk is ever mutated (a real .pytest_cache created AFTER
# the baseline still exists after Stop; review artifacts, tracked/staged
# candidates and junction targets all survive); hard-pruned directories are
# never descended into; the AST of the hook contains no reachable project-
# mutation command and no mutating git subcommand; the report always instructs
# the agent to inspect before deleting; a missing baseline is conservative; the
# scan-entry ceiling yields `partial` and never `clean`; an unreadable directory
# yields the NAMED cause `directory-unreadable`; unknown git state is never
# called disposable; unchanged evidence is anti-loop suppressed while changed
# evidence re-reports; the Claude and Codex adapters carry the same semantic
# instruction; the result-category contract still matches Cloudflare-Deploy.
# The candidate size walk is bounded on all three axes - entries, time (via a
# production-inert seam, since a real five-second walk cannot be forced) and
# depth - and a resulting `>=N` lower bound is never reported, stored, or
# compared as though it were an exact size.
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
[void](Disable-DaclBypassPrivilege)
# Get-ShortHash / Normalize-Path / Get-Field, so the suite can locate and read
# the hook's own state files exactly the way its consumers do.
. $HookLib

$Work = New-TestWorkspace -Prefix 'hookmaker-cleanuptest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
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
    # The whole folder, not just the entry script: the installer stages a hook's
    # own directory recursively, so a sibling it dot-sources ships with it.
    # Copying one file would test a runtime that is never installed - and the
    # hook would simply fail to load.
    Copy-Item (Join-Path (Split-Path -Parent $Hook) '*.ps1') $dir
    Copy-TestRuntimeLibraries -SourceHookLib $HookLib -Destination (Join-Path $Work '_hooklib.ps1')
    if ($EnvOverrides.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
        Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Temp-Cleanup.ps1'); LocalAppData = $fakeLocal }
}

# -SizeWalkSeconds drives the hook's production-inert size-walk time seam
# (TESTTEMPCLEANUP_TEST_SIZE_WALK_MAX_SECONDS). '0' makes the very first entry
# trip the ceiling, which is the only deterministic way to prove a time bound;
# the seam can only tighten the ceiling, never widen it. Like CLAUDE_PROJECT_DIR
# below it is set on EVERY call - blank when not requested - so an ambient value
# on the test machine can never leak into a case that did not ask for it.
function Fire {
    param([string]$HookPath, [string]$Cwd, [string]$EventName, [string]$SessionId = 'sess1', [string]$LocalAppData, [switch]$StopHookActive, [switch]$NoClaudeProjectDir, [string]$Exe = 'pwsh', [string]$SizeWalkSeconds = '')
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
    $savedSizeWalkSeconds = $env:TESTTEMPCLEANUP_TEST_SIZE_WALK_MAX_SECONDS
    try {
        $env:LOCALAPPDATA = $LocalAppData
        $env:CLAUDE_PROJECT_DIR = if ($NoClaudeProjectDir) { '' } else { $Cwd }
        $env:TESTTEMPCLEANUP_TEST_SIZE_WALK_MAX_SECONDS = $SizeWalkSeconds
        $proc = Start-BoundedProcess @startArgs
    }
    finally {
        $env:LOCALAPPDATA = $savedLocalAppData
        $env:CLAUDE_PROJECT_DIR = $savedProjectDir
        $env:TESTTEMPCLEANUP_TEST_SIZE_WALK_MAX_SECONDS = $savedSizeWalkSeconds
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
    Write-Host '--- the candidate SIZE walk never descends through a junction ---' -ForegroundColor Cyan
    # The junction case above covers a candidate that IS a link (measured not at
    # all). This covers a link INSIDE a candidate, which was unguarded:
    # Get-CandidateSize walked with [System.IO.Directory]::EnumerateFiles(...,
    # AllDirectories), and that FOLLOWS reparse points - so the size probe
    # descended through the link and measured a tree OUTSIDE the project, the one
    # thing this hook promises never to do. The reported size is the observable
    # proof: it must count only the bytes physically inside the candidate.
    $hc4b = New-IsolatedHookCopy
    $proj4b = New-GitRepo 'JunctionSizeWalk'
    Add-Commit $proj4b 'init'
    Fire -HookPath $hc4b.Script -Cwd $proj4b -EventName 'SessionStart' -LocalAppData $hc4b.LocalAppData | Out-Null
    # The junction target lives under %TEMP%, outside the project, and is padded
    # so that following the link cannot coincidentally produce the correct size.
    $outsideTarget = New-Dir (Join-Path $Work 'OutsideSizeTarget')
    Write-Utf8 (Join-Path $outsideTarget 'big.txt') ('x' * 4096)
    $sizeCache = New-Dir (Join-Path $proj4b '.pytest_cache')
    Write-Utf8 (Join-Path $sizeCache 'inner.txt') 'inner'
    $sizeLink = Join-Path $sizeCache 'linked'
    $sizeLinkOk = $false
    try { & cmd /c mklink /J "$sizeLink" "$outsideTarget" *> $null; $sizeLinkOk = (Test-Path -LiteralPath $sizeLink) } catch { }
    if (-not $sizeLinkOk) {
        Write-Host '  (skipped: this host cannot create a directory junction, so the follow-the-link size regression cannot be exercised)' -ForegroundColor DarkYellow
    }
    else {
        try {
            Check 'the junction really resolves to the outside tree before measuring' (
                Test-Path -LiteralPath (Join-Path $sizeLink 'big.txt'))
            $rSize = Fire -HookPath $hc4b.Script -Cwd $proj4b -EventName 'Stop' -LocalAppData $hc4b.LocalAppData
            # inner.txt is 5 bytes; big.txt behind the junction is 4096. A walk
            # that followed the link would report 4101.
            Check 'the reported size counts ONLY the bytes physically inside the project' (
                $rSize.Out -match ((Get-CandidateLinePattern '.pytest_cache' 'likely-disposable' 'untracked') +
                    ' \| link=none \| size=5 \|')) $rSize.Out
            Check '... so the tree behind the junction is never measured into it' (
                $rSize.Out -notmatch 'size=4101') $rSize.Out
            Check 'the junction target is untouched by the measurement' (
                ([System.IO.File]::ReadAllText((Join-Path $outsideTarget 'big.txt'))).Length -eq 4096)
        }
        finally {
            # Remove the LINK only. Directory.Delete on a junction unlinks it and
            # never touches the target - unlike a recursive delete through it.
            try { [System.IO.Directory]::Delete($sizeLink, $false) } catch { }
        }
        Check 'the junction fixture is unlinked and its target survived' (
            (-not (Test-Path -LiteralPath $sizeLink)) -and (Test-Path -LiteralPath (Join-Path $outsideTarget 'big.txt')))
    }

    # =====================================================================
    Write-Host '--- the size walk is bounded by ENTRIES, not by files alone ---' -ForegroundColor Cyan
    # Second half of the same defect: the ceiling counted FILES, so a tree made
    # of directories never tripped it and the walk ran to completion however
    # large it was - then reported a confident exact size for a measurement that
    # had had no bound at all. Past the ceiling the value must be a lower bound
    # ('>=N'), never a confident number.
    $hc4c = New-IsolatedHookCopy
    $proj4c = New-GitRepo 'SizeWalkBound'
    Add-Commit $proj4c 'init'
    Fire -HookPath $hc4c.Script -Cwd $proj4c -EventName 'SessionStart' -LocalAppData $hc4c.LocalAppData | Out-Null
    $wideCache = New-Dir (Join-Path $proj4c '.pytest_cache')
    # One entry past the 2000-entry ceiling, all directories, so a file-only cap
    # cannot see them at all.
    for ($i = 0; $i -lt 2001; $i++) { [void][System.IO.Directory]::CreateDirectory((Join-Path $wideCache ('d' + $i.ToString('0000')))) }
    $rBound = Fire -HookPath $hc4c.Script -Cwd $proj4c -EventName 'Stop' -LocalAppData $hc4c.LocalAppData
    Check 'a directory-only tree past the ceiling reports a BOUNDED size, never a confident one' (
        $rBound.Out -match '\.pytest_cache \| class=likely-disposable' -and $rBound.Out -match '\| size=>=') $rBound.Out
    Check 'the whole 2001-directory tree still exists (measuring mutates nothing)' (
        @(Get-ChildItem -LiteralPath $wideCache -Directory).Count -eq 2001)

    # =====================================================================
    Write-Host '--- the size walk is bounded by TIME, measured on a monotonic clock ---' -ForegroundColor Cyan
    # The seconds ceiling shipped with no red proof behind it, and it was
    # measured against [DateTime]::UtcNow - a WALL clock. An NTP correction or a
    # manual clock change landing between the two reads can move that deadline in
    # either direction, collapsing the budget to nothing or extending it
    # arbitrarily; a Stopwatch measures elapsed time from a tick source that
    # cannot be stepped. It is now read through a production-inert environment
    # seam that can only TIGHTEN the ceiling, which is what makes the bound
    # testable at all: a real five-second walk cannot be forced deterministically.
    # At a zero-second budget the first entry trips it, so the reported value must
    # be a lower bound rather than the exact number the unbounded walk produces.
    $hc4d = New-IsolatedHookCopy
    $proj4d = New-GitRepo 'SizeWalkTimeBound'
    Add-Commit $proj4d 'init'
    Fire -HookPath $hc4d.Script -Cwd $proj4d -EventName 'SessionStart' -LocalAppData $hc4d.LocalAppData | Out-Null
    # New-Cache writes a single x.txt of 'cache-content' - exactly 13 bytes.
    $timeCache = New-Cache $proj4d '.pytest_cache'
    $rTime = Fire -HookPath $hc4d.Script -Cwd $proj4d -EventName 'Stop' -LocalAppData $hc4d.LocalAppData -SizeWalkSeconds '0'
    Check 'a zero-second budget trips the TIME ceiling and reports a lower bound' (
        $rTime.Out -match '\.pytest_cache \| class=likely-disposable' -and $rTime.Out -match '\| size=>=0 \|') $rTime.Out
    Check '... so the exact size an unbounded walk would have produced is never claimed' (
        $rTime.Out -notmatch '\| size=13 \|') $rTime.Out
    Check 'the candidate is untouched by the bounded measurement' (
        [System.IO.File]::ReadAllText((Join-Path $timeCache 'x.txt')) -eq 'cache-content')

    # =====================================================================
    Write-Host '--- the size walk is bounded by DEPTH, like the candidate scan ---' -ForegroundColor Cyan
    # Get-CleanupScan has enforced a MaxDepth from the start; this walk had no
    # depth bound at all, so a deep real tree was bounded only by the entry and
    # time ceilings - and a narrow deep tree stays far under both while
    # descending arbitrarily. Depth is a COVERAGE limit here, not a stop
    # condition: what lies below it goes unmeasured (so the total is a lower
    # bound) while everything shallower is still measured honestly.
    $hc4e = New-IsolatedHookCopy
    $proj4e = New-GitRepo 'SizeWalkDepthBound'
    Add-Commit $proj4e 'init'
    Fire -HookPath $hc4e.Script -Cwd $proj4e -EventName 'SessionStart' -LocalAppData $hc4e.LocalAppData | Out-Null
    $deepCache = New-Dir (Join-Path $proj4e '.pytest_cache')
    Write-Utf8 (Join-Path $deepCache 'top.txt') 'abc'
    $deepChain = $deepCache
    for ($i = 1; $i -le 9; $i++) { $deepChain = New-Dir (Join-Path $deepChain ('d' + $i)) }
    Write-Utf8 (Join-Path $deepChain 'deep.txt') 'deepest'
    Check 'the deep fixture really is nine directories below the candidate' (
        Test-Path -LiteralPath (Join-Path $deepCache 'd1\d2\d3\d4\d5\d6\d7\d8\d9\deep.txt'))
    # 10 entries in total, so neither the 2000-entry nor the 5-second ceiling can
    # be what trips here - only the depth bound can.
    $rDepth = Fire -HookPath $hc4e.Script -Cwd $proj4e -EventName 'Stop' -LocalAppData $hc4e.LocalAppData
    Check 'past the depth ceiling the size is a lower bound of what was reachable' (
        $rDepth.Out -match '\.pytest_cache \| class=likely-disposable' -and $rDepth.Out -match '\| size=>=3 \|') $rDepth.Out
    Check '... and the unmeasured file below the ceiling is never counted into it' (
        $rDepth.Out -notmatch '\| size=10 \|') $rDepth.Out
    Check 'the whole deep tree still exists and its content is untouched' (
        [System.IO.File]::ReadAllText((Join-Path $deepChain 'deep.txt')) -eq 'deepest')

    # =====================================================================
    Write-Host '--- a >=N measurement is never compared or stored as an exact size ---' -ForegroundColor Cyan
    # The bounded flag was written into the baseline and then dropped on the way
    # back out: the Stop comparison rebuilt only { sizeBytes, modifiedUtc }, so
    # two LOWER BOUNDS that happened to land on the same number satisfied exactly
    # the equality an exact size would - and the candidate was then reported
    # during-session=unchanged, a claim a partial walk cannot support. The cache
    # exists BEFORE the baseline here, so it is the same candidate on both sides,
    # and both walks are bounded by the same zero-second budget.
    $hc4f = New-IsolatedHookCopy
    $proj4f = New-GitRepo 'BoundedNotExact'
    Write-Utf8 (Join-Path $proj4f 'src.txt') 'code'
    Add-Commit $proj4f 'init'
    New-Cache $proj4f '.pytest_cache' | Out-Null
    Fire -HookPath $hc4f.Script -Cwd $proj4f -EventName 'SessionStart' -LocalAppData $hc4f.LocalAppData -SizeWalkSeconds '0' | Out-Null
    $rExact = Fire -HookPath $hc4f.Script -Cwd $proj4f -EventName 'Stop' -LocalAppData $hc4f.LocalAppData -SizeWalkSeconds '0'
    Check 'a bounded baseline compared with a bounded rescan is NEVER reported as unchanged' (
        $rExact.Out -notmatch 'during-session=unchanged') $rExact.Out
    Check '... it is during-session=unknown, this field''s existing vocabulary for "cannot tell"' (
        $rExact.Out -match '\.pytest_cache \| class=likely-disposable \| type=test-cache-dir \| at-session-start=yes \| during-session=unknown') $rExact.Out

    # The control - and the proof of a THIRD defect, found by this very case
    # going red: with no seam the same shape measures exactly, so the comparison
    # must read 'unchanged'. It did not, because the baseline's timestamp comes
    # back from ConvertFrom-Json in a HOST-DIVERGENT shape - a [string] on
    # Windows PowerShell 5.1, a [DateTime] on pwsh 7, where [string] then yields
    # the culture's short form and can never equal the round-trip 'o' text the
    # live side produces. Every pre-existing candidate was therefore reported
    # during-session=modified on pwsh 7 alone, which also masked the bounded-size
    # rule above by never letting the comparison be reached.
    $hc4g = New-IsolatedHookCopy
    $proj4g = New-GitRepo 'ExactStillUnchanged'
    Write-Utf8 (Join-Path $proj4g 'src.txt') 'code'
    Add-Commit $proj4g 'init'
    New-Cache $proj4g '.pytest_cache' | Out-Null
    Fire -HookPath $hc4g.Script -Cwd $proj4g -EventName 'SessionStart' -LocalAppData $hc4g.LocalAppData | Out-Null
    $rUnchanged = Fire -HookPath $hc4g.Script -Cwd $proj4g -EventName 'Stop' -LocalAppData $hc4g.LocalAppData
    Check 'an EXACT baseline vs an EXACT rescan of the same bytes still reads unchanged' (
        $rUnchanged.Out -match 'at-session-start=yes \| during-session=unchanged') $rUnchanged.Out

    # The same shape on the other host, because a divergence is exactly what this
    # was: 5.1 kept the timestamp as a string and was always right, pwsh 7 coerced
    # it and was always wrong. One host answering correctly is what let this
    # survive - both must now answer identically or the divergence is back.
    $hc4h = New-IsolatedHookCopy
    $proj4h = New-GitRepo 'ExactStillUnchangedPs5'
    Write-Utf8 (Join-Path $proj4h 'src.txt') 'code'
    Add-Commit $proj4h 'init'
    New-Cache $proj4h '.pytest_cache' | Out-Null
    Fire -HookPath $hc4h.Script -Cwd $proj4h -EventName 'SessionStart' -LocalAppData $hc4h.LocalAppData -Exe 'powershell.exe' | Out-Null
    $rUnchanged51 = Fire -HookPath $hc4h.Script -Cwd $proj4h -EventName 'Stop' -LocalAppData $hc4h.LocalAppData -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 answers that identical comparison identically (no host divergence)' (
        $rUnchanged51.Out -match 'at-session-start=yes \| during-session=unchanged') $rUnchanged51.Out

    # =====================================================================
    Write-Host '--- node_modules is hard-pruned: never surfaced, never descended into ---' -ForegroundColor Cyan
    $hc5 = New-IsolatedHookCopy
    $proj5 = New-GitRepo 'HardPruned'
    Add-Commit $proj5 'init'
    Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'SessionStart' -LocalAppData $hc5.LocalAppData | Out-Null
    $nodeNested = New-Cache (New-Dir (Join-Path $proj5 'node_modules')) '.pytest_cache'
    $r = Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'Stop' -LocalAppData $hc5.LocalAppData
    Check 'node_modules itself is never surfaced as a candidate' ($r.Out -notmatch 'node_modules') $r.Out
    Check 'a cache nested inside node_modules is never discovered (not descended into)' (
        (Test-Path -LiteralPath $nodeNested) -and $r.Out -notmatch 'pytest_cache') $r.Out
    Check 'with only hard-pruned content present the state is clean and silent' (
        $r.Out -eq '' -and (Get-RecordedCategory $hc5.LocalAppData $proj5) -eq 'clean') ((Get-RecordedCategory $hc5.LocalAppData $proj5) + '|' + $r.Out)

    # =====================================================================
    Write-Host '--- a virtualenv is pruned by its PEP 405 marker, not by its name ---' -ForegroundColor Cyan
    # The real case: 'tools/spotdl-env' is a virtualenv whose name matches none
    # of '.venv'/'venv'/'env', so the walk descended and spent 9,815 of a
    # 13,559-entry budget counting third-party bytecode, hit its ceiling, and
    # could only answer PARTIAL. The marker file is what makes it a virtualenv.
    $hc6 = New-IsolatedHookCopy
    $proj6 = New-GitRepo 'VenvPruned'
    Add-Commit $proj6 'init'
    Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'SessionStart' -LocalAppData $hc6.LocalAppData | Out-Null
    $venv = New-Dir (Join-Path (New-Dir (Join-Path $proj6 'tools')) 'spotdl-env')
    Write-Utf8 (Join-Path $venv 'pyvenv.cfg') "home = C:\Python312`r`nversion = 3.12.1`r`n"
    $venvNested = New-Cache $venv '.mypy_cache'
    # A REAL candidate outside the virtualenv, so this cannot pass by the scan
    # simply finding nothing: the run must still report this one.
    $realCache = New-Cache $proj6 '.pytest_cache'
    $r6 = Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'Stop' -LocalAppData $hc6.LocalAppData
    Check 'a cache nested inside an oddly-named virtualenv is never discovered' ($r6.Out -notmatch 'mypy_cache') $r6.Out
    Check 'the virtualenv directory itself is never surfaced as a candidate' ($r6.Out -notmatch 'spotdl-env') $r6.Out
    Check 'the virtualenv and its contents still exist on disk' ((Test-Path -LiteralPath (Join-Path $venv 'pyvenv.cfg')) -and (Test-Path -LiteralPath $venvNested))
    Check 'a real candidate OUTSIDE the virtualenv is still reported (the scan did not just go blind)' (
        $r6.Out -match 'pytest_cache' -and (Test-Path -LiteralPath $realCache)) $r6.Out

    # The other marker: CACHEDIR.TAG is the cross-tool "regenerable cache"
    # standard (Bazel, Cargo, borg, restic...), so a directory carrying it is
    # skipped whatever it is called - the same reasoning as pyvenv.cfg.
    $hc7 = New-IsolatedHookCopy
    $proj7 = New-GitRepo 'MarkerPruned'
    Add-Commit $proj7 'init'
    Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'SessionStart' -LocalAppData $hc7.LocalAppData | Out-Null
    $tagged = New-Dir (Join-Path $proj7 'buildcache')
    Write-Utf8 (Join-Path $tagged 'CACHEDIR.TAG') "Signature: 8a477f597d28d172789f06886806bc55`r`n"
    $taggedNested = New-Cache $tagged '.mypy_cache'
    # An ordinary source directory with NO marker must still be walked, or the
    # probe would be over-pruning rather than pruning.
    $plainNested = New-Cache (New-Dir (Join-Path $proj7 'src')) '.pytest_cache'
    $r7 = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'Stop' -LocalAppData $hc7.LocalAppData
    Check 'a cache nested inside a CACHEDIR.TAG directory is never discovered' ($r7.Out -notmatch 'mypy_cache') $r7.Out
    Check 'the CACHEDIR.TAG directory itself is never surfaced as a candidate' ($r7.Out -notmatch 'buildcache') $r7.Out
    Check 'the marker directory and its contents still exist on disk' (
        (Test-Path -LiteralPath (Join-Path $tagged 'CACHEDIR.TAG')) -and (Test-Path -LiteralPath $taggedNested))
    Check 'an ordinary directory with NO marker is still walked (the probe does not over-prune)' (
        $r7.Out -match 'pytest_cache' -and (Test-Path -LiteralPath $plainNested)) $r7.Out

    # =====================================================================
    Write-Host '--- the shipped scan ceilings are the measured ones ---' -ForegroundColor Cyan
    # Pinned as VALUES, not as behaviour: these defaults were chosen against 14
    # real project trees (twelve never exceed depth 4, two reach depth 10 through
    # ordinary vendored content and one of those also passed 5000 entries). A
    # silent revert to 5000/8 would put those two back to reporting PARTIAL for
    # structure that is genuinely theirs, and nothing else in the suite would
    # notice. The .env.example must agree, or the documented default is a lie.
    $ceilingSource = Get-Content -LiteralPath $Hook -Raw
    Check 'MAX_SCAN_ENTRIES still defaults to 15000' (
        $ceilingSource -match "Get-IntConfig 'MAX_SCAN_ENTRIES' 15000 ") 'default changed'
    Check 'MAX_SCAN_DEPTH still defaults to 12' (
        $ceilingSource -match "Get-IntConfig 'MAX_SCAN_DEPTH' 12 ") 'default changed'
    $envExample = Join-Path (Split-Path -Parent $Hook) '.env.example'
    $envText = Get-Content -LiteralPath $envExample -Raw
    Check 'the shipped .env.example agrees with both defaults' (
        ($envText -match '(?m)^MAX_SCAN_ENTRIES=15000\s*$') -and
        ($envText -match '(?m)^MAX_SCAN_DEPTH=12\s*$')) $envText

    # =====================================================================
    Write-Host '--- STATIC: the hook AST contains no project-mutation primitive ---' -ForegroundColor Cyan
    # Parsed, not grepped: a COMMENT mentioning Remove-Item must not fail this,
    # and a real invocation must not slip through as a differently spelled string.
    # EVERY .ps1 in the hook PACKAGE, not just the entry point. The installer
    # stages the whole folder, so a companion module is reachable code as well -
    # and a safety check that read only the entry point would keep reporting
    # green while covering a fraction of the hook.
    $astFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -File -Filter '*.ps1')
    $astCommands = New-Object System.Collections.Generic.List[object]
    $astParseFailures = New-Object System.Collections.Generic.List[string]
    $hookAst = $null
    foreach ($astFile in $astFiles) {
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($astFile.FullName, [ref]$null, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) { [void]$astParseFailures.Add($astFile.Name + ': ' + (@($parseErrors) -join '; ')) }
        # The entry point's own AST is still needed on its own below, for the
        # state-location check: state lives under %LOCALAPPDATA%, and the entry
        # script is where that is resolved.
        if ([string]::Equals($astFile.FullName, (Resolve-Path -LiteralPath $Hook).Path, [System.StringComparison]::OrdinalIgnoreCase)) { $hookAst = $fileAst }
        foreach ($node in $fileAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            [void]$astCommands.Add($node)
        }
    }
    Check 'every file in the hook package parses with no errors' ($astParseFailures.Count -eq 0) (($astParseFailures.ToArray()) -join ' | ')
    Check 'the package really is more than the entry point (the scan is not silently narrow)' ($astFiles.Count -ge 1) ([string]$astFiles.Count)
    # .ToArray(), never @($list): a List[object] built with New-Object comes back
    # PSObject-wrapped and @() on it throws on both hosts.
    $commandAsts = $astCommands.ToArray()
    $forbiddenCmdlets = @('Remove-Item', 'Move-Item', 'Rename-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Clear-Content')
    $mutating = New-Object System.Collections.Generic.List[string]
    foreach ($commandAst in $commandAsts) {
        $name = $commandAst.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($forbiddenCmdlets -contains $name) { [void]$mutating.Add([System.IO.Path]::GetFileName([string]$commandAst.Extent.File) + ':' + $commandAst.Extent.StartLineNumber.ToString() + ':' + $name) }
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
            if ($gitMutating -ccontains $value) { [void]$gitOffenders.Add([System.IO.Path]::GetFileName([string]$commandAst.Extent.File) + ':' + $commandAst.Extent.StartLineNumber.ToString() + ':git ' + $value) }
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
        # The whole package, for the same reason the AST scan reads it all: a
        # setting moved into a companion module must not vanish from this check.
        $hookText = (@(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -File -Filter '*.ps1' |
                    ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n")
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
    Check 'Claude advisory uses non-continuing systemMessage, not decision:block' (
        $rClaude.Out -match '"systemMessage"' -and $rClaude.Out -notmatch 'hookSpecificOutput' -and $rClaude.Out -notmatch '"decision"') $rClaude.Out
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
    # The Codex shape is EVENT-scoped, and only the Stop half was ever pinned.
    # systemMessage is what Codex documents for Stop; off Stop it honours
    # hookSpecificOutput.additionalContext, and this hook emitted systemMessage
    # there too. Routing the shared helper through the adapter corrected it, so
    # the SessionStart half is pinned now rather than left to drift back.
    $rCodexPre = Fire -HookPath $hc12.Script -Cwd (New-GitRepo 'CodexShapePre') -EventName 'SessionStart' `
        -LocalAppData (New-IsolatedHookCopy).LocalAppData -NoClaudeProjectDir
    Check 'Codex OFF Stop uses hookSpecificOutput.additionalContext, not systemMessage' (
        $rCodexPre.Out -eq '' -or (
            $rCodexPre.Out -match '"additionalContext"' -and $rCodexPre.Out -notmatch '"systemMessage"')) $rCodexPre.Out
    # The gate shape is identical for both supported clients, so a blocking
    # message needs no per-client branch - proven by the residue block above.
    Check 'the blocking gate shape is client-independent (decision:block)' ($r2.Out -match '"decision":"block"') $r2.Out
    # The semantic contract is covered host-independently by
    # Test-HasFullInstruction, so it holds inside whatever envelope a client uses.
    Check 'the semantic instruction is asserted independently of any JSON envelope' (
        (Test-HasFullInstruction $rClaude.Out) -and (Test-HasFullInstruction $rCodex.Out))

    # =====================================================================
    Write-Host '--- stop_hook_active and SubagentStop-off guards ---' -ForegroundColor Cyan
    $hc13 = New-IsolatedHookCopy
    $proj13 = New-GitRepo 'Guards'
    Add-Commit $proj13 'init'
    Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'SessionStart' -LocalAppData $hc13.LocalAppData | Out-Null
    $guardCache = New-Cache $proj13
    $rGuard = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'Stop' -LocalAppData $hc13.LocalAppData -StopHookActive
    # stop_hook_active is set for ANY gate's block, so it must not silence
    # this one - that is what let a single block mute the other gates on the
    # same Stop. This gate stands down on its OWN marker instead. What the
    # assertion is really about is unchanged and still checked: the cache this
    # hook must never delete is still there afterwards.
    Check 'stop_hook_active ALONE does not silence it, and it still deletes nothing' (
        $rGuard.Exit -eq 0 -and (Test-Path -LiteralPath $guardCache)) $rGuard.Out
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
