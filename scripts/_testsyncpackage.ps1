# Dot-sourced by Test-Engine.ps1; both projects are owned fixtures.
$src = New-Project 'Source with spaces'
$dst = New-Project 'Destination with spaces'
$srcMemory = Join-Path $src '.ai'
$dstSync = Join-Path $dst '.ai\.cross-project-sync'
$cfg = Join-Path $Work 'cfg-source-only.json'
$route = New-Route 'source-only' (New-Endpoint 'Src' $src) (New-Endpoint 'Dst' $dst)
Write-Config -Path $cfg -Routes @($route) -Extensions @('.md', '.txt')
$utf8 = [Text.UTF8Encoding]::new($false)
$unicodeName = 'LESSON [' + [char]0x06cc + '].md'
$eligible = Join-Path $srcMemory $unicodeName
[IO.File]::WriteAllText($eligible, 'SOURCE-BYTES-NOT-IN-NOTICE', $utf8)
$unchanged = Join-Path $srcMemory 'UNCHANGED.md'
[IO.File]::WriteAllText($unchanged, 'baseline', $utf8)
$private = @('secrets.md', '.ignoreme', 'explain-AI.md', 'token_notes.md', '.cross-project-sync\old.md', 'logs\log.md', 'private\anything.md', 'notes.txt')
foreach ($relative in $private) {
    $file = Join-Path $srcMemory $relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $file))
    [IO.File]::WriteAllText($file, 'private fixture', $utf8)
}
$outside = New-Project 'Outside source boundary'
[IO.File]::WriteAllText((Join-Path $outside '.ai\EXTERNAL.md'), 'external fixture', $utf8)
$link = Join-Path $srcMemory 'external-link'
New-Item -ItemType Junction -Path $link -Target (Join-Path $outside '.ai') -ErrorAction Stop | Out-Null
try {
    $result = Fire -Cwd $dst -Config $cfg -SessionId 'migration'
    $notice = Get-SyncNotice $result.Out
    Check 'source review names Unicode and brackets without changing the path' ($notice.Contains('"' + $eligible + '"')) $notice
    Check 'source review does not disclose protected paths, link targets or file contents' (-not ($notice -match 'secrets\.md|\.ignoreme|explain-AI\.md|token_notes\.md|old\.md|log\.md|anything\.md|notes\.txt|EXTERNAL\.md|SOURCE-BYTES')) $notice
    Check 'source review instructs destination topic-first, router-last and read-only use' ($notice -match 'memory topic files first, then memory\.md' -and $notice -match 'Never copy a file or write to the source') $notice
    Check 'notice left the source file byte-for-byte unchanged' ([IO.File]::ReadAllText($eligible, $utf8) -ceq 'SOURCE-BYTES-NOT-IN-NOTICE')

    $stateFile = Get-ChildItem -LiteralPath (Join-Path $dstSync 'state') -Filter '*.json' | Select-Object -First 1
    $state = Get-Content -LiteralPath $stateFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    $oldCmd = Get-SyncAckCommand $result.Out
    $inbox = Join-Path $dstSync 'inbox\old-route\old-generation'
    [void][IO.Directory]::CreateDirectory($inbox)
    $legacyCopy = Join-Path $inbox 'fake.md'
    [IO.File]::WriteAllText($legacyCopy, 'legacy payload', $utf8)
    $state.version = 2
    $state.lastAppliedFiles = @($state.pending.sourceFiles | Where-Object path -EQ 'UNCHANGED.md')
    $state.pending = [pscustomobject]@{ packageRoot = $inbox; manifestPath = (Join-Path $inbox 'old-manifest.json'); filesRoot = $outside; sourceContentFingerprint = ('a' * 64) }
    $legacyStatePath = $stateFile.FullName -replace '\.v3\.json$', '.json'
    [IO.File]::Delete($stateFile.FullName)
    $legacyBytes = $state | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($legacyStatePath, $legacyBytes, $utf8)
    $oldAck = Run-Acknowledgement -Command $oldCmd
    Check 'legacy pending acknowledgement asks for a new review' ($oldAck.Exit -ne 0 -and $oldAck.Error -match 'Legacy review') $oldAck.Error
    $migrated = Fire -Cwd $dst -Config $cfg -SessionId 'migration'
    $notice = Get-SyncNotice $migrated.Out
    Check 'legacy pending is replaced even if it used the same session' ($notice.Contains($eligible)) $notice
    Check 'migration does not re-list previously applied or inbox files' (-not ($notice -match 'UNCHANGED\.md|old-manifest|old-generation')) $notice
    Check 'legacy inbox content is untouched' ([IO.File]::ReadAllText($legacyCopy, $utf8) -ceq 'legacy payload')
    Check 'P1-2 legacy state remains byte-for-byte unchanged after v3 publish' ([IO.File]::ReadAllText($legacyStatePath, $utf8) -ceq $legacyBytes)
    $ack = Run-Acknowledgement -Command (Get-SyncAckCommand $migrated.Out)
    Check 'migrated review acknowledges against the source' ($ack.Exit -eq 0) $ack.Error
    $stillThere = @(Get-ChildItem -LiteralPath (Join-Path $dstSync 'inbox') -Recurse -File)
    Check 'migration and acknowledgement neither add nor delete legacy inbox bytes' ($stillThere.Count -eq 1 -and [IO.File]::ReadAllText($legacyCopy, $utf8) -ceq 'legacy payload')

    [IO.File]::Delete($eligible)
    [IO.File]::SetLastWriteTimeUtc($unchanged, [DateTime]::UtcNow.AddMinutes(-2))
    $deletion = Fire -Cwd $dst -Config $cfg
    Check 'deletion and a metadata-only touch are silent' ($deletion.Exit -eq 0 -and [string]::IsNullOrWhiteSpace($deletion.Out)) $deletion.Error

    $redirected = New-Project 'Redirected destination'
    $redirect = Join-Path $redirected '.ai\.cross-project-sync'
    New-Item -ItemType Junction -Path $redirect -Target (Join-Path $outside '.ai') -ErrorAction Stop | Out-Null
    try {
        $redirectCfg = Join-Path $Work 'cfg-redirected.json'
        Write-Config -Path $redirectCfg -Routes @((New-Route 'redirected' (New-Endpoint 'Src' $src) (New-Endpoint 'Dst' $redirected))) -Extensions @('.md')
        $refused = Fire -Cwd $redirected -Config $redirectCfg
        Check 'destination state does not follow a junction' ([string]::IsNullOrWhiteSpace($refused.Out) -and -not (Test-Path -LiteralPath (Join-Path $outside '.ai\state'))) $refused.Error
    }
    finally { [IO.Directory]::Delete($redirect) }
}
finally { [IO.Directory]::Delete($link) }
