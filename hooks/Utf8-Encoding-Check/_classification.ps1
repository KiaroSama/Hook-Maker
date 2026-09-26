# Utf8-Encoding-Check: WHAT COUNTS AS A VIOLATION.
#
# Two halves of one question. Classification turns BYTES into a verdict - strict
# UTF-8, UTF-8 with BOM, UTF-16 LE/BE, binary, empty or invalid - with the
# bounded readers that fetch those bytes from disk or from a git blob without
# reading a whole large file into memory. The exception registry then says which
# non-UTF-8 files the project has documented as legitimately required to be that
# way, and matches a path against it.
#
# Classification alone cannot answer "is this a violation"; the registry alone
# has nothing to judge. They live together for that reason, apart from the walk
# that finds files and the output that reports them.
#
# Dot-sourced by Utf8-Encoding-Check.ps1 via $PSScriptRoot, which resolves the
# same way here and in an installed runtime directory.


# ---- classification ---------------------------------------------------------
# One deterministic function for every mode. Returns one of:
#   utf8 / utf8bom          valid strict UTF-8 (BOM never fails a file)
#   utf16le / utf16be       non-UTF-8 TEXT (violation-capable, never a skip)
#   invalid                 an invalid UTF-8 byte sequence (the violation)
#   binary                  NUL evidence across both byte parities (skip)
#   oversized               text-looking but not fully read (UNKNOWN)
# $Truncated means only the first window of a too-large file was supplied, so
# a full strict decode is impossible - the heuristics still run (binary and
# UTF-16 are recognizable from the window) but a text-looking window yields
# 'oversized', never a false 'utf8'.
function Get-Utf8Classification {
    param([byte[]]$Bytes, [bool]$Truncated = $false)
    $len = $Bytes.Length
    if ($len -eq 0) { return 'utf8' }
    if ($len -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return 'utf16le' }
    if ($len -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return 'utf16be' }
    $hasBom = ($len -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    # NUL scan over the first bounded window. BOM-less UTF-16 text shows its
    # zeros overwhelmingly on ONE byte parity (ASCII-range chars leave the
    # other byte of each pair zero); real binary spreads zeros across both.
    $window = [Math]::Min($len, $script:HeuristicWindowBytes)
    $evenZeros = 0
    $oddZeros = 0
    for ($i = 0; $i -lt $window; $i++) {
        if ($Bytes[$i] -eq 0) { if ($i % 2 -eq 0) { $evenZeros++ } else { $oddZeros++ } }
    }
    if (($evenZeros + $oddZeros) -gt 0) {
        if ($oddZeros -ge 2 -and $oddZeros -ge (3 * $evenZeros)) { return 'utf16le' }
        if ($evenZeros -ge 2 -and $evenZeros -ge (3 * $oddZeros)) { return 'utf16be' }
        return 'binary'
    }
    if ($Truncated) { return 'oversized' }
    $payloadOffset = 0
    if ($hasBom) { $payloadOffset = 3 }
    try {
        # STRICT decoder: throwOnInvalidBytes=true. Never replacement-char
        # decoding - U+FFFD substitution would silently bless invalid bytes.
        $strict = [System.Text.UTF8Encoding]::new($false, $true)
        [void]$strict.GetString($Bytes, $payloadOffset, $len - $payloadOffset)
        if ($hasBom) { return 'utf8bom' }
        return 'utf8'
    }
    catch [System.Text.DecoderFallbackException] { return 'invalid' }
    catch [System.ArgumentException] { return 'invalid' }
}

# The extension downgrade: ONLY an ambiguous invalid/oversized result for a
# recognized binary extension becomes 'binary'. Content evidence always ran
# first, so this never classifies binary by extension alone.
function Resolve-ClassWithExtension {
    param([string]$RelativePath, [string]$RawClass)
    if ($RawClass -eq 'invalid' -or $RawClass -eq 'oversized') {
        $ext = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
        if ($script:KnownBinaryExtensions -contains $ext) { return 'binary' }
    }
    return $RawClass
}

function Get-ClassLabel {
    param([string]$Class)
    if ($Class -eq 'invalid') { return 'an invalid UTF-8 byte sequence' }
    if ($Class -eq 'utf16le') { return 'UTF-16 LE text (not UTF-8)' }
    if ($Class -eq 'utf16be') { return 'UTF-16 BE text (not UTF-8)' }
    return $Class
}

# ---- bounded byte readers ---------------------------------------------------
# Working-tree read: full when the file fits the ceiling, else only the first
# heuristic window (Truncated). FileShare ReadWrite so a file the agent still
# has open does not spuriously read as 'unreadable'.
function Read-FileBytesBounded {
    param([string]$Path, [int64]$MaxFullBytes)
    $result = [pscustomobject]@{ Bytes = $null; Truncated = $false; Failed = $false }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = $stream.Length
        $toRead = $length
        if ($length -gt $MaxFullBytes) {
            $toRead = [Math]::Min([int64]$script:HeuristicWindowBytes, $length)
            $result.Truncated = $true
        }
        $buffer = New-Object byte[] ([int]$toRead)
        $total = 0
        while ($total -lt $buffer.Length) {
            $n = $stream.Read($buffer, $total, $buffer.Length - $total)
            if ($n -le 0) { break }
            $total += $n
        }
        if ($total -lt $buffer.Length) { $result.Failed = $true } else { $result.Bytes = $buffer }
    }
    catch { $result.Failed = $true }
    finally { if ($null -ne $stream) { try { $stream.Dispose() } catch { } } }
    return $result
}

