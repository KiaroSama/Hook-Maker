# Test-Utf8EncodingCheck.ps1 scenario block: BYTE-LEVEL CLASSIFICATION
# (valid ASCII/UTF-8/BOM, invalid sequences, UTF-16 with and without BOM,
# legacy codepages, binary-with-NUL, extensionless files, misleading
# extensions resolved by content instead of name, unreadable and oversized
# files, reparse points) and the EXCEPTION REGISTRY validation rules (every
# malformed/overbroad entry proven to NOT grant an exception).
#
# Dot-sourced by Test-Utf8EncodingCheck.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- classification: one project, every byte shape, one SessionStart ---' -ForegroundColor Cyan
    $hcCls = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FINDINGS=50`n"
    $projCls = New-Proj 'Classify'
    Write-Utf8 (Join-Path $projCls 'ascii.txt') "plain ascii text`n"
    # [char] composition instead of "`u{...}": the escape is pwsh-7-only and
    # would be a PARSE error under the Windows PowerShell 5.1 host.
    Write-Utf8 (Join-Path $projCls 'accents.md') ('h' + [char]0x00E9 + 'llo w' + [char]0x00F6 + 'rld ' + [char]0x2014 + " ok`n")
    Write-Bytes (Join-Path $projCls 'bom.json') (Get-Utf8BomBytes '{"ok":true}')
    Write-Bytes (Join-Path $projCls 'broken.txt') (Get-InvalidUtf8Bytes 'BROKENMARKER')
    Write-Bytes (Join-Path $projCls 'legacy.ini') (Get-Cp1252Bytes 'CP1252MARKER')
    Write-Bytes (Join-Path $projCls 'u16le.txt') (Get-Utf16LeBytes 'sixteen le text with bom')
    Write-Bytes (Join-Path $projCls 'u16be.txt') (Get-Utf16BeBytes 'sixteen be text with bom')
    Write-Bytes (Join-Path $projCls 'u16nobom.txt') (Get-Utf16LeBytes -NoBom 'sixteen le text without any bom marker')
    Write-Bytes (Join-Path $projCls 'blob.bin') (Get-BinaryBytes)
    Write-Utf8 (Join-Path $projCls 'LICENSE') "extensionless but perfectly valid text`n"
    Write-Bytes (Join-Path $projCls 'NOTICEFILE') (Get-InvalidUtf8Bytes 'NOTICEMARKER')
    Write-Utf8 (Join-Path $projCls 'textbytes.png') "these are plain text bytes despite the png name`n"
    Write-Bytes (Join-Path $projCls 'badbytes.png') (Get-InvalidUtf8Bytes 'BADPNGMARKER')
    Write-Bytes (Join-Path $projCls 'fake16.png') (Get-Utf16LeBytes 'utf-16 text hiding under a png name')
    Write-Bytes (Join-Path $projCls 'nulbytes.txt') (Get-BinaryBytes)
    Write-Bytes (Join-Path $projCls 'bominvalid.txt') ([byte[]]((New-Object System.Text.UTF8Encoding $true).GetPreamble() + (Get-InvalidUtf8Bytes 'BOMBROKENMARKER')))
    $rCls = Fire -HookPath $hcCls.Script -Cwd $projCls -EventName 'SessionStart' -LocalAppData $hcCls.LocalAppData
    Check 'classification run exits 0 with no stderr' ($rCls.Exit -eq 0 -and $rCls.Err -eq '') $rCls.Err
    $parsedCls = $null
    try { $parsedCls = $rCls.Out | ConvertFrom-Json } catch { $parsedCls = $null }
    Check 'the baseline advisory is a single valid JSON document' ($null -ne $parsedCls -and (@($rCls.Out -split "`n" | Where-Object { $_.Trim() -ne '' })).Count -eq 1) $rCls.Out
    Check 'SessionStart never blocks, even with many legacy findings' ($rCls.Out -notmatch '"decision"') $rCls.Out
    $msgCls = Get-Message $rCls.Out
    Check 'an invalid UTF-8 sequence (lone 0xC3) is a finding' ($msgCls -match '- broken\.txt - an invalid UTF-8 byte sequence') $msgCls
    Check 'a Windows-1252 high byte is rejected as invalid UTF-8' ($msgCls -match '- legacy\.ini - an invalid UTF-8 byte sequence') $msgCls
    Check 'UTF-16 LE (BOM) is non-UTF-8 TEXT, not a binary skip' ($msgCls -match '- u16le\.txt - UTF-16 LE text') $msgCls
    Check 'UTF-16 BE (BOM) is non-UTF-8 TEXT, not a binary skip' ($msgCls -match '- u16be\.txt - UTF-16 BE text') $msgCls
    Check 'BOM-less UTF-16 LE is recognized by its NUL parity pattern' ($msgCls -match '- u16nobom\.txt - UTF-16 LE text') $msgCls
    Check 'an extensionless INVALID file is still classified and reported' ($msgCls -match '- NOTICEFILE - an invalid UTF-8 byte sequence') $msgCls
    Check 'a BOM does not bless an invalid remainder (BOM + bad bytes = invalid)' ($msgCls -match '- bominvalid\.txt - an invalid UTF-8 byte sequence') $msgCls
    Check 'valid ASCII is never a finding' ($msgCls -notmatch '- ascii\.txt') $msgCls
    Check 'valid non-ASCII UTF-8 is never a finding' ($msgCls -notmatch '- accents\.md') $msgCls
    Check 'valid UTF-8 WITH a BOM passes (a BOM alone is never a violation)' ($msgCls -notmatch '- bom\.json') $msgCls
    Check 'an extensionless VALID file is never a finding' ($msgCls -notmatch '- LICENSE') $msgCls
    Check 'NUL bytes across both parities are binary, skipped (no finding)' ($msgCls -notmatch '- blob\.bin') $msgCls
    Check 'misleading extension: NUL bytes under a .txt name are STILL binary (heuristic, not extension)' ($msgCls -notmatch '- nulbytes\.txt') $msgCls
    Check 'misleading extension: text bytes under a .png name are validated by content and pass' ($msgCls -notmatch '- textbytes\.png') $msgCls
    Check 'misleading extension: UTF-16 bytes under a .png name are STILL a text finding (content read, extension ignored)' ($msgCls -match '- fake16\.png - UTF-16 LE text') $msgCls
    Check 'ambiguous invalid bytes under a known-binary extension downgrade to binary (no false positive)' ($msgCls -notmatch '- badbytes\.png') $msgCls
    Check 'a small fully-covered project is not marked partial' ($msgCls -notmatch '(?i)PARTIAL') $msgCls
    Check 'no fixture content ever appears in the advisory' (
        $msgCls -notmatch 'BROKENMARKER' -and $msgCls -notmatch 'CP1252MARKER' -and $msgCls -notmatch 'sixteen le text') $msgCls

    # =====================================================================
    Write-Host '--- oversized files: unknown for text, still binary for binary ---' -ForegroundColor Cyan
    $hcBig = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILE_KB=1`nUTF8_MAX_FINDINGS=50`n"
    $projBig = New-Proj 'Oversized'
    Write-Utf8 (Join-Path $projBig 'big.txt') (('a' * 3000) + "`n")
    $bigBinary = New-Object System.Collections.Generic.List[byte]
    for ($bi = 0; $bi -lt 200; $bi++) { foreach ($b in (Get-BinaryBytes)) { [void]$bigBinary.Add($b) } }
    Write-Bytes (Join-Path $projBig 'big.dat') ([byte[]]$bigBinary.ToArray())
    $rBig = Fire -HookPath $hcBig.Script -Cwd $projBig -EventName 'SessionStart' -LocalAppData $hcBig.LocalAppData
    $msgBig = Get-Message $rBig.Out
    Check 'an oversized TEXT file is reported as NOT validated (unknown), never silently passed' ($msgBig -match '1 file\(s\) exceeded UTF8_MAX_FILE_KB') $msgBig
    Check 'an oversized text file is not invented as a violation' ($msgBig -notmatch '- big\.txt -') $msgBig
    Check 'an oversized BINARY file is recognized as binary from its first window (not counted unknown)' ($msgBig -notmatch '2 file\(s\) exceeded') $msgBig

    # =====================================================================
    Write-Host '--- an unreadable file is honest partial coverage, never a violation ---' -ForegroundColor Cyan
    $hcLock = New-IsolatedHookCopy
    $projLock = New-Proj 'Locked'
    Write-Utf8 (Join-Path $projLock 'ok.txt') "readable`n"
    Write-Utf8 (Join-Path $projLock 'locked.txt') "cannot be opened while held`n"
    $lockStream = [System.IO.File]::Open((Join-Path $projLock 'locked.txt'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $rLock = Fire -HookPath $hcLock.Script -Cwd $projLock -EventName 'SessionStart' -LocalAppData $hcLock.LocalAppData
    }
    finally { $lockStream.Dispose() }
    $msgLock = Get-Message $rLock.Out
    Check 'an unreadable file makes the baseline PARTIAL with the read-failure cause' (
        $msgLock -match '(?i)could not be read' -and $msgLock -match '(?i)PARTIAL') $msgLock
    Check 'an unreadable file is never reported as a violation' ($msgLock -notmatch '- locked\.txt - an invalid') $msgLock

    # =====================================================================
    Write-Host '--- reparse points: child junction pruned, junction ROOT refused ---' -ForegroundColor Cyan
    $rpTarget = Join-Path $Work ('rp-target-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $rpTarget -Force | Out-Null
    Write-Bytes (Join-Path $rpTarget 'linkedbad.txt') (Get-InvalidUtf8Bytes 'LINKEDMARKER')
    # Control first: scanning the target DIRECTLY does find the finding.
    $hcRpCtl = New-IsolatedHookCopy
    $rRpCtl = Fire -HookPath $hcRpCtl.Script -Cwd $rpTarget -EventName 'SessionStart' -LocalAppData $hcRpCtl.LocalAppData
    Check 'control: the invalid file IS found when its directory is scanned directly' ((Get-Message $rRpCtl.Out) -match '- linkedbad\.txt') (Get-Message $rRpCtl.Out)
    $projRp = New-Proj 'Reparse'
    Write-Utf8 (Join-Path $projRp 'normal.txt') "clean`n"
    $rpLink = Join-Path $projRp 'linked'
    $madeJunction = $false
    try { New-Item -ItemType Junction -Path $rpLink -Target $rpTarget -ErrorAction Stop | Out-Null; $madeJunction = $true } catch { }
    if (-not $madeJunction) {
        try { & cmd /c mklink /J "$rpLink" "$rpTarget" 2>$null | Out-Null } catch { }
        $madeJunction = (Test-Path -LiteralPath $rpLink) -and
            ((((Get-Item -LiteralPath $rpLink -Force).Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    if ($madeJunction) {
        $hcRp = New-IsolatedHookCopy
        $rRp = Fire -HookPath $hcRp.Script -Cwd $projRp -EventName 'SessionStart' -LocalAppData $hcRp.LocalAppData
        Check 'a CHILD junction is never followed: the project scan stays silent/clean' ($rRp.Exit -eq 0 -and (Get-Message $rRp.Out) -notmatch 'linkedbad') ($rRp.Out)
        # Junction as the scan ROOT: refused, partial, nothing from behind it.
        $hcRpRoot = New-IsolatedHookCopy
        $rRpRoot = Fire -HookPath $hcRpRoot.Script -Cwd $rpLink -EventName 'SessionStart' -LocalAppData $hcRpRoot.LocalAppData
        $msgRpRoot = Get-Message $rRpRoot.Out
        Check 'a junction scan ROOT is refused and marked PARTIAL naming the root' (
            $msgRpRoot -match '(?i)PARTIAL' -and $msgRpRoot -match '(?i)scan root is a junction') $msgRpRoot
        Check 'no finding comes from behind the refused junction root' ($msgRpRoot -notmatch 'linkedbad') $msgRpRoot
    }
    else {
        Write-Host '[SKIP] junction could not be created in this harness - reparse assertions skipped' -ForegroundColor Yellow
    }

    # =====================================================================
    Write-Host '--- exception registry: a valid entry is honoured, every bad entry grants NOTHING ---' -ForegroundColor Cyan
    $hcExc = New-IsolatedHookCopy
    $projExc = New-GitRepo 'ExcRepo'
    Write-Utf8 (Join-Path $projExc 'README.md') "seed`n"
    Add-Commit $projExc 'seed'
    # The changed (untracked) non-UTF-8 file every scenario below pivots on.
    Write-Bytes (Join-Path $projExc 'legacy\notes.txt') (Get-Cp1252Bytes 'EXCMARKER')
    $excRegistry = Join-Path $projExc '.utf8-encoding-exceptions.json'

    # 1. No registry at all -> the changed invalid file blocks (the pivot).
    $r = Fire -HookPath $hcExc.Script -Cwd $projExc -EventName 'Stop' -SessionId 'exc01' -LocalAppData $hcExc.LocalAppData
    Check 'without a registry the changed non-UTF-8 file blocks' ((Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'legacy/notes\.txt') $r.Out

    # 2. A valid EXACT entry is honoured -> no block, silent.
    Write-Utf8 $excRegistry (Get-ExceptionJson -Path 'legacy/notes.txt')
    $r = Fire -HookPath $hcExc.Script -Cwd $projExc -EventName 'Stop' -SessionId 'exc02' -LocalAppData $hcExc.LocalAppData
    Check 'a valid exact-path exception is honoured (no block, silent)' ($r.Exit -eq 0 -and -not (Test-StopBlocks $r.Out) -and $r.Out -eq '') $r.Out

    # 3. A valid SINGLE NARROW GLOB is honoured too.
    Write-Utf8 $excRegistry (Get-ExceptionJson -Path 'legacy/*.txt')
    $r = Fire -HookPath $hcExc.Script -Cwd $projExc -EventName 'Stop' -SessionId 'exc03' -LocalAppData $hcExc.LocalAppData
    Check 'a valid single narrow glob exception is honoured' (-not (Test-StopBlocks $r.Out)) $r.Out

    # 4..10: every malformed/overbroad shape is REJECTED and the file still blocks.
    $badRegistries = @(
        @{ Name = 'a broad **/* pattern';            Json = (Get-ExceptionJson -Path '**/*') },
        @{ Name = 'a bare * pattern';                Json = (Get-ExceptionJson -Path '*') },
        @{ Name = 'a missing reason';                Json = (Get-ExceptionJson -Path 'legacy/notes.txt' -Reason '') },
        @{ Name = 'a placeholder reason (todo)';     Json = (Get-ExceptionJson -Path 'legacy/notes.txt' -Reason 'todo') },
        @{ Name = 'an unknown encoding (klingon)';   Json = (Get-ExceptionJson -Path 'legacy/notes.txt' -Encoding 'klingon') },
        @{ Name = 'the forbidden binary encoding';   Json = (Get-ExceptionJson -Path 'legacy/notes.txt' -Encoding 'binary') },
        @{ Name = 'an absolute path';                Json = (Get-ExceptionJson -Path 'C:/temp/notes.txt') },
        @{ Name = 'a path escaping the project';     Json = (Get-ExceptionJson -Path '../legacy/notes.txt') }
    )
    $excIndex = 3
    foreach ($bad in $badRegistries) {
        $excIndex++
        Write-Utf8 $excRegistry $bad.Json
        $r = Fire -HookPath $hcExc.Script -Cwd $projExc -EventName 'Stop' -SessionId ('exc{0:00}' -f $excIndex) -LocalAppData $hcExc.LocalAppData
        Check ($bad.Name + ' is rejected and grants NO exception (still blocks)') (
            (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'legacy/notes\.txt') $r.Out
    }
    Check 'a rejected entry is explained in the block message' ((Get-Message $r.Out) -match '(?i)rejected') (Get-Message $r.Out)

    # 11. The registry file itself must be valid UTF-8 - a corrupt registry
    #     rejects ALL exceptions and the pivot file still blocks.
    Write-Bytes $excRegistry (Get-InvalidUtf8Bytes 'CORRUPTREGISTRY')
    $r = Fire -HookPath $hcExc.Script -Cwd $projExc -EventName 'Stop' -SessionId 'exc99' -LocalAppData $hcExc.LocalAppData
    Check 'a registry that is not itself valid UTF-8 rejects ALL exceptions (still blocks)' (
        (Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'legacy/notes\.txt' -and (Get-Message $r.Out) -match '(?i)not itself valid UTF-8') $r.Out
    Remove-Item -LiteralPath $excRegistry -Force
