# Offline raw API adapter. Legacy fixture inputs are expanded to explicit metadata
# here, never in production. Every response is bound to the queried fixture SHA.
$mockDir=$env:GH_MOCK_DIR
if(-not$mockDir){exit 1}
$a=@($args)
Add-Content -LiteralPath (Join-Path $mockDir 'calls.txt') -Value ($a-join'|') -Encoding UTF8
function Emit-File {param($Path) Write-Output ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8));exit 0}
if($a.Count-ge2-and$a[0]-eq'auth'-and$a[1]-eq'status'){
    $f=Join-Path $mockDir 'auth_exit.txt';$code=if(Test-Path $f){[int]([IO.File]::ReadAllText($f).Trim())}else{0}
    if($code-ne0){[Console]::Error.WriteLine('You are not logged into any GitHub hosts.')};exit $code
}
if($a.Count-ge2-and$a[0]-eq'pr'-and$a[1]-eq'list'){
    $e=Join-Path $mockDir 'pr_exit.txt';if(Test-Path $e){exit ([int]([IO.File]::ReadAllText($e).Trim()))}
    $f=Join-Path $mockDir 'pr_list.json';if(Test-Path $f){Emit-File $f};Write-Output '[]';exit 0
}
if($a.Count-lt2-or$a[0]-ne'api'){exit 1}
$endpoint=[string]$a[1];$page=1
if($endpoint-match'[?&]page=(\d+)'){$page=[int]$Matches[1]}
if($endpoint-match'^repos/([^/]+/[^/]+)/actions/runs\?head_sha=([a-f0-9]+)'){
    $repo=$Matches[1];$sha=$Matches[2]
    [IO.File]::WriteAllText((Join-Path $mockDir 'received_sha.txt'),$sha,[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $mockDir 'api-identity.json'),(@{repo=$repo;sha=$sha}|ConvertTo-Json),[Text.Encoding]::UTF8)
    $f=Join-Path $mockDir 'run_list.json';$raw=if(Test-Path $f){[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)}else{'[]'}
    if([string]::IsNullOrWhiteSpace($raw)-or$raw.Trim()-eq'null'){Write-Output $raw;exit 0}
    $items=@($raw|ConvertFrom-Json);$runs=@()
    $expectedFile=Join-Path $mockDir 'expected_sha.txt'
    if(Test-Path $expectedFile){$expected=[IO.File]::ReadAllText($expectedFile).Trim();if($expected-cne$sha){[IO.File]::WriteAllText((Join-Path $mockDir 'sha_mismatch.txt'),'mismatch',[Text.Encoding]::UTF8)}}
    foreach($r in $items){
        $runs+=@{id=$r.databaseId;workflow_id=9;run_attempt=$(if($r.attempt){$r.attempt}else{1});name=$r.workflowName;head_sha=$sha;head_repository=@{full_name=$repo};repository=@{full_name=$repo};path='.github/workflows/ci.yml';event='workflow_dispatch';head_branch='main';status=$r.status;conclusion=$r.conclusion;updated_at='2026-10-17T10:00:00Z'}
    }
    Write-Output (@{total_count=$runs.Count;workflow_runs=$runs}|ConvertTo-Json -Depth 8 -Compress);exit 0
}
if($endpoint-match'/actions/runs/(\d+)/attempts/(\d+)/jobs'){
    $id=$Matches[1];$attempt=$Matches[2];$identity=Get-Content (Join-Path $mockDir 'api-identity.json') -Raw|ConvertFrom-Json
    $end=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
    Write-Output (@{total_count=1;jobs=@(@{id=([long]$id+1000);check_run_url=('https://api.github.com/repos/'+$identity.repo+'/check-runs/1');run_id=[long]$id;run_attempt=[int]$attempt;head_sha=$identity.sha;name='validate';status='completed';conclusion='success';completed_at=$end;steps=@(@{number=1;name='Validate';status='completed';conclusion='success';completed_at='2026-10-17T08:59:00Z'})})}|ConvertTo-Json -Depth 8 -Compress);exit 0
}
if($endpoint-match'/commits/([a-f0-9]{40})/status'){
    Write-Output (@{sha=$Matches[1];total_count=0;state='pending';statuses=@()}|ConvertTo-Json -Depth 4 -Compress);exit 0
}
if($endpoint-match'/commits/[^/]+/check-runs'){
    $pf=Join-Path $mockDir ('checkruns-page-'+$page+'.json');if(Test-Path $pf){Emit-File $pf}
    $f=Join-Path $mockDir 'checkruns.json';if($page-eq1-and(Test-Path $f)){Emit-File $f}
    if($page-gt1){Write-Output '{"total_count":0,"check_runs":[]}';exit 0}
    $commit=[regex]::Match($endpoint,'/commits/([a-f0-9]{40})/').Groups[1].Value
    Write-Output (@{total_count=1;check_runs=@(@{id=1;head_sha=$commit;status='completed';conclusion='success'})}|ConvertTo-Json -Depth 5 -Compress)
    exit 0
}
if($endpoint-match'/check-runs/([^/]+)/annotations'){
    $id=$Matches[1]
    foreach($name in @("annexit-$id-page-$page.txt","annexit-$id.txt",'annexit.txt')){$f=Join-Path $mockDir $name;if(Test-Path $f){exit ([int]([IO.File]::ReadAllText($f).Trim()))}}
    foreach($name in @("annotations-$id-page-$page.json",$(if($page-eq1){"annotations-$id.json"}else{'absent'}))){$f=Join-Path $mockDir $name;if(Test-Path $f){Emit-File $f}}
    Write-Output '[]';exit 0
}
exit 1