# Git blob read via `git cat-file blob <sha>` with the raw stdout STREAM (a
# text-mode capture would corrupt the bytes). Bounded: `cat-file -s` first,
# only the heuristic window of an oversized blob is read, the child is killed
# once enough bytes arrived, and a hard deadline caps a stalled read. The
# owned process is always reaped/disposed - no orphan survives this function.
function Get-GitBlobBytes {
    param([string]$Cwd, [string]$BlobSha, [int64]$MaxFullBytes)
    $result = [pscustomobject]@{ Bytes = $null; Truncated = $false; Failed = $false }
    if ($BlobSha -notmatch '^[0-9a-f]{6,64}$') { $result.Failed = $true; return $result }
    $sizeRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'cat-file', '-s', $BlobSha))
    $size = [int64]0
    if ($LASTEXITCODE -ne 0 -or -not [int64]::TryParse($sizeRaw.Trim(), [ref]$size) -or $size -lt 0) {
        $result.Failed = $true
        return $result
    }
    $toRead = $size
    if ($size -gt $MaxFullBytes) {
        $toRead = [Math]::Min([int64]$script:HeuristicWindowBytes, $size)
        $result.Truncated = $true
    }
    $proc = New-Object System.Diagnostics.Process
    try {
        $proc.StartInfo.FileName = 'git'
        # The sha is validated hex above and WorkingDirectory carries the repo
        # path, so no user-controlled text ever reaches this argument string.
        $proc.StartInfo.Arguments = 'cat-file blob ' + $BlobSha
        $proc.StartInfo.WorkingDirectory = $Cwd
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $proc.StartInfo.CreateNoWindow = $true
        [void]$proc.Start()
        $buffer = New-Object byte[] ([int]$toRead)
        $total = 0
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        $stream = $proc.StandardOutput.BaseStream
        while ($total -lt $buffer.Length) {
            if ($deadline.Elapsed.TotalSeconds -ge 15) { $result.Failed = $true; break }
            $n = $stream.Read($buffer, $total, $buffer.Length - $total)
            if ($n -le 0) { break }
            $total += $n
        }
        if (-not $result.Failed) {
            if ($total -lt $buffer.Length) { $result.Failed = $true } else { $result.Bytes = $buffer }
        }
    }
    catch { $result.Failed = $true }
    finally {
        # A truncated read leaves git blocked on a full pipe - kill it; a full
        # read lets it exit naturally. Either way the child is reaped here.
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { [void]$proc.WaitForExit(2000) } catch { }
        try { $proc.Dispose() } catch { }
    }
    return $result
}

