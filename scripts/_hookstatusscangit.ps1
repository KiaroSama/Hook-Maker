# ---------------------------------------------------------------------------
# Native Git discovery for the hook-status scan engine. Dot-sourced by
# _hookstatusscan.ps1 ONLY (which Get-HookStatus.ps1 dot-sources), so exactly
# like the rest of the engine it runs in the entry script's scope: $script:
# state and helpers resolve at CALL time. Do not dot-source this file
# directly.
#
# Responsibility: turn ONE repository root into raw native findings - resolve
# the .git directory (a real directory or a gitdir: pointer file), find the
# effective hooks path, and classify every native hook entrypoint. The `git
# config --get` child process below is the ONLY process the whole scanner
# ever starts: argument ARRAY (never a shell string), bounded timeout, clean
# fallback when git is absent - and `git config` cannot run a hook. Deciding
# WHICH repositories are visited is the walk's job (_hookstatusscan.ps1).
# ---------------------------------------------------------------------------

# ---- native Git discovery --------------------------------------------------

# `git config --get` with an argument ARRAY (never a shell string, so nothing in
# a repository path can be interpolated), a bounded timeout, and a clean
# fallback when git is absent. `git config` cannot run a hook.
$script:GitExecutable = $null
$script:GitProbed = $false
function Get-GitExecutable {
    if (-not $script:GitProbed) {
        $script:GitProbed = $true
        try {
            $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) { $script:GitExecutable = [string]$command.Source }
        }
        catch { $script:GitExecutable = $null }
    }
    return $script:GitExecutable
}

function Get-GitConfigValue {
    param([string]$RepositoryRoot, [string]$Name, [int]$TimeoutMs = 5000)
    $executable = Get-GitExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) { return '' }
    $process = $null
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $executable
        foreach ($argument in @('-C', $RepositoryRoot, 'config', '--get', $Name)) { [void]$info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        [void]$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill($true) } catch { }
            Add-ScanWarning ('git config timed out for repository: ' + $RepositoryRoot)
            return ''
        }
        if ($process.ExitCode -ne 0) { return '' }
        return ([string]$stdout.Result).Trim()
    }
    catch {
        Add-ScanWarning ('git could not be queried for ' + $RepositoryRoot + ': ' + $_.Exception.Message)
        return ''
    }
    finally { if ($null -ne $process) { try { $process.Dispose() } catch { } } }
}

# Fallback when git is unavailable: read core.hooksPath straight out of the
# repository's own config file. Deliberately a narrow INI read of one known key,
# not a general config parser.
function Get-HooksPathFromConfigFile {
    param([string]$GitDirectory)
    $configPath = Join-Path $GitDirectory 'config'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return '' }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) }
    catch { return '' }
    $inCore = $false
    foreach ($line in ($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[')) { $inCore = ($trimmed -match '^\[core(\s|\])'); continue }
        if (-not $inCore) { continue }
        $match = [regex]::Match($trimmed, '^hooksPath\s*=\s*(.+)$', 'IgnoreCase')
        if ($match.Success) { return $match.Groups[1].Value.Trim().Trim('"') }
    }
    return ''
}

# `.git` may be a directory OR a file containing `gitdir: <path>` (worktrees and
# submodules). Both are real repositories and both must be discovered.
function Resolve-GitDirectory {
    param([string]$RepositoryRoot)
    $dotGit = Join-Path $RepositoryRoot '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) { return (Get-CanonicalPathOrEmpty $dotGit) }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { return '' }
    $text = ''
    try {
        $item = Get-Item -LiteralPath $dotGit -Force -ErrorAction Stop
        # A `.git` pointer file is a single short line; anything larger is not
        # one and is not opened as text.
        if ($item.Length -gt 8192) { return '' }
        $text = [System.IO.File]::ReadAllText($dotGit, [System.Text.Encoding]::UTF8)
    }
    catch { return '' }
    $match = [regex]::Match($text, '(?im)^\s*gitdir\s*:\s*(.+?)\s*$')
    if (-not $match.Success) { return '' }
    $target = $match.Groups[1].Value.Trim()
    if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $RepositoryRoot $target }
    return (Get-CanonicalPathOrEmpty $target)
}

