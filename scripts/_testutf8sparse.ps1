param([switch]$RunRegression,[switch]$SmokeOnly)

function Get-Utf8SparseFixture {
    $bytes=New-Object byte[] 47961
    for($i=0;$i-lt$bytes.Length;$i++){$bytes[$i]=97}
    $prefix='2320e69687e4bbb6e6bc8fe6b49e0a0a'
    for($i=0;$i-lt$prefix.Length;$i+=2){$bytes[$i/2]=[Convert]::ToByte($prefix.Substring($i,2),16)}
    foreach($i in @(1250,4026,37208,41969,42929,43207,43684,43732)){$bytes[$i]=0}
    return ,$bytes
}

function Invoke-Utf8SparseRegression {
    param([string]$HooksRoot,[switch]$SmokeOnly)
    . (Join-Path $HooksRoot 'Utf8-Encoding-Check/_detection.ps1')
    . (Join-Path $HooksRoot 'Utf8-Encoding-Check/_classification.ps1')
    . (Join-Path $HooksRoot 'Utf8-Encoding-Check/_streamvalidation.ps1')
    $bytes=Get-Utf8SparseFixture
    Check 'complete sparse NUL UTF8 is not inferred UTF16' ((Get-Utf8Classification $bytes)-ceq'utf8')
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try{Check 'stream validates sparse NUL text through its final byte' ((Read-Utf8StreamClassification $stream $bytes.Length 64MB ([DateTime]::UtcNow.AddSeconds(5)))-ceq'utf8')}
    finally{$stream.Dispose()}
    $oid='a'*40
    $wire=[Text.Encoding]::ASCII.GetBytes($oid+' blob '+$bytes.Length+"`n")+$bytes+[byte[]]@(10)
    $stream=[IO.MemoryStream]::new([byte[]]$wire,$false)
    try{Check 'raw Git frame validates sparse NUL UTF8' ((Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(10))).Class-ceq'utf8')}
    finally{$stream.Dispose()}
    $quoted='"web/\346\226\207\344\273\266\346\274\217\346\264\236.md"'
    $path='web/'+[char]0x6587+[char]0x4ef6+[char]0x6f0f+[char]0x6d1e+'.md'
    Check 'Git octal UTF8 path preserves exact identity' ((ConvertFrom-GitQuotedPath $quoted)-ceq$path)
    if($SmokeOnly){return}
    $bad=[byte[]]$bytes.Clone();$bad[$bad.Length-1]=0xc3
    Check 'sparse NUL never hides invalid UTF8 tail' ((Get-Utf8Classification $bad)-ceq'invalid')
    $stream=[IO.MemoryStream]::new($bad,$false)
    try{Check 'stream sparse NUL invalid tail refuses' ((Read-Utf8StreamClassification $stream $bad.Length 64MB ([DateTime]::UtcNow.AddSeconds(5)))-ceq'invalid')}
    finally{$stream.Dispose()}
    $wire=[Text.Encoding]::ASCII.GetBytes($oid+' blob '+$bad.Length+"`n")+$bad+[byte[]]@(10)
    $stream=[IO.MemoryStream]::new([byte[]]$wire,$false)
    try{Check 'raw Git sparse NUL invalid final sequence refuses' ((Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(5))).Class-ceq'invalid')}
    finally{$stream.Dispose()}
    Check 'sparse NUL incomplete prefix remains unknown' ((Get-Utf8Classification $bytes[0..8191] $true)-ceq'oversized')
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try{Check 'sparse NUL capped stream is never validated' ((Read-Utf8StreamClassification $stream $bytes.Length 8192 ([DateTime]::UtcNow.AddSeconds(5)))-ceq'oversized')}
    finally{$stream.Dispose()}
    $wire=[Text.Encoding]::ASCII.GetBytes($oid+' blob '+$bytes.Length+"`n")+$bytes[0..8191]
    $stream=[IO.MemoryStream]::new([byte[]]$wire,$false)
    $refused=$false
    try{$null=Read-Utf8BatchFrame $stream $oid 64MB ([DateTime]::UtcNow.AddSeconds(5))}catch{$refused=$true}finally{$stream.Dispose()}
    Check 'raw Git sparse NUL incomplete body refuses' $refused
    foreach($zeroCount in @(3,4)){
        $boundary=[Text.Encoding]::ASCII.GetBytes('a'*64)
        for($i=0;$i-lt$zeroCount;$i++){$boundary[2*$i]=0}
        $want=if($zeroCount-eq3){'utf8'}else{'utf16be'}
        Check ('NUL density boundary '+$zeroCount+'/64') ((Get-Utf8Classification $boundary)-ceq$want)
    }
    $mixed=[byte[]]$bytes.Clone();$mixed[1251]=0
    Check 'sparse NULs on both parities are still strictly decoded' ((Get-Utf8Classification $mixed)-ceq'utf8')
    Check 'dense binary remains binary' ((Get-Utf8Classification ([byte[]]@(137,80,78,71,0,0,0,13,255,216,0,51,17,0,66,67)))-ceq'binary')
    foreach($encoding in @([Text.UnicodeEncoding]::new($false,$false,$true),[Text.UnicodeEncoding]::new($true,$false,$true))){
        $text=$encoding.GetBytes('genuine UTF16 without BOM')
        $want=if($encoding.CodePage-eq1201){'utf16be'}else{'utf16le'}
        Check ('dense '+$want+' remains nonUTF8') ((Get-Utf8Classification $text)-ceq$want)
    }
    $exceptions=@([pscustomobject]@{Path=$path;IsGlob=$false})
    Check 'decoded exact path matches only its real exception' ((Test-ExceptionMatch $exceptions (ConvertFrom-GitQuotedPath $quoted))-and-not(Test-ExceptionMatch $exceptions 'web/346/226/207.md'))
    foreach($malformed in @('"bad\12"','"bad\400"','"bad\q"','"bad\N"','"bad\377"','"bad\000"','"bad"tail"')){
        $refused=$false;try{$null=ConvertFrom-GitQuotedPath $malformed}catch{$refused=$true}
        Check 'malformed Git path cannot invent exception identity' $refused
    }
}
if($RunRegression){
    $script:Pass=0;$script:Fail=0
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    Invoke-Utf8SparseRegression (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks') -SmokeOnly:$SmokeOnly
    Write-Output ('Passed: '+$script:Pass+' Failed: '+$script:Fail)
    exit $script:Fail
}
