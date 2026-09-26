# Test-Utf8EncodingCheck.ps1 scenario block: the NATIVE PRE-PUSH GATE.
# Real throwaway repos with real bare remotes; the hook is invoked EXACTLY as
# the managed pre-push wrapper invokes each stage (powershell.exe 5.1,
# -File <script> -GitPrePush, stdin redirected from a file of git's raw
# ref-update lines, cwd = the repository). Covers: clean pushes, new-branch
# ranges, blobs deleted later in the outgoing range, multiple refs in one
# stdin, deletion refs, binary blobs, documented exceptions, fail-closed
# unresolvable ranges and ceiling overflows, the no-state/no-mutation
# guarantees, the pwsh host, and the red-proof stub + valid-bytes controls.
#
# Dot-sourced by Test-Utf8EncodingCheck.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- pre-push: a clean outgoing range passes silently ---' -ForegroundColor Cyan
    $hcPp = New-IsolatedHookCopy
    $ppValid = New-PushableRepo 'PpValid'
    Write-Utf8 (Join-Path $ppValid 'base.txt') "seed`n"
    Add-Commit $ppValid 'baseline'
    Push-Repo $ppValid
    Write-Utf8 (Join-Path $ppValid 'ok.txt') "a perfectly valid outgoing change`n"
    Add-Commit $ppValid 'clean outgoing commit'
    $r = FireGitPrePush -Cwd $ppValid -StdinText (Get-RefUpdateLine -Repo $ppValid) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'a valid outgoing range passes (exit 0, quiet)' ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ($r.Out + $r.Err)
    $r = FireGitPrePush -Cwd $ppValid -StdinText '' -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'empty pre-push stdin (nothing pushed) passes' ($r.Exit -eq 0) $r.Err

    # =====================================================================
    Write-Host '--- pre-push: new-branch outgoing invalid text blocks; twin + stub prove it ---' -ForegroundColor Cyan
    $ppNew = New-PushableRepo 'PpNewBranch'
    Write-Utf8 (Join-Path $ppNew 'base.txt') "seed`n"
    Add-Commit $ppNew 'baseline'
    Push-Repo $ppNew
    & git -C $ppNew checkout -q -b feature
    Write-Bytes (Join-Path $ppNew 'feature.txt') (Get-InvalidUtf8Bytes 'PPNEWMARKER')
    Add-Commit $ppNew 'feature work with invalid utf-8'
    $stdinNew = Get-RefUpdateLine -Repo $ppNew -Branch 'feature' -RemoteSha ('0' * 40)
    $sigPpBefore = Get-TreeSignature $ppNew
    $r = FireGitPrePush -Cwd $ppNew -StdinText $stdinNew -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    $sigPpAfter = Get-TreeSignature $ppNew
    Check 'new-branch push (remote sha all-zero) with an invalid text blob blocks (exit 1)' ($r.Exit -eq 1) ($r.Out + $r.Err)
    Check 'the block names the file and classification on stderr' (
        $r.Err -match 'UTF8 ENCODING CHECK' -and $r.Err -match 'feature\.txt' -and $r.Err -match 'invalid UTF-8') $r.Err
    Check 'the pre-push block never leaks blob contents' ($r.Err -notmatch 'PPNEWMARKER') $r.Err
    Check 'a blocked pre-push mutates nothing in the repository' ($sigPpBefore -eq $sigPpAfter)
    # NEGATIVE CONTROL twin: identical flow, VALID bytes -> passes.
    $ppNewCtl = New-PushableRepo 'PpNewBranchControl'
    Write-Utf8 (Join-Path $ppNewCtl 'base.txt') "seed`n"
    Add-Commit $ppNewCtl 'baseline'
    Push-Repo $ppNewCtl
    & git -C $ppNewCtl checkout -q -b feature
    Write-Utf8 (Join-Path $ppNewCtl 'feature.txt') "the same new-branch flow, valid UTF-8`n"
    Add-Commit $ppNewCtl 'feature work, valid'
    $r = FireGitPrePush -Cwd $ppNewCtl -StdinText (Get-RefUpdateLine -Repo $ppNewCtl -Branch 'feature' -RemoteSha ('0' * 40)) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'negative control: the SAME new-branch flow with valid bytes passes (block depends on the bytes)' ($r.Exit -eq 0) $r.Err
    # STUB PROOF: the exit-0 stub does not block the invalid push, so the
    # exit-1 assertions above are load-bearing.
    $stubPp = New-StubHook
    $r = FireGitPrePush -Cwd $ppNew -StdinText $stdinNew -HookPath $stubPp.Script -LocalAppData $stubPp.LocalAppData
    Check 'stub proof: an exit-0 stub lets the invalid push through (test is load-bearing)' ($r.Exit -eq 0 -and $r.Err -eq '') $r.Err

    # =====================================================================
    Write-Host '--- pre-push: invalid committed then DELETED in a later outgoing commit still blocks ---' -ForegroundColor Cyan
    $ppDel = New-PushableRepo 'PpDeletedLater'
    Write-Utf8 (Join-Path $ppDel 'base.txt') "seed`n"
    Add-Commit $ppDel 'baseline'
    Push-Repo $ppDel
    Write-Bytes (Join-Path $ppDel 'temp.txt') (Get-InvalidUtf8Bytes 'PPDELMARKER')
    Add-Commit $ppDel 'introduce invalid utf-8'
    & git -C $ppDel rm -q temp.txt 2>$null | Out-Null
    Add-Commit $ppDel 'delete it again (both commits still outgoing)'
    Check 'fixture sanity: the working tree no longer holds the file' (-not (Test-Path (Join-Path $ppDel 'temp.txt')))
    $r = FireGitPrePush -Cwd $ppDel -StdinText (Get-RefUpdateLine -Repo $ppDel) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'an invalid blob introduced and deleted within the outgoing range still blocks' (
        $r.Exit -eq 1 -and $r.Err -match 'temp\.txt') $r.Err

    # =====================================================================
    Write-Host '--- pre-push: multiple refs in one stdin; deletion refs scan nothing ---' -ForegroundColor Cyan
    $ppMulti = New-PushableRepo 'PpMultiRef'
    Write-Utf8 (Join-Path $ppMulti 'base.txt') "seed`n"
    Add-Commit $ppMulti 'baseline'
    Push-Repo $ppMulti
    & git -C $ppMulti checkout -q -b branchA
    Write-Bytes (Join-Path $ppMulti 'a.txt') (Get-InvalidUtf8Bytes 'MULTIAMARKER')
    Add-Commit $ppMulti 'branchA invalid'
    $stdinA = Get-RefUpdateLine -Repo $ppMulti -Branch 'branchA' -RemoteSha ('0' * 40)
    & git -C $ppMulti checkout -q main
    & git -C $ppMulti checkout -q -b branchB
    Write-Bytes (Join-Path $ppMulti 'b.txt') (Get-Utf16LeBytes 'branchB utf-16 payload')
    Add-Commit $ppMulti 'branchB utf-16'
    $stdinB = Get-RefUpdateLine -Repo $ppMulti -Branch 'branchB' -RemoteSha ('0' * 40)
    $r = FireGitPrePush -Cwd $ppMulti -StdinText ($stdinA + $stdinB) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'multiple refs in ONE stdin: both refs'' findings are reported' (
        $r.Exit -eq 1 -and $r.Err -match 'a\.txt' -and $r.Err -match 'b\.txt' -and $r.Err -match 'UTF-16 LE') $r.Err
    $ppDelRef = New-PushableRepo 'PpDeletionRef'
    Write-Utf8 (Join-Path $ppDelRef 'base.txt') "seed`n"
    Add-Commit $ppDelRef 'baseline'
    Push-Repo $ppDelRef
    $headSha = ((& git -C $ppDelRef rev-parse HEAD) | Out-String).Trim()
    $r = FireGitPrePush -Cwd $ppDelRef -StdinText ('refs/heads/gone ' + ('0' * 40) + ' refs/heads/gone ' + $headSha + "`n") -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'a deletion ref (local sha all-zero) pushes nothing and passes' ($r.Exit -eq 0) $r.Err

    # =====================================================================
    Write-Host '--- pre-push: binary blobs never false-positive ---' -ForegroundColor Cyan
    $ppBin = New-PushableRepo 'PpBinary'
    Write-Utf8 (Join-Path $ppBin 'base.txt') "seed`n"
    Add-Commit $ppBin 'baseline'
    Push-Repo $ppBin
    Write-Bytes (Join-Path $ppBin 'image.bin') (Get-BinaryBytes)
    Write-Bytes (Join-Path $ppBin 'photo.png') (Get-InvalidUtf8Bytes 'PNGMARKER')
    Add-Commit $ppBin 'binary payloads'
    $r = FireGitPrePush -Cwd $ppBin -StdinText (Get-RefUpdateLine -Repo $ppBin) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'binary-with-NUL and binary-extension blobs pass the pre-push gate (no false positive)' ($r.Exit -eq 0) $r.Err

    # =====================================================================
    Write-Host '--- pre-push: a documented exception passes; its absence blocks (twin) ---' -ForegroundColor Cyan
    $ppExc = New-PushableRepo 'PpException'
    Write-Utf8 (Join-Path $ppExc 'base.txt') "seed`n"
    Add-Commit $ppExc 'baseline'
    Push-Repo $ppExc
    Write-Bytes (Join-Path $ppExc 'legacy\report.txt') (Get-Utf16LeBytes 'legacy utf-16 report')
    Write-Utf8 (Join-Path $ppExc '.utf8-encoding-exceptions.json') (Get-ExceptionJson -Path 'legacy/report.txt' -Encoding 'utf-16le' -Reason 'legacy reporting tool emits UTF-16; kept byte-identical')
    Add-Commit $ppExc 'utf-16 file plus its documented exception'
    $r = FireGitPrePush -Cwd $ppExc -StdinText (Get-RefUpdateLine -Repo $ppExc) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'a documented exception lets the covered non-UTF-8 blob push (exit 0)' ($r.Exit -eq 0) $r.Err
    $ppExcCtl = New-PushableRepo 'PpExceptionControl'
    Write-Utf8 (Join-Path $ppExcCtl 'base.txt') "seed`n"
    Add-Commit $ppExcCtl 'baseline'
    Push-Repo $ppExcCtl
    Write-Bytes (Join-Path $ppExcCtl 'legacy\report.txt') (Get-Utf16LeBytes 'legacy utf-16 report')
    Add-Commit $ppExcCtl 'the same utf-16 file WITHOUT an exception'
    $r = FireGitPrePush -Cwd $ppExcCtl -StdinText (Get-RefUpdateLine -Repo $ppExcCtl) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'twin without the exception blocks (the exception was load-bearing)' (
        $r.Exit -eq 1 -and $r.Err -match 'legacy/report\.txt' -and $r.Err -match 'UTF-16 LE') $r.Err

    # =====================================================================
    Write-Host '--- pre-push: an unknown remote sha widens the scan, never skips it ---' -ForegroundColor Cyan
    # A remote sha git does not know cannot narrow the range, so everything
    # the local tip holds beyond the remote-tracking refs is scanned: a clean
    # change passes, an invalid one still blocks.
    $ppUnres = New-PushableRepo 'PpUnresolvable'
    Write-Utf8 (Join-Path $ppUnres 'base.txt') "seed`n"
    Add-Commit $ppUnres 'baseline'
    Push-Repo $ppUnres
    Write-Utf8 (Join-Path $ppUnres 'clean.txt') "clean outgoing change`n"
    Add-Commit $ppUnres 'clean change'
    $fakeRemote = 'deadbeef' + ('0' * 32)
    $r = FireGitPrePush -Cwd $ppUnres -StdinText (Get-RefUpdateLine -Repo $ppUnres -RemoteSha $fakeRemote) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'an unknown remote sha with a clean outgoing change passes' ($r.Exit -eq 0) $r.Err
    Write-Bytes (Join-Path $ppUnres 'bad.txt') (Get-InvalidUtf8Bytes 'PPUNRESMARKER')
    Add-Commit $ppUnres 'invalid change'
    $r = FireGitPrePush -Cwd $ppUnres -StdinText (Get-RefUpdateLine -Repo $ppUnres -RemoteSha $fakeRemote) -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData
    Check 'an unknown remote sha still blocks an invalid outgoing blob' ($r.Exit -eq 1 -and $r.Err -match 'bad\.txt') $r.Err

    # =====================================================================
    Write-Host '--- pre-push: no file-count ceiling; a rewrite of published content scans nothing ---' -ForegroundColor Cyan
    # UTF8_MAX_FILES=1 once refused any push of two or more blobs. The gate now
    # reads every sent blob, so the setting must not limit it: three valid
    # blobs pass, and an invalid THIRD one still blocks (the scan went past 1).
    $hcPpCap = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILES=1`n"
    $ppCap = New-PushableRepo 'PpCeiling'
    Write-Utf8 (Join-Path $ppCap 'base.txt') "seed`n"
    Add-Commit $ppCap 'baseline'
    Push-Repo $ppCap
    Write-Utf8 (Join-Path $ppCap 'f1.txt') "valid one`n"
    Write-Utf8 (Join-Path $ppCap 'f2.txt') "valid two`n"
    Write-Utf8 (Join-Path $ppCap 'f3.txt') "valid three`n"
    Add-Commit $ppCap 'three blobs, UTF8_MAX_FILES=1'
    $r = FireGitPrePush -Cwd $ppCap -StdinText (Get-RefUpdateLine -Repo $ppCap) -HookPath $hcPpCap.Script -LocalAppData $hcPpCap.LocalAppData
    Check 'UTF8_MAX_FILES does not cap the pre-push gate (three valid blobs pass)' ($r.Exit -eq 0) $r.Err
    Write-Bytes (Join-Path $ppCap 'f3.txt') (Get-InvalidUtf8Bytes 'PPCAPMARKER')
    Write-Utf8 (Join-Path $ppCap 'f4.txt') "valid four`n"
    Add-Commit $ppCap 'invalid blob among several'
    $r = FireGitPrePush -Cwd $ppCap -StdinText (Get-RefUpdateLine -Repo $ppCap) -HookPath $hcPpCap.Script -LocalAppData $hcPpCap.LocalAppData
    Check 'an invalid blob beyond the old ceiling still blocks' ($r.Exit -eq 1 -and $r.Err -match 'f3\.txt' -and $r.Err -notmatch 'UTF8_MAX_FILES') $r.Err
    # History rewrite: legacy invalid content already published, then only the
    # commit is rewritten (new sha, same tree). Nothing new is sent, so the
    # legacy blob is not re-judged; the untouched gate above proves it would be.
    $ppRewrite = New-PushableRepo 'PpRewrite'
    Write-Bytes (Join-Path $ppRewrite 'legacy.txt') (Get-InvalidUtf8Bytes 'PPREWRITEMARKER')
    Add-Commit $ppRewrite 'legacy content'
    Push-Repo $ppRewrite
    $publishedSha = ((& git -C $ppRewrite rev-parse HEAD) | Out-String).Trim()
    & git -C $ppRewrite commit -q --amend -m 'legacy content, rewritten metadata' 2>$null | Out-Null
    $r = FireGitPrePush -Cwd $ppRewrite -StdinText (Get-RefUpdateLine -Repo $ppRewrite -RemoteSha $publishedSha) -HookPath $hcPpCap.Script -LocalAppData $hcPpCap.LocalAppData
    Check 'a rewrite that sends no new blob passes, even over published legacy content' ($r.Exit -eq 0) $r.Err
    # Oversized TEXT blob: cannot be fully validated -> fail closed; the same
    # size of BINARY bytes is recognized from its window and passes.
    $hcPpBig = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILE_KB=1`n"
    $ppBigTxt = New-PushableRepo 'PpOversizeText'
    Write-Utf8 (Join-Path $ppBigTxt 'base.txt') "seed`n"
    Add-Commit $ppBigTxt 'baseline'
    Push-Repo $ppBigTxt
    Write-Utf8 (Join-Path $ppBigTxt 'big.txt') (('a' * 3000) + "`n")
    Add-Commit $ppBigTxt 'oversized text blob'
    $r = FireGitPrePush -Cwd $ppBigTxt -StdinText (Get-RefUpdateLine -Repo $ppBigTxt) -HookPath $hcPpBig.Script -LocalAppData $hcPpBig.LocalAppData
    Check 'an oversized outgoing TEXT blob fails closed (exit 1, names the ceiling)' (
        $r.Exit -eq 1 -and $r.Err -match 'UTF8_MAX_FILE_KB' -and $r.Err -match 'big\.txt') $r.Err
    $ppBigBin = New-PushableRepo 'PpOversizeBinary'
    Write-Utf8 (Join-Path $ppBigBin 'base.txt') "seed`n"
    Add-Commit $ppBigBin 'baseline'
    Push-Repo $ppBigBin
    $bigBinBytes = New-Object System.Collections.Generic.List[byte]
    for ($pbi = 0; $pbi -lt 200; $pbi++) { foreach ($b in (Get-BinaryBytes)) { [void]$bigBinBytes.Add($b) } }
    Write-Bytes (Join-Path $ppBigBin 'big.dat') ([byte[]]$bigBinBytes.ToArray())
    Add-Commit $ppBigBin 'oversized binary blob'
    $r = FireGitPrePush -Cwd $ppBigBin -StdinText (Get-RefUpdateLine -Repo $ppBigBin) -HookPath $hcPpBig.Script -LocalAppData $hcPpBig.LocalAppData
    Check 'an oversized outgoing BINARY blob is recognized from its window and passes' ($r.Exit -eq 0) $r.Err

    # =====================================================================
    Write-Host '--- pre-push: no state, no temp residue, and the pwsh host agrees ---' -ForegroundColor Cyan
    # The pre-push mode must write NO state: every scenario above shares
    # $hcPp, whose isolated LOCALAPPDATA must still hold nothing.
    $ppState = @(Get-ChildItem -LiteralPath (Join-Path $hcPp.LocalAppData 'HookMaker\state') -ErrorAction SilentlyContinue)
    Check 'the pre-push mode wrote no local state at all' ($ppState.Count -eq 0) (($ppState | ForEach-Object { $_.Name }) -join ', ')
    # The suite's own workspace ($Work) legitimately matches 'hookmaker-utf8*';
    # anything ELSE with that prefix would be residue the hook itself created.
    $workLeaf = Split-Path -Leaf $Work
    $hookTempFiles = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'hookmaker-utf8*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $workLeaf })
    Check 'the hook left no temp files of its own behind' ($hookTempFiles.Count -eq 0) (($hookTempFiles | ForEach-Object { $_.Name }) -join ', ')
    $r = FireGitPrePush -Cwd $ppNew -StdinText $stdinNew -HookPath $hcPp.Script -LocalAppData $hcPp.LocalAppData -Exe 'pwsh'
    Check 'pwsh host: the same invalid new-branch push still blocks' ($r.Exit -eq 1 -and $r.Err -match 'feature\.txt') $r.Err
