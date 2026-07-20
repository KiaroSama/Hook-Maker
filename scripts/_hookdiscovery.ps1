# ---------------------------------------------------------------------------
# Shared discovery primitives for the explicit hook-status scan (menu 22) and
# the discovered-record remover.
#
# ONE responsibility: turn on-disk evidence into stable, non-secret identity.
#
# This file exists because the scanner and the remover MUST agree byte-for-byte
# on what identifies a handler. The scanner persists a fingerprint; the remover
# recomputes it from the live file and refuses to touch anything unless it
# still matches. If those two computations could ever drift apart, the remover
# would either silently fail to find its target or - far worse - match the
# wrong handler. So the computation exists exactly once, here.
#
# Nothing in this file executes, dot-sources, or interprets discovered content.
# It only reads bytes and hashes structure.
#
# Dot-sourced by Get-HookStatus.ps1 and Uninstall-DiscoveredHook.ps1. Depends
# only on the .NET BCL, so it is safe to load before anything else.
# ---------------------------------------------------------------------------

# ---- canonical structural identity -----------------------------------------

# Deterministic textual form of a JSON-derived object.
#
# ConvertFrom-Json preserves the ORDER properties appeared in the file, so two
# byte-different files describing the same handler ({"type":"command","timeout":60}
# vs {"timeout":60,"type":"command"}) would otherwise fingerprint differently and
# a rescan would report a spurious change. Sorting property names ordinally
# removes that, so the fingerprint tracks MEANING, not formatting.
#
# Types are tagged (s:/n:/b:/z:) so the string "60" and the number 60 cannot
# collide into the same fingerprint - a handler whose timeout silently changed
# type is a real difference worth catching.
function ConvertTo-CanonicalStructureString {
    param($Value, [int]$Depth = 0)

    # ConvertFrom-Json output is a finite tree, so this cap is a guard against
    # pathological nesting rather than a real cycle risk.
    if ($Depth -gt 32) { return '!deep' }
    if ($null -eq $Value) { return 'z:' }

    if ($Value -is [string]) { return 's:' + $Value }
    if ($Value -is [bool]) { return 'b:' + $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return 'n:' + [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            [void]$parts.Add((ConvertTo-CanonicalStructureString -Value ([string]$key) -Depth ($Depth + 1)) + '=' +
                (ConvertTo-CanonicalStructureString -Value $Value[$key] -Depth ($Depth + 1)))
        }
        return '{' + ($parts.ToArray() -join ';') + '}'
    }

    # Order IS meaning for an array (handler execution order), so it is kept.
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($Value)) {
            [void]$parts.Add((ConvertTo-CanonicalStructureString -Value $item -Depth ($Depth + 1)))
        }
        return '[' + ($parts.ToArray() -join ',') + ']'
    }

    if ($Value -is [psobject] -and $null -ne $Value.PSObject) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($property in @($Value.PSObject.Properties | Sort-Object -Property Name -CaseSensitive)) {
            [void]$parts.Add('s:' + $property.Name + '=' +
                (ConvertTo-CanonicalStructureString -Value $property.Value -Depth ($Depth + 1)))
        }
        return '{' + ($parts.ToArray() -join ';') + '}'
    }

    return 's:' + [string]$Value
}

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

# Identity of ONE handler, as a 64-hex string.
#
# The raw command text is hashed but never persisted: a command line can embed a
# token or an expanded secret-bearing environment value, and the registry must
# not become a place secrets leak into. The hash is one-way, so it gives exact
# later matching without storing the text itself.
function Get-HandlerFingerprint {
    param([Parameter(Mandatory = $true)]$Handler)
    return (Get-Sha256Hex -Text ('handler|' + (ConvertTo-CanonicalStructureString -Value $Handler)))
}

# Identity of the GROUP a handler sits in (its matcher context), excluding the
# handler list itself - so a group keeps its identity as handlers are added or
# removed around ours. Used together with the handler fingerprint and the event
# name; a handler's array index is only ever a hint.
function Get-MatcherFingerprint {
    param([Parameter(Mandatory = $true)]$Group)
    $shape = [pscustomobject]@{}
    foreach ($property in @($Group.PSObject.Properties)) {
        if ($property.Name -eq 'hooks') { continue }
        Add-Member -InputObject $shape -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
    }
    return (Get-Sha256Hex -Text ('matcher|' + (ConvertTo-CanonicalStructureString -Value $shape)))
}

function Get-FileSha256Hex {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch { return '' }
}

# ---- path identity ---------------------------------------------------------

# The key used to deduplicate paths during a scan. Windows paths are
# case-insensitive, so the key is lowercased; a trailing separator is stripped
# so "C:\x" and "C:\x\" are one directory, but a drive root ("C:\") keeps its
# separator because "C:" alone means something different (the drive's current
# directory) to the Win32 path APIs.
function Get-CanonicalPathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return '' }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
    return $full.ToLowerInvariant()
}

function Get-CanonicalPathOrEmpty {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return '' }
}

# Symlinks, junctions and mount points are never followed during the walk: a
# junction pointing at its own ancestor is an infinite tree, and one pointing
# outside the user's chosen root would silently scan somewhere they did not ask
# for. Both are reported as skipped rather than traversed.
function Test-IsReparsePoint {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    }
    catch { return $false }
}

# ---- command target parsing (never execution) ------------------------------

# Extensions that can plausibly BE the thing a hook runs. Used only to pick the
# most likely target out of an already-tokenized command line.
$script:DiscoveryTargetExtensions = @('.ps1', '.psm1', '.js', '.mjs', '.cjs', '.py', '.sh', '.bash', '.rb', '.cmd', '.bat', '.exe')

