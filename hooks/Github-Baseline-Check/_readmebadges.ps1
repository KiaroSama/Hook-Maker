# Github-Baseline-Check - the README badge reminder (plan 012 step 6, steering V40:
# at least 12 badges, no cap, the Support/donations badge always).
#
# Dot-sourced by Github-Baseline-Check.ps1; definitions only, no exit.
#
# The rule (global-repository-rules.md, Required Repository README Badges)
# applies to EVERY repository, including one with no CI and no GitHub remote,
# which is exactly where the workflow baseline above stays silent - so this runs
# before any of that hook's GitHub-only exits. Advisory only: which badges are
# TRUE is a judgement about the project, never something to gate on.
#
# The count is bounded and textual: badge-provider images in the first 40 lines
# of the root README. It never fetches an image and never checks what a badge
# claims - that is the agent's job with the evidence in front of it.

$script:BadgeGuidance = 'README badges: at least 12 verified badges, no upper limit, as many rows as needed, always including [![Support donations](https://img.shields.io/badge/Support-donations-d04a9a)](#donate) linked to the README''s "## Donate" section (copy that section verbatim from another of the user''s repositories when it is missing). Fill in this order: CI status, license, version/release, tests or coverage, runtime versions, platform, downloads/distribution, documentation, a real paper/DOI, activity/community, built-with stack, repository facts. Never padded or fabricated; a real shortfall is reported. No private data in badge URLs. Rule: global-repository-rules.md.'
$script:BadgeMinimum = 12
# The donation badge and the section it links to. The section is looked for in
# the whole README (bounded), since it normally sits near the end.
$script:DonateBadgePattern = '(?i)img\.shields\.io/badge/Support-donations-'
$script:DonateSectionPattern = '(?im)^#{1,6}\s*Donate\s*$'
$script:DonateScanLines = 4000
$script:BadgeScanLines = 40
# Hosts and paths that serve badge images. A GitHub workflow badge is matched by
# its path, since github.com also serves ordinary images.
$script:BadgeUrlPattern = '(?i)(img\.shields\.io/|badge\.fury\.io/|codecov\.io/.+/(graph/)?badge|coveralls\.io/repos/.+/badge|/actions/workflows/[^)\s"'']+/badge\.svg|/workflows/[^)\s"'']+/badge\.svg|readthedocs\.org/projects/.+/badge|sonarcloud\.io/api/project_badges|snyk\.io/test/.+/badge|zenodo\.org/badge|static\.pepy\.tech/|pepy\.tech/badge|api\.netlify\.com/api/v1/badges|img\.badgesize\.io/|badgen\.net/)'

function Get-ReadmeBadgeState {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $readme = $null
    foreach ($name in @('README.md', 'Readme.md', 'readme.md', 'README.MD', 'README')) {
        $candidate = Join-Path $ProjectRoot $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $readme = $candidate; break }
    }
    if ($null -eq $readme) { return [pscustomobject]@{ Found = $false; Count = 0; Readable = $true; DonateBadge = $false; DonateSection = $false } }
    # An explicit reader, disposed here: an enumerator abandoned by
    # Select-Object -First can keep the README open on Windows PowerShell 5.1.
    $lines = New-Object System.Collections.Generic.List[string]
    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($readme, [System.Text.Encoding]::UTF8)
        $donateSection = $false
        $read = 0
        while ($read -lt $script:DonateScanLines) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($read -lt $script:BadgeScanLines) { [void]$lines.Add($line) }
            if (-not $donateSection -and $line -match $script:DonateSectionPattern) { $donateSection = $true }
            $read++
        }
    }
    catch { return [pscustomobject]@{ Found = $true; Count = 0; Readable = $false; DonateBadge = $false; DonateSection = $false } }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    $urls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $donateBadge = $false
    foreach ($line in $lines) {
        foreach ($m in [regex]::Matches([string]$line, '!\[[^\]]*\]\(\s*<?([^)\s>]+)|<img\b[^>]*\bsrc\s*=\s*["'']([^"'']+)["'']')) {
            $url = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if ($url -match $script:BadgeUrlPattern) { [void]$urls.Add($url) }
            if ($url -match $script:DonateBadgePattern) { $donateBadge = $true }
        }
    }
    return [pscustomobject]@{ Found = $true; Count = $urls.Count; Readable = $true; DonateBadge = $donateBadge; DonateSection = $donateSection }
}

function Get-ReadmeBadgeNote {
    param([Parameter(Mandatory = $true)]$State)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add($script:BadgeGuidance)
    if (-not $State.Found) {
        [void]$lines.Add('- This repository has no root README: it needs useful project documentation with the verified badges, never a badge-only placeholder.')
    }
    elseif (-not $State.Readable) {
        [void]$lines.Add('- The README could not be read, so its badge count is UNKNOWN.')
    }
    else {
        if ($State.Count -lt $script:BadgeMinimum) {
            [void]$lines.Add('- The README shows ' + $State.Count + ' badge image(s) near its title - below ' + $script:BadgeMinimum + '. Look for verifiable facts not yet shown; a real shortfall is reported, never padded. This is a prompt, not a defect.')
        }
        if (-not $State.DonateBadge) {
            [void]$lines.Add('- The Support-donations badge is missing near the title.')
        }
        if (-not $State.DonateSection) {
            [void]$lines.Add('- The README has no "## Donate" section for the #donate link: copy it verbatim from another of the user''s repositories; never invent or alter a wallet address.')
        }
    }
    return ($lines.ToArray() -join "`n")
}
