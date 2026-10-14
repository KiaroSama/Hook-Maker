# Fixed-memory validation shared by disk and the raw Git batch transport.
# Decoder state survives chunk boundaries; only the final flush can prove that
# a trailing lead byte is not an incomplete sequence. No decoded text is kept.

function Read-Utf8StreamChunk {
    param([System.IO.Stream]$Stream, [byte[]]$Buffer, [int]$Offset, [int]$Count, [DateTime]$DeadlineUtc)
    $remaining = [int][Math]::Min([int]::MaxValue, [Math]::Ceiling(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds))
    if ($remaining -le 0) { throw 'UTF-8 read deadline exhausted' }
    $pending = $Stream.ReadAsync($Buffer, $Offset, $Count)
    if (-not $pending.Wait($remaining)) { throw 'UTF-8 stream read timed out' }
    return $pending.GetAwaiter().GetResult()
}

function Read-Utf8StreamClassification {
    param(
        [System.IO.Stream]$Stream, [int64]$Length, [int64]$MaxFullBytes,
        [DateTime]$DeadlineUtc, [switch]$Drain
    )
    if ($Length -lt 0) { throw 'Negative UTF-8 body length' }
    $buffer = New-Object byte[] 65536
    $prefixLength = [int][Math]::Min([int64]$script:HeuristicWindowBytes, $Length)
    $prefixRead = 0
    while ($prefixRead -lt $prefixLength) {
        $n = Read-Utf8StreamChunk $Stream $buffer $prefixRead ($prefixLength - $prefixRead) $DeadlineUtc
        if ($n -le 0) { throw 'UTF-8 stream ended in heuristic window' }
        $prefixRead += $n
    }
    # Preserve the historical heuristic exactly, including both byte parities
    # and BOM precedence. The unused buffer tail must never enter that window.
    $prefix = New-Object byte[] $prefixLength
    [Array]::Copy($buffer, $prefix, $prefixLength)
    $class = Get-Utf8Classification -Bytes $prefix -Truncated $true
    $decoder = $null
    $chars = $null
    if ($class -eq 'oversized' -or ($Length -eq 0 -and $class -eq 'utf8')) {
        if ($Length -gt $MaxFullBytes) { $class = 'oversized' }
        else {
            $class = 'utf8'
            if ($prefixLength -ge 3 -and $prefix[0] -eq 0xEF -and $prefix[1] -eq 0xBB -and $prefix[2] -eq 0xBF) { $class = 'utf8bom' }
            $decoder = ([System.Text.UTF8Encoding]::new($false, $true)).GetDecoder()
            # One chunk plus pending UTF-8 bytes can yield one extra character.
            $chars = New-Object char[] 65538
            try { [void]$decoder.GetChars($buffer, 0, $prefixLength, $chars, 0, $false) }
            catch [System.Text.DecoderFallbackException] { $class = 'invalid'; $decoder = $null }
        }
    }
    if (-not $Drain -and $null -eq $decoder) { return $class }
    $total = [int64]$prefixLength
    while ($total -lt $Length) {
        $want = [int][Math]::Min([int64]$buffer.Length, $Length - $total)
        $n = Read-Utf8StreamChunk $Stream $buffer 0 $want $DeadlineUtc
        if ($n -le 0) { throw 'UTF-8 stream ended mid-body' }
        $total += $n
        if ($null -ne $decoder) {
            try { [void]$decoder.GetChars($buffer, 0, $n, $chars, 0, $false) }
            catch [System.Text.DecoderFallbackException] { $class = 'invalid'; $decoder = $null }
        }
        if (-not $Drain -and $null -eq $decoder) { return $class }
    }
    if ($null -ne $decoder) {
        try { [void]$decoder.GetChars($buffer, 0, 0, $chars, 0, $true) }
        catch [System.Text.DecoderFallbackException] { $class = 'invalid' }
    }
    return $class
}

function Get-Utf8FileClassification {
    param([string]$Path, [int64]$MaxFullBytes, [DateTime]$DeadlineUtc = ([DateTime]::UtcNow.AddSeconds(15)))
    $result = [pscustomobject]@{ Class = ''; Failed = $true; Truncated = $false }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = $stream.Length
        $class = Read-Utf8StreamClassification $stream $length $MaxFullBytes $DeadlineUtc
        # Concurrent growth/shrink is incomplete coverage, never a clean prefix.
        if ($stream.Length -ne $length) { throw 'UTF-8 file size changed during validation' }
        $result.Class = $class
        $result.Truncated = ($class -eq 'oversized')
        $result.Failed = $false
    }
    catch { }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    return $result
}

function Read-Utf8BatchFrame {
    param([System.IO.Stream]$Stream, [string]$ExpectedSha, [int64]$MaxFullBytes, [DateTime]$DeadlineUtc)
    $header = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($header.Count -le 128) {
        if ((Read-Utf8StreamChunk $Stream $one 0 1 $DeadlineUtc) -ne 1) { throw 'cat-file --batch ended in header' }
        if ($one[0] -eq 10) { break }
        [void]$header.Add($one[0])
    }
    if ($header.Count -gt 128) { throw 'cat-file --batch header exceeded bound' }
    $text = [System.Text.Encoding]::ASCII.GetString($header.ToArray())
    $pattern = '^' + [regex]::Escape($ExpectedSha) + ' blob ([0-9]+)$'
    $size = [int64]0
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success -or -not [int64]::TryParse($match.Groups[1].Value, [ref]$size)) { throw 'cat-file --batch malformed object header' }
    $class = Read-Utf8StreamClassification $Stream $size $MaxFullBytes $DeadlineUtc -Drain
    # The separator is NOT part of the body or decoder: consuming size+1 in
    # one read both hid malformed separators and could swallow the next header.
    if ((Read-Utf8StreamChunk $Stream $one 0 1 $DeadlineUtc) -ne 1 -or $one[0] -ne 10) { throw 'cat-file --batch missing object delimiter' }
    return [pscustomobject]@{ Class = $class; Bytes = $null; Truncated = ($class -eq 'oversized'); Failed = $false }
}
