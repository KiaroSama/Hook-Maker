# Dot-sourced by Test-Engine.ps1. All links and paths are isolated fixtures.
$edgeSrc = New-Project 'Edge source'
$edgeDst = New-Project ('[Archive](2026)\Project $draft `' + "'s")
$edgeCfg = Join-Path $Work 'edge-config.json'
$srcEndpoint = New-Endpoint 'Source' $edgeSrc
$dstEndpoint = New-Endpoint 'Destination' $edgeDst
$edgeRoute = New-Route ('edge' + [char]0x202e) $srcEndpoint $dstEndpoint
Write-Config -Path $edgeCfg -Routes @($edgeRoute) -Extensions @('.md')
[IO.File]::WriteAllText((Join-Path $edgeSrc '.ai\EDGE.md'),'first note')
$edge = Fire -Cwd $edgeDst -Config $edgeCfg
$edgeNotice = Get-SyncNotice $edge.Out
Check 'review route metadata escapes bidi controls' (-not $edgeNotice.Contains([string][char]0x202e)) $edgeNotice
$edgeCommand = Get-SyncAckCommand $edge.Out
Check 'archive folder remains literal inside a separate fenced command block' ($edgeCommand.Contains('[Archive](2026)') -and
    $edgeNotice.Contains("`n~~~`n$edgeCommand`n~~~")) $edgeCommand
$restrictedAck = Run-Acknowledgement -Command $edgeCommand -Restricted
Check 'pasted command acknowledges in a restricted Windows PowerShell session' ($restrictedAck.Exit -eq 0 -and $restrictedAck.Out -match 'acknowledged') $restrictedAck.Error
[IO.File]::WriteAllText((Join-Path $edgeSrc '.ai\EDGE.md'), 'second note')
$edgeCommand = Get-SyncAckCommand (Fire -Cwd $edgeDst -Config $edgeCfg).Out
if ($edgeCommand -ne '') {
    # Parse the fixture command as PowerShell, but do not evaluate any input.
    $tok=$null; $err=$null
    $parsed=[Management.Automation.Language.Parser]::ParseInput($edgeCommand,[ref]$tok,[ref]$err)
    $cmd=$parsed.Find({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)
    $unsafeExpansion=@($parsed.FindAll({param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'draft'},$true)).Count
    Check 'review command does not expand destination dollar and backtick' ($err.Count -eq 0 -and $unsafeExpansion -eq 0 -and $null -ne $cmd) $edgeCommand
} else { Check 'review command does not expand destination dollar and backtick' $false $edgeNotice }
$edgeAck = Run-Acknowledgement -Command $edgeCommand
Check 'pasted command acknowledges literal apostrophe, dollar, backtick and bidi route id' ($edgeAck.Exit -eq 0 -and $edgeAck.Out -match 'acknowledged') $edgeAck.Error

$edgeState = Get-ChildItem -LiteralPath (Join-Path $edgeDst '.ai\.cross-project-sync\state') -Filter '*.v3.json' | Select-Object -First 1
$edgeStamp = [IO.Path]::ChangeExtension($edgeState.FullName,'.scan')
$stampOther = Join-Path $Work 'keep linked stamp bytes.txt'
[IO.File]::WriteAllText($stampOther,'unchanged'); [IO.File]::Delete($edgeStamp)
New-Item -ItemType HardLink -Path $edgeStamp -Target $stampOther | Out-Null
try {
    $null = Fire -Cwd $edgeDst -Config $edgeCfg
    Check 'a hard-linked scan stamp cannot truncate its other name' ([IO.File]::ReadAllText($stampOther) -ceq 'unchanged')
} finally { [IO.File]::Delete($edgeStamp) }

$hiddenSrc = Join-Path $edgeSrc '.ai\.cross-project-sync\inbox\old'
[void][IO.Directory]::CreateDirectory((Join-Path $hiddenSrc '.ai'))
[IO.File]::WriteAllText((Join-Path $hiddenSrc '.ai\OLD-NOTE.md'),'legacy content')
$hiddenDst = New-Project 'Hidden source destination'
Write-Config -Path $edgeCfg -Routes @((New-Route 'hidden' (New-Endpoint 'Bad' $hiddenSrc) (New-Endpoint 'Dest' $hiddenDst))) -Extensions @('.md')
$hidden = Fire -Cwd $hiddenDst -Config $edgeCfg
Check 'protected path segments above a configured source root are refused' (-not (Get-SyncNotice $hidden.Out).Contains('OLD-NOTE.md')) $hidden.Out

$venvSrc = New-Project '.venv\Workspace'
[IO.File]::WriteAllText((Join-Path $venvSrc '.ai\VENV-NOTE.md'), 'protected content')
Write-Config -Path $edgeCfg -Routes @(
    (New-Route 'venv' (New-Endpoint 'Venv' $venvSrc) (New-Endpoint 'Dest' $hiddenDst)),
    (New-Route 'temp' (New-Endpoint 'Ordinary' $edgeSrc) (New-Endpoint 'Dest' $hiddenDst))
) -Extensions @('.md')
$rootNotice = Get-SyncNotice (Fire -Cwd $hiddenDst -Config $edgeCfg).Out
Check 'a configured source root inside .venv is refused' (-not $rootNotice.Contains('VENV-NOTE.md')) $rootNotice
Check 'an ordinary temporary workspace still emits its notice' ($rootNotice.Contains('EDGE.md')) $rootNotice

$first = New-Project 'Buffered first source'; $second = New-Project 'Buffered second source'
$bufferDst = New-Project 'Buffered destination'
[IO.File]::WriteAllText((Join-Path $first '.ai\FIRST.md'),'first')
[IO.File]::WriteAllText((Join-Path $second '.ai\SECOND.md'),'second')
$bufferConfig = Join-Path $Work 'buffered-config.json'
$secondRoute = New-Route 'second' (New-Endpoint 'second' $second) (New-Endpoint 'dst' $bufferDst)
Write-Config -Path $bufferConfig -Routes @($secondRoute) -Extensions @('.md')
$null = Fire -Cwd $bufferDst -Config $bufferConfig
$bufferState = (Get-ChildItem -LiteralPath (Join-Path $bufferDst '.ai\.cross-project-sync\state') -Filter '*.v3.json' | Select-Object -First 1).FullName
$sha=[Security.Cryptography.SHA256]::Create()
try { $key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($bufferState.ToUpperInvariant()))).Replace('-','').ToLowerInvariant() }
finally { $sha.Dispose() }
$mutex=[Threading.Mutex]::new($false,('Global\HookMakerSync-'+$key))
try {
    if(-not $mutex.WaitOne(0)){throw 'Fixture route lock is busy.'}
    $firstRoute=New-Route 'first' (New-Endpoint 'first' $first) (New-Endpoint 'dst' $bufferDst)
    Write-Config -Path $bufferConfig -Routes @($firstRoute,$secondRoute) -Extensions @('.md')
    $buffered = Fire -Cwd $bufferDst -Config $bufferConfig -SessionId 'buffered'
    Check 'later route lock failure cannot suppress an earlier notice' ((Get-SyncNotice $buffered.Out).Contains('FIRST.md')) $buffered.Error
    $mutex.ReleaseMutex()
} finally { $mutex.Dispose() }

