# Local branch names are not the remote protection destination. Resolve once
# per carryover from current refs/config; never memoize this mutable identity.
function Get-CiCarryoverDestination {
    param([string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,[string]$Branch)
    $rows=@(Invoke-DocsGit @('-C',$ProjectRoot,'for-each-ref','--format=%(refname:short)|%(upstream:remotename)|%(upstream:remoteref)|%(upstream:short)|%(objectname)',('refs/heads/'+$Branch)))
    if($LASTEXITCODE-ne0-or$rows.Count-ne1){return ''}
    $parts=([string]$rows[0]).Split('|')
    if($parts.Count-ne5-or$parts[0]-cne$Branch-or$parts[1]-cnotmatch'^[A-Za-z0-9_.-]+$'-or
        $parts[2]-cnotmatch'^refs/heads/(.+)$'-or$parts[4]-cne$Sha){return ''}
    $destination=$parts[2].Substring(11)
    if($destination-cne$Branch-or$parts[3]-cne($parts[1]+'/'+$destination)){return ''}
    $url=(@(Invoke-DocsGit @('-C',$ProjectRoot,'remote','get-url',$parts[1]))-join'').Trim()
    if($LASTEXITCODE-ne0-or$url-cnotmatch'^(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$'-or
        ($Matches[1]+'/'+$Matches[2])-ine$RepoSlug){return ''}
    return $destination
}
