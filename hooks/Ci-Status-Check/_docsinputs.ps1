# Size is not evidence of a consumer. Discover relevant inputs across the full
# tracked tree, including vendor/tests; unreadable or incomplete scope is unknown.
. (Join-Path $PSScriptRoot '_docsquery.ps1')
. (Join-Path $PSScriptRoot '_docsreviewed.ps1')
# Recognize a fully consumed Cargo-generated data subset, not a suffix waiver.
# Escapes, unknown tables/keys and other TOML forms stay unknown; no evaluation.
function Test-DocsCargoLockData {
    param([string]$Path, [string[]]$Lines)
    if ([IO.Path]::GetFileName($Path) -cne 'Cargo.lock') { return $false }
    $version = $false; $package = $false; $array = $false; $count = 0; $fields = @{}
    $quoted = '"[^"\\\x00-\x1f]*"'
    foreach ($raw in $Lines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($array) {
            if ($line -eq ']') { $array = $false; continue }
            if ($arrayLast -or $line -notmatch ('^' + $quoted + ',?$')) { return $false }
            $arrayLast = -not $line.EndsWith(',')
            continue
        }
        if ($line -ceq '[[package]]') {
            if (-not $version -or ($package -and (-not $fields.ContainsKey('name') -or -not $fields.ContainsKey('version')))) { return $false }
            $package = $true; $count++; $fields = @{}; continue
        }
        if (-not $package) {
            if ($version -or $line -cnotmatch '^version = [34]$') { return $false }
            $version = $true; continue
        }
        if ($line -cnotmatch '^(name|version|source|checksum|replace|dependencies) = (.+)$') { return $false }
        $key = $Matches[1]; $value = $Matches[2]
        if ($fields.ContainsKey($key)) { return $false }
        $fields[$key] = $true
        if ($key -eq 'dependencies') {
            if ($value -eq '[') { $array = $true; $arrayLast = $false; continue }
            if ($value -notmatch ('^\[\s*(?:' + $quoted + '\s*,\s*)*(?:' + $quoted + '\s*)?\]$')) { return $false }
        }
        elseif ($value -notmatch ('^' + $quoted + '$')) { return $false }
        elseif ($key -eq 'name' -and $value -notmatch '^"[A-Za-z0-9_-]+"$') { return $false }
        elseif ($key -eq 'version' -and $value -notmatch '^"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?"$') { return $false }
        elseif ($key -eq 'checksum' -and $value -notmatch '^"[a-f0-9]{64}"$') { return $false }
    }
    return ($version -and $count -gt 0 -and -not $array -and $fields.ContainsKey('name') -and $fields.ContainsKey('version'))
}

