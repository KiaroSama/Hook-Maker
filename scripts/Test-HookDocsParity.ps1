# Offline suite: the hook reference (docs\HOOKS.md, docs\HOOKS-FA.md) and the
# README hook counts agree with the installer's own metadata. The docs are the
# per-hook behaviour contract and changed in almost every round, and nothing
# checked them: the Persian Ai-Memory-Load entry lost its events and both
# READMEs kept an old hook count for weeks.
#
# Layout checked: a summary table (first cell a link to the hook's section) and
# one `## `<Hook>`` section per hook whose first line states when it runs.
# Read-only; no child process. Usage: pwsh -NoLogo -NoProfile -File .\scripts\Test-HookDocsParity.ps1

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_testlib.ps1')
. (Join-Path $RepoRoot 'hooks\_hooklib.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red; if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray } }
}

# ---- the installer's metadata, read by AST (the wizard is never started) ----
$presentation = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts\Setup-SyncGroupPresentation.ps1'), [ref]$null, [ref]$null)
$metaAst = $presentation.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:HookMeta' }, $true)
$script:HookMeta = & ([scriptblock]::Create($metaAst.Right.Extent.Text))
$wizard = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts\Setup-SyncGroup.ps1'), [ref]$null, [ref]$null)
$eventsFn = $wizard.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HookRecommendedEvents' }, $true)
. ([scriptblock]::Create($eventsFn.Extent.Text))

$engine = 'Cross-Project-.ai-Knowledge-Sync'
$hookDirs = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'hooks') -Directory | Where-Object { -not $_.Name.StartsWith('_') -and $_.Name -notlike 'ZZZ-*' } | ForEach-Object { $_.Name })

# ---- parse one reference file ----
function Read-HookReference {
    param([string]$Path)
    $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
    $tableRuns = [ordered]@{}; $sectionRuns = [ordered]@{}; $dupes = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $row = [regex]::Match($line, '^\| \[`([^`]+)`\]\(#([^)]+)\) \| ([^|]+) \|')
        if ($row.Success) {
            if ($tableRuns.Contains($row.Groups[1].Value)) { $dupes += $row.Groups[1].Value }
            $tableRuns[$row.Groups[1].Value] = $row.Groups[3].Value.Trim()
            continue
        }
        $head = [regex]::Match($line, '^## `([^`]+)`\s*$')
        if ($head.Success) {
            $name = $head.Groups[1].Value
            if ($sectionRuns.Contains($name)) { $dupes += $name }
            # The first non-empty line of the section says when the hook runs.
            $j = $i + 1; while ($j -lt $lines.Count -and $lines[$j].Trim() -eq '') { $j++ }
            $sectionRuns[$name] = $(if ($j -lt $lines.Count) { $lines[$j] } else { '' })
        }
    }
    return [pscustomobject]@{ Table = $tableRuns; Sections = $sectionRuns; Duplicates = @($dupes) }
}
function Get-SetDifference { param($A, $B) return @(@($A | Where-Object { @($B) -notcontains $_ }) + @($B | Where-Object { @($A) -notcontains $_ } | ForEach-Object { '+' + $_ })) }

$en = Read-HookReference (Join-Path $RepoRoot 'docs\HOOKS.md')
$fa = Read-HookReference (Join-Path $RepoRoot 'docs\HOOKS-FA.md')

Write-Host '--- the same hooks everywhere ---' -ForegroundColor Cyan
foreach ($doc in @(@('EN', $en), @('FA', $fa))) {
    $label = $doc[0]; $ref = $doc[1]
    $d = @(Get-SetDifference @($ref.Sections.Keys) $hookDirs)
    Check ($label + ': one section per hooks\ folder') ($d.Count -eq 0) ($d -join ', ')
    $d = @(Get-SetDifference @($ref.Table.Keys) @($ref.Sections.Keys))
    Check ($label + ': the summary table lists exactly the sectioned hooks') ($d.Count -eq 0) ($d -join ', ')
    Check ($label + ': no hook appears twice') ($ref.Duplicates.Count -eq 0) ($ref.Duplicates -join ', ')
    $d = @(Get-SetDifference @($script:HookMeta.Keys) @($ref.Sections.Keys | Where-Object { $_ -ne $engine }))
    Check ($label + ': every installer metadata entry has a section, and nothing else does') ($d.Count -eq 0) ($d -join ', ')
}

Write-Host '--- the recommended events are written down in both languages ---' -ForegroundColor Cyan
foreach ($name in @($script:HookMeta.Keys | Sort-Object)) {
    $envPath = Join-Path $RepoRoot ('hooks\' + $name + '\.env')
    $events = @(Get-HookRecommendedEvents -Hook ([pscustomobject]@{ Name = $name; EnvPath = $envPath }))
    foreach ($doc in @(@('EN', $en), @('FA', $fa))) {
        $ref = $doc[1]
        $texts = @($(if ($ref.Sections.Contains($name)) { $ref.Sections[$name] }), $(if ($ref.Table.Contains($name)) { $ref.Table[$name] }))
        $missing = @($events | Where-Object { $e = $_; @($texts | Where-Object { $_ -notmatch ('\b' + [regex]::Escape($e) + '\b') }).Count -gt 0 })
        Check ($doc[0] + ': ' + $name + ' names its events (' + ($events -join ', ') + ')') ($missing.Count -eq 0) ('missing: ' + ($missing -join ', '))
    }
}

Write-Host '--- README hook counts ---' -ForegroundColor Cyan
$count = $script:HookMeta.Count
$readme = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'README.md'), [System.Text.Encoding]::UTF8)
$m = [regex]::Match($readme, '(?m)^(\d+) hooks ship with Hook Maker')
Check ('README.md states ' + $count + ' hooks') ($m.Success -and [int]$m.Groups[1].Value -eq $count) $(if ($m.Success) { $m.Value } else { 'no count line' })
# Persian digits and the word "hook", built from code points so this file stays ASCII.
$faDigits = -join (0..9 | ForEach-Object { [char](0x06F0 + $_) })
$faHook = -join ([char]0x0647, [char]0x0648, [char]0x06A9)
$readmeFa = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'README-FA.md'), [System.Text.Encoding]::UTF8)
$m = [regex]::Match($readmeFa, '(?m)^([' + $faDigits + ']+) ' + $faHook + ' ')
$faCount = -1
if ($m.Success) { $faCount = [int](-join ($m.Groups[1].Value.ToCharArray() | ForEach-Object { [string]([int]$_ - 0x06F0) })) }
Check ('README-FA.md states ' + $count + ' hooks (Persian digits)') ($faCount -eq $count) ('found ' + $faCount)

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
