# Actual Stop transport, one shared large Git fixture, no hosted requests.
function Invoke-LargeDocsStopRegression {
    param([string]$Workspace, [string]$HooksRoot, [switch]$SmokeOnly)
    $root = Join-Path $Workspace 'large-stop'
    $repo = Join-Path $root 'repo'
    $shim = Join-Path $root 'shim'
    [void][IO.Directory]::CreateDirectory($repo)
    [void][IO.Directory]::CreateDirectory($shim)
    & git -C $repo init -qb main
    & git -C $repo config user.name fixture
    & git -C $repo config user.email fixture@example.invalid
    & git -C $repo config core.autocrlf false
    & git -C $repo remote add origin https://github.com/owner/repo.git
    foreach ($dir in @('docs', '.github/workflows', 'data')) { [void][IO.Directory]::CreateDirectory((Join-Path $repo $dir)) }
    Write-Utf8 (Join-Path $repo '.github/workflows/ci.yml') "on: [push]`njobs:`n  test:`n    runs-on: windows-latest`n    steps:`n      - name: Validate`n        run: echo fixture"
    Write-Utf8 (Join-Path $repo 'docs/compatibility.md') 'Original prose'
    Write-Utf8 (Join-Path $repo 'docs/source-format.md') 'Original format prose'
    for ($i = 0; $i -lt 2001; $i++) { Write-Utf8 (Join-Path $repo ('data/' + $i + '.txt')) 'Unrelated payload' }
    & git -C $repo add .
    & git -C $repo commit -qm code
    $base = ([string](& git -C $repo rev-parse HEAD)).Trim()
    Write-Utf8 (Join-Path $repo 'docs/compatibility.md') 'Revised compatibility prose'
    Write-Utf8 (Join-Path $repo 'docs/source-format.md') 'Revised format prose'
    & git -C $repo add .
    & git -C $repo commit -qm 'docs [skip ci]'
    $sha = ([string](& git -C $repo rev-parse HEAD)).Trim()
    & git -C $repo update-ref refs/remotes/origin/main $sha
    & git -C $repo config branch.main.remote origin
    & git -C $repo config branch.main.merge refs/heads/main
    if ($LASTEXITCODE -ne 0) { throw 'Large fixture Git setup failed.' }
    $mock = @'
$a = @($args)
$utf8 = New-Object Text.UTF8Encoding($false,$true)
[Console]::OutputEncoding = $utf8
if ($a[0] -eq 'auth') { exit 0 }
if ($a[0] -eq 'run') { '[]'; exit 0 }
if ($a[0] -eq 'api') {
    $e = [string]$a[1]; $base = $env:GH_DOCS_BASE
    if ($e -match '/rules/branches/') { '[]'; exit 0 }
    if ($e -match '/branches/') { '{"name":"main","protected":false}'; exit 0 }
    if ($e -match '/attempts/1/jobs') { @{total_count=1;jobs=@(@{id=12;check_run_url='https://api.github.com/repos/owner/repo/check-runs/12';run_id=1;run_attempt=1;head_sha=$base;name='test';status='completed';conclusion='success';completed_at='2026-10-17T09:00:00Z';steps=@(@{number=1;name='Validate';status='completed';conclusion='success';completed_at='2026-10-17T08:59:00Z'})})}|ConvertTo-Json -Depth 8 -Compress;exit 0 }
    if ($e -match '/actions/runs') {
        if (-not $e.Contains($base)) { '{"total_count":0,"workflow_runs":[]}'; exit 0 }
        @{ total_count=1; workflow_runs=@(@{id=1;workflow_id=9;run_attempt=1;head_sha=$base; head_repository=@{full_name='owner/repo'}; repository=@{full_name='owner/repo'}; head_branch='main'; status='completed'; conclusion='success'; path='.github/workflows/ci.yml'; event='push'}) } | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    if ($e -match '/commits/([a-f0-9]{40})/check-runs') {
        $commit=$Matches[1]
        if($commit-cne$base){'{"total_count":0,"check_runs":[]}';exit 0}
        @{total_count=1; check_runs=@(@{id=12;head_sha=$commit; status='completed'; conclusion='success'})} | ConvertTo-Json -Depth 4 -Compress; exit 0
    }
    if ($e -match '/commits/([a-f0-9]{40})/status') { @{sha=$Matches[1]; total_count=0; statuses=@(); state='pending'} | ConvertTo-Json -Depth 4 -Compress; exit 0 }
}
exit 1
'@
    Write-Utf8 (Join-Path $shim 'gh.ps1') $mock
    $savedPath = $env:PATH; $savedBase = $env:GH_DOCS_BASE
    $token = $null
    try {
        $token = Enter-TestStateIsolation -Workspace $root
        $env:GH_DOCS_BASE = $base
        $env:PATH = $shim + ';' + $savedPath
        $inputFile = Join-Path $root 'input.json'
        Write-Utf8 $inputFile (@{cwd=$repo; session_id='large-docs'; hook_event_name='Stop'} | ConvertTo-Json)
        $outFile = Join-Path $root 'output.txt'; $errFile = Join-Path $root 'error.txt'
        $hook = Join-Path $HooksRoot 'Ci-Status-Check/Ci-Status-Check.ps1'
        $proc = Start-BoundedProcess -FilePath pwsh -ArgumentList @('-NoLogo','-NoProfile','-File',$hook) -WorkingDirectory $repo -Wait -NoNewWindow -TimeoutMs 60000 -RedirectStandardInput $inputFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $out = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8)
        $err = [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8)
        $records = @(Get-ChildItem -LiteralPath $env:HOOKMAKER_STATE_DIR -Filter 'CiStatusCheck-*.txt' -File | Where-Object { $_.Name -notmatch 'Auth|Notice|External' })
        $lines = @(); if ($records.Count -eq 1) { $lines = @([IO.File]::ReadAllLines($records[0].FullName, [Text.Encoding]::UTF8)) }
        Check 'large public Stop carries exact ancestor, not invented final CI' ($proc.ExitCode -eq 0 -and $err -eq '' -and $out -match 'systemMessage' -and $out.Contains($base) -and $out -notmatch '"decision"' -and $lines.Count -eq 6 -and $lines[0] -ceq $sha -and $lines[3] -ceq 'docs-only-carryover' -and $lines[4] -ceq $base) ($out + $err + ($lines -join '|'))
        $proc.Dispose()
        if (-not $SmokeOnly) {
            $env:LOCALAPPDATA = Join-Path $root 'ps51-local'
            $env:HOOKMAKER_STATE_DIR = Join-Path $env:LOCALAPPDATA 'HookMaker/state'
            $proc = Start-BoundedProcess -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-File',$hook) -WorkingDirectory $repo -Wait -NoNewWindow -TimeoutMs 60000 -RedirectStandardInput $inputFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $out = [IO.File]::ReadAllText($outFile,[Text.Encoding]::UTF8); $err = [IO.File]::ReadAllText($errFile,[Text.Encoding]::UTF8)
            Check '5.1 large Stop carries exact ancestor with strict UTF-8 queries' ($proc.ExitCode -eq 0 -and $err -eq '' -and $out.Contains($base) -and $out -match 'systemMessage' -and $out -notmatch '"decision"') ($out + $err)
            $proc.Dispose()
            foreach ($variant in @(
                @{Name='vendored direct read'; Path='vendor/check.py'; Text='open("docs/compatibility.md").read()'},
                @{Name='indirect glob'; Path='tests/input.py'; Text='for p in root.rglob("*"): validate(p.read_text())'},
                @{Name='package long description'; Path='pyproject.toml'; Text='readme = "docs/source-format.md"'},
                @{Name='basename argument'; Path='build.sh'; Text='run-tool compatibility.md'},
                @{Name='semantic extractor'; Path='build.sh'; Text='remark-extract "*.md"'},
                @{Name='empty docs configuration'; Path='vendor/mkdocs.yml'; Text=''},
                @{Name='encoding is not hygiene'; Path='build.ps1'; Text='$x=[IO.File]::ReadAllText("docs/compatibility.md",[Text.Encoding]::UTF8); if($x.Contains("required")){throw "invalid"}'},
                @{Name='unbounded generic reader'; Path='vendor/consumer.py'; Text='validate(open(sys.argv[1]).read())'},
                @{Name='unsupported language reader'; Path='vendor/consumer.c'; Text='fopen("input", "r");'},
                @{Name='relevant content overflow'; Path='vendor/consumer.py'; Text='open("input").read()' + ('x' * 1048577)},
                @{Name='query UTF-8 round trip'; Path='vendor/consumer.py'; Text='open("' + [char]0x062f + [char]0x0627 + [char]0x062f + [char]0x0647 + '").read()'},
                @{Name='embedded document'; Path='guide.md'; Text='```python' + "`n" + 'open("compatibility.md").read()' + "`n" + '```'}
            )) {
                $env:LOCALAPPDATA = Join-Path $root ('state-' + $variant.Name.Replace(' ','-'))
                $env:HOOKMAKER_STATE_DIR = Join-Path $env:LOCALAPPDATA 'HookMaker/state'
                Write-Utf8 (Join-Path $repo $variant.Path) $variant.Text
                & git -C $repo add .; & git -C $repo commit -qm 'input source'
                $env:GH_DOCS_BASE = ([string](& git -C $repo rev-parse HEAD)).Trim()
                Write-Utf8 (Join-Path $repo 'docs/compatibility.md') ('Prose ' + $variant.Name)
                & git -C $repo add .; & git -C $repo commit -qm 'docs [skip ci]'
                $head = ([string](& git -C $repo rev-parse HEAD)).Trim()
                & git -C $repo update-ref refs/remotes/origin/main $head
                $proc = Start-BoundedProcess -FilePath pwsh -ArgumentList @('-NoLogo','-NoProfile','-File',$hook) -WorkingDirectory $repo -Wait -NoNewWindow -TimeoutMs 60000 -RedirectStandardInput $inputFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                $out = [IO.File]::ReadAllText($outFile,[Text.Encoding]::UTF8); $err = [IO.File]::ReadAllText($errFile,[Text.Encoding]::UTF8)
                Check ($variant.Name + ': public Stop refuses without indefinite CI wait') ($proc.ExitCode -eq 0 -and $err -eq '' -and $out -match '"decision"' -and $out -match 'carryover not verified' -and $out -notmatch 'wait briefly|no runs are registered yet') ($out + $err)
                $proc.Dispose()
                # Isolated fixture only, not application history.
                & git -C $repo reset --hard $sha *> $null
                & git -C $repo update-ref refs/remotes/origin/main $sha
            }
            # Reuse the real repository and GitHub transport; reviewed inputs are
            # fixture-authored source evidence, not generated from successful jobs.
            foreach($document in @('docs/compatibility.md','docs/source-format.md')){
                Write-Utf8 (Join-Path $repo $document) ('Baseline prose'+"`n"+'```powershell'+"`n"+'Write-Output 42'+"`n"+'```')
            }
            [void][IO.Directory]::CreateDirectory((Join-Path $repo 'scripts'))
            foreach($i in 0..154){Write-Utf8 (Join-Path $repo "scripts/reader-$i.ps1") '$null=[IO.File]::ReadAllText("data/0.txt")'}
            & git -C $repo add .; & git -C $repo commit -qm 'reviewed fixture source'
            $reviewBase=([string](& git -C $repo rev-parse HEAD)).Trim()
            $env:GH_DOCS_BASE=$reviewBase
            $documents=@('docs/compatibility.md','docs/source-format.md')
            $inventory=Get-CiClosureInventory $repo $reviewBase $documents
            $tree=([string](& git -C $repo rev-parse ($reviewBase+'^{tree}'))).Trim()
            $projection=Get-RepositoryIdentityHash (@('fence:```powershell','code:Write-Output 42','fence:```')-join"`n")
            $policy=@{schema=3;repository='owner/repo';verdict='non-semantic';rationale='Every synthetic reader reads fixed unrelated data';baseline=@{sha=$reviewBase;tree=$tree};ancestor=@{sha=$reviewBase;tree=$tree};sourceBranches=@('main');destinationBranches=@('main');documents=$documents;documentContracts=@($documents|ForEach-Object{@{path=$_;sha256=$projection}});inventory=@{count=$inventory.Count;sha256=$inventory.Fingerprint};candidates=@(0..154|ForEach-Object{$path="scripts/reader-$_.ps1";@{path=$path;blob=$inventory.Entries[$path].Blob;bytes=$inventory.Entries[$path].Bytes;role='fixed-unrelated-input';rationale='Literal data/0.txt input only; no document path or traversal'}})}
            foreach($document in $documents){Write-Utf8 (Join-Path $repo $document) ('Revised prose'+"`n"+'```powershell'+"`n"+'Write-Output 42'+"`n"+'```')}
            & git -C $repo add .; & git -C $repo commit -qm 'docs [skip ci]'
            $reviewFinal=([string](& git -C $repo rev-parse HEAD)).Trim()
            & git -C $repo update-ref refs/remotes/origin/main $reviewFinal
            $unreviewed=Test-DocsHaveSemanticConsumers $repo $reviewFinal $documents 'owner/repo'
            Check '155-reader automatic path retains original candidate refusal' ($unreviewed-and$script:DocsCarryoverReason-match'more than 100')
            $runtime=Join-Path $root 'reviewed-runtime/Ci-Status-Check'
            [void][IO.Directory]::CreateDirectory($runtime)
            foreach($module in @(Get-ChildItem (Split-Path -Parent $hook) -File|Where-Object{$_.Extension-in@('.ps1','.cs')})){Copy-Item -LiteralPath $module.FullName -Destination $runtime}
            Copy-TestRuntimeLibraries -SourceHookLib (Join-Path $HooksRoot '_hooklib.ps1') -Destination (Join-Path (Split-Path -Parent $runtime) '_hooklib.ps1')
            Write-Utf8 (Join-Path $runtime '_docs-policy.json') ($policy|ConvertTo-Json -Depth 12 -Compress)
            foreach($hostName in @('pwsh','powershell.exe')){
                $env:LOCALAPPDATA=Join-Path $root ('reviewed-'+$hostName)
                $env:HOOKMAKER_STATE_DIR=Join-Path $env:LOCALAPPDATA 'HookMaker/state'
                $proc=Start-BoundedProcess -FilePath $hostName -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $runtime 'Ci-Status-Check.ps1')) -WorkingDirectory $repo -TimeoutMs 60000 -RedirectStandardInput $inputFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                $out=[IO.File]::ReadAllText($outFile,[Text.Encoding]::UTF8);$err=[IO.File]::ReadAllText($errFile,[Text.Encoding]::UTF8)
                $records=@(Get-ChildItem $env:HOOKMAKER_STATE_DIR -Filter 'CiStatusCheck-*.txt' -File|Where-Object{$_.Name-notmatch'Auth|Notice|External'})
                $lines=@();if($records.Count-eq1){$lines=@([IO.File]::ReadAllLines($records[0].FullName,[Text.Encoding]::UTF8))}
                Check ('155-reader public Stop preserves snippets and ancestor-only proof '+$hostName) ($proc.ExitCode-eq0-and$err-eq''-and$out.Contains($reviewBase)-and$out-match'systemMessage'-and$out-notmatch'"decision"'-and$lines.Count-eq6-and$lines[0]-ceq$reviewFinal-and$lines[3]-ceq'docs-only-carryover'-and$lines[4]-ceq$reviewBase) ($out+$err+($lines-join'|'))
                $proc.Dispose()
            }
        }
    }
    finally {
        if ($null -ne $token) { Exit-TestStateIsolation -Token $token }
        $env:PATH = $savedPath
        if ($null -eq $savedBase) { Remove-Item Env:GH_DOCS_BASE -ErrorAction SilentlyContinue } else { $env:GH_DOCS_BASE = $savedBase }
    }
}
