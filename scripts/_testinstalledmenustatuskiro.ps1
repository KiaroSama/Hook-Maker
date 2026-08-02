# Test-InstalledHooksMenu.ps1 scenario block: a Kiro finding grouped, labelled and located as Kiro (never filed under Claude or Codex), section ordering, client display names, the global roots listing, and a failed scan reporting honestly with no totals block.
#
# Dot-sourced by Test-InstalledHooksMenu.ps1 INTO its scope - it relies on that
# suite's harness (Check, $script:Pass/$script:Fail), helpers, fixtures and
# workspace. NOT a standalone suite: run scripts\Test-InstalledHooksMenu.ps1.

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
