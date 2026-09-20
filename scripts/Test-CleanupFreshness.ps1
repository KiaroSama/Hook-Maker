# Offline suite for the cleanup-evidence contract between
# hooks\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1 (producer) and
# hooks\Cloudflare-Deploy\_cleanupevidence.ps1 (consumer).
#
# It exercises the REAL code, never a copy:
#   * hooks\Cloudflare-Deploy\_cleanupevidence.ps1 is a pure module (constants +
#     three functions, no side effects) and is dot-sourced verbatim.
#   * Get-CleanupProjectKey / Get-CleanupResultPath / $script:CleanupCategories
#     are AST-extracted from Cloudflare-Deploy.ps1, whose top level executes on
#     load and therefore cannot be dot-sourced.
#   * The producer is parsed, never run: the mirror assertions compare its
#     SHIPPED detection tables and its emitted record shape against the
#     consumer's copies.
#
# Cost: one throwaway git repo, built once and reused; every case runs
# in-process. No hook is spawned, no install is performed, and there is no
# sleep anywhere - the cases that need "before"/"after" set file timestamps and
# record timestamps explicitly instead of waiting for a clock.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-CleanupFreshness.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HookLib = Join-Path $RepoRoot 'hooks\_hooklib.ps1'
$Consumer = Join-Path $RepoRoot 'hooks\Cloudflare-Deploy\Cloudflare-Deploy.ps1'
$Evidence = Join-Path $RepoRoot 'hooks\Cloudflare-Deploy\_cleanupevidence.ps1'
$Producer = Join-Path $RepoRoot 'hooks\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1'
# The record document is its own sibling now (the entry point is past the size
# ceiling). An assertion pointed at the entry point alone would cover a
# fraction of the contract while still reporting green.
$RecordBuilder = Join-Path $RepoRoot 'hooks\Test-Temp-Cleanup\_cleanuprecord.ps1'
foreach ($required in @($HookLib, $Consumer, $Evidence, $Producer)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}
if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'git is required by this suite (the fingerprint hint and the ignored-residue case both need a real repo).' -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')

# Read-JsonFile / Get-Field / Get-ShortHash / Normalize-Path / Get-RepoStateFingerprint.
. $HookLib

$Work = New-TestWorkspace -Prefix 'hookmaker-cleanupfresh'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# ---- the real code under test -------------------------------------------
$ConsumerAst = [System.Management.Automation.Language.Parser]::ParseFile($Consumer, [ref]$null, [ref]$null)
# EVERY .ps1 in the producer's package, not just its entry point - same reason
# the record document is read from its own sibling above. The detection tables
# moved into _discovery.ps1 when the entry point was split at the size ceiling,
# and an AST pointed at the entry point alone stops finding them: it threw here
# rather than going quietly green, which is the right failure, but the fix is
# to read what the installer actually ships.
$ProducerAst = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Producer) -File -Filter '*.ps1' |
    ForEach-Object { [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null) })
$RecordAst = [System.Management.Automation.Language.Parser]::ParseFile($RecordBuilder, [ref]$null, [ref]$null)
$RecordText = [System.IO.File]::ReadAllText($RecordBuilder)

