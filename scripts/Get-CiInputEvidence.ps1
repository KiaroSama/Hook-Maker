# Read-only preanalysis; no report is consumed by CI carryover or success gates.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$Commit,
    [Parameter(Mandatory=$true)][string[]]$Document,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [string]$LogDirectory = '',
    [ValidateRange(1,600)][int]$TimeoutSeconds = 120,
    [ValidateRange(1,5000)][int]$MaxCandidates = 200,
    [ValidateRange(1024,67108864)][long]$MaxContentBytes = 8388608
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'hooks/_hooklib.ps1')
. (Join-Path $PSScriptRoot '_managementaudit.ps1')
. (Join-Path $PSScriptRoot '_ciinputevidence.ps1')
$temp = ''; $exitCode = 1
try {
    if ($Commit -cnotmatch '^[a-f0-9]{40}$') { throw 'Supply an exact lowercase 40-hex commit identity.' }
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char[]]@('/','\'))
    if (-not [IO.Directory]::Exists($root)) { throw 'The local repository directory does not exist.' }
    Assert-EvidencePhysicalPath $root
    Assert-EvidencePhysicalPath (Join-Path $root '.git')
    $result = [IO.Path]::GetFullPath($ResultPath)
    $parent = [IO.Path]::GetDirectoryName($result)
    if (-not [IO.Directory]::Exists($parent)) { throw 'The output parent directory must already exist.' }
    if ([IO.File]::Exists($result) -or [IO.Directory]::Exists($result)) { throw 'Output already exists; existing evidence will not be overwritten.' }
    if ($LogDirectory -eq '') { $LogDirectory = Join-Path $toolRoot 'logs' }
    $logRoot = [IO.Path]::GetFullPath($LogDirectory)
    foreach ($path in @($result,$logRoot)) {
        Assert-EvidencePhysicalPath $path
        if ([string]::Equals($path,$root,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Output and diagnostics must be outside the inspected project.' }
    }
    foreach ($doc in $Document) {
        if ($doc.Length -gt 4096 -or $doc -notmatch '\.(md|txt)$' -or $doc -match '(^/|\\|[\x00-\x1f\x7f:]|(^|/)\.{1,2}(/|$)|//)' -or (Test-EvidenceProtectedPath $doc)) { throw 'Document must be a safe public relative prose path.' }
    }
    if ($Document.Count -eq 0 -or $Document.Count -gt 100) { throw 'Supply between 1 and 100 document paths.' }
    $script:EvidenceRoot=$root; $script:EvidenceDeadline=[DateTime]::UtcNow.AddSeconds(10)
    $top = (Invoke-EvidenceGit @('rev-parse','--show-toplevel')).Trim()
    if (-not [string]::Equals([IO.Path]::GetFullPath($top).TrimEnd([char[]]@('/','\')),$root,[StringComparison]::OrdinalIgnoreCase)) { throw 'ProjectRoot must be the repository top-level directory.' }
    # Explicit log destination avoids inheriting another project's log override.
    $logPath = New-ManagementLogFile -Directory $logRoot -Name 'Get-CiInputEvidence'
    Start-ManagementAudit -ToolRoot $toolRoot -Name 'Get-CiInputEvidence' -Path $logPath
    Write-ManagementAudit -Event 'evidence-start' -Data @{commit=$Commit;documentCount=$Document.Count;timeoutSeconds=$TimeoutSeconds;maxCandidates=$MaxCandidates;maxContentBytes=$MaxContentBytes}
    $report = Get-CiInputEvidence -Root $root -Commit $Commit -Documents $Document -TimeoutSeconds $TimeoutSeconds -MaxCandidates $MaxCandidates -MaxContentBytes $MaxContentBytes
    $json = $report | ConvertTo-Json -Depth 12
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 16777216) { throw 'Serialized report exceeds the 16 MiB publication limit.' }
    $temp = Join-Path $parent ('.ci-input-evidence-'+[guid]::NewGuid().ToString('N')+'.tmp')
    Assert-EvidencePhysicalPath $parent
    $stream = [IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $encoded=[Text.UTF8Encoding]::new($false).GetBytes($json); $stream.Write($encoded,0,$encoded.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    # Two-argument Move is create-only on both supported hosts, including races.
    [IO.File]::Move($temp,$result)
    $temp=''
    $exitCode = if ($report.discovery -eq 'complete') {0} else {2}
    Write-ManagementAudit -Event 'evidence-complete' -Data @{commit=$Commit;discovery=$report.discovery;verdict='UNKNOWN';coverage=$report.coverage;exitCode=$exitCode}
    Write-Output ('Evidence report written; discovery='+$report.discovery+'; verdict=UNKNOWN; no carryover or CI success was granted.')
}
catch {
    Write-ManagementAudit -Event 'evidence-failed' -Data @{reason='Validation, immutable Git query or output publication failed.';exitCode=1}
    [Console]::Error.WriteLine('CI input evidence failed: '+(ConvertTo-ManagementAuditData ([string]$_.Exception.Message)))
}
finally {
    if ($temp -ne '' -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
}
exit $exitCode
