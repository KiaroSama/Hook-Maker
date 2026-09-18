# Dependency-Version-Check\_pythonscope.ps1 - WHOSE PACKAGES ARE THE PROJECT'S?
#
# ROLE: pure resolution, no reporting and no mutation. It answers two questions
# the pip branch cannot answer on its own, and it never installs, upgrades,
# uninstalls or creates an environment.
#
# 1. WHICH INTERPRETER speaks for this project. A project venv wins, exactly as
#    before. What is new is the explicitly configured shared base: a project may
#    legitimately have no venv of its own and run on a shared interpreter
#    (global-environment-rules.md permits a verified shared base with
#    --system-site-packages). That is only honoured when the project CONFIGURED
#    it and the path verifies - never `pip` from PATH, whose environment belongs
#    to the machine rather than to this project.
#
# 2. WHICH PACKAGES are in scope. With a shared or system-site-packages
#    environment, `pip list --outdated` reports the whole machine: every global
#    package becomes a "project finding", which is noise at best and wrong at
#    worst. Findings are therefore restricted to the project's DECLARED set plus
#    its transitive closure, and a set that cannot be determined is reported as
#    INCOMPLETE rather than silently widened back to everything.
#
# Names are compared in PEP 503 normalised form (lowercase, runs of - _ . folded
# to a single -), because `Flask_SQLAlchemy`, `flask-sqlalchemy` and
# `Flask.SQLAlchemy` are one package.

$script:PythonScopeMaxManifestBytes = 512KB   # a manifest larger than this is not parsed
$script:PythonScopeMaxNames = 2000            # bound on the declared/closure set
$script:PythonScopeClosureTimeoutSec = 20     # bound on the one metadata query

function Get-NormalizedPythonName {
    param([AllowEmptyString()][string]$Name)
    $text = ([string]$Name).Trim().ToLowerInvariant()
    if ($text -eq '') { return '' }
    return ([System.Text.RegularExpressions.Regex]::Replace($text, '[-_.]+', '-'))
}

# One requirement line or dependency string -> the bare package name.
# Handles `pkg==1.2`, `pkg[extra]>=1`, `pkg ; python_version < "3.12"`,
# `pkg @ https://...`, and ignores option lines (-r, --index-url), comments,
# blanks, editable/URL-only entries that name no package.
function Get-RequirementName {
    param([AllowEmptyString()][string]$Line)
    $text = ([string]$Line).Trim()
    if ($text -eq '' -or $text.StartsWith('#') -or $text.StartsWith('-')) { return '' }
    $text = ($text -split '#')[0].Trim()
    $text = ($text -split ';')[0].Trim()
    $text = ($text -split '@')[0].Trim()
    $match = [System.Text.RegularExpressions.Regex]::Match($text, '^[A-Za-z0-9][A-Za-z0-9._-]*')
    if (-not $match.Success) { return '' }
    return (Get-NormalizedPythonName -Name $match.Value)
}

function Read-BoundedText {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Length -gt $script:PythonScopeMaxManifestBytes) { return $null }
        return [System.IO.File]::ReadAllText($Path)
    }
    catch { return $null }
}

