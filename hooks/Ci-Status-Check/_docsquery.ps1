# Private Git transport: strict UTF-8, bounded output and the shared deadline.
# Unlike a tree-wide path count, these limits describe evidence we actually read.
function Initialize-DocsEvidenceCache {
    param([string]$ScopeKey)
    $script:DocsEvidenceScope=$ScopeKey
    $script:DocsEvidenceCache=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $script:DocsEvidenceBytes=0
}
function Get-DocsImmutableQueryKey {
    param([string[]]$Arguments)
    if(-not(Get-Variable DocsEvidenceScope -Scope Script -ErrorAction SilentlyContinue)-or$script:DocsEvidenceScope-eq''){return ''}
    if($Arguments.Count-lt4-or$Arguments[0]-cne'-C'){return ''}
    $verb=$Arguments[2];$tail=@($Arguments|Select-Object -Skip 3)
    # Exact immutable object reads only; mutable refs and working/index state
    # must still be acquired afresh by their owning identity/approval gates.
    $oid='(?:[a-f0-9]{40}|[a-f0-9]{64})'
    $safe=$false
    switch -CaseSensitive ($verb) {
        'show' {$safe=$tail.Count-eq1-and$tail[0]-cmatch('^'+$oid+':[^\r\n]+$')}
        'ls-tree' {
            $safe=($tail.Count-eq2-and$tail[0]-ceq'-r'-and$tail[1]-cmatch('^'+$oid+'$'))-or
                ($tail.Count-eq3-and$tail[0]-ceq'-r'-and$tail[1]-cin@('-l','--name-only')-and$tail[2]-cmatch('^'+$oid+'$'))-or
                ($tail.Count-eq5-and$tail[0]-ceq'-r'-and$tail[1]-ceq'--name-only'-and$tail[2]-cmatch('^'+$oid+'$')-and$tail[3]-ceq'--'-and$tail[4]-ceq'.github/workflows')
        }
        'rev-parse' {$safe=$tail.Count-eq1-and$tail[0]-cmatch('^'+$oid+'(?::[^\r\n]+|\^\{tree\})?$')}
        'log' {$safe=$tail.Count-eq3-and$tail[0]-ceq'-1'-and$tail[1]-ceq'--format=%B'-and$tail[2]-cmatch('^'+$oid+'$')}
        'rev-list' {$safe=(($tail.Count-eq3-and$tail[0]-ceq'--first-parent'-and$tail[1]-ceq'--max-count=9')-or($tail.Count-eq4-and$tail[0]-ceq'--parents'-and$tail[1]-ceq'-n'-and$tail[2]-ceq'1'))-and$tail[-1]-cmatch('^'+$oid+'$')}
        'diff' {$safe=$tail.Count-eq4-and$tail[0]-ceq'--name-only'-and$tail[1]-ceq'--no-renames'-and$tail[2]-cmatch('^'+$oid+'$')-and$tail[3]-cmatch('^'+$oid+'$')}
    }
    if(-not$safe){return ''}
    return $script:DocsEvidenceScope+'|'+(ConvertTo-Json -InputObject $Arguments -Compress)
}
function Save-DocsImmutableQuery {
    param([string]$Key,[string[]]$Lines)
    if($Key-eq''-or$LASTEXITCODE-ne0){return}
    $size=[Text.Encoding]::UTF8.GetByteCount(($Lines-join"`n"))
    if($script:DocsEvidenceCache.Count-ge256-or$script:DocsEvidenceBytes+$size-gt4194304){return}
    $script:DocsEvidenceCache[$Key]=[string[]]$Lines.Clone();$script:DocsEvidenceBytes+=$size
}
function Invoke-DocsGitQuery {
    param([string[]]$Arguments,[switch]$PreserveEmptyLines)
    $key=Get-DocsImmutableQueryKey $Arguments
    if($key-ne''-and$PreserveEmptyLines){$key+='|preserve-empty'}
    if($key-ne''-and$script:DocsEvidenceCache.ContainsKey($key)){$global:LASTEXITCODE=0;return $script:DocsEvidenceCache[$key]}
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
        if($PreserveEmptyLines){
            $content=$text.ToString()
            if($content.EndsWith("`n")){$content=$content.Substring(0,$content.Length-1);if($content.EndsWith("`r")){$content=$content.Substring(0,$content.Length-1)}}
            $lines=@($content -split "`r?`n")
        }else{$lines=@($text.ToString() -split "`r?`n" | Where-Object { $_ -ne '' })}
        Save-DocsImmutableQuery -Key $key -Lines $lines
        return $lines
    }
    catch {
        $script:DocsCarryoverReason = 'unknown: bounded Git evidence unavailable (' + $_.Exception.Message + ')'
        $global:LASTEXITCODE = 124
        if ($null -ne $process) { try { $null = Stop-ProcessTree -ProcessId $process.Id -RootCreated $created -TimeoutMilliseconds ([Math]::Max(1,1000 * [Math]::Min(2,(Get-GhRemainingSeconds)))) } catch { } }
        return @()
    }
    finally { if ($null -ne $process) { $process.Dispose() } }
}
