# Offline test suite for the hook-list management rows.
#
# Part 1 - menu 27 (Uninstall Installed Hooks): proves the list and
# confirmation screens in Setup-SyncGroupInstalledHooks.ps1 render the FULL
# install identity that Get-InstalledHookSnapshot already collects - hook type,
# exact target path, per-client event names and the exact persisted
# sourceScript in the list; record id, settings path, runtime script and
# native-Git ownership status in the confirmation screen - and that declining
# the final confirmation mutates nothing (the record survives in the registry).
#
# Part 2 - the fixed menu numbering itself: shipped hooks occupy exactly 3..24
# (the three test-health hooks at 20/21/22, Utf8-Encoding-Check at 23, and
# Cloudflare-Deploy last at 24), 25 is Update, 26 is Get hook status, 27 is
# Uninstall, custom hooks start at 28, adding a custom hook shifts NONE of the
# three management rows, each management action must be selected alone, and
# item 1 ("Select all") expands to the sync group plus every hook while
# excluding all three management indices.
#
# Part 3 - the menu 26 prompt flow (Setup-SyncGroupHookStatus.ps1): which root
# folder inputs are accepted (quoted paths with spaces, a project root, a
# .claude\hooks\Hook-Maker direct subtree), that an invalid path re-prompts
# instead of scanning, that the global question defaults to No on a bare Enter,
# that 0 at the global question returns to the root prompt, and that cancelling
# writes nothing to the install registry.
#
# Drives the real interactive wizard via Start-Process with a scripted stdin
# answer file (same pattern as Test-LegacyDiscovery.ps1's Invoke-Wizard):
# main menu 1 (Create or install a hook) -> submenu 1 (Install an existing
# hook) -> the hook list -> the flow under test.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstalledHooksMenu.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$Setup = Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($Setup, $InstallScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Same chain as Test-UninstallHook.ps1: _hooklib.ps1 first (Get-ShortHash,
# Read-JsonFile, ...), then _installplan.ps1, then _installlib.ps1 (which
# dot-sources _installregistry.ps1 itself, so Read-InstallRegistry /
# Get-ClientSubrecord / Get-InstalledClientNames all become available).
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')
# _installlib.ps1 itself dot-sources _clientcapability.ps1 and _installvalidate.ps1,
# so Get-HookMakerClientIds / Get-HookMakerClientCapability / Get-CanonicalClientSettingsPath
# are already reachable here (and, being script scope, inside the & {} render
# harnesses below). Setup-SyncGroupInstalledHooks.ps1 is loaded for the REAL
# Get-ClientDisplayName: the result screen used to be asserted against a local
# stub of it, which cannot prove the shipped function names a client correctly.
. (Join-Path $ScriptRoot 'Setup-SyncGroupInstalledHooks.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-menu22-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

function New-FixtureHook {
    param([string]$Name, [string]$Body = "exit 0`n")
    $dir = Join-Path $RealHooksDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Utf8 (Join-Path $dir ($Name + '.ps1')) $Body
    return (Join-Path $dir ($Name + '.ps1'))
}
function Remove-FixtureHook {
    param([string]$Name)
    $dir = Join-Path $RealHooksDir $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- immunity to OTHER suites' throwaway fixtures --------------------------
# ZZZ- is this project's reserved prefix for throwaway hook fixtures, and
# several suites create them directly inside the REAL hooks\ directory. Such a
# directory is a CUSTOM hook to the wizard (it is not in $script:HookMeta), so
# it takes an index in the custom block and pushes every later row down one - a
# leftover from an aborted run silently corrupted this suite's counts and row
# assertions. Every count and index taken off the real hooks\ directory below
# therefore goes through Remove-ForeignFixtureRows first.
#
# This suite's OWN fixtures are kept: they are what the custom-block assertions
# are about. Everything else starting with ZZZ- belongs to another suite.
$script:OwnFixtureHooks = @('ZZZ-Menusuite-Fixture')
function Test-ForeignFixtureRow {
    param([string]$Label)
    # -match is case-insensitive, which is the intent: zzz-, Zzz- and ZZZ- are
    # all the same reserved fixture prefix.
    if ($Label -notmatch '^ZZZ-') { return $false }
    foreach ($own in $script:OwnFixtureHooks) {
        if ($Label -match ('^' + [regex]::Escape($own) + '\b')) { return $false }
    }
    return $true
}
# Drops foreign fixture rows and shifts the rows after each one down by exactly
# the number dropped before it, so the surviving rows keep the numbers they
# would have had on a clean hooks\ directory. It shifts rather than renumbering
# 1..N on purpose: renumbering would manufacture contiguity and quietly defeat
# the "rows 3..24 all exist" assertion if a real row ever went missing.
function Remove-ForeignFixtureRows {
    param($Rows)
    if ($null -eq $Rows) { return $null }
    $dropped = @(@($Rows.Keys) | Where-Object { Test-ForeignFixtureRow ([string]$Rows[$_]) })
    $out = @{}
    foreach ($key in @($Rows.Keys)) {
        if ($dropped -contains $key) { continue }
        $shift = @($dropped | Where-Object { $_ -lt $key }).Count
        $out[$key - $shift] = [string]$Rows[$key]
    }
    return , $out
}
# One comparable string for a whole row map, so "nothing moved" is provable
# row-for-row instead of by spot-checking a few indices.
#
# Row 1 is excluded: it is the "Select all" aggregate, and its hint quotes the
# LIVE hook spans ("...install every hook below (3-24 and 28-28)"), so it
# legitimately changes when a hook exists that this suite filters out - that is
# the wizard counting correctly, not a row moving. Nothing here pins that hint's
# text; the assertion on row 1 matches its "Select all hooks" prefix only.
function Get-RowSignature {
    param($Rows)
    if ($null -eq $Rows) { return '<no rows>' }
    return ((@($Rows.Keys) | Sort-Object | Where-Object { $_ -ne 1 } | ForEach-Object { [string]$_ + '. ' + [string]$Rows[$_] }) -join "`n")
}

function New-Config {
    param([string]$Path)
    '{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[]}' | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-Registry { return Read-InstallRegistry -ToolRoot $ToolRoot }
function Get-RecordForScope {
    param([string]$FriendlyName, [string]$TargetProjectRoot)
    return @((Get-Registry).installs | Where-Object { [string]$_.friendlyName -eq $FriendlyName -and [string]$_.targetProjectRoot -eq $TargetProjectRoot })[0]
}

# Same spawned-process pattern as Test-LegacyDiscovery.ps1's Invoke-Wizard:
# writes the scripted answers to a stdin file, spawns the wizard as a real
# process (isolated by -WorkingDirectory and the HOOKMAKER_STATE_DIR
# environment override), and strips ANSI color codes from the captured output
# so assertions can match plain text.
function Invoke-Wizard {
    param([string[]]$Answers, [string]$Config, [string]$WorkingDirectory)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "in-$token.txt"; $outF = Join-Path $Work "out-$token.txt"; $errF = Join-Path $Work "err-$token.txt"
    [System.IO.File]::WriteAllText($inF, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    $argLine = '-NoLogo -NoProfile -File "' + $Setup + '" -ConfigPath "' + $Config + '"'
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine; RedirectStandardInput = $inF
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        WorkingDirectory = $WorkingDirectory
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\x1b\[[0-9;]*m", ''); Err = $err }
}

# Pulls the numbered rows out of the LAST rendered "Available hooks (hooks\):"
# block and returns them as an ordered index -> label map. Anchoring on the last
# block matters: an answer sequence that re-displays the menu after an error
# leaves several copies in the captured output.
function Get-HookListRows {
    param([string]$Output)
    $header = 'Available hooks (hooks\):'
    $start = $Output.LastIndexOf($header)
    if ($start -lt 0) { return $null }
    $end = $Output.IndexOf('  Tip: use lists and ranges', $start)
    if ($end -lt 0) { $end = $Output.Length }
    # A plain hashtable, NOT [ordered]: an OrderedDictionary indexed with an
    # [int] treats it as a POSITIONAL index rather than a key, so $rows[21]
    # would silently mean "the 22nd row" instead of "the row numbered 21".
    $rows = @{}
    foreach ($line in ($Output.Substring($start, $end - $start) -split "`r?`n")) {
        $m = [regex]::Match($line, '^  (\d+)\. (.+?)\s*$')
        if ($m.Success) { $rows[[int]$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    return , $rows
}

try {
    Write-Host '--- menu 26 lists the full install identity and the confirmation screen repeats it ---' -ForegroundColor Cyan

    # ZZZ-Regtest-* throwaway fixture, no internal lower->upper case transition
    # (Get-HookFriendlyName hyphenates PascalCase boundaries; this name already
    # uses hyphens so its rendered label matches the name verbatim).
    $fxName = 'ZZZ-Menusuite-Fixture'
    $fxScript = New-FixtureHook $fxName
    try {
        $proj = New-Proj 'Menu22Proj'
        $cfg = Join-Path $Work 'cfg.json'; New-Config $cfg

        # Claude + Codex, multi-event (2 events), project-scoped.
        & $InstallScript -CustomHook $fxScript -Events @('SessionStart', 'Stop') -TargetProject $proj *> $null
        $rec = Get-RecordForScope $fxName $proj
        Check 'setup: the fixture installed a project-scoped record' ($null -ne $rec)
        Check 'setup: the record has both clients' ((@(Get-InstalledClientNames -Record $rec) | Sort-Object) -join ',' -eq 'claude,codex')

        $claudeSettings = [string]$rec.clients.claude.settingsPath
        $claudeRuntimeScript = [string]$rec.clients.claude.runtimeScript
        $codexSettings = [string]$rec.clients.codex.settingsPath
        $codexRuntimeScript = [string]$rec.clients.codex.runtimeScript

        # main menu 1 -> submenu 1 -> hook list 26 (Uninstall) -> select row 1
        # (the fixture record) -> decline the confirmation -> exit the main menu.
        $r = Invoke-Wizard -Config $cfg -Answers @('1', '1', '27', '1', 'n', '0') -WorkingDirectory $proj
        Check 'the wizard run exits 0' ($r.Exit -eq 0) $r.Err

        # ---- list screen: everything Get-InstalledHookSnapshot collects ----
        Check 'list: the friendly hook name appears' ($r.Out -match [regex]::Escape('ZZZ-Menusuite-Fixture')) $r.Out
        Check 'list: the hook type (CustomHook) appears' ($r.Out -match 'CustomHook') $r.Out
        Check 'list: the exact target project root appears' ($r.Out -match [regex]::Escape($proj)) $r.Out
        Check 'list: Claude''s events appear' ($r.Out -match 'Claude \[SessionStart, Stop\]') $r.Out
        Check 'list: Codex''s events appear' ($r.Out -match 'Codex \[SessionStart, Stop\]') $r.Out
        Check 'list: the exact persisted sourceScript appears' ($r.Out -match [regex]::Escape($fxScript)) $r.Out

        # ---- confirmation screen: record id, settings path, runtime script, native-git status ----
        Check 'confirm: the record id appears' ($r.Out -match [regex]::Escape($rec.id)) $r.Out
        Check 'confirm: the Claude settings path appears' ($r.Out -match [regex]::Escape($claudeSettings)) $r.Out
        Check 'confirm: the Codex settings path appears' ($r.Out -match [regex]::Escape($codexSettings)) $r.Out
        Check 'confirm: the Claude runtime script path appears' ($r.Out -match [regex]::Escape($claudeRuntimeScript)) $r.Out
        Check 'confirm: the Codex runtime script path appears' ($r.Out -match [regex]::Escape($codexRuntimeScript)) $r.Out
        Check 'confirm: native-Git ownership status appears (this install does not own it)' ($r.Out -match 'native Git:\s*no') $r.Out

        # ---- decline was honored: no mutation at all ----
        Check 'decline: the wizard reported "Canceled"' ($r.Out -match 'Canceled\. Nothing was changed\.') $r.Out
        $recAfter = Get-RecordForScope $fxName $proj
        Check 'decline: the record still exists in the registry' ($null -ne $recAfter -and [string]$recAfter.id -eq [string]$rec.id)
        Check 'decline: the Claude settings file is untouched' (Test-Path -LiteralPath $claudeSettings)
        Check 'decline: the Claude runtime script is untouched' (Test-Path -LiteralPath $claudeRuntimeScript)

        Write-Host ''
        Write-Host '--- sample rendered list block for this install ---' -ForegroundColor DarkGray
        # The fixture also appears earlier as a plain installable custom hook in
        # "Available hooks:" - the row we want is the one inside "Installed
        # hooks:", so anchor the search there rather than on the first match.
        $installedHeaderAt = $r.Out.IndexOf('Installed hooks:')
        $sampleStart = if ($installedHeaderAt -ge 0) { $r.Out.IndexOf('ZZZ-Menusuite-Fixture', $installedHeaderAt) } else { -1 }
        if ($sampleStart -ge 0) {
            $sampleEnd = $r.Out.IndexOf("`n`n", $sampleStart)
            if ($sampleEnd -lt 0) { $sampleEnd = [Math]::Min($r.Out.Length, $sampleStart + 600) }
            Write-Host $r.Out.Substring($sampleStart, $sampleEnd - $sampleStart)
        }

        # ================================================================
        # Part 2 - the fixed menu numbering
        # ================================================================
        Write-Host ''
        # Banner deliberately states the LAYOUT, not a rendering: the concrete
        # numbers depend on how many shipped hooks exist and this line had gone
        # stale against the assertions below it, which compute from the real
        # count. The assertions are the specification.
        Write-Host '--- hook list layout: shipped block, then the 3 management rows, then custom ---' -ForegroundColor Cyan

        # Render the hook list and leave without selecting anything.
        $menu = Invoke-Wizard -Config $cfg -Answers @('1', '1', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'menu: the render-only run exits 0' ($menu.Exit -eq 0) $menu.Err
        # Foreign ZZZ-* fixtures are removed before ANY count or index below is
        # taken - see Remove-ForeignFixtureRows. $foreignRowCount is what the
        # WIZARD still sees (it installs those hooks too), needed wherever an
        # assertion compares against a number the wizard itself rendered.
        $rawRows = Get-HookListRows $menu.Out
        $rows = Remove-ForeignFixtureRows $rawRows
        Check 'menu: the hook list block was rendered' ($null -ne $rows) $menu.Out
        $foreignRowCount = 0
        if ($null -ne $rawRows) { $foreignRowCount = @($rawRows.Keys).Count - @($rows.Keys).Count }

        if ($null -ne $rows) {
            $indices = @($rows.Keys)
            Check 'menu: item 1 is "Select all hooks"' ([string]$rows[1] -match '^Select all hooks') ([string]$rows[1])
            Check 'menu: item 2 is the sync group' ([string]$rows[2] -match '^Create or update a sync group') ([string]$rows[2])

            # The 22 shipped hooks occupy exactly 3..24 - no gap, and no
            # management row anywhere inside that range.
            $shippedRange = @(3..24)
            $missing = @($shippedRange | Where-Object { -not $rows.Contains($_) })
            Check 'menu: rows 3..24 all exist (the 22 shipped hooks)' ($missing.Count -eq 0) ('missing: ' + ($missing -join ','))
            $strayManagement = @($shippedRange | Where-Object { $rows.Contains($_) -and [string]$rows[$_] -match '\[manage\]' })
            Check 'menu: no management row appears inside the shipped range 3..24' ($strayManagement.Count -eq 0) ('stray: ' + ($strayManagement -join ','))

            # The three test-health hooks (24.txt) sit at 20/21/22 IN THAT
            # ORDER, then Utf8-Encoding-Check at 23 (30.md), then
            # Cloudflare-Deploy, which stays the last individual entry.
            Check 'menu: 20 is Test-Plan-Check' ([string]$rows[20] -match '^Test-Plan-Check \| \[pre-task\] \|') ([string]$rows[20])
            Check 'menu: 21 is Test-Run-Guard' ([string]$rows[21] -match '^Test-Run-Guard \| \[pre\+post-task\] \|') ([string]$rows[21])
            Check 'menu: 22 is Test-Completion-Check' ([string]$rows[22] -match '^Test-Completion-Check \| \[post-task\] \|') ([string]$rows[22])
            Check 'menu: 23 is Utf8-Encoding-Check' ([string]$rows[23] -match '^Utf8-Encoding-Check \| \[pre\+post-task\] \|') ([string]$rows[23])
            Check 'menu: 24 is Cloudflare-Deploy (still the last individual entry)' ([string]$rows[24] -match '^Cloudflare-Deploy \| \[post-task\] \|') ([string]$rows[24])

            Check 'menu: 25 is Update installed hooks' ([string]$rows[25] -match '^Update installed hooks \| \[manage\] \|') ([string]$rows[25])
            # The exact contract wording for the two rows the task pins. Row 26
            # gained '; skips dependency caches' when the scan started pruning
            # node_modules/.next/... - the row states what the scan DOES, and a
            # scan that no longer walks those trees must say so rather than let
            # the reader assume full coverage.
            Check 'menu: 26 renders EXACTLY the contract row' ([string]$rows[26] -eq 'Get hook status | [manage] | scan a path for installed hooks (skips dependency caches) and track results') ([string]$rows[26])
            Check 'menu: 27 renders EXACTLY the contract row' ([string]$rows[27] -eq 'Uninstall installed hooks | [manage] | list and remove installed hooks; never deletes hook sources') ([string]$rows[27])

            # The fixture is the only custom hook, so the custom block starts at
            # 28 - i.e. adding a custom hook did NOT shift 20-27 at all.
            Check 'menu: custom hooks start at 28' ([string]$rows[28] -match 'ZZZ-Menusuite-Fixture') ([string]$rows[28])
            Check 'menu: adding a custom hook did not shift the management rows' (([string]$rows[25] -match 'Update') -and ([string]$rows[26] -match 'Get hook status') -and ([string]$rows[27] -match 'Uninstall')) (($indices | Sort-Object) -join ',')
            Check 'menu: adding a custom hook did not shift the three new shipped rows' (([string]$rows[20] -match 'Test-Plan-Check') -and ([string]$rows[21] -match 'Test-Run-Guard') -and ([string]$rows[22] -match 'Test-Completion-Check')) (($indices | Sort-Object) -join ',')
            Check 'menu: the Tip line names all three management indices' ($menu.Out -match '25/26/27 are management actions') $menu.Out

            # Each newly inserted row (the three test-health hooks and
            # Utf8-Encoding-Check) must render on ONE line, within the budget
            # the existing shipped rows already respect (the longest
            # pre-existing row is the yardstick - no new row may be the one that
            # starts wrapping).
            $newRowNumbers = @(20, 21, 22, 23)
            $existingRowLengths = @(@($rows.Keys) |
                Where-Object { $_ -ge 3 -and $_ -le 24 -and $newRowNumbers -notcontains $_ } |
                ForEach-Object { ('  ' + $_ + '. ' + [string]$rows[$_]).Length })
            $rowBudget = (@($existingRowLengths | Sort-Object -Descending)[0])
            foreach ($n in $newRowNumbers) {
                $rendered = '  ' + $n + '. ' + [string]$rows[$n]
                Check ('menu: row ' + $n + ' renders on exactly one line within the existing budget (' + $rowBudget + ')') (
                    $rendered -notmatch "[`r`n]" -and $rendered.Length -le $rowBudget) ($rendered.Length.ToString() + ': ' + $rendered)
            }
        }

        Write-Host ''
        Write-Host '--- a foreign ZZZ-* fixture in the real hooks\ dir moves nothing this suite reads ---' -ForegroundColor Cyan

        # The failure this pins happened for real: a leftover hooks\ZZZ-* from
        # another suite's aborted run is a custom hook to the wizard, so it took
        # an index inside the custom block and pushed this suite's own fixture
        # down one, breaking the counts above. Create one deliberately, render
        # the SAME menu again, and require the filtered view to be identical
        # row for row.
        $probeName = 'ZZZ-Menu-Immunity-Probe'  # sorts BEFORE ZZZ-Menusuite-Fixture, so it really does shift it
        $beforeSignature = Get-RowSignature $rows
        [void](New-FixtureHook $probeName)
        try {
            $probe = Invoke-Wizard -Config $cfg -Answers @('1', '1', '0', '0', 'exit') -WorkingDirectory $proj
            Check 'immunity: the probe render run exits 0' ($probe.Exit -eq 0) $probe.Err
            $probeRaw = Get-HookListRows $probe.Out
            # The probe must actually be IN the rendered menu, otherwise the
            # equality below would prove nothing at all.
            Check 'immunity: the foreign fixture really did render as one extra row' (
                $null -ne $probeRaw -and $null -ne $rawRows -and
                @($probeRaw.Keys).Count -eq (@($rawRows.Keys).Count + 1) -and
                @(@($probeRaw.Values) | Where-Object { $_ -match [regex]::Escape($probeName) }).Count -eq 1) (Get-RowSignature $probeRaw)
            $probeRows = Remove-ForeignFixtureRows $probeRaw
            Check 'immunity: every row this suite reads is unchanged' (
                (Get-RowSignature $probeRows) -eq $beforeSignature) ((Get-RowSignature $probeRows) + "`n--- expected ---`n" + $beforeSignature)
            Check 'immunity: the hook total is unchanged' (
                (@($probeRows.Keys).Count - 5) -eq 23) ('total hooks: ' + (@($probeRows.Keys).Count - 5))
            Check 'immunity: the custom block still starts at 28 with this suite''s own fixture' (
                [string]$probeRows[28] -match 'ZZZ-Menusuite-Fixture') ([string]$probeRows[28])
            Check 'immunity: the foreign fixture is absent from the filtered view' (
                @(@($probeRows.Values) | Where-Object { $_ -match [regex]::Escape($probeName) }).Count -eq 0) (Get-RowSignature $probeRows)
        }
        finally {
            # A leaked hooks\ZZZ-* corrupts the NEXT run of this suite and of
            # Test-Wizard, so the removal is mandatory, not best-effort.
            Remove-FixtureHook $probeName
        }
        Check 'immunity: the foreign fixture was removed from the real hooks directory' (
            -not (Test-Path -LiteralPath (Join-Path $RealHooksDir $probeName))) $probeName

        Write-Host ''
        Write-Host '--- each management action must be selected alone ---' -ForegroundColor Cyan

        # Four illegal mixtures, one after another; each must be rejected and
        # re-render the menu rather than performing half of what was typed.
        $reject = Invoke-Wizard -Config $cfg -Answers @('1', '1', '3,26', '25-27', '1,27', '26,28', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'mix: the rejection run exits 0' ($reject.Exit -eq 0) $reject.Err
        $rejectionCount = ([regex]::Matches($reject.Out, [regex]::Escape('on its own - it cannot be combined'))).Count
        Check 'mix: all four illegal selections were rejected (3,26 / 25-27 / 1,27 / 26,28)' ($rejectionCount -eq 4) ('rejections seen: ' + $rejectionCount)
        Check 'mix: the rejection names all three management indices' ($reject.Out -match 'Select 25 \(update\), 26 \(status\) or 27 \(uninstall\)') $reject.Out
        # None of the three management screens may have been entered. The
        # comparison is CASE-SENSITIVE on purpose: the phase headers ("Get Hook
        # Status") differ from the menu rows ("Get hook status") only by case,
        # and PowerShell's -notmatch is case-insensitive, so -cnotmatch is what
        # actually distinguishes "the screen opened" from "the row was listed".
        Check 'mix: no management screen was entered by an illegal mixture' (($reject.Out -cnotmatch 'Get Hook Status') -and ($reject.Out -cnotmatch 'Uninstall Installed Hooks') -and ($reject.Out -cnotmatch 'Update Previously Installed Hooks')) $reject.Out

        Write-Host ''
        Write-Host '--- item 1 expands to the sync group + every hook, never a management action ---' -ForegroundColor Cyan

        # Item 1 rebuilds the selection as: the sync group, then every shipped
        # and custom hook. The wizard announces the remaining count right before
        # it hands off to the sync-group flow, which is exactly the expansion.
        $totalHooks = 0
        if ($null -ne $rows) { $totalHooks = @($rows.Keys).Count - 5 }  # minus items 1, 2 and the 3 management rows
        $all = Invoke-Wizard -Config $cfg -Answers @('1', '1', '1', '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'select-all: the run exits 0' ($all.Exit -eq 0) $all.Err
        Check 'select-all: 22 shipped + 1 custom hook were counted from the menu' ($totalHooks -eq 23) ('total hooks: ' + $totalHooks)
        # The wizard counts what it will actually install, foreign fixtures
        # included, so the number it PRINTS is the unfiltered one.
        Check 'select-all: item 1 expanded to the sync group plus every hook' ($all.Out -match ('Running the sync group first, then installing ' + ($totalHooks + $foreignRowCount) + ' more hook\(s\)')) $all.Out
        Check 'select-all: item 1 never entered a management screen' (($all.Out -cnotmatch 'Get Hook Status') -and ($all.Out -cnotmatch 'Uninstall Installed Hooks') -and ($all.Out -cnotmatch 'Update Previously Installed Hooks')) $all.Out

        # ================================================================
        # Part 3 - the menu 25 (Get hook status) prompt flow
        # ================================================================
        Write-Host ''
        Write-Host '--- menu 25 root-folder prompt: what is accepted, and what re-prompts ---' -ForegroundColor Cyan

        $registryPath = Join-Path $IsolatedStateDir 'install-registry.json'
        $registryBefore = if (Test-Path -LiteralPath $registryPath) { [System.IO.File]::ReadAllBytes($registryPath) } else { $null }
        $registryWriteBefore = if (Test-Path -LiteralPath $registryPath) { (Get-Item -LiteralPath $registryPath).LastWriteTimeUtc } else { $null }

        $globalQuestion = "Also inspect the current user's global Claude, Codex and Kiro hook locations\?"

        # -- a missing path re-prompts instead of scanning -------------------
        $missingPath = Join-Path $Work 'no-such-folder-here'
        $bad = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $missingPath, '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the invalid-path run exits 0' ($bad.Exit -eq 0) $bad.Err
        Check 'status: a missing folder is rejected with the exact path' ($bad.Out -match [regex]::Escape('Folder not found: ' + $missingPath)) $bad.Out
        Check 'status: the root prompt was shown again after the rejection' (([regex]::Matches($bad.Out, 'Root folder to scan')).Count -ge 2) $bad.Out
        Check 'status: an invalid path never reached the global question' ($bad.Out -notmatch $globalQuestion) $bad.Out
        Check 'status: an invalid path never started a scan' ($bad.Out -notmatch 'Roots to scan:') $bad.Out

        # -- a quoted path containing spaces is accepted ---------------------
        $spaceDir = New-Proj 'Status Root With Spaces'
        $quoted = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', ('"' + $spaceDir + '"'), '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the quoted-path run exits 0' ($quoted.Exit -eq 0) $quoted.Err
        Check 'status: a quoted path containing spaces is accepted' ($quoted.Out -match $globalQuestion) $quoted.Out
        # 0 at the global question goes BACK to the root prompt: that is the
        # second render of the root prompt in this run, and nothing was scanned.
        Check 'status: 0 at the global question returns to the root prompt' (([regex]::Matches($quoted.Out, 'Root folder to scan')).Count -eq 2) $quoted.Out
        Check 'status: cancelling never started a scan' ($quoted.Out -notmatch 'Roots to scan:') $quoted.Out

        # -- a plain project root is accepted --------------------------------
        $projRoot = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $proj, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the project-root run exits 0' ($projRoot.Exit -eq 0) $projRoot.Err
        Check 'status: a project root is accepted' ($projRoot.Out -match $globalQuestion) $projRoot.Out

        # -- a .claude\hooks\Hook-Maker direct subtree is accepted ------------
        # The scan must not demand the exact project root: pointing it at a
        # directory well inside the project has to work too.
        $subtree = Join-Path $proj '.claude\hooks\Hook-Maker'
        New-Item -ItemType Directory -Path $subtree -Force | Out-Null
        $sub = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $subtree, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the .claude\hooks\Hook-Maker run exits 0' ($sub.Exit -eq 0) $sub.Err
        Check 'status: a .claude\hooks\Hook-Maker direct subtree is accepted' ($sub.Out -match $globalQuestion) $sub.Out

        # -- cancelling wrote nothing to the registry -------------------------
        # Asserted here, while every run above cancelled before the scan. The
        # default-No scenario below deliberately runs LAST, because it is the
        # only one that proceeds far enough to hand off to the scanner.
        $registryAfter = if (Test-Path -LiteralPath $registryPath) { [System.IO.File]::ReadAllBytes($registryPath) } else { $null }
        $registryWriteAfter = if (Test-Path -LiteralPath $registryPath) { (Get-Item -LiteralPath $registryPath).LastWriteTimeUtc } else { $null }
        $sameBytes = ($null -eq $registryBefore -and $null -eq $registryAfter) -or
                     ($null -ne $registryBefore -and $null -ne $registryAfter -and
                      [Convert]::ToBase64String($registryBefore) -eq [Convert]::ToBase64String($registryAfter))
        Check 'status: cancelling the scan left the install registry byte-identical' $sameBytes
        Check 'status: cancelling the scan did not rewrite the install registry file' ($registryWriteBefore -eq $registryWriteAfter) ([string]$registryWriteBefore + ' -> ' + [string]$registryWriteAfter)

        # -- the global question defaults to No on a bare Enter ---------------
        # Enter answers No, so the roots screen must say the global locations
        # are excluded and must list only the chosen root.
        $defaultNo = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $proj, '', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the default-No run exits 0' ($defaultNo.Exit -eq 0) $defaultNo.Err
        Check 'status: Enter at the global question means No' ($defaultNo.Out -match [regex]::Escape('Global Claude/Codex/Kiro locations are NOT included in this scan.')) $defaultNo.Out
        Check 'status: the canonical root is shown before the scan starts' ($defaultNo.Out -match [regex]::Escape($proj)) $defaultNo.Out
        Check 'status: the roots screen states reparse points are not followed' ($defaultNo.Out -match 'Reparse points .* are not followed') $defaultNo.Out
    }
    finally {
        Remove-FixtureHook $fxName
    }

    # ================================================================
    # Part 4 - the result screen, rendered offline from a synthetic
    # scan-result document
    # ================================================================
    # scripts\Get-HookStatus.ps1 owns the scanning and may not exist yet, so the
    # grouping/totals rendering is exercised directly instead: the wizard's UI
    # primitives are stubbed into a capture buffer, Setup-SyncGroupHookStatus.ps1
    # is dot-sourced on top of them, and Show-HookStatusResult is handed a
    # contract-shaped document covering every group at once.
    Write-Host ''
    Write-Host '--- menu 25 result screen groups findings and reports partial coverage ---' -ForegroundColor Cyan

    $render = & {
        $script:Captured = New-Object System.Collections.Generic.List[string]
        function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Args) [void]$script:Captured.Add((@($Args) -join ' ')) }
        function Get-Painted { param([AllowEmptyString()][string]$Text, [string]$Color) return $Text }
        function Write-PhaseHeader { param([string]$Text, [string]$Color, [string]$Char = '=') [void]$script:Captured.Add($Text) }
        function Write-MenuTitle { param([string]$Text) [void]$script:Captured.Add($Text) }
        function Write-Field { param([string]$Name, [AllowEmptyString()][string]$Value, [string]$ValueColor = '') [void]$script:Captured.Add(($Name.Trim() + ': ' + $Value)) }
        function Write-NoteLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-ErrorLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-Log { param([string]$Level, [string]$Component, [string]$Message) }
        # NO Get-ClientDisplayName stub: the real one (dot-sourced at script
        # scope above) is what has to name a client correctly on this screen.
        $C = @{ Reset = ''; Bold = ''; Red = ''; Green = ''; White = ''; Gray = ''; Dim = ''; LightBlue = ''; HintYellow = ''; NoteYellow = ''; Aqua = ''; Amber = ''; Mint = ''; Orchid = ''; Teal = ''; Summary = ''; Process = ''; Input = '' }
        $script:MenuSep = ' | '
        . (Join-Path $ScriptRoot 'Setup-SyncGroupHookStatus.ps1')

        $document = [pscustomobject]@{
            overall  = 'partial'
            coverage = [pscustomobject]@{ complete = $false; inaccessible = @('C:\Locked'); skippedReparse = @('C:\Junction') }
            counts   = [pscustomobject]@{ directories = 412; settingsFiles = 7; gitRepositories = 3; logicalHooks = 4; ambiguous = 1 }
            findings = @(
                [pscustomobject]@{
                    friendlyName = 'Secrets-Check'; hookType = 'ClaudeRegistration'; scope = 'project'
                    targetProjectRoot = 'C:\Proj\A'; status = 'active'; statusReason = ''; managedBy = 'hookMaker'
                    removalPolicy = 'full'; needsManualRepair = $false; nativeGit = $null; runtimeArtifacts = @()
                    clients = @([pscustomobject]@{ client = 'claude'; settingsPath = 'C:\Proj\A\.claude\settings.local.json'; events = @('PreToolUse'); parsedTargets = @('C:\Proj\A\.claude\hooks\Hook-Maker\Secrets-Check.ps1'); registrationStatus = 'parsed' })
                }
                [pscustomobject]@{
                    friendlyName = 'team-formatter'; hookType = 'ClaudeRegistration'; scope = 'project'
                    targetProjectRoot = 'C:\Proj\A'; status = 'active'; statusReason = ''; managedBy = 'external'
                    removalPolicy = 'registrationOnly'; needsManualRepair = $false; nativeGit = $null; runtimeArtifacts = @()
                    clients = @([pscustomobject]@{ client = 'claude'; settingsPath = 'C:\Proj\A\.claude\settings.json'; events = @('PostToolUse'); parsedTargets = @('C:\Proj\A\tools\format.js'); registrationStatus = 'parsed' })
                }
                [pscustomobject]@{
                    friendlyName = 'vendor-lint'; hookType = 'CodexRegistration'; scope = 'project'
                    targetProjectRoot = 'C:\Proj\B'; status = 'registrationOnly'; statusReason = 'target file not found'; managedBy = 'external'
                    removalPolicy = 'registrationOnly'; needsManualRepair = $false; nativeGit = $null
                    runtimeArtifacts = @([pscustomobject]@{ path = 'C:\Proj\B\.codex\old-runtime.ps1'; kind = 'script'; classification = 'orphanRuntimeCandidate'; deleteEligibility = 'preserve'; deleteReason = 'not proven unreferenced' })
                    clients = @([pscustomobject]@{ client = 'codex'; settingsPath = 'C:\Proj\B\.codex\hooks.json'; events = @('Stop'); parsedTargets = @(); registrationStatus = 'targetMissing' })
                }
                # Kiro is a perHookFile client: its registration is one JSON
                # document under .kiro\hooks, not an entry in a shared settings
                # file. It must be grouped and labelled as Kiro - it used to be
                # filed under the External Claude heading and rendered as a bare
                # lowercase 'kiro'.
                [pscustomobject]@{
                    friendlyName = 'kiro-lint'; hookType = 'KiroRegistration'; scope = 'project'
                    targetProjectRoot = 'C:\Proj\D'; status = 'active'; statusReason = ''; managedBy = 'external'
                    removalPolicy = 'registrationOnly'; needsManualRepair = $false; nativeGit = $null; runtimeArtifacts = @()
                    clients = @([pscustomobject]@{ client = 'kiro'; settingsPath = 'C:\Proj\D\.kiro\hooks\kiro-lint.kiro.hook'; events = @('PreToolUse'); parsedTargets = @('C:\Proj\D\tools\lint.ps1'); registrationStatus = 'parsed' })
                }
                [pscustomobject]@{
                    friendlyName = 'pre-push'; hookType = 'NativeGitHook'; scope = 'project'
                    targetProjectRoot = 'C:\Proj\C'; status = 'active'; statusReason = ''; managedBy = 'external'
                    removalPolicy = 'nativeFileOnly'; needsManualRepair = $false; clients = @(); runtimeArtifacts = @()
                    nativeGit = [pscustomobject]@{ repositoryRoot = 'C:\Proj\C'; hookPath = 'C:\Proj\C\.git\hooks\pre-push'; classification = 'externalNativeHook'; managedStages = @() }
                }
                [pscustomobject]@{
                    friendlyName = 'opaque-hook'; hookType = 'ClaudeRegistration'; scope = 'global'
                    targetProjectRoot = ''; status = 'ambiguous'; statusReason = 'command could not be parsed'; managedBy = 'unknown'
                    removalPolicy = 'unavailable'; needsManualRepair = $true; nativeGit = $null; runtimeArtifacts = @()
                    clients = @([pscustomobject]@{ client = 'claude'; settingsPath = 'C:\Users\x\.claude\settings.json'; events = @('SessionStart'); parsedTargets = @(); registrationStatus = 'unparsedCommand' })
                }
            )
            recordsAdded = 2; recordsUpdated = 1; recordsMatched = 1
            warnings = @(); errors = @(); registryPath = 'C:\Tool\state\install-registry.json'
        }
        Show-HookStatusResult -Document $document -Elapsed ([TimeSpan]::FromSeconds(3))
        return ($script:Captured -join "`n")
    }

    Check 'render: managed findings get their own group' ($render -match 'Hook Maker managed:') $render
    Check 'render: external Claude findings get their own group' ($render -match 'External Claude registrations:') $render
    Check 'render: external Codex findings get their own group' ($render -match 'External Codex registrations:') $render
    Check 'render: native Git findings get their own group' ($render -match 'Native Git hooks:') $render
    Check 'render: ambiguous/unparsed findings get their own group' ($render -match 'Ambiguous / unparsed:') $render
    Check 'render: an unparsable command is named as such, and the raw command is not shown' ($render -match 'unparsed command') $render
    Check 'render: orphan runtime candidates are listed and explicitly not deleted' (($render -match 'Orphan runtime candidates:') -and ($render -match 'Nothing here was deleted')) $render
    Check 'render: inaccessible and reparse-point paths are both reported' (($render -match 'not readable C:\\Locked') -and ($render -match 'reparse point C:\\Junction')) $render
    Check 'render: the exact settings path is shown' ($render -match [regex]::Escape('C:\Proj\A\.claude\settings.local.json')) $render
    Check 'render: the exact parsed target is shown' ($render -match [regex]::Escape('C:\Proj\A\.claude\hooks\Hook-Maker\Secrets-Check.ps1')) $render
    Check 'render: the native hook path is shown' ($render -match [regex]::Escape('C:\Proj\C\.git\hooks\pre-push')) $render
    Check 'render: uninstall capability is stated per hook (full/registration-only/native-file-only/unavailable)' (($render -match 'automatic uninstall: full') -and ($render -match 'automatic uninstall: registration-only') -and ($render -match 'automatic uninstall: native-file-only') -and ($render -match 'automatic uninstall: unavailable')) $render
    Check 'render: the totals block reports every counter' (($render -match 'directories inspected: 412') -and ($render -match 'candidate settings files: 7') -and ($render -match 'candidate Git repositories: 3') -and ($render -match 'verified logical hooks: 4') -and ($render -match 'records added: 2') -and ($render -match 'records updated: 1') -and ($render -match 'records matched: 1') -and ($render -match 'ambiguous findings: 1') -and ($render -match 'inaccessible directories: 1')) $render
    Check 'render: the totals block reports elapsed time and the exact registry path' (($render -match 'elapsed: 00:00:03') -and ($render -match [regex]::Escape('C:\Tool\state\install-registry.json'))) $render
    Check 'render: partial coverage is stated explicitly, never implied complete' (($render -match 'COVERAGE IS PARTIAL') -and ($render -match 'does NOT prove that no other hooks exist')) $render
    # The banner names a cause ONLY when the document evidences one. This
    # document lists both an unreadable path and a reparse point, so the
    # evidenced wording is required and the "did not enumerate" wording is not.
    Check 'render: partial coverage names a cause only when the scan evidenced one' (($render -match 'unreadable or were reparse points') -and ($render -notmatch 'did not enumerate which parts were skipped')) $render

    # ================================================================
    # Part 5 - Kiro is displayed as Kiro, and Claude/Codex are untouched
    # ================================================================
    # Kiro became a real third client, but this screen predated it: the group
    # switch had no KiroRegistration case (so a Kiro finding was filed under
    # "External Claude registrations:" - attributed to the WRONG client), the
    # display-name switch had no kiro case (so it printed a bare lowercase
    # "kiro"), and the roots screen listed only the Claude and Codex global
    # locations. All three now derive from the one client capability table.
    Write-Host ''
    Write-Host '--- a Kiro finding is grouped, labelled and located as Kiro ---' -ForegroundColor Cyan

    # Returns just the body of one result-screen section, so "this finding is
    # under that heading" is provable rather than inferred from co-occurrence
    # anywhere in the output.
    $sectionHeadings = @(
        'Hook Maker managed:', 'External Claude registrations:', 'External Codex registrations:',
        'External Kiro registrations:', 'Native Git hooks:', 'Ambiguous / unparsed:',
        'Orphan runtime candidates:', 'Inaccessible / skipped:', 'Totals:'
    )
    function Get-RenderSection {
        param([string]$Text, [string]$Heading)
        $start = $Text.IndexOf($Heading)
        if ($start -lt 0) { return '' }
        $start += $Heading.Length
        $end = $Text.Length
        foreach ($other in $sectionHeadings) {
            $at = $Text.IndexOf($other, $start)
            if ($at -ge 0 -and $at -lt $end) { $end = $at }
        }
        return $Text.Substring($start, $end - $start)
    }

    $kiroSection = Get-RenderSection $render 'External Kiro registrations:'
    $claudeSection = Get-RenderSection $render 'External Claude registrations:'
    $codexSection = Get-RenderSection $render 'External Codex registrations:'

    Check 'kiro: external Kiro findings get their own group' ($render -match 'External Kiro registrations:') $render
    Check 'kiro: the Kiro finding is IN the Kiro section' ($kiroSection -match 'kiro-lint') $kiroSection
    Check 'kiro: the Kiro finding is NOT filed under the external Claude section' ($claudeSection -notmatch 'kiro-lint') $claudeSection
    Check 'kiro: the Kiro finding is NOT filed under the external Codex section' ($codexSection -notmatch 'kiro-lint') $codexSection
    # Case-SENSITIVE: 'Kiro events' vs 'kiro events' is the entire defect.
    Check 'kiro: the client renders with its display name, never the bare registry id' (
        ($kiroSection -cmatch 'Kiro events:') -and ($kiroSection -cnotmatch 'kiro events:')) $kiroSection
    Check 'kiro: the Kiro registration path (a .kiro\hooks file, not a shared settings file) is shown' (
        $kiroSection -match [regex]::Escape('C:\Proj\D\.kiro\hooks\kiro-lint.kiro.hook')) $kiroSection

    # Claude and Codex must be exactly where they were, with their own findings.
    Check 'kiro: the external Claude section still holds only its own finding' (
        ($claudeSection -match 'team-formatter') -and ($claudeSection -notmatch 'vendor-lint')) $claudeSection
    Check 'kiro: the external Codex section still holds only its own finding' (
        ($codexSection -match 'vendor-lint') -and ($codexSection -notmatch 'team-formatter')) $codexSection
    Check 'kiro: Claude and Codex clients still render with their display names' (
        ($claudeSection -cmatch 'Claude events:') -and ($codexSection -cmatch 'Codex events:')) $render

    # Section ORDER: managed, then the clients in capability-table order, then
    # the two client-independent sections. Kiro is appended after Codex, so no
    # pre-existing heading moved relative to another.
    $order = @($sectionHeadings[0..5] | ForEach-Object { $render.IndexOf($_) })
    Check 'kiro: section order is managed, Claude, Codex, Kiro, native Git, ambiguous' (
        @($order | Where-Object { $_ -lt 0 }).Count -eq 0 -and
        $order[0] -lt $order[1] -and $order[1] -lt $order[2] -and
        $order[2] -lt $order[3] -and $order[3] -lt $order[4] -and $order[4] -lt $order[5]) (($order -join ','))

    # ---- the display-name function itself -------------------------------
    Check 'kiro: Get-ClientDisplayName maps kiro to Kiro' ((Get-ClientDisplayName 'kiro') -ceq 'Kiro') (Get-ClientDisplayName 'kiro')
    Check 'kiro: Get-ClientDisplayName still maps claude/codex unchanged' (
        ((Get-ClientDisplayName 'claude') -ceq 'Claude') -and ((Get-ClientDisplayName 'codex') -ceq 'Codex')) (
        (Get-ClientDisplayName 'claude') + '/' + (Get-ClientDisplayName 'codex'))
    Check 'kiro: every capability-table client has a display name here' (
        @(@(Get-HookMakerClientIds) | Where-Object {
            (Get-ClientDisplayName $_) -cne [string](Get-HookMakerClientCapability -ClientId $_).displayName }).Count -eq 0) (
        (@(Get-HookMakerClientIds) -join ','))
    # An id the table does not know keeps the old default-branch behaviour:
    # returned unchanged, never blank and never guessed onto a known client.
    Check 'kiro: an unknown client id is returned unchanged' ((Get-ClientDisplayName 'vendor-x') -ceq 'vendor-x') (Get-ClientDisplayName 'vendor-x')
    Check 'kiro: an empty client id is returned unchanged, not thrown on' ((Get-ClientDisplayName '') -ceq '') 'empty'

    # ---- the roots screen lists every client's global location -----------
    # Driven offline: -IncludeGlobal makes the real scan add $HOME as a root,
    # which is far too expensive for a test. Invoke-GetHookStatus prints the
    # roots screen BEFORE it checks the scanner exists (deliberately - see the
    # comment at that check), so pointing $StatusScript at an absent file
    # exercises the listing and stops there, scanning nothing.
    $rootsRender = & {
        $script:Captured = New-Object System.Collections.Generic.List[string]
        function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Args) [void]$script:Captured.Add((@($Args) -join ' ')) }
        function Get-Painted { param([AllowEmptyString()][string]$Text, [string]$Color) return $Text }
        function Write-PhaseHeader { param([string]$Text, [string]$Color, [string]$Char = '=') [void]$script:Captured.Add($Text) }
        function Write-MenuTitle { param([string]$Text) [void]$script:Captured.Add($Text) }
        function Write-Field { param([string]$Name, [AllowEmptyString()][string]$Value, [string]$ValueColor = '') [void]$script:Captured.Add(($Name.Trim() + ': ' + $Value)) }
        function Write-NoteLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-ErrorLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-Log { param([string]$Level, [string]$Component, [string]$Message) }
        function New-QuestionPrompt { param([string]$Title, [string]$Details, [string]$Default) return $Title }
        function Get-ExampleText { param([string]$Text) return $Text }
        function Read-Answer { param([string]$Prompt, [string]$LogLabel) return $Work }
        function Read-YesNo { param([string]$Prompt, [bool]$Default, [string]$LogLabel) return $true }
        $C = @{ Reset = ''; Bold = ''; Red = ''; Green = ''; White = ''; Gray = ''; Dim = ''; LightBlue = ''; HintYellow = ''; NoteYellow = ''; Aqua = ''; Amber = ''; Mint = ''; Orchid = ''; Teal = ''; Summary = ''; Process = ''; Input = '' }
        $script:MenuSep = ' | '
        $StatusScript = Join-Path $Work 'no-such-scanner.ps1'
        . (Join-Path $ScriptRoot 'Setup-SyncGroupHookStatus.ps1')
        [void](Invoke-GetHookStatus)
        return ($script:Captured -join "`n")
    }

    $claudeGlobal = Join-Path $HOME (Get-HookMakerClientCapability -ClientId 'claude').globalRegistration
    $codexGlobal = Join-Path $HOME (Get-HookMakerClientCapability -ClientId 'codex').globalRegistration
    $kiroGlobal = Join-Path $HOME (Get-HookMakerClientCapability -ClientId 'kiro').globalRegistration
    Check 'roots: the Claude global settings file is still listed' (
        ($rootsRender -match [regex]::Escape($claudeGlobal)) -and ($rootsRender -cmatch 'Claude global')) $rootsRender
    Check 'roots: the Codex global settings file is still listed' (
        ($rootsRender -match [regex]::Escape($codexGlobal)) -and ($rootsRender -cmatch 'Codex global')) $rootsRender
    # Kiro is perHookFile, so its global location is the registration DIRECTORY.
    # Get-CanonicalClientSettingsPath refuses that client by design; a naive
    # 'kiro' added to the old pair would have thrown out of the roots screen.
    Check 'roots: the Kiro global registration directory is listed alongside them' (
        ($rootsRender -match [regex]::Escape($kiroGlobal)) -and ($rootsRender -cmatch 'Kiro global')) $rootsRender
    $rootsOrder = @(@('Claude global', 'Codex global', 'Kiro global') | ForEach-Object { $rootsRender.IndexOf($_) })
    Check 'roots: global locations are listed in capability-table order' (
        $rootsOrder[0] -ge 0 -and $rootsOrder[1] -gt $rootsOrder[0] -and $rootsOrder[2] -gt $rootsOrder[1]) (($rootsOrder -join ','))
    Check 'roots: the run stopped at the absent scanner and scanned nothing' (
        ($rootsRender -match 'The scanner is not available') -and ($rootsRender -notmatch 'directories inspected')) $rootsRender

    # A failed scan must report nothing-was-written and print no findings.
    $failedRender = & {
        $script:Captured = New-Object System.Collections.Generic.List[string]
        function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Args) [void]$script:Captured.Add((@($Args) -join ' ')) }
        function Get-Painted { param([AllowEmptyString()][string]$Text, [string]$Color) return $Text }
        function Write-PhaseHeader { param([string]$Text, [string]$Color, [string]$Char = '=') [void]$script:Captured.Add($Text) }
        function Write-MenuTitle { param([string]$Text) [void]$script:Captured.Add($Text) }
        function Write-Field { param([string]$Name, [AllowEmptyString()][string]$Value, [string]$ValueColor = '') [void]$script:Captured.Add(($Name.Trim() + ': ' + $Value)) }
        function Write-NoteLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-ErrorLine { param([string]$Message) [void]$script:Captured.Add($Message) }
        function Write-Log { param([string]$Level, [string]$Component, [string]$Message) }
        function Get-ClientDisplayName { param([string]$Client) return $Client }
        $C = @{ Reset = ''; Bold = ''; Red = ''; Green = ''; White = ''; Gray = ''; Dim = ''; LightBlue = ''; HintYellow = ''; NoteYellow = ''; Aqua = ''; Amber = ''; Mint = ''; Orchid = ''; Teal = ''; Summary = ''; Process = ''; Input = '' }
        $script:MenuSep = ' | '
        . (Join-Path $ScriptRoot 'Setup-SyncGroupHookStatus.ps1')
        Show-HookStatusResult -Document ([pscustomobject]@{ overall = 'failed'; errors = @('access denied at the root') }) -Elapsed ([TimeSpan]::Zero)
        return ($script:Captured -join "`n")
    }
    Check 'render: a failed scan says nothing was written to the registry' ($failedRender -match 'Nothing was written to the install registry') $failedRender
    Check 'render: a failed scan surfaces the reported error' ($failedRender -match 'access denied at the root') $failedRender
    Check 'render: a failed scan prints no totals block' ($failedRender -notmatch 'directories inspected') $failedRender

    # ================================================================
    # Part 6 - a non-removable row is skipped, never a veto over the
    # rest of the uninstall selection
    # ================================================================
    # Any row needing manual repair used to reject the WHOLE selection with a
    # continue, so picking 370 rows containing 3 unrepairable ones removed
    # nothing and simply re-asked - the only way forward was to hand-compute the
    # gaps. The blocked rows are now skipped, the rest proceeds, the skipped
    # ones are listed by name and counted, and only a selection where NOTHING is
    # removable is still refused outright.
    #
    # Driven through the same & {} stub harness the result screens above use:
    # the registry readers, the UI primitives and the uninstall EXECUTOR are all
    # stubbed, so the selection logic runs for real while nothing is removed.
    # The removable records are JSON clones of the REAL managed record installed
    # at the top of this suite (only their ids differ - friendlyName is pinned to
    # the runtime path by Test-InstallRecordValid), so the row model sees a
    # genuine record shape rather than a hand-built guess.
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
        function New-QuestionPrompt { param([string]$Title, [string]$Details, [string]$Default) return $Title }
        # A scripted answer queue, exhausted into '0' so a wrong expectation
        # ends the screen instead of looping forever.
        function Read-Answer {
            param([string]$Prompt, [string]$LogLabel)
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
                # 1-4: two removable rows and two blocked ones in one selection.
                [pscustomobject]@{ Name = 'mixed'; Answers = @('1-4') }
                # 3,4: nothing removable at all - then 0 to leave the re-ask.
                [pscustomobject]@{ Name = 'allBlocked'; Answers = @('3,4', '0') }
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
    Check 'uninstall: the refusal re-asks instead of exiting the screen' (
        (@([regex]::Matches($allBlocked, [regex]::Escape('Installed hooks:'))).Count -eq 2) -and
        ($allBlocked -match 'Canceled\. Nothing was changed\.')) $allBlocked
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
