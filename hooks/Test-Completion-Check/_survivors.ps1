# Test-Completion-Check\_survivors.ps1 - POSSIBLE ORPHANED TEST PROCESSES.
#
# ROLE: DETECTOR / ADVISORY. It never blocks, never terminates a process, never
# reads process memory or environment, and writes nothing into the project. Its
# only outputs are a list of candidates and the instruction to run the sweep.
#
# WHY IT EXISTS. The gate in Test-Completion-Check.ps1 blocks on a still-active
# or unrecorded GUARDED run, which is correct and unchanged. A process started
# OUTSIDE the guarded runner - a raw pytest the guard did not recognise, a dev
# server, a browser, a detached batch - leaves no record anywhere, so that gate
# is blind to exactly the survivors that keep outliving a task
# (global-test-rules.md -> No Orphaned Test Processes).
#
# WHY IT IS ADVISORY AND NEVER A BLOCK. Ownership cannot be proven from outside
# a process. An image name in the pattern set that started after this session's
# baseline is a CANDIDATE, nothing more: the same list legitimately contains the
# user's own editor, a browser they opened to read documentation, or another
# agent's work. A gate must name the exact action that clears it; "decide
# whether one of these is yours" is not that, so this reports and the agent
# sweeps. Every block condition of the hook is untouched by this file.
#
# ADVISORY IS NOT FREE, WHICH THIS FILE LEARNED THE EXPENSIVE WAY. On Claude a
# Stop emission of ANY shape sends the turn back to the model: the client counts
# hookSpecificOutput.additionalContext at Stop as the turn being blocked from
# ending, exactly as it counts decision:block. So the cost of speaking here is a
# whole extra turn, and speaking repeatedly is a loop the client ends by
# overriding the hook. Two rules follow and both are load-bearing: never inside a
# continuation, and never twice for the same set of processes - where the SET
# must exclude the client's own cohort, whose pids are new on every event.
#
# BOUNDS. Exactly ONE Get-CimInstance Win32_Process call with its own operation
# timeout, a capped number of printed rows, a capped pattern count, and a
# bounded ancestor walk. A refused or timed-out query FAILS OPEN with an honest
# partial note - it never invents an all-clear and never delays completion.
#
# THE SESSION WINDOW. The lower bound is the SessionStart baseline this state
# directory already holds: Test-Temp-Cleanup writes
# TestTempCleanup-baseline-<projectKey>.json at SessionStart carrying
# { sessionId, timestampUtc }. That is the single source of truth for "when this
# session started"; this file reads it and never writes or derives a second one.
# It is honoured only when its sessionId is THIS session - a baseline from an
# earlier session would open the window to everything that has run since. When
# it is absent or belongs to another session the check is simply NOT EVALUATED
# (the same optional-input contract every other coordination file here has: a
# missing producer can never widen, or in this case fabricate, a finding).

# Image-name patterns (wildcards, case-insensitive) whose processes are worth
# naming as possible test survivors: runners, language/worker hosts, browsers
# and their drivers, and dev servers. Deliberately excludes git, the editor and
# the shell family's own ancestors are removed separately.
$script:SurvivorDefaultPatterns = @(
    'node*', 'python*', 'pytest*', 'jest*', 'vitest*', 'mocha*', 'pwsh*', 'powershell*',
    'dotnet*', 'java*', 'ruby*', 'php*', 'deno*', 'bun*', 'cargo*',
    'chrome*', 'chromium*', 'msedge*', 'firefox*', 'chromedriver*', 'geckodriver*',
    'playwright*', 'uvicorn*', 'gunicorn*', 'vite*', 'webpack*'
)
$script:SurvivorMaxPatterns = 64      # bound on the configurable set
$script:SurvivorMaxRows = 10          # rows PRINTED; the rest are counted, not listed
$script:SurvivorTimeoutSec = 5        # the one CIM call's own operation timeout
$script:SurvivorCmdChars = 120        # first N chars of the command line
$script:SurvivorMaxHops = 32          # ancestor walk bound (a cycle can never spin)

