# Test-Engine.ps1 scenario block: OWNED PACKAGE GENERATIONS (L08).
#
# Four properties, each one a defect that was reproducible before it:
#   1. CONTAINMENT runs from the TRUSTED CONFIGURED DESTINATION down, not just
#      from the inbox: a junction on an internal staging ancestor redirected
#      every write and delete out of the project while each path still looked
#      contained.
#   2. A replacement STAGES A NEW GENERATION and only then retires the old one.
#      The old code deleted the whole inbox before the first byte was copied, so
#      a failed copy left the state record pointing at files that no longer
#      existed - announced as a dead path on every event afterwards, and
#      un-acknowledgeable for ever.
#   3. STAGED BYTES ARE VERIFIED against the snapshot that described them.
#   4. The ACK is bound to the GENERATION ON DISK, not to a matching string.
#
# Dot-sourced by Test-Engine.ps1 into its scope (uses its $Work, Check,
# New-Project, Fire, Write-Config, New-Route, New-Endpoint helpers) - not a
# standalone suite.

    # =====================================================================
    Write-Host '--- owned package generations: containment, verified staging, bound ACK ---' -ForegroundColor Cyan

    # The guard is exercised directly: these are refusals, and a refusal that is
    # only observed through an end-to-end side effect is indistinguishable from
    # the operation never being attempted.
    # _hooklib.ps1 FIRST: the guard calls Normalize-Path and Test-PathInside from
    # it, and without them every containment answer degrades to "refused" - which
    # passes every negative assertion below for entirely the wrong reason.
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $Engine)) '_hooklib.ps1')
    . (Join-Path (Split-Path -Parent $Engine) '_packageguard.ps1')

    $guardRoot = Join-Path $Work 'guard'
    $trusted = Join-Path $guardRoot 'dest'
    $inbox = Join-Path $trusted '.ai\.cross-project-sync\inbox'
    $outside = Join-Path $guardRoot 'outside'
    New-Item -ItemType Directory -Path $inbox, $outside -Force | Out-Null
    $generation = Join-Path $inbox 'abcdef0123456789'
    New-Item -ItemType Directory -Path $generation -Force | Out-Null

    Check 'a generation inside the owned inbox, inside the trusted destination, is removable' (
        Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot $inbox -Target $generation) $generation
    Check 'a target outside the owned inbox is refused' (
        -not (Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot $inbox -Target $outside)) $outside
    Check 'the inbox root itself is refused unless the caller says it is rebuilding' (
        -not (Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot $inbox -Target $inbox)) $inbox
    Check 'the inbox root is allowed when the caller IS rebuilding it' (
        Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot $inbox -Target $inbox -AllowRootItself) $inbox
    Check 'an owned root outside the trusted destination is refused, however contained the target looks' (
        -not (Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot $outside -Target (Join-Path $outside 'gen'))) $outside
    # A SIBLING whose name merely starts with the trusted root's name is not inside it.
    Check 'containment compares whole segments (a sibling-prefix destination is not the trusted one)' (
        -not (Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot ($trusted + '2') -Target ($trusted + '2\x'))) ($trusted + '2')

    # THE ANCESTOR JUNCTION. `inbox` itself is the link here: every path below it
    # still reads as contained, and the old target-to-inbox check passed it.
    $junctionTrusted = Join-Path $guardRoot 'jdest'
    $junctionParent = Join-Path $junctionTrusted '.ai\.cross-project-sync'
    $junctionTarget = Join-Path $guardRoot 'jelsewhere'
    New-Item -ItemType Directory -Path $junctionParent, $junctionTarget -Force | Out-Null
    $junctionInbox = Join-Path $junctionParent 'inbox'
    $junctionMade = $false
    try {
        New-Item -ItemType Junction -Path $junctionInbox -Target $junctionTarget -ErrorAction Stop | Out-Null
        $junctionMade = $true
    }
    catch { $junctionMade = $false }
    if ($junctionMade) {
        $throughLink = Join-Path $junctionInbox 'gen'
        New-Item -ItemType Directory -Path $throughLink -Force | Out-Null
        Check 'a junction ON AN INTERNAL STAGING ANCESTOR is refused, not followed' (
            -not (Test-OwnedStagingChain -TrustedRoot $junctionTrusted -OwnedRoot $junctionInbox -Target $throughLink)) $throughLink
        Check 'and the deletion that would have followed it is refused too' (
            -not (Remove-OwnedPackageDirectory -Path $throughLink -OwnedRoot $junctionInbox -TrustedRoot $junctionTrusted)) $throughLink
        Check 'the directory behind the link is still there (nothing outside the project was touched)' (
            Test-Path -LiteralPath $throughLink) $throughLink
    }
    else {
        Write-Host '  (skipped: this account cannot create a directory junction)' -ForegroundColor DarkYellow
    }

    # ---- staged bytes are proven, not assumed ----------------------------
    $verifyRoot = Join-Path $guardRoot 'verify'
    New-Item -ItemType Directory -Path $verifyRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $verifyRoot 'a.md'), 'hello', (New-Object System.Text.UTF8Encoding $false))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $expected = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('hello')))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    $records = @([pscustomobject]@{ path = 'a.md'; sha256 = $expected })
    Check 'staged bytes that match the snapshot verify' (
        Test-StagedFilesVerified -FilesRoot $verifyRoot -Records $records) ''
    [System.IO.File]::WriteAllText((Join-Path $verifyRoot 'a.md'), 'tampered', (New-Object System.Text.UTF8Encoding $false))
    Check 'staged bytes that changed after the copy do NOT verify' (
        -not (Test-StagedFilesVerified -FilesRoot $verifyRoot -Records $records)) ''
    Remove-Item -LiteralPath (Join-Path $verifyRoot 'a.md') -Force
    Check 'a staged file that is missing does NOT verify' (
        -not (Test-StagedFilesVerified -FilesRoot $verifyRoot -Records $records)) ''

    # ---- end to end: a second change does not destroy the first review ----
    $src = New-Project 'PkgSrc'
    $dst = New-Project 'PkgDst'
    Set-Content -LiteralPath (Join-Path $src '.ai\LESSON.md') "# one`nfirst" -Encoding utf8
    $pkgCfg = Join-Path $Work 'cfg-package.json'
    Write-Config -Path $pkgCfg -Routes @((New-Route 'src-to-dst' (New-Endpoint 'PkgSrc' $src) (New-Endpoint 'PkgDst' $dst))) -Extensions @('.md')

    $r = Fire -Cwd $dst -Config $pkgCfg
    Check 'a first change is announced' ($r.Out -match 'CROSS-PROJECT KNOWLEDGE REVIEW REQUIRED') $r.Out
    $pkgInbox = Join-Path $dst '.ai\.cross-project-sync\inbox'
    $firstGeneration = @(Get-ChildItem -LiteralPath $pkgInbox -Recurse -Directory -Filter '*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') })
    Check 'the first review staged exactly one generation' ($firstGeneration.Count -eq 1) ([string]$firstGeneration.Count)
    $firstRoot = ''
    if ($firstGeneration.Count -eq 1) { $firstRoot = $firstGeneration[0].FullName }

    # THE SOURCE CHANGES WHILE THAT REVIEW IS OPEN. The old code wiped the inbox
    # here, so the open review's files vanished and its ACK could never validate
    # again. A new generation is staged instead; the reviewer's own generation
    # survives until the new one is verified.
    Set-Content -LiteralPath (Join-Path $src '.ai\LESSON.md') "# two`nsecond" -Encoding utf8
    $r2 = Fire -Cwd $dst -Config $pkgCfg
    Check 'the changed source is announced again' ($r2.Out -match 'CROSS-PROJECT KNOWLEDGE REVIEW REQUIRED') $r2.Out
    $secondGeneration = @(Get-ChildItem -LiteralPath $pkgInbox -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') })
    Check 'the replacement is a NEW generation, and the superseded one is retired only after it exists' (
        $secondGeneration.Count -eq 1 -and $secondGeneration[0].FullName -ne $firstRoot) (
        (@($secondGeneration | ForEach-Object { $_.Name }) -join ',') + ' first=' + (Split-Path -Leaf $firstRoot))

    # ---- the ACK is bound to the generation on disk ----------------------
    $ackManifest = Join-Path $secondGeneration[0].FullName 'manifest.json'
    $ackCommand = [string](Get-Content -LiteralPath $ackManifest -Raw | ConvertFrom-Json).acknowledgementCommand
    Check 'the manifest carries its own acknowledgement command' (-not [string]::IsNullOrWhiteSpace($ackCommand)) $ackCommand

    # Delete the reviewed package, then acknowledge it: the string still matches,
    # the package does not exist, and accepting would mark the source processed
    # on the strength of nothing.
    $movedAside = Join-Path $Work 'moved-generation'
    Move-Item -LiteralPath $secondGeneration[0].FullName -Destination $movedAside -Force
    $ackGone = Run-Acknowledgement -Command $ackCommand
    Check 'acknowledging a package that is no longer on disk is REFUSED' ($ackGone.Exit -ne 0) ($ackGone.Out + $ackGone.Error)
    Check 'and the refusal says the source will be staged again rather than blaming the reviewer' (
        ($ackGone.Error + $ackGone.Out) -match 'no longer intact') ($ackGone.Error + $ackGone.Out)

    # Put it back, tamper with the manifest's identity, and try again.
    Move-Item -LiteralPath $movedAside -Destination $secondGeneration[0].FullName -Force
    $tampered = Get-Content -LiteralPath $ackManifest -Raw | ConvertFrom-Json
    $tampered.sourceContentFingerprint = ('0' * 64)
    $tampered | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ackManifest -Encoding utf8
    $ackTampered = Run-Acknowledgement -Command $ackCommand
    Check 'acknowledging a package whose manifest no longer identifies itself is REFUSED' ($ackTampered.Exit -ne 0) ($ackTampered.Out + $ackTampered.Error)

    # ---- a dead pending record is recovered, never announced --------------
    # Delete the package outright and fire: the state record still points at
    # it, and the route must stage the current source again instead of
    # announcing files that are not there.
    Remove-Item -LiteralPath $secondGeneration[0].FullName -Recurse -Force
    $r3 = Fire -Cwd $dst -Config $pkgCfg
    Check 'a pending record whose package is gone is rebuilt, not announced as a dead path' (
        $r3.Out -match 'CROSS-PROJECT KNOWLEDGE REVIEW REQUIRED') $r3.Out
    $rebuilt = @(Get-ChildItem -LiteralPath $pkgInbox -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') })
    Check 'and the rebuilt generation really exists on disk' ($rebuilt.Count -eq 1) ([string]$rebuilt.Count)
    $rebuiltFiles = @(Get-ChildItem -LiteralPath (Join-Path $rebuilt[0].FullName 'files') -Recurse -File -ErrorAction SilentlyContinue)
    Check 'the rebuilt generation carries the staged files the message points at' ($rebuiltFiles.Count -ge 1) ([string]$rebuiltFiles.Count)
