# Invocation-local read-only transport, not CI results or proof. Definitions only.
# Call Initialize-CiApiBatch once before the invocation's deadline is initialized.
function Initialize-CiApiBatch {
    $script:CiApiBatchState = @{
        Seen = (New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
        Cache = (New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal))
        Bytes = [long]0; Reserved = [long]0; Exhausted = $false; Busy = $false; PeakLive = 0
    }
    try {
        if (-not ('HookMaker.CiBatchJson' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot '_cibatchjson.cs') -ErrorAction Stop
        }
    }
    catch { $script:CiApiBatchState.Exhausted = $true }
}

function Test-CiBatchEndpoint {
    param([string]$Endpoint)
    if ([string]::IsNullOrWhiteSpace($Endpoint) -or $Endpoint.Length -gt 2048) { return $false }
    # No URL, fragment, headers, arbitrary query keys, dot segments or gh expansion.
    $parts = $Endpoint.Split('?')
    if ($parts.Count -gt 2) { return $false }
    $prefix = '^repos/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+/'
    $tail = '(?:actions/runs(?:/[1-9][0-9]*(?:/attempts/[1-9][0-9]*/jobs|/jobs)?)?|commits/[0-9a-fA-F]{40}/(?:check-runs|status)|check-runs/[1-9][0-9]*/annotations|(?:branches|rules/branches)/[A-Za-z0-9_%./-]+)$'
    if ($parts[0] -cnotmatch ($prefix+$tail)) { return $false }
    foreach ($segment in ($parts[0] -split '/')) {
        try { $decoded = [Uri]::UnescapeDataString($segment) } catch { return $false }
        if ($decoded -match '(^|/)\.{1,2}(/|$)' -or $decoded -match '[\x00-\x20\x7f\\?#{}]' -or $decoded.Contains('%')) { return $false }
    }
    if ($parts.Count -eq 2) {
        $keys = @{}
        foreach ($pair in ($parts[1] -split '&')) {
            if ($pair -cnotmatch '^(per_page|page|head_sha|filter|status|event|branch)=([A-Za-z0-9_%./-]+)$') { return $false }
            $key = $Matches[1]; $value = $Matches[2]
            if ($keys.ContainsKey($key)) { return $false }; $keys[$key] = $true
            switch ($key) {
                'per_page' { if ($value -notmatch '^[0-9]{1,3}$' -or [int]$value -lt 1 -or [int]$value -gt 100) { return $false } }
                'page' { if ($value -notmatch '^[1-9][0-9]{0,5}$') { return $false } }
                'head_sha' { if ($value -notmatch '^[0-9a-fA-F]{40}$') { return $false } }
                'filter' { if ($value -cnotin @('latest','all')) { return $false } }
                'status' { if ($value -cnotin @('completed','queued','in_progress','requested','waiting','pending','action_required','cancelled','failure','neutral','skipped','stale','success','timed_out')) { return $false } }
                'event' { if ($value -cnotmatch '^[a-z][a-z_]{0,63}$') { return $false } }
                'branch' { if ($value -match '%(?![0-9a-fA-F]{2})') { return $false } }
            }
        }
    }
    return $true
}

function ConvertFrom-CiBatchJson {
    param([string]$Text)
    if (-not [HookMaker.CiBatchJson]::IsValid($Text)) { throw 'Invalid CI API JSON.' }
    # Preserve [] and single-element arrays on both supported PowerShell hosts.
    $wrapped = ConvertFrom-Json -InputObject ('{"value":'+$Text+'}') -ErrorAction Stop
    if ($null -eq $wrapped.value) { throw 'Null CI API response.' }
    return ,$wrapped.value
}

