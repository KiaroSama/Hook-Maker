# Graph-Update-Check private sibling: the Markdown work time.
#
# The graph covers Markdown folders Git never shows (graphify-markdown.md):
# .ai/, specs/, .specify/, plans/ and any top-level folder holding ten or more
# .md files, git-ignored or not. Get-LatestWorkTimeUtc is git-based, so an edit
# there never made the graph stale. This walk finds the newest .md write time
# in those folders, bounded in depth, files and time; a bound hit is reported
# as Partial and never read as "nothing changed".
# Dot-sourced by Graph-Update-Check.ps1 (definitions only).

$script:MarkdownWorkNamedFolders = @('.ai', 'specs', '.specify', 'plans')
# Dependency, build, cache, log and agent-configuration folders: never graph material.
$script:MarkdownWorkSkip = @('node_modules', '.venv', 'venv', 'dist', 'build', 'coverage', 'logs', '.codebase-memory',
    'graphify-out', '.git', '.claude', '.codex', '.agents', '.kiro', '.cursor', '.cline', '.ignoreme', '.playwright-mcp')

function Test-MarkdownWorkSkipped {
    param([string]$Name)
    $lower = $Name.ToLowerInvariant()
    return ($script:MarkdownWorkSkip -contains $lower -or $lower.StartsWith('.ci-'))
}

# Newest .md under one root: returns @{ Newest; Count; Partial }. Reparse points
# are not followed (a junction can lead anywhere, including back up the tree).
function Get-MarkdownFolderScan {
    param([string]$Root, [int]$MaxDepth, [System.Diagnostics.Stopwatch]$Clock, [int]$BudgetMs, [ref]$FilesLeft)
    $newest = [DateTime]::MinValue; $count = 0; $partial = $false
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($Root, 0))
    while ($stack.Count -gt 0) {
        if ($Clock.ElapsedMilliseconds -gt $BudgetMs -or $FilesLeft.Value -le 0) { $partial = $true; break }
        $entry = $stack.Pop(); $dir = [string]$entry[0]; $depth = [int]$entry[1]
        try { $info = New-Object System.IO.DirectoryInfo $dir; $children = @($info.GetFileSystemInfos()) } catch { continue }
        foreach ($child in $children) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($child -is [System.IO.DirectoryInfo]) {
                if ($depth -lt $MaxDepth -and -not (Test-MarkdownWorkSkipped $child.Name)) { $stack.Push(@($child.FullName, ($depth + 1))) }
                continue
            }
            if ($child.Extension -ne '.md') { continue }
            if ($FilesLeft.Value -le 0) { $partial = $true; break }    # the cap is per file, not per directory
            $count++; $FilesLeft.Value--
            if ($child.LastWriteTimeUtc -gt $newest) { $newest = $child.LastWriteTimeUtc }
        }
    }
    return [pscustomobject]@{ Newest = $newest; Count = $count; Partial = $partial }
}

# The Markdown work time of a project: @{ TimeUtc (or $null); Partial; Files }.
function Get-MarkdownWorkTime {
    param([string]$ProjectRoot, [int]$MaxFiles = 5000, [int]$BudgetMs = 2000, [int]$MaxDepth = 4)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $filesLeft = $MaxFiles
    $newest = [DateTime]::MinValue; $partial = $false; $files = 0
    $tops = @()
    try { $tops = @((New-Object System.IO.DirectoryInfo $ProjectRoot).GetDirectories()) } catch { $tops = @() }
    foreach ($top in $tops) {
        if (($top.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $named = $script:MarkdownWorkNamedFolders -contains $top.Name.ToLowerInvariant()
        if (-not $named -and (Test-MarkdownWorkSkipped $top.Name)) { continue }
        $scan = Get-MarkdownFolderScan -Root $top.FullName -MaxDepth $MaxDepth -Clock $clock -BudgetMs $BudgetMs -FilesLeft ([ref]$filesLeft)
        $files += $scan.Count
        if ($scan.Partial) { $partial = $true }
        # A folder counts when it is one of the named ones or holds 10+ .md files.
        if (($named -or $scan.Count -ge 10) -and $scan.Newest -gt $newest) { $newest = $scan.Newest }
        if ($partial) { break }
    }
    $time = $(if ($newest -eq [DateTime]::MinValue) { $null } else { $newest })
    return [pscustomobject]@{ TimeUtc = $time; Partial = $partial; Files = $files }
}
