# Github-Baseline-Check - the release build matrix reminder (steering V85-V88,
# spec 041). Dot-sourced by Github-Baseline-Check.ps1; definitions only, no exit.
#
# global-architecture-rules.md: a binary release defaults to four targets -
# Windows x64+arm64, Linux x64+arm64 - never 32-bit and never macOS unless the
# user asked in that request. This reads only RELEASE workflows (file name or
# name: says release, or a push on tags) and reports what the text shows.
# Advisory only: an explicit user request can legitimately add macOS or 32-bit,
# and the hook cannot see that request.

$script:ReleaseBit32Pattern = '(?i)\b(i[3-6]86|x86(?![_-]64)|win-x86|armv7|armhf|arm-unknown|GOARCH[:=]\s*["'']?386|\b386\b)'
$script:ReleaseMacPattern = '(?i)\b(macos-[0-9a-z.-]+|apple-darwin|osx-(x64|arm64)|darwin[-/](amd64|arm64))\b'
$script:ReleaseArmPatterns = [ordered]@{
    'Windows arm64' = '(?i)(aarch64-pc-windows|win-arm64|windows-11-arm|windows[^\n]{0,40}arm64)'
    'Linux arm64'   = '(?i)(aarch64-unknown-linux|linux-arm64|ubuntu-[0-9.]+-arm|ubuntu-24\.04-arm|linux/arm64)'
}

function Get-ReleaseMatrixFinding {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $dir = Join-Path $ProjectRoot '.github\workflows'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $issues = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yml', '.yaml') } | Select-Object -First 40)) {
        $text = ''
        try { $text = [IO.File]::ReadAllText($file.FullName) } catch { continue }
        $isRelease = $file.Name -match '(?i)release' -or $text -match '(?im)^name:\s*["'']?[^\n]*release' -or $text -match '(?ms)^\s*push:\s*$.{0,200}?^\s*tags:'
        if (-not $isRelease) { continue }
        $found = New-Object System.Collections.Generic.List[string]
        $m = [regex]::Match($text, $script:ReleaseBit32Pattern)
        if ($m.Success) { [void]$found.Add('32-bit ' + $m.Value) }
        $m = [regex]::Match($text, $script:ReleaseMacPattern)
        if ($m.Success) { [void]$found.Add('macOS ' + $m.Value) }
        # arm64 gaps only where the matching x64 target is already built.
        if ($text -match '(?i)(windows-|pc-windows|win-x64)') { if ($text -notmatch $script:ReleaseArmPatterns['Windows arm64']) { [void]$found.Add('no Windows arm64') } }
        if ($text -match '(?i)(ubuntu-|unknown-linux|linux-x64|linux/amd64)') { if ($text -notmatch $script:ReleaseArmPatterns['Linux arm64']) { [void]$found.Add('no Linux arm64') } }
        if ($found.Count -gt 0) { [void]$issues.Add('- ' + $file.Name + ': ' + ($found -join '; ')) }
    }
    return @($issues)
}

# One note per finding set per project, or ''.
function Get-ReleaseMatrixNote {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $issues = @(Get-ReleaseMatrixFinding -ProjectRoot $ProjectRoot)
    if ($issues.Count -eq 0) { return '' }
    $note = 'RELEASE MATRIX: Windows+Linux x64/arm64; no 32-bit/macOS unless asked (global-architecture-rules.md Release build matrix).' + "`n" + ($issues -join "`n")
    $state = Join-Path $env:LOCALAPPDATA ('HookMaker\state\GithubBaselineCheck-matrix-' + (Get-ShortHash $ProjectRoot.ToLowerInvariant()) + '.txt')
    $fp = Get-ShortHash $note
    try { if ([IO.File]::Exists($state) -and ([IO.File]::ReadAllText($state)).Trim() -eq $fp) { return '' } } catch { }
    try { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $state)); [IO.File]::WriteAllText($state, $fp) } catch { }
    return $note
}
