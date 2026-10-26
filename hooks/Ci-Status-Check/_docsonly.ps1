# Skip-marked prose-only chains may reuse independently verified ancestor CI.
# Local cache is optional: pending reports overwrite it. This module coordinates
# bounded exact remote evidence, conservative input policy and serialized once
# publication. Outcome is docs-only-carryover, NEVER ci-green for documentation;
# Test-Completion-Check remains unchanged. Owning policy: GitHub rules Section8.
#
# Anything else keeps today's behaviour: no skip marker, a file that is not
# documentation, a parent that was not verified green, or a branch whose
# protection requires status checks (a skipped commit would leave them pending).

$ciProofRoot = if ([IO.File]::Exists((Join-Path $PSScriptRoot '_ciprovenance.ps1'))) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $ciProofRoot '_ciprovenance.ps1')
foreach ($module in @('_docsancestor.ps1', '_docsinputs.ps1', '_ciupstream.ps1', '_ciworkload.ps1')) { . (Join-Path $PSScriptRoot $module) }

$script:DocsOnlySkipMarkers = @('[skip ci]', '[ci skip]', '[no ci]', '[skip actions]', '[actions skip]')

function Test-CommitHasSkipMarker {
    param([string]$Message)
    $lower = ([string]$Message).ToLowerInvariant()
    foreach ($marker in $script:DocsOnlySkipMarkers) { if ($lower.Contains($marker)) { return $true } }
    return ($Message -match '(?im)^skip-checks:\s*true\s*$')
}

# Tracked public documentation only: Markdown, plus a .txt that is plainly prose
# (under docs/, or a README/CHANGELOG/NOTICE/AUTHORS/CONTRIBUTING file). A .txt
# elsewhere is usually build or dependency input (requirements.txt, CMakeLists.txt),
# and nothing under .github or a test, fixture or example path ever counts.
function Test-DocumentationOnlyPath {
    param([string]$Path)
    $p = ([string]$Path).Replace('\', '/').ToLowerInvariant()
    if ($p.StartsWith('.github/') -or $p -match '(^|/)(tests?|fixtures?|examples?|samples?|testdata)(/|$)' -or $p -match '\.example\.') { return $false }
    if ($p.EndsWith('.md')) { return $true }
    if (-not $p.EndsWith('.txt')) { return $false }
    $leaf = $p.Substring($p.LastIndexOf('/') + 1)
    return ($p.StartsWith('docs/') -or $leaf -match '^(readme|changelog|changes|history|notice|authors|contributing)([._-].*)?\.txt$')
}

# The last SHA observed green: this commit's own record when it says
# ci-green, or the parent a previous docs-only carry-over named.
function Get-VerifiedGreenBase {
    param([string]$StatePath)
    try {
        if (-not [IO.File]::Exists($StatePath)) { return '' }
        $lines = @([IO.File]::ReadAllLines($StatePath, [Text.Encoding]::UTF8))
        # Cache is an optional search hint, never authority; legacy labels are ignored.
        $carry = Read-CiCarryover -Lines $lines
        if ($null -ne $carry) { return $carry.parent }
        if ($lines.Count -eq 5) {
            $candidate = $lines[4] | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Read-CiProvenance -Lines $lines -Repository ([string]$candidate.repository) -Sha $lines[0])) { return $lines[0] }
        }
    }
    catch { }
    return ''
}