# Many blobs through ONE `git cat-file --batch` child: the pre-push scan used
# to start two git processes per blob, which is the only reason it ever needed
# a file-count cap. Request and response alternate one blob at a time, so
# neither pipe can fill and deadlock. Returns sha -> the Get-GitBlobBytes
# result shape; an oversized blob keeps only its heuristic window (the rest is
# drained, never classified). Any protocol error leaves every unanswered blob
# Failed, which the caller turns into a fail-closed coverage error.
function Read-GitBlobsBatch {
    param([string]$Cwd, [string[]]$BlobShas, [int64]$MaxFullBytes)
    $results = @{}
    foreach ($sha in $BlobShas) { $results[$sha] = [pscustomobject]@{ Bytes = $null; Truncated = $false; Failed = $true } }
    $valid = @($BlobShas | Where-Object { $_ -match '^[0-9a-f]{40,64}$' })
    if ($valid.Count -eq 0) { return $results }
    $proc = New-Object System.Diagnostics.Process
    try {
        $proc.StartInfo.FileName = 'git'
        $proc.StartInfo.Arguments = 'cat-file --batch'
        $proc.StartInfo.WorkingDirectory = $Cwd
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardInput = $true
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $proc.StartInfo.CreateNoWindow = $true
        [void]$proc.Start()
        $proc.BeginErrorReadLine()
        $in = $proc.StandardInput.BaseStream
        $out = $proc.StandardOutput.BaseStream
        $header = New-Object System.Collections.Generic.List[byte]
        $scratch = New-Object byte[] 65536
        foreach ($sha in $valid) {
            $request = [System.Text.Encoding]::ASCII.GetBytes($sha + "`n")
            $in.Write($request, 0, $request.Length)
            $in.Flush()
            $header.Clear()
            while ($true) {
                $b = $out.ReadByte()
                if ($b -lt 0) { throw 'cat-file --batch ended early' }
                if ($b -eq 10) { break }
                [void]$header.Add([byte]$b)
            }
            $parts = @(([System.Text.Encoding]::ASCII.GetString($header.ToArray())) -split ' ')
            $size = [int64]0
            if ($parts.Count -ne 3 -or $parts[1] -ne 'blob' -or -not [int64]::TryParse($parts[2], [ref]$size)) { continue }
            $keep = $size
            $truncated = $false
            if ($size -gt $MaxFullBytes) { $keep = [Math]::Min([int64]$script:HeuristicWindowBytes, $size); $truncated = $true }
            $buffer = New-Object byte[] ([int]$keep)
            $total = [int64]0
            # size + 1: git writes an LF after every object body.
            while ($total -lt $size + 1) {
                if ($total -lt $keep) { $n = $out.Read($buffer, [int]$total, [int]($keep - $total)) }
                else { $n = $out.Read($scratch, 0, [int][Math]::Min([int64]$scratch.Length, $size + 1 - $total)) }
                if ($n -le 0) { throw 'cat-file --batch ended mid-object' }
                $total += $n
            }
            $results[$sha] = [pscustomobject]@{ Bytes = $buffer; Truncated = $truncated; Failed = $false }
        }
        $in.Close()
    }
    catch { }
    finally {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { [void]$proc.WaitForExit(2000) } catch { }
        try { $proc.Dispose() } catch { }
    }
    return $results
}

