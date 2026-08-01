function Check {
    param([string]$Name, [bool]$Condition, [string]$Actual = $null)
    if ($Condition) {
        $script:Pass++
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($env:HOOKMAKER_TEST_DEBUG -eq '1' -and $null -ne $Actual) {
            $preview = $Actual
            if ($preview.Length -gt $script:TestPreviewLength) {
                $preview = $preview.Substring(0, $script:TestPreviewLength)
            }
            Write-Host ('       actual: [' + $preview + ']') -ForegroundColor DarkGray
        }
    }
}

# Creates a suite's throwaway workspace. This is the line 37 suites each inlined
# - Join-Path (GetTempPath) (<prefix> + '-' + <8 hex chars>) - written once, plus
# one escape hatch.
#
# HOOKMAKER_TEST_TEMP_ROOT exists because a full-matrix run twice had a LIVE
# workspace deleted underneath it by something outside this repo (no code here
# sweeps %TEMP%; Storage Sense, a scanner and the harness are all still suspects)
# and the suite then crashed at its own file writer. Relocating the workspaces
# turns "is the deleter %TEMP%-specific?" into an experiment instead of a guess.
#
# It is a DIAGNOSTIC switch, never a new default: unset or blank keeps the old
# %TEMP% behaviour byte-for-byte. An unusable value - a path that cannot be
# created, a permission denial, garbage - falls back to %TEMP% rather than
# throwing, because a suite failing over a diagnostic setting would be a worse
# bug than the one it was set to diagnose. The returned path is always a
# directory that exists.
function New-TestWorkspace {
    param([Parameter(Mandatory)][string]$Prefix)

    $root = ''
    $configured = [string]$env:HOOKMAKER_TEST_TEMP_ROOT
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        try {
            $candidate = [System.IO.Path]::GetFullPath($configured)
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
                New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
            }
            # Trust the filesystem, not the absence of an exception: New-Item
            # -Force is a SILENT no-op for some unusable targets (a path under a
            # FILE returns nothing and throws nothing), which would otherwise hand
            # back a workspace that does not exist - the very crash this helper is
            # meant to be diagnosing.
            if (Test-Path -LiteralPath $candidate -PathType Container) { $root = $candidate }
        }
        catch { $root = '' }
    }
    if ($root -eq '') { $root = [System.IO.Path]::GetTempPath() }

    $path = Join-Path $root ($Prefix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

# Removes a suite's throwaway workspace and PROVES it is gone. A child hook
# process, a git invocation, or an antivirus scan of the freshly written .git
# tree can still hold a handle for a beat after the suite's work finishes; a
# plain `Remove-Item -ErrorAction SilentlyContinue` then fails and the suite
# exits 0 with the tree still on disk (see the leaked hookmaker-* dirs this was
# written to stop). So: retry with a short backoff - the handle almost always
# releases within a second or two - verify after each attempt, and if the tree
# still will not go, say so LOUDLY and return $false so the caller can fail the
# suite instead of leaking silently. Every operation is scoped strictly to the
# given path(s); there is no broad or recursive delete of anything else.
#
# Deliberately does NOT hunt down and kill git/pwsh children: that risks killing
# an unrelated process and cannot be scoped to $Work. GC + WaitForPendingFinalizers
# releases any handle THIS process still holds (an undisposed child Process object,
# a FileStream), and the backoff covers an external holder releasing its lock.
function Remove-TestWorkspace {
    param([Parameter(Mandatory)][string[]]$Path)

    $allGone = $true
    foreach ($target in $Path) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        if (-not (Test-Path -LiteralPath $target)) { continue }

        $removed = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { } }
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            }
            catch { }
            if (-not (Test-Path -LiteralPath $target)) { $removed = $true; break }
            if ($attempt -lt 10) {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                Start-Sleep -Milliseconds ($attempt * 150)
            }
        }

        if (-not $removed) {
            $allGone = $false
            Write-Host ''
            Write-Host ('LEAKED WORKSPACE: could not remove ' + $target +
                ' after 10 attempts - a handle is still open (stray git/pwsh child or AV lock). Left on disk for inspection.') -ForegroundColor Red
        }
    }
    return $allGone
}
