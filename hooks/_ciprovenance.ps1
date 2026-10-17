# Versioned CI observations: legacy labels and observation time are not execution proof.
function ConvertTo-CiUtcTime {
    param($Value)
    if($Value -is [DateTimeOffset]){return $Value.ToUniversalTime()}
    if($Value -is [DateTime]){return [DateTimeOffset]($Value.ToUniversalTime())}
    $parsed=[DateTimeOffset]::MinValue
    if($Value -isnot [string]-or$Value-notmatch'(?:Z|[+-]\d{2}:\d{2})$'-or
        -not[DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){return $null}
    return $parsed.ToUniversalTime()
}

# Carryover coordinates a notice only; it never excuses a failed test or proves CI.
function Read-CiCarryover {
    param([string[]]$Lines,[string]$Repository='',[string]$Sha='',[switch]$NoticeIdentityOnly)
    try {
        if($Lines.Count-ne6-or$Lines[1]-cne'verified'-or$Lines[3]-cne'docs-only-carryover'-or
            $Lines[0]-cnotmatch'^[a-f0-9]{40}$'-or$Lines[4]-cnotmatch'^[a-f0-9]{40}$'-or$Lines[5].Length-gt65536){return $null}
        $proof=$Lines[5]|ConvertFrom-Json -ErrorAction Stop
        $time=ConvertTo-CiUtcTime $Lines[2];$observed=ConvertTo-CiUtcTime $proof.observedUtc
        $now=[DateTimeOffset]::UtcNow
        if($proof.schema-ne1-or$proof.sha-cne$Lines[0]-or$proof.parent-cne$Lines[4]-or
            $proof.outcome-cne'docs-only-carryover'-or$proof.repository-cnotmatch'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'-or
            $proof.sourceFingerprint-cnotmatch'^[a-f0-9]{64}$'-or
            ($Repository-ne''-and$proof.repository-ine$Repository)-or($Sha-ne''-and$proof.sha-cne$Sha)-or
            $null-eq$time-or$time-ne$observed-or$time-gt$now-or(-not$NoticeIdentityOnly-and($now-$time).TotalMinutes-ge1)){return $null}
        return $proof
    }catch{return $null}
}

function Read-CiProvenance {
    param([string[]]$Lines,[string]$Repository,[string]$Sha,$FailureEndedUtc=$null)
    try {
        if($Lines.Count-ne5-or$Lines[0]-cne$Sha-or$Lines[1]-cne'verified'-or$Lines[3]-cne'ci-green'-or
            $Sha-cnotmatch'^(?:[a-f0-9]{40}|[a-f0-9]{64})$'-or$Lines[4].Length-gt65536){return $null}
        $proof=$Lines[4]|ConvertFrom-Json -ErrorAction Stop
        if($proof.schema-ne1-or$proof.repository-ine$Repository-or$proof.sha-cne$Sha-or$proof.outcome-cne'ci-green'-or
            $proof.workloadFingerprint-cnotmatch'^[a-f0-9]{64}$'-or$proof.sourceFingerprint-cnotmatch'^[a-f0-9]{64}$'){return $null}
        $observed=ConvertTo-CiUtcTime $proof.observedUtc
        $completed=ConvertTo-CiUtcTime $proof.completedUtc
        $lineTime=ConvertTo-CiUtcTime $Lines[2]
        $now=[DateTimeOffset]::UtcNow
        if($null-eq$observed-or$null-eq$completed-or$null-eq$lineTime-or$lineTime-ne$observed-or
            $observed-gt$now-or($now-$observed).TotalMinutes-gt60-or$completed-gt$observed){return $null}
        $runs=@($proof.runs)
        if($runs.Count-lt1-or$runs.Count-gt50){return $null}
        $ids=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $oldest=[DateTimeOffset]::MaxValue
        foreach($run in $runs){
            if([string]$run.id-cnotmatch'^[1-9][0-9]*$'-or[string]$run.attempt-cnotmatch'^[1-9][0-9]*$'-or
                [string]$run.workflowId-cnotmatch'^[1-9][0-9]*$'-or$run.path-cnotmatch'^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$'-or
                $run.event-cnotin@('workflow_dispatch','push','pull_request')-or[string]::IsNullOrWhiteSpace([string]$run.branch)-or
                -not$ids.Add([string]$run.id)){return $null}
            $end=ConvertTo-CiUtcTime $run.completedUtc
            if($null-eq$end-or$end-gt$observed){return $null}
            if($end-lt$oldest){$oldest=$end}
        }
        # Every required workflow, not just the newest, must postdate the failure.
        if($completed-ne$oldest){return $null}
        if($null-ne$FailureEndedUtc){
            $failure=ConvertTo-CiUtcTime $FailureEndedUtc
            if($null-eq$failure-or$completed-le$failure){return $null}
        }
        return $proof
    }catch{return $null}
}
