# Exact classifier seam; synthetic bytes prove thresholds, not RSA validity.
# Public RSA/DER fixtures are data only; signature trust is deliberately not tested.
. (Join-Path $HooksRoot 'Utf8-Encoding-Check/_detection.ps1')
. (Join-Path $HooksRoot 'Utf8-Encoding-Check/_classification.ps1')
. (Join-Path $HooksRoot 'Utf8-Encoding-Check/_streamvalidation.ps1')
Initialize-Utf8BatchReader
$script:HookDeadlineUtc = $null
$opaque = New-Object byte[] 384
for ($i = 0; $i -lt $opaque.Length; $i++) { $opaque[$i] = 0xDB }
for ($i = 0; $i -lt 32; $i++) { $opaque[$i * 8] = 1 }
# DB DB is an unpaired high surrogate in both byte orders; no NUL evidence.
$oid = 'a' * 40
foreach ($shape in @('no-nul', 'sparse-nul')) {
    $body = [byte[]]$opaque.Clone()
    if ($shape -eq 'sparse-nul') { $body[1] = 0; $body[3] = 0 }
    $direct = Get-Utf8Classification -Bytes $body
    Check ('opaque complete direct ' + $shape) ($direct -eq 'binary') $direct
    $stream = [IO.MemoryStream]::new($body, $false)
    try { $disk = Read-Utf8StreamClassification $stream $body.Length 64MB ([DateTime]::UtcNow.AddSeconds(5)) }
    finally { $stream.Dispose() }
    Check ('opaque complete stream ' + $shape) ($disk -eq 'binary') $disk
    $frameBytes = [Text.Encoding]::ASCII.GetBytes($oid + ' blob ' + $body.Length + "`n") + $body + [byte[]]@(10)
    $stream = [IO.MemoryStream]::new([byte[]]$frameBytes, $false)
    try { $frame = Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(5)) }
    finally { $stream.Dispose() }
    Check ('opaque complete frame ' + $shape) ($frame.Class -eq 'binary' -and $null -eq $frame.Bytes -and -not $frame.Failed) $frame.Class
}

