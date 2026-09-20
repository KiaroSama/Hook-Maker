# Utf8-Encoding-Check, the NATIVE PRE-PUSH stage: every text blob that is about
# to leave this machine is decoded, and the push is refused when any of them is
# not UTF-8 - or when the set could not be fully enumerated.
#
# It is the one stage that FAILS CLOSED. The other two report on what they
# managed to look at; this one refuses a push it could not actually scan,
# because an unverified blob is exactly the blob that carries the problem.
# That different answer to "what do I do when I do not know" is why it is its
# own file.
#
# Split out of Utf8-Encoding-Check.ps1 at the 800-line ceiling; dot-sourced by
# it in the position the block occupied, so it runs in that scope with the
# resolved cwd, config, state path and exception registry already in hand. The
# block always exits - 0 or 1 - so control never returns to the caller.
# ---------------------------------------------------------------------------

# =============================================================================
# -GitPrePush: validate every outgoing text blob; FAIL CLOSED on any gap.
# =============================================================================
if ($GitPrePush) {
    if ($refUpdateLines.Count -eq 0) { exit 0 }
    $violations = New-Object System.Collections.Generic.List[string]
    $coverageErrors = New-Object System.Collections.Generic.List[string]
    $allZero = '0' * 40

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('UTF8 ENCODING CHECK - git is unavailable, so the outgoing range cannot be scanned; refusing to authorize the push as clean.')
        exit 1
    }

    # -- outgoing commit set (the Secrets-Check Get-OutgoingCommits shape,
    #    plus an explicit commit ceiling that fails closed on overflow) --
    $commits = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in $refUpdateLines) {
        $parts = @($line.Trim() -split '\s+')
        if ($parts.Count -lt 4) { continue }
        $localRef = $parts[0]
        $localSha = $parts[1]
        $remoteSha = $parts[3]
        if ($localSha -eq $allZero) { continue }    # deletion - nothing pushed
        $revs = @()
        if ($remoteSha -eq $allZero) {
            # New branch: scope to commits not already on any remote-tracking
            # ref, so previously-reviewed history is not rescanned.
            $revs = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-list', $localSha, '--not', '--remotes') | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                [void]$coverageErrors.Add('new ref ' + $localRef + ' - outgoing commits could not be resolved (rev-list failed); refusing to treat it as clean')
                continue
            }
        }
        else {
            $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--verify', '--quiet', ($remoteSha + '^{commit}'))
            if ($LASTEXITCODE -ne 0) {
                $shortRemote = if ($remoteSha.Length -gt 7) { $remoteSha.Substring(0, 7) } else { $remoteSha }
                [void]$coverageErrors.Add('ref ' + $localRef + ' - remote commit ' + $shortRemote + ' is not resolvable locally, so the outgoing range cannot be bounded; refusing to treat it as clean')
                continue
            }
            $revs = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-list', ($remoteSha + '..' + $localSha)) | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                [void]$coverageErrors.Add('ref ' + $localRef + ' - outgoing commits could not be resolved (rev-list failed); refusing to treat it as clean')
                continue
            }
        }
        foreach ($rev in $revs) { [void]$commits.Add([string]$rev) }
    }
    if ($commits.Count -gt $script:MaxOutgoingCommits) {
        [void]$coverageErrors.Add('the outgoing range holds ' + $commits.Count + ' commits, over the ' + $script:MaxOutgoingCommits + '-commit ceiling; required coverage would be incomplete, so the push is refused (fail closed)')
    }

    # -- changed blobs per outgoing commit (diff-tree), deduped by sha+path --
    $blobs = New-Object System.Collections.Generic.List[object]
    $seenBlobs = New-Object System.Collections.Generic.HashSet[string]
    $blobOverflow = $false
    if ($coverageErrors.Count -eq 0) {
        foreach ($commit in @($commits)) {
            if ($blobOverflow) { break }
            $diffLines = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff-tree', '-r', '--root', '--no-commit-id', '--diff-filter=d', [string]$commit) | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                $shortCommit = ([string]$commit)
                if ($shortCommit.Length -gt 7) { $shortCommit = $shortCommit.Substring(0, 7) }
                [void]$coverageErrors.Add('changed files in outgoing commit ' + $shortCommit + ' could not be enumerated; refusing to treat the push as clean')
                continue
            }
            foreach ($rawLine in $diffLines) {
                $lineText = [string]$rawLine
                if (-not $lineText.StartsWith(':')) { continue }
                $tabIndex = $lineText.IndexOf("`t")
                if ($tabIndex -lt 0) { continue }
                $meta = @($lineText.Substring(1, $tabIndex - 1) -split '\s+')
                if ($meta.Count -lt 5) { continue }
                $newSha = [string]$meta[3]
                if ($newSha -eq $allZero) { continue }
                $blobPath = (ConvertFrom-GitQuotedPath ($lineText.Substring($tabIndex + 1))).Replace('\', '/')
                if (-not $seenBlobs.Add($newSha + '|' + $blobPath)) { continue }
                if ($blobs.Count -ge $maxFiles) { $blobOverflow = $true; break }
                [void]$blobs.Add([pscustomobject]@{ Sha = $newSha; Path = $blobPath })
            }
        }
    }
    if ($blobOverflow) {
        [void]$coverageErrors.Add('the outgoing range changes more than ' + $maxFiles + ' blobs (UTF8_MAX_FILES); required coverage would be incomplete, so the push is refused (fail closed). Raise UTF8_MAX_FILES or push in smaller batches')
    }

    # -- strict validation of every enumerated blob --
    $violatedPaths = New-Object System.Collections.Generic.HashSet[string]
    if ($coverageErrors.Count -eq 0) {
        foreach ($blob in $blobs.ToArray()) {
            if (Test-ExceptionMatch -Exceptions $exceptions -RelativePath $blob.Path) { continue }
            $read = Get-GitBlobBytes -Cwd $cwd -BlobSha $blob.Sha -MaxFullBytes $maxFileBytes
            if ($read.Failed) {
                [void]$coverageErrors.Add('outgoing blob for ' + $blob.Path + ' could not be read; refusing to treat the push as clean')
                continue
            }
            $class = Resolve-ClassWithExtension -RelativePath $blob.Path -RawClass (Get-Utf8Classification -Bytes $read.Bytes -Truncated $read.Truncated)
            if ($script:ViolationClasses -contains $class) {
                if ($violatedPaths.Add($blob.Path)) {
                    [void]$violations.Add($blob.Path + ' - ' + (Get-ClassLabel $class) + ' in an outgoing commit')
                }
            }
            elseif ($class -eq 'oversized') {
                [void]$coverageErrors.Add('outgoing text blob ' + $blob.Path + ' exceeds UTF8_MAX_FILE_KB and could not be fully validated; raise the ceiling or add a documented exception (fail closed)')
            }
        }
    }

    if ($violations.Count -eq 0 -and $coverageErrors.Count -eq 0) { exit 0 }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('UTF8 ENCODING CHECK - push blocked:')
    $shown = 0
    foreach ($violation in $violations.ToArray()) {
        if ($shown -ge $maxFindings) { [void]$lines.Add('(+' + ($violations.Count - $shown) + ' more non-UTF-8 finding(s) omitted)'); break }
        [void]$lines.Add('- ' + $violation)
        $shown++
    }
    foreach ($coverageError in $coverageErrors.ToArray()) { [void]$lines.Add('- Outgoing coverage incomplete: ' + $coverageError + '.') }
    [void]$lines.Add('Re-save each named file as strict UTF-8 in a new commit (this hook never rewrites or transcodes anything), or add a narrow documented exception to ' + $exceptionFileSetting + ', then push again.')
    foreach ($warning in $configWarnings.ToArray()) { [void]$lines.Add('Utf8-Encoding-Check .env: ' + $warning) }
    # Advisory-only softens CONFIRMED findings to a warning, but an
    # unscannable REQUIRED range still fails closed - a gate must never
    # authorize a push it could not actually scan.
    [Console]::Error.WriteLine(($lines.ToArray() -join "`n"))
    if ($advisoryOnly -and $coverageErrors.Count -eq 0) { exit 0 }
    exit 1
}

