# Check the bilingual hook tables, event lists, shipped counts and README badges.
# Read the installer metadata without running the wizard.
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
    $tableRuns = [ordered]@{}; $sectionRuns = [ordered]@{}; $dupes = @(); $badAnchors = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $row = [regex]::Match($line, '^\| \[`([^`]+)`\]\(#([^)]+)\) \| ([^|]+) \|')
        if ($row.Success) {
            $name = $row.Groups[1].Value
            if ($tableRuns.Contains($name)) { $dupes += $name }
            $tableRuns[$name] = $row.Groups[3].Value.Trim()
            $anchor = ($name -replace '[^A-Za-z0-9_-]', '').ToLowerInvariant()
            if ($row.Groups[2].Value -cne $anchor) { $badAnchors += $name }
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
    return [pscustomobject]@{ Table = $tableRuns; Sections = $sectionRuns; Duplicates = @($dupes); BadAnchors = @($badAnchors) }
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
    Check ($label + ': table links match their hook headings') ($ref.BadAnchors.Count -eq 0) ($ref.BadAnchors -join ', ')
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
$packageCount = $script:HookMeta.Count
$count = $hookDirs.Count
Check 'shipped count includes exactly one engine outside installer package metadata' ($hookDirs -contains $engine -and $count -eq ($packageCount + 1))
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$readme = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'README.md'), $utf8)
$readmeFa = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'README-FA.md'), $utf8)
$m = [regex]::Match($readme, '(?m)^([0-9]+) hooks ship with Hook Maker: ([0-9]+) custom hook packages')
Check "README.md states $count hooks and $packageCount packages" ($m.Success -and $m.Groups[1].Value -ceq "$count" -and $m.Groups[2].Value -ceq "$packageCount") $m.Value

# Normalize only the Persian prose count; the badge URLs use ASCII in both files.
$rtlPrefix = -join ([char]0x200F, [char]0x2067)
$faDigits = '[' + [char]0x06F0 + '-' + [char]0x06F9 + ']+'
$faHook = -join ([char]0x0647, [char]0x0648, [char]0x06A9)
$faPackage = -join ([char]0x0628, [char]0x0633, [char]0x062A, [char]0x0647, [char]0x0654)
$faCountLine = [regex]::Match($readmeFa, ('(?m)^' + $rtlPrefix + '(' + $faDigits + ') ' + $faHook + ' [^\r\n:]+: (' + $faDigits + ') ' + $faPackage))
$faCounts = @(foreach ($group in @($faCountLine.Groups[1], $faCountLine.Groups[2])) {
    -join ($group.Value.ToCharArray() | ForEach-Object { [string]([int]$_ - 0x06F0) })
})
Check "README-FA.md states $count hooks and $packageCount packages" ($faCountLine.Success -and $faCounts[0] -ceq "$count" -and $faCounts[1] -ceq "$packageCount") $faCountLine.Value

Write-Host '--- bilingual README badges ---' -ForegroundColor Cyan
$badgePattern = '(?m)^\[!\[(?<alt>[^\]\r\n]+)\]\(https://img\.shields\.io/badge/(?<label>[A-Za-z0-9.%]+)-(?<value>[A-Za-z0-9.%]+)-(?<color>[0-9a-f]{6})\)\]\((?<target>[^()\s]+)\)\r?$'
$blocks = @(foreach ($doc in @(@('README.md', $readme), @('README-FA.md', $readmeFa))) {
    $name = $doc[0]; $text = $doc[1]
    $block = [regex]::Matches($text, '(?ms)^<div align="center">\r?\n\r?\n(.*?)\r?\n\r?\n</div>\r?$')
    $rows = @()
    if ($block.Count -eq 1) { $rows = @([regex]::Matches($block[0].Groups[1].Value, $badgePattern)) }
    $shieldImages = [regex]::Matches($text, 'https?://img\.shields\.io/').Count
    Check "$name has one centered block with 12 to 16 static badges" ($block.Count -eq 1 -and $rows.Count -ge 12 -and $rows.Count -le 16 -and $rows.Count -eq $shieldImages) "valid rows: $($rows.Count), Shields URLs: $shieldImages"
    $colors = @($rows | ForEach-Object { $_.Groups['color'].Value })
    Check "$name badge colors are distinct" ($colors.Count -eq @($colors | Sort-Object -Unique).Count)
    $required = @($rows | Where-Object { $_.Groups['color'].Value -in '8b5cf6', '0891b2', 'ca8a04', 'd04a9a' } | ForEach-Object { $_.Groups['label'].Value + '-' + $_.Groups['color'].Value })
    Check "$name orders the four required badges" (($required -join ',') -ceq 'PowerShell-8b5cf6,platform-0891b2,repo%20size-ca8a04,Support-d04a9a')
    $hookBadges = @($rows | Where-Object { $_.Groups['label'].Value -ceq 'hooks' })
    Check "$name badge states $count shipped hooks" ($hookBadges.Count -eq 1 -and $hookBadges[0].Groups['value'].Value -ceq ("$count" + '%20shipped'))
    foreach ($row in $rows) {
        $target = $row.Groups['target'].Value
        if ($target -ceq '#donate') {
            $ok = $row.Groups['label'].Value -ceq 'Support' -and $row.Groups['value'].Value -ceq 'donations' -and $row.Groups['color'].Value -ceq 'd04a9a' -and $row.Index -eq $rows[-1].Index -and $text -cmatch '(?m)^(?:## Donate|<a name="donate"></a>)\r?$'
        }
        else {
            $ok = $row.Groups['label'].Value -cne 'Support' -and $target -cmatch '^(?:\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*/)*[A-Za-z0-9_-][A-Za-z0-9_.-]*$' -and (Test-Path -LiteralPath (Join-Path $RepoRoot $target) -PathType Leaf)
        }
        Check "$name badge points to a file or the final donation anchor" $ok $target
    }
    ($rows | ForEach-Object { $_.Value.TrimEnd("`r") }) -join "`n"
})
Check 'README badge rows match in both languages' ($blocks.Count -eq 2 -and $blocks[0] -ceq $blocks[1])

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
