# ---------------------------------------------------------------------------
# A sync group AS DATA: the full-mesh route profile built from a set of
# projects, who belongs to an existing profile, the transitive-closure merge
# that decides which existing groups an entry absorbs, and a profile's display
# name.
#
# Split out of Setup-SyncGroupBuilder.ps1 at the 800-line ceiling. That file
# keeps the interactive flow - reading the project list, confirming, applying,
# resetting - and this one holds the computation underneath it. The seam is
# real and was already recognised: Test-SyncGroupMerge.ps1 exercises exactly
# these functions with the wizard's console machinery stubbed out, because they
# touch no filesystem and print nothing.
#
# Dot-sourced by Setup-SyncGroupBuilder.ps1 in the position the block occupied.
# Like that file, these functions rely on the wizard's ambient script-scope
# helpers (Get-ShortHash, Get-Slug) resolved at call time.
# ---------------------------------------------------------------------------

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

