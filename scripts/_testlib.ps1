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
