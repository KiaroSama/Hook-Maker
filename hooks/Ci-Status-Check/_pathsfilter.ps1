# Ci-Status-Check private sibling: "no workflow can run for the files this push
# changed". A commit with zero runs used to block for ever when every push
# workflow carries a `paths:`/`paths-ignore:` filter the push does not satisfy -
# no wait and no pull request would ever start a run. Only THAT shape is
# recognised; a PR-only workflow or a branch filter keeps the block (the
# maintainer's standing decision: open the PR / push to the right branch).
#
# Read as DATA with a bounded line reader (no YAML parser is guaranteed here).
# Anything it cannot read with certainty answers "may run", which keeps the
# block: this file can turn a block into a note, never silence a real gap.
# Dot-sourced by Ci-Status-Check.ps1 (definitions only).

# GitHub filter glob -> anchored regex: `**` any characters, `*` any but `/`,
# `?` one character but `/` (docs: "Filter pattern cheat sheet").
function ConvertTo-FilterRegex {
    param([string]$Glob)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('^')
    for ($i = 0; $i -lt $Glob.Length; $i++) {
        $c = $Glob[$i]
        if ($c -eq '*' -and $i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
            if ($i + 2 -lt $Glob.Length -and $Glob[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 2 }
            else { [void]$sb.Append('.*'); $i += 1 }
        }
        elseif ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

# Sequential include/exclude, as GitHub evaluates `paths` and `branches`: a later
# `!pattern` removes what an earlier pattern matched.
function Test-FilterMatch {
    param([string]$Value, [string[]]$Patterns)
    $matched = $false
    foreach ($p in @($Patterns)) {
        $negate = $p.StartsWith('!')
        $glob = $(if ($negate) { $p.Substring(1) } else { $p })
        if ($Value -match (ConvertTo-FilterRegex $glob)) { $matched = -not $negate }
    }
    return $matched
}

# The `push` trigger of one workflow text: $null when it has none, otherwise
# @{ Branches; BranchesIgnore; Paths; PathsIgnore; Certain }.
function Get-WorkflowPushFilter {
    param([AllowEmptyString()][string]$Text)
    $lines = @($Text -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^["'']?on["'']?\s*:\s*(?<rest>.*)$') { continue }
        $rest = ($Matches['rest'] -replace '\s+#.*$', '').Trim()
        if ($rest -ne '') {
            if ($rest.StartsWith('{')) { return [pscustomobject]@{ Certain = $false } }     # flow mapping: not read here
            $names = @($rest.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") })
            if ($names -contains 'push') { return [pscustomobject]@{ Certain = $true; Branches = @(); BranchesIgnore = @(); Paths = @(); PathsIgnore = @() } }
            return $null
        }
        $pushIndent = -1; $filter = $null; $key = ''
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if ($line.Trim() -eq '' -or $line.Trim().StartsWith('#')) { continue }
            $indent = $line.Length - $line.TrimStart(' ').Length
            if ($indent -eq 0) { break }
            if ($pushIndent -lt 0) {
                if ($line -match '^\s*["'']?push["'']?\s*:\s*(?<v>.*)$') {
                    $pushIndent = $indent
                    $filter = [pscustomobject]@{ Certain = $true; Branches = @(); BranchesIgnore = @(); Paths = @(); PathsIgnore = @() }
                    if (($Matches['v'] -replace '\s+#.*$', '').Trim() -notin @('', '{}', 'null', '~')) { return [pscustomobject]@{ Certain = $false } }
                }
                continue
            }
            if ($indent -le $pushIndent) { break }
            if ($line -match '^\s*(?<k>branches|branches-ignore|paths|paths-ignore|tags|tags-ignore)\s*:\s*(?<v>.*)$') {
                $key = $Matches['k']; $v = ($Matches['v'] -replace '\s+#.*$', '').Trim()
                if ($v -ne '') {
                    if (-not ($v.StartsWith('[') -and $v.EndsWith(']'))) { return [pscustomobject]@{ Certain = $false } }
                    $items = @($v.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ -ne '' })
                    $filter = Add-PushFilterItems $filter $key $items
                    $key = ''
                }
                continue
            }
            if ($key -ne '' -and $line -match '^\s*-\s*(?<item>.+?)\s*$') {
                $filter = Add-PushFilterItems $filter $key @(($Matches['item'] -replace '\s+#.*$', '').Trim().Trim('"', "'"))
                continue
            }
            return [pscustomobject]@{ Certain = $false }    # a key this reader does not know: never guess
        }
        return $filter
    }
    return $null
}

function Add-PushFilterItems {
    param($Filter, [string]$Key, [string[]]$Items)
    switch ($Key) {
        'branches' { $Filter.Branches = @($Filter.Branches) + $Items }
        'branches-ignore' { $Filter.BranchesIgnore = @($Filter.BranchesIgnore) + $Items }
        'paths' { $Filter.Paths = @($Filter.Paths) + $Items }
        'paths-ignore' { $Filter.PathsIgnore = @($Filter.PathsIgnore) + $Items }
        default { $Filter.Certain = $false }    # tags filters: a branch push is never a tag push; not read
    }
    return $Filter
}

# True only when EVERY workflow starts on push for this branch, carries a paths
# filter, and not one changed file satisfies it. Any other trigger (pull_request,
# schedule, ...), a branch filter that excludes the branch, an unreadable file or
# an empty change list answers $false: the existing block stays.
function Test-NoWorkflowForChangedPaths {
    param([string]$ProjectRoot, [string]$Branch, [string[]]$ChangedFiles)
    if (@($ChangedFiles).Count -eq 0) { return $false }
    $dir = Join-Path $ProjectRoot '.github\workflows'
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yml', '.yaml') } | Select-Object -First 50)
    if ($files.Count -eq 0) { return $false }
    foreach ($file in $files) {
        if ($file.Length -gt 262144) { return $false }
        $text = ''
        try { $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) } catch { return $false }
        $triggers = @(Get-WorkflowTopTriggers $text)
        if ($triggers.Count -eq 0) { return $false }    # triggers not read (flow mapping, odd layout): never guess
        if (@($triggers | Where-Object { $_ -cnotin @('push', 'workflow_dispatch', 'workflow_call') }).Count -gt 0) { return $false }
        if ($triggers -cnotcontains 'push') { continue }    # manual-only workflow: never runs on a push anyway
        $filter = Get-WorkflowPushFilter $text
        if ($null -eq $filter -or -not $filter.Certain) { return $false }
        if (@($filter.Branches).Count -gt 0 -and -not (Test-FilterMatch $Branch $filter.Branches)) { return $false }
        if (@($filter.BranchesIgnore).Count -gt 0 -and (Test-FilterMatch $Branch $filter.BranchesIgnore)) { return $false }
        if (@($filter.Paths).Count -eq 0 -and @($filter.PathsIgnore).Count -eq 0) { return $false }
        foreach ($changed in @($ChangedFiles)) {
            if (@($filter.Paths).Count -gt 0 -and (Test-FilterMatch $changed $filter.Paths)) { return $false }
            if (@($filter.PathsIgnore).Count -gt 0 -and -not (Test-FilterMatch $changed $filter.PathsIgnore)) { return $false }
        }
    }
    return $true
}

# The files the last push changed: the remote-tracking ref before the push (its
# reflog) to the pushed commit. No previous value, a failed diff or more than
# 1,000 files (GitHub then runs every workflow) -> @(), which means "may run".
function Get-PushChangedFiles {
    param([string]$Cwd, [string]$Upstream, [string]$Sha)
    if ([string]::IsNullOrWhiteSpace($Upstream)) { return @() }
    $before = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'rev-parse', '--verify', '--quiet', ($Upstream + '@{1}')))
    if ($LASTEXITCODE -ne 0 -or $before.Count -ne 1) { return @() }
    $files = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, '-c', 'core.quotePath=false', 'diff', '--name-only', ([string]$before[0]).Trim(), $Sha))
    if ($LASTEXITCODE -ne 0 -or $files.Count -gt 1000) { return @() }
    return @($files | Where-Object { $_ })
}