function Get-AstFunction {
    param($Ast, [string]$Name)
    $fn = $Ast.Find({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq $Name }, $true)
    if ($null -eq $fn) { throw ("function not found in source: " + $Name) }
    return $fn.Extent.Text
}
# -Ast takes ONE ast or a whole package of them. "Exactly one" is unchanged and
# is now asserted across the package, so it still catches a table that vanished
# AND a table defined twice in two files - the failure mode a split invites.
function Get-AstAssignment {
    param($Ast, [string]$VariableName)
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($one in @($Ast)) {
        foreach ($node in $one.FindAll({
                    $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $args[0].Left.Extent.Text -eq $VariableName }, $true)) {
            [void]$found.Add($node)
        }
    }
    if ($found.Count -ne 1) { throw ("expected exactly one assignment to " + $VariableName + ", found " + $found.Count) }
    return $found[0]
}
# Every string constant inside an assignment's right-hand side, in source order.
function Get-AstStringValues {
    param($Ast, [string]$VariableName)
    return @((Get-AstAssignment -Ast $Ast -VariableName $VariableName).Right.FindAll({
                $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
        ForEach-Object { $_.Value })
}

$entryModule = Join-Path $Work 'consumerentry.ps1'
Write-Utf8 $entryModule (
    (Get-AstAssignment -Ast $ConsumerAst -VariableName '$script:CleanupCategories').Extent.Text + "`r`n" +
    (Get-AstFunction -Ast $ConsumerAst -Name 'Get-CleanupProjectKey') + "`r`n" +
    (Get-AstFunction -Ast $ConsumerAst -Name 'Get-CleanupResultPath') + "`r`n")
. $entryModule
# The evidence module has no side effects by design, so the shipped file itself
# is what runs here - not an extract of it.
. $Evidence

# ---- shared fixture: one real git repo, built once -----------------------
$env:LOCALAPPDATA = Join-Path $Work 'appdata'
New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') -Force | Out-Null

$Repo = Join-Path $Work 'proj'
New-Item -ItemType Directory -Path (Join-Path $Repo 'src') -Force | Out-Null
Write-Utf8 (Join-Path $Repo 'src\app.py') "print('hi')`r`n"
# The candidate names this suite creates must be genuinely IGNORED, or the
# defect it pins cannot be reproduced: an ignored path is exactly what the repo
# fingerprint cannot see.
# The last four are R05 fixtures. They hold real files (a marker, a config
# name), so git would report the directory as untracked and the repo-state
# HINT would reject the record long before the filesystem witness ran - the
# test would pass for the wrong reason, or fail for one.
Write-Utf8 (Join-Path $Repo '.gitignore') ".pytest_cache/`r`n__pycache__/`r`n*.pyc`r`ncoverage`r`nmy-scratch-cache/`r`nspotdl-env/`r`nweird-cache-name/`r`nplain-dir/`r`n"
& git -C $Repo init -q 2>&1 | Out-Null
& git -C $Repo -c user.email='t@example.invalid' -c user.name='T' add -A 2>&1 | Out-Null
& git -C $Repo -c user.email='t@example.invalid' -c user.name='T' commit -q -m 'init' 2>&1 | Out-Null

$SessionId = 'session-A'
$ResultPath = Get-CleanupResultPath -Root $Repo
# Lazy + cached: Get-RepoStateFingerprint costs three git calls and the tracked
# tree never changes in this suite (every candidate created below is ignored).
# A case that needs a FRESH measurement takes one explicitly.
$script:BaseFingerprint = $null
function Get-BaseFingerprint {
    if ($null -eq $script:BaseFingerprint) { $script:BaseFingerprint = (Get-RepoStateFingerprint -ProjectRoot $Repo) }
    return $script:BaseFingerprint
}

function New-ValidRecord {
    param([hashtable]$Override = @{}, [string[]]$Remove = @())
    $record = [ordered]@{
        schemaVersion = 3
        producerGeneration = 3
        sessionId = $SessionId
        fingerprint = (Get-BaseFingerprint)
        category = 'clean'
        scanComplete = $true
        partialCauses = @()
        candidateCount = 0
        reviewCount = 0
        residueCount = 0
        evidenceFingerprint = 'evfp0000'
        # Generation 3. scanStartedUtc is the freshness reference; the two name
        # lists are the detection configuration the scan actually ran under.
        scanStartedUtc = ([DateTime]::UtcNow.ToString('o'))
        extraCandidateNames = @()
        extraReviewNames = @()
        timestampUtc = ([DateTime]::UtcNow.ToString('o'))
    }
    foreach ($key in @($Override.Keys)) { $record[$key] = $Override[$key] }
    foreach ($key in $Remove) { [void]$record.Remove($key) }
    return $record
}
function Write-Record { param($Record) Write-Utf8 $ResultPath ($Record | ConvertTo-Json) }
function Get-Verdict { param([string]$Session = $SessionId) return (Get-CleanupEvidenceVerdict -Root $Repo -SessionId $Session) }
# Deterministic "this existed before the scan" / "this appeared after it", with
# no sleeping: the timestamps are set, never waited for.
function Set-StampUtc {
    param([string]$Path, [DateTime]$Utc)
    $item = Get-Item -LiteralPath $Path -Force
    $item.CreationTimeUtc = $Utc
    $item.LastWriteTimeUtc = $Utc
}

try {
    # =====================================================================
    Write-Host '--- 1/4 the mirrored contract still equals the producer''s own tables ---' -ForegroundColor Cyan
    # Two self-contained runtimes cannot share a file, so the consumer holds a
    # copy. A copy is only safe while something proves it still matches - this is
    # that proof, and the reason a drifted table cannot ship quietly.
    $producerNames = @(
        (Get-AstStringValues -Ast $ProducerAst -VariableName '$script:DisposableCacheNames') +
        (Get-AstStringValues -Ast $ProducerAst -VariableName '$script:TaskCreatedOnlyNames') +
        (Get-AstStringValues -Ast $ProducerAst -VariableName '$script:ReviewOnlyNames'))
    $consumerNames = Get-AstStringValues -Ast (
        [System.Management.Automation.Language.Parser]::ParseFile($Evidence, [ref]$null, [ref]$null)) -VariableName '$script:CleanupWitnessNames'
    Check 'the witness NAME mirror equals the producer''s three shipped name tables' (
        (@($producerNames | Sort-Object) -join '|') -eq (@($consumerNames | Sort-Object) -join '|')) (
        'producer=[' + ($producerNames -join ',') + '] consumer=[' + ($consumerNames -join ',') + ']')

    $EvidenceAst = [System.Management.Automation.Language.Parser]::ParseFile($Evidence, [ref]$null, [ref]$null)
    $producerPatterns = @(
        (Get-AstStringValues -Ast $ProducerAst -VariableName '$script:TaskCreatedOnlyFilePatterns') +
        (Get-AstStringValues -Ast $ProducerAst -VariableName '$script:ReviewOnlyFilePatterns'))
    $consumerPatterns = Get-AstStringValues -Ast $EvidenceAst -VariableName '$script:CleanupWitnessFilePatterns'
    Check 'the witness FILE-PATTERN mirror equals the producer''s two pattern lists' (
        (@($producerPatterns | Sort-Object) -join '|') -eq (@($consumerPatterns | Sort-Object) -join '|')) (
        'producer=[' + ($producerPatterns -join ',') + '] consumer=[' + ($consumerPatterns -join ',') + ']')

    $producerPrune = Get-AstStringValues -Ast $ProducerAst -VariableName '$script:HardPruneNames'
    $consumerPrune = Get-AstStringValues -Ast $EvidenceAst -VariableName '$script:CleanupWitnessPruneNames'
    Check 'the PRUNE mirror equals the producer''s hard-prune set (a drifted one silences the gate)' (
        (@($producerPrune | Sort-Object) -join '|') -eq (@($consumerPrune | Sort-Object) -join '|')) (
        'producer=[' + ($producerPrune -join ',') + '] consumer=[' + ($consumerPrune -join ',') + ']')

    # A registered GitHub Actions runner lives INSIDE the project as .ci-runner and
    # is CI runtime state, not this project's residue - the same category as .cache
    # before it. It vendors thousands of third-party files, among them names this
    # witness treats as cleanup-relevant. Unpruned, the walk descends into it, reads a
    # vendored __pycache__ newer than the record as fresh residue, and reports the
    # evidence stale - silencing the deploy gate over a tree the PRODUCER never
    # classified. Its own root on purpose: dropping a fresh cache into the shared repo
    # fixture would change what every later case observes.
    $runnerProj = Join-Path $Work 'ci-runner-project'
    # NO already-pruned segment on this path. An earlier draft routed it through
    # node_modules, which the witness prunes anyway, so the walk stopped before the
    # cache and the assertion passed while the .ci-runner prune did not yet exist -
    # a green that proved nothing. Real runner trees carry such paths (_work/_temp).
    $runnerDeep = Join-Path $runnerProj '.ci-runner\windows\_work\_temp\artifacts\__pycache__'
    New-Item -ItemType Directory -Path $runnerDeep -Force | Out-Null
    Write-Utf8 (Join-Path $runnerDeep 'vendored.pyc') 'third-party byte code'
    Check '.ci-runner is never descended into: a vendored cache newer than the record is not residue' (
        Test-CleanupEvidenceStillCurrent -Root $runnerProj -RecordedUtc ([DateTime]::UtcNow.AddMinutes(-5))) (
        'the witness walked into .ci-runner and read CI runtime state as project residue')
    # Positive control: the SAME fresh cache outside .ci-runner must still be seen,
    # so the assertion above cannot pass by the witness simply never looking.
    $plainCache = Join-Path $runnerProj 'src\__pycache__'
    New-Item -ItemType Directory -Path $plainCache -Force | Out-Null
    Write-Utf8 (Join-Path $plainCache 'own.pyc') 'our own byte code'
    Check 'control: an identical cache OUTSIDE .ci-runner is still observed as newer' (
        -not (Test-CleanupEvidenceStillCurrent -Root $runnerProj -RecordedUtc ([DateTime]::UtcNow.AddMinutes(-5)))) (
        'the witness missed real residue - the prune is too broad')

    # The coordination record the producer actually emits, read from its AST.
    $recordHash = $RecordAst.Find({
            $args[0] -is [System.Management.Automation.Language.HashtableAst] -and
            @($args[0].KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) -contains 'evidenceFingerprint' }, $true)
    Check 'the producer''s coordination record is locatable in its source' ($null -ne $recordHash)
    $producerFields = @($recordHash.KeyValuePairs | ForEach-Object { [string]$_.Item1.Extent.Text })
    $requiredFields = Get-AstStringValues -Ast $EvidenceAst -VariableName '$script:CleanupResultRequiredFields'
    Check 'the required-field set is EXACTLY what the producer writes (no missing field, no stale extra)' (
        (@($producerFields | Sort-Object) -join '|') -eq (@($requiredFields | Sort-Object) -join '|')) (
        'producer=[' + ($producerFields -join ',') + '] consumer=[' + ($requiredFields -join ',') + ']')

    function Get-RecordLiteral {
        param([string]$Key)
        $pair = @($recordHash.KeyValuePairs | Where-Object { [string]$_.Item1.Extent.Text -eq $Key })
        if ($pair.Count -ne 1) { return '<not found>' }
        return ([string]$pair[0].Item2.Extent.Text).Trim()
    }
    # The two versions are named constants in the builder rather than literals
    # inside the hashtable, so read them where they are declared.
    function Get-RecordVersion {
        param([string]$Name)
        $m = [regex]::Match($RecordText, ('(?m)^\$script:' + [regex]::Escape($Name) + '\s*=\s*(\d+)\s*$'))
        if (-not $m.Success) { return '<not found>' }
        return $m.Groups[1].Value
    }
    Check 'the producer stamps the schemaVersion this consumer accepts' (
        (Get-RecordVersion 'CleanupRecordSchemaVersion') -eq [string]$script:CleanupResultSchemaVersion) (
        'producer=' + (Get-RecordVersion 'CleanupRecordSchemaVersion') + ' consumer=' + $script:CleanupResultSchemaVersion)
    Check 'the producer stamps the producerGeneration this consumer accepts' (
        (Get-RecordVersion 'CleanupRecordProducerGeneration') -eq [string]$script:CleanupResultProducerGeneration) (
        'producer=' + (Get-RecordVersion 'CleanupRecordProducerGeneration') + ' consumer=' + $script:CleanupResultProducerGeneration)
    Check 'the entry point loads the record builder rather than inlining it' (
        ([System.IO.File]::ReadAllText($Producer)) -match [regex]::Escape("'_cleanuprecord.ps1'"))
    Check 'the entry point loads the evidence module rather than inlining it' (
        ([System.IO.File]::ReadAllText($Consumer)) -match [regex]::Escape("'_cleanupevidence.ps1'"))

    # =====================================================================
    Write-Host '--- 2/4 leaf-name matching (what counts as cleanup-relevant) ---' -ForegroundColor Cyan
    Check 'a cache DIRECTORY name matches' (Test-CleanupWitnessMatch -Name '.pytest_cache' -IsDir $true)
    Check 'matching is case-insensitive, like the producer''s own name sets' (Test-CleanupWitnessMatch -Name 'TESTRESULTS' -IsDir $true)
    Check 'a .pyc FILE matches by pattern' (Test-CleanupWitnessMatch -Name 'mod.pyc' -IsDir $false)
    Check 'a file pattern does NOT match a directory of the same name' (-not (Test-CleanupWitnessMatch -Name 'mod.pyc' -IsDir $true))
    Check 'an ordinary source directory does not match' (-not (Test-CleanupWitnessMatch -Name 'src' -IsDir $true))
    Check 'an ordinary source file does not match' (-not (Test-CleanupWitnessMatch -Name 'app.py' -IsDir $false))

    # =====================================================================
    Write-Host '--- 3/4 a record is evidence only when every part of it checks out ---' -ForegroundColor Cyan
    # POSITIVE CONTROL FIRST. Without it a function that answered 'unknown' to
    # everything would satisfy every other case in this section.
    Write-Record (New-ValidRecord)
    Check 'POSITIVE CONTROL: a complete, current, this-session clean record IS evidence' ((Get-Verdict) -eq 'clean') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ category = 'review-required'; reviewCount = 3 })
    Check 'POSITIVE CONTROL: a valid non-clean category is passed through, not flattened to unknown' (
        (Get-Verdict) -eq 'review-required') (Get-Verdict)

    Remove-Item -LiteralPath $ResultPath -Force
    Check 'no record at all -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Utf8 $ResultPath '{ this is not json'
    Check 'an unparseable record -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # SHAPE: an older or newer build's record cannot fake a field set it never had.
    foreach ($field in $requiredFields) {
        Write-Record (New-ValidRecord -Remove @($field))
        Check ('a record missing "' + $field + '" -> unknown') ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    }
    Write-Record (New-ValidRecord -Override @{ schemaVersion = 1 })
    Check 'an older schemaVersion -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ producerGeneration = 1 })
    Check 'an older producerGeneration (same shape, different meaning of clean) -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # ORIGIN: the producer/consumer barrier.
    Write-Record (New-ValidRecord -Override @{ sessionId = 'session-B' })
    Check 'a clean record from ANOTHER session -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ sessionId = '' })
    Check 'a record with no session id -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord)
    Check 'a consumer with no session id of its own -> unknown (two absences are not a match)' (
        (Get-Verdict -Session '') -eq 'unknown') (Get-Verdict -Session '')

    # COVERAGE: never an all-clear on an incomplete scan.
    Write-Record (New-ValidRecord -Override @{ scanComplete = $false })
    Check 'an incomplete scan -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ partialCauses = @('directory-unreadable') })
    Check 'a record claiming clean while naming a partial cause -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # VOCABULARY and internal agreement.
    Write-Record (New-ValidRecord -Override @{ category = 'sparkling' })
    Check 'a category outside the shared vocabulary -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ reviewCount = 2 })
    Check 'clean while counting review work -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ residueCount = 1 })
    Check 'clean while counting confirmed residue -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ reviewCount = 'lots' })
    Check 'an unparseable count on a clean record -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # FRESHNESS backstop, measured on scanStartedUtc - the instant the scan
    # BEGAN is what the filesystem witness compares against.
    Write-Record (New-ValidRecord -Override @{ scanStartedUtc = 'yesterday-ish' })
    Check 'an unusable timestamp -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ scanStartedUtc = ([DateTime]::UtcNow.AddMinutes(30).ToString('o')) })
    Check 'a future-dated record -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{
            scanStartedUtc = ([DateTime]::UtcNow.AddMinutes(-($script:CleanupResultMaxAgeMinutes + 5)).ToString('o')) })
    Check 'a record older than the max age -> unknown' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # The cache hint is still checked - it was never wrong, only insufficient.
    Write-Record (New-ValidRecord -Override @{ fingerprint = 'stale0000' })
    Check 'a mismatched repo-state fingerprint -> unknown (the hint is retained)' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # =====================================================================
    Write-Host '--- 4/4 THE FINDING: ignored residue the repo fingerprint cannot see ---' -ForegroundColor Cyan
    # The record is dated five minutes ago, so the cache directory created below
    # is unambiguously newer than the scan it describes. No sleeping.
    $scanUtc = [DateTime]::UtcNow.AddMinutes(-5)
    Write-Record (New-ValidRecord -Override @{ scanStartedUtc = $scanUtc.ToString('o') })
    Check 'baseline: the clean record is evidence before any residue appears' ((Get-Verdict) -eq 'clean') (Get-Verdict)

    # No CACHEDIR.TAG in it: the producer prunes any directory holding one, so
    # a tagged fixture describes a tree the scan deliberately never entered
    # rather than residue the scan missed. The tagged case is asserted on its
    # own below, where it belongs.
    $cache = Join-Path $Repo '.pytest_cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    Write-Utf8 (Join-Path $cache 'lastfailed') '{}'
    $porcelain = @(& git -C $Repo status --porcelain 2>&1 | Where-Object { $_ })
    Check 'PREMISE: the new cache directory is IGNORED - git porcelain is still empty' (
        $porcelain.Count -eq 0) ($porcelain -join ' / ')
    Check 'PREMISE: the repo-state fingerprint is therefore COMPLETELY unchanged by it' (
        (Get-RepoStateFingerprint -ProjectRoot $Repo) -eq (Get-BaseFingerprint)) (
        'now=' + (Get-RepoStateFingerprint -ProjectRoot $Repo) + ' before=' + (Get-BaseFingerprint))
    Check 'THE FIX: the same record is no longer evidence once ignored residue appears -> unknown' (
        (Get-Verdict) -eq 'unknown') (Get-Verdict)

    # Not a TTL: the record is well inside its max age and still rejected.
    Check 'and it is rejected on the FILESYSTEM, not on age - the record is minutes old' (
        ([DateTime]::UtcNow - $scanUtc).TotalMinutes -lt $script:CleanupResultMaxAgeMinutes) (
        'age=' + [string]([DateTime]::UtcNow - $scanUtc).TotalMinutes)

    # A candidate the producer DID see must not silence the gate for ever - that
    # would be the dead gate this project has shipped twice before.
    Set-StampUtc -Path (Join-Path $cache 'lastfailed') -Utc $scanUtc.AddMinutes(-10)
    Set-StampUtc -Path $cache -Utc $scanUtc.AddMinutes(-10)
    Check 'a candidate that predates the scan is covered by it - still evidence, not a dead gate' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)

    # Ignored residue inside a PRUNED directory belongs to a dependency store,
    # not to this task; the producer never looks there and neither may this.
    $vendored = Join-Path $Repo 'node_modules\pkg\__pycache__'
    New-Item -ItemType Directory -Path $vendored -Force | Out-Null
    Write-Utf8 (Join-Path $vendored 'x.pyc') 'x'
    Check 'a fresh cache inside a hard-pruned directory does NOT invalidate the record' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)

    # A brand-new .pyc in the project's own tree does.
    $pycache = Join-Path $Repo 'src\__pycache__'
    New-Item -ItemType Directory -Path $pycache -Force | Out-Null
    Write-Utf8 (Join-Path $pycache 'app.cpython-312.pyc') 'x'
    Check 'a __pycache__ created in the project''s own tree after the scan -> unknown' (
        (Get-Verdict) -eq 'unknown') (Get-Verdict)
    Set-StampUtc -Path $pycache -Utc $scanUtc.AddMinutes(-10)
    Set-StampUtc -Path (Join-Path $pycache 'app.cpython-312.pyc') -Utc $scanUtc.AddMinutes(-10)
    Check 'backdating it restores the verdict - the check is the timestamp, nothing else' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)

    # An unreadable directory is missing coverage, and missing coverage is never
    # an all-clear.
    # =====================================================================
    Write-Host '--- R05: the witness observes the same scan the record describes ---' -ForegroundColor Cyan

    # 1. A CONFIGURED extra candidate name. The witness mirrored only the
    # SHIPPED names, so a name the scan was configured to look for was invisible
    # to it - and residue under that name left a stale verdict reading 'clean'.
    Write-Record (New-ValidRecord)
    Check 'POSITIVE CONTROL: the generation-3 record is evidence to begin with' ((Get-Verdict) -eq 'clean') (Get-Verdict)
    $extraDir = Join-Path $Repo 'my-scratch-cache'
    New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
    Set-StampUtc -Path $extraDir -Utc ([DateTime]::UtcNow.AddMinutes(1))
    Write-Record (New-ValidRecord)
    Check 'PREMISE: an unconfigured extra name is not the witness''s business - still clean' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ extraCandidateNames = @('my-scratch-cache') })
    Check 'THE FIX: the same residue under a CONFIGURED name now invalidates the record' (
        (Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{ extraReviewNames = @('my-scratch-cache') })
    Check 'a configured REVIEW name counts the same way' ((Get-Verdict) -eq 'unknown') (Get-Verdict)
    Set-StampUtc -Path $extraDir -Utc ([DateTime]::UtcNow.AddMinutes(-30))
    Write-Record (New-ValidRecord -Override @{ extraCandidateNames = @('my-scratch-cache') })
    Check 'and backdating it restores the verdict - it is the timestamp, not the name' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)
    Remove-Item -LiteralPath $extraDir -Recurse -Force

    # 2. MARKER PRUNING. The producer skips any directory holding pyvenv.cfg or
    # CACHEDIR.TAG, whatever it is called. The witness did not, so it descended
    # into a custom-named virtualenv and rejected evidence over paths the scan
    # had deliberately excluded - a permanent 'unknown' no cleanup could clear.
    $venv = Join-Path $Repo 'spotdl-env'
    New-Item -ItemType Directory -Path $venv -Force | Out-Null
    Write-Utf8 (Join-Path $venv 'pyvenv.cfg') 'home = C:\Python'
    $venvCache = Join-Path $venv '.pytest_cache'
    New-Item -ItemType Directory -Path $venvCache -Force | Out-Null
    Set-StampUtc -Path $venvCache -Utc ([DateTime]::UtcNow.AddMinutes(1))
    Write-Record (New-ValidRecord)
    Check 'a cache inside a MARKER-pruned virtualenv does not invalidate the record' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)
    $tagged = Join-Path $Repo 'weird-cache-name'
    New-Item -ItemType Directory -Path $tagged -Force | Out-Null
    Write-Utf8 (Join-Path $tagged 'CACHEDIR.TAG') 'Signature: 8a477f597d28d172789f06886806bc55'
    $taggedCache = Join-Path $tagged '.mypy_cache'
    New-Item -ItemType Directory -Path $taggedCache -Force | Out-Null
    Set-StampUtc -Path $taggedCache -Utc ([DateTime]::UtcNow.AddMinutes(1))
    Write-Record (New-ValidRecord)
    Check 'a cache inside a CACHEDIR.TAG tree does not invalidate it either' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)
    # NEGATIVE CONTROL: the same cache OUTSIDE a marked tree still does.
    $plainCache = Join-Path $Repo 'plain-dir\.mypy_cache'
    New-Item -ItemType Directory -Path $plainCache -Force | Out-Null
    Set-StampUtc -Path $plainCache -Utc ([DateTime]::UtcNow.AddMinutes(1))
    Write-Record (New-ValidRecord)
    Check 'NEGATIVE CONTROL: the same cache outside a marked tree DOES invalidate it' (
        (Get-Verdict) -eq 'unknown') (Get-Verdict)
    Remove-Item -LiteralPath $venv -Recurse -Force
    Remove-Item -LiteralPath $tagged -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $Repo 'plain-dir') -Recurse -Force

    # 3. THE SCAN WINDOW. The reference is when the scan STARTED, so a path
    # created while the walk was already past its directory - earlier than the
    # completion stamp, later than the start - is correctly uninspected.
    $raced = Join-Path $Repo '.ruff_cache'
    New-Item -ItemType Directory -Path $raced -Force | Out-Null
    $midScan = [DateTime]::UtcNow.AddMinutes(-5)
    Set-StampUtc -Path $raced -Utc $midScan
    Write-Record (New-ValidRecord -Override @{
            scanStartedUtc = ([DateTime]::UtcNow.AddMinutes(-10).ToString('o'))
            timestampUtc   = ([DateTime]::UtcNow.AddMinutes(-1).ToString('o'))
        })
    Check 'a path created DURING the scan is uninspected -> unknown, not clean' (
        (Get-Verdict) -eq 'unknown') (Get-Verdict)
    Write-Record (New-ValidRecord -Override @{
            scanStartedUtc = ([DateTime]::UtcNow.AddMinutes(-3).ToString('o'))
            timestampUtc   = ([DateTime]::UtcNow.AddMinutes(-1).ToString('o'))
        })
    Check 'a path that predates the scan START is covered by it - still clean' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)
    Remove-Item -LiteralPath $raced -Recurse -Force

    # =====================================================================
    Write-Host '--- L06: producer and consumer accept the SAME configuration ---' -ForegroundColor Cyan
    # The producer accepted an extra leaf of any length and any count; the
    # witness silently dropped anything over 64 and stopped at 200. A
    # 65-character configured name was therefore scanned and never looked for,
    # so residue under it left a stale 'clean' standing.
    $prodBoundsText = [System.IO.File]::ReadAllText($RecordBuilder)
    function Get-BoundLiteral {
        param([string]$Text, [string]$Name)
        $m = [regex]::Match($Text, ('(?m)^\$script:' + [regex]::Escape($Name) + '\s*=\s*(\d+)\s*$'))
        if (-not $m.Success) { return '<not found>' }
        return $m.Groups[1].Value
    }
    Check 'the accepted NAME LENGTH is the same on both sides' (
        (Get-BoundLiteral $prodBoundsText 'CleanupExtraNameMaxLength') -eq [string]$script:CleanupWitnessNameMaxLength) (
        'producer=' + (Get-BoundLiteral $prodBoundsText 'CleanupExtraNameMaxLength') + ' consumer=' + $script:CleanupWitnessNameMaxLength)
    Check 'the accepted NAME COUNT is the same on both sides' (
        (Get-BoundLiteral $prodBoundsText 'CleanupExtraNameMaxCount') -eq [string]$script:CleanupWitnessNameMaxCount) (
        'producer=' + (Get-BoundLiteral $prodBoundsText 'CleanupExtraNameMaxCount') + ' consumer=' + $script:CleanupWitnessNameMaxCount)

    $name64 = ('a' * 64)
    $name65 = ('a' * 65)
    Write-Record (New-ValidRecord -Override @{ extraCandidateNames = @($name64) })
    Check 'a 64-character configured name is accepted and revalidated' (
        $null -ne (Get-CleanupWitnessNames -Record ((Get-Content -LiteralPath $ResultPath -Raw) | ConvertFrom-Json)))
    Check 'and the record with it is still usable evidence' ((Get-Verdict) -eq 'clean') (Get-Verdict)

    Write-Record (New-ValidRecord -Override @{ extraCandidateNames = @($name65) })
    Check 'a 65-character name is REFUSED, not silently dropped' (
        $null -eq (Get-CleanupWitnessNames -Record ((Get-Content -LiteralPath $ResultPath -Raw) | ConvertFrom-Json)))
    Check 'and the verdict is unknown, never a stale clean' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # The count bound behaves the same way at its boundary.
    $manyNames = @(1..$script:CleanupWitnessNameMaxCount | ForEach-Object { 'cfg-name-' + $_ })
    Write-Record (New-ValidRecord -Override @{ extraCandidateNames = $manyNames })
    Check 'exactly the accepted number of names is still usable' (
        $null -ne (Get-CleanupWitnessNames -Record ((Get-Content -LiteralPath $ResultPath -Raw) | ConvertFrom-Json)))
    $tooMany = @(1..($script:CleanupWitnessNameMaxCount + 1) | ForEach-Object { 'cfg-name-' + $_ })
    Write-Record (New-ValidRecord -Override @{ extraCandidateNames = $tooMany })
    Check 'one name past the cap is REFUSED rather than truncated' (
        $null -eq (Get-CleanupWitnessNames -Record ((Get-Content -LiteralPath $ResultPath -Raw) | ConvertFrom-Json)))
    Check 'and that record is unknown too' ((Get-Verdict) -eq 'unknown') (Get-Verdict)

    # NEGATIVE CONTROL: an ordinary configured name still works end to end,
    # so the bound is a bound and not a blanket refusal.
    Write-Record (New-ValidRecord -Override @{ extraCandidateNames = @('my-scratch-cache') })
    Check 'NEGATIVE CONTROL: an ordinary configured extra name is still accepted' (
        (Get-Verdict) -eq 'clean') (Get-Verdict)

    Check 'a root that does not exist -> not current (no all-clear on absent coverage)' (
        -not (Test-CleanupEvidenceStillCurrent -Root (Join-Path $Work 'no-such-project') -RecordedUtc ([DateTime]::UtcNow)))

    # =====================================================================
    Write-Host '--- 5/5 BOTH HOSTS decode the recorded timestamp to the same instant ---' -ForegroundColor Cyan
    # The rest of this suite is in-process, so it only ever sees pwsh. That is
    # not enough here: ConvertFrom-Json is not type-stable across hosts (5.1
    # leaves an ISO-8601 string a String, pwsh decodes it to a [DateTime] whose
    # [string] cast drops the Z), and the first version of this check read the
    # record hours old on pwsh while passing on 5.1 - a gate that would have gone
    # permanently silent on the host Codex installs. One real child per host is
    # the shape that actually ships, and it costs about a second each.
    $child = Join-Path $Work 'verdict-host.ps1'
    Write-Utf8 $child @'
