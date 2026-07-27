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

# The one profile that ships in sync-hooks.example.json. It is disabled and its
# routes point at placeholder paths, so it can never match a real project - which
# is why the reset action keeps it as the editable template while removing every
# wizard-created group.
$script:ExampleProfileId = 'example-sync-profile'

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

# ----------------------------------------------- transitive group merge ----
# A new sync group that shares ANY project with an existing group is really the
# same mesh - the user linked them. Sync 1,2,3 then sync 4 with 3, and 4 must
# end up meshed with 1, 2 AND 3, not only 3. This computes the transitive
# closure (every existing profile whose members intersect the growing set is
# absorbed) and returns ONE full-mesh profile over the union.
#
# The merged profile REUSES the id of the LARGEST absorbed group (the "anchor").
# The engine filters routes by the installed -Profile id and reads the live
# config at run time (Cross-Project-.ai-Knowledge-Sync.ps1 line ~537), so the
# anchor group's already-installed hooks keep working and automatically pick up
# the widened mesh with no reinstall. Only NEW projects and members of the
# smaller absorbed groups (whose old profile id is being removed) need an engine
# install pointing at the anchor id. A brand-new group with no overlap keeps its
# deterministic hash id and installs into all of its projects.
function Get-SyncProfileMembers {
    param([Parameter(Mandatory = $true)]$ProfileObj)
    $seen = @{}
    $members = New-Object System.Collections.Generic.List[object]
    foreach ($route in @($ProfileObj.routes)) {
        foreach ($endpoint in @($route.source, $route.destination)) {
            if ($null -eq $endpoint) { continue }
            $root = ''
            try { $root = [string]$endpoint.root } catch { $root = '' }
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $lower = $root.ToLowerInvariant()
            if ($seen.ContainsKey($lower)) { continue }
            $seen[$lower] = $true
            $name = ''
            try { $name = [string]$endpoint.name } catch { $name = '' }
            if ([string]::IsNullOrWhiteSpace($name)) { $name = Split-Path -Leaf $root }
            [void]$members.Add([pscustomobject]@{ Name = $name; Root = $root; Lower = $lower })
        }
    }
    return $members.ToArray()
}