# Classify ONE native hook file.
#
# A Hook Maker wrapper is only claimed when the canonical generator REBUILDS the
# exact file from the stage list read back out of it - a marker line alone is
# not proof, because a tampered or hand-edited wrapper still carries the marker.
# That is why managedStages is populated only on an exact rebuild match.
function Get-NativeHookClassification {
    param([string]$HookPath)
    $result = [pscustomobject]@{ Classification = 'externalNativeHook'; ManagedStages = @() }
    $text = ''
    try {
        $item = Get-Item -LiteralPath $HookPath -Force -ErrorAction Stop
        if ($item.Length -gt 262144) { return $result }
        $text = [System.IO.File]::ReadAllText($HookPath, [System.Text.Encoding]::UTF8)
    }
    catch {
        $result.Classification = 'ambiguous'
        return $result
    }
    if ($text -notlike ('*' + $script:PrePushMarker + '*')) { return $result }

    $stages = @([regex]::Matches($text, '-File\s+"([^"]+)"\s+-GitPrePush') | ForEach-Object { $_.Groups[1].Value })
    if ($stages.Count -eq 0) {
        $result.Classification = 'ambiguous'
        return $result
    }
    $expected = ''
    try { $expected = New-PrePushWrapperBody -ManagedScripts $stages } catch { $expected = '' }
    if ($expected -ne '' -and (Compare-PrePushWrapperBody -Expected $expected -Actual $text)) {
        $result.Classification = 'hookMakerWrapper'
        $result.ManagedStages = @($stages | ForEach-Object { Get-CanonicalPathOrEmpty ($_.Replace('/', '\')) } | Where-Object { $_ -ne '' })
        return $result
    }
    # Marker present but the bytes are not what this generator produces: the
    # wrapper was edited or is from another writer. Reported, never claimed.
    $result.Classification = 'ambiguous'
    return $result
}

function Read-GitRepository {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $canonicalRoot = Get-CanonicalPathOrEmpty $RepositoryRoot
    if ($canonicalRoot -eq '') { return }
    $key = Get-CanonicalPathKey $canonicalRoot
    if ($key -eq '' -or -not $script:SeenGitKeys.Add($key)) { return }
    $gitDirectory = Resolve-GitDirectory -RepositoryRoot $canonicalRoot
    if ($gitDirectory -eq '') { return }
    $script:GitRepositoriesSeen++
    $script:CandidateRootsSeen++
    # Repaint here too, not only once per directory: the per-candidate
    # work below (settings parsing, one finding per registered hook)
    # grew long once projects held 22 hooks each, and with the only
    # call sitting in the directory walk the elapsed counter froze for
    # the whole of it and the scan read as hung. Show-ScanProgress is
    # throttled to 750 ms, so extra calls cost nothing.
    Show-ScanProgress

    $hooksPath = ''
    $configured = Get-GitConfigValue -RepositoryRoot $canonicalRoot -Name 'core.hooksPath'
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = Get-HooksPathFromConfigFile -GitDirectory $gitDirectory }
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $candidate = $configured
        if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $canonicalRoot $candidate }
        $hooksPath = Get-CanonicalPathOrEmpty $candidate
        if ($hooksPath -eq '') { Add-ScanWarning ('core.hooksPath could not be resolved for ' + $canonicalRoot) }
    }
    if ($hooksPath -eq '') { $hooksPath = Get-CanonicalPathOrEmpty (Join-Path $gitDirectory 'hooks') }
    if ($hooksPath -eq '' -or -not (Test-Path -LiteralPath $hooksPath -PathType Container)) { return }
    if (Test-IsReparsePoint -Path $hooksPath) {
        [void]$script:SkippedReparse.Add($hooksPath)
        return
    }

    $entries = @()
    try { $entries = @((New-Object System.IO.DirectoryInfo $hooksPath).EnumerateFiles()) }
    catch {
        [void]$script:Inaccessible.Add($hooksPath)
        Add-ScanWarning ('git hooks directory could not be listed: ' + $hooksPath)
        return
    }
    foreach ($entry in $entries) {
        # `*.sample` files are git's shipped examples: never installed, never
        # executed, and reporting them would bury the real hooks in noise.
        if ($entry.Name -like '*.sample') { continue }
        $classification = Get-NativeHookClassification -HookPath $entry.FullName
        [void]$script:NativeFindings.Add([pscustomobject]@{
            RepositoryRoot  = $canonicalRoot
            HooksPath       = $hooksPath
            HookName        = $entry.Name
            HookPath        = (Get-CanonicalPathOrEmpty $entry.FullName)
            HookHash        = (Get-FileSha256Hex -Path $entry.FullName)
            HookSize        = [int64]$entry.Length
            HookModifiedUtc = $entry.LastWriteTimeUtc.ToString('o')
            Classification  = $classification.Classification
            ManagedStages   = @($classification.ManagedStages)
        })
    }
}
