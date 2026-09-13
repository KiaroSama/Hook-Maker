# Test-Utf8EncodingCheck.ps1 shared harness: fixture builders (raw-byte
# writers, throwaway git repos + bare remotes), isolated hook copies with a
# fake LOCALAPPDATA, the Fire / FireGitPrePush process runners, and the
# output parsers. Dot-sourced by Test-Utf8EncodingCheck.ps1 into the caller's
# scope (uses its $Work / $Hook / $HookLib) - not a standalone suite.

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

function New-GitRepo {
    param([string]$Name)
    $repo = New-Proj $Name
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    & git -C $repo config core.autocrlf false
    return $repo
}

function New-PushableRepo {
    param([string]$Name)
    $repo = New-GitRepo $Name
    $bare = Join-Path $Work ($Name + '.git')
    & git init -q --bare $bare 2>$null | Out-Null
    & git -C $repo remote add origin $bare 2>$null | Out-Null
    return $repo
}

function Push-Repo {
    param([string]$Repo, [string]$Branch = 'main')
    & git -C $Repo push -q origin $Branch 2>$null | Out-Null
}

function Add-Commit {
    param([string]$Repo, [string]$Message = 'c')
    & git -C $Repo add -A 2>$null | Out-Null
    & git -C $Repo commit -q -m $Message 2>$null | Out-Null
}

# One real pre-push ref-update stdin line from actual git plumbing (local
# HEAD sha + the local remote-tracking ref) - never hand-typed shas.
# LocalSha/RemoteSha are intentionally UNTYPED: a [string] param would coerce
# an omitted $null default to '' (see LESSON.md).
function Get-RefUpdateLine {
    param([string]$Repo, [string]$Branch = 'main', $LocalSha = $null, $RemoteSha = $null)
    $local = if ($null -ne $LocalSha) { [string]$LocalSha } else { ((& git -C $Repo rev-parse ('refs/heads/' + $Branch)) | Out-String).Trim() }
    $remote = if ($null -ne $RemoteSha) { [string]$RemoteSha } else {
        $resolved = & git -C $Repo rev-parse ('refs/remotes/origin/' + $Branch) 2>$null
        if ($LASTEXITCODE -eq 0) { ([string]$resolved).Trim() } else { '0' * 40 }
    }
    return ('refs/heads/' + $Branch + ' ' + $local + ' refs/heads/' + $Branch + ' ' + $remote + "`n")
}

# Raw-byte writer: the whole suite is about exact bytes, so fixtures are
# always written with WriteAllBytes, never through a text encoder implicitly.
function Write-Bytes {
    param([string]$Path, [byte[]]$Bytes)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

# ---- byte fixtures ----------------------------------------------------------
# An ASCII marker + a lone 0xC3 lead byte followed by LF: 0xC3 demands a
# continuation byte and 0x0A is not one -> strictly invalid UTF-8, no NULs.
function Get-InvalidUtf8Bytes {
    param([string]$Marker = 'INVALIDPAYLOAD')
    return [byte[]](([System.Text.Encoding]::ASCII.GetBytes($Marker)) + @([byte]0xC3, [byte]0x0A))
}

# Windows-1252 'café' - 0xE9 is a bare high byte, invalid in strict UTF-8.
function Get-Cp1252Bytes {
    param([string]$Marker = 'CP1252PAYLOAD')
    return [byte[]](([System.Text.Encoding]::ASCII.GetBytes($Marker + ' caf')) + @([byte]0xE9, [byte]0x0A))
}

function Get-Utf16LeBytes {
    param([string]$Text, [switch]$NoBom)
    $enc = [System.Text.Encoding]::Unicode
    if ($NoBom) { return [byte[]]$enc.GetBytes($Text) }
    return [byte[]]($enc.GetPreamble() + $enc.GetBytes($Text))
}

function Get-Utf16BeBytes {
    param([string]$Text)
    $enc = [System.Text.Encoding]::BigEndianUnicode
    return [byte[]]($enc.GetPreamble() + $enc.GetBytes($Text))
}

function Get-Utf8BomBytes {
    param([string]$Text)
    $enc = New-Object System.Text.UTF8Encoding $true
    return [byte[]]($enc.GetPreamble() + $enc.GetBytes($Text))
}

# NUL bytes spread across BOTH byte parities (indexes 4,5,6,10,13) so the
# one-parity UTF-16 heuristic cannot fire -> classified binary.
function Get-BinaryBytes {
    return [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x0D, 0xFF, 0xD8, 0x00, 0x33, 0x11, 0x00, 0x42, 0x43)
}

# ---- isolated hook copies ---------------------------------------------------
# Per-test hook copy + fake LOCALAPPDATA so fingerprint/baseline state never
# collides between scenarios. The copy dot-sources '..\_hooklib.ps1', which
# resolves to $Work\_hooklib.ps1 since the copy dir sits one level under $Work.
function New-IsolatedHookCopy {
    param([string]$EnvContent = $null)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # The whole hook PACKAGE - the installer stages every .ps1 beside the entry
    # point, so a single-file copy would exercise a runtime that cannot exist.
    foreach ($pkgFile in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -File -Filter '*.ps1')) {
        Copy-Item $pkgFile.FullName (Join-Path $dir $pkgFile.Name) -Force
    }
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($null -ne $EnvContent) { Write-Utf8 (Join-Path $dir '.env') $EnvContent }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Utf8-Encoding-Check.ps1'); LocalAppData = $fakeLocal }
}

