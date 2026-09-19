# Dot-sourced scenario block of Test-InstallRegistrySchema.ps1: registry
# availability and path-safety primitives - a zero-byte/whitespace-only
# registry is corrupt (not missing), an orphan lock from a killed writer is
# reclaimed and released; Test-PathContainedIn handles drive/UNC roots,
# sibling-prefix attacks, traversal, separators and case; a planned artifact
# can never escape its staging directory.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions - later blocks also read fixtures defined by
# earlier blocks. Run scripts\Test-InstallRegistrySchema.ps1 instead.

    # =====================================================================

    Write-Host '--- registry availability: zero-byte file and orphan lock ---' -ForegroundColor Cyan

    $availRoot = Join-Path $Work 'availability-root'

    New-Item -ItemType Directory -Path (Join-Path $availRoot 'state') -Force | Out-Null

    $availRegistry = Join-Path $availRoot 'state\install-registry.json'

    $savedAvailStateDir = $env:HOOKMAKER_STATE_DIR

    $env:HOOKMAKER_STATE_DIR = ''

    try {

        Write-Utf8 $availRegistry '{"version":2,"installs":[{"id":"real-record","schema":2,"friendlyName":"Real"}]}'

        Check 'a healthy registry reads as ok' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'ok')

        [System.IO.File]::WriteAllText($availRegistry, '')

        Check 'a zero-byte registry is corrupt, not missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'corrupt')

        [System.IO.File]::WriteAllText($availRegistry, '    ')

        Check 'a whitespace-only registry is corrupt, not missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'corrupt')

        Remove-Item -LiteralPath $availRegistry -Force

        Check 'a genuinely absent registry is still reported missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'missing')

        $availLock = Join-Path $availRoot 'state\install-registry.lock'

        Write-Utf8 $availLock '{"pid":999999,"host":"machine-that-died"}'

        $reclaimed = $false

        $probeRecord = [pscustomobject][ordered]@{

            id = 'orphan-lock-probe'; schema = 2; friendlyName = 'OrphanProbe'; hookType = 'CustomHook'

            sourceScript = ''; sourceDir = ''; scope = 'project'; targetProjectRoot = ''

            profile = ''; configPath = ''; sourceManifest = @(); clients = [pscustomobject]@{}; nativeGit = $null

            lastResult = 'ok'; lastReason = 'probe'; lastError = ''

        }

        try { Update-InstallRegistry -ToolRoot $availRoot -Record $probeRecord | Out-Null; $reclaimed = $true } catch { }

        Check 'an orphan lock from a killed writer is reclaimed, not fatal forever' $reclaimed

        $released = $false; $lockProbe = $null
        try {
            $lockProbe = [IO.File]::Open($availLock, 'Open', 'ReadWrite', 'None')
            $released = $true
        }
        catch { $released = $false }
        finally { if ($null -ne $lockProbe) { $lockProbe.Dispose() } }
        Check 'a completed registry write leaves the stable lock available for the next writer' $released

    }

    finally { $env:HOOKMAKER_STATE_DIR = $savedAvailStateDir }



    # =====================================================================

    # Filesystem roots and physical boundaries. Lexical containment must never

    # turn a root into a non-root ('C:\' -> 'C:'), and a sibling whose name

    # merely starts with the parent's name is not inside it.

    Write-Host '--- path roots, sibling-prefix attacks and traversal ---' -ForegroundColor Cyan

    Check 'a drive root contains its children' (Test-PathContainedIn -ChildPath 'C:\Windows\System32' -ParentPath 'C:\')

    Check 'a drive root is contained in itself' (Test-PathContainedIn -ChildPath 'C:\' -ParentPath 'C:\')

    Check 'a UNC share root contains its children' (Test-PathContainedIn -ChildPath '\\server\share\dir\file.txt' -ParentPath '\\server\share')

    Check 'a sibling-prefix directory is NOT contained' (-not (Test-PathContainedIn -ChildPath 'C:\Hook-Maker-Evil\x.ps1' -ParentPath 'C:\Hook-Maker'))

    Check 'an exact-name directory IS contained' (Test-PathContainedIn -ChildPath 'C:\Hook-Maker\x.ps1' -ParentPath 'C:\Hook-Maker')

    Check 'a parent-relative traversal escapes containment' (-not (Test-PathContainedIn -ChildPath 'C:\Hook-Maker\..\Other\x.ps1' -ParentPath 'C:\Hook-Maker'))

    Check 'a nested traversal that stays inside is contained' (Test-PathContainedIn -ChildPath 'C:\Hook-Maker\sub\..\x.ps1' -ParentPath 'C:\Hook-Maker')

    Check 'alternate separators are normalized' (Test-PathContainedIn -ChildPath 'C:/Hook-Maker/sub/x.ps1' -ParentPath 'C:\Hook-Maker')

    Check 'Windows path comparison is case-insensitive' (Test-PathContainedIn -ChildPath 'C:\HOOK-MAKER\x.ps1' -ParentPath 'C:\hook-maker')

    Check 'an unrelated drive is never contained' (-not (Test-PathContainedIn -ChildPath 'D:\Hook-Maker\x.ps1' -ParentPath 'C:\Hook-Maker'))

    Check 'empty paths are never contained' ((-not (Test-PathContainedIn -ChildPath '' -ParentPath 'C:\X')) -and (-not (Test-PathContainedIn -ChildPath 'C:\X' -ParentPath '')))

    # A planned artifact must never be able to escape its staging directory.

    $escapePlan = @(New-PlanArtifact -RelativePath '../escaped.ps1' -Kind 'Generated' -GeneratedContent 'x')

    $escapeRoot = Join-Path $Work 'escape-root'

    New-Item -ItemType Directory -Path $escapeRoot -Force | Out-Null

    $escapeThrew = $false

    try { Install-PlannedRuntime -Plan $escapePlan -RuntimeRoot $escapeRoot -FriendlyName 'Escape-Test' | Out-Null } catch { $escapeThrew = $true }

    Check 'a planned artifact that escapes staging is rejected' $escapeThrew

    Check 'the escape attempt wrote nothing outside the runtime root' (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $escapeRoot) 'escaped.ps1')))