function Test-DocsHaveSemanticConsumers {
    param([string]$ProjectRoot, [string]$Sha, [string[]]$Files, [string]$RepoSlug = '')
    $script:DocsCarryoverReason = 'unknown: documentation consumer evidence incomplete'
    $paths = @(Invoke-DocsGitQuery @('-C',$ProjectRoot,'ls-tree','-r','--name-only',$Sha))
    if ($LASTEXITCODE -ne 0) { return $true }
    $config = @($paths | Where-Object { $_ -match '(^|/)(mkdocs\.ya?ml|conf\.py|docusaurus\.config\.[^/]+|book\.toml|\.readthedocs\.ya?ml)$' })
    if ($config.Count -gt 0) { $script:DocsCarryoverReason = 'semantic: documentation toolchain configuration'; return $true }
    # Literal references include basenames (relative/constructed paths). Markdown
    # references stay candidates: embedded code/imports cannot be excluded by suffix.
    $literalArgs = @('-C',$ProjectRoot,'grep','--threads=1','-I','-l','-i','-F')
    foreach ($file in $Files) {
        $literalArgs += @('-e',$file,'-e',[IO.Path]::GetFileName($file))
    }
    $literal = @(Invoke-DocsGitQuery ($literalArgs + @($Sha,'--')))
    if ($LASTEXITCODE -notin @(0,1)) { return $true }
    # Reader discovery does not require docs vocabulary. A generic walker can
    # reach a changed document without ever spelling its name or extension.
    $readerPattern = 'readFile|read_text|read_bytes|ReadAllText|Get-Content|open[[:space:]]*\(|fopen|ifstream|File\.read|File\.Read|rglob[[:space:]]*\(|glob[[:space:]]*\(|include_str!|include_bytes!|read_dir|walkdir|os\.walk|readdir|ls-files|ls-tree|doctest|remark-extract|mdx|markdown-loader|md-loader|long_description|readme[[:space:]]*=|sphinx|mkdocs|docusaurus|mdbook|markdown|docs[/\\]|["'']docs["'']'
    $readers = @(Invoke-DocsGitQuery @('-C',$ProjectRoot,'grep','--threads=1','-I','-l','-i','-E','-e',$readerPattern,$Sha,'--'))
    if ($LASTEXITCODE -notin @(0,1)) { return $true }
    $matches = @(@($literal) + @($readers) | Sort-Object -Unique | Where-Object { $_ -cne ($Sha + ':.hookmaker-docs-policy.json') })
    if ($matches.Count -gt 100) { $script:DocsCarryoverReason = 'unknown: more than 100 relevant reader/reference candidates; input scope not fully verified'; return $true }
    $bytes = 0
    $candidates = New-Object Collections.Generic.List[object]
    foreach ($match in $matches) {
        if (-not ([string]$match).StartsWith($Sha + ':', [StringComparison]::Ordinal)) { return $true }
        $path = ([string]$match).Substring($Sha.Length + 1)
        $lines = @(Invoke-DocsGitQuery @('-C',$ProjectRoot,'show',($Sha + ':' + $path)))
        if ($LASTEXITCODE -ne 0) { return $true }
        $text = $lines -join "`n"; $bytes += [Text.Encoding]::UTF8.GetByteCount($text)
        if ($bytes -gt 1048576) { $script:DocsCarryoverReason = 'unknown: relevant consumer content exceeds 1 MiB'; return $true }
        $candidates.Add([pscustomobject]@{Path=$path;Lines=$lines;Text=$text;Bytes=[Text.Encoding]::UTF8.GetByteCount($text);Match=$match})
    }
    # Review covers every discovered candidate and the whole exact tree, including
    # transitive readers. It is not inferred from open/read/UTF8 vocabulary.
    if (Test-DocsReviewedInputScope -ProjectRoot $ProjectRoot -RepoSlug $RepoSlug -Sha $Sha -Files $Files -Candidates $candidates.ToArray()) {
        $script:DocsCarryoverReason = ''; return $false
    }
    foreach ($candidate in $candidates) {
        $path=$candidate.Path; $lines=$candidate.Lines; $text=$candidate.Text; $match=$candidate.Match
        # Dependency names are not executable reader operations. Literal changed-doc
        # references still require proof; data classification does not certify consumers.
        if ($literal -notcontains $match -and (Test-DocsCargoLockData $path $lines)) { continue }
        # Plain prose links are references, not reads. Embedded executable blocks
        # and include directives remain unknown, including inside vendor Markdown.
        if ($path -match '\.(md|txt)$' -and $text -notmatch '```|~~~|(?i)(include|doctest|mdx|<script)') { continue }
        # Encoding vocabulary alone never proves hygiene: a decoder can pass its
        # result into a semantic assertion through an arbitrary variable name.
        if ($text -match '(?i)(doctest|markdown[-_ ]?doctest|remark-extract|mdx|markdown-loader|md-loader|embed.*\.md|include_str!.*\.md|sphinx|mkdocs|docusaurus|mdbook|long_description|readme\s*=)') {
            $script:DocsCarryoverReason = 'semantic: documentation build/test/package input in ' + $path
            return $true
        }
        if ($readers -contains $match) {
            $script:DocsCarryoverReason = 'unknown: reader input scope not proven disjoint or hygiene-only in ' + $path
            return $true
        }
        foreach ($line in $lines) {
            if ($line -match '(?i)(prettier|markdownlint|format:|format:check)' -and $line -notmatch '(?i)(--plugin|--config)') { continue }
            foreach ($file in $Files) {
                if (($line.IndexOf($file, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $line.IndexOf([IO.Path]::GetFileName($file), [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                    $script:DocsCarryoverReason = 'semantic: changed document reference in ' + $path
                    return $true
                }
            }
        }
    }
    $script:DocsCarryoverReason = ''
    return $false
}
