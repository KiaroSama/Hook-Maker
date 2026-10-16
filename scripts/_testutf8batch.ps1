# One real object database and one import process, not 1358 git subprocesses.
. (Join-Path $HooksRoot 'Utf8-Encoding-Check/_classification.ps1')
. (Join-Path $HooksRoot 'Utf8-Encoding-Check/_streamvalidation.ps1')
. (Join-Path $HooksRoot 'Utf8-Encoding-Check/_detection.ps1')
$repo=New-GitRepo 'LargeBatch'
$inputPath=Join-Path $Work 'batch-import.txt'
$writer=[IO.StreamWriter]::new($inputPath,$false,[Text.UTF8Encoding]::new($false))
try {
    for($i=1;$i-le1358;$i++) {
        $body=if($i-eq1358){'{"catalog":"'+('a'*(5929288-14))+'"}'}else{('{"id":'+$i+',"text":"'+('a'*8192)+'"}')}
        $writer.Write("blob`nmark :$i`ndata $([Text.Encoding]::UTF8.GetByteCount($body))`n$body`n")
    }
    $writer.Write("commit refs/heads/main`ncommitter fixture <fixture@example.invalid> 1700000000 +0000`ndata 7`nfixture`n")
    for($i=1;$i-le2117;$i++){$mark=1+(($i-1)%1358);$writer.Write("M 100644 :$mark catalog-$i.json`n")}
    $writer.Write("`ndone`n")
} finally {$writer.Dispose()}
$import=Start-BoundedProcess -FilePath git -ArgumentList @('-C',$repo,'fast-import','--quiet') -RedirectStandardInput $inputPath -RedirectStandardOutput (Join-Path $Work 'import.out') -RedirectStandardError (Join-Path $Work 'import.err') -TimeoutMs 30000
if($import.ExitCode-ne0){throw 'Large batch fixture import failed'}
$ids=@(git -C $repo ls-tree -r HEAD | ForEach-Object{($_ -split '\s+')[2]} | Select-Object -Unique)
if($ids.Count-ne1358){throw 'Large fixture distinct blob count mismatch'}
$script:HookDeadlineUtc=[DateTime]::UtcNow.AddSeconds(30)
$clock=[Diagnostics.Stopwatch]::StartNew()
$reads=Read-GitBlobsBatch -Cwd $repo -BlobShas ($ids+$ids[0..15]) -MaxFullBytes 8MB
$failed=@($ids|Where-Object{$reads[$_].Failed-or$reads[$_].Class-ne'utf8'})
Check '1358 blobs /2117 paths and repeated IDs fully validate inside unchanged20s batch budget' ($failed.Count-eq0-and$clock.Elapsed.TotalSeconds-lt22) ('failed='+$failed.Count+' elapsedSeconds='+[Math]::Round($clock.Elapsed.TotalSeconds,2))
Write-Host ('Batch elapsedSeconds='+[Math]::Round($clock.Elapsed.TotalSeconds,2)+' uniqueBlobs='+$ids.Count+' failed='+$failed.Count)
if (-not $BatchOnly) {
    $batch51Out=Join-Path $Work 'batch51.out'; $batch51Err=Join-Path $Work 'batch51.err'
    $batch51=Start-BoundedProcess -FilePath powershell.exe -ArgumentList @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Test-Utf8EncodingCheck.ps1'),'-BatchOnly') -RedirectStandardOutput $batch51Out -RedirectStandardError $batch51Err -TimeoutMs 40000
    $batch51Text=[IO.File]::ReadAllText($batch51Out,[Text.Encoding]::UTF8); $batch51Error=[IO.File]::ReadAllText($batch51Err,[Text.Encoding]::UTF8)
    if($batch51.ExitCode-ne0-or$batch51Text-notmatch'Passed: 1  Failed: 0'-or$batch51Error-ne''){Write-Host ('Batch51 exit='+$batch51.ExitCode+' diagnostic: '+$batch51Error+$batch51Text)}
    Check '5.1 validates realistic1358blob batch within unchanged production budget' ($batch51.ExitCode-eq0-and$batch51Text-match'Passed: 1  Failed: 0'-and$batch51Error-eq'')
    $hc=New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILE_KB=8192`n"
    $r=FireGitPrePush -Cwd $repo -StdinText (Get-RefUpdateLine $repo -RemoteSha ('0'*40)) -HookPath $hc.Script -LocalAppData $hc.LocalAppData
    Check 'real native outgoing range validates all2117 paths /1358 blobs without exception' ($r.Exit-eq0-and$r.Err-eq'') $r.Err
    $missing='f'*40
    $script:HookDeadlineUtc=[DateTime]::UtcNow.AddSeconds(25)
    $bad=Read-GitBlobsBatch -Cwd $repo -BlobShas @($missing) -MaxFullBytes 8MB
    Check 'real missing Git object has exact fail-closed diagnostic' ($bad[$missing].Failed-and$bad[$missing].Failure-eq'missing-object')
    $script:HookDeadlineUtc=[DateTime]::UtcNow.AddSeconds(25)
    $expired=Read-GitBlobsBatch -Cwd $repo -BlobShas @($ids[0]) -MaxFullBytes 8MB -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1))
    Check 'expired batch is deadline, not an encoding violation or clean result' ($expired[$ids[0]].Failed-and$expired[$ids[0]].Failure-eq'deadline')
    . (Join-Path $PSScriptRoot '_testutf8batchfaults.ps1')
    . (Join-Path $PSScriptRoot '_testutf8batchprocess.ps1')
}
