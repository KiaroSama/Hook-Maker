# Hook Maker registration ownership: given a registered command in a client's
# settings, is it OURS, and if so which installation does it belong to?
#
# Deliberately separate from plan construction and from staging - this is the
# only concern that reads a THIRD PARTY's document and decides ownership, and
# it is consumed by install, update, status, discovery and uninstall alike.
# Dot-sourced by _installplan.ps1 into the caller's scope; not a standalone
# module.

# ---- Hook Maker registration ownership -------------------------------------

# The ONE place that decides "is this registered command a Hook Maker command,
# and if so which installation does it belong to?".
#
# Ownership is proven by the managed runtime PATH SHAPE
# (...\hooks\Hook-Maker\<Name>\<file>.ps1, or the legacy ...\hooks\HookMaker\...),
# never by a bare script basename - a user's own unrelated script that happens
# to share a filename must never be treated as ours.
function Get-HookMakerCommandInfo {
    param(
        [string]$Command,
        # Tool roots whose own hooks\ folder is KNOWN to be Hook Maker's. Only
        # these make the ambiguous historical tool-folder shape provable.
        [string[]]$KnownToolRoots = @()
    )
    $result = [pscustomobject]@{
        IsHookMaker   = $false
        # Looks like a Hook Maker layout but ownership cannot be proven.
        # Such entries are PRESERVED and reported, never removed.
        IsAmbiguous   = $false
        RuntimeScript = ''
        HookName      = ''
        Profile       = ''
        ConfigPath    = ''
        Layout        = ''
    }
    if ([string]::IsNullOrWhiteSpace($Command)) { return $result }

    # Form 1 (current + the renamed-folder legacy): a self-contained managed
    # runtime under ...\hooks\Hook-Maker\<Name>\<file>.ps1 (or the older
    # un-hyphenated HookMaker root). This shape is unambiguous - only Hook
    # Maker creates it.
    $match = [regex]::Match($Command, '(?<full>[^"]*[\\/]hooks[\\/](?<root>Hook-Maker|HookMaker)[\\/](?<name>[^\\/"]+)[\\/](?<leaf>[^\\/"]+\.ps1))')
    if ($match.Success) {
        $result.IsHookMaker = $true
        $result.RuntimeScript = $match.Groups['full'].Value
        $result.HookName = $match.Groups['name'].Value
        $result.Layout = if ($match.Groups['root'].Value -eq 'HookMaker') { 'legacy-root' } else { 'current' }
    }
    else {
        # Form 2 (proven historical): before self-contained installs, the
        # registered command pointed straight at a Hook Maker TOOL FOLDER's own
        # source layout, <toolRoot>\hooks\<Name>\<Name>.ps1.
        #
        # That path SHAPE alone is not proof of ownership - any project can have
        # hooks/Foo/Foo.ps1 - so it is only accepted when the path is rooted
        # under a KNOWN Hook Maker tool root supplied by the caller
        # (-KnownToolRoots: this installation plus any tool root recorded in the
        # registry's own history). Without that proof the entry is reported as
        # AMBIGUOUS: preserved, never removed.
        $legacy = [regex]::Match($Command, '(?<full>[^"]*[\\/]hooks[\\/](?<name>[^\\/"]+)[\\/](?<leaf>[^\\/"]+)\.ps1)')
        if (-not ($legacy.Success -and [string]::Equals($legacy.Groups['name'].Value, $legacy.Groups['leaf'].Value, [System.StringComparison]::OrdinalIgnoreCase))) {
            return $result
        }
        $candidatePath = $legacy.Groups['full'].Value
        $provenRoot = $false
        foreach ($knownRoot in @($KnownToolRoots)) {
            if ([string]::IsNullOrWhiteSpace($knownRoot)) { continue }
            $hooksRoot = Join-Path $knownRoot 'hooks'
            if (Test-PathContainedIn -ChildPath $candidatePath -ParentPath $hooksRoot) { $provenRoot = $true; break }
        }
        if (-not $provenRoot) {
            $result.IsAmbiguous = $true
            $result.RuntimeScript = $candidatePath
            $result.HookName = $legacy.Groups['name'].Value
            $result.Layout = 'ambiguous-toolfolder'
            return $result
        }
        $result.IsHookMaker = $true
        $result.RuntimeScript = $candidatePath
        $result.HookName = $legacy.Groups['name'].Value
        $result.Layout = 'legacy-toolfolder'
    }
    $profileMatch = [regex]::Match($Command, '-Profile\s+"([^"]*)"')
    if ($profileMatch.Success) { $result.Profile = $profileMatch.Groups[1].Value }
    $configMatch = [regex]::Match($Command, '-ConfigPath\s+"([^"]*)"')
    if ($configMatch.Success) { $result.ConfigPath = $configMatch.Groups[1].Value }
    return $result
}

# Every command-bearing field a client may use. Checked consistently everywhere
# so a handler registered only under commandWindows/command_windows is neither
# missed during discovery nor orphaned during stale removal.
$script:HookCommandFieldNames = @('command', 'commandWindows', 'command_windows')

function Get-HandlerCommandValues {
    param([Parameter(Mandatory = $true)]$Handler)
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($field in $script:HookCommandFieldNames) {
        if ($null -ne $Handler.PSObject.Properties[$field]) {
            $value = [string]$Handler.$field
            if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$values.Add($value) }
        }
    }
    return $values.ToArray()
}

# Does this handler belong to the given logical installation? Requires a real
# managed-runtime path match on at least one command field, the same hook name,
# and - for the sync engine - the same profile.
#
# A handler commonly carries the SAME logical command in more than one field
# (portable + Windows form). Ownership requires EVERY present field to
# positively agree with this install's target (mirroring _hookdiscovery.ps1's
# Get-HandlerTargetAgreement "all agree" philosophy for the read-only
# scanner). Get-HandlerCommandValues only returns fields that are actually
# present, so anything reaching this loop is real content - a plain user
# command, a DIFFERENT hook, a different profile, or an ambiguous unproven
# legacy shape all mean the handler is not fully ours, and removing it would
# silence whatever that other field pointed at.
function Test-HandlerBelongsToInstall {
    param(
        [Parameter(Mandatory = $true)]$Handler,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [string]$ProfileId = '',
        [string[]]$AlsoMatchHookNames = @(),
        [string[]]$KnownToolRoots = @()
    )
    $names = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    [void]$names.Add($FriendlyName)
    foreach ($alias in @($AlsoMatchHookNames)) {
        if (-not [string]::IsNullOrWhiteSpace($alias)) { [void]$names.Add($alias) }
    }
    $anyAgreed = $false
    foreach ($command in @(Get-HandlerCommandValues -Handler $Handler)) {
        $info = Get-HookMakerCommandInfo -Command $command -KnownToolRoots $KnownToolRoots
        if ($info.IsHookMaker -and $names.Contains($info.HookName) -and
            ([string]::IsNullOrWhiteSpace($ProfileId) -or $info.Profile -eq $ProfileId)) {
            $anyAgreed = $true
            continue
        }
        return $false
    }
    return $anyAgreed
}