# $null (today's behaviour) or @{ Parent; Files } when the carry-over applies.
function Get-DocsOnlyCarryover {
    param([string]$ProjectRoot, [string]$Sha, [string]$Branch, [string]$RepoSlug, [string]$StatePath)
    $script:DocsCarryoverReason = ''
    $script:DocsReviewedClosure=$null
    $script:DocsReviewDestination=Get-CiCarryoverDestination $ProjectRoot $RepoSlug $Sha $Branch
    if($script:DocsReviewDestination-eq''){$script:DocsCarryoverReason='unknown: exact upstream protection destination unavailable or mismatched';return $null}
    $message = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'log', '-1', '--format=%B', $Sha)) -join "`n"
    if ($LASTEXITCODE -ne 0) { $script:DocsCarryoverReason = 'unknown: final commit message unavailable'; return $null }
    if (-not (Test-CommitHasSkipMarker -Message $message)) { return $null }
    $script:DocsCarryoverReason = 'unknown: skipped commit ancestry or prose-only edge not verified'
    # The pending record overwrites the old green cache; never make local history
    # a prerequisite. Walk at most eight first-parent edges, rejecting EVERY edge
    # so code later reverted to the same tree cannot masquerade as docs-only.
    $chain = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'rev-list', '--first-parent', '--max-count=9', $Sha))
    if ($LASTEXITCODE -ne 0 -or $chain.Count -lt 2 -or $chain[0] -cne $Sha) { return $null }
    $cached = Get-VerifiedGreenBase -StatePath $StatePath
    $finalSnapshot=Get-CiRunSnapshot -ProjectRoot $ProjectRoot -RepoSlug $RepoSlug -Sha $Sha -Branch $Branch
    if($null-eq$finalSnapshot-or-not$finalSnapshot.ChecksComplete-or-not$finalSnapshot.CommitChecksSafe-or
        $finalSnapshot.PendingRuns.Count-or$finalSnapshot.FailedRuns.Count-or$finalSnapshot.InfraRuns.Count-or$finalSnapshot.BillingRuns.Count){return $null}
    $files = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $candidates = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $chain.Count - 1; $i++) {
        $parents = ([string](Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'rev-list', '--parents', '-n', '1', $chain[$i]))).Split(' ')
        if ($LASTEXITCODE -ne 0 -or $parents.Count -ne 2 -or $parents[1] -cne $chain[$i + 1]) { break }
        $delta = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'diff', '--name-only', '--no-renames', $chain[$i + 1], $chain[$i]))
        if ($LASTEXITCODE -ne 0 -or $delta.Count -eq 0 -or @($delta | Where-Object { -not (Test-DocumentationOnlyPath $_) }).Count -gt 0) { break }
        foreach ($path in $delta) { [void]$files.Add([string]$path) }
        $candidates.Add([string]$chain[$i + 1])
        if ([string]$chain[$i + 1] -ceq $cached) { break }
    }
    if ($candidates.Count -eq 0 -or (Test-DocsHaveSemanticConsumers $ProjectRoot $Sha @($files) $RepoSlug)) { return $null }
    $script:DocsCarryoverReason = 'unknown or required final-SHA checks: branch protection/rules did not permit carryover'
    if (-not (Test-NoRequiredStatusChecks -RepoSlug $RepoSlug -Branch $Branch)) { return $null }
    $script:DocsCarryoverReason = 'unknown or non-success: complete nearest eligible ancestor checks not verified'
    $ordered = @($candidates.ToArray())
    if($null-ne$script:DocsReviewedClosure){
        foreach($object in @($Sha)+$ordered){
            $inventory=Get-CiClosureInventory $ProjectRoot $object @($script:DocsReviewedClosure.documents)
            if($null-eq$inventory-or$inventory.Fingerprint-cne$script:DocsReviewedClosure.inventory.sha256){return $null}
            foreach($document in @($script:DocsReviewedClosure.documents)){
                if(-not$inventory.Entries.ContainsKey($document)-or$inventory.Entries[$document].Mode-cne'100644'-or
                    -not(Test-DocsClosureDocument $ProjectRoot $object $document $script:DocsReviewedClosure)){return $null}
            }
        }
    }
    # Nearest first: an older cached success cannot conceal a newer failed run.
    foreach ($base in $ordered) {
        if ((Get-GhRemainingSeconds) -lt 1) { break }
        $script:DocsAncestorAbsent = $false
        if (Test-DocsAncestorGreen $ProjectRoot $RepoSlug $base $Branch) {
            if(-not(Test-DocsReviewedAncestorBinding $ProjectRoot $RepoSlug $Sha $base $Branch)){return $null}
            $source = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'ls-tree', '-r', $Sha)) -join "`n"
            if ($LASTEXITCODE -ne 0 -or [Text.Encoding]::UTF8.GetByteCount($source) -gt 1048576) { return $null }
            return [pscustomobject]@{ Parent = $base; Files = @($files | Sort-Object); SourceFingerprint = Get-RepositoryIdentityHash $source }
        }
        if (-not $script:DocsAncestorAbsent) { return $null }
    }
    return $null
}