# A do-nothing stand-in with the same parameter contract. Used ONLY to prove
# the suite's block assertions are load-bearing (they must FAIL against an
# exit-0 stub) - the red half of red-before-green for a brand-new hook.
function New-StubHook {
    $dir = Join-Path $Work ('stubhook-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Utf8 (Join-Path $dir 'Utf8-Encoding-Check.ps1') "param([switch]`$GitPrePush)`nexit 0`n"
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Utf8-Encoding-Check.ps1'); LocalAppData = $fakeLocal }
}

# ---- process runners --------------------------------------------------------
# Lifecycle-event runner (SessionStart / Stop / SubagentStop): JSON on stdin,
# isolated LOCALAPPDATA, client-detection env var passed explicitly (the
# parent's CLAUDE_PROJECT_DIR is cleared at suite start because Start-Process
# -Environment MERGES rather than replaces).
function Fire {
    param(
        [string]$HookPath, [string]$Cwd, [string]$EventName, [string]$LocalAppData,
        [string]$SessionId = 'sess1', [switch]$ClaudeInputShape, [string]$ClaudeProjectDir = '',
        [switch]$StopHookActive, [string]$Exe = 'pwsh', [hashtable]$ExtraEnv = @{}
    )
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    if ($ClaudeInputShape) { $obj['hookSpecificOutput'] = @{ hookEventName = $EventName } }
    $payload = $obj | ConvertTo-Json -Depth 5
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $envTable = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData; CLAUDE_PROJECT_DIR = $ClaudeProjectDir }
        foreach ($k in $ExtraEnv.Keys) { $envTable[$k] = [string]$ExtraEnv[$k] }
        $startArgs.Environment = $envTable
    }
    $proc = Start-Process @startArgs
    # Bounded: -Wait has no ceiling. A hook that blocks on stdin or deadlocks
    # would otherwise hang this suite until the bucket's blunt per-suite limit
    # killed it, which reports a timed-out SUITE instead of this child.
    if (-not $proc.WaitForExit(180000)) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        throw ('the hook child (pid ' + $proc.Id + ') did not exit within 180s and was terminated')
    }
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Native pre-push runner: EXACTLY how the managed wrapper invokes each stage -
# powershell.exe 5.1, -File <script> -GitPrePush, the working directory set to
# the repo (the hook resolves cwd via Get-Location, not stdin), and stdin
# redirected from a file holding git's raw ref-update lines.
function FireGitPrePush {
    param([string]$Cwd, [string]$StdinText, [string]$HookPath, [string]$LocalAppData, [string]$Exe = 'powershell')
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.txt')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $StdinText, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '" -GitPrePush' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $HookPath + '" -GitPrePush' }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; WorkingDirectory = $Cwd
        RedirectStandardInput = $inFile; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData; CLAUDE_PROJECT_DIR = '' }
    }
    $proc = Start-Process @startArgs
    # Bounded: -Wait has no ceiling. A hook that blocks on stdin or deadlocks
    # would otherwise hang this suite until the bucket's blunt per-suite limit
    # killed it, which reports a timed-out SUITE instead of this child.
    if (-not $proc.WaitForExit(180000)) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        throw ('the hook child (pid ' + $proc.Id + ') did not exit within 180s and was terminated')
    }
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# ---- output parsers ---------------------------------------------------------
# Parses the advisory (never regexes it) and returns the model/user-visible text.
function Get-Message {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    try { $doc = $Text | ConvertFrom-Json } catch { return '' }
    if ($null -ne $doc.PSObject.Properties['hookSpecificOutput'] -and $null -ne $doc.hookSpecificOutput) {
        return [string]$doc.hookSpecificOutput.additionalContext
    }
    if ($null -ne $doc.PSObject.Properties['systemMessage']) { return [string]$doc.systemMessage }
    if ($null -ne $doc.PSObject.Properties['reason']) { return [string]$doc.reason }
    return ''
}

function Test-StopBlocks {
    param([string]$Out)
    $parsed = $null
    try { $parsed = $Out | ConvertFrom-Json } catch { return $false }
    return ($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['decision'] -and [string]$parsed.decision -eq 'block')
}

# Byte-level snapshot of an entire tree: relative path + length + SHA-256.
# Proving "untouched" by Test-Path would pass even if content were rewritten.
function Get-TreeSignature {
    param([string]$Root)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $parts = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object {
                $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($_.FullName))).Replace('-', '')
                $_.FullName.Substring($Root.Length) + '|' + $_.Length + '|' + $hash
            })
        return ($parts -join "`n")
    }
    finally { $sha.Dispose() }
}

# The valid exception-registry JSON used by several scenarios.
function Get-ExceptionJson {
    param([string]$Path, [string]$Encoding = 'windows-1252', [string]$Reason = 'vendor export kept byte-identical for diffing')
    return ('{"version":1,"exceptions":[{"path":"' + $Path + '","encoding":"' + $Encoding + '","reason":"' + $Reason + '","verification":"reviewed by suite"}]}')
}
