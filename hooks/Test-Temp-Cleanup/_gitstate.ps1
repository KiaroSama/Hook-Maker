# Test-Temp-Cleanup private sibling: git state for the WHOLE candidate set.
#
# One git process per FACT for the whole set, not three per candidate: hundreds
# of residues used to mean hundreds of spawns inside a 60 s hook. Same five
# answers as Get-GitCandidateState and the same "never guess": a batch whose git
# call fails leaves every path in it 'unknown'. Index listings are read
# NUL-separated (-z) and check-ignore runs with core.quotePath=false (its -z needs
# --stdin), so non-ASCII names compare exactly; paths compare case-insensitively
# like the Windows file system that produced them - an index entry missed here
# would read as 'untracked', i.e. deletable.
# Dot-sourced by Test-Temp-Cleanup.ps1 (definitions only).

function Split-GitNulOutput {
    param($Output)
    return @((@($Output) -join "`n").Split([char]0) | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`r", "`n") })
}

function Test-GitPathCovers {
    param([string]$Listed, [string]$Candidate)
    if ([string]::Equals($Listed, $Candidate, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $Listed.StartsWith($Candidate.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-GitCandidateStateTable {
    param([string]$Root, [string[]]$RelPaths, [bool]$GitAvailable)
    $table = @{}
    foreach ($p in @($RelPaths)) { $table[$p] = 'unknown' }
    if (-not $GitAvailable -or @($RelPaths).Count -eq 0) { return $table }
    $gitRel = @{}
    foreach ($p in @($RelPaths)) { $r = $p.Replace('\', '/'); if ($r -ne '') { $gitRel[$p] = $r } }
    # Batches by accumulated command-line length (Windows caps it at 32,767).
    $batches = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[string]; $chars = 0
    foreach ($p in @($gitRel.Keys)) {
        if ($current.Count -gt 0 -and ($chars + $gitRel[$p].Length + 3) -gt 8000) { [void]$batches.Add($current.ToArray()); $current = New-Object System.Collections.Generic.List[string]; $chars = 0 }
        [void]$current.Add($p); $chars += $gitRel[$p].Length + 3
    }
    if ($current.Count -gt 0) { [void]$batches.Add($current.ToArray()) }
    foreach ($batch in $batches) {
        # ':(icase)': the index may hold another casing of the same Windows path.
        $specs = @($batch | ForEach-Object { ':(icase)' + $gitRel[$_] })
        # Which candidates have index entries (a directory counts when any file inside does).
        $cachedRaw = Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $Root, 'ls-files', '-z', '--cached', '--') + $specs)
        if ($LASTEXITCODE -ne 0) { continue }
        $cached = Split-GitNulOutput $cachedRaw
        $stagedRaw = Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $Root, 'diff', '--cached', '--name-only', '-z', '--') + $specs)
        $stagedOk = ($LASTEXITCODE -eq 0)
        $staged = Split-GitNulOutput $stagedRaw
        $notTracked = New-Object System.Collections.Generic.List[string]
        foreach ($p in $batch) {
            $r = $gitRel[$p]
            if (@($cached | Where-Object { Test-GitPathCovers $_ $r }).Count -gt 0) {
                if (-not $stagedOk) { continue }
                $table[$p] = $(if (@($staged | Where-Object { Test-GitPathCovers $_ $r }).Count -gt 0) { 'staged' } else { 'tracked' })
            }
            else { [void]$notTracked.Add($p) }
        }
        if ($notTracked.Count -eq 0) { continue }
        # Of the non-indexed ones, which are ignored. -v prints
        # `<source>:<line>:<pattern><TAB><path>` per matched path; a NEGATION
        # pattern (!...) means NOT ignored, exactly as `check-ignore --quiet`
        # answers. Exit 1 = none matched; above 1 = do not guess.
        $ignoredOut = @(Invoke-QuietCommand -FilePath git -ArgumentList (@('-c', 'core.quotePath=false', '-C', $Root, 'check-ignore', '-v', '--') + @($notTracked | ForEach-Object { $gitRel[$_] })))
        if ($LASTEXITCODE -gt 1) { continue }
        $ignoredSet = @{}
        foreach ($line in $ignoredOut) {
            $text = [string]$line; $tab = $text.IndexOf("`t"); if ($tab -lt 0) { continue }
            $source = $text.Substring(0, $tab); $colon = $source.LastIndexOf(':'); if ($colon -lt 0) { continue }
            if (-not $source.Substring($colon + 1).StartsWith('!')) { $ignoredSet[$text.Substring($tab + 1).ToLowerInvariant()] = $true }
        }
        foreach ($p in $notTracked) { $table[$p] = $(if ($ignoredSet.ContainsKey($gitRel[$p].ToLowerInvariant())) { 'ignored' } else { 'untracked' }) }
    }
    return $table
}