param([string]$Root, [string]$AppData, [string]$Entry, [string]$Evidence, [string]$HookLib, [string]$Session, [string]$Fingerprint)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = $AppData
. $HookLib
. $Entry
. $Evidence
$record = [ordered]@{
    schemaVersion = 3; producerGeneration = 3; sessionId = $Session; fingerprint = $Fingerprint
    category = 'clean'; scanComplete = $true; partialCauses = @(); candidateCount = 0
    reviewCount = 0; residueCount = 0; evidenceFingerprint = 'evfp0000'
    scanStartedUtc = ([DateTime]::UtcNow.ToString('o'))
    extraCandidateNames = @(); extraReviewNames = @()
    timestampUtc = ([DateTime]::UtcNow.ToString('o'))
}
[System.IO.File]::WriteAllText((Get-CleanupResultPath -Root $Root), ($record | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
Write-Output ((Get-CleanupEvidenceVerdict -Root $Root -SessionId $Session) + '|' + $PSVersionTable.PSVersion.ToString())
'@
    $childArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $child,
        '-Root', $Repo, '-AppData', $env:LOCALAPPDATA, '-Entry', $entryModule, '-Evidence', $Evidence,
        '-HookLib', $HookLib, '-Session', $SessionId, '-Fingerprint', (Get-BaseFingerprint))
    foreach ($exe in @('pwsh', 'powershell.exe')) {
        $childOut = ''
        try { $childOut = ((& $exe @childArgs 2>&1) -join ' ').Trim() } catch { $childOut = 'LAUNCH FAILED: ' + $_.Exception.Message }
        Check ('a fresh clean record is evidence under ' + $exe + ' too (no cross-host timestamp drift)') (
            $childOut -match '^clean\|') $childOut
    }
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
