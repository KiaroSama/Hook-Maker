# ---------------------------------------------------------------------------
# Sync-group builder: collecting project paths, building the full-mesh route
# profile, and confirming + applying a new or updated sync group.
#
# Split out of Setup-SyncGroup.ps1 (which had grown past the file-size review
# signal) because this is a genuine cohesive unit: Invoke-CreateGroup has
# exactly one external caller (the "install an existing hook" menu flow),
# New-GroupProfile is private to it, and Read-ProjectList is a shared helper
# also used by other wizard flows that collect a project list.
#
# Dot-sourced by Setup-SyncGroup.ps1 only. These functions rely on that
# script's ambient script-scope state ($ToolRoot/$ConfigPath/$C/Write-Log/
# Write-PhaseHeader/Read-Answer/etc.) - dot-sourcing splices this file's
# functions into the caller's scope, and calls resolve at invocation time,
# so this is a normal one-directional dependency, not a layering violation.
# ---------------------------------------------------------------------------

# ----------------------------------------------------------- input phase ----
# Collects project root paths. Returns an array, or $null when the user backs out.
function Read-ProjectList {
    param(
        [int]$MinimumCount = 2,
        [switch]$ShowAiNote,
        [object[]]$InitialProjects = @()
    )

    Write-PhaseHeader 'Add Projects' $C.Input '-'
    Write-MenuTitle 'Target projects:'
    Write-Host (Get-Painted ('  Enter each project root path, one per line (at least ' + $MinimumCount + ').') $C.Gray)

    $projects = New-Object System.Collections.Generic.List[object]
    foreach ($project in @($InitialProjects)) {
        [void]$projects.Add($project)
    }
    $example = Get-ExampleText 'G:\Projects\My Bot'
    # Reserve ONE top-level question number for this whole repeated-entry flow;
    # every child prompt below renders as "<parent>-<slot>" instead of stealing
    # a fresh top-level integer per path. The slot advances only when an entry
    # is actually accepted (see below); invalid/duplicate/overlapping input and
    # a premature "done" re-display the same slot, and "undo" steps it back.
    $parentNumber = Get-ReservedQuestionNumber
    $childNumber = 1
    while ($true) {
        $prompt = New-NestedQuestionPrompt -ParentNumber $parentNumber -ChildNumber $childNumber -Title 'Project root path' -Details ('done=finish, undo=remove last; example: ' + $example) -Default $null
        $value = Read-Answer $prompt 'project root path'
        if ($value -eq '0') {
            Write-Log 'INFO' 'INPUT' 'User backed out of project entry.'
            return $null
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-ErrorLine 'This value cannot be empty. Enter a path, or done to finish.'
            continue
        }
        $lower = $value.ToLowerInvariant()

        if ($lower -eq 'undo') {
            if ($projects.Count -gt 0) {
                $removed = $projects[$projects.Count - 1]
                $projects.RemoveAt($projects.Count - 1)
                if ($childNumber -gt 1) { $childNumber-- }
                Write-Host ('  ' + (Get-Painted ('- removed ' + $removed.Name + '  ' + $removed.Root) $C.Dim))
                Write-Log 'INFO' 'INPUT' ('Removed project: ' + $removed.Root)
            }
            else {
                Write-NoteLine 'Nothing to undo.'
            }
            continue
        }
        if ($lower -eq 'done') {
            if ($projects.Count -ge $MinimumCount) {
                break
            }
            Write-ErrorLine ('At least ' + $MinimumCount + ' project(s) required (currently ' + $projects.Count + ').')
            continue
        }

        try {
            $root = Normalize-Path $value
        }
        catch {
            Write-ErrorLine ('Invalid path: ' + $value)
            Write-Log 'WARNING' 'INPUT' ('Invalid path rejected: ' + $value)
            continue
        }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-ErrorLine ('Directory not found: ' + $root)
            Write-Log 'WARNING' 'INPUT' ('Missing directory rejected: ' + $root)
            continue
        }

        $isDuplicate = $false
        foreach ($existing in $projects) {
            if ([string]::Equals($existing.Root, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isDuplicate = $true
                break
            }
        }
        if ($isDuplicate) {
            Write-NoteLine ('Already added: ' + $root)
            Write-Log 'WARNING' 'INPUT' ('Duplicate rejected: ' + $root)
            continue
        }

        $overlap = $null
        foreach ($existing in $projects) {
            if ((Test-PathInside -Candidate $root -Parent $existing.Root) -or (Test-PathInside -Candidate $existing.Root -Parent $root)) {
                $overlap = $existing
                break
            }
        }
        if ($null -ne $overlap) {
            Write-ErrorLine ('Path overlaps an already added project: ' + $overlap.Root)
            Write-Log 'WARNING' 'INPUT' ('Nested path rejected: ' + $root + ' vs ' + $overlap.Root)
            continue
        }

        $aiPath = Join-Path $root '.ai'
        $entry = [pscustomobject][ordered]@{
            Name     = Split-Path -Leaf $root
            Root     = $root
            AiPath   = $aiPath
            AiExists = (Test-Path -LiteralPath $aiPath -PathType Container)
        }
        [void]$projects.Add($entry)

        $note = ''
        if ($ShowAiNote) {
            if ($entry.AiExists) {
                $note = ' ' + (Get-Painted '(.ai exists)' $C.Mint)
            }
            else {
                $note = ' ' + (Get-Painted '(.ai will be created)' $C.Amber)
            }
        }
        Write-Host ('  ' + (Get-Painted '+ added' $C.Green) + ' ' + (Get-Painted $entry.Name $C.Bold) + '  ' + (Get-Painted $entry.Root $C.Gray) + $note)
        Write-Log 'INFO' 'INPUT' ('Added project: ' + $root + ' | aiExists=' + $entry.AiExists)
        $childNumber++
    }

    return $projects.ToArray()
}

