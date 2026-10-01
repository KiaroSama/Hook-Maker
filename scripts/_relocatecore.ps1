# Relocation core: find a project whose folder was renamed or moved, and repair
# its installs without a prompt. Shared by the wizard's "Fix a renamed or moved
# project" flow, the wizard update and Update-Fleet.ps1.
#
# A missing root may equally mean "deleted", so the new location is never
# guessed: it is PROVEN by the record ids the moved folder still carries in its
# runtime ownership metadata (.hookmaker-runtime.json), which travel with the
# folder. Exactly one folder carrying one of the root's record ids is a proven
# move; none, or more than one (a copy), is reported and nothing is written.
#
# Needs (loaded by the caller): _installlib.ps1 (registry, Get-InstalledClientNames,
# Get-ClientSubrecord), _installinvoke.ps1 (Get-PartialInstallVerdict) and
# Setup-SyncGroupRelocate.ps1 (Get-RelocationCandidate, Update-SyncConfigRoot).

$script:RelocateSearchDepth = 4
$script:RelocateSearchDirs = 4000
$script:RelocateSearchMs = 15000
# One budget for every missing root of a run, so projects that were really deleted
# cannot add a full search each to every later update.
$script:RelocateTotalMs = 30000
$script:RelocateSkipNames = @('node_modules', 'venv', '__pycache__', 'dist', 'build', 'bin', 'obj', 'target', 'logs')

# The nearest ancestor of the missing root that still exists: a rename keeps
# the folder under its parent, a move into a group folder keeps it under the
# old parent's parent, so the search starts there.
function Get-RelocationSearchRoot {
    param([Parameter(Mandatory = $true)][string]$OldRoot)
    $parent = Split-Path -Parent $OldRoot
    while (-not [string]::IsNullOrWhiteSpace($parent) -and -not [IO.Directory]::Exists($parent)) { $parent = Split-Path -Parent $parent }
    return [string]$parent
}

# Record ids named by the runtime metadata of every Hook Maker hook installed
# directly in this folder, for both clients. Read-only; a malformed document
# contributes nothing.
function Get-FolderRuntimeRecordIds {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($client in @('.claude', '.codex')) {
        $root = Join-Path $ProjectDir ($client + '\hooks\Hook-Maker')
        if (-not [IO.Directory]::Exists($root)) { continue }
        foreach ($hookDir in @([IO.Directory]::GetDirectories($root))) {
            $meta = Join-Path $hookDir '.hookmaker-runtime.json'
            try {
                if (-not [IO.File]::Exists($meta) -or (New-Object IO.FileInfo $meta).Length -gt 262144) { continue }
                $id = [string](([IO.File]::ReadAllText($meta, [Text.Encoding]::UTF8) | ConvertFrom-Json).recordId)
                if ($id -ne '') { [void]$ids.Add($id) }
            }
            catch { }
        }
    }
    return @($ids.ToArray())
}

