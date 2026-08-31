# "Fix a renamed or moved project" - the pure decision functions.
#
# Loaded by Test-Wizard.ps1. The other wizard blocks drive the wizard as a
# PROCESS through stdin; these functions decide what gets deleted inside a
# user's project, so they are exercised DIRECTLY with fabricated state - a
# stdin-driven run could not put a half-moved project on disk deterministically,
# and "it did not crash" is not evidence about which files it chose.

Write-Host ''
Write-Host '--- relocate: a path inside JSON has its separators doubled ---' -ForegroundColor Cyan
# The bug this exists to stop: two of my own survey scripts reported "0 stale
# documents" while 21 broken ones sat on disk, because a raw search for
# 'G:\x\y' can never match the 'G:\\x\\y' a JSON document actually stores.
$relRoot = 'G:\Program Files\Old Name'
Check 'relocate: the plain spelling is found' (
    Test-TextNamesRoot -Text ('command: ' + $relRoot + '\.kiro') -Root $relRoot)
Check 'relocate: the JSON-escaped spelling is found too' (
    Test-TextNamesRoot -Text ('{"c":"' + $relRoot.Replace('\', '\\') + '\\x"}') -Root $relRoot)
Check 'relocate: an unrelated path is not found' (
    -not (Test-TextNamesRoot -Text '{"c":"G:\\Program Files\\Other\\x"}' -Root $relRoot))
Check 'relocate: empty text is not a match' (-not (Test-TextNamesRoot -Text '' -Root $relRoot))

Write-Host ''
Write-Host '--- relocate: the hook slug is read back off a document name ---' -ForegroundColor Cyan
Check 'relocate: slug drops the prefix and the record id' (
    (Get-DocumentHookSlug -FileName 'hookmaker-ai-memory-check-e84c6df413.json') -eq 'ai-memory-check')
Check 'relocate: a hyphenated hook name survives intact' (
    (Get-DocumentHookSlug -FileName 'hookmaker-cross-project-ai-knowledge-sync-a7816458de.json') -eq 'cross-project-ai-knowledge-sync')
Check 'relocate: a foreign document yields no slug' (
    (Get-DocumentHookSlug -FileName 'something-else.json') -eq '')

Write-Host ''
Write-Host '--- relocate: an orphaned document is removable only on ALL THREE conditions ---' -ForegroundColor Cyan
$relWork = New-TestWorkspace -Prefix 'hookmaker-relocate'
try {
    $relOld = 'G:\Program Files\Gone Away'
    $relNew = Join-Path $relWork 'moved'
    $relKiro = Join-Path $relNew '.kiro\hooks'
    New-Item -ItemType Directory -Path $relKiro -Force | Out-Null

    function New-RelocDocument {
        param([string]$Name, [string]$Root, [int]$Commands = 1)
        $hooks = @()
        for ($i = 0; $i -lt $Commands; $i++) {
            $hooks += @{ name = ('h' + $i); action = @{ type = 'command'; command = ('powershell -File "' + $Root + '\.kiro\hook-runtime\x.ps1"') } }
        }
        $doc = @{ version = 'v1'; hooks = $hooks }
        [System.IO.File]::WriteAllText((Join-Path $relKiro $Name), ($doc | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
    }

    # stale + a replacement exists -> removable
    New-RelocDocument 'hookmaker-alpha-1111111111.json' $relOld
    New-RelocDocument 'hookmaker-alpha-2222222222.json' $relNew
    # stale but NOTHING replaces it -> must be left alone, or the project loses
    # the hook entirely instead of being repointed
    New-RelocDocument 'hookmaker-beta-3333333333.json' $relOld
    # mixed commands: one still points at the new root, so it is not purely
    # stale and this must not guess
    $mixed = @{ version = 'v1'; hooks = @(
            @{ name = 'a'; action = @{ type = 'command'; command = ('x "' + $relOld + '\a.ps1"') } },
            @{ name = 'b'; action = @{ type = 'command'; command = ('x "' + $relNew + '\b.ps1"') } }) }
    [System.IO.File]::WriteAllText((Join-Path $relKiro 'hookmaker-gamma-4444444444.json'), ($mixed | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
    New-RelocDocument 'hookmaker-gamma-5555555555.json' $relNew
    # a document that names neither -> untouched, never even considered
    New-RelocDocument 'hookmaker-delta-6666666666.json' $relNew

    $orphans = Get-OrphanedClientDocument -NewRoot $relNew -OldRoot $relOld
    $removableNames = @(@($orphans.Removable) | ForEach-Object { $_.Name })
    Check 'relocate: exactly the stale-with-a-replacement document is removable' (
        $removableNames.Count -eq 1 -and $removableNames[0] -eq 'hookmaker-alpha-1111111111.json') ($removableNames -join ',')
    Check 'relocate: a stale document with NO replacement is reported, not removed' (
        @($orphans.Ambiguous) -contains 'hookmaker-beta-3333333333.json') (@($orphans.Ambiguous) -join ',')
    Check 'relocate: a document whose commands are not ALL old is reported, not removed' (
        @($orphans.Ambiguous) -contains 'hookmaker-gamma-4444444444.json') (@($orphans.Ambiguous) -join ',')
    Check 'relocate: a document naming neither root is not considered at all' (
        $removableNames -notcontains 'hookmaker-delta-6666666666.json' -and
        @($orphans.Ambiguous) -notcontains 'hookmaker-delta-6666666666.json') (@($orphans.Ambiguous) -join ',')
    Check 'relocate: nothing was deleted by the INSPECTION itself' (
        @(Get-ChildItem -LiteralPath $relKiro -Filter '*.json' -File).Count -eq 6) (
        [string]@(Get-ChildItem -LiteralPath $relKiro -Filter '*.json' -File).Count)

    Write-Host ''
    Write-Host '--- relocate: a project with no per-hook-file client is simply empty ---' -ForegroundColor Cyan
    $relBare = Join-Path $relWork 'bare'
    New-Item -ItemType Directory -Path $relBare -Force | Out-Null
    $bareOrphans = Get-OrphanedClientDocument -NewRoot $relBare -OldRoot $relOld
    Check 'relocate: a missing .kiro\hooks directory yields nothing, and does not throw' (
        @($bareOrphans.Removable).Count -eq 0 -and @($bareOrphans.Ambiguous).Count -eq 0)

    Write-Host ''
    Write-Host '--- relocate: sync routes are repointed; ids are deliberately NOT ---' -ForegroundColor Cyan
    # Route ids and the profile id are opaque keys with live state behind them:
    # records reference the profile id, and the engine writes route ids into its
    # own sync state. Renaming either orphans that state to change a label no
    # user output shows, so this asserts they are LEFT ALONE.
    $relCfg = Join-Path $relWork 'sync-hooks.json'
    $cfgDoc = @{
        version  = 1
        profiles = @(@{
                id      = 'sync-group-abcdef1234'
                name    = 'Sync group: Gone Away + Other'
                enabled = $true
                routes  = @(
                    @{ id = 'gone-away-to-other'; enabled = $true
                        source = @{ name = 'Gone Away'; root = $relOld; directory = '.ai'; aliases = @() }
                        destination = @{ name = 'Other'; root = 'G:\Program Files\Other'; directory = '.ai'; aliases = @() }
                    },
                    @{ id = 'other-to-gone-away'; enabled = $true
                        source = @{ name = 'Other'; root = 'G:\Program Files\Other'; directory = '.ai'; aliases = @() }
                        destination = @{ name = 'Gone Away'; root = $relOld; directory = '.ai'; aliases = @() }
                    })
            })
    }
    [System.IO.File]::WriteAllText($relCfg, ($cfgDoc | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
    $relChange = Update-SyncConfigRoot -ConfigPath $relCfg -OldRoot $relOld -NewRoot $relNew
    $after = Get-Content -LiteralPath $relCfg -Raw | ConvertFrom-Json
    $afterRoutes = @($after.profiles[0].routes)
    Check 'relocate: both route ends that named the old root are repointed' ($relChange.Roots -eq 2) ([string]$relChange.Roots)
    Check 'relocate: the source root really changed on disk' (
        [string]$afterRoutes[0].source.root -eq $relNew) ([string]$afterRoutes[0].source.root)
    Check 'relocate: the destination root really changed on disk' (
        [string]$afterRoutes[1].destination.root -eq $relNew) ([string]$afterRoutes[1].destination.root)
    Check 'relocate: the display names follow the new folder leaf' (
        [string]$afterRoutes[0].source.name -eq 'moved' -and [string]$afterRoutes[1].destination.name -eq 'moved') (
        [string]$afterRoutes[0].source.name)
    Check 'relocate: the OTHER project is untouched' (
        [string]$afterRoutes[0].destination.root -eq 'G:\Program Files\Other' -and
        [string]$afterRoutes[0].destination.name -eq 'Other') ([string]$afterRoutes[0].destination.root)
    Check 'relocate: route IDS are left alone (they key live sync state)' (
        [string]$afterRoutes[0].id -eq 'gone-away-to-other' -and
        [string]$afterRoutes[1].id -eq 'other-to-gone-away') ([string]$afterRoutes[0].id)
    Check 'relocate: the profile ID is left alone (records reference it)' (
        [string]$after.profiles[0].id -eq 'sync-group-abcdef1234') ([string]$after.profiles[0].id)
    Check 'relocate: the profile display name follows the rename' (
        [string]$after.profiles[0].name -eq 'Sync group: moved + Other') ([string]$after.profiles[0].name)

    # A config that names nothing of ours must come back byte-identical, or a
    # relocation would rewrite unrelated groups on every run.
    $relUntouched = Join-Path $relWork 'untouched.json'
    [System.IO.File]::WriteAllText($relUntouched, ($cfgDoc | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
    $beforeBytes = [System.IO.File]::ReadAllBytes($relUntouched)
    $noChange = Update-SyncConfigRoot -ConfigPath $relUntouched -OldRoot 'G:\Program Files\Never Existed' -NewRoot $relNew
    Check 'relocate: a config naming no matching root reports zero changes' (
        $noChange.Roots -eq 0 -and $noChange.Names -eq 0 -and $noChange.Profiles -eq 0) (
        [string]$noChange.Roots + '/' + [string]$noChange.Names + '/' + [string]$noChange.Profiles)
    Check 'relocate: and is left byte-for-byte unchanged' (
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$beforeBytes, [byte[]][System.IO.File]::ReadAllBytes($relUntouched)))

    Write-Host ''
    Write-Host '--- relocate: only project roots that are GONE are offered ---' -ForegroundColor Cyan
    # An existing root was not moved; offering it would invite repointing
    # something that is fine. ToolRoot deliberately points at an EMPTY
    # workspace: the registry then contributes nothing, so this asserts the
    # filter itself rather than whatever this machine happens to have installed.
    # (The first version read the live registry through an undefined $ToolRoot -
    # Test-Wizard never defined one - which threw under StrictMode and took the
    # whole rest of the suite with it.)
    #
    # A sync route can also name a root the registry does not: a group outlives
    # its member's hooks, and a rename repaired only in the registry leaves the
    # route behind. Two real groups were still pointing at a folder renamed two
    # renames ago while the registry was clean, so a registry-only candidate
    # list could never offer it.
    $relGoneRoot = Join-Path $relWork 'RenamedAwayProject'
    $relCfgOnly = Join-Path $relWork 'config-only.json'
    $cfgOnlyDoc = @{
        version  = 1
        profiles = @(@{
                id      = 'sync-group-cfgonly99'
                name    = 'Sync group: RenamedAwayProject + moved'
                enabled = $true
                routes  = @(@{ id = 'a-to-b'; enabled = $true
                        source      = @{ name = 'RenamedAwayProject'; root = $relGoneRoot; directory = '.ai'; aliases = @() }
                        destination = @{ name = 'moved'; root = $relNew; directory = '.ai'; aliases = @() }
                    })
            })
    }
    [System.IO.File]::WriteAllText($relCfgOnly, ($cfgOnlyDoc | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
    $cfgOnlyCandidates = @(Get-RelocationCandidate -ToolRoot $relWork -ConfigPath $relCfgOnly)
    $cfgOnlyRoots = @($cfgOnlyCandidates | ForEach-Object { [string]$_.Root })
    Check 'relocate: a root only the sync config names is still offered' (
        $cfgOnlyRoots -contains $relGoneRoot) ($cfgOnlyRoots -join ' ; ')
    Check 'relocate: a root that still exists is never a candidate' (
        $cfgOnlyRoots -notcontains $relNew) ($cfgOnlyRoots -join ' ; ')
    Check 'relocate: a config-only candidate carries no records to reinstall' (
        @(@($cfgOnlyCandidates | Where-Object { $_.Root -eq $relGoneRoot })[0].Records).Count -eq 0)
    Check 'relocate: no config path at all contributes nothing' (
        @(Get-SyncConfigRoot -ConfigPath '').Count -eq 0)
    Check 'relocate: a missing config contributes nothing' (
        @(Get-SyncConfigRoot -ConfigPath (Join-Path $relWork 'no-such-config.json')).Count -eq 0)
    $relBadJson = Join-Path $relWork 'broken.json'
    [System.IO.File]::WriteAllText($relBadJson, '{ not json', (New-Object System.Text.UTF8Encoding $false))
    Check 'relocate: an unparsable config is silent, never fatal' (
        @(Get-SyncConfigRoot -ConfigPath $relBadJson).Count -eq 0)
}
finally {
    if (-not (Remove-TestWorkspace $relWork)) { $script:Fail++ }
}