# --------------------------------------------------------- profile build ----
function New-GroupProfile {
    param([Parameter(Mandatory = $true)]$Projects)

    $canonical = (@($Projects | ForEach-Object { $_.Root.ToLowerInvariant() }) | Sort-Object) -join '|'
    $profileId = 'sync-group-' + (Get-ShortHash -Text $canonical)

    # Deterministic slugs: assign in sorted-root order so re-runs keep the same route ids.
    $slugMap = @{}
    $usedSlugs = @{}
    foreach ($project in @($Projects | Sort-Object -Property Root)) {
        $slug = Get-Slug -Name $project.Name
        $candidate = $slug
        $counter = 2
        while ($usedSlugs.ContainsKey($candidate)) {
            $candidate = $slug + '-' + $counter
            $counter++
        }
        $usedSlugs[$candidate] = $true
        $slugMap[$project.Root] = $candidate
    }

    $routes = New-Object System.Collections.Generic.List[object]
    foreach ($source in $Projects) {
        foreach ($destination in $Projects) {
            if ([string]::Equals($source.Root, $destination.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            [void]$routes.Add([pscustomobject][ordered]@{
                id          = $slugMap[$source.Root] + '-to-' + $slugMap[$destination.Root]
                enabled     = $true
                source      = [pscustomobject][ordered]@{
                    name      = $source.Name
                    root      = $source.Root
                    directory = '.ai'
                    aliases   = @()
                }
                destination = [pscustomobject][ordered]@{
                    name      = $destination.Name
                    root      = $destination.Root
                    directory = '.ai'
                    aliases   = @()
                }
            })
        }
    }

    return [pscustomobject][ordered]@{
        id      = $profileId
        name    = 'Sync group: ' + ((@($Projects | ForEach-Object { $_.Name })) -join ' + ')
        enabled = $true
        routes  = $routes.ToArray()
    }
}

# --------------------------------------------------- sync group flow (1) ----
function Invoke-CreateGroup {
    Write-Log 'INFO' 'GROUP' 'Create/update sync group started.'

    $config = Read-JsonFile $ConfigPath
    if ($null -eq $config) {
        Write-ErrorLine ('Config file not found or empty: ' + $ConfigPath)
        Write-Log 'ERROR' 'CONFIG' ('Config missing or empty: ' + $ConfigPath)
        return 'back'
    }

    $events = @('SessionStart', 'UserPromptSubmit')
    if ($null -ne $config.PSObject.Properties['defaults'] -and $null -ne $config.defaults -and
        $null -ne $config.defaults.PSObject.Properties['events'] -and $null -ne $config.defaults.events) {
        $events = @($config.defaults.events)
    }

    # Optional config mode: the engine's .env can predefine the group's project
    # paths (SYNC_PROJECTS) so nothing has to be typed.
    $configProjects = @()
    $engineEnv = Read-HookEnv (Join-Path $HooksDir 'Cross-Project-.ai-Knowledge-Sync\.env')
    if ($engineEnv.ContainsKey('SYNC_PROJECTS') -and $engineEnv['SYNC_PROJECTS'] -ne '') {
        foreach ($path in @($engineEnv['SYNC_PROJECTS'].Split(';') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })) {
            try {
                $root = Normalize-Path $path
            }
            catch {
                Write-NoteLine ('Ignoring invalid path in SYNC_PROJECTS: ' + $path)
                continue
            }
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-NoteLine ('Ignoring missing directory in SYNC_PROJECTS: ' + $root)
                continue
            }
            $aiPath = Join-Path $root '.ai'
            $configProjects += [pscustomobject][ordered]@{
                Name     = Split-Path -Leaf $root
                Root     = $root
                AiPath   = $aiPath
                AiExists = (Test-Path -LiteralPath $aiPath -PathType Container)
            }
        }
    }

    # Stage machine: project entry (0) <-> client (1) <-> confirm (2). Back steps
    # one stage; back at project entry returns to the main menu.
    $projects = $null
    $groupProfile = $null
    $clients = 'Both'
    $routeCount = 0
    $stage = 0
    while ($true) {
        if ($stage -eq 0) {
            $projects = $null
            if ($configProjects.Count -ge 2) {
                $useConfig = Read-YesNo (New-QuestionPrompt 'Use the project paths from the config?' ($configProjects.Count.ToString() + ' path(s) in the engine .env') 'y') $true 'use sync config'
                if ($null -eq $useConfig) {
                    return 'back'
                }
                if ($useConfig -eq $true) {
                    $projects = @($configProjects)
                }
            }
            if ($null -eq $projects) {
                $projects = Read-ProjectList -MinimumCount 2 -ShowAiNote
                if ($null -eq $projects) {
                    return 'back'
                }
            }
            $groupProfile = New-GroupProfile -Projects $projects
            $routeCount = @($groupProfile.routes).Count
            $stage = 1
            continue
        }
        if ($stage -eq 1) {
            # Which client(s) gets the sync hook (Claude / Codex / both).
            $clients = Read-ClientChoice
            if ($null -eq $clients) {
                $stage = 0
                continue
            }
            Write-Log 'INFO' 'GROUP' ('Client target selected: ' + $clients)
            $stage = 2
            continue
        }

        # stage 2: summary + confirm
        Write-PhaseHeader 'Summary' $C.Summary '-'
        Write-MenuTitle 'Sync group:'
        for ($i = 0; $i -lt $projects.Count; $i++) {
            $project = $projects[$i]
            $note = '(.ai will be created)'
            $noteColor = $C.Amber
            if ($project.AiExists) {
                $note = '(.ai exists)'
                $noteColor = $C.Mint
            }
            Write-MenuLine ($i + 1) $project.Name ($project.Root + '  ')
            Write-Host ('     ' + (Get-Painted $note $noteColor))
        }
        Write-Host ''
        Write-Field 'profile id' $groupProfile.id $C.Aqua
        Write-Field 'profile name' $groupProfile.name
        Write-Field 'routes' ($routeCount.ToString() + ' (full mesh)')
        Write-Field 'events' ($events -join ', ')
        Write-Field 'config file' $ConfigPath $C.LightBlue
        if ($NoInstall) {
            Write-Field 'hook install' 'skipped (-NoInstall)' $C.Amber
        }
        else {
            Write-Field 'client' $clients
            Write-Field 'hook install' (Get-ClientInstallLabel $clients)
        }
        Write-Host ''
        Write-Host (Get-Painted '  Routes:' $C.Gray)
        foreach ($route in @($groupProfile.routes)) {
            Write-Host ('    ' + (Get-Painted ($route.source.name + ' -> ' + $route.destination.name) $C.Dim))
        }

        Write-PhaseHeader 'Confirm' $C.Confirm '-'
        $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start sync group'
        if ($null -eq $confirm) {
            $stage = 1
            continue
        }
        if ($confirm -ne $true) {
            Write-NoteLine 'Canceled. Nothing was changed.'
            Write-Log 'INFO' 'GROUP' 'User declined at confirmation; no changes applied.'
            return 'canceled'
        }
        break
    }
    $installScope = if ($NoInstall) { 'skipped (-NoInstall)' } else { $clients }
    Write-Log 'INFO' 'GROUP' ('Confirmed. profile=' + $groupProfile.id + ' | name="' + $groupProfile.name + '" | projects=' + $projects.Count + ' | routes=' + $routeCount + ' (full mesh) | events=' + ($events -join ',') + ' | client=' + $installScope + ' | config=' + $ConfigPath)
    foreach ($project in $projects) {
        Write-Log 'DEBUG' 'GROUP' ('Project: ' + $project.Name + ' | root=' + $project.Root + ' | aiExists=' + $project.AiExists)
    }
    foreach ($route in @($groupProfile.routes)) {
        Write-Log 'DEBUG' 'GROUP' ('Route ' + $route.id + ': ' + $route.source.name + ' -> ' + $route.destination.name + ' | src=' + $route.source.root + ' | dst=' + $route.destination.root)
    }

    # ---- apply ----
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-PhaseHeader 'Applying Changes' $C.Process '-'

    # Creating a project's .ai directory can fail (permission denied, path in
    # use, read-only location). That must NOT crash the whole wizard and eject
    # the user - catch it, report which project failed, and abort this install
    # cleanly back to the menu BEFORE any profile/config is written, so nothing
    # is left half-applied and the user can fix access and retry. A LATER
    # project's failure must not leave an EARLIER project's freshly-created
    # empty .ai directory behind while claiming "nothing was changed" - track
    # every directory actually created THIS run and roll it back on any failure.
    $aiCreateFailures = New-Object System.Collections.Generic.List[object]
    $aiCreatedThisRun = New-Object System.Collections.Generic.List[string]
    foreach ($project in $projects) {
        if (-not $project.AiExists) {
            try {
                New-Item -ItemType Directory -Path $project.AiPath -Force -ErrorAction Stop | Out-Null
                [void]$aiCreatedThisRun.Add($project.AiPath)
                Write-Host ('  ' + (Get-Painted '+ created' $C.Green) + ' ' + (Get-Painted $project.AiPath $C.LightBlue))
                Write-Log 'INFO' 'CONFIG' ('Created knowledge directory: ' + $project.AiPath)
            }
            catch {
                [void]$aiCreateFailures.Add([pscustomobject]@{ Path = $project.AiPath; Reason = $_.Exception.Message })
                Write-Host ('  ' + (Get-Painted '! failed ' $C.Amber) + ' ' + (Get-Painted $project.AiPath $C.LightBlue))
                Write-Log 'ERROR' 'CONFIG' ('Could not create knowledge directory: ' + $project.AiPath + ' | ' + $_.Exception.Message)
            }
        }
        else {
            Write-Host ('  ' + (Get-Painted ('= exists  ' + $project.AiPath) $C.Dim))
            Write-Log 'DEBUG' 'CONFIG' ('Knowledge directory exists: ' + $project.AiPath)
        }
    }
    if ($aiCreateFailures.Count -gt 0) {
        # Roll back ONLY the .ai directories this run just created - never a
        # pre-existing one, and never one that unexpectedly gained content, so
        # user data is never at risk even if something else touched it meanwhile.
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        foreach ($createdPath in $aiCreatedThisRun) {
            try {
                $isEmpty = @(Get-ChildItem -LiteralPath $createdPath -Force -ErrorAction Stop).Count -eq 0
                if ($isEmpty) {
                    Remove-Item -LiteralPath $createdPath -Force -ErrorAction Stop
                    Write-Log 'INFO' 'CONFIG' ('Rolled back just-created knowledge directory: ' + $createdPath)
                }
                else {
                    [void]$rollbackFailures.Add($createdPath)
                }
            }
            catch {
                [void]$rollbackFailures.Add($createdPath)
                Write-Log 'ERROR' 'CONFIG' ('Could not roll back knowledge directory: ' + $createdPath + ' | ' + $_.Exception.Message)
            }
        }
        if ($rollbackFailures.Count -eq 0) {
            Write-ErrorLine ('Could not create ' + $aiCreateFailures.Count + ' knowledge (.ai) directory(ies) - likely a permission-denied or read-only location. Nothing was changed; fix access to these paths and retry:')
        }
        else {
            Write-ErrorLine ('Could not create ' + $aiCreateFailures.Count + ' knowledge (.ai) directory(ies) - likely a permission-denied or read-only location. No profile/config was written, but these directory(ies) created earlier this run could not be rolled back:')
            foreach ($path in $rollbackFailures) { Write-NoteLine ('  ' + $path) }
        }
        foreach ($failure in $aiCreateFailures) { Write-NoteLine ('  ' + $failure.Path) }
        Write-Log 'ERROR' 'GROUP' ('Aborted sync group: ' + $aiCreateFailures.Count + ' .ai directory creation failure(s); ' + ($aiCreatedThisRun.Count - $rollbackFailures.Count) + ' directory(ies) rolled back; no profile written.')
        return 'back'
    }

    $existingProfiles = @()
    if ($null -ne $config.PSObject.Properties['profiles'] -and $null -ne $config.profiles) {
        $existingProfiles = @($config.profiles)
    }
    $replaced = $false
    $newProfiles = New-Object System.Collections.Generic.List[object]
    foreach ($existing in $existingProfiles) {
        if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['id'] -and [string]$existing.id -eq $groupProfile.id) {
            [void]$newProfiles.Add($groupProfile)
            $replaced = $true
        }
        else {
            [void]$newProfiles.Add($existing)
        }
    }
    if (-not $replaced) {
        [void]$newProfiles.Add($groupProfile)
    }
    Set-ObjectProperty -Object $config -Name 'profiles' -Value $newProfiles.ToArray()
    if ($null -eq $config.PSObject.Properties['version']) {
        Set-ObjectProperty -Object $config -Name 'version' -Value 2
    }

    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $backupPath = $ConfigPath + '.backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        Write-Log 'INFO' 'CONFIG' ('Config backup created: ' + $backupPath)
    }
    Write-JsonFileAtomic -Value $config -Path $ConfigPath
    $action = 'added'
    if ($replaced) {
        $action = 'updated'
    }
    Write-Host ('  ' + (Get-Painted ('+ profile ' + $action) $C.Green) + ' ' + (Get-Painted $groupProfile.id $C.Aqua) + (Get-Painted (' (' + $routeCount + ' routes)') $C.Dim))
    Write-Log 'INFO' 'CONFIG' ('Profile ' + $action + ': ' + $groupProfile.id + ' | routes=' + $routeCount + ' | config=' + $ConfigPath)

    $validateOutput = & $ValidateScript -ConfigPath $ConfigPath *>&1
    foreach ($line in @($validateOutput)) {
        Write-Log 'DEBUG' 'VALIDATE' ([string]$line)
    }
    Write-Host ('  ' + (Get-Painted '+ configuration validated' $C.Green))
    Write-Log 'INFO' 'VALIDATE' 'Configuration validated after write.'

    if ($NoInstall) {
        Write-NoteLine '  hook install skipped (-NoInstall)'
        Write-Log 'INFO' 'INSTALL' 'Hook install skipped by -NoInstall.'
    }
    else {
        # Install the hook locally in each project, not in the user's home settings,
        # so only these projects carry the hook and nothing else on the machine is touched.
        $clientArgs = Get-ClientInstallArgs $clients
        foreach ($project in $projects) {
            Write-Log 'INFO' 'INSTALL' ('Installing engine hook -> ' + $project.Name + ' | root=' + $project.Root + ' | profile=' + $groupProfile.id + ' | client=' + $clients + ' | events=' + ($events -join ','))
            $installOutput = & $InstallScript -Profile $groupProfile.id -ConfigPath $ConfigPath -TargetProject $project.Root @clientArgs *>&1
            foreach ($line in @($installOutput)) {
                Write-Log 'INFO' 'INSTALL' ([string]$line)
            }
            Write-Host ('  ' + (Get-Painted '+ hook installed in' $C.Green) + ' ' + (Get-Painted $project.Name $C.Bold) + '  ' + (Get-Painted $project.Root $C.Gray))
        }
    }

    $stopwatch.Stop()
    Write-PhaseHeader 'Completed' $C.Done '='
    Write-Host (Get-Painted '  Restart the Claude/Codex clients and review /hooks inside each project.' $C.White)
    Write-Host (Get-Painted '  Opening any of these projects now reviews the other projects'' knowledge first.' $C.White)
    Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
    if ($null -ne $script:LogPath) {
        Write-Host (Get-Painted ('  Log: ' + $script:LogPath) $C.Dim)
    }
    $installSummary = if ($NoInstall) { 'not installed (-NoInstall)' } else { $clients + ' in ' + $projects.Count + ' project(s)' }
    Write-Log 'INFO' 'DONE' ('Sync group applied: ' + $groupProfile.id + ' | routes=' + $routeCount + ' | events=' + ($events -join ',') + ' | install=' + $installSummary + ' | durationMs=' + $stopwatch.ElapsedMilliseconds)
    return 'done'
}
