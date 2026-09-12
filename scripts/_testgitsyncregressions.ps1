# Regression scenarios invoked by Test-GitSyncCheck.ps1's existing harness.
$orderProbe = & {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $Hook)) '_hooklib.ps1')
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Hook, [ref]$tokens, [ref]$parseErrors)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-WorktreeDirtyFingerprint' }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $orderDir = Join-Path $Work 'status-order'
    Write-Utf8 (Join-Path $orderDir 'one.txt') 'one'
    Write-Utf8 (Join-Path $orderDir 'two.txt') 'two'
    function Invoke-Git {
        param($GitArgs, $RepoPath, $TimeoutSeconds)
        return [pscustomobject]@{ Ok = $true; Output = @($dirtyFixtureRecords) }
    }
    $dirtyFixtureRecords = "? one.txt`0? two.txt`0"
    $first = Get-WorktreeDirtyFingerprint $orderDir
    $dirtyFixtureRecords = "? two.txt`0? one.txt`0"
    $reordered = Get-WorktreeDirtyFingerprint $orderDir
    Write-Utf8 (Join-Path $orderDir 'one.txt') 'two'
    Write-Utf8 (Join-Path $orderDir 'two.txt') 'one'
    $swapped = Get-WorktreeDirtyFingerprint $orderDir
    [pscustomobject]@{ First = $first; Reordered = $reordered; Swapped = $swapped }
}
Check 'porcelain record ordering does not change a complete content fingerprint' (
    $orderProbe.First -ne '' -and $orderProbe.First -eq $orderProbe.Reordered)
Check 'content hashes stay bound to paths when file contents are swapped' (
    $orderProbe.Swapped -ne '' -and $orderProbe.Swapped -ne $orderProbe.Reordered)
