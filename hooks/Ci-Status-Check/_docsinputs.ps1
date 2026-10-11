# Size is not evidence of a consumer. Discover relevant inputs across the full
# tracked tree, including vendor/tests; unreadable or incomplete scope is unknown.
. (Join-Path $PSScriptRoot '_docsquery.ps1')
function Test-DocsHaveSemanticConsumers {
    param([string]$ProjectRoot, [string]$Sha, [string[]]$Files)
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
    $matches = @(@($literal) + @($readers) | Sort-Object -Unique)
    if ($matches.Count -gt 100) { $script:DocsCarryoverReason = 'unknown: more than 100 relevant reader/reference candidates; input scope not fully verified'; return $true }
    $bytes = 0
    foreach ($match in $matches) {
        if (-not ([string]$match).StartsWith($Sha + ':', [StringComparison]::Ordinal)) { return $true }
        $path = ([string]$match).Substring($Sha.Length + 1)
        $lines = @(Invoke-DocsGitQuery @('-C',$ProjectRoot,'show',($Sha + ':' + $path)))
        if ($LASTEXITCODE -ne 0) { return $true }
        $text = $lines -join "`n"; $bytes += [Text.Encoding]::UTF8.GetByteCount($text)
        if ($bytes -gt 1048576) { $script:DocsCarryoverReason = 'unknown: relevant consumer content exceeds 1 MiB'; return $true }
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
