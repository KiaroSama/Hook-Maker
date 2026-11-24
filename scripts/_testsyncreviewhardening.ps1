# Dot-sourced by Test-Engine.ps1 after the normal route scenarios.
$hardSrc = New-Project 'Hardening source'; $hardDst = New-Project 'Hardening destination'
$hardCfg = Join-Path $Work 'cfg-hardening.json'
$hardRoute = New-Route 'hardening' (New-Endpoint 'Src' $hardSrc) (New-Endpoint 'Dst' $hardDst)
Write-Config -Path $hardCfg -Routes @($hardRoute) -Extensions @('.md')
$hardNote = Join-Path $hardSrc '.ai\Build blocked.md'
[IO.File]::WriteAllText($hardNote, 'old')
$unsafeName = 'Unsafe-' + [char]0x202E + '.md'
[IO.File]::WriteAllText((Join-Path $hardSrc ('.ai\' + $unsafeName)), 'unsafe')
$outsidePath = Join-Path $Work 'Outside note.md'
[IO.File]::WriteAllText($outsidePath, 'not owned by source')
$linkedFile = Join-Path $hardSrc '.ai\Hard link.md'
New-Item -ItemType HardLink -Path $linkedFile -Target $outsidePath -ErrorAction Stop | Out-Null
try {
    $hardNotice = Fire -Cwd $hardDst -Config $hardCfg -SessionId 'literal'
    $text = Get-SyncNotice $hardNotice.Out
    Check 'P1-1 multiply-linked source files are not announced' (-not $text.Contains('Hard link.md')) $text
    Check 'P1-3 source paths survive prose rewriting verbatim' ($text.Contains($hardNote) -and -not $text.Contains('Build unverified.md')) $text
    Check 'P1-3 bidi controls in file names are not announced' (-not $text.Contains([string][char]0x202E)) $text
    $hardAck = Run-Acknowledgement -Command (Get-SyncAckCommand $hardNotice.Out)
    Check 'hardening fixture acknowledges the current source' ($hardAck.Exit -eq 0) $hardAck.Error
    $time = [IO.File]::GetLastWriteTimeUtc($hardNote)
    [IO.File]::WriteAllText($hardNote, 'new')
    [IO.File]::SetLastWriteTimeUtc($hardNote, $time)
    $equalMeta = Fire -Cwd $hardDst -Config $hardCfg -SessionId 'same-metadata'
    Check 'P2-5 same length and timestamp edit is announced' ((Get-SyncNotice $equalMeta.Out).Contains($hardNote)) $equalMeta.Out
    $hardStateDir = Join-Path $hardDst '.ai\.cross-project-sync\state'
    $hardState = Get-ChildItem -LiteralPath $hardStateDir -File -Filter '*.json' | Select-Object -First 1
    $oldKeyText = 'grp|hardening|' + $hardSrc
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $oldKeyHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($oldKeyText))).Replace('-', '').ToLowerInvariant().Substring(0,10) }
    finally { $sha.Dispose() }
    $oldKey = ([regex]::Replace($oldKeyText,'[^A-Za-z0-9._-]+','-').Trim('-'))
    $oldKey = $oldKey.Substring(0,[Math]::Min(48,$oldKey.Length)) + '-' + $oldKeyHash
    $simulatedOldReader = Join-Path $hardStateDir ($oldKey + '.json')
    Check 'P1-2 old fixed-name route state cannot see v3 pending' ($hardState.Name -ceq ($oldKey + '.v3.json') -and -not [IO.File]::Exists($simulatedOldReader)) $hardState.Name
    $linkParent = Join-Path $Work 'above configured source'
    New-Item -ItemType Junction -Path $linkParent -Target (Split-Path -Parent $hardSrc) -ErrorAction Stop | Out-Null
    try {
        $linkedSrc = Join-Path $linkParent (Split-Path -Leaf $hardSrc)
        $linkedCase = New-Project 'Linked source destination'
        $linkCfg = Join-Path $Work 'cfg-link-ancestor.json'
        Write-Config -Path $linkCfg -Routes @((New-Route 'link-ancestor' (New-Endpoint 'Src' $linkedSrc) (New-Endpoint 'Dst' $linkedCase))) -Extensions @('.md')
        $redirectedRoot = Fire -Cwd $linkedCase -Config $linkCfg
        Check 'P1-1 junction above configured source root is refused' ([string]::IsNullOrEmpty($redirectedRoot.Out)) $redirectedRoot.Out
    }
    finally { [IO.Directory]::Delete($linkParent) }

    $laterSrc = New-Project 'Later valid source'
    [IO.File]::WriteAllText((Join-Path $laterSrc '.ai\LATER.md'), 'review later route')
    $laterRoute = New-Route 'valid-later' (New-Endpoint 'Later' $laterSrc) (New-Endpoint 'Dst' $hardDst)
    $legacyPath = $hardState.FullName -replace '\.v3\.json$', '.json'
    if ($legacyPath -ne $hardState.FullName) { [IO.File]::Delete($hardState.FullName) }
    [IO.File]::WriteAllText($legacyPath, '{')
    Write-Config -Path $hardCfg -Routes @($hardRoute,$laterRoute) -Extensions @('.md')
    $later = Fire -Cwd $hardDst -Config $hardCfg -SessionId 'damaged-legacy'
    Check 'P2-7 truncated legacy state cannot mute a later route' ($later.Exit -eq 0 -and (Get-SyncNotice $later.Out).Contains('LATER.md')) $later.Error
    Check 'P2-7 truncated legacy file is preserved' ([IO.File]::ReadAllText($legacyPath) -ceq '{')
}
finally { [IO.File]::Delete($linkedFile) }