foreach ($hostName in @('pwsh', 'powershell.exe')) {
    Write-Host ('--- worktree record/content regressions: ' + $hostName + ' ---') -ForegroundColor Cyan
    $hostTag = if ($hostName -eq 'pwsh') { 'ps7' } else { 'ps5' }

    $many = New-PushedRepo ('multi-' + $hostTag)
    $first = Join-Path $ReposRoot ('multi-' + $hostTag + '-first')
    $last = Join-Path $ReposRoot ('multi-' + $hostTag + '-last')
    & git -C $many worktree add -q $first -b ('multi-' + $hostTag + '-first') 2>$null
    & git -C $many worktree add -q $last -b ('multi-' + $hostTag + '-last') 2>$null
    Fire -Cwd $many -EventName 'SessionStart' -SessionId ('multi-' + $hostTag) -Exe $hostName | Out-Null
    Write-Utf8 (Join-Path $first 'f.txt') 'changed in the non-final worktree'
    $r = Fire -Cwd $many -SessionId ('multi-' + $hostTag) -Exe $hostName
    Check ($hostName + ': a dirty non-final linked worktree is inspected') (
        $r.Exit -eq 0 -and $r.Out -match '"decision":"block"' -and
        $r.Out -match ('multi-' + $hostTag + '-first')) ($r.Out + $r.Err)

    $dirty = New-PushedRepo ('dirty-content-' + $hostTag)
    $other = Join-Path $ReposRoot ('dirty-content-' + $hostTag + '-other')
    & git -C $dirty worktree add -q $other -b ('dirty-content-' + $hostTag + '-other') 2>$null
    $dirtyFile = Join-Path $other 'f.txt'
    Write-Utf8 $dirtyFile 'before-task'
    $savedTime = [System.IO.File]::GetLastWriteTimeUtc($dirtyFile)
    $beforeStatus = ((& git -C $other status --porcelain) -join "`n")
    Fire -Cwd $dirty -EventName 'SessionStart' -SessionId ('content-' + $hostTag) -Exe $hostName | Out-Null
    $unchanged = Fire -Cwd $dirty -SessionId ('content-' + $hostTag) -Exe $hostName
    Check ($hostName + ': unchanged pre-existing dirty bytes remain silent') ($unchanged.Exit -eq 0 -and $unchanged.Out -eq '') $unchanged.Out
    Write-Utf8 $dirtyFile 'during-task'
    [System.IO.File]::SetLastWriteTimeUtc($dirtyFile, $savedTime)
    $afterStatus = ((& git -C $other status --porcelain) -join "`n")
    Check ($hostName + ': fixture preserves status codes, length and modification time') (
        $beforeStatus -eq $afterStatus -and (Get-Item -LiteralPath $dirtyFile).Length -eq 11 -and
        [System.IO.File]::GetLastWriteTimeUtc($dirtyFile) -eq $savedTime)
    $r = Fire -Cwd $dirty -SessionId ('content-' + $hostTag) -Exe $hostName
    Check ($hostName + ': changed bytes in an already-dirty tracked file are task-scoped') (
        $r.Exit -eq 0 -and $r.Out -match '"decision":"block"' -and $r.Out -match 'pre-existing worktree') ($r.Out + $r.Err)

    $untracked = Join-Path $other ('new folder\untracked-' + [char]0x0645 + '.txt')
    Write-Utf8 $untracked 'untracked-before'
    Fire -Cwd $dirty -EventName 'SessionStart' -SessionId ('untracked-' + $hostTag) -Exe $hostName | Out-Null
    Write-Utf8 $untracked 'untracked-during'
    $r = Fire -Cwd $dirty -SessionId ('untracked-' + $hostTag) -Exe $hostName
    Check ($hostName + ': changed bytes under an already-untracked directory are task-scoped') (
        $r.Exit -eq 0 -and $r.Out -match '"decision":"block"' -and $r.Out -match 'pre-existing worktree') ($r.Out + $r.Err)

    Write-Utf8 $dirtyFile 'staged-one'
    & git -C $other add f.txt
    Write-Utf8 $dirtyFile 'working-bytes'
    Fire -Cwd $dirty -EventName 'SessionStart' -SessionId ('index-' + $hostTag) -Exe $hostName | Out-Null
    $beforeStatus = ((& git -C $other status --porcelain) -join "`n")
    Write-Utf8 $dirtyFile 'staged-two'
    & git -C $other add f.txt
    Write-Utf8 $dirtyFile 'working-bytes'
    $afterStatus = ((& git -C $other status --porcelain) -join "`n")
    Check ($hostName + ': index-only fixture preserves worktree bytes and status codes') ($beforeStatus -eq $afterStatus)
    $r = Fire -Cwd $dirty -SessionId ('index-' + $hostTag) -Exe $hostName
    Check ($hostName + ': changed staged bytes are detected independently of worktree bytes') (
        $r.Exit -eq 0 -and $r.Out -match '"decision":"block"' -and $r.Out -match 'pre-existing worktree') ($r.Out + $r.Err)

    $large = Join-Path $other 'large.dat'
    $stream = [System.IO.File]::Create($large)
    try { $stream.SetLength(16MB + 1) } finally { $stream.Dispose() }
    Fire -Cwd $dirty -EventName 'SessionStart' -SessionId ('bounded-' + $hostTag) -Exe $hostName | Out-Null
    $r = Fire -Cwd $dirty -SessionId ('bounded-' + $hostTag) -Exe $hostName
    Check ($hostName + ': incomplete content hashing is UNKNOWN, never unchanged or a block') (
        $r.Exit -eq 0 -and $r.Out -match 'UNKNOWN' -and $r.Out -notmatch '"decision":"block"') ($r.Out + $r.Err)
    $stateText = (@(Get-ChildItem -LiteralPath $FakeLocalAppData -Filter '*.json' -Recurse -File |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n")
    Check ($hostName + ': worktree state persists no file contents') (
        $stateText -notmatch 'before-task|during-task|untracked-before|untracked-during')
}