function New-CiBatchProcessInfo {
    param([string]$Endpoint)
    # Match Invoke-QuietCommand's PATH resolution, including same-host gh.ps1.
    $resolved = @(Get-Command gh -ErrorAction Stop | Where-Object { $_.CommandType -in @('Application','ExternalScript') })
    if ($resolved.Count -eq 0) { throw 'GitHub CLI unavailable.' }
    $target = [string]$resolved[0].Source
    # No fields/body/method switches: gh api defaults GET, including old shims.
    $arguments = @('api',$Endpoint)
    $extension = [IO.Path]::GetExtension($target).ToLowerInvariant()
    $cmdLine = $null
    if ($extension -eq '.ps1') {
        $arguments = @('-NoLogo','-NoProfile','-File',$target)+$arguments
        $target = [string](Get-Process -Id $PID).Path
    }
    elseif ($extension -in @('.cmd','.bat')) {
        $cmdLine = '/s /c "'+(ConvertTo-Win32ArgumentString (@($target)+$arguments))+'"'
        $target = Join-Path $env:SystemRoot 'System32/cmd.exe'
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $target
    $info.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    if ($null -ne $cmdLine) { $info.Arguments = $cmdLine }
    elseif ($info.PSObject.Properties.Name -contains 'ArgumentList') { foreach ($arg in $arguments) { [void]$info.ArgumentList.Add($arg) } }
    else { $info.Arguments = ConvertTo-Win32ArgumentString $arguments }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    return $info
}

function Get-CiBatchMilliseconds {
    param([DateTime]$Deadline)
    return [int][Math]::Max(0,[Math]::Min(($Deadline-[DateTime]::UtcNow).TotalMilliseconds,1000.0*(Get-GhRemainingSeconds)))
}

function Start-CiBatchRead {
    param([object]$Request,[int]$Stream,[object]$State)
    # Charge each outstanding raw read BEFORE it starts. A failed/cancelled read
    # retains this conservative charge: retries cannot hide undrained bytes.
    $available = [Math]::Min(1048576-$Request.Bytes,4194304-$State.Bytes)
    # Pending stderr reservations are not observed bytes: subtracting them made
    # a valid stdout tail drain one byte at a time (or deadlock before EOF).
    # Actual combined bytes are checked before retention; failures conservatively
    # charge outstanding reads, so retries cannot hide undrained output.
    $size = [int][Math]::Min(65536,[Math]::Max(1,$available))
    $State.Reserved += $size; $Request.Reserved[$Stream] = $size
    return $Request.Streams[$Stream].ReadAsync($Request.Buffers[$Stream],0,$size)
}

function Close-CiBatchProcess {
    param([object]$Request,[DateTime]$Deadline,[switch]$Completed)
    $clean = $false
    try {
        if ($Completed -and $Request.Process.HasExited -and $Request.Ended[0] -and $Request.Ended[1]) { $clean=$true }
        $left = Get-CiBatchMilliseconds $Deadline
        if (-not $clean -and $null -ne $Request.Created -and $left -gt 0) {
            # _processtree pins birth identities on every parent edge and kill.
            # Retain our root handle even after exit, so inherited pipes remain owned.
            $cleanup = Stop-ProcessTree -ProcessId $Request.Process.Id -RootCreated $Request.Created -TimeoutMilliseconds ([int][Math]::Min(2000,$left))
            $clean = $null -ne $cleanup -and $cleanup.Cleared
        }
        if (-not $clean -and -not $Request.Process.HasExited) { $Request.Process.Kill() }
    }
    catch { $clean = $false }
    finally {
        # Close pending raw reads too; never wait unboundedly for inherited EOF.
        foreach ($stream in $Request.Streams) { try { $stream.Dispose() } catch { } }
        foreach ($buffer in $Request.Output) { $buffer.Dispose() }
        $Request.Process.Dispose()
    }
    return $clean
}

function Invoke-CiApiBatch {
    param([AllowEmptyCollection()][string[]]$Endpoints,[string]$ScopeKey)
    $global:LASTEXITCODE = 1
    $stateVar = Get-Variable CiApiBatchState -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $stateVar -or $stateVar.Value.Busy -or $stateVar.Value.Exhausted -or [string]::IsNullOrWhiteSpace($ScopeKey) -or $ScopeKey.Length -gt 8192) { return $null }
    $state = $stateVar.Value
    if ($null -eq $Endpoints) { return $null }
    $wanted = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($endpoint in $Endpoints) {
        if (-not (Test-CiBatchEndpoint $endpoint)) { return $null }
        [void]$wanted.Add($endpoint)
    }
    $new = @($wanted | Where-Object { -not $state.Seen.Contains($_) })
    if ($state.Seen.Count+$new.Count -gt 32) { return $null }
    foreach ($endpoint in $new) { [void]$state.Seen.Add($endpoint) }
    $result = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $pending = New-Object 'Collections.Generic.Queue[string]'
    $wire = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $live = New-Object 'Collections.Generic.List[object]'
    $completed = New-Object 'Collections.Generic.List[object]'
    $utf8 = New-Object Text.UTF8Encoding($false,$true)
    $left = Get-GhRemainingSeconds
    if ($left -lt 1) { $script:GhBudgetExhausted = $true; $global:LASTEXITCODE = 124; return $null }
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(40,$left))
    $state.Busy = $true; $cleanupVerified = $false
    try {
        foreach ($endpoint in $wanted) {
            $cacheKey = $ScopeKey.Length.ToString()+':'+$ScopeKey+$endpoint
            if ($state.Cache.ContainsKey($cacheKey)) { $result[$endpoint] = ConvertFrom-CiBatchJson $state.Cache[$cacheKey] }
            else { $pending.Enqueue($endpoint) }
        }
        while ($pending.Count -gt 0 -or $live.Count -gt 0) {
            # Reserve cleanup INSIDE the original shared deadline, not after it.
            $reserve = 2000*[Math]::Min(4,[Math]::Max(1,$live.Count+$pending.Count))
            if ((Get-CiBatchMilliseconds $deadline) -le $reserve) { throw 'CI API deadline exhausted.' }
            while ($pending.Count -gt 0 -and $live.Count -lt 4) {
                if ((Get-CiBatchMilliseconds $deadline) -le 2000*($live.Count+1)) { throw 'CI API deadline exhausted.' }
                if ($state.Bytes -ge 4194304) { $state.Exhausted=$true; throw 'CI API response byte limit exceeded.' }
                $endpoint = $pending.Dequeue()
                $process = New-Object Diagnostics.Process
                $request = @{ Endpoint=$endpoint; Process=$process; Created=$null; Bytes=[long]0; Streams=@(); Output=@(); Tasks=@(); Buffers=@(); Reserved=@(0,0); Ended=@($false,$false) }
                [void]$live.Add($request)
                $process.StartInfo = New-CiBatchProcessInfo $endpoint
                if (-not $process.Start()) { throw 'CI API process unavailable.' }
                $null = $process.Handle
                $request.Created = $process.StartTime.ToUniversalTime()
                $process.StandardInput.Close()
                $request.Streams = @($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
                $request.Output = @((New-Object IO.MemoryStream),(New-Object IO.MemoryStream))
                $request.Buffers = @((New-Object byte[] 65536),(New-Object byte[] 65536))
                $request.Tasks = @((Start-CiBatchRead $request 0 $state),(Start-CiBatchRead $request 1 $state))
                $state.PeakLive = [Math]::Max($state.PeakLive,$live.Count)
            }
            $tasks = New-Object 'Collections.Generic.List[Threading.Tasks.Task]'
            foreach ($request in $live.ToArray()) {
                for ($i=0; $i -lt 2; $i++) {
                    if ($request.Ended[$i]) { continue }
                    if ($null -eq $request.Tasks[$i]) { $request.Tasks[$i] = Start-CiBatchRead $request $i $state }
                    if ($null -eq $request.Tasks[$i]) { continue }
                    if (-not $request.Tasks[$i].IsCompleted) { [void]$tasks.Add($request.Tasks[$i]); continue }
                    $count = $request.Tasks[$i].GetAwaiter().GetResult()
                    $state.Reserved -= $request.Reserved[$i]; $request.Reserved[$i]=0
                    $request.Bytes += $count; $state.Bytes += $count
                    if ($request.Bytes -gt 1048576 -or $state.Bytes -gt 4194304) { $state.Exhausted=$true; throw 'CI API response byte limit exceeded.' }
                    if ($count -eq 0) { $request.Ended[$i]=$true; continue }
                    $request.Output[$i].Write($request.Buffers[$i],0,$count)
                    $request.Tasks[$i] = Start-CiBatchRead $request $i $state
                    if ($null -ne $request.Tasks[$i]) { [void]$tasks.Add($request.Tasks[$i]) }
                }
                if ($request.Ended[0] -and $request.Ended[1] -and $request.Process.HasExited) {
                    if ($request.Process.ExitCode -ne 0) { throw 'CI API process failed.' }
                    $text = $utf8.GetString($request.Output[0].ToArray())
                    $null = $utf8.GetString($request.Output[1].ToArray())
                    $parsed = ConvertFrom-CiBatchJson $text
                    foreach ($stream in $request.Streams) { $stream.Dispose() }
                    foreach ($buffer in $request.Output) { $buffer.Dispose() }
                    $request.Streams=@(); $request.Output=@()
                    [void]$live.Remove($request); [void]$completed.Add($request)
                    $result[$request.Endpoint] = $parsed; $wire[$request.Endpoint] = $text
                }
            }
            if ($live.Count -gt 0) {
                $wait = [int][Math]::Min(25,[Math]::Max(0,(Get-CiBatchMilliseconds $deadline)-2000*$live.Count))
                if ($wait -le 0) { throw 'CI API deadline exhausted.' }
                if ($tasks.Count -gt 0) { [void][Threading.Tasks.Task]::WaitAny($tasks.ToArray(),$wait) }
                else { [void]$live[0].Process.WaitForExit($wait) }
            }
        }
        if ($completed.Count -gt 0) {
            $remainingMs = Get-CiBatchMilliseconds $deadline
            if ($remainingMs -lt 1000) { throw 'CI API cleanup deadline exhausted.' }
            $snapshot = Get-ProcessSnapshot -TimeoutSeconds ([int][Math]::Min(2,[Math]::Floor($remainingMs/1000)))
            if ($null -eq $snapshot -or @($snapshot).Count -eq 0) { throw 'CI API cleanup ownership unavailable.' }
            foreach ($entry in $snapshot) {
                if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['ProcessId'] -or $null -eq $entry.PSObject.Properties['ParentProcessId'] -or $null -eq $entry.PSObject.Properties['CreationDate']) { throw 'CI API cleanup snapshot incomplete.' }
            }
            foreach ($request in $completed.ToArray()) {
                $walk = Get-OwnedDescendantId -RootId $request.Process.Id -RootCreated $request.Created -Snapshot $snapshot
                if ($walk.Truncated -or $walk.Ids.Count -gt 0) {
                    [void]$completed.Remove($request)
                    $null = Close-CiBatchProcess $request $deadline
                    throw 'CI API descendant cleanup required.'
                }
            }
        }
        $cleanupVerified = $true
        # A partial batch cannot seed even positive cache entries.
        foreach ($endpoint in $wire.Keys) { $state.Cache[$ScopeKey.Length.ToString()+':'+$ScopeKey+$endpoint] = $wire[$endpoint] }
        $global:LASTEXITCODE = 0
        return ,$result
    }
    catch {
        if ((Get-CiBatchMilliseconds $deadline) -le 2000*[Math]::Max(1,$live.Count)) { $script:GhBudgetExhausted=$true; $global:LASTEXITCODE=124 }
        return $null
    }
    finally {
        foreach ($request in $live.ToArray()) {
            # Unobserved reservations remain charged even after process cleanup.
            $state.Bytes += $request.Reserved[0]+$request.Reserved[1]
            $state.Reserved -= $request.Reserved[0]+$request.Reserved[1]
            $null = Close-CiBatchProcess $request $deadline
        }
        foreach ($request in $completed.ToArray()) { $null = Close-CiBatchProcess $request $deadline -Completed:$cleanupVerified }
        $state.Busy = $false
        if(-not$cleanupVerified-and$global:LASTEXITCODE-eq0){$global:LASTEXITCODE=1}
    }
}

function Read-CiBatchApi {
    param([string]$Endpoint,[string]$ScopeKey)
    $batch = Invoke-CiApiBatch -Endpoints @($Endpoint) -ScopeKey $ScopeKey
    if ($null -eq $batch) { return $null }
    return ,$batch[$Endpoint]
}