function Get-SyncGroupMerge {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$NewProjects,
        # Absorb ONLY groups whose every member is already one of the entered
        # projects. A group that would drag in projects the user did not name is
        # left alone, and the shared project simply belongs to both groups - the
        # engine iterates every profile, so it still receives from both.
        #
        # This exists because the closure is silently enormous: adding one
        # project that happens to belong to another cluster merges that whole
        # cluster, and any cluster IT touches, in one step. That is right when
        # the user means "link these", and wrong when they mean "just add this
        # one project". The caller asks; this switch is the "no" answer.
        [switch]$NoExpand
    )
    $existingProfiles = @()
    if ($null -ne $Config.PSObject.Properties['profiles'] -and $null -ne $Config.profiles) {
        $existingProfiles = @($Config.profiles)
    }

    # union of roots (lowercased), seeded with the just-entered projects
    $unionLower = @{}
    $entryByLower = @{}
    # The entered set never grows - it is what "expansion" is measured against.
    $enteredLower = @{}
    foreach ($project in @($NewProjects)) {
        $lower = $project.Root.ToLowerInvariant()
        $unionLower[$lower] = $true
        $entryByLower[$lower] = $project
        $enteredLower[$lower] = $true
    }
    # Absorbed groups that bring in at least one project the user did not enter.
    # Reported whether or not they were absorbed, so the caller can show exactly
    # what a "yes" would pull in before anything is decided.
    $expansionProfiles = New-Object System.Collections.Generic.List[object]

    # transitive closure: keep absorbing profiles until none intersects the union
    $overlap = New-Object System.Collections.Generic.List[object]
    $overlapIds = @{}
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($prof in $existingProfiles) {
            $profId = ''
            try { $profId = [string]$prof.id } catch { $profId = '' }
            if ([string]::IsNullOrWhiteSpace($profId) -or $overlapIds.ContainsKey($profId)) { continue }
            $members = Get-SyncProfileMembers -ProfileObj $prof
            $intersects = $false
            foreach ($m in $members) { if ($unionLower.ContainsKey($m.Lower)) { $intersects = $true; break } }
            if (-not $intersects) { continue }
            # Does this group reach beyond what the user actually named?
            $outsiders = @($members | Where-Object { -not $enteredLower.ContainsKey($_.Lower) })
            if ($outsiders.Count -gt 0) {
                [void]$expansionProfiles.Add([pscustomobject]@{
                        Id       = $profId
                        Name     = (Get-ProfileDisplayName -ProfileObj $prof -Fallback $profId)
                        Members  = $members
                        Outsider = $outsiders
                    })
                # -NoExpand stops here: not absorbed, union not widened, so the
                # closure never reaches whatever THAT group is linked to either.
                if ($NoExpand) { continue }
            }
            $overlapIds[$profId] = $true
            [void]$overlap.Add([pscustomobject]@{ Id = $profId; Profile = $prof; Members = $members; Count = $members.Count })
            foreach ($m in $members) {
                if (-not $unionLower.ContainsKey($m.Lower)) {
                    $unionLower[$m.Lower] = $true
                    if (-not $entryByLower.ContainsKey($m.Lower)) {
                        $aiPath = Join-Path $m.Root '.ai'
                        $entryByLower[$m.Lower] = [pscustomobject][ordered]@{
                            Name     = $m.Name
                            Root     = $m.Root
                            AiPath   = $aiPath
                            AiExists = (Test-Path -LiteralPath $aiPath -PathType Container)
                        }
                    }
                }
            }
            $changed = $true
        }
    }

    $allMembers = @($entryByLower.Values | Sort-Object -Property Root)

    # anchor = the largest absorbed group; reuse its id so its hooks keep working
    $anchorId = ''
    $anchorMembersLower = @{}
    if ($overlap.Count -gt 0) {
        $anchor = @($overlap | Sort-Object -Property @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Id }; Descending = $false })[0]
        $anchorId = $anchor.Id
        foreach ($m in $anchor.Members) { $anchorMembersLower[$m.Lower] = $true }
    }

    $merged = New-GroupProfile -Projects $allMembers
    if (-not [string]::IsNullOrWhiteSpace($anchorId)) {
        $merged.id = $anchorId
    }

    # keep a route the user had DISABLED in an absorbed profile disabled after the
    # merge - the widening must never silently re-enable a route they turned off.
    $disabledPairs = @{}
    foreach ($o in $overlap) {
        foreach ($route in @($o.Profile.routes)) {
            $enabled = $true
            if ($null -ne $route.PSObject.Properties['enabled']) { try { $enabled = [bool]$route.enabled } catch { $enabled = $true } }
            if ($enabled) { continue }
            if ($null -eq $route.source -or $null -eq $route.destination) { continue }
            $key = ([string]$route.source.root).ToLowerInvariant() + '|' + ([string]$route.destination.root).ToLowerInvariant()
            $disabledPairs[$key] = $true
        }
    }
    if ($disabledPairs.Count -gt 0) {
        foreach ($route in @($merged.routes)) {
            $key = ([string]$route.source.root).ToLowerInvariant() + '|' + ([string]$route.destination.root).ToLowerInvariant()
            if ($disabledPairs.ContainsKey($key)) { $route.enabled = $false }
        }
    }

    # engine (re)install set: everything in the union that is NOT already an
    # anchor member (anchor members keep their hook + widened mesh automatically).
    $installMembers = @($allMembers | Where-Object { -not $anchorMembersLower.ContainsKey($_.Root.ToLowerInvariant()) })

    return [pscustomobject]@{
        Profile           = $merged
        AllMembers        = @($allMembers)
        InstallMembers    = @($installMembers)
        RemoveProfileIds  = @($overlapIds.Keys)
        MergedFromCount   = $overlap.Count
        # Groups that reach beyond the entered projects. Non-empty means the
        # caller has a real choice to put to the user.
        ExpansionProfiles = @($expansionProfiles.ToArray())
        # Projects that a "yes" would add and a "no" would leave out.
        ExpansionMembers  = @($allMembers | Where-Object { -not $enteredLower.ContainsKey($_.Root.ToLowerInvariant()) })
    }
}

