# Conservative static eligibility, not a claim that arbitrary programs cannot
# read Markdown. Known hygiene readers are allowed; semantic/unknown consumers
# and docs toolchains reject carryover. Only bounded tracked text is inspected.
function Test-DocsHaveSemanticConsumers {
    param([string]$ProjectRoot, [string]$Sha, [string[]]$Files)
    $paths = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'ls-tree', '-r', '--name-only', $Sha))
    if ($LASTEXITCODE -ne 0 -or $paths.Count -gt 2000) { return $true }
    if (@($paths | Where-Object { $_ -match '(^|/)(mkdocs\.ya?ml|conf\.py|docusaurus\.config\.[^/]+|book\.toml|\.readthedocs\.ya?ml)$' }).Count -gt 0) { return $true }
    # One bounded git grep instead of one git show per source file. Only files
    # that mention documentation or a docs engine need consumer inspection.
    $matches = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'grep', '-I', '-l', '-i', '-E', '(\.md|docs|doctest|markdown|sphinx|mkdocs|docusaurus|mdbook)', $Sha, '--', '*.ps1', '*.py', '*.js', '*.mjs', '*.cjs', '*.ts', '*.tsx', '*.json', '*.toml', '*.yml', '*.yaml', '*.sh', '*.rb', '*.go', '*.rs', '*.cs', '*Makefile', '*Dockerfile'))
    if ($LASTEXITCODE -notin @(0, 1) -or $matches.Count -gt 100) { return $true }
    $bytes = 0
    foreach ($match in $matches) {
        if (-not ([string]$match).StartsWith($Sha + ':')) { return $true }
        $path = ([string]$match).Substring(41)
        $lines = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'show', ($Sha + ':' + $path)))
        if ($LASTEXITCODE -ne 0) { return $true }
        $text = $lines -join "`n"; $bytes += [Text.Encoding]::UTF8.GetByteCount($text)
        if ($bytes -gt 1048576) { return $true }
        if ($text -match '(?i)(doctest|markdown[-_ ]?doctest|remark-extract|mdx|markdown-loader|md-loader|embed.*\.md|include_str!.*\.md|sphinx|mkdocs|docusaurus|mdbook)') { return $true }
        $hygieneReader = $text -match 'TextDecoder\(["'']utf-8["'']|UTF8Encoding|Encoding\]::UTF8' -and
            $text -match '(?i)(utf-8|encoding)' -and
            $text -notmatch '(?i)(markdown|snapshot|expect\(|assert\(|JSON\.parse|eval\(|writeFile|WriteAllText)'
        $proseReference = $text -match '(?i)((?<!\\)\.md\b|["'']docs["'']|docs/)'
        if ($proseReference -and $text -match '(?i)(readFile|read_text|ReadAllText|Get-Content|open\(|glob\(|include_str!|require\(|import\s)' -and -not $hygieneReader) { return $true }
        # An explicit changed-path reference outside formatting commands is a
        # semantic input until proven otherwise. No target code is evaluated.
        foreach ($line in $lines) {
            if ($line -match '(?i)(prettier|markdownlint|format:|format:check)' -and $line -notmatch '(?i)(--plugin|--config)') { continue }
            foreach ($file in $Files) {
                if ($line.IndexOf($file, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
            if ($line -match '(?i)((?<!\\)\.md\b|["'']docs["'']|docs/)' -and $line -match '(?i)(read|load|glob|open|include|import|require|snapshot|parse|compile|exec|run|copy)') {
                # A UTF-8/source-size reader may scan docs without consuming their
                # meaning. Require the whole file's diagnostic shape, no parsers,
                # transformations or assertions over Markdown content.
                if (-not $hygieneReader) { return $true }
            }
        }
    }
    return $false
}