# The configurable pattern set. An EMPTY value switches the advisory off
# deliberately; an oversized list is truncated and reported rather than honoured.
function Get-SurvivorPatterns {
    if (-not $script:config.ContainsKey('TEST_COMPLETION_SURVIVOR_PATTERNS')) {
        return $script:SurvivorDefaultPatterns
    }
    $raw = [string]$script:config['TEST_COMPLETION_SURVIVOR_PATTERNS']
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $patterns = @(@($raw -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($patterns.Count -gt $script:SurvivorMaxPatterns) {
        [void]$script:configWarnings.Add('TEST_COMPLETION_SURVIVOR_PATTERNS lists ' + $patterns.Count +
            ' patterns, over the ' + $script:SurvivorMaxPatterns + ' cap; only the first ' +
            $script:SurvivorMaxPatterns + ' are used.')
        $patterns = @($patterns[0..($script:SurvivorMaxPatterns - 1)])
    }
    return $patterns
}

# This session's SessionStart baseline time, or $null when there is none for
# THIS session. ConvertTo-UtcTime is the hook's own JSON-timestamp normaliser -
# the 210-minute double-offset bug it documents applies here identically.
function Get-SessionBaselineUtc {
    $path = Join-Path $script:stateDir ('TestTempCleanup-baseline-' + $script:projectKey + '.json')
    $doc = $null
    try { $doc = Read-JsonFile -Path $path } catch { return $null }
    if ($null -eq $doc) { return $null }
    if ([string]::IsNullOrWhiteSpace($script:sessionId)) { return $null }
    if ([string](Get-Field $doc 'sessionId') -ne $script:sessionId) { return $null }
    return (ConvertTo-UtcTime (Get-Field $doc 'timestampUtc'))
}

# ONE process snapshot, filtered to matching images started after $SinceUtc.
# Ok=$false means the query itself failed or timed out: that is reported as
# PARTIAL coverage, never as "nothing found".
#
# SELF-EXCLUSION IS LOAD-BEARING: this hook runs as pwsh/powershell, which is in
# the default pattern set, and its ancestors are the agent's own shell and
# client. Both would otherwise be listed as survivors of the session they are
# hosting. The walk uses the ParentProcessId of the SAME snapshot, so it costs
# no extra query.
function Get-SurvivorSnapshot {
    param([DateTime]$SinceUtc, [string[]]$Patterns)
    $processes = @()
    try {
        $cimArgs = @{
            ClassName           = 'Win32_Process'
            Property            = @('ProcessId', 'ParentProcessId', 'Name', 'CreationDate', 'CommandLine')
            OperationTimeoutSec = $script:SurvivorTimeoutSec
            ErrorAction         = 'Stop'
        }
        $processes = @(Get-CimInstance @cimArgs)
    }
    catch { return [pscustomobject]@{ Ok = $false; Rows = @() } }

    $parents = @{}
    foreach ($process in $processes) {
        $parents[[string][int](Get-Field $process 'ProcessId')] = [int](Get-Field $process 'ParentProcessId')
    }
    $excluded = @{}
    $current = $PID
    for ($hop = 0; $hop -lt $script:SurvivorMaxHops; $hop++) {
        $key = [string]$current
        if ($current -le 0 -or $excluded.ContainsKey($key)) { break }
        $excluded[$key] = $true
        if (-not $parents.ContainsKey($key)) { break }
        $current = $parents[$key]
    }

    # SIBLINGS ARE INFRASTRUCTURE TOO. Excluding only the ancestor chain leaves
    # everything the CLIENT starts beside this hook: the other Stop hooks of the
    # same dispatch, the MCP servers, the tool shell. Their pids are new on every
    # event, so the report's own fingerprint changed on every Stop and the
    # advisory repeated - measured at 13 consecutive Stops in one session, each
    # repeat a forced turn (a Stop emission is never free on Claude), until the
    # client's block cap ended the task. Not one of the rows was a test process.
    #
    # ONE HOP ONLY, and that is the whole distinction: a DIRECT child of an
    # ancestor of mine was started by the client, while a deeper descendant - a
    # test the agent started through the tool shell - is this task's and is still
    # reported. Uses the same snapshot, so it costs no extra query.
    $cohort = @{}
    foreach ($key in $excluded.Keys) { $cohort[$key] = $true }
    foreach ($process in $processes) {
        $childId = [int](Get-Field $process 'ProcessId')
        if ($childId -le 0) { continue }
        if ($excluded.ContainsKey([string][int](Get-Field $process 'ParentProcessId'))) { $cohort[[string]$childId] = $true }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($process in $processes) {
        $processId = [int](Get-Field $process 'ProcessId')
        if ($processId -le 0 -or $cohort.ContainsKey([string]$processId)) { continue }
        $name = [string](Get-Field $process 'Name')
        if ($name -eq '') { continue }
        $matched = $false
        foreach ($pattern in $Patterns) { if ($name -like $pattern) { $matched = $true; break } }
        if (-not $matched) { continue }
        $started = $null
        try {
            $created = Get-Field $process 'CreationDate'
            if ($null -ne $created) { $started = ([DateTime]$created).ToUniversalTime() }
        }
        catch { $started = $null }
        # An unreadable start time cannot be placed inside the session window, and
        # listing it would be a guess. Skipped, not reported as a survivor.
        if ($null -eq $started -or $started -le $SinceUtc) { continue }
        [void]$rows.Add([pscustomobject]@{
                Pid     = $processId
                Started = $started
                Text    = (Format-SurvivorCommand -Name $name -CommandLine ([string](Get-Field $process 'CommandLine')))
            })
    }
    return [pscustomobject]@{ Ok = $true; Rows = @($rows.ToArray() | Sort-Object Started, Pid) }
}

# One display line's command text: control characters flattened so a row can
# never break the message layout, and cut to the first $SurvivorCmdChars chars.
# A command line is often unreadable for another user's process - the image name
# is then all that can honestly be shown.
function Format-SurvivorCommand {
    param([string]$Name, [string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return ($Name + '  (command line unavailable)') }
    $text = [System.Text.RegularExpressions.Regex]::Replace($CommandLine, '[\x00-\x1F\x7F]', ' ').Trim()
    if ($text.Length -gt $script:SurvivorCmdChars) { $text = $text.Substring(0, $script:SurvivorCmdChars) + ' ...' }
    return $text
}

# Once per session per unchanged state, the shape Test-DdGateShouldReport uses:
# an unchanged list is reported once, a changed list immediately.
function Test-SurvivorShouldReport {
    param([string]$StateToken)
    $fingerprint = Get-ShortHash ($StateToken + '|' + $script:sessionId)
    $path = Join-Path $script:stateDir ('TestCompletionCheck-survivors-' + $script:projectKey + '.txt')
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if (([System.IO.File]::ReadAllText($path)).Trim() -eq $fingerprint) { return $false }
        }
    }
    catch { }
    try {
        if (-not (Test-Path -LiteralPath $script:stateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($path, $fingerprint, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
    return $true
}

# The advisory. Silent by default: no configured patterns, no baseline for this
# session, or no candidate all mean nothing is said. Emitted through the hook's
# own Write-Finding -Blocking $false, so the client shapes come from the shared
# Write-HookResult adapter (Kind 'advisory') and nothing here hand-rolls JSON.
function Write-SurvivorAdvisory {
    # NEVER DURING A CONTINUATION. On Claude a Stop emission is not free: even
    # hookSpecificOutput.additionalContext sends the turn back to the model, so
    # an advisory at Stop costs exactly what a block costs. This one has nothing
    # new to say inside a chain it started - the sweep instruction is the same
    # sentence every time - and saying it again is the loop above. It speaks on a
    # genuine Stop or not at all.
    $stopActive = Get-Field $hookInput 'stop_hook_active'
    if ($null -ne $stopActive -and [bool]$stopActive) { return }
    $patterns = @(Get-SurvivorPatterns)
    if ($patterns.Count -eq 0) { return }
    $since = Get-SessionBaselineUtc
    if ($null -eq $since) { return }

    $snapshot = Get-SurvivorSnapshot -SinceUtc $since -Patterns $patterns
    if (-not $snapshot.Ok) {
        if (-not (Test-SurvivorShouldReport 'enumeration-unavailable')) { return }
        Write-Finding -Blocking $false -Lines @(
            'TEST COMPLETION CHECK - the process list could not be read (the query was refused or timed out), so possible orphaned test processes from this session could NOT be checked: coverage here is PARTIAL, not clean.',
            'Run the survivor sweep yourself before finishing (global-test-rules.md -> No Orphaned Test Processes): list what this task started, terminate every survivor, verify it is gone, and report each pid.')
        return
    }
    $rows = @($snapshot.Rows)
    if ($rows.Count -eq 0) { return }

    # THE IDENTITY OF THE FINDING IS THE SET OF PROCESSES, nothing else. Start
    # ticks used to be in here as well, which made two readings of the same
    # process differ whenever the clock source did, and the rows beyond the
    # printed cap churned with every transient process on the machine.
    $token = 'survivors|' + ((@($rows | ForEach-Object { [string]$_.Pid }) | Sort-Object) -join ',')
    if (-not (Test-SurvivorShouldReport $token)) { return }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('TEST COMPLETION CHECK - possible orphaned test processes started during this session (advisory; the hook cannot prove ownership and kills nothing):')
    $shown = [Math]::Min($rows.Count, $script:SurvivorMaxRows)
    for ($i = 0; $i -lt $shown; $i++) {
        [void]$lines.Add('  pid ' + $rows[$i].Pid + '  started ' + $rows[$i].Started.ToString('yyyy-MM-dd HH:mm:ss') + 'Z  ' + $rows[$i].Text)
    }
    if ($rows.Count -gt $shown) {
        [void]$lines.Add('  ... and ' + ($rows.Count - $shown) + ' more matching process(es) not listed - this list is capped at ' +
            $script:SurvivorMaxRows + ' rows, so the coverage shown here is PARTIAL.')
    }
    [void]$lines.Add('Run the survivor sweep before finishing (global-test-rules.md -> No Orphaned Test Processes): confirm each pid by start time, terminate what this task started, verify it is gone, and report each in the completion message. A report that says done while one of these is yours and alive is false.')
    Write-Finding -Blocking $false -Lines $lines.ToArray()
}
