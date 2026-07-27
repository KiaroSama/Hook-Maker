# Offline test suite for the sync-group MERGE decision in
# scripts\Setup-SyncGroupBuilder.ps1 - purely computational, no filesystem, no
# child processes, no wizard.
#
# What it pins: adding one project to a group can silently merge FAR more than
# that group. The merge computes a transitive closure, so a project that already
# belongs to another cluster drags that cluster - and every cluster it touches -
# into one mesh. That is correct when the user means "link these" and wrong when
# they mean "just add this one", so the builder must REPORT the expansion and
# offer -NoExpand. These assertions fix both answers in place.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-SyncGroupMerge.ps1
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ToolRoot = Split-Path -Parent $PSScriptRoot
$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray }
    }
}

# Setup-SyncGroupBuilder.ps1 is dot-sourced by the wizard, which supplies these
# two helpers. Stubbing them keeps this suite free of the wizard's console and
# menu machinery - the merge logic under test uses neither.
function Get-ShortHash { param([string]$Text) return 'h' + ([Math]::Abs($Text.GetHashCode())).ToString() }
function Get-Slug { param([string]$Name) return ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
. (Join-Path $PSScriptRoot 'Setup-SyncGroupBuilder.ps1')

function New-TestProject {
    param([string]$Name)
    return [pscustomobject]@{ Name = $Name; Root = ('C:\P\' + $Name); AiPath = ('C:\P\' + $Name + '\.ai'); AiExists = $true }
}

# A full-mesh profile over the given member names, exactly the shape the wizard
# writes: one directed route per ordered pair.
function New-TestGroup {
    param([string]$Id, [string[]]$Members)
    $routes = @()
    foreach ($s in $Members) {
        foreach ($d in $Members) {
            if ($s -eq $d) { continue }
            $routes += [pscustomobject]@{
                id          = ($s + '-to-' + $d)
                enabled     = $true
                source      = [pscustomobject]@{ name = $s; root = ('C:\P\' + $s) }
                destination = [pscustomobject]@{ name = $d; root = ('C:\P\' + $d) }
            }
        }
    }
    return [pscustomobject]@{ id = $Id; name = ('Group ' + $Id); enabled = $true; routes = $routes }
}

function Get-Names { param($Members) return (@($Members | ForEach-Object { $_.Name } | Sort-Object) -join ',') }

Write-Host '--- the chained-cluster scenario: A+B+C, D+F+G, G+H+I; add D to A+B+C ---' -ForegroundColor Cyan
# D belongs to a second cluster, and G in THAT cluster belongs to a third. This
# is the case where a user adding one project cannot see what they are about to
# link, which is the whole reason the prompt exists.
$config = [pscustomobject]@{
    profiles = @((New-TestGroup 'g-abc' @('A', 'B', 'C')),
                 (New-TestGroup 'g-dfg' @('D', 'F', 'G')),
                 (New-TestGroup 'g-ghi' @('G', 'H', 'I')))
}
$entered = @((New-TestProject 'A'), (New-TestProject 'B'), (New-TestProject 'C'), (New-TestProject 'D'))

$full = Get-SyncGroupMerge -Config $config -NewProjects $entered
Check 'the default still computes the FULL transitive closure (behaviour unchanged)' (
    (Get-Names $full.AllMembers) -eq 'A,B,C,D,F,G,H,I') (Get-Names $full.AllMembers)
Check 'the merged mesh is 8x7 = 56 directed routes' (
    @($full.Profile.routes).Count -eq 56) ([string]@($full.Profile.routes).Count)
Check 'the third cluster is reached only THROUGH the second (closure, not one hop)' (
    @($full.RemoveProfileIds) -contains 'g-ghi') (@($full.RemoveProfileIds) -join ',')

Write-Host ''
Write-Host '--- the expansion is reported, so the caller can ask before merging ---' -ForegroundColor Cyan
Check 'an expansion is reported when an entered project belongs elsewhere' (
    @($full.ExpansionProfiles).Count -ge 1) ('groups=' + @($full.ExpansionProfiles).Count)
Check 'the reported group is the one the entered project belongs to' (
    @($full.ExpansionProfiles | Where-Object { $_.Id -eq 'g-dfg' }).Count -eq 1) (
    (@($full.ExpansionProfiles | ForEach-Object { $_.Id }) -join ','))
Check 'every reported group carries a display name for the prompt' (
    @($full.ExpansionProfiles | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Name) }).Count -eq 0) 'names'
Check 'it lists exactly the projects a YES would add, and no others' (
    (Get-Names $full.ExpansionMembers) -eq 'F,G,H,I') (Get-Names $full.ExpansionMembers)

Write-Host ''
Write-Host '--- NO (the default answer): only the entered projects are meshed ---' -ForegroundColor Cyan
$no = Get-SyncGroupMerge -Config $config -NewProjects $entered -NoExpand
Check 'the mesh is limited to the entered projects' (
    (Get-Names $no.AllMembers) -eq 'A,B,C,D') (Get-Names $no.AllMembers)
Check 'the mesh is 4x3 = 12 directed routes' (
    @($no.Profile.routes).Count -eq 12) ([string]@($no.Profile.routes).Count)
# A group wholly inside the entered set adds nobody, so absorbing it is exactly
# the "add D to A+B+C" the user asked for - declining must not block that.
Check 'the fully-contained group is STILL absorbed (it introduces no new project)' (
    @($no.RemoveProfileIds) -contains 'g-abc') (@($no.RemoveProfileIds) -join ',')
Check 'the other cluster is NOT absorbed and survives untouched' (
    -not (@($no.RemoveProfileIds) -contains 'g-dfg')) (@($no.RemoveProfileIds) -join ',')
Check 'the cluster BEHIND it is never reached either' (
    -not (@($no.RemoveProfileIds) -contains 'g-ghi')) (@($no.RemoveProfileIds) -join ',')
Check 'the anchor id is reused, so the existing group''s hooks keep working' (
    [string]$no.Profile.id -eq 'g-abc') ([string]$no.Profile.id)
# Declining still reports what was declined, so the log can record the choice.
Check 'declining still reports the expansion it refused' (
    @($no.ExpansionProfiles).Count -ge 1) ([string]@($no.ExpansionProfiles).Count)

Write-Host ''
Write-Host '--- no overlap: nothing to ask ---' -ForegroundColor Cyan
$fresh = Get-SyncGroupMerge -Config ([pscustomobject]@{ profiles = @() }) -NewProjects @((New-TestProject 'X'), (New-TestProject 'Y'))
Check 'a brand-new group reports no expansion (the prompt must not appear)' (
    @($fresh.ExpansionProfiles).Count -eq 0) ([string]@($fresh.ExpansionProfiles).Count)
Check 'a brand-new group still meshes its own members' (
    @($fresh.Profile.routes).Count -eq 2) ([string]@($fresh.Profile.routes).Count)

# Overlap that adds nobody must NOT trigger the question: re-running the wizard
# with the same projects is a no-op re-confirm, not a merge decision.
$same = Get-SyncGroupMerge -Config ([pscustomobject]@{ profiles = @((New-TestGroup 'g-abc' @('A', 'B', 'C'))) }) `
    -NewProjects @((New-TestProject 'A'), (New-TestProject 'B'), (New-TestProject 'C'))
Check 're-entering an existing group unchanged asks nothing' (
    @($same.ExpansionProfiles).Count -eq 0) ([string]@($same.ExpansionProfiles).Count)

# ---- every yes/no prompt must SHOW its default (round 40c) -------------------
# Read-YesNo computes a default marker but only uses it in its RETRY message, so
# a caller that passes a bare string renders a question with no [y] or [n] at
# all and the user cannot tell what Enter does. Exactly one call site did that -
# the merge question added this session. Pin the rule for every call site rather
# than the one string, because the next bare caller has the same bug.
$callerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Setup-SyncGroup*.ps1' -File)
$bareCalls = New-Object System.Collections.Generic.List[string]
foreach ($file in $callerFiles) {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        $lineNumber++
        if ($line -notmatch 'Read-YesNo\s') { continue }
        if ($line -match 'function\s+Read-YesNo') { continue }
        # A COMMENT that merely mentions Read-YesNo is not a call site. Without
        # this the guard fails on the comment written to explain the guard.
        if ($line.TrimStart().StartsWith('#')) { continue }
        # The prompt argument must be built by New-QuestionPrompt, which is the
        # only thing that renders "[n]" and the {back=0, quit=exit} legend.
        if ($line -notmatch 'Read-YesNo\s*\(\s*New-QuestionPrompt') {
            [void]$bareCalls.Add($file.Name + ':' + $lineNumber)
        }
    }
}
Check 'every Read-YesNo call renders its default through New-QuestionPrompt' (
    $bareCalls.Count -eq 0) ($bareCalls -join ', ')

# And the guard must be able to SEE the calls, or it proves nothing by passing.
$totalCalls = 0
foreach ($file in $callerFiles) {
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        if ($line -match 'Read-YesNo\s*\(\s*New-QuestionPrompt') { $totalCalls++ }
    }
}
Check 'the prompt-default guard actually inspected the real call sites' ($totalCalls -ge 8) ([string]$totalCalls)

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