# NTFS directory case sensitivity requires an opt-in capability on the test host.
# If unavailable, exercise the exact production map with real snapshot records.
$caseSrc = New-Project 'Case source'; $caseDst = New-Project 'Case destination'
$caseDir = Join-Path $caseSrc '.ai'
$null = & fsutil.exe file setCaseSensitiveInfo $caseDir enable 2>&1
if ($LASTEXITCODE -eq 0) {
    [IO.File]::WriteAllText((Join-Path $caseDir 'NOTE.md'),'upper')
    [IO.File]::WriteAllText((Join-Path $caseDir 'note.md'),'lower')
    Write-Config -Path $edgeCfg -Routes @((New-Route 'case' (New-Endpoint 'Src' $caseSrc) (New-Endpoint 'Dst' $caseDst))) -Extensions @('.md')
    $caseFirst=Fire -Cwd $caseDst -Config $edgeCfg
    $caseAck=Run-Acknowledgement -Command (Get-SyncAckCommand $caseFirst.Out)
    $caseAgain=Fire -Cwd $caseDst -Config $edgeCfg
    Check 'case-distinct files with different bytes stay acknowledged' ($caseAck.Exit-eq0 -and [string]::IsNullOrWhiteSpace($caseAgain.Out)) $caseAgain.Out
    $caseDst2=New-Project 'Case alias destination'
    [IO.File]::Delete((Join-Path $caseDir 'note.md'))
    Write-Config -Path $edgeCfg -Routes @((New-Route 'case-alias' (New-Endpoint 'Src' $caseSrc) (New-Endpoint 'Dst' $caseDst2))) -Extensions @('.md')
    $caseFirst=Fire -Cwd $caseDst2 -Config $edgeCfg
    $caseAck=Run-Acknowledgement -Command (Get-SyncAckCommand $caseFirst.Out)
    [IO.File]::WriteAllText((Join-Path $caseDir 'note.md'),'upper')
    $caseAgain=Fire -Cwd $caseDst2 -Config $edgeCfg
    $caseText=Get-SyncNotice $caseAgain.Out
    Check 'equal-content case alias is offered as a separate source path' ($caseAck.Exit-eq0 -and $caseText.Contains('\note.md') -and -not $caseText.Contains('\NOTE.md')) $caseText
}
else {
    $tok=$null;$err=$null
    $model=[Management.Automation.Language.Parser]::ParseFile($Engine,[ref]$tok,[ref]$err)
    $mapFunction=$model.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Convert-FileRecordsToMap'},$true)
    . ([scriptblock]::Create($mapFunction.Extent.Text))
    $caseMap=Convert-FileRecordsToMap @([pscustomobject]@{path='NOTE.md';sha256='upper'},[pscustomobject]@{path='note.md';sha256='lower'})
    Check 'case-distinct files with different bytes stay acknowledged' ($caseMap.Count-eq2 -and $caseMap['NOTE.md'].sha256-ne$caseMap['note.md'].sha256)
    $caseMap=Convert-FileRecordsToMap @([pscustomobject]@{path='NOTE.md';sha256='equal'})
    Check 'equal-content case alias is offered as a separate source path' (-not $caseMap.ContainsKey('note.md'))
}
