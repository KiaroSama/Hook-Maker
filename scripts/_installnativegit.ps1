# The NATIVE GIT pre-push chain, split out of Install-Hook.ps1 (which had grown
# past the file-size review threshold) as a PURE relocation - the body below is
# byte-identical to what lived there.
#
# Scope: the one hook that also manages a real .git/hooks/pre-push wrapper
# (Ignore-Rules-Check). It stages the managed runtime plus its chain companions
# through the SAME canonical plan every other runtime uses, preserves any
# pre-existing user hook as opaque bytes, regenerates only the owned wrapper,
# and records what the chain manages so the updater can detect companion drift.
#
# Dot-sourced by Install-Hook.ps1 only, and it RELIES ON THAT SCRIPT'S SCOPE
# exactly as _installruntime.ps1 and _installclientsettings.ps1 do: it reads
# $FriendlyName, $TargetProject, $projectRoot, $ToolRoot, $HookScript,
# $SourceDir, $Profile and $Utf8NoBom, and it assigns $script:NativeGitState.
# Nothing here is callable on its own.

function Install-IgnorePrePush {
    if ($FriendlyName -ne 'Ignore-Rules-Check' -or [string]::IsNullOrWhiteSpace($TargetProject)) { return }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return }
    # ONLY the repository's own top level may own its pre-push hook.
    #
    # `rev-parse --git-path hooks` answers for the ENCLOSING repository, so a
    # target that is merely a subdirectory resolves to its parent repo's real
    # .git\hooks - and that record then owns, regenerates and (on uninstall)
    # DELETES a pre-push hook belonging to a repository it is not the root of.
    # Observed for real: fixture projects created under this repo's own state\
    # directory took ownership of this repository's pre-push chain, and removing
    # those records removed it.
    #
    # Skipping is the whole fix: every other client still installs, and this
    # function already returns early when git is absent or rev-parse fails, so a
    # chain-less install is an established, supported outcome.
    $topLevel = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $projectRoot, 'rev-parse', '--show-toplevel'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($topLevel)) { return }
    if ((Normalize-Path ($topLevel.Trim() -replace '/', '\')).ToLowerInvariant() -cne
        (Normalize-Path $projectRoot).ToLowerInvariant()) {
        return
    }
    $hooksPath = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $projectRoot, 'rev-parse', '--git-path', 'hooks'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hooksPath)) { return }
    if (-not [System.IO.Path]::IsPathRooted($hooksPath)) { $hooksPath = Join-Path $projectRoot $hooksPath }
    $hooksPath = [System.IO.Path]::GetFullPath($hooksPath)

    $runtimeRoot = Join-Path $hooksPath 'Hook-Maker'
    $runtime = Copy-HookRuntime -ClientDir $hooksPath -RuntimeRootOverride $runtimeRoot
    $oldWrongRoot = Join-Path (Split-Path -Parent $hooksPath) 'hooks\Hook-Maker'
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($oldWrongRoot), [System.IO.Path]::GetFullPath($runtimeRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($name in @('Ignore-Rules-Check', 'Secrets-Check', 'Large-File-Check')) {
            $stale = Join-Path $oldWrongRoot $name
            if (Test-Path -LiteralPath $stale -PathType Container) { Remove-Item -LiteralPath $stale -Recurse -Force }
        }
        if ((Test-Path -LiteralPath $oldWrongRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $oldWrongRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $oldWrongRoot -Force
        }
    }
    # Native companions go through the SAME canonical plan and transactional
    # staging as any other managed runtime, so they get a private _hooklib.ps1
    # and the matching dot-source rewrite. Copying just the script by hand left
    # the companion with no library to load once the shared root copy was
    # retired, which broke the real pre-push chain.
    function Copy-PrePushCompanion {
        param([Parameter(Mandatory = $true)][string]$Name)
        $sourceScript = Join-Path $ToolRoot ('hooks\' + $Name + '\' + $Name + '.ps1')
        if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) { throw "Pre-push check not found: $sourceScript" }
        $destinationDir = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $Name))
        if (-not (Test-PathContainedIn -ChildPath $destinationDir -ParentPath $runtimeRoot)) {
            throw "Unsafe pre-push runtime path: $destinationDir"
        }
        $companionPlan = Get-InstallPlanFor -HookScript $sourceScript -ToolRoot $ToolRoot -FriendlyNameOverride $Name
        Install-PlannedRuntime -Plan $companionPlan -RuntimeRoot $runtimeRoot -FriendlyName $Name | Out-Null
        return (Join-Path $destinationDir ($Name + '.ps1'))
    }
    # The canonical chain-companion list (30.md Part C): the ONE place the
    # managed stage set is decided. Everything downstream (expectedStages,
    # companions, sourceManifest, updater integrity, status, uninstall) derives
    # from the record this writes, so extending the chain is exactly this list.
    $chainCompanions = @('Secrets-Check', 'Utf8-Encoding-Check')
    $secretsScript = Copy-PrePushCompanion 'Secrets-Check'
    $utf8Script = Copy-PrePushCompanion 'Utf8-Encoding-Check'
    $staleLargeFileCheck = Join-Path $runtimeRoot 'Large-File-Check'
    if (Test-Path -LiteralPath $staleLargeFileCheck) {
        Remove-Item -LiteralPath $staleLargeFileCheck -Recurse -Force
    }
    $prePush = Join-Path $hooksPath 'pre-push'
    $previous = $prePush + '.hookmaker-existing'
    $marker = $script:PrePushMarker
    if (Test-Path -LiteralPath $prePush -PathType Leaf) {
        $current = [System.IO.File]::ReadAllText($prePush)
        if (-not $current.Contains($marker)) {
            if (Test-Path -LiteralPath $previous) { throw "Cannot preserve the existing pre-push hook because '$previous' already exists." }
            # Move, never copy-and-rewrite: the user's hook is preserved as
            # opaque BYTES (it may be binary, or have no trailing newline).
            Move-Item -LiteralPath $prePush -Destination $previous
        }
    }
    # "Did a user hook ever exist here?" is STICKY. If we recorded one before
    # and the file has since vanished, we must not silently rewrite history to
    # previousHookPreserved=false - that would erase the fact that a user hook
    # is expected and let a rebuilt wrapper quietly drop the stage. It becomes
    # an unresolved state the updater reports for manual attention instead.
    $previousExistsNow = Test-Path -LiteralPath $previous -PathType Leaf
    $previousEverPreserved = $previousExistsNow
    $previousMissing = $false
    try {
        $existingRecord = Get-InstallRecordById -ToolRoot $ToolRoot -Id (Get-InstallRecordId -FriendlyName $FriendlyName -ScopeKey ($projectRoot.ToLowerInvariant()) -ProfileId ([string]$Profile))
        if ($null -ne $existingRecord -and
            $null -ne $existingRecord.PSObject.Properties['nativeGit'] -and $null -ne $existingRecord.nativeGit -and
            $null -ne $existingRecord.nativeGit.PSObject.Properties['previousHookPreserved'] -and
            $existingRecord.nativeGit.previousHookPreserved -eq $true) {
            $previousEverPreserved = $true
            $previousMissing = (-not $previousExistsNow)
        }
    }
    catch { }

    # ONE canonical generator (see New-PrePushWrapperBody) produces these bytes,
    # and the updater's integrity check rebuilds them with the same function to
    # compare exactly - so the wrapper's stdin buffering, stage order,
    # fail-closed `|| exit $?`, cleanup trap and previous-hook invocation can
    # never drift apart from what we verify.
    # Chain order is the canonical contract: Ignore -> Secrets -> Utf8 ->
    # preserved previous user hook (30.md Part C).
    $managedStages = @($runtime.Script, $secretsScript, $utf8Script)
    $body = New-PrePushWrapperBody -ManagedScripts $managedStages
    [System.IO.File]::WriteAllText($prePush, $body, $Utf8NoBom)
    Write-Host "Native git pre-push protection installed in: $prePush"

    # Record what this chain manages so the updater can detect a stale managed
    # companion (e.g. a changed Secrets-Check source) as drift of THIS logical
    # installation. The preserved previous hook is tracked by path/existence
    # only - it is user-owned and is never hashed or rewritten.
    $script:NativeGitState = [pscustomobject][ordered]@{
        managed               = $true
        hooksPath             = $hooksPath
        runtimeRoot           = $runtimeRoot
        wrapperPath           = $prePush
        previousHookPath      = $previous
        # Sticky: once true, stays true. previousHookMissing records that the
        # user's preserved hook has since disappeared, so the updater surfaces
        # it for manual attention instead of quietly forgetting it ever existed.
        previousHookPreserved = $previousEverPreserved
        previousHookMissing   = $previousMissing
        expectedStages        = @($managedStages)
        wrapperBodyHash       = (Get-ShortHash $body)
        companions            = @($chainCompanions)
        sourceManifest        = @(Get-NativePrePushSourceManifest -ToolRoot $ToolRoot -PrimaryFriendlyName $FriendlyName -PrimaryHookScript $HookScript -PrimarySourceDir $SourceDir -Companions $chainCompanions)
    }
}
