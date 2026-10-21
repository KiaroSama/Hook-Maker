# Enrollment binds reviewed INPUT to a physical repository/ref, never to a run.
function Get-CiEnrollmentContext {
    param([string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,[string]$Branch,[string]$Remote)
    try {
        $root=Get-RepositoryPhysicalRoot $ProjectRoot
        $identity=@(Invoke-DocsGit @('-C',$root,'rev-parse','--show-toplevel','HEAD','--abbrev-ref','HEAD'))
        if($LASTEXITCODE-ne0-or$identity.Count-ne3){return $null}
        # rev-parse emits one value for each requested expression/option.
        if((Normalize-Path $identity[0])-ine(Normalize-Path $root)-or$identity[1]-cne$Sha-or$identity[2]-cne$Branch){return $null}
        if($Remote-cnotmatch'^[A-Za-z0-9_.-]+$'){return $null}
        $url=@(Invoke-DocsGit @('-C',$root,'remote','get-url',$Remote))
        if($LASTEXITCODE-ne0-or$url.Count-ne1-or$url[0]-notmatch'^(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$'){return $null}
        if(($Matches[1]+'/'+$Matches[2])-ine$RepoSlug){return $null}
        $configured=@(Invoke-DocsGit @('-C',$root,'config','--get',('branch.'+$Branch+'.remote')))
        if($LASTEXITCODE-ne0-or$configured.Count-ne1-or$configured[0]-cne$Remote){return $null}
        $merge=@(Invoke-DocsGit @('-C',$root,'config','--get',('branch.'+$Branch+'.merge')))
        if($LASTEXITCODE-ne0-or$merge.Count-ne1-or$merge[0]-cnotmatch'^refs/heads/[^\r\n]+$'){return $null}
        return [pscustomobject]@{version=1;root=$root;repository=$RepoSlug;commit=$Sha;branch=$Branch;remote=$Remote;remoteFingerprint=Get-RepositoryIdentityHash ($url[0]+'|'+$merge[0])}
    }catch{return $null}
}
function Get-CiReviewedInputFingerprint {
    param($Policy)
    $copy=$Policy|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $copy.PSObject.Properties.Remove('enrollment')
    return Get-RepositoryIdentityHash ($copy|ConvertTo-Json -Depth 30 -Compress)
}
function Test-CiEnrollmentBinding {
    param($Enrollment,[string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,[string]$Branch)
    try {
        if($Enrollment.version-ne1-or$Enrollment.repository-ine$RepoSlug-or$Enrollment.commit-cne$Sha-or$Enrollment.branch-cne$Branch){return $false}
        $actual=Get-CiEnrollmentContext $ProjectRoot $RepoSlug $Sha $Branch ([string]$Enrollment.remote)
        return $null-ne$actual-and$actual.root-ceq$Enrollment.root-and$actual.remoteFingerprint-ceq$Enrollment.remoteFingerprint
    }catch{return $false}
}
