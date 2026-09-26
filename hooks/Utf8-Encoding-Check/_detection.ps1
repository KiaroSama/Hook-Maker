# Utf8-Encoding-Check, the DETECTION layer: every fixed table and threshold the
# hook detects with, and the bounded walk that applies them.
#
# Nothing here decides anything. It answers "what is there, and what am I
# allowed to look at" - which directories are pruned before descent, which
# extensions may downgrade an ambiguous verdict, which encodings are named,
# how wide the heuristic window is, where the pre-push ceilings sit, and what
# the violation vocabulary is - and then collects file entries. The three event
# stages in Utf8-Encoding-Check.ps1 are what turn that into a baseline, an
# advisory, or a refusal.
#
# Split out of Utf8-Encoding-Check.ps1 at the 800-line ceiling; dot-sourced by
# it where the constants block sat, so every table is still defined in that
# scope BEFORE _classification.ps1 loads, exactly as before. The three
# functions below are definitions only, so moving them ahead of that
# dot-source changes nothing: they are resolved at call time.
#
# It contains no top-level `exit` and must not grow one. `exit` inside a
# dot-sourced file terminates only that file - the caller runs on and the
# process exit code is never set - so a gate that refuses something can never
# live out here. That is measured, on both 5.1 and 7, not assumed.
# ---------------------------------------------------------------------------

# ---- constants --------------------------------------------------------------
# Directory names pruned BEFORE descent (Secrets-Check.ps1 $excludedDirs).
$script:ExcludedDirs = @('.git', 'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target', 'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env', '.ai', 'graphify-out', '.claude', '.codex', '.agents', 'bin', 'obj', '.ci-runner', '.tox', 'site-packages')
# Extensions that may DOWNGRADE an ambiguous 'invalid'/'oversized' result to
# binary. Never consulted before the bytes themselves have been examined.
$script:KnownBinaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.avif', '.pdf', '.zip', '.gz', '.tgz', '.bz2', '.xz', '.7z', '.rar', '.jar', '.war', '.exe', '.dll', '.so', '.dylib', '.pdb', '.lib', '.a', '.o', '.obj', '.bin', '.dat', '.db', '.sqlite', '.sqlite3', '.mdb', '.mp3', '.mp4', '.m4a', '.avi', '.mov', '.mkv', '.wav', '.ogg', '.flac', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.class', '.pyc', '.pyo', '.pyd', '.wasm', '.node', '.iso', '.dmg', '.msi', '.cab', '.nupkg', '.snupkg', '.whl', '.egg', '.parquet', '.xls', '.xlsx', '.doc', '.docx', '.ppt', '.pptx', '.swf', '.psd', '.ai0')
$script:RecognizedEncodings = @('utf-16le', 'utf-16be', 'windows-1252', 'iso-8859-1', 'latin-1', 'shift_jis', 'euc-jp', 'gb18030')
$script:PlaceholderReasons = @('todo', 'tbd', 'n/a', 'none', '-', 'x', 'fixme', 'because', 'reason')
$script:HeuristicWindowBytes = 8192
$script:ViolationClasses = @('invalid', 'utf16le', 'utf16be')

# ---- misc helpers -----------------------------------------------------------
function Test-PathExcluded {
    param([string]$RelativePath)
    foreach ($segment in $RelativePath.Split('/')) {
        if ($script:ExcludedDirs -contains $segment.ToLowerInvariant()) { return $true }
    }
    return $false
}

