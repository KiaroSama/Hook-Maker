# Validate from the configured project root, not from a potentially linked memory directory.
function Test-SyncPathChain {
    param([string]$Root, [string]$Path, [switch]$Leaf, [switch]$AllowMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $rootPath = [IO.Path]::GetFullPath($Root)
        $volume = [IO.Path]::GetPathRoot($fullPath)
        $rootVolume = [IO.Path]::GetPathRoot($rootPath)
    }
    catch { return $false }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($volume.TrimEnd('\', '/'), $rootVolume.TrimEnd('\', '/'))) { return $false }
    $pathTail = $fullPath.Substring($volume.Length).TrimEnd('\', '/')
    $rootTail = $rootPath.Substring($rootVolume.Length).TrimEnd('\', '/')
    $fullPath = $fullPath.TrimEnd('\', '/')
    $rootPath = $rootPath.TrimEnd('\', '/')
    # A case-sensitive NTFS directory can contain siblings that differ only in case.
    if ($rootTail -ne '' -and -not [StringComparer]::Ordinal.Equals($pathTail, $rootTail) -and
        -not $pathTail.StartsWith($rootTail + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) { return $false }
    $segments = @($volume)
    $cursor = $volume.TrimEnd('\', '/')
    foreach ($name in ($pathTail -split '[\\/]')) {
        if ($name -eq '') { continue }
        $cursor += [IO.Path]::DirectorySeparatorChar + $name
        $segments += $cursor
    }
    foreach ($segment in $segments) {
        $expectDirectory = -not ($Leaf -and [StringComparer]::Ordinal.Equals($segment, $fullPath))
        try {
            $attributes = [IO.File]::GetAttributes($segment)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or
                (([bool]($attributes -band [IO.FileAttributes]::Directory)) -ne $expectDirectory)) { return $false }
        }
        catch [IO.FileNotFoundException] { if (-not $AllowMissing -or $segment.Length -le $rootPath.Length) { return $false } }
        catch [IO.DirectoryNotFoundException] { if (-not $AllowMissing -or $segment.Length -le $rootPath.Length) { return $false } }
        catch { return $false }
    }
    return $true
}

function Test-SyncRegularLeaf {
    param([string]$Path)
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        if ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) { return $false }
        Initialize-SyncNoteHandle
        $stream = [IO.File]::OpenRead($Path)
        try { return [HookMaker.SyncNoteHandle]::IsExpectedFile($stream.SafeFileHandle, [IO.Path]::GetFullPath($Path)) }
        finally { $stream.Dispose() }
    }
    catch [IO.FileNotFoundException] { return $true }
    catch [IO.DirectoryNotFoundException] { return $true }
    catch { return $false }
}

function Test-SyncStatePath {
    param($Context, [string]$Path)
    $stamp = Get-ScanStampPath -StatePath $Path
    return ((Test-SyncPathChain -Root $Context.destinationRoot -Path $Path -Leaf -AllowMissing) -and
        (Test-SyncPathChain -Root $Context.destinationRoot -Path $stamp -Leaf -AllowMissing) -and
        (Test-SyncRegularLeaf $stamp))
}

function Get-EligibleFiles {
    param($Context)

    $source = [IO.Path]::GetFullPath($Context.sourceDirectory).TrimEnd('\', '/')
    if (-not (Test-SyncPathChain -Root $Context.sourceRoot -Path $source)) { throw 'Unsafe sync source directory.' }
    $extensions = @(Get-PropertyValue -Primary $Context.route -Secondary $Context.profile -Tertiary $Context.defaults -Name 'includeExtensions' -Fallback @())
    $excludePatterns = @(Get-PropertyValue -Primary $Context.route -Secondary $Context.profile -Tertiary $Context.defaults -Name 'excludePatterns' -Fallback @())
    $maxFileBytes = [int64](Get-PropertyValue -Primary $Context.route -Secondary $Context.profile -Tertiary $Context.defaults -Name 'maxFileBytes' -Fallback 2097152L)
    $privateDirs = '^(?:\..+|logs?|raw[-_ ]?logs?|archive|artifacts?|cache|graph|graphify-out|indexes|node_modules|temp|tmp|research|targets|scans?|(?:private|secrets?|credentials?|tokens?)(?:[-_. ].*)?)$'
    $privateFiles = '^(?:\..+|explain-ai\.md|(?:attack_surface|scope|security_notes|reporting)\.md|(?:logs?|raw[-_ ]?logs?|secrets?|credentials?|tokens?|private|transcripts?|scans?)(?:[-_. ].*)?\.md)$|\.(?:log|tmp|bak)\.md$'
    $sourceParts = $source -split '[\\/]'
    $protectedAncestors = '^(?:\.cross-project-sync|\.ignoreme|\.git|\.claude|\.codex|\.agents|\.specify|\.kiro|\.cursor|\.cline|\.codebase-memory|\.venv|logs?|raw[-_ ]?logs?|archive|artifacts?|cache|graph|graphify-out|indexes|node_modules|research|targets|scans?|(?:private|secrets?|credentials?|tokens?)(?:[-_. ].*)?)$'
    if ($sourceParts -match $protectedAncestors) { throw 'Unsafe sync source directory.' }
    $root = [IO.Path]::GetFullPath($Context.sourceRoot).TrimEnd('\', '/')
    $sourceParts = $source.Substring($root.Length).TrimStart('\', '/') -split '[\\/]'
    if (@($sourceParts | Where-Object { $_ -ine '.ai' -and $_ -match $privateDirs }).Count -gt 0) { throw 'Unsafe sync source directory.' }
    $result = New-Object System.Collections.Generic.List[object]
    $directories = New-Object 'System.Collections.Generic.Stack[string]'
    $directories.Push($source)
    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        if (-not (Test-SyncPathChain -Root $Context.sourceRoot -Path $directory)) { throw 'Unsafe sync source directory.' }
        foreach ($item in (Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.FullName -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}`]') { continue }
            $relative = $item.FullName.Substring($source.Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) {
                if ($item.Name -notmatch $privateDirs -and -not (Test-WildcardMatch -Value ($relative + '/') -Patterns $excludePatterns)) {
                    $directories.Push($item.FullName)
                }
                continue
            }
            if ($item.Extension -ine '.md' -or ($extensions.Count -gt 0 -and '.md' -notin $extensions) -or
                $item.Name -match $privateFiles -or $item.Length -gt $maxFileBytes -or
                (Test-WildcardMatch -Value $relative -Patterns $excludePatterns)) { continue }
            [void]$result.Add([pscustomobject]@{
                Path = $relative
                FullPath = $item.FullName
                SourceRoot = $Context.sourceRoot
                Length = [int64]$item.Length
                LastWriteTicks = [int64]$item.LastWriteTimeUtc.Ticks
            })
        }
    }
    $byPath = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($record in $result) { $byPath.Add($record.Path, $record) }
    return $byPath.Values
}

function Initialize-SyncNoteHandle {
    if ('HookMaker.SyncNoteHandle' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace HookMaker {
    public static class SyncNoteHandle {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo {
            internal uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);

        public static bool IsExpectedFile(SafeFileHandle handle, string expected) {
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info) || info.Links != 1 || (info.Attributes & 0x410) != 0)
                return false;
            var path = new StringBuilder(512);
            uint count = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
            if (count >= path.Capacity && count < 32768) {
                path.EnsureCapacity((int)count + 1);
                count = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
            }
            if (count == 0 || count >= path.Capacity) return false;
            string actual = path.ToString();
            if (actual.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) actual = @"\\" + actual.Substring(8);
            else if (actual.StartsWith(@"\\?\", StringComparison.Ordinal)) actual = actual.Substring(4);
            return String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);
        }
    }
}
'@
}
