# Bounded local heuristic, not a YAML/expression evaluator or successful-CI proof.
# Unknown conditions, unsupported structure and incomplete reads never establish CI.
function Get-ManualWorkflowJobs {
    param([string[]]$Lines)
    $jobs = New-Object 'System.Collections.Generic.List[object]'
    $inJobs = $false; $indent = -1; $body = @()
    foreach ($line in @($Lines) + @('END_OF_WORKFLOW')) {
        if ($line -match '^jobs:\s*(?:#.*)?$') { $inJobs = $true; continue }
        if ($line.Trim() -eq '' -or $line.TrimStart().StartsWith('#')) { continue }
        $depth = $line.Length - $line.TrimStart(' ').Length
        $next = $inJobs -and $line -match '^ +[A-Za-z0-9_-]+:\s*(?:#.*)?$' -and ($indent -lt 0 -or $depth -eq $indent)
        if ($body.Count -and ($next -or $depth -eq 0)) {
            [void]$jobs.Add([pscustomobject]@{ Indent = $indent; Lines = $body })
            $body = @()
        }
        if ($depth -eq 0) { $inJobs = $false }
        if ($next) { $indent = $depth; $body = @($line) }
        elseif ($inJobs -and $body.Count) { $body += $line }
    }
    return $jobs.ToArray()
}

function Test-ManualWorkflowValidation {
    param([string[]]$Lines)
    $keyword = '(?i)\b(test|lint|typecheck|type-check|build|verify|check)\b'
    # Each step is examined independently; a nested with.run cannot count.
    $stepIndent = -1; $step = @(); $steps = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in @($Lines) + @('END_OF_STEPS')) {
        $depth = $line.Length - $line.TrimStart(' ').Length
        $next = $line -match '^ +-\s+\S' -and ($stepIndent -lt 0 -or $depth -eq $stepIndent)
        if ($step.Count -and ($next -or $depth -eq 0)) { [void]$steps.Add(@($step)); $step = @() }
        if ($next) { $stepIndent = $depth; $step = @($line) }
        elseif ($step.Count) { $step += $line }
    }
    foreach ($entry in $steps) {
        $text = $entry -join "`n"
        if ($text -match '(?im)^\s*(?:-\s*)?["'']?(?:if|continue-on-error)["'']?\s*:') { continue }
        for ($i = 0; $i -lt $entry.Count; $i++) {
            $line = [string]$entry[$i]
            if ($line -notmatch '^(?<indent> *)(?:-\s*)?(?<kind>run|uses):\s*(?<rest>.*)$') { continue }
            $depth = $Matches['indent'].Length
            if ($depth -ne $stepIndent -and $depth -ne ($stepIndent + 2)) { continue }
            $kind = $Matches['kind']; $rest = $Matches['rest'].Trim()
            if ($rest.StartsWith('#')) { continue }
            if ($kind -eq 'uses' -and $rest -match '\.github/workflows/') { continue }
            if ($rest -notmatch '^[|>][+-]?\d*\s*$') {
                if ($rest -match $keyword) { return $true }
                continue
            }
            for ($j = $i + 1; $j -lt [Math]::Min($entry.Count, $i + 40); $j++) {
                $nextLine = [string]$entry[$j]
                if ($nextLine.Trim() -eq '') { continue }
                if (($nextLine.Length - $nextLine.TrimStart(' ').Length) -le ($stepIndent + 2)) { break }
                if ($nextLine.TrimStart().StartsWith('#')) { continue }
                if ($nextLine -match $keyword) { return $true }
            }
        }
    }
    return $false
}

