param([string]$ResultPath = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'scripts\_testlib.ps1')
$work = New-TestWorkspace -Prefix 'hookmaker-publication'
$utf8 = New-Object Text.UTF8Encoding($false)
$cases = New-Object 'System.Collections.Generic.List[object]'
function Check-Package {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    [void]$cases.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    $level = if ($Passed) { 'INFO' } else { 'ERROR' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' ' + $Detail)
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    . (Join-Path $repo 'hooks\_hooklib.ps1')
    $engineDir = Join-Path $repo 'hooks\Cross-Project-.ai-Knowledge-Sync'
    . (Join-Path $engineDir '_packageguard.ps1')
    . (Join-Path $engineDir '_packagebuild.ps1')
    # Import the real pure mapping function from the checked-out production AST.
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $engineDir 'Cross-Project-.ai-Knowledge-Sync.ps1'), [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Engine source does not parse.' }
    $function = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Convert-FileRecordsToMap' }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    # Only the human-facing command renderer is irrelevant to byte integrity.
    function Get-AcknowledgementCommand { param($Context, $Fingerprint) return ('ACK ' + $Fingerprint) }
    $source = Join-Path $work 'source'; $destination = Join-Path $work 'destination'
    [void][IO.Directory]::CreateDirectory($source); [void][IO.Directory]::CreateDirectory($destination)
    $context = [pscustomobject]@{
        profileId = 'p'; routeId = 'r'; profile = [pscustomobject]@{ name = 'P' }
        route = [pscustomobject]@{ source = [pscustomobject]@{}; destination = [pscustomobject]@{} }
        sourceRoot = $source; sourceDirectory = $source; destinationRoot = $destination; destinationDirectory = $destination
    }
    $paths = [pscustomobject]@{ inboxRoot = (Join-Path $destination 'inbox\route'); statePath = (Join-Path $destination 'state.json') }
    $state = [pscustomobject]@{ lastAppliedFiles = @(); pending = $null; lastNotifiedSessionId = ''; lastNotifiedAtUtc = '' }
    $sourceFile = Join-Path $source 'lesson.md'
    [IO.File]::WriteAllText($sourceFile, 'version one', $utf8)
    $snapshot = [pscustomobject]@{ fingerprint = ('a' * 64); files = @([pscustomobject]@{ path = 'lesson.md'; sha256 = (Get-PackageFileDigest $sourceFile) }) }
    $first = New-PendingPackage -Context $context -State $state -StatePaths $paths -QuickFingerprint 'q1' -ContentSnapshot $snapshot
    Check-Package 'a real single-file package passes proof validation' (Test-PendingPackageIntact $first $context $paths)
    $state = Publish-PendingPackage -Context $context -State $state -StatePaths $paths -Pending $first -SessionId 'session'
    Check-Package 'a persisted package retains its array shape and validates after JSON decoding' (Test-PendingPackageIntact (Read-JsonFile $paths.statePath).pending $context $paths)
    $staged = Join-Path $first.filesRoot 'lesson.md'
    [IO.File]::WriteAllText($staged, 'tampered', $utf8)
    Check-Package 'tampering with staged bytes is rejected' (-not (Test-PendingPackageIntact $first $context $paths))
    [IO.File]::WriteAllText($staged, 'version one', $utf8)
    Check-Package 'restoring exactly reviewed bytes restores validity' (Test-PendingPackageIntact $first $context $paths)
    $extra = Join-Path $first.filesRoot 'unreviewed.md'
    [IO.File]::WriteAllText($extra, 'unreviewed', $utf8)
    Check-Package 'an extra unreviewed file invalidates the exact package set' (-not (Test-PendingPackageIntact $first $context $paths))
    [IO.File]::Delete($extra)
    $manifest = [IO.File]::ReadAllText($first.manifestPath)
    [IO.File]::AppendAllText($first.manifestPath, ' ', $utf8)
    Check-Package 'manifest bytes are pinned independently of their declared fingerprint' (-not (Test-PendingPackageIntact $first $context $paths))
    [IO.File]::WriteAllText($first.manifestPath, $manifest, $utf8)
    [IO.File]::WriteAllText($sourceFile, 'version two', $utf8)
    $snapshot.fingerprint = 'b' * 64
    $snapshot.files = @([pscustomobject]@{ path = 'lesson.md'; sha256 = (Get-PackageFileDigest $sourceFile) })
    $second = New-PendingPackage -Context $context -State $state -StatePaths $paths -QuickFingerprint 'q2' -ContentSnapshot $snapshot
    Check-Package 'building a replacement does not retire the published generation' ([IO.Directory]::Exists($first.packageRoot) -and (Test-PendingPackageIntact $second $context $paths))
    $before = [IO.File]::ReadAllText($paths.statePath)
    $handle = [IO.File]::Open($paths.statePath, 'Open', 'Read', 'None')
    $failed = $false
    try { $null = Publish-PendingPackage -Context $context -State $state -StatePaths $paths -Pending $second -SessionId 'session' }
    catch { $failed = $true }
    finally { $handle.Dispose() }
    Check-Package 'a real file-sharing publication failure is propagated' $failed
    Check-Package 'failed publication preserves the old pointer byte-for-byte' ([IO.File]::ReadAllText($paths.statePath) -ceq $before)
    Check-Package 'failed publication preserves the old reviewed generation' (Test-PendingPackageIntact $first $context $paths)
    $state = Publish-PendingPackage -Context $context -State $state -StatePaths $paths -Pending $second -SessionId 'session'
    Check-Package 'successful publication points to the verified replacement' ((Read-JsonFile $paths.statePath).pending.packageRoot -ceq $second.packageRoot)
    Check-Package 'only post-commit cleanup retires the old generation' (-not [IO.Directory]::Exists($first.packageRoot))
    $empty = New-PendingPackage -Context $context -State $state -StatePaths $paths -QuickFingerprint 'empty' -ContentSnapshot ([pscustomobject]@{ fingerprint = ('c' * 64); files = @() })
    Check-Package 'an empty or deletion-only generation remains a valid review package' (Test-PendingPackageIntact $empty $context $paths)
    Check-Package 'duplicate builds never overwrite an immutable generation in place' ($first.packageRoot -cne $second.packageRoot -and $second.packageRoot -cne $empty.packageRoot)
    $link = Join-Path $second.filesRoot 'linked'
    $outside = Join-Path $work 'outside'; [void][IO.Directory]::CreateDirectory($outside)
    [IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'), 'preserve', $utf8)
    $null = New-Item -ItemType Junction -Path $link -Target $outside
    Check-Package 'an internal junction invalidates the reviewed tree' (-not (Test-PendingPackageIntact $second $context $paths))
    Check-Package 'retirement refuses a tree containing an internal junction' (
        -not (Remove-OwnedPackageDirectory -Path $second.packageRoot -OwnedRoot $paths.inboxRoot -TrustedRoot $destination))
    Check-Package 'a refused retirement preserves both the package and its external target' (
        [IO.File]::Exists($second.manifestPath) -and [IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -ceq 'preserve')
    # Delete only the test-owned link, not recursively through its target.
    [IO.Directory]::Delete($link)
    Check-Package 'the external junction target is not modified by verification' ([IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -ceq 'preserve')
    $emptyTarget = Join-Path $work 'empty-external-target'
    [void][IO.Directory]::CreateDirectory($emptyTarget)
    [IO.Directory]::Delete($empty.filesRoot)
    $null = New-Item -ItemType Junction -Path $empty.filesRoot -Target $emptyTarget
    try {
        Check-Package 'an empty redirected files root is not accepted as an empty reviewed set' (
            -not (Test-PendingPackageIntact $empty $context $paths))
    }
    finally { [IO.Directory]::Delete($empty.filesRoot) }
}
catch { Check-Package 'suite completes without an unexpected exception' $false ($_.Exception.Message + ' | ' + $_.ScriptStackTrace) }
finally {
    if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    Check-Package 'all owned test artifacts are removed' (-not [IO.Directory]::Exists($work))
}
$failures = @($cases.ToArray() | Where-Object { -not $_.passed }).Count
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    [IO.File]::WriteAllText($ResultPath, (([ordered]@{ schema = 1; hostVersion = $PSVersionTable.PSVersion.ToString(); cases = $cases.ToArray(); failed = $failures }) | ConvertTo-Json -Depth 8), $utf8)
}
Write-Host ('Cases: ' + $cases.Count + '; failed: ' + $failures)
if ($failures -gt 0) { exit 1 }
exit 0
