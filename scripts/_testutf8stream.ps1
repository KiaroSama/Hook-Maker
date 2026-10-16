# Public lifecycle/native seams, plus the raw Git transport boundary. Shared
# fixtures and streams avoid a child/repository for each sequence or bad frame.
Write-Host '--- large catalog: full validation beyond the old ceiling ---' -ForegroundColor Cyan
$streamCopy = New-IsolatedHookCopy
$streamProject = New-Proj 'StreamCatalog'
$catalogPath = Join-Path $streamProject 'catalog.json'
$catalogText = '{"catalog":"' + ('a' * (3353196 - 14)) + '"}'
Write-Utf8 $catalogPath $catalogText
Check 'catalog fixture has the reported exact byte size and valid JSON' (
    (Get-Item -LiteralPath $catalogPath).Length -eq 3353196 -and
    ($catalogText | ConvertFrom-Json).catalog.Length -eq (3353196 - 14))
$r = Fire -HookPath $streamCopy.Script -Cwd $streamProject -EventName 'SessionStart' -LocalAppData $streamCopy.LocalAppData
Check 'default full validation accepts a 3353196-byte catalog without an exception or bypass' (
    $r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ($r.Out + $r.Err)
$tail = [System.IO.File]::Open($catalogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
try { $null = $tail.Seek(-1, [System.IO.SeekOrigin]::End); $tail.WriteByte(0xFF) }
finally { $tail.Dispose() }
$r = Fire -HookPath $streamCopy.Script -Cwd $streamProject -EventName 'SessionStart' -SessionId 'bad-tail' -LocalAppData $streamCopy.LocalAppData
Check 'an invalid last byte beyond the former ceiling is rejected as invalid, not unknown' (
    $r.Exit -eq 0 -and (Get-Message $r.Out) -match 'catalog\.json - an invalid UTF-8' -and
    (Get-Message $r.Out) -notmatch 'exceeded UTF8_MAX_FILE_KB') ($r.Out + $r.Err)

if (-not $StreamOnly) {
    . (Join-Path $PSScriptRoot '_testutf8transport.ps1')
    $transportOut = Join-Path $Work 'transport51.out'
    $transportErr = Join-Path $Work 'transport51.err'
    $transportHost = Start-BoundedProcess -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ScriptRoot 'Test-Utf8EncodingCheck.ps1'), '-TransportOnly') -RedirectStandardOutput $transportOut -RedirectStandardError $transportErr -TimeoutMs 30000
    $transportText = [IO.File]::ReadAllText($transportOut, [Text.Encoding]::UTF8)
    if ($transportHost.ExitCode -ne 0 -or $transportText -notmatch 'Passed: [1-9][0-9]*  Failed: 0') { Write-Host ('Transport51 exit=' + $transportHost.ExitCode + ' diagnostic: ' + [IO.File]::ReadAllText($transportErr,[Text.Encoding]::UTF8) + $transportText) }
    Check 'WindowsPowerShell5.1 executes every transport/resource boundary assertion' ($transportHost.ExitCode -eq 0 -and $transportText -match 'Passed: [1-9][0-9]*  Failed: 0') ([IO.File]::ReadAllText($transportErr, [Text.Encoding]::UTF8)+$transportText)
    # Whole public native scan: a large blob is followed by a smaller invalid
    # blob, exercising frame alignment without manufacturing Git output.
    $repo = New-PushableRepo 'StreamPush'
    Write-Utf8 (Join-Path $repo 'base.txt') "seed`n"
    Add-Commit $repo 'baseline'; Push-Repo $repo
    Write-Utf8 (Join-Path $repo 'catalog.json') $catalogText
    Add-Commit $repo 'large catalog'
    $refLine = Get-RefUpdateLine -Repo $repo
    $r = FireGitPrePush -Cwd $repo -StdinText $refLine -HookPath $streamCopy.Script -LocalAppData $streamCopy.LocalAppData
    Check 'native outgoing 3353196-byte catalog passes default complete validation' ($r.Exit -eq 0 -and $r.Err -eq '') ($r.Out+$r.Err)
    $capCopy = New-IsolatedHookCopy -EnvContent "UTF8_MAX_FILE_KB=1024`n"
    $r = FireGitPrePush -Cwd $repo -StdinText $refLine -HookPath $capCopy.Script -LocalAppData $capCopy.LocalAppData
    Check 'explicit retained1024KiB cap still fails closed for large outgoing text' ($r.Exit -eq 1 -and $r.Err -match 'UTF8_MAX_FILE_KB') $r.Err
    Write-Bytes (Join-Path $repo 'zzz.txt') (Get-InvalidUtf8Bytes)
    Add-Commit $repo 'invalid following blob'
    $r = FireGitPrePush -Cwd $repo -StdinText (Get-RefUpdateLine -Repo $repo) -HookPath $streamCopy.Script -LocalAppData $streamCopy.LocalAppData
    Check 'invalid blob after large valid blob is not swallowed by batch framing' ($r.Exit -eq 1 -and $r.Err -match 'zzz\.txt' -and $r.Err -notmatch 'could not be read') $r.Err
    $tail = [System.IO.File]::Open((Join-Path $repo 'catalog.json'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
    try { $null=$tail.Seek(-1,[System.IO.SeekOrigin]::End); $tail.WriteByte(0xFF) } finally { $tail.Dispose() }
    Add-Commit $repo 'invalid final byte'
    $r = FireGitPrePush -Cwd $repo -StdinText (Get-RefUpdateLine -Repo $repo) -HookPath $streamCopy.Script -LocalAppData $streamCopy.LocalAppData
    Check 'native invalid final byte beyond former ceiling blocks as invalid' ($r.Exit -eq 1 -and $r.Err -match 'catalog\.json - an invalid UTF-8') $r.Err
    foreach ($malformedRef in @('refs/heads/main', ((Get-RefUpdateLine -Repo $repo).Trim() + ' extra'))) {
        $r = FireGitPrePush -Cwd $repo -StdinText ($malformedRef + "`n") -HookPath $streamCopy.Script -LocalAppData $streamCopy.LocalAppData
        Check 'malformed native ref input refuses required coverage' ($r.Exit -eq 1 -and $r.Err -match 'malformed') $r.Err
    }
    $script:HookDeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
    $tipBlob = ((& git -C $repo rev-parse 'HEAD:catalog.json') | Out-String).Trim()
    $read = Get-GitBlobBytes -Cwd $repo -BlobSha $tipBlob -MaxFullBytes 64MB -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1))
    Check 'staged reader honors exhausted caller scan deadline without a fresh20s budget' $read.Failed
    # Commit-delta needs a baseline; staged invalid content is independently
    # visible even with a clean working tree and no baseline.
    Write-Bytes (Join-Path $repo 'staged.json') ([System.Text.Encoding]::UTF8.GetBytes($catalogText) + [byte[]]@(0xC3))
    & git -C $repo add staged.json
    Write-Utf8 (Join-Path $repo 'staged.json') $catalogText
    $r = Fire -HookPath $streamCopy.Script -Cwd $repo -EventName 'Stop' -SessionId 'stream-staged' -LocalAppData $streamCopy.LocalAppData
    Check 'large staged invalid tail blocks even after working tree reverted valid' ((Test-StopBlocks $r.Out) -and (Get-Message $r.Out) -match 'staged.json \(staged content\)') ($r.Out+$r.Err)
}