# Bounded breadth-first search under the search root for folders carrying one
# of the record ids. A folder that is itself a project (it has .git, .claude or
# .codex) is examined but never descended into - projects do not nest - which
# keeps a tree of real projects cheap to walk. Partial = a bound was reached.
function Find-RelocatedProjectRoot {
    param(
        [Parameter(Mandatory = $true)][string]$OldRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RecordIds,
        [ValidateRange(0, 2147483647)][int]$TimeoutMs = $script:RelocateSearchMs
    )
    $result = [pscustomobject]@{ Candidates = @(); Partial = $false; SearchRoot = '' }
    $searchRoot = Get-RelocationSearchRoot -OldRoot $OldRoot
    $wanted = @{}
    foreach ($id in @($RecordIds)) { if (-not [string]::IsNullOrWhiteSpace($id)) { $wanted[$id] = $true } }
    if ($searchRoot -eq '' -or $wanted.Count -eq 0) { return $result }
    $result.SearchRoot = $searchRoot
    $found = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ Dir = $searchRoot; Depth = 0 })
    $visited = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0) {
        if ($visited -ge $script:RelocateSearchDirs -or $clock.ElapsedMilliseconds -ge $TimeoutMs) { $result.Partial = $true; break }
        $item = $queue.Dequeue()
        $visited++
        $isProject = $false
        foreach ($marker in @('.git', '.claude', '.codex')) { if (Test-Path -LiteralPath (Join-Path $item.Dir $marker)) { $isProject = $true } }
        if ($isProject) {
            foreach ($id in @(Get-FolderRuntimeRecordIds -ProjectDir $item.Dir)) {
                if ($wanted.ContainsKey($id)) { [void]$found.Add($item.Dir); break }
            }
            if ($item.Depth -gt 0) { continue }
        }
        if ($item.Depth -ge $script:RelocateSearchDepth) { continue }
        $children = @()
        try { $children = @([IO.Directory]::GetDirectories($item.Dir)) } catch { continue }
        foreach ($child in $children) {
            $info = New-Object IO.DirectoryInfo $child
            if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $info.Name.StartsWith('.') -or
                $script:RelocateSkipNames -contains $info.Name) { continue }
            $queue.Enqueue([pscustomobject]@{ Dir = $child; Depth = $item.Depth + 1 })
        }
    }
    $result.Candidates = @($found.ToArray() | Where-Object { -not [string]::Equals($_, $OldRoot, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object -Unique)
    return $result
}

# Reinstalls every client registration of the records at the new root with that
# client's own recorded events, drops each record only once all its clients are
# installed and tracked, and repoints sync routes. The installer rewrites the
# moved settings files in place, so the handlers that still name the old path
# are replaced rather than left behind.
function Invoke-ProjectRelocation {
    param(
        [Parameter(Mandatory = $true)][string]$OldRoot,
        [Parameter(Mandatory = $true)][string]$NewRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        # A script path, or a scriptblock with the same parameters (tests).
        [Parameter(Mandatory = $true)]$InstallScript,
        [Parameter(Mandatory = $true)]$UninstallScript,
        [scriptblock]$Log = { param($Level, $Message) }
    )
    $installed = 0; $installFailed = 0; $codex = $false
    $failures = New-Object System.Collections.Generic.List[string]
    $replacedRecords = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($Records)) {
        $friendly = [string]$record.friendlyName
        $recordClients = @(Get-InstalledClientNames -Record $record)
        $recordReplaced = ($recordClients.Count -gt 0)
        if (-not $recordReplaced) { [void]$failures.Add($friendly + ': no recorded clients; original record retained') }
        foreach ($client in $recordClients) {
            if ($client -eq 'codex') { $codex = $true }
            $subrecord = Get-ClientSubrecord -Record $record -Client $client
            $events = @()
            if ($null -ne $subrecord -and $null -ne $subrecord.PSObject.Properties['events']) { $events = @($subrecord.events) }
            if ($events.Count -eq 0) {
                $recordReplaced = $false
                $installFailed++; [void]$failures.Add($friendly + '/' + $client + ': no recorded events'); continue
            }
            # Per client, with that client's OWN events - the shape the updater
            # uses to repair a record. A union would re-add events a reduced
            # client that lacks the event never had.
            $installArgs = @{ Events = @($events); TargetProject = $NewRoot }
            if ([string]$record.hookType -eq 'Engine') {
                $installArgs['Profile'] = [string]$record.profile
                $installArgs['ConfigPath'] = [string]$record.configPath
            }
            else { $installArgs['CustomHook'] = [string]$record.sourceScript }
            $resultPath = Join-Path ([IO.Path]::GetTempPath()) ('hookmaker-relocate-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
            $installArgs['ResultPath'] = $resultPath
            try {
                $output = & $InstallScript @installArgs -Clients @($client) *>&1
                foreach ($line in @($output)) { & $Log 'INFO' ([string]$line) }
                $result = $null
                if (Test-Path -LiteralPath $resultPath -PathType Leaf) { $result = Get-Content -LiteralPath $resultPath -Raw -Encoding utf8 | ConvertFrom-Json }
                $overall = ''
                if ($null -ne $result) { $overall = [string]$result.overall }
                $detail = if ($overall -eq '') { 'no result document' } else { $overall }
                $components = @()
                if ($null -ne $result -and $null -ne $result.PSObject.Properties['components']) { $components = @($result.components) }
                $accepted = ($overall -eq 'ok')
                if ($overall -eq 'partial') {
                    $verdict = Get-PartialInstallVerdict -Components $components
                    $accepted = -not $verdict.IsFailure
                    $detail = [string]$verdict.Summary
                }
                # A runtime without its tracking record cannot replace the old
                # retry metadata. Prove both outcomes for THIS client first.
                $clientInstalled = @($components | Where-Object { $_.component -eq $client -and $_.status -eq 'ok' }).Count -eq 1
                $tracked = @($components | Where-Object { $_.component -eq 'registry' -and $_.status -eq 'ok' }).Count -eq 1
                if ($accepted -and $clientInstalled -and $tracked) { $installed++ }
                else {
                    $recordReplaced = $false
                    $installFailed++
                    if ($accepted) { $detail = 'replacement installation and tracking were not confirmed' }
                    [void]$failures.Add($friendly + '/' + $client + ': ' + $detail)
                }
            }
            catch {
                $recordReplaced = $false
                $installFailed++; [void]$failures.Add($friendly + '/' + $client + ': ' + $_.Exception.Message)
            }
            finally { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
        }
        if ($recordReplaced) { [void]$replacedRecords.Add($record) }
    }

    $dropped = 0; $dropFailed = 0
    # Keep the complete original record if ANY client failed. It remains a
    # relocation candidate, preserving each client's events for a later retry.
    foreach ($record in $replacedRecords) {
        $resultPath = Join-Path ([IO.Path]::GetTempPath()) ('hookmaker-relocate-un-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
        try {
            & $UninstallScript -RecordId ([string]$record.id) -ResultPath $resultPath *> $null
            $result = $null
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }
            if ($null -ne $result -and [string]$result.overall -eq 'ok') { $dropped++ }
            else {
                $dropFailed++
                $detail = 'no result document'
                if ($null -ne $result) { $detail = [string]$result.overall }
                [void]$failures.Add('record ' + [string]$record.id + ' (' + [string]$record.friendlyName + '): ' + $detail)
            }
        }
        catch { $dropFailed++; [void]$failures.Add('record ' + [string]$record.id + ': ' + $_.Exception.Message) }
        finally { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
    }
    $configChange = Update-SyncConfigRoot -ConfigPath $ConfigPath -OldRoot $OldRoot -NewRoot $NewRoot
    return [pscustomobject]@{
        Installed = $installed; InstallFailed = $installFailed; Replaced = $replacedRecords.Count
        Dropped = $dropped; DropFailed = $dropFailed; Failures = @($failures.ToArray())
        ConfigChange = $configChange; Codex = $codex
    }
}

# The non-interactive pass the update runs first: every missing project root
# with records is searched for; a single proven folder is repaired (with -Apply)
# or announced (without). Returns one row per missing root.
function Invoke-FleetRelocations {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        # A script path, or a scriptblock with the same parameters (tests).
        [Parameter(Mandatory = $true)]$InstallScript,
        [Parameter(Mandatory = $true)]$UninstallScript,
        [switch]$Apply,
        [string]$OnlyProject = '',
        [scriptblock]$Log = { param($Level, $Message) }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $budget = [Diagnostics.Stopwatch]::StartNew()
    $perSearch = $script:RelocateSearchMs
    foreach ($candidate in @(Get-RelocationCandidate -ToolRoot $ToolRoot -ConfigPath $ConfigPath)) {
        $records = @($candidate.Records)
        if ($records.Count -eq 0) { continue }
        $oldRoot = [string]$candidate.Root
        $left = $script:RelocateTotalMs - $budget.ElapsedMilliseconds
        if ($left -le 0) {
            [void]$rows.Add([pscustomobject]@{ OldRoot = $oldRoot; NewRoot = ''; State = 'not-found'; Records = $records.Count; Result = $null; Partial = $true })
            continue
        }
        $ids = @($records | ForEach-Object { [string]$_.id })
        $search = Find-RelocatedProjectRoot -OldRoot $oldRoot -RecordIds $ids -TimeoutMs ([int][Math]::Min($perSearch, $left))
        $row = [pscustomobject]@{ OldRoot = $oldRoot; NewRoot = ''; State = 'not-found'; Records = $records.Count; Result = $null; Partial = $search.Partial }
        if (@($search.Candidates).Count -gt 1) { $row.State = 'ambiguous' }
        elseif (@($search.Candidates).Count -eq 1) { $row.NewRoot = [string]$search.Candidates[0]; $row.State = 'proven' }
        if ($OnlyProject -ne '') {
            $selected = $false
            foreach ($root in @($oldRoot, $row.NewRoot)) {
                if ($root -ne '' -and ([string]::Equals($root, $OnlyProject, [StringComparison]::OrdinalIgnoreCase) -or
                        [string]::Equals((Split-Path -Leaf $root), $OnlyProject, [StringComparison]::OrdinalIgnoreCase))) { $selected = $true }
            }
            if (-not $selected) { continue }
        }
        if ($row.State -eq 'proven' -and $Apply) {
            & $Log 'INFO' ('Relocating ' + $oldRoot + ' -> ' + $row.NewRoot + ' (' + $records.Count + ' record(s), proven by record id)')
            $row.Result = Invoke-ProjectRelocation -OldRoot $oldRoot -NewRoot $row.NewRoot -Records $records -ConfigPath $ConfigPath `
                -InstallScript $InstallScript -UninstallScript $UninstallScript -Log $Log
            $row.State = if (@($row.Result.Failures).Count -eq 0) { 'relocated' } else { 'relocated-with-problems' }
        }
        [void]$rows.Add($row)
    }
    return @($rows.ToArray())
}

# One line per row, shared by Update-Fleet and the wizard so both say the same
# thing, including the Codex step no tool can take for the user.
function Format-FleetRelocationLines {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($row in @($Rows)) {
        switch ($row.State) {
            'proven' { [void]$lines.Add('RELOCATE would move ' + $row.Records + ' record(s): ' + $row.OldRoot + ' -> ' + $row.NewRoot) }
            'relocated' { [void]$lines.Add('RELOCATED ' + $row.Records + ' record(s): ' + $row.OldRoot + ' -> ' + $row.NewRoot) }
            'relocated-with-problems' {
                [void]$lines.Add('RELOCATED WITH PROBLEMS: ' + $row.OldRoot + ' -> ' + $row.NewRoot)
                foreach ($failure in @($row.Result.Failures)) { [void]$lines.Add('  ' + $failure) }
            }
            'ambiguous' { [void]$lines.Add('RELOCATE skipped: ' + $row.OldRoot + ' - more than one folder carries its hooks (a copy?); fix it in the wizard, naming the right one') }
            default {
                $why = if ($row.Partial) { ' (search bound reached; fix it in the wizard if it was moved)' } else { ' (renamed outside the search area, or deleted)' }
                [void]$lines.Add('RELOCATE not found: ' + $row.OldRoot + $why)
            }
        }
        if ($row.State -like 'relocated*' -and $null -ne $row.Result -and $row.Result.Codex) {
            [void]$lines.Add('  Codex: open ' + $row.NewRoot + ' in Codex, trust the project if asked, then /hooks -> review and trust the Hook Maker hooks (their commands now name the new path).')
        }
    }
    return @($lines.ToArray())
}