# The DECLARED set, from the manifests the project actually has. Returns
# @{ Names = <string[]>; Unreadable = <string[]> } so the caller can tell "no
# dependencies declared" from "a manifest exists but could not be read" - the
# second is incomplete coverage, never an all-clear.
function Get-DeclaredPythonPackages {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $names = New-Object System.Collections.Generic.HashSet[string]
    $unreadable = New-Object System.Collections.Generic.List[string]

    $requirementFiles = @()
    try {
        $requirementFiles = @(Get-ChildItem -LiteralPath $ProjectRoot -File -Filter 'requirements*.txt' -Force -ErrorAction SilentlyContinue)
    }
    catch { }
    foreach ($file in $requirementFiles) {
        $text = Read-BoundedText -Path $file.FullName
        if ($null -eq $text) { [void]$unreadable.Add($file.Name); continue }
        foreach ($line in ($text -split "`n")) {
            $name = Get-RequirementName -Line $line
            if ($name -ne '' -and $names.Count -lt $script:PythonScopeMaxNames) { [void]$names.Add($name) }
        }
    }

    # pyproject.toml: PEP 621 [project] dependencies / optional-dependencies and
    # poetry's [tool.poetry.dependencies]. Deliberately NOT a TOML parser - it
    # collects quoted requirement strings inside the dependency tables and the
    # bare keys of a poetry table. A shape it does not understand contributes
    # nothing and is reported as unreadable, never silently treated as empty.
    $pyproject = Join-Path $ProjectRoot 'pyproject.toml'
    if (Test-Path -LiteralPath $pyproject -PathType Leaf) {
        $text = Read-BoundedText -Path $pyproject
        if ($null -eq $text) { [void]$unreadable.Add('pyproject.toml') }
        else {
            $inTable = $false
            $isPoetryTable = $false
            $sawAny = $false
            foreach ($rawLine in ($text -split "`n")) {
                $line = $rawLine.Trim()
                if ($line.StartsWith('[')) {
                    $inTable = ($line -match '^\[(project\.optional-dependencies|tool\.poetry\.dependencies|tool\.poetry\.group\.[^\]]+\.dependencies)\]')
                    $isPoetryTable = ($line -match '^\[tool\.poetry')
                    continue
                }
                if ($line -match '^dependencies\s*=') { $inTable = $true; $isPoetryTable = $false }
                if (-not $inTable) { continue }
                foreach ($quoted in [System.Text.RegularExpressions.Regex]::Matches($line, '"([^"]+)"|''([^'']+)''')) {
                    $value = $quoted.Groups[1].Value
                    if ($value -eq '') { $value = $quoted.Groups[2].Value }
                    $name = Get-RequirementName -Line $value
                    if ($name -ne '' -and $names.Count -lt $script:PythonScopeMaxNames) { [void]$names.Add($name); $sawAny = $true }
                }
                if ($isPoetryTable -and $line -match '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*=') {
                    $name = Get-NormalizedPythonName -Name $Matches[1]
                    if ($name -ne '' -and $name -ne 'python' -and $names.Count -lt $script:PythonScopeMaxNames) { [void]$names.Add($name); $sawAny = $true }
                }
            }
            if (-not $sawAny) { [void]$unreadable.Add('pyproject.toml') }
        }
    }

    foreach ($leaf in @('Pipfile', 'setup.cfg')) {
        $path = Join-Path $ProjectRoot $leaf
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $text = Read-BoundedText -Path $path
        if ($null -eq $text) { [void]$unreadable.Add($leaf); continue }
        $found = $false
        foreach ($rawLine in ($text -split "`n")) {
            $line = $rawLine.Trim()
            $name = ''
            if ($line -match '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*=\s*["'']') { $name = Get-NormalizedPythonName -Name $Matches[1] }
            elseif ($line -ne '' -and -not $line.StartsWith('[') -and -not $line.StartsWith('#') -and $line -notmatch '=') { $name = Get-RequirementName -Line $line }
            if ($name -ne '' -and $name -ne 'python' -and $names.Count -lt $script:PythonScopeMaxNames) { [void]$names.Add($name); $found = $true }
        }
        if (-not $found) { [void]$unreadable.Add($leaf) }
    }

    return [pscustomobject]@{ Names = @($names); Unreadable = @($unreadable.ToArray()) }
}

# The transitive closure of the declared set, asked of the SAME interpreter that
# will be listed. importlib.metadata is stdlib from 3.8, so this needs no
# package and installs nothing. Returns $null when the query fails - the caller
# then reports reduced coverage instead of pretending the declared set was the
# whole story, and never widens the scope back to the machine.
function Expand-PythonDependencyClosure {
    param(
        [Parameter(Mandatory = $true)][string]$PythonExecutable,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    if (@($Names).Count -eq 0) { return @() }
    $snippet = @(
        'import json,sys',
        'try:',
        '    from importlib.metadata import requires',
        'except Exception:',
        '    print("[]"); sys.exit(0)',
        'import re',
        'def norm(n): return re.sub(r"[-_.]+","-",n.strip().lower())',
        'seen=set(); queue=[norm(x) for x in json.loads(sys.argv[1])]',
        'while queue:',
        '    name=queue.pop()',
        '    if name in seen: continue',
        '    seen.add(name)',
        '    if len(seen)>%MAX%: break',
        '    try: reqs=requires(name) or []',
        '    except Exception: continue',
        '    for r in reqs:',
        '        m=re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", r.strip())',
        '        if m: queue.append(norm(m.group(0)))',
        'print(json.dumps(sorted(seen)))'
    ) -join "`n"
    $snippet = $snippet.Replace('%MAX%', [string]$script:PythonScopeMaxNames)
    $payload = (@($Names) | ConvertTo-Json -Compress)
    if ($payload -notmatch '^\[') { $payload = '[' + $payload + ']' }   # one name serialises as a bare string
    $raw = $null
    try {
        $raw = Invoke-QuietCommand -FilePath $PythonExecutable -ArgumentList @('-c', $snippet, $payload) -TimeoutSeconds $script:PythonScopeClosureTimeoutSec
    }
    catch { return $null }
    $text = (@($raw) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        $parsed = @(($text | ConvertFrom-Json))
        $result = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $parsed) {
            # Only a plain package name counts. An interpreter stub or a wrapper
            # that prints something else entirely would otherwise contribute
            # rubbish to the scope, and the scope decides what gets REPORTED.
            if ($entry -isnot [string]) { continue }
            $name = Get-NormalizedPythonName -Name ([string]$entry)
            if ($name -match '^[a-z0-9][a-z0-9-]*$') { [void]$result.Add($name) }
        }
        return @($result.ToArray())
    }
    catch { return $null }
}