function Test-NoRequiredStatusChecks {
    param([string]$RepoSlug, [string]$Branch)
    $encoded = [uri]::EscapeDataString($Branch)
    try {
        $branchEndpoint='repos/'+$RepoSlug+'/branches/'+$encoded
        $rulesEndpoint='repos/'+$RepoSlug+'/rules/branches/'+$encoded+'?per_page=100'
        if((Get-Variable CiApiScopeKey -Scope Script -ErrorAction SilentlyContinue)-and$script:CiApiScopeKey-ne''){
            $batch=Invoke-CiApiBatch -Endpoints @($branchEndpoint,$rulesEndpoint) -ScopeKey $script:CiApiScopeKey
            if($null-eq$batch){return $false}
        }
        $branchDoc=Read-CiWorkloadApi $branchEndpoint
        if ($null -eq $branchDoc -or [string](Get-Field $branchDoc 'name') -cne $Branch -or
            (Get-Field $branchDoc 'protected') -isnot [bool]) { return $false }
        if ([bool](Get-Field $branchDoc 'protected')) {
            if ($null -eq (Get-Field $branchDoc 'protection') -or $null -eq (Get-Field (Get-Field $branchDoc 'protection') 'required_status_checks')) { return $false }
            $checks = Get-Field (Get-Field $branchDoc 'protection') 'required_status_checks'
            if ($null -ne $checks) {
                if ($null -eq $checks.PSObject.Properties['contexts'] -or $null -eq $checks.PSObject.Properties['enforcement_level']) { return $false }
                $level = [string](Get-Field $checks 'enforcement_level')
                if (@(Get-Field $checks 'contexts' | Where-Object { $null -ne $_ }).Count -gt 0 -or
                    @(Get-Field $checks 'checks' | Where-Object { $null -ne $_ }).Count -gt 0 -or $level -ne 'off') { return $false }
            }
        }
        if((Get-Variable CiApiScopeKey -Scope Script -ErrorAction SilentlyContinue)-and$script:CiApiScopeKey-ne''){
            if($batch[$rulesEndpoint]-isnot[Array]){return $false}
            $rules=@($batch[$rulesEndpoint])
        }else{
            $rawRules = @(Invoke-GhBounded -ArgumentList @('api', $rulesEndpoint)) -join "`n"
            if ($LASTEXITCODE -ne 0 -or -not $rawRules.TrimStart().StartsWith('[')) { return $false }
            $rules = @($rawRules | ConvertFrom-Json | ForEach-Object { $_ })
        }
        if ($rules.Count -ge 100) { return $false }
        foreach ($rule in $rules) {
            $type = [string](Get-Field $rule 'type')
            if ($type -eq '' -or $type -in @('required_status_checks', 'workflows')) { return $false }
        }
        return $true
    }
    catch { return $false }
}

# Writes the carry-over record and exits with the note, or returns quietly.
function Invoke-DocsOnlyCarryover {
    param([string]$ProjectRoot, [string]$Sha, [string]$Branch, [string]$RepoSlug, [string]$StatePath, [string]$EventName)
    $carry = Get-DocsOnlyCarryover -ProjectRoot $ProjectRoot -Sha $Sha -Branch $Branch -RepoSlug $RepoSlug -StatePath $StatePath
    if ($null -eq $carry) { return }
    $when = [DateTimeOffset]::UtcNow.ToString('o')
    $proof = [ordered]@{schema=1;repository=$RepoSlug;sha=$Sha;parent=$carry.Parent;outcome='docs-only-carryover';observedUtc=$when;sourceFingerprint=$carry.SourceFingerprint}
    $receipt = @($Sha, 'verified', $when, 'docs-only-carryover', $carry.Parent, ($proof | ConvertTo-Json -Compress))
    if ($null -eq (Read-CiCarryover -Lines $receipt -Repository $RepoSlug -Sha $Sha)) { return }
    if (-not (Write-CiStateAtomic -Path $StatePath -Lines $receipt)) {
        # A concurrent winner already published the SAME versioned source review.
        $lines = @(); try { $lines = @([IO.File]::ReadAllLines($StatePath, [Text.Encoding]::UTF8)) } catch { }
        $winner = Read-CiCarryover -Lines $lines -Repository $RepoSlug -Sha $Sha -NoticeIdentityOnly
        if ($null -ne $winner -and $winner.parent -ceq $carry.Parent -and $winner.sourceFingerprint -ceq $carry.SourceFingerprint) { exit 0 }
        return
    }
    $shown = @($carry.Files | Select-Object -First 5)
    $more = if ($carry.Files.Count -gt $shown.Count) { ', ...' } else { '' }
    exit (Write-HookResult -EventName $EventName -Kind 'advisory' -Message ('CI CHECK: tests verified green on ' + $carry.Parent +
        '; ' + $Sha.Substring(0, [Math]::Min(7, $Sha.Length)) + ' changes documentation only (' + $carry.Files.Count + ' file(s): ' + ($shown -join ', ') + $more +
        ') and carries a skip marker, so no run was started. Report the tests as passed on that parent - this commit is not a new green result.')).ExitCode
}