$savedInitializer = (Get-Command Initialize-Utf8BatchReader).ScriptBlock
try {
    function Initialize-Utf8BatchReader { throw 'Compiler unavailable before any text registry classification' }
    $registryBytes = [Text.Encoding]::UTF8.GetBytes('{"version":1,"exceptions":[],"note":"an existing complete UTF-8 exception registry"}')
    Check 'unavailable compiler does not abort registry classification' ((Get-Utf8Classification -Bytes $registryBytes) -eq 'utf8')
}
finally { Set-Item Function:Initialize-Utf8BatchReader -Value $savedInitializer }
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
$controls = [string]([char]1) * 40 + [string]([char]0x06CC) * 160
$negatives = @(
    @{Name='valid-controls.sig'; Bytes=$strictUtf8.GetBytes($controls); Want='utf8'},
    @{Name='bom.der'; Bytes=[byte[]](@(239,187,191) + $strictUtf8.GetBytes($controls)); Want='utf8bom'},
    @{Name='latin.sig'; Bytes=[byte[]](0xE9,0x61,0x62,0x0A); Want='invalid'},
    @{Name='long1252.der'; Bytes=[Text.Encoding]::GetEncoding(1252).GetBytes(('caf' + [char]0xE9 + ' ') * 2000); Want='invalid'},
    @{Name='le.sig'; Bytes=[Text.Encoding]::Unicode.GetBytes($controls); Want='utf16le'},
    @{Name='be.der'; Bytes=[Text.Encoding]::BigEndianUnicode.GetBytes($controls); Want='utf16be'},
    @{Name='malformed-bom.sig'; Bytes=[byte[]]@(255,254,0,216); Want='utf16le'},
    @{Name='trailing.der'; Bytes=[byte[]](@(239,187,191,97,195)); Want='invalid'}
)
foreach ($case in $negatives) {
    $class = Get-Utf8Classification -Bytes $case.Bytes
    $stream = [IO.MemoryStream]::new([byte[]]$case.Bytes, $false)
    try { $streamClass = Read-Utf8StreamClassification $stream $case.Bytes.Length 64MB ([DateTime]::UtcNow.AddSeconds(5)) }
    finally { $stream.Dispose() }
    $frameBytes = [Text.Encoding]::ASCII.GetBytes($oid + ' blob ' + $case.Bytes.Length + "`n") + $case.Bytes + [byte[]]@(10)
    $stream = [IO.MemoryStream]::new([byte[]]$frameBytes, $false)
    try { $frame = Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(5)) }
    finally { $stream.Dispose() }
    Check ('opaque text veto agrees across paths: ' + $case.Name) ($class -eq $case.Want -and $streamClass -eq $case.Want -and $frame.Class -eq $case.Want) ($class + '/' + $streamClass + '/' + $frame.Class)
}
foreach ($count in @(63,64,8192,8193)) {
    $bytes = New-Object byte[] $count
    for ($i=0; $i -lt $count; $i++) { $bytes[$i]=0xDB }
    for ($i=0; $i -lt $count; $i+=8) { $bytes[$i]=1 }
    $expected = $count -ge 64 -and $count -le 8192
    Check ('opaque evidence exact size boundary ' + $count) ([HookMakerUtf8.BinaryEvidence]::IsOpaque($bytes,$count,$true) -eq $expected)
    Check ('partial evidence never opaque at ' + $count) (-not [HookMakerUtf8.BinaryEvidence]::IsOpaque($bytes,$count,$false))
}
foreach ($encoding in @([Text.UnicodeEncoding]::new($false,$false,$true), [Text.UnicodeEncoding]::new($true,$false,$true))) {
    $textBytes = $encoding.GetBytes(([string]([char]0x01DB) * 192))
    Check 'valid BOMless UTF16 vetoes opacity despite both density thresholds' (-not [HookMakerUtf8.BinaryEvidence]::IsOpaque($textBytes,$textBytes.Length,$true))
}
foreach ($prefix in @([byte[]]@(239,187,191), [byte[]]@(255,254), [byte[]]@(254,255))) {
    $bomBytes = [byte[]]($prefix + $opaque)
    Check 'text BOM vetoes otherwise opaque evidence' (-not [HookMakerUtf8.BinaryEvidence]::IsOpaque($bomBytes,$bomBytes.Length,$true))
}
# Simulate unavailable compiler at the initialization boundary, not the classifier.
& {
    function Initialize-Utf8BatchReader { throw 'Compiler unavailable in fixture' }
    $valid = Get-Utf8Classification -Bytes $strictUtf8.GetBytes($controls)
    $invalid = Get-Utf8Classification -Bytes $opaque
    Check 'unavailable helper preserves strict valid/invalid behavior' ($valid -eq 'utf8' -and $invalid -eq 'invalid') ($valid + '/' + $invalid)
}
$originalInputs = -not [string]::IsNullOrWhiteSpace($OpaqueFixtureDirectory)
$fixtureDir = $OpaqueFixtureDirectory
if ($originalInputs) { $fixtureDir = [IO.Path]::GetFullPath($fixtureDir) }
if (-not $originalInputs) {
    # CI uses deterministic opaque controls, not redistributed third-party fixtures.
    # Original public32 acceptance is a separate local-by-design invocation.
    $fixtureDir = Join-Path $Work 'opaque-controls'
    [void][IO.Directory]::CreateDirectory($fixtureDir)
    for ($index=0; $index -lt 32; $index++) {
        $bytes = [byte[]]$opaque.Clone(); $bytes[381]=[byte](32+$index)
        Write-Bytes (Join-Path $fixtureDir ('control-'+$index+'.sig')) $bytes
    }
}
$publicFiles = @(Get-ChildItem -LiteralPath $fixtureDir -File | Where-Object { $_.Extension -in @('.sig','.der') } | Sort-Object Name)
Check ('all 32 opaque inputs are present; originals=' + $originalInputs) ($publicFiles.Count -eq 32)
$repo = New-GitRepo 'opaque-public-outgoing'
foreach ($file in $publicFiles) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $repo $file.Name) }
Add-Commit $repo 'fixture'
$oids = @(& git -C $repo ls-files -s | ForEach-Object { ([string]$_ -split ' ')[1] } | Select-Object -Unique)
$batch = Read-GitBlobsBatch $repo $oids 64MB ([DateTime]::UtcNow.AddSeconds(20))
Check 'real Git object batch recognizes every public input without payload retention' (
    $oids.Count -eq 32 -and @($oids | Where-Object { $batch[$_].Failed -or $batch[$_].Class -ne 'binary' -or $null -ne $batch[$_].Bytes }).Count -eq 0)
$copy = New-IsolatedHookCopy
$refs = Get-RefUpdateLine -Repo $repo -RemoteSha ('0' * 40)
foreach ($hostName in @('pwsh','powershell')) {
    if ($hostName -eq 'powershell' -and -not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) { continue }
    $outgoing = FireGitPrePush -Cwd $repo -StdinText $refs -HookPath $copy.Script -LocalAppData $copy.LocalAppData -Exe $hostName
    Check ('actual outgoing opaque input gate passes: ' + $hostName) ($outgoing.Exit -eq 0) $outgoing.Err
}
Write-Bytes (Join-Path $repo 'negative.sig') ([byte[]]@(0xE9,97,10))
Add-Commit $repo 'negative'
$negative = FireGitPrePush -Cwd $repo -StdinText (Get-RefUpdateLine -Repo $repo -RemoteSha ('0' * 40)) -HookPath $copy.Script -LocalAppData $copy.LocalAppData -Exe 'pwsh'
Check 'actual outgoing text under signature name is still rejected' ($negative.Exit -ne 0 -and $negative.Err -match 'negative.sig') ($negative.Err + $negative.Out)
foreach ($file in $publicFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $direct = Get-Utf8Classification -Bytes $bytes
    $disk = Get-Utf8FileClassification $file.FullName 64MB ([DateTime]::UtcNow.AddSeconds(5))
    $frameBytes = [Text.Encoding]::ASCII.GetBytes($oid + ' blob ' + $bytes.Length + "`n") + $bytes + [byte[]]@(10)
    $stream = [IO.MemoryStream]::new([byte[]]$frameBytes,$false)
    try { $frame = Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(5)) }
    finally { $stream.Dispose() }
    Check ('opaque input direct/disk/frame agree: ' + $file.Name) ($direct -eq 'binary' -and $disk.Class -eq 'binary' -and -not $disk.Failed -and $frame.Class -eq 'binary' -and $null -eq $frame.Bytes)
}
