# Exact-root owner approval. Repository files and global Git config are never written.
function Get-RepositoryIdentityHash {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-RepositoryOwnerIdentity {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-RepositoryPhysicalRoot {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    if (-not [IO.Directory]::Exists($full) -or $full.Contains('*') -or $full.Contains('?')) { throw 'Repository root must be an existing exact directory.' }
    # Unresolved/changed links cannot inherit an approval for a lexical alias.
    $probe=$full
    while($probe) {
        if(([IO.File]::GetAttributes($probe)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Repository root contains a reparse point; select its verified physical root explicitly.'}
        $parent=[IO.Directory]::GetParent($probe)
        if($null-eq$parent){break};$probe=$parent.FullName
    }
    return $full
}

function Get-RepositoryApprovalIdentity {
    param([string]$Root)
    $physical=Get-RepositoryPhysicalRoot $Root
    $marker=Join-Path $physical '.git'
    if(-not [IO.File]::Exists($marker)-and-not[IO.Directory]::Exists($marker)){throw 'Approval requires the exact repository root, not a parent or nested folder.'}
    if(([IO.File]::GetAttributes($marker)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Repository metadata cannot be a reparse point.'}
    $gitDir=$marker
    if([IO.File]::Exists($marker)) {
        $text=[IO.File]::ReadAllText($marker,(New-Object Text.UTF8Encoding($false,$true)))
        if($text-notmatch'^gitdir: ([^\r\n]+)\s*$'){throw 'Repository worktree metadata is invalid.'}
        $gitDir=$matches[1];if(-not[IO.Path]::IsPathRooted($gitDir)){$gitDir=Join-Path $physical $gitDir}
    }
    $gitDir=Get-RepositoryPhysicalRoot $gitDir
    $id=Get-RepositoryIdentityHash ($physical.ToLowerInvariant()+'|'+$gitDir.ToLowerInvariant()+'|'+[IO.Directory]::GetCreationTimeUtc($physical).Ticks+'|'+[IO.Directory]::GetCreationTimeUtc($gitDir).Ticks+'|'+[IO.File]::GetCreationTimeUtc($marker).Ticks)
    return [pscustomobject]@{Root=$physical;GitDirectory=$gitDir;Identity=$id;Owner=Get-RepositoryOwnerIdentity}
}

function Get-RepositoryApprovalPath {
    param([string]$Root)
    $state=[string]$env:HOOKMAKER_STATE_DIR
    if([string]::IsNullOrWhiteSpace($state)){$state=Join-Path $env:LOCALAPPDATA 'HookMaker/state'}
    return Join-Path (Join-Path $state 'repository-approvals') ((Get-RepositoryIdentityHash $Root.ToLowerInvariant())+'.json')
}

function Test-RepositoryRootApproval {
    param($Identity)
    $path=Get-RepositoryApprovalPath $Identity.Root
    if(-not[IO.File]::Exists($path)){return $false}
    try {
        if(([IO.File]::GetAttributes($path)-band[IO.FileAttributes]::ReparsePoint)-ne0-or([IO.FileInfo]$path).Length-gt16384){return $false}
        $doc=[IO.File]::ReadAllText($path,(New-Object Text.UTF8Encoding($false,$true)))|ConvertFrom-Json
        return ($doc.schema-eq1-and$doc.root-ceq$Identity.Root-and$doc.gitDirectory-ceq$Identity.GitDirectory-and$doc.repositoryIdentity-ceq$Identity.Identity-and$doc.ownerIdentity-ceq$Identity.Owner)
    } catch {return $false}
}

function Set-RepositoryRootApproval {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot,[switch]$Approve,[switch]$Revoke,[switch]$OwnerConfirmed)
    if($Approve-eq$Revoke){throw 'Choose exactly one approval or revocation action.'}
    if($Approve-and-not$OwnerConfirmed){throw 'Explicit repository owner approval is required; project selection alone is not approval.'}
    $identity=Get-RepositoryApprovalIdentity $ProjectRoot
    $path=Get-RepositoryApprovalPath $identity.Root;$dir=Split-Path -Parent $path
    [void][IO.Directory]::CreateDirectory($dir)
    [void](Get-RepositoryPhysicalRoot $dir)
    foreach ($target in @($path,$path+'.lock')) {
        if ([IO.File]::Exists($target) -and ([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Approval state cannot be a reparse point.' }
    }
    $lock=$null;$tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $lock=[IO.File]::Open($path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if($Revoke){if([IO.File]::Exists($path)){[IO.File]::Delete($path)};return}
        $doc=[ordered]@{schema=1;root=$identity.Root;gitDirectory=$identity.GitDirectory;repositoryIdentity=$identity.Identity;ownerIdentity=$identity.Owner;approvedUtc=[DateTime]::UtcNow.ToString('o')}
        [IO.File]::WriteAllText($tmp,($doc|ConvertTo-Json),(New-Object Text.UTF8Encoding $false))
        if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[NullString]::Value)}else{[IO.File]::Move($tmp,$path)}
        if(-not(Test-RepositoryRootApproval $identity)){throw 'Repository approval publication could not be verified.'}
    } finally {if($lock){$lock.Dispose()};if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
