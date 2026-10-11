# Private Git transport: strict UTF-8, bounded output and the shared deadline.
# Unlike a tree-wide path count, these limits describe evidence we actually read.
function Invoke-DocsGitQuery {
    param([string[]]$Arguments)
    $left = Get-GhRemainingSeconds
    if ($left -lt 3) { $script:DocsCarryoverReason = 'unknown: shared evidence deadline exhausted'; $global:LASTEXITCODE = 124; return @() }
    $process = $null; $timer = [Diagnostics.Stopwatch]::StartNew()
    $limit = 1048576; $timeout = 1000 * [Math]::Min(5, [Math]::Max(1,$left - 2))
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = 'git'
        $info.Arguments = ConvertTo-Win32ArgumentString (@('-c','core.quotePath=false','-c','color.ui=false') + $Arguments)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $utf8 = New-Object Text.UTF8Encoding($false,$true)
        $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
        $process = [Diagnostics.Process]::Start($info)
        $created = $process.StartTime.ToUniversalTime(); $process.StandardInput.Close()
        $buffers = @((New-Object char[] 4096), (New-Object char[] 4096))
        $readers = @($process.StandardOutput, $process.StandardError)
        $text = New-Object Text.StringBuilder
        $tasks = @($readers[0].ReadAsync($buffers[0],0,4096), $readers[1].ReadAsync($buffers[1],0,4096))
        $ended = @($false,$false); $bytes = 0
        while (-not ($ended[0] -and $ended[1] -and $process.HasExited)) {
            if ($timer.ElapsedMilliseconds -ge $timeout) { throw 'query deadline exhausted' }
            $pending = @($tasks | Where-Object { $null -ne $_ })
            if ($pending.Count -gt 0) { [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$pending, [int][Math]::Min(100, $timeout - $timer.ElapsedMilliseconds)) }
            else { [void]$process.WaitForExit([int][Math]::Min(100, $timeout - $timer.ElapsedMilliseconds)) }
            for ($i = 0; $i -lt 2; $i++) {
                if ($ended[$i] -or -not $tasks[$i].IsCompleted) { continue }
                $count = $tasks[$i].GetAwaiter().GetResult()
                if ($count -eq 0) { $ended[$i] = $true; $tasks[$i] = $null; continue }
                $chunk = New-Object string($buffers[$i],0,$count)
                $bytes += $utf8.GetByteCount($chunk)
                if ($bytes -gt $limit) { throw 'query output exceeds 1 MiB' }
                if ($i -eq 0) { [void]$text.Append($chunk) }
                $tasks[$i] = $readers[$i].ReadAsync($buffers[$i],0,4096)
            }
        }
        $global:LASTEXITCODE = $process.ExitCode
        if ($process.ExitCode -notin @(0,1)) { $script:DocsCarryoverReason = 'unknown: Git evidence query failed' }
        return @($text.ToString() -split "`r?`n" | Where-Object { $_ -ne '' })
    }
    catch {
        $script:DocsCarryoverReason = 'unknown: bounded Git evidence unavailable (' + $_.Exception.Message + ')'
        $global:LASTEXITCODE = 124
        if ($null -ne $process) { try { $null = Stop-ProcessTree -ProcessId $process.Id -RootCreated $created -TimeoutMilliseconds ([Math]::Max(1,1000 * [Math]::Min(2,(Get-GhRemainingSeconds)))) } catch { } }
        return @()
    }
    finally { if ($null -ne $process) { $process.Dispose() } }
}
