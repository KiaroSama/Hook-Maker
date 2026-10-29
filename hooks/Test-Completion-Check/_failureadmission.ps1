# Delivery reservations never retire a failure or provide successful evidence.
function Get-FailedReceiptDeliveryClaim {
    param($HookInput, $Doc, [string]$Path, [string[]]$EvidencePaths)
    try {
        $identity = Get-DeliveryIdentity $HookInput
        $exitCode = 0
        if ($identity -eq '' -or (Get-Field $Doc 'schema') -ne 2 -or
            [string](Get-Field $Doc 'overall') -cne 'failed' -or
            -not [int]::TryParse([string](Get-Field $Doc 'exitCode'), [ref]$exitCode) -or $exitCode -eq 0 -or
            (Get-Field $Doc 'terminated') -ne $false -or
            $null -eq $Doc.PSObject.Properties['leakedProcessIds'] -or
            $Doc.leakedProcessIds -isnot [array] -or $Doc.leakedProcessIds.Count -ne 0 -or
            -not [string]::Equals((Normalize-Path $Doc.workingDirectory), (Normalize-Path $HookInput.cwd), [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $unique = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($evidencePath in $EvidencePaths) {
            [void]$unique.Add((Normalize-Path $evidencePath))
            if ($unique.Count -gt 1024) { return $null }
        }
        $paths = @($unique)
        [Array]::Sort($paths, [StringComparer]::OrdinalIgnoreCase)
        if ($paths.Count -eq 0 -or $paths.Count -gt 1024 -or $paths -notcontains $Path) { return $null }
        $pins = New-Object 'Collections.Generic.List[string]'
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $totalBytes = 0L
        foreach ($entry in $paths) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item.Length -gt 1048576 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
            $totalBytes += $item.Length
            if ($totalBytes -gt 16777216) { return $null }
            # Bound allocation even if a producer grows the file after stat.
            $stream = [IO.File]::Open($item.FullName, 'Open', 'Read', 'Read')
            try {
                if ($stream.Length -ne $item.Length) { return $null }
                $bytes = New-Object byte[] ([int]$stream.Length)
                $read = 0
                while ($read -lt $bytes.Length) {
                    $n = $stream.Read($bytes, $read, $bytes.Length - $read)
                    if ($n -eq 0) { return $null }
                    $read += $n
                }
            } finally { $stream.Dispose() }
            $parsed = $utf8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -isnot [pscustomobject]) { return $null }
            if ($entry -eq $Path -and ($parsed | ConvertTo-Json -Depth 50 -Compress) -cne ($Doc | ConvertTo-Json -Depth 50 -Compress)) { return $null }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            [void]$pins.Add((Normalize-Path $item.FullName).ToLowerInvariant() + '|' + $hash)
        }
        $snapshot = Get-DeliveryHash ($pins.ToArray() -join "`n")
        $root = Normalize-Path $HookInput.cwd
        $key = Get-DeliveryHash $root.ToLowerInvariant()
        $reservation = Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker/state') ('FailedReceiptDelivery-' + $key + '.json')
        # Snapshot is part of the actor key: A/B/A must not forget A.
        return Invoke-DeliveryClaim -Path $reservation -Identity ($identity + '|' + $snapshot) -Fingerprint $snapshot
    }
    catch { return $null }
}
