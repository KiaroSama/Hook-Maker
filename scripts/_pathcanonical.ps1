# Link-aware project path identity (spec 039).
#
# [IO.Path]::GetFullPath only normalises TEXT; it never follows a symbolic link
# or junction. Install-Hook used it alone, so a project opened through a link
# (`...\Portable\Scripts\Numera Browser` -> `G:\Program Files\Numera Browser`)
# became a SECOND registry root for the same physical folder: two records for
# one hook, two handler sets in one settings file, and a fleet compare that
# reported the pair as different forever. Every place that decides "is this the
# same project folder" goes through Resolve-RealDirectoryPath instead.
#
# FileSystemInfo.ResolveLinkTarget would do this in one call, but it is .NET 6+
# and Windows PowerShell 5.1 (Claude's hook host) has no such method, so the
# walk below uses Get-Item's LinkType/Target, which both hosts expose.
#
# Needs nothing else loaded. Never throws.

$script:PathCanonicalMaxHops = 63

function Resolve-RealDirectoryPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $text = $Path
    try { $text = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)) }
    catch { return $Path }
    $text = Get-TrimmedDirectoryPath $text
    # A failure anywhere below returns the plain normalised text: an unreadable
    # or broken link may only fail to MERGE two spellings, never merge the
    # wrong ones.
    try {
        $current = $text
        $hops = 0
        $restart = $true
        while ($restart) {
            $restart = $false
            $root = [System.IO.Path]::GetPathRoot($current)
            if ([string]::IsNullOrEmpty($root)) { return $text }
            $rest = $current.Substring($root.Length)
            $parts = @($rest.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries))
            $prefix = $root
            for ($i = 0; $i -lt $parts.Count; $i++) {
                $candidate = Join-Path $prefix $parts[$i]
                $target = Get-DirectoryLinkTarget $candidate
                if ($null -eq $target) {
                    # Not a link, or not on disk: the tail stays as text.
                    if (-not [System.IO.Directory]::Exists($candidate)) {
                        $prefix = $candidate
                        for ($j = $i + 1; $j -lt $parts.Count; $j++) { $prefix = Join-Path $prefix $parts[$j] }
                        break
                    }
                    $prefix = $candidate
                    continue
                }
                $hops++
                if ($hops -gt $script:PathCanonicalMaxHops) { return $text }
                if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $prefix $target }
                $next = [System.IO.Path]::GetFullPath($target)
                for ($j = $i + 1; $j -lt $parts.Count; $j++) { $next = Join-Path $next $parts[$j] }
                $current = Get-TrimmedDirectoryPath $next
                $restart = $true
                break
            }
            if (-not $restart) { return (Get-TrimmedDirectoryPath $prefix) }
        }
    }
    catch { return $text }
    return $text
}

# Target of a SymbolicLink/Junction directory, $null for anything else. On 5.1
# Target is a string[]; on 7 it is a string.
function Get-DirectoryLinkTarget {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return $null }
    $info = New-Object System.IO.DirectoryInfo $Path
    if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $null }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $linkType = [string]$item.LinkType
    if ($linkType -ne 'SymbolicLink' -and $linkType -ne 'Junction') { return $null }
    $target = @($item.Target | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) | Select-Object -First 1
    if ($null -eq $target) { return $null }
    # Junction targets can carry the \??\ NT prefix on some hosts.
    $value = ([string]$target) -replace '^\\\\\?\?\\', '' -replace '^\\\?\?\\', ''
    return $value
}

function Get-TrimmedDirectoryPath {
    param([string]$Path)
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ($Path.Length -le $root.Length) { return $Path }
    return $Path.TrimEnd([char[]]@('\', '/'))
}

# True when $Path is a different spelling that resolves to $RealPath.
function Test-PathIsAliasOf {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RealPath)
    $resolved = Resolve-RealDirectoryPath $Path
    if (-not [string]::Equals($resolved, (Get-TrimmedDirectoryPath $RealPath), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $plain = Get-TrimmedDirectoryPath ([System.IO.Path]::GetFullPath($Path))
    return -not [string]::Equals($plain, $resolved, [System.StringComparison]::OrdinalIgnoreCase)
}

# An alias record may be dropped from the registry WITHOUT the normal file
# removal only when it is proven superseded: its project root resolves to a
# different real folder, and a record at that real folder carries the same
# hook, profile and every client the alias record has. Its runtime folder IS
# the real record's folder (same physical directory), and a normal uninstall
# would refuse anyway, because the real record's handlers name the same hook
# and profile in the same physical settings file.
function Test-AliasRecordSuperseded {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Installs
    )
    $result = [pscustomobject]@{ Ok = $false; Reason = ''; RealRoot = ''; SupersededBy = '' }
    $root = ''
    if ($null -ne $Record.PSObject.Properties['targetProjectRoot']) { $root = [string]$Record.targetProjectRoot }
    if ($null -eq $Record.PSObject.Properties['scope'] -or [string]$Record.scope -ne 'project' -or [string]::IsNullOrWhiteSpace($root)) {
        $result.Reason = 'not a project-scope record'; return $result
    }
    if (-not [System.IO.Directory]::Exists($root)) { $result.Reason = 'project root is not on disk'; return $result }
    $real = Resolve-RealDirectoryPath $root
    if (-not (Test-PathIsAliasOf -Path $root -RealPath $real)) { $result.Reason = 'project root is not a link to another folder'; return $result }
    $result.RealRoot = $real
    $clients = @()
    if ($null -ne $Record.PSObject.Properties['clients'] -and $null -ne $Record.clients) { $clients = @($Record.clients.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($other in @($Installs)) {
        if ($null -eq $other -or $null -eq $other.PSObject.Properties['id'] -or [string]$other.id -ceq [string]$Record.id) { continue }
        if ($null -eq $other.PSObject.Properties['targetProjectRoot']) { continue }
        if (-not [string]::Equals((Get-TrimmedDirectoryPath ([string]$other.targetProjectRoot)), $real, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not [string]::Equals([string]$other.friendlyName, [string]$Record.friendlyName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([string]$other.profile -cne [string]$Record.profile) { continue }
        $otherClients = @()
        if ($null -ne $other.PSObject.Properties['clients'] -and $null -ne $other.clients) { $otherClients = @($other.clients.PSObject.Properties | ForEach-Object { $_.Name }) }
        if (@($clients | Where-Object { $otherClients -notcontains $_ }).Count -gt 0) { continue }
        $result.Ok = $true; $result.SupersededBy = [string]$other.id
        return $result
    }
    $result.Reason = 'no record at the real folder carries this hook, profile and every client yet'
    return $result
}
