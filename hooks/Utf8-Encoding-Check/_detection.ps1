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

# Git C-quotes UTF-8 BYTES, not Unicode codepoints. Decode octal bytes together
# before path normalization; a malformed escape must never alias an exception.
function ConvertFrom-GitQuotedPath {
    param([string]$Path)
    if (-not $Path.StartsWith('"')) { return $Path }
    if ($Path.Length -lt 2 -or -not $Path.EndsWith('"')) { throw 'Malformed Git quoted path' }
    $strict=[Text.UTF8Encoding]::new($false,$true)
    $bytes=New-Object 'Collections.Generic.List[byte]'
    $escapes=@{a=7;b=8;f=12;n=10;r=13;t=9;v=11;'\'=92;'"'=34}
    for($i=1;$i-lt$Path.Length-1;$i++){
        $c=$Path[$i]
        if($c-eq'"'){throw 'Malformed Git quoted path'}
        if($c-ne'\'){
            $start=$i
            while($i+1-lt$Path.Length-1-and$Path[$i+1]-ne'\'-and$Path[$i+1]-ne'"'){$i++}
            $bytes.AddRange($strict.GetBytes($Path.Substring($start,$i-$start+1)))
            continue
        }
        $i++
        if($i-ge$Path.Length-1){throw 'Truncated Git path escape'}
        $key=[string]$Path[$i]
        if($escapes.ContainsKey($key)-and$key-ceq$key.ToLowerInvariant()){[void]$bytes.Add([byte]$escapes[$key]);continue}
        if($i+2-ge$Path.Length-1-or$Path.Substring($i,3)-cnotmatch'^[0-3][0-7]{2}$'){throw 'Invalid Git path octal escape'}
        [void]$bytes.Add([Convert]::ToByte($Path.Substring($i,3),8));$i+=2
    }
    $decoded=$strict.GetString($bytes.ToArray())
    if($decoded.IndexOf([char]0)-ge0){throw 'NUL is not a Git path'}
    return $decoded
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
    $walkDeadline = [DateTime]::UtcNow.AddSeconds($maxSeconds)
    if ($script:HookDeadlineUtc -lt $walkDeadline) { $walkDeadline = $script:HookDeadlineUtc }

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
                    $read = Get-Utf8FileClassification -Path $info.FullName -MaxFullBytes $maxFileBytes -DeadlineUtc $walkDeadline
                    if ($read.Failed) { $class = 'unreadable'; $scanIncomplete = $true }
                    else { $class = Resolve-ClassWithExtension -RelativePath $relative -RawClass $read.Class }
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