function Get-ManualWorkflowState {
    param([string]$ProjectRoot)
    $answer = [pscustomobject]@{ Compliant = $false; HasValidation = $false; Complete = $true; Problems = @() }
    $dir = Join-Path $ProjectRoot '.github/workflows'
    if (-not [IO.Directory]::Exists($dir)) { return $answer }
    $nodes = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $automatic = $false
    try {
        if (([IO.File]::GetAttributes($dir) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked workflow directory' }
        $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop | Where-Object { $_.Extension -in @('.yml', '.yaml') } | Select-Object -First 51)
        if ($files.Count -gt 50) { throw 'Workflow file limit' }
        foreach ($file in $files) {
            $reader = $null
            try {
                if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked workflow file' }
                $stream = [IO.File]::OpenRead($file.FullName)
                $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false)
                if ($stream.Length -gt 262144) { throw 'Workflow byte limit' }
                $buffer = New-Object char[] 262145
                $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
                if ($length -gt 262144 -or $stream.Length -gt 262144) { throw 'Workflow read limit' }
                $text = ([string]::new($buffer, 0, $length)).TrimStart([char]0xFEFF)
            }
            catch { $answer.Complete = $false; continue }
            finally { if ($null -ne $reader) { $reader.Dispose() } }
            $triggers = @(Get-WorkflowTopTriggers $text)
            if ($triggers.Count -eq 0 -or $text -match '(?m)^\t|^ *<<:|^ *[A-Za-z0-9_-]+:\s*[&*][A-Za-z0-9_-]+\s*(?:#.*)?$') { $answer.Complete = $false }
            if (@($triggers | Where-Object { $_ -cnotin @('workflow_dispatch', 'workflow_call') }).Count) { $automatic = $true }
            $calls = New-Object 'System.Collections.Generic.List[string]'; $valid = $false
            $jobs = @(Get-ManualWorkflowJobs @($text -split '\r?\n'))
            if ($jobs.Count -eq 0) { $answer.Complete = $false }
            foreach ($job in $jobs) {
                $body = $job.Lines -join "`n"
                $property = '^ {' + ($job.Indent + 2) + '}'
                # No invented evaluation of expressions, needs or conditional execution.
                if ($body -match ('(?im)' + $property + '["'']?(?:if|needs|continue-on-error)["'']?\s*:')) { continue }
                $uses = [regex]::Match($body, '(?m)' + $property + 'uses:\s*(?<value>[^\r\n]+)')
                if ($uses.Success) {
                    $value = $uses.Groups['value'].Value
                    if ($value -cmatch '^[''"'']?\./\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)[''"'']?\s*(?:#.*)?$') { [void]$calls.Add($Matches[1]) }
                    else { $answer.Complete = $false }
                }
                elseif (Test-ManualWorkflowValidation $job.Lines) { $valid = $true }
            }
            $nodes[$file.Name] = [pscustomobject]@{ Triggers = $triggers; Calls = $calls.ToArray(); Validation = $valid }
        }
    }
    catch { $answer.Complete = $false }
    if ($automatic) { $answer.Problems += 'Automatic CI initiating trigger exists; all hosts require workflow_dispatch.' }
    $roots = @($nodes.Keys | Where-Object { $nodes[$_].Triggers -ccontains 'workflow_dispatch' })
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($root in $roots) { $queue.Enqueue($root) }
    while ($queue.Count) {
        $key = $queue.Dequeue(); if (-not $seen.Add($key)) { continue }
        $node = $nodes[$key]; if ($node.Validation) { $answer.HasValidation = $true }
        foreach ($child in $node.Calls) {
            if (-not $nodes.ContainsKey($child) -or $nodes[$child].Triggers -cnotcontains 'workflow_call') { $answer.Complete = $false; continue }
            $queue.Enqueue($child)
        }
    }
    # Remove leaves iteratively: any reachable remainder is a cycle. At most 50 passes.
    $pending = @($seen)
    for ($pass = 0; $pass -lt 50 -and $pending.Count; $pass++) {
        $leaves = @($pending | Where-Object { @($nodes[$_].Calls | Where-Object { $pending -ccontains $_ }).Count -eq 0 })
        if ($leaves.Count -eq 0) { $answer.Complete = $false; break }
        $pending = @($pending | Where-Object { $leaves -cnotcontains $_ })
    }
    if (-not $answer.Complete) { $answer.Problems += 'Manual workflow reachability is UNKNOWN (unreadable, over-limit, unsupported or cyclic structure); inspect the actual workflows.' }
    $answer.Compliant = $answer.Complete -and -not $automatic -and $roots.Count -gt 0 -and $answer.HasValidation
    return $answer
}

function Test-ManualCiRepository {
    param([string]$ProjectRoot)
    return (Get-ManualWorkflowState $ProjectRoot).Compliant
}
