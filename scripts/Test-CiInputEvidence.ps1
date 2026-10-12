# One inert Git fixture; the target's code is data and must never run.
param([switch]$SmokeOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Pass = 0; $script:Fail = 0
$Work = New-TestWorkspace -Prefix 'hookmaker-ciinputs'
$repo = Join-Path $Work 'target repo'
$reports = Join-Path $Work 'reports'
[void][IO.Directory]::CreateDirectory($repo)
[void][IO.Directory]::CreateDirectory($reports)
$tool = Join-Path $PSScriptRoot 'Get-CiInputEvidence.ps1'
function Invoke-EvidenceReport {
    param([string]$Name, [string[]]$Extra = @(), [string]$HostName = 'pwsh', [string]$DocumentPath = 'docs/guide.md', [string]$OutputPath = '')
    $out = Join-Path $reports ($Name + '.out'); $err = Join-Path $reports ($Name + '.err')
    $path = if ($OutputPath -eq '') { Join-Path $reports ($Name + '.json') } else { $OutputPath }
    if (-not [IO.File]::Exists($tool)) { return [pscustomobject]@{Exit=1;Doc=$null;Path=$path;Output='Report entry point missing.'} }
    $proc = Start-BoundedProcess -FilePath $HostName -ArgumentList (@('-NoProfile','-File',$tool,'-ProjectRoot',$repo,'-Commit',$commit,'-Document',$DocumentPath,'-ResultPath',$path,'-LogDirectory',$reports) + $Extra) -Wait -NoNewWindow -TimeoutMs 30000 -RedirectStandardOutput $out -RedirectStandardError $err
    $doc = $null
    if ([IO.File]::Exists($path)) { $doc = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json }
    return [pscustomobject]@{Exit=$proc.ExitCode;Doc=$doc;Path=$path;Output=([IO.File]::ReadAllText($out,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8))}
}
try {
    Write-Utf8 (Join-Path $repo 'docs/guide.md') 'Original prose'
    Write-Utf8 (Join-Path $repo 'scripts/reader.py') "from pathlib import Path`nPath('must-not-execute').write_text('bad')`nvalue = Path('docs/guide.md').read_text(encoding='utf-8')`n"
    Write-Utf8 (Join-Path $repo '.github/workflows/ci.yml') "name: Fixture`non: [push]`njobs:`n  test:`n    runs-on: ubuntu-latest`n    steps:`n      - run: python scripts/reader.py`n      - uses: fixture/action@v1`n"
    Write-Utf8 (Join-Path $repo 'package.json') '{"scripts":{"build":"echo token=private-example"},"dependencies":{"example":"1"}}'
    & git -C $repo init -q
    & git -C $repo add .
    & git -C $repo -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git commit failed.' }
    $commit = (& git -C $repo rev-parse HEAD).Trim()
    Write-Utf8 (Join-Path $repo 'scripts/reader.py') 'Working tree differs and is not evidence'
    $before = (& git -C $repo status --porcelain) -join "`n"
    $run = Invoke-EvidenceReport 'normal'
    Check 'actual CLI inventories immutable evidence but never grants carryover' ($run.Exit -eq 0 -and $null -ne $run.Doc -and $run.Doc.commit -ceq $commit -and $run.Doc.verdict -ceq 'UNKNOWN' -and $run.Doc.gateWaived -eq $false -and @($run.Doc.inputs | Where-Object { $_.path -eq 'scripts/reader.py' -and @($_.operations | Where-Object kind -eq 'file-read').Count -eq 1 }).Count -eq 1 -and -not [IO.File]::Exists((Join-Path $repo 'must-not-execute')) -and ((& git -C $repo status --porcelain) -join "`n") -ceq $before) $run.Output
    if (-not $SmokeOnly) {
        Check 'report omits raw source, commands and credential-like values' (-not [IO.File]::ReadAllText($run.Path,[Text.Encoding]::UTF8).Contains('private-example') -and -not [IO.File]::ReadAllText($run.Path,[Text.Encoding]::UTF8).Contains('must-not-execute'))
        Check 'workflow command/action locations are evidence, not executed commands' (@($run.Doc.inputs | Where-Object { $_.category -eq 'workflow' -and @($_.operations | Where-Object kind -eq 'workflow-command').Count -eq 1 -and @($_.operations | Where-Object kind -eq 'workflow-action').Count -eq 1 }).Count -eq 1)
        $hash = (Get-FileHash $run.Path -Algorithm SHA256).Hash
        $again = Invoke-EvidenceReport 'normal'
        Check 'existing output is refused without losing its bytes' ($again.Exit -eq 1 -and (Get-FileHash $run.Path -Algorithm SHA256).Hash -ceq $hash)
        $limited = Invoke-EvidenceReport 'limited' @('-MaxCandidates','1')
        Check 'candidate budget exhaustion is partial UNKNOWN, not successful proof' ($limited.Exit -eq 2 -and $limited.Doc.discovery -eq 'partial' -and $limited.Doc.coverage.inspected -eq 1 -and $limited.Doc.verdict -eq 'UNKNOWN') $limited.Output
        $invalid = Invoke-EvidenceReport 'invalid' -DocumentPath '../outside.md'
        Check 'document traversal produces no report' ($invalid.Exit -eq 1 -and -not [IO.File]::Exists($invalid.Path))
        $inside = Join-Path $repo 'report.json'
        $badOutput = Invoke-EvidenceReport 'inside' -OutputPath $inside
        Check 'output inside inspected target is refused' ($badOutput.Exit -ne 0 -and -not [IO.File]::Exists($inside))
        $legacy = Invoke-EvidenceReport 'legacy' @() 'powershell.exe'
        Check 'Windows PowerShell also reports immutable UNKNOWN without executing target' ($legacy.Exit -eq 0 -and $legacy.Doc.verdict -eq 'UNKNOWN' -and @($legacy.Doc.inputs | Where-Object path -eq 'scripts/reader.py').Count -eq 1) $legacy.Output
        Check 'new UTF8 diagnostic log per accepted run' (@(Get-ChildItem $reports -Filter 'Get-CiInputEvidence_*.log').Count -ge 3)
        Write-Utf8 (Join-Path $repo 'scripts/reader.py') 'Replacement object contains no read operation'
        & git -C $repo add scripts/reader.py
        & git -C $repo -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m replacement
        $replacement = (& git -C $repo rev-parse HEAD).Trim()
        & git -C $repo replace $commit $replacement
        if ($LASTEXITCODE -ne 0) { throw 'Replacement fixture setup failed.' }
        $replaced = Invoke-EvidenceReport 'replaced'
        Check 'replacement refs cannot substitute evidence for the requested commit' ($replaced.Exit -eq 0 -and @($replaced.Doc.inputs | Where-Object { $_.path -eq 'scripts/reader.py' -and @($_.operations | Where-Object kind -eq 'file-read').Count -eq 1 }).Count -eq 1) $replaced.Output
        & git -C $repo replace -d $commit | Out-Null
        Write-Utf8 (Join-Path $repo '.env.example') "# Synthetic public template only`nread_text('docs/guide.md')`n"
        & git -C $repo add .env.example
        & git -C $repo -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m protected-template
        $commit = (& git -C $repo rev-parse HEAD).Trim()
        $protected = Invoke-EvidenceReport 'protected'
        Check 'protected content is excluded from grep candidate discovery' ($protected.Exit -eq 2 -and $protected.Doc.coverage.protectedInputs -eq 1 -and @($protected.Doc.inputs | Where-Object path -eq '.env.example').Count -eq 0 -and $protected.Doc.coverage.candidates -eq 2) $protected.Output
        [IO.File]::WriteAllBytes((Join-Path $repo 'scripts/bad.py'),[byte[]]@(114,101,97,100,95,116,101,120,116,195,40))
        & git -C $repo add scripts/bad.py
        & git -C $repo -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m invalid-encoding
        $commit = (& git -C $repo rev-parse HEAD).Trim()
        $encoding = Invoke-EvidenceReport 'encoding'
        Check 'invalid UTF8 is partial evidence, never silently decoded or certified' ($encoding.Exit -eq 2 -and @($encoding.Doc.inputs | Where-Object { $_.path -eq 'scripts/bad.py' -and $_.inspection -eq 'unavailable' }).Count -eq 1 -and $encoding.Doc.verdict -eq 'UNKNOWN') $encoding.Output
        $logs = @(Get-ChildItem $reports -Filter 'Get-CiInputEvidence_*.log')
        $logText = @($logs | ForEach-Object { [IO.File]::ReadAllText($_.FullName,[Text.UTF8Encoding]::new($false,$true)) }) -join "`n"
        Check 'logs are structured UTC and omit target commands or fixture credentials' ($logText -match '\[\d{4}-\d{2}-\d{2} .* UTC\] \[INFO\] \[AUDIT\]' -and -not $logText.Contains('private-example') -and -not $logText.Contains('must-not-execute'))
    }
}
finally { if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ } }
Write-Host ('Passed: ' + $script:Pass + ' Failed: ' + $script:Fail)
exit $script:Fail