# Split a command line the way a shell would GROUP it, without any of the
# semantics: quotes group, whitespace separates, and nothing is expanded,
# substituted, or run. This is deliberately a dumb tokenizer - the moment it
# tried to be clever about operators or variables it would be interpreting
# untrusted input.
function Split-CommandTokens {
    param([string]$Command)
    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Command)) { return $tokens.ToArray() }
    $current = New-Object System.Text.StringBuilder
    $quote = [char]0
    foreach ($ch in $Command.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 } else { [void]$current.Append($ch) }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ([char]::IsWhiteSpace($ch)) {
            if ($current.Length -gt 0) { [void]$tokens.Add($current.ToString()); [void]$current.Clear() }
            continue
        }
        [void]$current.Append($ch)
    }
    if ($current.Length -gt 0) { [void]$tokens.Add($current.ToString()) }
    return $tokens.ToArray()
}

# What script/executable does this command line run?
#
# Returns Parsed=$false with a Reason rather than guessing. "Cannot be parsed"
# is a legitimate, reportable outcome: per the discovery model a registration is
# still an installed hook even when its target is unprovable - it just cannot be
# automatically removed.
#
# Never executes, dot-sources, or resolves the command in any way.
function Get-CommandTargetInfo {
    param([string]$Command)

    $result = [pscustomobject]@{
        Parsed = $false
        Target = ''
        Reason = ''
        Tokens = 0
    }
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $result.Reason = 'empty command'
        return $result
    }

    $tokens = @(Split-CommandTokens -Command $Command)
    $result.Tokens = $tokens.Count
    if ($tokens.Count -eq 0) {
        $result.Reason = 'no tokens'
        return $result
    }

    # A shell operator means the line runs more than one thing, so no single
    # target can be claimed. Reported as ambiguous instead of picking one.
    foreach ($token in $tokens) {
        if ($token -eq '|' -or $token -eq '&&' -or $token -eq '||' -or $token -eq ';' -or $token -eq '&') {
            $result.Reason = 'command chains multiple operations'
            return $result
        }
    }

    # Preferred: an explicit -File/--file argument, which is exactly how this
    # tool and most PowerShell hook registrations name their script.
    for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
        if ($tokens[$i] -ieq '-File' -or $tokens[$i] -ieq '--file' -or $tokens[$i] -ieq '-f') {
            $candidate = Get-CanonicalPathOrEmpty $tokens[$i + 1]
            if ($candidate -ne '') {
                $result.Parsed = $true
                $result.Target = $candidate
                return $result
            }
        }
    }

    # Otherwise: the first token carrying a runnable extension. Scanning all
    # tokens (not just the first) is what finds `pwsh -NoProfile x.ps1` and
    # `node tools/hook.js` alike.
    foreach ($token in $tokens) {
        if ($token.StartsWith('-')) { continue }
        $extension = ''
        try { $extension = [System.IO.Path]::GetExtension($token) } catch { continue }
        if ([string]::IsNullOrWhiteSpace($extension)) { continue }
        if ($script:DiscoveryTargetExtensions -notcontains $extension.ToLowerInvariant()) { continue }
        $candidate = Get-CanonicalPathOrEmpty $token
        if ($candidate -ne '') {
            $result.Parsed = $true
            $result.Target = $candidate
            return $result
        }
    }

    $result.Reason = 'no script or executable target could be identified'
    return $result
}

# Every command-bearing field on one handler, with its FIELD NAME kept.
#
# Distinct from _installplan.ps1's Get-HandlerCommandValues, which returns bare
# values for ownership matching. Discovery has to report WHICH spellings were
# present and whether they agree, so the names travel with the values.
function Get-DiscoveryCommandFields {
    param([Parameter(Mandatory = $true)]$Handler)
    $fields = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('command', 'commandWindows', 'command_windows')) {
        $property = $Handler.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        $value = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        [void]$fields.Add([pscustomobject]@{ Name = $name; Value = $value })
    }
    return $fields.ToArray()
}

# Do all present command fields point at the same target?
#
# Disagreement is a first-class finding, not an error: it is precisely the shape
# that makes automatic removal unsafe, because deleting the registration would
# also silence whatever the other field pointed at.
function Get-HandlerTargetAgreement {
    param([Parameter(Mandatory = $true)]$Handler)

    $result = [pscustomobject]@{
        FieldNames    = @()
        ParsedTargets = @()
        AllAgree      = $false
        AnyParsed     = $false
        Reason        = ''
    }
    $fields = @(Get-DiscoveryCommandFields -Handler $Handler)
    if ($fields.Count -eq 0) {
        $result.Reason = 'handler carries no command field'
        return $result
    }
    $result.FieldNames = @($fields | ForEach-Object { $_.Name })

    $targets = New-Object System.Collections.Generic.List[string]
    $unparsed = 0
    foreach ($field in $fields) {
        $info = Get-CommandTargetInfo -Command $field.Value
        if ($info.Parsed) { [void]$targets.Add($info.Target) } else { $unparsed++ }
    }
    $distinct = @($targets.ToArray() | Sort-Object -Unique)
    $result.ParsedTargets = $distinct
    $result.AnyParsed = ($targets.Count -gt 0)

    if ($targets.Count -eq 0) {
        $result.Reason = 'no command field could be parsed to a target'
        return $result
    }
    if ($unparsed -gt 0) {
        $result.Reason = 'some command fields could not be parsed'
        return $result
    }
    # Case-insensitive because these are Windows paths; Sort-Object -Unique above
    # is case-sensitive, so compare on the canonical key instead.
    $distinctKeys = @($targets.ToArray() | ForEach-Object { Get-CanonicalPathKey $_ } | Sort-Object -Unique)
    if ($distinctKeys.Count -gt 1) {
        $result.Reason = 'command fields disagree on the target'
        return $result
    }
    $result.AllAgree = $true
    return $result
}
