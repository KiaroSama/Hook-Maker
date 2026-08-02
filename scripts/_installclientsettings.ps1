# ---------------------------------------------------------------------------
# Client settings mutation: the read-modify-write of ONE client settings file
# (.claude\settings*.json / .codex\hooks.json) - pruning this install's stale
# handlers, adding its handler group, and replacing the file transactionally
# with a backup beside it.
#
# Split out of Install-Hook.ps1 (which had grown past the file-size review
# signal) because deciding what a settings file should contain is a distinct
# responsibility from staging the runtime it points at (_installruntime.ps1).
#
# Dot-sourced by Install-Hook.ps1 only. These functions rely on that script's
# parameters and ambient script-scope state ($Profile, $FriendlyName,
# $SourceName, $Timestamp, $Utf8NoBom, $script:KnownToolRoots) and on
# _installplan.ps1 (Test-HandlerBelongsToInstall) - dot-sourcing splices these
# functions into the callers scope, and calls resolve at invocation time, so
# this is a normal one-directional dependency, not a layering violation.
# ---------------------------------------------------------------------------

# Removes existing handlers for the SAME hook so a re-install replaces the old
# registration instead of duplicating it. Matches the command by either the new
# friendly script leaf or the legacy internal-name leaf (so entries from older
# versions - including the flat tool-folder layout - are migrated), and, for the
# engine, the same -Profile.
function Remove-StaleHandlers {
    param(
        [Parameter(Mandatory = $true)]$HooksObject,
        [Parameter(Mandatory = $true)][string]$EventName
    )

    if ($null -eq $HooksObject.PSObject.Properties[$EventName]) {
        return
    }
    # Ownership is proven by the managed runtime PATH SHAPE
    # (...\hooks\Hook-Maker\<Name>\<file>.ps1, or the legacy HookMaker layout),
    # checked across command / commandWindows / command_windows - never by a
    # bare script basename. A user's own unrelated handler that happens to
    # point at a script with the same filename is NOT ours and is preserved.
    $keptGroups = @()
    foreach ($group in @($HooksObject.$EventName)) {
        # A group with no `hooks` key at all (foreign/hand-edited entry) is not
        # a recognized handler-group shape - unlike a legitimate "hooks": []
        # group, there is nothing here to prove ownership over, so it passes
        # through untouched instead of being pruned as empty.
        if ($null -eq $group.PSObject.Properties['hooks']) {
            $keptGroups += $group
            continue
        }
        $keptHandlers = @()
        foreach ($handler in @($group.hooks)) {
            # KnownToolRoots is what makes the historical tool-folder layout
            # provable rather than a shape guess: only a command rooted under a
            # KNOWN Hook Maker tool root can be claimed. Anything else that
            # merely looks similar is left untouched.
            $sameHook = Test-HandlerBelongsToInstall -Handler $handler -FriendlyName $FriendlyName `
                -ProfileId ([string]$Profile) -AlsoMatchHookNames @($SourceName) `
                -KnownToolRoots $script:KnownToolRoots
            if (-not $sameHook) {
                $keptHandlers += $handler
            }
        }
        if ($keptHandlers.Count -gt 0) {
            $group.hooks = $keptHandlers
            $keptGroups += $group
        }
    }
    $HooksObject.$EventName = $keptGroups
}

function Read-OrCreateJsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{}
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }
    return ($raw | ConvertFrom-Json)
}

function Ensure-Property {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $DefaultValue
    }
    return $Object.$Name
}

# A settings file is backed up once per install RUN, not once per hook.
#
# Installing 20 hooks is 20 separate Install-Hook.ps1 invocations, each with its
# own timestamp, so one settings.local.json collected 20 near-identical copies
# of itself - and the only genuinely useful one, the state BEFORE the batch, was
# buried among 19 mid-batch snapshots. When the caller marks a run
# (HOOKMAKER_BACKUP_RUN, which the wizard sets at startup), the first install of
# that run writes the backup and every later one finds it already there and
# leaves it alone, so what survives is exactly the pre-batch file. A direct
# single install with no run marker keeps the old per-invocation name.
function Get-BackupRunStamp {
    param([Parameter(Mandatory = $true)][string]$Operation, [Parameter(Mandatory = $true)][string]$Fallback)
    $run = [string]$env:HOOKMAKER_BACKUP_RUN
    if ([string]::IsNullOrWhiteSpace($run)) { return $Fallback }
    # The value lands in a FILE NAME, so it is sanitized rather than trusted.
    $safe = ($run -replace '[^A-Za-z0-9._-]', '')
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
    if ($safe -eq '') { return $Fallback }
    return ($Operation + '-' + $safe)
}

function Backup-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $backupPath = $Path + '.backup-' + (Get-BackupRunStamp -Operation 'install' -Fallback $Timestamp)
    # Never -Force over an existing run backup: that would replace the pre-batch
    # state with a mid-batch one, which is the copy nobody needs.
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }
    # ONE backup per file at a time. The per-run rule above stops copies piling
    # up within a run; this stops them piling up ACROSS runs. Runs unconditionally
    # (not only when a copy was just made) so a second install in the same run
    # still clears anything an earlier run left behind.
    Remove-SupersededBackups -Path $Path -KeepPath $backupPath
}

# Settings are replaced transactionally: serialize to a sibling temp file,
# re-parse that temp file to prove it is valid JSON, and only then atomically
# replace the real file. A failure at any step leaves the original settings
# exactly as they were - never truncated or half-written.
function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 50
    $temporaryPath = $Path + '.hookmaker-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $Utf8NoBom)
        # Re-parse from disk: proves what we are about to publish is loadable.
        $verify = [System.IO.File]::ReadAllText($temporaryPath, [System.Text.Encoding]::UTF8)
        $null = $verify | ConvertFrom-Json
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # [NullString]::Value, not $null: PowerShell coerces a bare $null
            # to '' for a [string] parameter, and Replace rejects an empty
            # backup path.
            [System.IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-HookGroup {
    param(
        [Parameter(Mandatory = $true)]$HooksObject,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)]$Group,
        [Parameter(Mandatory = $true)][string]$ExactCommand
    )

    $groups = @()
    if ($null -ne $HooksObject.PSObject.Properties[$EventName]) {
        $groups = @($HooksObject.$EventName)
    }

    foreach ($existingGroup in $groups) {
        # A group missing `hooks` entirely (foreign/hand-edited) has none to
        # compare against - never a StrictMode crash, just zero candidates.
        $existingHandlers = @(if ($null -ne $existingGroup.PSObject.Properties['hooks']) { $existingGroup.hooks } else { @() })
        foreach ($handler in $existingHandlers) {
            foreach ($propertyName in @('command', 'commandWindows', 'command_windows')) {
                if ($null -ne $handler.PSObject.Properties[$propertyName] -and [string]$handler.$propertyName -eq $ExactCommand) {
                    return
                }
            }
        }
    }

    if ($null -eq $HooksObject.PSObject.Properties[$EventName]) {
        $HooksObject | Add-Member -MemberType NoteProperty -Name $EventName -Value @($Group)
    }
    else {
        $HooksObject.$EventName = @($HooksObject.$EventName) + @($Group)
    }
}
