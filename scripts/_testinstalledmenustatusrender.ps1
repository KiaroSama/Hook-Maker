# Test-InstalledHooksMenu.ps1 scenario block: the hook-status result screen: every finding group, the exact paths and per-hook uninstall capability, the totals block, and partial coverage stated explicitly rather than implied as complete.
#
# Dot-sourced by Test-InstalledHooksMenu.ps1 INTO its scope - it relies on that
# suite's harness (Check, $script:Pass/$script:Fail), helpers, fixtures and
# workspace. NOT a standalone suite: run scripts\Test-InstalledHooksMenu.ps1.

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