# A sync profile's display name, falling back to its id when unnamed - used by
# the expansion prompt, which must be able to name every group it lists.
function Get-ProfileDisplayName {
    param($ProfileObj, [string]$Fallback)
    $name = ''
    if ($null -ne $ProfileObj -and $null -ne $ProfileObj.PSObject.Properties['name']) {
        try { $name = [string]$ProfileObj.name } catch { $name = '' }
    }
    if ([string]::IsNullOrWhiteSpace($name)) { return $Fallback }
    return $name
}

# --------------------------------------------------- sync group flow (1) ----
function Invoke-CreateGroup {
    Write-Log 'INFO' 'GROUP' 'Create/update sync group started.'
    # Published so the "install an existing hook" flow can reuse THIS group's
    # project paths as the install targets for any other hooks selected in the
    # same batch - the user enters the paths once, not once per menu item.
    # Reset up front so a back/cancel never leaves a previous run's paths behind.
    $script:LastGroupProjects = @()
    $script:LastGroupClients = ''

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
            # Merge with any existing group that shares a project (transitive):
            # one full-mesh profile over the union, reusing the largest absorbed
            # group's id so its hooks keep working without reinstall.
            #
            # But NEVER silently. If one of the entered projects already belongs
            # to another group, the closure would pull that whole cluster - and
            # everything IT touches - into this mesh. That is a decision, not a
            # detail, so it is shown in full and asked, defaulting to NO.
            $merge = Get-SyncGroupMerge -Config $config -NewProjects $projects
            if (@($merge.ExpansionProfiles).Count -gt 0) {
                $enteredLookup = @{}
                foreach ($p in @($projects)) { $enteredLookup[$p.Root.ToLowerInvariant()] = $true }
                Write-Host ''
                Write-MenuTitle 'These entered project(s) already belong to other sync group(s):'
                foreach ($grp in @($merge.ExpansionProfiles)) {
                    Write-Host ''
                    Write-Field '  group' ([string]$grp.Name) $C.Aqua
                    Write-Field '  id' ([string]$grp.Id)
                    foreach ($m in @($grp.Members)) {
                        $mark = '+'
                        $markColor = $C.Amber
                        if ($enteredLookup.ContainsKey(([string]$m.Root).ToLowerInvariant())) {
                            $mark = '='
                            $markColor = $C.Mint
                        }
                        Write-Host ('    ' + (Get-Painted $mark $markColor) + ' ' + [string]$m.Name + '  ' + [string]$m.Root)
                    }
                }
                Write-Host ''
                Write-NoteLine ('  ' + (Get-Painted '=' $C.Mint) + ' already entered    ' +
                    (Get-Painted '+' $C.Amber) + ' would be ADDED to this mesh')
                Write-NoteLine ('  Answering yes merges ' + @($merge.ExpansionProfiles).Count +
                    ' group(s) and every group they are linked to into ONE mesh of ' +
                    @($merge.AllMembers).Count + ' project(s) - each syncs with all the others.')
                Write-NoteLine '  Answering no adds only the project(s) you entered. The other groups stay as they are,'
                Write-NoteLine '  and a project in both simply belongs to both - it still receives from each.'
                # Membership is CONFIGURATION in sync-hooks.json, not proof that
                # anything is installed. Uninstalling every hook leaves the group
                # topology untouched on purpose - removing a hook must not
                # silently destroy the mesh the user built - but then this screen
                # reads as "these projects are syncing" when nothing is running.
                Write-NoteLine '  Membership is routing configuration, not installed hooks: a group keeps its projects'
                Write-NoteLine '  even after every hook is uninstalled, and syncing only happens once hooks are installed.'
                Write-Log 'INFO' 'GROUP' ('Expansion offered: groups=' + @($merge.ExpansionProfiles).Count +
                    '; wouldAdd=' + @($merge.ExpansionMembers).Count + '; unionIfYes=' + @($merge.AllMembers).Count)
                # Through New-QuestionPrompt like every other yes/no question, so
                # the prompt actually SHOWS its default. Read-YesNo only puts the
                # default in its retry message, so a bare string renders with no
                # [n] at all and the user cannot tell what Enter does.
                $expand = Read-YesNo (New-QuestionPrompt 'Also sync the connected group(s)?' 'y/n' 'n') $false 'sync group expand'
                if ($null -eq $expand) { return 'back' }
                if (-not $expand) {
                    $merge = Get-SyncGroupMerge -Config $config -NewProjects $projects -NoExpand
                    Write-Log 'INFO' 'GROUP' ('Expansion DECLINED: mesh limited to ' + @($merge.AllMembers).Count + ' entered project(s).')
                }
                else {
                    Write-Log 'INFO' 'GROUP' ('Expansion ACCEPTED: mesh of ' + @($merge.AllMembers).Count + ' project(s).')
                }
            }
            $groupProfile = $merge.Profile
            $allMembers = @($merge.AllMembers)
            $installMembers = @($merge.InstallMembers)
            $removeProfileIds = @($merge.RemoveProfileIds)
            $mergedFromCount = $merge.MergedFromCount
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
        if ($mergedFromCount -gt 0) {
            Write-NoteLine ('  Merges with ' + $mergedFromCount + ' existing sync group(s) into one full mesh of ' + $allMembers.Count + ' project(s) - every member syncs with every other.')
        }
        Write-MenuTitle 'Sync group:'
        for ($i = 0; $i -lt $allMembers.Count; $i++) {
            $project = $allMembers[$i]
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
    Write-Log 'INFO' 'GROUP' ('Confirmed. profile=' + $groupProfile.id + ' | name="' + $groupProfile.name + '" | projects=' + $allMembers.Count + ' | mergedFrom=' + $mergedFromCount + ' | reinstall=' + @($installMembers).Count + ' | routes=' + $routeCount + ' (full mesh) | events=' + ($events -join ',') + ' | client=' + $installScope + ' | config=' + $ConfigPath)
    foreach ($project in $allMembers) {
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
    foreach ($project in $allMembers) {
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
    # Drop every absorbed profile (the transitive-closure merge) and any profile
    # sharing the merged id, then add the single merged full-mesh profile.
    $removeSet = @{}
    foreach ($rid in @($removeProfileIds)) { $removeSet[[string]$rid] = $true }
    $removeSet[[string]$groupProfile.id] = $true
    $replaced = $false
    $newProfiles = New-Object System.Collections.Generic.List[object]
    foreach ($existing in $existingProfiles) {
        if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['id'] -and $removeSet.ContainsKey([string]$existing.id)) {
            $replaced = $true
            continue
        }
        [void]$newProfiles.Add($existing)
    }
    [void]$newProfiles.Add($groupProfile)
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
        # Install the engine only where it's needed: the new projects and any
        # member of a smaller absorbed group (whose old profile id was removed).
        # Members of the anchor group already carry a hook pointing at the reused
        # id and pick up the widened mesh from the live config with no reinstall.
        if (@($installMembers).Count -eq 0) {
            Write-NoteLine '  All members already carry the sync hook; the widened mesh applies with no reinstall.'
        }
        foreach ($project in $installMembers) {
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
    $installSummary = if ($NoInstall) { 'not installed (-NoInstall)' } else { $clients + ' in ' + @($installMembers).Count + ' of ' + $allMembers.Count + ' project(s)' }
    Write-Log 'INFO' 'DONE' ('Sync group applied: ' + $groupProfile.id + ' | routes=' + $routeCount + ' | events=' + ($events -join ',') + ' | install=' + $installSummary + ' | durationMs=' + $stopwatch.ElapsedMilliseconds)
    $script:LastGroupProjects = @($projects)
    # Carried to the hook flow in the same batch so "which client" is asked once.
    $script:LastGroupClients = $clients
    return 'done'
}

# ---- reset every sync group ------------------------------------------------
# Removes all wizard-created sync groups and leaves the config exactly as a
# fresh install has it: version + defaults + the disabled example profile.
#
# This exists because group membership is CONFIGURATION and deliberately
# survives uninstalling every hook (see Invoke-CreateGroup) - which means a user
# who has removed all their hooks still gets told their projects "already belong
# to" groups, with no supported way to clear that. Editing sync-hooks.json by
# hand was the only route.
#
# The example profile is KEPT: it ships disabled and points at placeholder paths
# (D:\Projects\Project A), so it can never match a real project or trigger the
# overlap prompt, and removing it would leave no template to edit.
function Invoke-ResetSyncGroups {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$ValidateScript
    )
    Write-Log 'INFO' 'RESET' 'Reset sync groups started.'
    Write-PhaseHeader 'Reset Sync Groups' $C.Input '-'

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-NoteLine '  There is no sync configuration file yet - nothing to reset.'
        Write-Log 'INFO' 'RESET' 'No config file; nothing to reset.'
        return 'done'
    }
    $config = $null
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Write-ErrorLine ('The sync configuration could not be read: ' + $_.Exception.Message)
        Write-NoteLine '  It has NOT been modified. Repair or remove the file, then try again.'
        Write-Log 'ERROR' 'RESET' ('Config unreadable: ' + $_.Exception.Message)
        return 'done'
    }

    $existing = @()
    if ($null -ne $config.PSObject.Properties['profiles'] -and $null -ne $config.profiles) {
        $existing = @($config.profiles)
    }
    $groups = @($existing | Where-Object { $null -ne $_ -and [string]$_.id -ne $script:ExampleProfileId })
    if ($groups.Count -eq 0) {
        Write-NoteLine '  No sync groups are configured - nothing to reset.'
        Write-Log 'INFO' 'RESET' 'No groups configured; nothing to reset.'
        return 'done'
    }

    Write-NoteLine ('  ' + $groups.Count + ' sync group(s) would be removed from the configuration:')
    foreach ($g in $groups) {
        $routeCount = 0
        if ($null -ne $g.PSObject.Properties['routes'] -and $null -ne $g.routes) { $routeCount = @($g.routes).Count }
        Write-Host ('    ' + (Get-Painted ([string]$g.id) $C.Aqua) + $script:MenuSep +
            (Get-Painted ([string]$g.name) $C.Gray) + $script:MenuSep +
            (Get-Painted ($routeCount.ToString() + ' route(s)') $C.Dim))
    }
    Write-NoteLine '  This changes routing configuration ONLY. No hook is uninstalled and no file'
    Write-NoteLine '  in any project is touched - use the uninstall action for that.'
    Write-NoteLine '  A timestamped backup of the current configuration is written first.'

    $confirm = Read-YesNo (New-QuestionPrompt ('Remove all ' + $groups.Count + ' sync group(s) now?') 'y/n' 'n') $false 'confirm reset sync groups'
    if ($null -eq $confirm) { return 'back' }
    if (-not $confirm) {
        Write-NoteLine '  Canceled. Nothing was changed.'
        Write-Log 'INFO' 'RESET' 'Reset declined; no change.'
        return 'done'
    }

    $backupPath = $ConfigPath + '.backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
    Write-Log 'INFO' 'RESET' ('Config backup created: ' + $backupPath)

    $kept = @($existing | Where-Object { $null -ne $_ -and [string]$_.id -eq $script:ExampleProfileId })
    Set-ObjectProperty -Object $config -Name 'profiles' -Value $kept
    Write-JsonFileAtomic -Value $config -Path $ConfigPath

    Write-Host ('  ' + (Get-Painted ('- removed ' + $groups.Count + ' sync group(s)') $C.Green))
    Write-Field 'backup' $backupPath
    Write-Log 'INFO' 'RESET' ('Reset complete: removed=' + $groups.Count + '; kept=' + @($kept).Count + '; backup=' + $backupPath)

    $validateOutput = & $ValidateScript -ConfigPath $ConfigPath *>&1
    foreach ($line in @($validateOutput)) { Write-Log 'DEBUG' 'VALIDATE' ([string]$line) }
    Write-Host ('  ' + (Get-Painted '+ configuration validated' $C.Green))
    return 'done'
}