# ---- exception registry -----------------------------------------------------
# Loads and STRICTLY validates the optional exception file. Returns only the
# entries that pass every rule; each rejection lands in $configWarnings and
# NEVER grants an exception.
function Get-Utf8Exceptions {
    param([string]$ProjectRoot)
    $valid = New-Object System.Collections.Generic.List[object]
    $relSetting = $exceptionFileSetting.Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($exceptionFileSetting) -or $relSetting -match '(^|/)\.\.(/|$)') {
        [void]$configWarnings.Add('UTF8_EXCEPTION_FILE must be a project-relative path inside the project; the configured value was rejected and no exceptions apply.')
        return $valid.ToArray()
    }
    $fullPath = ''
    try { $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $exceptionFileSetting)) } catch { $fullPath = '' }
    if ($fullPath -eq '' -or -not (Test-PathInside -Candidate $fullPath -Parent $ProjectRoot)) {
        [void]$configWarnings.Add('UTF8_EXCEPTION_FILE resolves outside the project; it was rejected and no exceptions apply.')
        return $valid.ToArray()
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $valid.ToArray() }
    $read = Read-FileBytesBounded -Path $fullPath -MaxFullBytes $maxFileBytes
    if ($read.Failed -or $read.Truncated) {
        [void]$configWarnings.Add('exception registry ' + $exceptionFileSetting + ' could not be fully read; ALL exceptions were rejected.')
        return $valid.ToArray()
    }
    $registryClass = Get-Utf8Classification -Bytes $read.Bytes
    if ($registryClass -ne 'utf8' -and $registryClass -ne 'utf8bom') {
        [void]$configWarnings.Add('exception registry ' + $exceptionFileSetting + ' is not itself valid UTF-8 (' + $registryClass + '); ALL exceptions were rejected.')
        return $valid.ToArray()
    }
    $payloadOffset = 0
    if ($registryClass -eq 'utf8bom') { $payloadOffset = 3 }
    $doc = $null
    try { $doc = ([System.Text.Encoding]::UTF8.GetString($read.Bytes, $payloadOffset, $read.Bytes.Length - $payloadOffset)) | ConvertFrom-Json } catch { $doc = $null }
    if ($null -eq $doc) {
        [void]$configWarnings.Add('exception registry ' + $exceptionFileSetting + ' is not valid JSON; ALL exceptions were rejected.')
        return $valid.ToArray()
    }
    $version = Get-Field $doc 'version'
    if ([string]$version -ne '1') {
        [void]$configWarnings.Add('exception registry ' + $exceptionFileSetting + ' has an unsupported version (expected 1); ALL exceptions were rejected.')
        return $valid.ToArray()
    }
    $index = 0
    foreach ($entry in @(Get-Field $doc 'exceptions')) {
        $index++
        if ($null -eq $entry) { continue }
        $path = ([string](Get-Field $entry 'path')).Trim().Replace('\', '/')
        $encoding = ([string](Get-Field $entry 'encoding')).Trim().ToLowerInvariant()
        $reason = ([string](Get-Field $entry 'reason')).Trim()
        $reject = ''
        if ($path -eq '') { $reject = 'path is empty' }
        elseif ([System.IO.Path]::IsPathRooted($path) -or $path -match '^[A-Za-z]:' -or $path.StartsWith('/')) { $reject = 'path is absolute; only project-relative paths are allowed' }
        elseif ($path -match '(^|/)\.\.(/|$)') { $reject = 'path contains ".." and could escape the project' }
        elseif ($path.Contains('**')) { $reject = 'broad "**" patterns are not allowed; use an exact path or one narrow "*" glob' }
        elseif ($path.Contains('?') -or $path.Contains('[') -or $path.Contains(']')) { $reject = 'only "*" is allowed as a wildcard (deterministic matching)' }
        elseif (@($path.ToCharArray() | Where-Object { [string]$_ -eq '*' }).Count -gt 1) { $reject = 'more than one "*" makes the pattern too broad' }
        elseif (@($path.ToCharArray() | Where-Object { [string]$_ -ne '*' -and [string]$_ -ne '/' }).Count -lt 3) { $reject = 'the pattern has fewer than 3 literal characters and is too broad' }
        elseif (-not $script:RecognizedEncodings.Contains($encoding)) { $reject = 'encoding "' + $encoding + '" is not a recognized label (binary is deliberately not one - an exception cannot reclassify binary as text)' }
        elseif ($reason.Length -lt 5 -or $script:PlaceholderReasons -contains $reason.ToLowerInvariant()) { $reject = 'reason is missing or a placeholder; a concrete reason is required' }
        if ($reject -eq '' -and -not $path.Contains('*')) {
            # Belt and braces: an exact path must also physically resolve
            # inside the project even after normalization.
            $entryFull = ''
            try { $entryFull = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $path)) } catch { $entryFull = '' }
            if ($entryFull -eq '' -or -not (Test-PathInside -Candidate $entryFull -Parent $ProjectRoot)) { $reject = 'path resolves outside the project' }
        }
        if ($reject -ne '') {
            [void]$configWarnings.Add('exception entry ' + $index + ' (' + $path + ') rejected: ' + $reject + '. It grants nothing.')
            continue
        }
        [void]$valid.Add([pscustomobject]@{ Path = $path; IsGlob = $path.Contains('*'); Encoding = $encoding; Reason = $reason })
    }
    return $valid.ToArray()
}

function Test-ExceptionMatch {
    param($Exceptions, [string]$RelativePath)
    foreach ($entry in @($Exceptions)) {
        if ($entry.IsGlob) {
            if ($RelativePath -like $entry.Path) { return $true }
        }
        elseif ([string]::Equals($RelativePath, $entry.Path, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
