# Closed workflow subset, not a general YAML parser. Every mapping is consumed;
# unknown structure refuses instead of deriving expectations from green API rows.
function Read-CiLiteralScalar {
    param([string]$Value)
    if($Value.Length-gt1024-or$Value-cnotmatch'^[A-Za-z0-9_./@ ()$=-][A-Za-z0-9_./@ ()$=:+-]*$'){throw 'Unsupported scalar'}
    return $Value
}
function Read-CiLiteralFields {
    param([string[]]$Lines,[int]$Indent)
    $fields=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    for($i=0;$i-lt$Lines.Count;$i++){
        $line=$Lines[$i]
        if($line.Trim()-eq''-or$line.TrimStart().StartsWith('#')){continue}
        if($line-cnotmatch('^ {'+$Indent+'}([A-Za-z][A-Za-z0-9_-]*):(?: +(.*))?$')){throw 'Unsupported mapping'}
        $key=$Matches[1];$value=[string]$Matches[2]
        if($fields.ContainsKey($key)){throw 'Duplicate mapping'}
        $body=New-Object Collections.Generic.List[string]
        while($i+1-lt$Lines.Count){
            $next=$Lines[$i+1]
            if($next.Trim()-ne''-and($next.Length-$next.TrimStart(' ').Length)-le$Indent){break}
            $i++;$body.Add($next)
        }
        $fields.Add($key,[pscustomobject]@{Value=$value;Body=$body.ToArray()})
    }
    return ,$fields
}
function Assert-CiLiteralKeys {
    param($Fields,[string[]]$Allowed)
    foreach($key in $Fields.Keys){if($Allowed-cnotcontains$key){throw 'Unsupported key'}}
}
function Read-CiLiteralStringMap {
    param($Field,[int]$Indent,[switch]$Permissions)
    if($Field.Value-ne''){throw 'Unsupported map value'}
    $map=Read-CiLiteralFields $Field.Body $Indent
    if($map.Count-eq0){throw 'Empty map'}
    foreach($key in $map.Keys){
        if($map[$key].Body.Count){throw 'Nested map'}
        if($Permissions){if($map[$key].Value-cnotin@('read','write','none')){throw 'Unsupported permission'}}
        else{[void](Read-CiLiteralScalar $map[$key].Value)}
    }
}
function Get-CiLiteralStepCondition {
    param([string]$Condition,[string]$Os)
    if($Condition-eq''){return $true}
    # Only runner OS predicates: no event/ref/input/needs/status approximation.
    if($Condition-cnotmatch"^(?:always\(\) && )?runner\.os (==|!=) '(Windows|Linux|macOS)'$"){throw 'Unsupported step condition'}
    $equal=$Os-ieq$Matches[2]
    if($Matches[1]-ceq'=='){return $equal}
    return -not$equal
}
function Read-CiLiteralSteps {
    param([string[]]$Lines,[string]$Os)
    $steps=New-Object Collections.Generic.List[object]
    $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    for($i=0;$i-lt$Lines.Count;$i++){
        if($Lines[$i].Trim()-eq''-or$Lines[$i].TrimStart().StartsWith('#')){continue}
        if($Lines[$i]-cnotmatch'^      - ([A-Za-z][A-Za-z0-9_-]*):(?: +(.*))?$'){throw 'Unsupported step'}
        $block=New-Object Collections.Generic.List[string]
        $block.Add('        '+$Lines[$i].Substring(8))
        while($i+1-lt$Lines.Count-and$Lines[$i+1]-cnotmatch'^      - '){$i++;$block.Add($Lines[$i])}
        $fields=Read-CiLiteralFields $block.ToArray() 8
        Assert-CiLiteralKeys $fields @('name','run','uses','if','with','shell','timeout-minutes','env','working-directory','id')
        if($fields.ContainsKey('run')-eq$fields.ContainsKey('uses')){throw 'Ambiguous execution'}
        foreach($key in @('name','if','shell','timeout-minutes','working-directory','id')){
            if($fields.ContainsKey($key)-and$fields[$key].Body.Count){throw 'Nested scalar'}
        }
        $uses='';$defaultName=''
        if($fields.ContainsKey('uses')){
            $uses=$fields['uses'].Value
            if($fields['uses'].Body.Count-or$uses-cnotmatch'^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[a-f0-9]{40}$'){throw 'Unsupported action'}
            $defaultName='Run '+$uses
        }else{
            $run=$fields['run']
            if($run.Value-cin@('|','|-','>','>-')){
                if($run.Body.Count-eq0){throw 'Empty script'}
                $parts=New-Object Collections.Generic.List[string]
                foreach($line in $run.Body){
                    if($line.Trim()-eq''){$parts.Add('');continue}
                    if($line-cnotmatch'^          (.*)$'){throw 'Unsupported script indent'}
                    $parts.Add($Matches[1])
                }
                # Folded multiline names are not guessed. Explicit names avoid
                # YAML folding/version/first-line ambiguity entirely.
                if($run.Value.StartsWith('>')-and-not$fields.ContainsKey('name')){throw 'Unnamed folded script'}
                $scriptText=$parts.ToArray()-join"`n"
            }else{
                if($run.Body.Count){throw 'Unexpected script body'}
                $scriptText=Read-CiLiteralScalar $run.Value
            }
            if($scriptText-match'\$\{\{|[\x00-\x08\x0b\x0c\x0e-\x1f]'){throw 'Dynamic script name'}
            $first=($scriptText.TrimStart([char[]]@(' ',"`t","`r","`n"))-split'\r?\n')[0]
            if($first-eq''-or$first.Length-gt512){throw 'Invalid script name'}
            $defaultName='Run '+$first
        }
        $name=$defaultName
        if($fields.ContainsKey('name')){$name=Read-CiLiteralScalar $fields['name'].Value}
        if($name-cin@('Set up job','Complete job')-or$name.StartsWith('Post ',[StringComparison]::Ordinal)-or
            $name.StartsWith('Pre ',[StringComparison]::Ordinal)-or-not$names.Add($name)){throw 'Ambiguous step names'}
        foreach($key in @('shell','working-directory','id')){if($fields.ContainsKey($key)){[void](Read-CiLiteralScalar $fields[$key].Value)}}
        if($fields.ContainsKey('timeout-minutes')-and$fields['timeout-minutes'].Value-cnotmatch'^[1-9][0-9]*$'){throw 'Invalid step timeout'}
        if($fields.ContainsKey('env')){Read-CiLiteralStringMap $fields['env'] 10}
        if($fields.ContainsKey('with')){
            if($uses-eq''-or$fields['with'].Value-ne''){throw 'Invalid action inputs'}
            $inputs=Read-CiLiteralFields $fields['with'].Body 10
            foreach($input in $inputs.Values){
                if($input.Value-cin@('|','|-')){
                    foreach($line in $input.Body){
                        if($line.Trim()-ne''-and$line-cnotmatch'^            [^\x00-\x1f]+$'){throw 'Unsupported input block'}
                        if($line-match'\$\{\{'){throw 'Dynamic input block'}
                    }
                }elseif($input.Body.Count-or$input.Value-eq''){throw 'Unsupported input value'}
                $literal=$input.Value.Replace('${{ matrix.os }}',$Os)
                if($literal-match'\$\{\{|^[&*!{\[]|[{}\x00-\x1f]'){throw 'Dynamic action input'}
            }
        }
        $condition=if($fields.ContainsKey('if')){$fields['if'].Value}else{''}
        $required=Get-CiLiteralStepCondition $condition $Os
        $steps.Add([pscustomobject]@{Name=$name;Required=$required;Uses=$uses})
        if($steps.Count-gt100){throw 'Step bound'}
    }
    if($steps.Count-eq0){throw 'Missing steps'}
    return $steps.ToArray()
}
function Get-CiLiteralWorkflow {
    param([string]$Text,[string]$Path,[string]$Branch)
    try{
        if($Text.Length-gt262144-or$Text.Contains("`t")){return $null}
        $top=Read-CiLiteralFields @($Text-split'\r?\n') 0
        Assert-CiLiteralKeys $top @('name','on','permissions','concurrency','env','jobs')
        foreach($required in @('on','jobs')){if(-not$top.ContainsKey($required)){return $null}}
        $trigger=$top['on']
        if($trigger.Value-ceq'[workflow_dispatch]') {if($trigger.Body.Count){return $null}}
        elseif($trigger.Value-eq''){
            $events=Read-CiLiteralFields $trigger.Body 2
            if($events.Count-ne1-or-not$events.ContainsKey('workflow_dispatch')-or$events['workflow_dispatch'].Value-ne''-or$events['workflow_dispatch'].Body.Count){return $null}
        }else{return $null}
        if($top.ContainsKey('name')){if($top['name'].Body.Count){return $null};[void](Read-CiLiteralScalar $top['name'].Value)}
        if($top.ContainsKey('permissions')){Read-CiLiteralStringMap $top['permissions'] 2 -Permissions}
        if($top.ContainsKey('env')){Read-CiLiteralStringMap $top['env'] 2}
        if($top.ContainsKey('concurrency')){
            if($top['concurrency'].Value-ne''){return $null}
            $concurrency=Read-CiLiteralFields $top['concurrency'].Body 2
            Assert-CiLiteralKeys $concurrency @('group','cancel-in-progress')
            foreach($field in $concurrency.Values){if($field.Body.Count){return $null}}
            if($concurrency.ContainsKey('cancel-in-progress')-and$concurrency['cancel-in-progress'].Value-cnotin@('true','false')){return $null}
            if($concurrency.ContainsKey('group')){[void](Read-CiLiteralScalar $concurrency['group'].Value.Replace('${{ github.ref }}','ref'))}
        }
        if($top['jobs'].Value-ne''){return $null}
        $definitions=Read-CiLiteralFields $top['jobs'].Body 2
        if($definitions.Count-eq0-or$definitions.Count-gt100){return $null}
        $jobs=New-Object Collections.Generic.List[object]
        foreach($id in $definitions.Keys){
            if($definitions[$id].Value-ne''){return $null}
            $job=Read-CiLiteralFields $definitions[$id].Body 4
            Assert-CiLiteralKeys $job @('name','runs-on','strategy','steps','timeout-minutes','env','permissions')
            foreach($required in @('runs-on','steps')){if(-not$job.ContainsKey($required)){return $null}}
            foreach($key in @('name','runs-on','timeout-minutes')){if($job.ContainsKey($key)-and$job[$key].Body.Count){return $null}}
            if($job['steps'].Value-ne''){return $null}
            if($job.ContainsKey('env')){Read-CiLiteralStringMap $job['env'] 6}
            if($job.ContainsKey('permissions')){Read-CiLiteralStringMap $job['permissions'] 6 -Permissions}
            if($job.ContainsKey('timeout-minutes')-and$job['timeout-minutes'].Value-cnotmatch'^[1-9][0-9]*$'){return $null}
            $labels=@($job['runs-on'].Value)
            if($job.ContainsKey('strategy')){
                if($job['strategy'].Value-ne''){return $null}
                $strategy=Read-CiLiteralFields $job['strategy'].Body 6
                Assert-CiLiteralKeys $strategy @('fail-fast','matrix')
                if(-not$strategy.ContainsKey('matrix')-or$strategy['matrix'].Value-ne''){return $null}
                if($strategy.ContainsKey('fail-fast')-and($strategy['fail-fast'].Body.Count-or$strategy['fail-fast'].Value-cnotin@('true','false'))){return $null}
                $matrix=Read-CiLiteralFields $strategy['matrix'].Body 8
                if($matrix.Count-ne1-or-not$matrix.ContainsKey('os')-or$matrix['os'].Body.Count-or$job['runs-on'].Value-cne'${{ matrix.os }}'){return $null}
                if($matrix['os'].Value-cnotmatch'^\[([A-Za-z0-9_.-]+(?:, *[A-Za-z0-9_.-]+)*)\]$'){return $null}
                $labels=@($Matches[1]-split', *')
                if($labels.Count-gt16-or@($labels|Select-Object -Unique).Count-ne$labels.Count){return $null}
            }
            foreach($label in $labels){
                $os=if($label-cmatch'^windows-(latest|[0-9]+)$'){'Windows'}elseif($label-cmatch'^ubuntu-(latest|[0-9]+\.[0-9]+)$'){'Linux'}elseif($label-cmatch'^macos-(latest|[0-9]+)$'){'macOS'}else{return $null}
                $steps=@(Read-CiLiteralSteps $job['steps'].Body $os)
                $name=$id
                if($job.ContainsKey('name')){$name=Read-CiLiteralScalar $job['name'].Value.Replace('${{ matrix.os }}',$label)}
                $jobs.Add([pscustomobject]@{Name=$name;Labels=@($label);MainSteps=$steps;Steps=@($steps|Where-Object{$_.Required}|ForEach-Object{$_.Name})})
                if($jobs.Count-gt100){return $null}
            }
        }
        # Label identity is independent of hosted implicit display names. Two
        # definitions requesting the same labels are ambiguous in this subset.
        $unique=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($job in $jobs){if(-not$unique.Add(($job.Labels-join'|'))){return $null}}
        return [pscustomobject]@{Path=$Path;Id='';Event='workflow_dispatch';Branch=$Branch;Jobs=$jobs.ToArray()}
    }catch{return $null}
}
function Test-CiLiteralJobSteps {
    param($Expected,$Job)
    $actual=@($Job.steps|Sort-Object {[int]$_.number})
    $main=@($Expected.MainSteps);$index=0;$setupSeen=$false;$completeSeen=$false
    $allowed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($step in $main){if($step.Uses-ne''){[void]$allowed.Add('Post '+$step.Name)}}
    foreach($step in $actual){
        if($index-lt$main.Count-and$step.name-ceq$main[$index].Name){
            $want=if($main[$index].Required){'success'}else{'skipped'}
            if($step.status-cne'completed'-or$step.conclusion-cne$want){return $false}
            $index++;continue
        }
        $setup=$index-eq0-and-not$setupSeen-and$step.name-ceq'Set up job'
        $complete=$index-eq$main.Count-and-not$completeSeen-and$step.name-ceq'Complete job'
        $cleanup=$index-eq$main.Count-and-not$completeSeen-and$allowed.Remove([string]$step.name)
        if((-not$setup-and-not$cleanup-and-not$complete)-or$step.status-cne'completed'-or$step.conclusion-cne'success'){return $false}
        if($setup){$setupSeen=$true};if($complete){$completeSeen=$true}
    }
    return $index-eq$main.Count
}
