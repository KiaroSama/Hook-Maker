# Raw transport/resource boundary checks shared by both host invocations.
    Write-Host '--- streaming boundaries, final flush and exact Git frames ---' -ForegroundColor Cyan
    . (Join-Path $HooksRoot 'Utf8-Encoding-Check\_detection.ps1')
    . (Join-Path $HooksRoot 'Utf8-Encoding-Check\_classification.ps1')
    . (Join-Path $HooksRoot 'Utf8-Encoding-Check\_streamvalidation.ps1')
    # Prefix consumes8192 bytes; subsequent64KiB chunk ends at73728.
    $boundary = 8192 + 65536
    $sequences = @(
        @{ Name='two-byte'; Bytes=[byte[]]@(0xC3,0xA9) },
        @{ Name='three-byte'; Bytes=[byte[]]@(0xE2,0x82,0xAC) },
        @{ Name='four-byte'; Bytes=[byte[]]@(0xF0,0x9F,0x98,0x80) }
    )
    foreach ($sequence in $sequences) {
        foreach ($split in 1..($sequence.Bytes.Length - 1)) {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes('a' * ($boundary - $split) + 'zzzz')
            [Array]::Copy($sequence.Bytes, 0, $bytes, $boundary - $split, $sequence.Bytes.Length)
            $stream = [System.IO.MemoryStream]::new($bytes, $false)
            try { $class = Read-Utf8StreamClassification $stream $bytes.Length 64MB ([DateTime]::UtcNow.AddSeconds(2)) }
            finally { $stream.Dispose() }
            Check ($sequence.Name + ' character split after byte' + $split + ' passes') ($class -eq 'utf8') $class
        }
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('a' * $boundary) + $sequence.Bytes[0..($sequence.Bytes.Length - 2)]
        $stream = [System.IO.MemoryStream]::new([byte[]]$bytes, $false)
        try { $class = Read-Utf8StreamClassification $stream $bytes.Length 64MB ([DateTime]::UtcNow.AddSeconds(2)) }
        finally { $stream.Dispose() }
        Check ($sequence.Name + ' incomplete final sequence fails after final flush') ($class -eq 'invalid') $class
    }
    foreach ($bad in @([byte[]]@(0xC0,0xAF), [byte[]]@(0xED,0xA0,0x80), [byte[]]@(0xF4,0x90,0x80,0x80))) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('a' * $boundary) + $bad
        $stream = [System.IO.MemoryStream]::new([byte[]]$bytes, $false)
        try { $class = Read-Utf8StreamClassification $stream $bytes.Length 64MB ([DateTime]::UtcNow.AddSeconds(2)) }
        finally { $stream.Dispose() }
        Check 'late overlong/surrogate/out-of-range scalar is rejected' ($class -eq 'invalid') $class
    }
    # Compile before starting frame deadlines: cold Add-Type is setup, not pipe I/O.
    Initialize-Utf8BatchReader
    # Raw transport fault fixtures: no fake decoder or mock of internal logic.
    $oid = 'a' * 40
    $frames = @(
        @{ Name='valid BOM'; Header=($oid+' blob 4'); Body=[byte[]]@(0xEF,0xBB,0xBF,0x61); End=[byte[]]@(10); Want='utf8bom' },
        @{ Name='empty body'; Header=($oid+' blob 0'); Body=[byte[]]@(); End=[byte[]]@(10); Want='utf8' },
        @{ Name='missing delimiter'; Header=($oid+' blob 1'); Body=[byte[]]@(97); End=[byte[]]@(); Want='failure' },
        @{ Name='wrong delimiter'; Header=($oid+' blob 1'); Body=[byte[]]@(97); End=[byte[]]@(13); Want='failure' },
        @{ Name='truncated body'; Header=($oid+' blob 5'); Body=[byte[]]@(97); End=[byte[]]@(10); Want='failure' },
        @{ Name='wrong oid'; Header=(('b'*40)+' blob 1'); Body=[byte[]]@(97); End=[byte[]]@(10); Want='failure' },
        @{ Name='wrong type'; Header=($oid+' tree 1'); Body=[byte[]]@(97); End=[byte[]]@(10); Want='failure' },
        @{ Name='CRLF header'; Header=($oid+" blob 0`r"); Body=[byte[]]@(); End=[byte[]]@(10); Want='failure' },
        @{ Name='negative size'; Header=($oid+' blob -1'); Body=[byte[]]@(); End=[byte[]]@(10); Want='failure' },
        @{ Name='overflow size'; Header=($oid+' blob 9223372036854775808'); Body=[byte[]]@(); End=[byte[]]@(10); Want='failure' },
        @{ Name='oversized header'; Header=('a'*130); Body=[byte[]]@(); End=[byte[]]@(10); Want='failure' }
    )
    foreach ($frame in $frames) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($frame.Header + "`n") + $frame.Body + $frame.End
        $stream = [System.IO.MemoryStream]::new([byte[]]$bytes, $false)
        $actual = 'failure'
        try { $actual = (Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(2))).Class }
        catch { }
        finally { $stream.Dispose() }
        Check ('Git frame: ' + $frame.Name) ($actual -eq $frame.Want) $actual
    }
    foreach ($headerBytes in @([byte[]]@(), [Text.Encoding]::ASCII.GetBytes($oid+' blob 1'))) {
        $stream = [IO.MemoryStream]::new([byte[]]$headerBytes,$false); $failedHeader=$false
        try { $null=Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(2)) }
        catch { $failedHeader=$true } finally { $stream.Dispose() }
        Check 'premature headerEOF/missingLF refuses coverage' $failedHeader
    }
    $oid64='b'*64
    $stream=[IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes($oid64+" blob 1`na`n"),$false)
    try { $frame64=Read-Utf8BatchFrame $stream $oid64 64MB ([DateTime]::UtcNow.AddSeconds(2)); Check '64hex object identity framing remains supported' ($frame64.Class -eq 'utf8') }
    finally { $stream.Dispose() }
    $stream = [System.IO.MemoryStream]::new([byte[]]@(97), $false)
    $expired = $false
    try { $null = Read-Utf8StreamClassification $stream 1 64MB ([DateTime]::UtcNow.AddSeconds(-1)) }
    catch { $expired = $true }
    finally { $stream.Dispose() }
    Check 'an exhausted read deadline refuses coverage' $expired

    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '_testutf8resourcestream.cs'), [Text.Encoding]::UTF8))
    $lazy = [Utf8ResourceStream]::new(64MB)
    try {
        $class = Read-Utf8StreamClassification $lazy $lazy.Length 64MB ([DateTime]::UtcNow.AddSeconds(10))
        Check 'exact64MiB text is fully validated with read requests no larger than64KiB' (
            $class -eq 'utf8' -and $lazy.Position -eq 64MB -and $lazy.MaximumReadSize -le 65536) $class
    } finally { $lazy.Dispose() }
    $lazy = [Utf8ResourceStream]::new(64MB + 1)
    try {
        $class = Read-Utf8StreamClassification $lazy $lazy.Length 64MB ([DateTime]::UtcNow.AddSeconds(2))
        Check 'one byte over explicit64MiB cap remains unknown with only heuristic read' (
            $class -eq 'oversized' -and $lazy.Position -eq 8192) $class
    } finally { $lazy.Dispose() }
    $lazy = [Utf8ResourceStream]::new(65536)
    $lazy.ShortReadSize = 7; $lazy.PatchOffset = 8191; $lazy.Patch = [byte[]]@(0xF0,0x9F,0x98,0x80)
    try {
        $class = Read-Utf8StreamClassification $lazy $lazy.Length 64MB ([DateTime]::UtcNow.AddSeconds(5))
        Check 'short transport reads preserve a multibyte sequence across heuristic boundary' ($class -eq 'utf8') $class
    } finally { $lazy.Dispose() }
    $lazy = [Utf8ResourceStream]::new(1); $lazy.Stall = $true
    $timer = [Diagnostics.Stopwatch]::StartNew(); $refused = $false
    try { $null = Read-Utf8StreamClassification $lazy 1 64MB ([DateTime]::UtcNow.AddMilliseconds(100)) }
    catch { $refused = $true }
    finally { $lazy.Dispose() }
    Check 'stalled async transport refuses within its deadline, not a clean result' ($refused -and $timer.Elapsed.TotalSeconds -lt 2)

    # Process is substituted only at the OS boundary; production orchestration,
    # pending raw pipe read, timeout, kill, WaitForExit and Dispose all run.
    $stallScript = Join-Path $Work 'stall-batch.ps1'
    $pidPath = Join-Path $Work 'stall-batch.pid'
    Write-Utf8 $stallScript "param([string]`$PidPath)`n[IO.File]::WriteAllText(`$PidPath,[string]`$PID,[Text.Encoding]::UTF8)`n`$null=[Console]::In.ReadLine()`n[Threading.Thread]::Sleep([Threading.Timeout]::Infinite)`n"
    $factory = (Get-Command New-Utf8GitProcess).ScriptBlock
    function New-Utf8GitProcess {
        param([string]$Cwd)
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo.FileName = (Get-Process -Id $PID).Path
        $proc.StartInfo.Arguments = ConvertTo-ProcessArgumentString @('-NoProfile','-File',$stallScript,$pidPath)
        $proc.StartInfo.WorkingDirectory = $Cwd
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardInput = $true
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $proc.StartInfo.CreateNoWindow = $true
        return $proc
    }
    $script:HookDeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $reads = Read-GitBlobsBatch -Cwd $Work -BlobShas @($oid) -MaxFullBytes 64MB -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(2))
        $childPid = if (Test-Path -LiteralPath $pidPath) { [int][IO.File]::ReadAllText($pidPath,[Text.Encoding]::UTF8) } else { 0 }
        Check 'stalled batch pipe fails closed and reaps the exact owned child' (
            $reads[$oid].Failed -and $timer.Elapsed.TotalSeconds -lt 5 -and $childPid -gt 0 -and
            $null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue))
    } finally { Set-Item -Path Function:New-Utf8GitProcess -Value $factory }

    if ($TransportOnly) {
        . (Join-Path $PSScriptRoot '_testutf8batchfaults.ps1')
        . (Join-Path $PSScriptRoot '_testutf8batchprocess.ps1')
    }
    # Drained classified objects must leave the next header at its exact byte.
    foreach ($firstBody in @([byte[]]@(0,0,97), [Text.Encoding]::ASCII.GetBytes('a'*3000))) {
        $bytes = [Text.Encoding]::ASCII.GetBytes($oid+' blob '+$firstBody.Length+"`n") + $firstBody + [byte[]]@(10) +
            [Text.Encoding]::ASCII.GetBytes($oid+" blob 1`na`n")
        $stream = [IO.MemoryStream]::new([byte[]]$bytes,$false)
        try {
            $first = Read-Utf8BatchFrame $stream $oid 1024 ([DateTime]::UtcNow.AddSeconds(2))
            $second = Read-Utf8BatchFrame $stream $oid 1024 ([DateTime]::UtcNow.AddSeconds(2))
            Check 'binary/over-cap frame drains exactly before the next text frame' (
                @('binary','oversized') -contains $first.Class -and $second.Class -eq 'utf8' -and $stream.Position -eq $stream.Length)
        } finally { $stream.Dispose() }
    }