$pageSrc = New-Project 'Page source'; $pageDst = New-Project 'Page destination'
$pageCfg = Join-Path $Work 'cfg-page.json'
$pageRoute = New-Route 'pagination' (New-Endpoint 'Src' $pageSrc) (New-Endpoint 'Dst' $pageDst)
Write-Config -Path $pageCfg -Routes @($pageRoute) -Extensions @('.md')
1..60 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $pageSrc ('.ai\LESSON-' + $_.ToString('00') + '-' + ('a'*100) + '.md')), 'lesson') }
$page1 = Fire -Cwd $pageDst -Config $pageCfg -SessionId 'page-session'
$pageText = Get-SyncNotice $page1.Out
$firstCount = [regex]::Matches($pageText,'LESSON-\d\d-').Count
Check 'P2-4 first notice is bounded and offers a nonempty partial batch' ($pageText.Length -le 8000 -and $firstCount -gt 0 -and $firstCount -le 24) ([string]$firstCount)
$pageAck = Run-Acknowledgement -Command (Get-SyncAckCommand $page1.Out)
Check 'P2-4 first batch acknowledgement succeeds' ($pageAck.Exit -eq 0) $pageAck.Error
$page2 = Fire -Cwd $pageDst -Config $pageCfg -SessionId 'page-session'
$page2Text = Get-SyncNotice $page2.Out
Check 'P2-4 unlisted paths remain queued after the first acknowledgement' ($page2Text.Contains(('LESSON-' + ($firstCount+1).ToString('00') + '-')) -and -not $page2Text.Contains('LESSON-01-')) $page2Text
$oldPageAck = Run-Acknowledgement -Command (Get-SyncAckCommand $page1.Out)
Check 'P2-4 previous batch command cannot acknowledge a later batch' ($oldPageAck.Exit -ne 0 -and $oldPageAck.Error -match 'Review changed') $oldPageAck.Error

$extraSrc = New-Project 'Second page source'
1..24 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $extraSrc ('.ai\EXTRA-' + $_.ToString('00') + '-' + ('b'*120) + '.md')), 'second route') }
$extraRoute = New-Route 'second-pagination' (New-Endpoint 'Src2' $extraSrc) (New-Endpoint 'Dst' $pageDst)
Write-Config -Path $pageCfg -Routes @($pageRoute,$extraRoute) -Extensions @('.md')
$combined = Get-SyncNotice (Fire -Cwd $pageDst -Config $pageCfg).Out
Check 'P2-4 context-wide cap also applies to multiple routes' ($combined.Length -gt 0 -and $combined.Length -le 8000 -and [regex]::Matches($combined,'(?:LESSON|EXTRA)-\d\d-').Count -le 24) $combined

$unicodeSrc = New-Project 'Unicode twins source'; $unicodeDst = New-Project 'Unicode twins destination'
$nfd = 'cafe' + [char]0x0301 + '.md'
$nfc = 'caf' + [char]0x00e9 + '.md'
1..23 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $unicodeSrc ('.ai\A-' + $_.ToString('00') + '.md')), 'filler') }
foreach ($note in @($nfd, $nfc)) { [IO.File]::WriteAllText((Join-Path $unicodeSrc ('.ai\' + $note)), 'identical bytes') }
Write-Config -Path $pageCfg -Routes @((New-Route 'unicode-page' (New-Endpoint 'Src' $unicodeSrc) (New-Endpoint 'Dst' $unicodeDst))) -Extensions @('.md')
$firstUnicode = Fire -Cwd $unicodeDst -Config $pageCfg
$firstText = Get-SyncNotice $firstUnicode.Out
Check 'ordinal batch fixture lists the NFD twin but not its NFC twin' ($firstText.Contains($nfd) -and -not $firstText.Contains($nfc)) $firstText
$unicodeAck = Run-Acknowledgement -Command (Get-SyncAckCommand $firstUnicode.Out)
Check 'acknowledging the listed NFD twin succeeds' ($unicodeAck.Exit -eq 0 -and $unicodeAck.Out -match 'acknowledged') $unicodeAck.Error
$nextText = Get-SyncNotice (Fire -Cwd $unicodeDst -Config $pageCfg).Out
Check 'acknowledging an NFD name leaves the unlisted NFC twin queued' ($nextText.Contains($nfc) -and -not $nextText.Contains($nfd)) $nextText
