# Diagnostic discovery only. An immutable blob identity is not an effect proof.
function Assert-EvidencePhysicalPath {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if (((Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse paths cannot establish an evidence boundary.' }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Test-EvidenceProtectedPath {
    param([string]$Path)
    return $Path -match '(?i)(^|/)(\.ai|\.specify|specs|plans|\.claude|\.codex|\.kiro|\.agents|\.cursor|\.cline|graphify-out|\.codebase-memory|\.ignoreme|secrets\.md|explain-AI\.md|CLAUDE\.md|AGENTS\.md|reference\.md|\.env(?:\.[^/]+)?)(/|$)|\.(pem|key|pfx|p12)$'
}
function Invoke-EvidenceGit {
    param([string[]]$Arguments)
    $left = $script:EvidenceDeadline - [DateTime]::UtcNow
    if ($left.TotalSeconds -le 0) { throw 'Evidence deadline exhausted.' }
    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = 'git'
        $info.Arguments = ConvertTo-Win32ArgumentString (@('--no-lazy-fetch','--no-replace-objects','-c','core.quotePath=false','-c','color.ui=false','-c','core.fsmonitor=false','-c','core.pager=cat','-C',$script:EvidenceRoot) + $Arguments)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $utf8 = [Text.UTF8Encoding]::new($false,$true)
        $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
        $info.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
        $info.EnvironmentVariables['GIT_NO_REPLACE_OBJECTS'] = '1'
        $info.EnvironmentVariables['GIT_NO_LAZY_FETCH'] = '1'
        $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
        $process = [Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $timeout = [Math]::Min(5000,$left.TotalMilliseconds)
        $buffers = @((New-Object char[] 4096),(New-Object char[] 4096))
        $readers = @($process.StandardOutput,$process.StandardError)
        $tasks = @($readers[0].ReadAsync($buffers[0],0,4096),$readers[1].ReadAsync($buffers[1],0,4096))
        $ended = @($false,$false); $bytes = 0; $text = New-Object Text.StringBuilder
        while (-not ($ended[0] -and $ended[1] -and $process.HasExited)) {
            if ($timer.ElapsedMilliseconds -ge $timeout) { throw 'Bounded Git query timed out.' }
            $pending = @($tasks | Where-Object { $null -ne $_ })
            if ($pending.Count -gt 0) { [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$pending,50) }
            else { [void]$process.WaitForExit(50) }
            for ($i=0; $i -lt 2; $i++) {
                if ($ended[$i] -or -not $tasks[$i].IsCompleted) { continue }
                $count = $tasks[$i].GetAwaiter().GetResult()
                if ($count -eq 0) { $ended[$i]=$true; $tasks[$i]=$null; continue }
                $chunk = New-Object string($buffers[$i],0,$count)
                $bytes += $utf8.GetByteCount($chunk)
                if ($bytes -gt 16777216) { throw 'Git query output exceeds 16 MiB.' }
                if ($i -eq 0) { [void]$text.Append($chunk) }
                $tasks[$i] = $readers[$i].ReadAsync($buffers[$i],0,4096)
            }
        }
        if ($process.ExitCode -notin @(0,1) -or ($process.ExitCode -eq 1 -and $Arguments[0] -ne 'grep')) { throw 'Git evidence query failed.' }
        return $text.ToString()
    }
    finally {
        if ($null -ne $process) {
            if (-not $process.HasExited) {
                $process.Kill()
                if (-not $process.WaitForExit(2000)) { throw 'Git query termination could not be verified.' }
            }
            $process.Dispose()
        }
    }
}
function Get-EvidenceCategory {
    param([string]$Path)
    if ($Path -match '^\.github/workflows/[^/]+\.ya?ml$') { return 'workflow' }
    if ($Path -match '(^|/)(Cargo\.(toml|lock)|package(?:-lock)?\.json|[^/]*config\.[^/]+|build\.rs|requirements[^/]*\.txt|pyproject\.toml|CMakeLists\.txt|Makefile)$') { return 'build-manifest' }
    return 'reader-reference'
}
function Get-EvidenceOperations {
    param([string]$Text,[string]$Category)
    $patterns = [ordered]@{
        'file-read' = 'readFile|read_text|read_bytes|read_to_string|ReadAllText|Get-Content|\bopen\s*\(|fopen|ifstream|File\.read|File\.Read|storage::bytes|storage::read'
        'path-discovery' = 'rglob\s*\(|glob\s*\(|read_dir|walkdir|os\.walk|readdir|ls-files|ls-tree|import\.meta\.glob'
        'embedded-input' = 'include_str!|include_bytes!|\binclude!|doctest|mdx|markdown-loader|md-loader|long_description|readme\s*='
        'external-execution' = 'Command::new|subprocess\.|Start-Process|Invoke-OwnedProcess|tauri_build::|\b(?:exec|spawn)\s*\('
        'dependency-declaration' = '\[.*dependencies\]|"(?:devDependencies|dependencies|scripts)"\s*:|^\s*(?:requires|build-backend)\s*='
    }
    if ($Category -eq 'workflow') {
        $patterns['workflow-command'] = '^\s*-?\s*run\s*:'
        $patterns['workflow-action'] = '^\s*-?\s*uses\s*:'
    }
    $operations = New-Object System.Collections.Generic.List[object]
    $lines = $Text -split "`r?`n"
    for ($line=0; $line -lt $lines.Count; $line++) {
        if ([DateTime]::UtcNow -ge $script:EvidenceDeadline) { return [pscustomobject]@{Items=$operations.ToArray();Truncated=$true} }
        foreach ($kind in $patterns.Keys) {
            if ($lines[$line] -match $patterns[$kind]) {
                if ($operations.Count -ge 1000) { return [pscustomobject]@{Items=$operations.ToArray();Truncated=$true} }
                [void]$operations.Add([pscustomobject]@{line=$line+1;kind=$kind})
            }
        }
    }
    return [pscustomobject]@{Items=$operations.ToArray();Truncated=$false}
}
function Get-CiInputEvidence {
    param([string]$Root,[string]$Commit,[string[]]$Documents,[int]$TimeoutSeconds,[int]$MaxCandidates,[long]$MaxContentBytes)
    $script:EvidenceRoot = $Root
    $script:EvidenceDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $exact = (Invoke-EvidenceGit @('rev-parse','--verify',($Commit+'^{commit}'))).Trim()
    if ($exact -cne $Commit) { throw 'Requested exact commit is not available locally.' }
    $treeId = (Invoke-EvidenceGit @('rev-parse',($Commit+'^{tree}'))).Trim()
    $raw = Invoke-EvidenceGit @('ls-tree','-r','-z','--long',$Commit)
    $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $unsupported = 0; $protected = 0
    foreach ($row in $raw.Split([char]0)) {
        if ($row -eq '') { continue }
        if ([DateTime]::UtcNow -ge $script:EvidenceDeadline) { throw 'Tree inventory deadline exhausted before complete discovery.' }
        if ($entries.Count -ge 100000) { throw 'Tree evidence exceeds 100000 entries.' }
        $m = [regex]::Match($row,'^(?<mode>[0-7]{6}) (?<type>blob|commit) (?<blob>[a-f0-9]{40,64})\s+(?<size>\d+|-)\t(?<path>.+)$',[Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $m.Success) { throw 'Unsupported tree record serialization.' }
        $path = $m.Groups['path'].Value
        if ($path -match '[\x00-\x1f\x7f\\]' -or $path.Length -gt 4096) { throw 'Unsupported tracked path encoding.' }
        $item = [pscustomobject]@{path=$path;blob=$m.Groups['blob'].Value;mode=$m.Groups['mode'].Value;size=0L;category=(Get-EvidenceCategory $path);operations=@();inspection='pending'}
        if ($m.Groups['type'].Value -ne 'blob' -or $item.mode -notin @('100644','100755')) { $unsupported++; $item.inspection='unsupported' }
        else { $item.size=[long]$m.Groups['size'].Value }
        if (Test-EvidenceProtectedPath $path) { $protected++ }
        $entries[$path]=$item
    }
    foreach ($doc in $Documents) {
        if (-not $entries.ContainsKey($doc) -or $entries[$doc].mode -notin @('100644','100755')) { throw 'Document must be a regular tracked blob at the requested commit.' }
    }
    $argsList = @('grep','--threads=1','-I','-l','-z','-i','-E','-e','readFile|read_text|read_bytes|read_to_string|ReadAllText|Get-Content|open[[:space:]]*\(|storage::bytes|storage::read|rglob|glob[[:space:]]*\(|read_dir|walkdir|os\.walk|readdir|ls-files|ls-tree|include_str!|include_bytes!|doctest|mdx|long_description|markdown|Command::new|subprocess\.|tauri_build::')
    $excludes = @($entries.Keys | Where-Object { (Test-EvidenceProtectedPath $_) -or $entries[$_].inspection -eq 'unsupported' } | ForEach-Object { ':(exclude,literal)' + $_ })
    if (($excludes -join ' ').Length -gt 16000) { throw 'Protected path exclusions exceed the safe query argument budget.' }
    $readers = Invoke-EvidenceGit ($argsList + @($Commit,'--','.') + $excludes)
    $literalArgs = @('grep','--threads=1','-I','-l','-z','-i','-F')
    foreach ($doc in $Documents) { $literalArgs += @('-e',$doc,'-e',[IO.Path]::GetFileName($doc)) }
    $references = Invoke-EvidenceGit ($literalArgs + @($Commit,'--','.') + $excludes)
    $candidatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($value in @($readers,$references)) {
        foreach ($hit in $value.Split([char]0)) {
            if ($hit -eq '') { continue }
            if (-not $hit.StartsWith($Commit+':',[StringComparison]::Ordinal)) { throw 'Grep evidence does not belong to the exact commit.' }
            [void]$candidatePaths.Add($hit.Substring($Commit.Length+1))
        }
    }
    foreach ($path in $entries.Keys) {
        if ([DateTime]::UtcNow -ge $script:EvidenceDeadline) { throw 'Candidate discovery deadline exhausted.' }
        if ($entries[$path].category -ne 'reader-reference') { [void]$candidatePaths.Add($path) }
    }
    $inputs = New-Object System.Collections.Generic.List[object]
    $inspected = 0; $bytes = 0L; $partial = $false; $reasons = @('Arbitrary executable/import/dependency effects are unproved.','Regex discovery is not a complete semantic input analysis.')
    if ($unsupported -gt 0) { $partial=$true; $reasons += 'Tracked symlink or submodule inputs are unsupported.' }
    if ($protected -gt 0) { $partial=$true; $reasons += 'Protected tracked inputs were not inspected.' }
    # Prioritize workflow/build roots, but keep every reader candidate in the report.
    $ordered = @($candidatePaths | Sort-Object @{Expression={if ($entries[$_].category -eq 'workflow') {0} elseif ($entries[$_].category -eq 'build-manifest') {1} else {2}}}, @{Expression={$_}})
    foreach ($path in $ordered) {
        if ([DateTime]::UtcNow -ge $script:EvidenceDeadline) { $partial=$true; $reasons += 'Deadline exhausted; remaining candidate details omitted.'; break }
        if ($inputs.Count -ge 5000) { $partial=$true; $reasons += 'Candidate detail output capped at 5000; remaining candidates counted only.'; break }
        if (-not $entries.ContainsKey($path)) { throw 'Reader candidate absent from immutable tree inventory.' }
        $item = $entries[$path]
        if (Test-EvidenceProtectedPath $path) { continue }
        if ($item.inspection -eq 'unsupported') { [void]$inputs.Add($item); continue }
        if ($inspected -ge $MaxCandidates -or $bytes+$item.size -gt $MaxContentBytes -or [DateTime]::UtcNow -ge $script:EvidenceDeadline) { $partial=$true; $item.inspection='budget'; [void]$inputs.Add($item); continue }
        try {
            $text = Invoke-EvidenceGit @('cat-file','blob',$item.blob)
            if ([Text.Encoding]::UTF8.GetByteCount($text) -ne $item.size) { throw 'Blob text length differs from immutable tree size.' }
            $bytes += $item.size; $inspected++
            $found = Get-EvidenceOperations $text $item.category
            $item.operations=@($found.Items); $item.inspection='inspected'
            if ($found.Truncated) { $partial=$true; $reasons += 'Operation evidence truncated at 1000 entries for one input.' }
        } catch { $partial=$true; $item.inspection='unavailable'; $reasons += 'One or more candidate blobs could not be read within strict encoding/query bounds.' }
        [void]$inputs.Add($item)
    }
    if (@($inputs | Where-Object inspection -eq 'budget').Count -gt 0) { $reasons += 'Inspection budget exhausted; candidates retained without discharging them.' }
    return [pscustomobject][ordered]@{
        schema=1;toolVersion=1;commit=$Commit;tree=$treeId;generatedUtc=[DateTime]::UtcNow.ToString('o')
        verdict='UNKNOWN';gateWaived=$false;discovery=$(if ($partial) {'partial'} else {'complete'})
        documents=@($Documents);coverage=@{treeEntries=$entries.Count;candidates=$candidatePaths.Count;inspected=$inspected;contentBytes=$bytes;protectedInputs=$protected;unsupportedInputs=$unsupported}
        limits=@{timeoutSeconds=$TimeoutSeconds;querySeconds=5;queryOutputBytes=16777216;maxContentBytes=$MaxContentBytes;maxCandidates=$MaxCandidates;workers=1}
        unresolved=@($reasons | Sort-Object -Unique);inputs=@($inputs.ToArray())
    }
}
