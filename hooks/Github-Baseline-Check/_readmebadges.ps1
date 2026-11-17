# Github-Baseline-Check - the README badge reminder (plan 012 step 6, steering V40,
# cap V45, centred V47: 12 to 16 badges inside one <div align="center"> block, the
# Support/donations badge always).
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

$script:BadgeGuidance = 'BEFORE README: global-repository-rules.md README FULL; 12 to 16 verified badges/Donate. BEFORE app logo/signing: global-project-lifecycle-rules.md FULL; README!=app logo.'
$script:BadgeMinimum = 12
$script:BadgeMaximum = 16
# The donation badge and the section it links to. The section is looked for in
# the whole README (bounded), since it normally sits near the end.
$script:DonateBadgePattern = '(?i)img\.shields\.io/badge/Support-donations-'
$script:DonateSectionPattern = '(?im)^#{1,6}\s*Donate\s*$'
$script:DonateScanLines = 4000
# A badge row is centred when it sits between an opening <div align="center"> and
# its </div>; GitHub keeps that attribute.
$script:CentreOpenPattern = '(?i)<div\b[^>]*\balign\s*=\s*["'']?center\b'
$script:DivClosePattern = '(?i)</div\s*>'
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
    if ($null -eq $readme) { return [pscustomobject]@{ Found = $false; Count = 0; Readable = $true; DonateBadge = $false; DonateSection = $false; Centred = $true } }
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
    catch { return [pscustomobject]@{ Found = $true; Count = 0; Readable = $false; DonateBadge = $false; DonateSection = $false; Centred = $true } }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    $urls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $donateBadge = $false
    $inCentre = $false
    $outsideCentre = 0
    foreach ($line in $lines) {
        if ([string]$line -match $script:CentreOpenPattern) { $inCentre = $true }
        foreach ($m in [regex]::Matches([string]$line, '!\[[^\]]*\]\(\s*<?([^)\s>]+)|<img\b[^>]*\bsrc\s*=\s*["'']([^"'']+)["'']')) {
            $url = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if ($url -match $script:BadgeUrlPattern) {
                [void]$urls.Add($url)
                if (-not $inCentre) { $outsideCentre++ }
            }
            if ($url -match $script:DonateBadgePattern) { $donateBadge = $true }
        }
        if ([string]$line -match $script:DivClosePattern) { $inCentre = $false }
    }
    return [pscustomobject]@{ Found = $true; Count = $urls.Count; Readable = $true; DonateBadge = $donateBadge; DonateSection = $donateSection; Centred = ($outsideCentre -eq 0); Format = @(Get-ReadmeBadgeFormatIssue -Lines $lines) }
}

# Steering V92-V93: the mandatory four by their RESERVED colours, donations last,
# the plain flat-square URL shape, one colour per badge, and a link target that
# is not the image itself. Textual only; a badge's TRUTH stays the agent's job.
$script:ReservedBadgeColour = [ordered]@{ 'language-version' = '8b5cf6'; 'platform' = '0891b2'; 'repo-size' = 'ca8a04' }
function Get-ReadmeBadgeFormatIssue {
    param([AllowEmptyCollection()][System.Collections.Generic.List[string]]$Lines)
    $badges = New-Object System.Collections.Generic.List[object]
    foreach ($line in $Lines) {
        foreach ($m in [regex]::Matches([string]$line, '(?i)\[!\[[^\]]*\]\(\s*(https?://img\.shields\.io/[^)\s]+)\s*\)\]\(\s*([^)\s]*)\s*\)')) {
            $url = $m.Groups[1].Value
            $hex = if ($url -match '(?i)/badge/[^?#]*-([0-9a-f]{6})(?:[?#]|$)') { $Matches[1].ToLowerInvariant() } else { '' }
            [void]$badges.Add([pscustomobject]@{ Url = $url; Target = $m.Groups[2].Value; Hex = $hex })
        }
    }
    $issues = New-Object System.Collections.Generic.List[string]
    if ($badges.Count -eq 0) { return @() }
    $hexes = @($badges | ForEach-Object { $_.Hex } | Where-Object { $_ })
    $absent = @($script:ReservedBadgeColour.Keys | Where-Object { $hexes -notcontains $script:ReservedBadgeColour[$_] } | ForEach-Object { $_ + ' #' + $script:ReservedBadgeColour[$_] })
    if ($absent.Count -gt 0) { [void]$issues.Add('mandatory missing: ' + ($absent -join ', ')) }
    if ($badges[$badges.Count - 1].Url -notmatch $script:DonateBadgePattern -and @($badges | Where-Object { $_.Url -match $script:DonateBadgePattern }).Count -gt 0) { [void]$issues.Add('donations badge not last') }
    $shape = @($badges | Where-Object { $_.Url -match '(?i)/style/|/endpoint|\?' -or $_.Hex -eq '' })
    if ($shape.Count -gt 0) { [void]$issues.Add([string]$shape.Count + ' not plain flat-square /badge/<label>-<value>-<hex>') }
    $dupes = @($hexes | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupes.Count -gt 0) { [void]$issues.Add('shared colour(s) ' + ($dupes -join ', ')) }
    $selfLinks = @($badges | Where-Object { $_.Target -eq '' -or $_.Target -match '(?i)img\.shields\.io' })
    if ($selfLinks.Count -gt 0) { [void]$issues.Add([string]$selfLinks.Count + ' linking to the image, not a repo path/anchor') }
    return @($issues)
}

function Get-ReadmeBadgeNote {
    param([Parameter(Mandatory = $true)]$State)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add($script:BadgeGuidance)
    if (-not $State.Found) {
        [void]$lines.Add('- README missing: useful docs + verified badges, not badge-only.')
    }
    elseif (-not $State.Readable) {
        [void]$lines.Add('- README unreadable; badge count UNKNOWN.')
    }
    else {
        if ($State.Count -lt $script:BadgeMinimum) {
            [void]$lines.Add('- Title badges: ' + $State.Count + ' < ' + $script:BadgeMinimum + '. Add distinct verified facts or report shortfall; no padding. Advisory, not defect.')
        }
        elseif ($State.Count -gt $script:BadgeMaximum) {
            [void]$lines.Add('- Title badges: ' + $State.Count + ' > ' + $script:BadgeMaximum + '. Trim lower-priority facts. Advisory, not defect.')
        }
        if ($State.Count -gt 0 -and -not $State.Centred) {
            [void]$lines.Add('- Center badge rows: one <div align="center">, blank lines after opening/before </div>.')
        }
        if (-not $State.DonateBadge) {
            [void]$lines.Add('- Title lacks Support-donations badge.')
        }
        $format = @(if ($null -ne $State.PSObject.Properties['Format']) { $State.Format | Where-Object { $_ } })
        if ($format.Count -gt 0) {
            [void]$lines.Add('- Badge format: ' + ($format -join '; ') + '.')
        }
        if (-not $State.DonateSection) {
            [void]$lines.Add('- Missing ## Donate/#donate: verbatim authorized public text; never invent/alter wallets.')
        }
    }
    return ($lines.ToArray() -join "`n")
}
