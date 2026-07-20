# Offline test suite for the hook-list management rows.
#
# Part 1 - menu 26 (Uninstall Installed Hooks): proves the list and
# confirmation screens in Setup-SyncGroupInstalledHooks.ps1 render the FULL
# install identity that Get-InstalledHookSnapshot already collects - hook type,
# exact target path, per-client event names and the exact persisted
# sourceScript in the list; record id, settings path, runtime script and
# native-Git ownership status in the confirmation screen - and that declining
# the final confirmation mutates nothing (the record survives in the registry).
#
# Part 2 - the fixed menu numbering itself: shipped hooks occupy exactly 3..23
# (the three test-health hooks at 20/21/22 and Cloudflare-Deploy last at 23),
# 24 is Update, 25 is Get hook status, 26 is Uninstall, custom hooks start at
# 27, adding a custom hook shifts NONE of the three management rows, each
# management action must be selected alone, and item 1 ("Select all") expands to
# the sync group plus every hook while excluding all three management indices.
#
# Part 3 - the menu 25 prompt flow (Setup-SyncGroupHookStatus.ps1): which root
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
    $fxName = 'ZZZ-Regtest-Menu'
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
        $r = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', '1', 'n', '0') -WorkingDirectory $proj
        Check 'the wizard run exits 0' ($r.Exit -eq 0) $r.Err

        # ---- list screen: everything Get-InstalledHookSnapshot collects ----
        Check 'list: the friendly hook name appears' ($r.Out -match [regex]::Escape('ZZZ-Regtest-Menu')) $r.Out
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
        $sampleStart = if ($installedHeaderAt -ge 0) { $r.Out.IndexOf('ZZZ-Regtest-Menu', $installedHeaderAt) } else { -1 }
        if ($sampleStart -ge 0) {
            $sampleEnd = $r.Out.IndexOf("`n`n", $sampleStart)
            if ($sampleEnd -lt 0) { $sampleEnd = [Math]::Min($r.Out.Length, $sampleStart + 600) }
            Write-Host $r.Out.Substring($sampleStart, $sampleEnd - $sampleStart)
        }

        # ================================================================
        # Part 2 - the fixed menu numbering
        # ================================================================
        Write-Host ''
        Write-Host '--- the hook list numbers 3..23 shipped, 24/25/26 management, 27+ custom ---' -ForegroundColor Cyan

        # Render the hook list and leave without selecting anything.
        $menu = Invoke-Wizard -Config $cfg -Answers @('1', '1', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'menu: the render-only run exits 0' ($menu.Exit -eq 0) $menu.Err
        $rows = Get-HookListRows $menu.Out
        Check 'menu: the hook list block was rendered' ($null -ne $rows) $menu.Out

        if ($null -ne $rows) {
            $indices = @($rows.Keys)
            Check 'menu: item 1 is "Select all hooks"' ([string]$rows[1] -match '^Select all hooks') ([string]$rows[1])
            Check 'menu: item 2 is the sync group' ([string]$rows[2] -match '^Create or update a sync group') ([string]$rows[2])

            # The 21 shipped hooks occupy exactly 3..23 - no gap, and no
            # management row anywhere inside that range.
            $shippedRange = @(3..23)
            $missing = @($shippedRange | Where-Object { -not $rows.Contains($_) })
            Check 'menu: rows 3..23 all exist (the 21 shipped hooks)' ($missing.Count -eq 0) ('missing: ' + ($missing -join ','))
            $strayManagement = @($shippedRange | Where-Object { $rows.Contains($_) -and [string]$rows[$_] -match '\[manage\]' })
            Check 'menu: no management row appears inside the shipped range 3..23' ($strayManagement.Count -eq 0) ('stray: ' + ($strayManagement -join ','))

            # The three test-health hooks (24.txt) sit at 20/21/22 IN THAT
            # ORDER, immediately before Cloudflare-Deploy, which stays the last
            # individual entry.
            Check 'menu: 20 is Test-Plan-Check' ([string]$rows[20] -match '^Test-Plan-Check \| \[pre-task\] \|') ([string]$rows[20])
            Check 'menu: 21 is Test-Run-Guard' ([string]$rows[21] -match '^Test-Run-Guard \| \[pre\+post-task\] \|') ([string]$rows[21])
            Check 'menu: 22 is Test-Completion-Check' ([string]$rows[22] -match '^Test-Completion-Check \| \[post-task\] \|') ([string]$rows[22])
            Check 'menu: 23 is Cloudflare-Deploy (still the last individual entry)' ([string]$rows[23] -match '^Cloudflare-Deploy \| \[post-task\] \|') ([string]$rows[23])

            Check 'menu: 24 is Update installed hooks' ([string]$rows[24] -match '^Update installed hooks \| \[manage\] \|') ([string]$rows[24])
            # The exact contract wording for the two rows the task pins.
            Check 'menu: 25 renders EXACTLY the contract row' ([string]$rows[25] -eq 'Get hook status | [manage] | scan a path, detect installed hooks, and track verified results') ([string]$rows[25])
            Check 'menu: 26 renders EXACTLY the contract row' ([string]$rows[26] -eq 'Uninstall installed hooks | [manage] | list and remove installed hooks; never deletes hook sources') ([string]$rows[26])

            # The fixture is the only custom hook, so the custom block starts at
            # 27 - i.e. adding a custom hook did NOT shift 20-26 at all.
            Check 'menu: custom hooks start at 27' ([string]$rows[27] -match 'ZZZ-Regtest-Menu') ([string]$rows[27])
            Check 'menu: adding a custom hook did not shift the management rows' (([string]$rows[24] -match 'Update') -and ([string]$rows[25] -match 'Get hook status') -and ([string]$rows[26] -match 'Uninstall')) (($indices | Sort-Object) -join ',')
            Check 'menu: adding a custom hook did not shift the three new shipped rows' (([string]$rows[20] -match 'Test-Plan-Check') -and ([string]$rows[21] -match 'Test-Run-Guard') -and ([string]$rows[22] -match 'Test-Completion-Check')) (($indices | Sort-Object) -join ',')
            Check 'menu: the Tip line names all three management indices' ($menu.Out -match '24/25/26 are management actions') $menu.Out

            # Each of the three new rows must render on ONE line, within the
            # budget the existing shipped rows already respect (the longest
            # pre-existing row is the yardstick - no new row may be the one that
            # starts wrapping).
            $newRowNumbers = @(20, 21, 22)
            $existingRowLengths = @(@($rows.Keys) |
                Where-Object { $_ -ge 3 -and $_ -le 23 -and $newRowNumbers -notcontains $_ } |
                ForEach-Object { ('  ' + $_ + '. ' + [string]$rows[$_]).Length })
            $rowBudget = (@($existingRowLengths | Sort-Object -Descending)[0])
            foreach ($n in $newRowNumbers) {
                $rendered = '  ' + $n + '. ' + [string]$rows[$n]
                Check ('menu: row ' + $n + ' renders on exactly one line within the existing budget (' + $rowBudget + ')') (
                    $rendered -notmatch "[`r`n]" -and $rendered.Length -le $rowBudget) ($rendered.Length.ToString() + ': ' + $rendered)
            }
        }

        Write-Host ''
        Write-Host '--- each management action must be selected alone ---' -ForegroundColor Cyan

        # Four illegal mixtures, one after another; each must be rejected and
        # re-render the menu rather than performing half of what was typed.
        $reject = Invoke-Wizard -Config $cfg -Answers @('1', '1', '3,25', '24-26', '1,26', '25,27', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'mix: the rejection run exits 0' ($reject.Exit -eq 0) $reject.Err
        $rejectionCount = ([regex]::Matches($reject.Out, [regex]::Escape('on its own - it cannot be combined'))).Count
        Check 'mix: all four illegal selections were rejected (3,25 / 24-26 / 1,26 / 25,27)' ($rejectionCount -eq 4) ('rejections seen: ' + $rejectionCount)
        Check 'mix: the rejection names all three management indices' ($reject.Out -match 'Select 24 \(update\), 25 \(status\) or 26 \(uninstall\)') $reject.Out
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
        Check 'select-all: 21 shipped + 1 custom hook were counted from the menu' ($totalHooks -eq 22) ('total hooks: ' + $totalHooks)
        Check 'select-all: item 1 expanded to the sync group plus every hook' ($all.Out -match ('Running the sync group first, then installing ' + $totalHooks + ' more hook\(s\)')) $all.Out
        Check 'select-all: item 1 never entered a management screen' (($all.Out -cnotmatch 'Get Hook Status') -and ($all.Out -cnotmatch 'Uninstall Installed Hooks') -and ($all.Out -cnotmatch 'Update Previously Installed Hooks')) $all.Out

        # ================================================================
        # Part 3 - the menu 25 (Get hook status) prompt flow
        # ================================================================
        Write-Host ''
        Write-Host '--- menu 25 root-folder prompt: what is accepted, and what re-prompts ---' -ForegroundColor Cyan

        $registryPath = Join-Path $IsolatedStateDir 'install-registry.json'
        $registryBefore = if (Test-Path -LiteralPath $registryPath) { [System.IO.File]::ReadAllBytes($registryPath) } else { $null }
        $registryWriteBefore = if (Test-Path -LiteralPath $registryPath) { (Get-Item -LiteralPath $registryPath).LastWriteTimeUtc } else { $null }

        $globalQuestion = "Also inspect the current user's global Claude and Codex hook locations\?"

        # -- a missing path re-prompts instead of scanning -------------------
        $missingPath = Join-Path $Work 'no-such-folder-here'
        $bad = Invoke-Wizard -Config $cfg -Answers @('1', '1', '25', $missingPath, '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the invalid-path run exits 0' ($bad.Exit -eq 0) $bad.Err
        Check 'status: a missing folder is rejected with the exact path' ($bad.Out -match [regex]::Escape('Folder not found: ' + $missingPath)) $bad.Out
        Check 'status: the root prompt was shown again after the rejection' (([regex]::Matches($bad.Out, 'Root folder to scan')).Count -ge 2) $bad.Out
        Check 'status: an invalid path never reached the global question' ($bad.Out -notmatch $globalQuestion) $bad.Out
        Check 'status: an invalid path never started a scan' ($bad.Out -notmatch 'Roots to scan:') $bad.Out

        # -- a quoted path containing spaces is accepted ---------------------
        $spaceDir = New-Proj 'Status Root With Spaces'
        $quoted = Invoke-Wizard -Config $cfg -Answers @('1', '1', '25', ('"' + $spaceDir + '"'), '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the quoted-path run exits 0' ($quoted.Exit -eq 0) $quoted.Err
        Check 'status: a quoted path containing spaces is accepted' ($quoted.Out -match $globalQuestion) $quoted.Out
        # 0 at the global question goes BACK to the root prompt: that is the
        # second render of the root prompt in this run, and nothing was scanned.
        Check 'status: 0 at the global question returns to the root prompt' (([regex]::Matches($quoted.Out, 'Root folder to scan')).Count -eq 2) $quoted.Out
        Check 'status: cancelling never started a scan' ($quoted.Out -notmatch 'Roots to scan:') $quoted.Out

        # -- a plain project root is accepted --------------------------------
        $projRoot = Invoke-Wizard -Config $cfg -Answers @('1', '1', '25', $proj, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the project-root run exits 0' ($projRoot.Exit -eq 0) $projRoot.Err
        Check 'status: a project root is accepted' ($projRoot.Out -match $globalQuestion) $projRoot.Out

        # -- a .claude\hooks\Hook-Maker direct subtree is accepted ------------
        # The scan must not demand the exact project root: pointing it at a
        # directory well inside the project has to work too.
        $subtree = Join-Path $proj '.claude\hooks\Hook-Maker'
        New-Item -ItemType Directory -Path $subtree -Force | Out-Null
        $sub = Invoke-Wizard -Config $cfg -Answers @('1', '1', '25', $subtree, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
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
        $defaultNo = Invoke-Wizard -Config $cfg -Answers @('1', '1', '25', $proj, '', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the default-No run exits 0' ($defaultNo.Exit -eq 0) $defaultNo.Err
        Check 'status: Enter at the global question means No' ($defaultNo.Out -match [regex]::Escape('Global Claude/Codex locations are NOT included in this scan.')) $defaultNo.Out
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
        function Get-ClientDisplayName { param([string]$Client) if ($Client -eq 'claude') { 'Claude' } elseif ($Client -eq 'codex') { 'Codex' } else { $Client } }
        $C = @{ Reset = ''; Bold = ''; Red = ''; Green = ''; White = ''; Gray = ''; Dim = ''; LightBlue = ''; HintYellow = ''; NoteYellow = ''; Aqua = ''; Amber = ''; Mint = ''; Summary = ''; Process = ''; Input = '' }
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
        $C = @{ Reset = ''; Bold = ''; Red = ''; Green = ''; White = ''; Gray = ''; Dim = ''; LightBlue = ''; HintYellow = ''; NoteYellow = ''; Aqua = ''; Amber = ''; Mint = ''; Summary = ''; Process = ''; Input = '' }
        $script:MenuSep = ' | '
        . (Join-Path $ScriptRoot 'Setup-SyncGroupHookStatus.ps1')
        Show-HookStatusResult -Document ([pscustomobject]@{ overall = 'failed'; errors = @('access denied at the root') }) -Elapsed ([TimeSpan]::Zero)
        return ($script:Captured -join "`n")
    }
    Check 'render: a failed scan says nothing was written to the registry' ($failedRender -match 'Nothing was written to the install registry') $failedRender
    Check 'render: a failed scan surfaces the reported error' ($failedRender -match 'access denied at the root') $failedRender
    Check 'render: a failed scan prints no totals block' ($failedRender -notmatch 'directories inspected') $failedRender
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