# git quotes a path containing specials as "..." with backslash escapes; the
# common cases (spaces stay unquoted, quotes/backslashes escaped) are handled.
# An octal-escaped non-ASCII path is left as-is - it can only fail an
# exception match, which is the strict (safe) direction.
function ConvertFrom-GitQuotedPath {
    param([string]$Path)
    if ($Path.Length -ge 2 -and $Path.StartsWith('"') -and $Path.EndsWith('"')) {
        return $Path.Substring(1, $Path.Length - 2).Replace('\"', '"').Replace('\\', '\')
    }
    return $Path
}

# ---- bounded project walk (baseline + non-git delta) ------------------------
# Explicit-stack walk mirroring Test-Plan-Check: excluded trees pruned BEFORE
# descent, a reparse-point ROOT refused (nothing pushed, marked partial),
# child reparse points never followed, lazy enumeration with the wall clock
# paid for EVERY enumerated entry. Every file is classified from its BYTES.
function Invoke-Utf8Walk {
    param([string]$Root, $Exceptions)
    $fileLimitReached = $false
    $dirLimitReached = $false
    $timeLimitReached = $false
    $scanIncomplete = $false
    $rootReparse = $false
    $dirsVisited = 0
    $entries = New-Object System.Collections.Generic.List[object]
    $walkTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $rootFull = $Root.TrimEnd('\', '/')
    try { $rootFull = (Get-Item -LiteralPath $Root -Force -ErrorAction Stop).FullName.TrimEnd('\', '/') } catch { }
    try { $rootReparse = ((([System.IO.File]::GetAttributes($rootFull)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { }
    $stack = New-Object System.Collections.Generic.Stack[string]
    if (-not $rootReparse) { $stack.Push($rootFull) }
    while ($stack.Count -gt 0) {
        if ($entries.Count -ge $maxFiles) { $fileLimitReached = $true; break }
        if ($dirsVisited -ge $maxDirs) { $dirLimitReached = $true; break }
        if ($walkTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
        $current = $stack.Pop()
        $dirsVisited++
        try {
            foreach ($dirPath in [System.IO.Directory]::EnumerateDirectories($current)) {
                if ($walkTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
                $dir = Get-Item -LiteralPath $dirPath -Force -ErrorAction SilentlyContinue
                if ($null -eq $dir -or ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                # A virtualenv is pruned by its PEP 405 marker, not its name (see _hooklib.ps1).
                if (Test-IsMarkerPrunedDirectory $dir.FullName) { continue }
                if ($script:ExcludedDirs -notcontains $dir.Name.ToLowerInvariant()) { $stack.Push($dir.FullName) }
            }
        }
        catch { $scanIncomplete = $true }
        if ($timeLimitReached) { break }
        try {
            foreach ($filePath in [System.IO.Directory]::EnumerateFiles($current)) {
                if ($entries.Count -ge $maxFiles) { $fileLimitReached = $true; break }
                if ($walkTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
                $info = Get-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
                if ($null -eq $info -or ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                $relative = $info.FullName
                if ($relative.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $relative.Substring($rootFull.Length).TrimStart('\', '/')
                }
                $relative = $relative.Replace('\', '/')
                $class = ''
                if (Test-ExceptionMatch -Exceptions $Exceptions -RelativePath $relative) {
                    $class = 'excepted'
                }
                else {
                    $read = Read-FileBytesBounded -Path $info.FullName -MaxFullBytes $maxFileBytes
                    if ($read.Failed) { $class = 'unreadable'; $scanIncomplete = $true }
                    else { $class = Resolve-ClassWithExtension -RelativePath $relative -RawClass (Get-Utf8Classification -Bytes $read.Bytes -Truncated $read.Truncated) }
                }
                [void]$entries.Add([pscustomobject]@{ p = $relative; s = [int64]$info.Length; t = [string]$info.LastWriteTimeUtc.Ticks; c = $class })
            }
        }
        catch { $scanIncomplete = $true }
        if ($timeLimitReached) { break }
    }

    $causes = New-Object System.Collections.Generic.List[string]
    if ($rootReparse) { [void]$causes.Add('the scan root is a junction/symlink and was not followed') }
    if ($fileLimitReached) { [void]$causes.Add('a file ceiling of ' + $maxFiles + ' classified files was reached') }
    if ($dirLimitReached) { [void]$causes.Add('a directory ceiling of ' + $maxDirs + ' directories was reached') }
    if ($timeLimitReached) { [void]$causes.Add('a scan time limit of ' + $maxSeconds + ' seconds was reached') }
    if ($scanIncomplete) { [void]$causes.Add('one or more files or directories could not be read') }
    return [pscustomobject]@{
        Entries = @($entries.ToArray())
        Partial = ($causes.Count -gt 0)
        PartialCause = ($causes -join ' and ')
    }
}

