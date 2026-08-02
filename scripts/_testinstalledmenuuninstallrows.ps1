# Test-InstalledHooksMenu.ps1 scenario block: uninstall row selection: a blocked row is skipped rather than vetoing the rest, the project-scope filter and its defaults, and the rendered location text.
#
# Dot-sourced by Test-InstalledHooksMenu.ps1 INTO its scope - it relies on that
# suite's harness (Check, $script:Pass/$script:Fail), helpers, fixtures and
# workspace. NOT a standalone suite: run scripts\Test-InstalledHooksMenu.ps1.

    Write-Host ''
    Write-Host '--- a blocked uninstall row is skipped, not a veto over the rest ---' -ForegroundColor Cyan

    $executorLog = Join-Path $Work 'uninstall-executor-calls.txt'
    $stubExecutor = Join-Path $Work 'Stub-Uninstall-Hook.ps1'
    Write-Utf8 $stubExecutor ((@(
        'param([string]$RecordId, [string]$ToolRoot, [string]$ResultPath)'
        'Add-Content -LiteralPath (Join-Path $PSScriptRoot ''uninstall-executor-calls.txt'') -Value $RecordId'
        '[System.IO.File]::WriteAllText($ResultPath, ''{"overall":"ok"}'')'
    ) -join "`r`n") + "`r`n")

    function New-RemovableRecord {
        param($Source, [string]$Id)
        $clone = ($Source | ConvertTo-Json -Depth 30) | ConvertFrom-Json
        $clone.id = $Id
        return $clone
    }
    # Non-removable for the clearest possible reason: the scan itself flagged it
    # (Get-DiscoveredRemovalCapability's needsManualRepair branch).
    function New-BlockedRecord {
        param([string]$Id, [string]$FriendlyName)
        return [pscustomobject]@{
            id = $Id; recordType = 'discovered'; friendlyName = $FriendlyName
            hookType = 'ClaudeRegistration'; scope = 'project'; targetProjectRoot = 'C:\Proj\Blocked'
            status = 'ambiguous'; statusReason = 'command could not be parsed'
            removalPolicy = 'unavailable'; needsManualRepair = $true
            clients = @([pscustomobject]@{ client = 'claude'; settingsPath = 'C:\Proj\Blocked\.claude\settings.json'; events = @('SessionStart') })
        }
    }
    # Rows 1-2 removable, rows 3-4 blocked, row 5 the project aggregate.
    $uninstallInstalls = @(
        (New-RemovableRecord $rec 'zzz-removable-a')
        (New-RemovableRecord $rec 'zzz-removable-b')
        (New-BlockedRecord 'zzz-blocked-a' 'ZZZ-Blocked-One')
        (New-BlockedRecord 'zzz-blocked-b' 'ZZZ-Blocked-Two')
    )

    $uninstallRuns = & {
        $script:Captured = New-Object System.Collections.Generic.List[string]
        function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Args) [void]$script:Captured.Add((@($Args) -join ' ')) }
        function Get-Painted { param([AllowEmptyString()][string]$Text, [string]$Color) return $Text }
        function Write-PhaseHeader { param([string]$Text, [string]$Color, [string]$Char = '=') [void]$script:Captured.Add($Text) }
        function Write-MenuTitle { param([string]$Text) [void]$script:Captured.Add($Text) }
        function Write-Field { param([string]$Name, [AllowEmptyString()][string]$Value, [string]$ValueColor = '') [void]$script:Captured.Add(($Name.Trim() + ': ' + $Value)) }
        function Write-NoteLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-ErrorLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-Log { param([string]$Level, [string]$Component, [string]$Message) }
        # The default is part of what is being asserted (which row Enter picks),
        # so it travels into the captured prompt text rather than being dropped.
        function New-QuestionPrompt { param([string]$Title, [string]$Details, [string]$Default) return ($Title + ' [' + $Default + ']') }
        # Used by the scope submenu that now precedes the list.
        function Write-MenuLine { param([int]$Number, [string]$Label, [string]$Suffix = '') [void]$script:Captured.Add(($Number.ToString() + '. ' + $Label + ' ' + $Suffix)) }
        function Get-ExampleText { param([string]$Text) return $Text }
        # A scripted answer queue, exhausted into '0' so a wrong expectation
        # ends the screen instead of looping forever.
        function Read-Answer {
            param([string]$Prompt, [string]$LogLabel)
            # The prompt carries the DEFAULT, and which row Enter picks is part
            # of what these cases assert, so it is captured like any other line.
            [void]$script:Captured.Add($Prompt)
            if ($script:UninstallAnswers.Count -eq 0) { return '0' }
            return $script:UninstallAnswers.Dequeue()
        }
        function Read-YesNo { param([string]$Prompt, [bool]$Default, [string]$LogLabel) return $true }
        # The registry is supplied directly, so nothing on disk is read and the
        # real install-registry file cannot be touched by this part.
        function Read-InstallRegistryState { param([string]$ToolRoot) return [pscustomobject]@{ State = 'ok'; Reason = ''; Path = 'synthetic' } }
        function Read-InstallRegistry { param([string]$ToolRoot) return [pscustomobject]@{ installs = $uninstallInstalls } }
        $C = @{ Reset = ''; Bold = ''; Red = ''; Green = ''; White = ''; Gray = ''; Dim = ''; LightBlue = ''; HintYellow = ''; NoteYellow = ''; Aqua = ''; Amber = ''; Mint = ''; Orchid = ''; Teal = ''; Summary = ''; Process = ''; Input = ''; Confirm = '' }
        $script:MenuSep = ' | '
        # Record type routes to the executor; both point at the stub, so a
        # misrouted record would still be visible in the call log.
        $UninstallScript = $stubExecutor
        # Get-RecordDisplayField (the StrictMode-safe field reader the snapshot
        # uses for every record) lives in Setup-SyncGroupInstallFlows.ps1, which
        # defines functions only. The real one is loaded rather than stubbed:
        # its fallback behaviour is part of what the row model relies on.
        . (Join-Path $ScriptRoot 'Setup-SyncGroupInstallFlows.ps1')
        . (Join-Path $ScriptRoot 'Setup-SyncGroupInstalledHooks.ps1')

        $results = @{}
        foreach ($case in @(
                # Every case starts by choosing a scope: '2' = every installed
                # hook, which is the set these cases were written against.
                # 1-4: two removable rows and two blocked ones in one selection.
                [pscustomobject]@{ Name = 'mixed'; Answers = @('2', '1-4') }
                # 3,4: nothing removable at all - then 0 to leave the re-ask.
                [pscustomobject]@{ Name = 'allBlocked'; Answers = @('2', '3,4', '0') }
                # Scope 1 + the folder the two REMOVABLE rows were installed
                # into: only those are listed, and the blocked rows - which live
                # in a different project - are gone from the screen entirely.
                [pscustomobject]@{ Name = 'filtered'; Answers = @('1', $proj, '0') }
                # The scope prompt defaults to 1, so Enter takes the project
                # route; the selection then defaults to the single aggregate
                # row, so Enter again removes exactly that project's hooks.
                [pscustomobject]@{ Name = 'filteredDefault'; Answers = @('', $proj, '') }
                # A quoted path (how Explorer hands one over) must resolve too.
                [pscustomobject]@{ Name = 'filteredQuoted'; Answers = @('1', ('"' + $proj + '"'), '0') }
                # A PARENT folder includes the projects underneath it: C:\Proj
                # owns only the blocked rows (C:\Proj\Blocked).
                [pscustomobject]@{ Name = 'filteredParent'; Answers = @('1', 'C:\Proj', '0') }
                # Scope 1 + a folder with no tracked install: not an error and
                # not a dead end - it says so and offers the scope menu again.
                [pscustomobject]@{ Name = 'filteredEmpty'; Answers = @('1', 'C:\Proj\Nothing\Here', '0') }
            )) {
            $script:Captured = New-Object System.Collections.Generic.List[string]
            $script:UninstallAnswers = New-Object System.Collections.Generic.Queue[string]
            foreach ($answer in $case.Answers) { $script:UninstallAnswers.Enqueue($answer) }
            [void](Invoke-UninstallInstalledHooks)
            $results[$case.Name] = ($script:Captured -join "`n")
            $results[($case.Name + 'Calls')] = if (Test-Path -LiteralPath $executorLog) { [System.IO.File]::ReadAllText($executorLog) } else { '' }
        }
        return , $results
    }

    $mixed = [string]$uninstallRuns['mixed']
    $mixedCalls = @(([string]$uninstallRuns['mixedCalls']) -split "`r?`n" | Where-Object { $_ -ne '' })
    # The skip notice and its per-row list, isolated from the rest of the
    # output: the LIST screen prints every blocked row's name and reason too, so
    # matching anywhere in the capture would prove nothing about the skip block.
    $skipStart = $mixed.IndexOf('need manual repair and are SKIPPED')
    $skipEnd = if ($skipStart -ge 0) { $mixed.IndexOf('Confirm Uninstall', $skipStart) } else { -1 }
    $skipBlock = if ($skipStart -ge 0 -and $skipEnd -gt $skipStart) { $mixed.Substring($skipStart, $skipEnd - $skipStart) } else { '' }

    # "did not abort" has to be asserted as what DID happen: the run reached the
    # confirmation after ONE list render. A bare "the refusal message is absent"
    # passes against the pre-fix code too, which rejected with different wording.
    Check 'uninstall: a blocked row does not abort the selection - it reaches the confirmation' (
        ($mixed -match 'Confirm Uninstall') -and
        (@([regex]::Matches($mixed, [regex]::Escape('Installed hooks:'))).Count -eq 1) -and
        ($mixed -notmatch 'Nothing removable was selected\.')) $mixed
    Check 'uninstall: the blocked rows are announced as skipped, with their count' ($mixed -match '2 selected record\(s\) need manual repair and are SKIPPED') $mixed
    Check 'uninstall: each blocked row is named in the skip list' (
        ($skipBlock -match 'ZZZ-Blocked-One') -and ($skipBlock -match 'ZZZ-Blocked-Two')) $skipBlock
    Check 'uninstall: the skip list gives the reason for each blocked row' (
        (@([regex]::Matches($skipBlock, [regex]::Escape('manual repair: the scan flagged this record for review'))).Count) -eq 2) $skipBlock
    Check 'uninstall: the confirmation offered exactly the two removable records' ($mixed -match 'installations to remove: 2') $mixed
    Check 'uninstall: only the removable records reached the executor' (
        (($mixedCalls | Sort-Object) -join ',') -eq 'zzz-removable-a,zzz-removable-b') (($mixedCalls -join ',') + ' (' + $mixedCalls.Count + ')')
    Check 'uninstall: the removable records are reported as removed' ($mixed -match 'removed: 2') $mixed
    Check 'uninstall: the summary counts the skipped rows separately' ($mixed -match 'skipped \(manual repair\): 2') $mixed
    Check 'uninstall: nothing was silently lost - the kept-in-registry note is shown' ($mixed -match 'are KEPT in the registry') $mixed

    $allBlocked = [string]$uninstallRuns['allBlocked']
    $allBlockedCalls = @(([string]$uninstallRuns['allBlockedCalls']) -split "`r?`n" | Where-Object { $_ -ne '' })
    Check 'uninstall: a selection where EVERYTHING is blocked is still refused' ($allBlocked -match 'Nothing removable was selected\.') $allBlocked
    Check 'uninstall: the refusal never reached the confirmation screen' ($allBlocked -notmatch 'Confirm Uninstall') $allBlocked
    Check 'uninstall: the refusal invoked no executor at all' ($allBlockedCalls.Count -eq $mixedCalls.Count) (($allBlockedCalls -join ',') + ' (' + $allBlockedCalls.Count + ')')

    # ---- scope submenu: uninstall one project instead of the whole machine ---
    # A real registry holds hundreds of installs. One flat list of all of them
    # cannot be picked from, so the screen asks WHICH SET first.
    $filtered = [string]$uninstallRuns['filtered']
    Check 'uninstall: the scope menu offers both ways before any list is drawn' (
        ($filtered -match 'What do you want to uninstall\?') -and
        ($filtered -match '1\. Only the hooks in one project') -and
        ($filtered -match '2\. Every installed hook')) $filtered
    Check 'uninstall: the scope prompt defaults to the project route' (
        $filtered -match [regex]::Escape('Choose [1]')) $filtered
    # The whole point of the project scope is "clear this project", so the row
    # that does exactly that is what Enter picks.
    Check 'uninstall: the selection defaults to the single remove-all row' (
        $filtered -match [regex]::Escape('Select what to uninstall (number, list, or range) [3]')) $filtered
    Check 'uninstall: a project scope lists that project''s hooks' ($filtered -match 'ZZZ-Menusuite-Fixture') $filtered
    Check 'uninstall: a project scope EXCLUDES hooks installed elsewhere' (
        ($filtered -notmatch 'ZZZ-Blocked-One') -and ($filtered -notmatch 'ZZZ-Blocked-Two')) $filtered
    Check 'uninstall: the filtered list says which folder it is showing' (
        $filtered -match ('Showing only hooks installed in ' + [regex]::Escape($proj))) $filtered
    Check 'uninstall: the project aggregate row counts only the filtered rows' (
        $filtered -match '2 removable hook\(s\)') $filtered

    # Enter at the scope prompt and Enter at the selection: the project route
    # with its remove-all row, i.e. the two removable records and nothing else.
    $filteredDefault = [string]$uninstallRuns['filteredDefault']
    $filteredDefaultCalls = @(([string]$uninstallRuns['filteredDefaultCalls']) -split "`r?`n" | Where-Object { $_ -ne '' })
    Check 'uninstall: pressing Enter twice takes the project route and its remove-all row' (
        ($filteredDefault -match 'Showing only hooks installed in') -and
        ($filteredDefault -match 'installations to remove: 2')) $filteredDefault
    Check 'uninstall: and that default removed exactly the filtered project''s records' (
        ((@($filteredDefaultCalls | Sort-Object -Unique) -join ',') -match 'zzz-removable-a') -and
        ((@($filteredDefaultCalls | Sort-Object -Unique) -join ',') -match 'zzz-removable-b') -and
        ((@($filteredDefaultCalls | Sort-Object -Unique) -join ',') -notmatch 'zzz-blocked')) (@($filteredDefaultCalls) -join ',')

    # A path pasted from Explorer arrives wrapped in quotes; the same rows must
    # come back, otherwise the feature fails on the most common way to type one.
    $filteredQuoted = [string]$uninstallRuns['filteredQuoted']
    Check 'uninstall: a quoted project folder resolves exactly like an unquoted one' (
        ($filteredQuoted -match 'ZZZ-Menusuite-Fixture') -and ($filteredQuoted -notmatch 'ZZZ-Blocked-One')) $filteredQuoted

    # Containment, not equality: a parent folder covers the projects under it.
    $filteredParent = [string]$uninstallRuns['filteredParent']
    Check 'uninstall: a parent folder includes the projects underneath it' (
        ($filteredParent -match 'ZZZ-Blocked-One') -and ($filteredParent -match 'ZZZ-Blocked-Two')) $filteredParent
    Check 'uninstall: and still excludes a project outside that parent' (
        $filteredParent -notmatch 'ZZZ-Menusuite-Fixture') $filteredParent

    # An empty match is a normal answer, not a failure: say so and offer the
    # scope menu again rather than dropping the user out of the screen.
    $filteredEmpty = [string]$uninstallRuns['filteredEmpty']
    Check 'uninstall: a folder with no tracked install says so instead of an empty list' (
        $filteredEmpty -match 'No tracked hooks are installed in') $filteredEmpty
    Check 'uninstall: and never draws a hook list for it' (
        $filteredEmpty -notmatch 'Installed hooks:') $filteredEmpty
    Check 'uninstall: the refusal re-asks instead of exiting the screen' (
        (@([regex]::Matches($allBlocked, [regex]::Escape('Installed hooks:'))).Count -eq 2) -and
        ($allBlocked -match 'Canceled\. Nothing was changed\.')) $allBlocked

    # ---- where a record lives (round 40) -----------------------------------
    # The uninstall outcome lines used to print only an opaque record id, so a
    # row asking for manual repair told the user nothing about WHICH hook it was
    # or where to go and look - the id had to be resolved against the registry
    # by hand. A native Git hook is one exact file, and that path is the answer.
    $locNative = [pscustomobject]@{
        friendlyName = 'pre-push (Ftree)'
        scope        = 'project'
        targetProjectRoot = 'G:\proj\Ftree'
        nativeGit    = [pscustomobject]@{ hookPath = 'G:\proj\Ftree\.git\hooks\pre-push' }
    }
    Check 'location: a native Git hook reports its exact file path' ((Get-RecordLocationText $locNative) -eq 'G:\proj\Ftree\.git\hooks\pre-push') (Get-RecordLocationText $locNative)

    $locProject = [pscustomobject]@{ friendlyName = 'Secrets-Check'; scope = 'project'; targetProjectRoot = 'G:\proj\Thing' }
    Check 'location: a project install reports its project root' ((Get-RecordLocationText $locProject) -eq 'G:\proj\Thing') (Get-RecordLocationText $locProject)

    $locGlobal = [pscustomobject]@{ friendlyName = 'Secrets-Check'; scope = 'global'; targetProjectRoot = '' }
    Check 'location: a global install says so instead of showing an empty path' ((Get-RecordLocationText $locGlobal) -match 'global') (Get-RecordLocationText $locGlobal)

    # Never render a blank or misleading location: an unknown one must SAY it is
    # unknown, otherwise the line reads as though the hook is nowhere.
    $locUnknown = [pscustomobject]@{ friendlyName = 'x'; scope = 'project'; targetProjectRoot = '' }
    Check 'location: an unresolvable record says the location is unknown' ((Get-RecordLocationText $locUnknown) -match 'unknown') (Get-RecordLocationText $locUnknown)
    Check 'location: a null record does not throw' ((Get-RecordLocationText $null) -match 'unknown') (Get-RecordLocationText $null)
