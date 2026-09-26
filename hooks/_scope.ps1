# _scope.ps1 - WHAT IS IN SCOPE FOR A HOOK.
#
# Two questions, one file, because they are the same question asked of two
# different inputs: does this PROMPT describe work on the project, and is this
# DIRECTORY the project's own source? Both are answers several hooks must agree
# on, and both went wrong in the same way - by being answered separately in
# each hook until the copies drifted.
#
# WHY NOT _hooklib.ps1. That file is over 1400 lines. The architecture rule
# closes a file to new code at about 700 and forbids growing one already past
# 800, so a shared answer that belongs beside the others goes in its own file
# named for the responsibility it carries. This is not a fragment created to
# duck the number: nothing here is a wrapper, and both halves have more than
# one caller.
#
# INSTALLED RUNTIMES. Like _hooklib.ps1, this travels with every hook that
# dot-sources it: scripts\_installruntimepayload.ps1 copies it into the
# runtime and scripts\_installplan.ps1 rewrites '..\_scope.ps1' to
# '_scope.ps1' for the flat installed layout. A hook that dot-sources it must
# use the '..\' spelling in this repository so that rewrite matches.
#
# ASCII ONLY. Persian terms are \uXXXX escapes, exactly as _hooklib.ps1 does,
# because an installed runtime is read by hosts whose console code page is not
# ours to choose.

# ---- prompt scope ----------------------------------------------------------
# Moved here from Feature-Request-Check.ps1, which carried this comment:
# "Kept in this hook rather than _hooklib.ps1: no second caller exists, and a
# shared definition earns its place when something else needs the same answer."
# Speckit-Check is that second caller. The patterns are byte-for-byte the ones
# Feature-Request-Check used alone, so its behaviour is unchanged by the move.

$script:FeatureBugPattern = @(
    '(?i)\b(fix|bug|error|crash|typo|broken|fails|failing|regression|stack ?trace)\b',
    '\u0628\u0627\u06af',                                       # bug (bag)
    '\u062e\u0637\u0627',                                       # error (khata)
    '\u0627\u0631\u0648\u0631',                                 # error, loan word (eror)
    '\u06a9\u0631\u0634',                                       # crash (kerash)
    '\u062e\u0631\u0627\u0628'                                  # broken (kharab)
) -join '|'

$script:FeatureExplicitPattern = @(
    '(?i)\bfeature\b',
    '(?i)\bfeature request\b',
    '(?i)\bnew capability\b',
    '(?i)\bas a user\b',
    '(?i)\bshould be able to\b',
    '(?i)\bmake it possible\b',
    '\u0641\u06cc\u0686\u0631',                                 # feature, loan word (ficher)
    '\u0642\u0627\u0628\u0644\u06cc\u062a',                     # capability (ghabeliyat)
    '\u067e\u06cc\u0627\u062f\u0647\u200c?\s?\u0633\u0627\u0632\u06cc'  # implementation (piade-sazi), ZWNJ or space
) -join '|'

# Verb + object within 60 characters. The window is what stops "add" in
# "add a comment explaining why" from reading as a feature request.
$script:FeatureVerbPattern = @(
    '(?i)\b(add|implement|build|create|introduce|support)\b[\s\S]{0,60}\b(feature|capability|command|button|page|screen|endpoint|api|option|setting|flag|mode|panel|menu|dialog|report|export|import|filter|search|login|auth|dashboard|hook|integration)\b',
    '\u0627\u0636\u0627\u0641\u0647\s+\u06a9\u0646',            # add (ezafe kon)
    '\u0627\u0636\u0627\u0641\u0647\s+\u06a9\u0646\u06cc\u0645', # let us add (ezafe konim)
    '\u0628\u0633\u0627\u0632',                                 # build (besaz)
    '\u0627\u06cc\u062c\u0627\u062f\s+\u06a9\u0646',            # create (ijad kon)
    '\u062f\u0631\u0633\u062a\s+\u06a9\u0646'                   # make (dorost kon)
) -join '|'

function Test-FeatureRequestPrompt {
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $false }
    # An explicit phrase is decisive on its own - "the feature request is broken"
    # is still about a feature.
    if ($Prompt -match $script:FeatureExplicitPattern) { return $true }
    # Otherwise a build verb only counts when nothing says "this is a defect".
    if ($Prompt -match $script:FeatureBugPattern) { return $false }
    return ($Prompt -match $script:FeatureVerbPattern)
}

# Does this prompt describe work that CHANGES the project?
#
# COMPOSED, never a third pattern set. Three arms, each one an answer that
# already exists:
#   1. a feature request                  -> Test-FeatureRequestPrompt
#   2. a structural/codebase request      -> Test-CodebaseStructurePrompt (_hooklib.ps1)
#   3. a defect                           -> $script:FeatureBugPattern
#
# ARM 3 IS THE WHOLE POINT. Test-FeatureRequestPrompt SUBTRACTS the defect
# case on purpose - a bug must not start the feature chain - so asking it
# alone leaves "fix the crash in X" unanswered. The 2026-09-19 rules route a
# bug through the spec-driven workflow too (diagnose, then converge or the
# full chain), so the caller that asks about the whole workflow has to add
# back exactly what the feature question removed.
#
# FAILS TOWARD SILENCE: an empty prompt, or one no arm recognises, is not work.
function Test-ProjectChangingPrompt {
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $false }
    if (Test-FeatureRequestPrompt -Prompt $Prompt) { return $true }
    # Guarded: a runtime that somehow lacks _hooklib.ps1 must degrade to the
    # other two arms rather than throw inside a hook that never blocks.
    if (Get-Command -Name 'Test-CodebaseStructurePrompt' -ErrorAction SilentlyContinue) {
        if (Test-CodebaseStructurePrompt -Prompt $Prompt) { return $true }
    }
    return ($Prompt -match $script:FeatureBugPattern)
}

# ---- filesystem scope ------------------------------------------------------
# Directories that are never the scanned project's own source, shared by every
# hook that walks a project tree.
#
# THE DEFECT THIS EXISTS FOR. Five hooks each carried their own array. Two of
# them excluded '.ci-runner'; three did not, and none excluded the other three
# directory names the environment rules give project-owned CI artifacts. So on
# a project that keeps its self-hosted runner inside its own root, the runner's
# work directory - which holds a SECOND CHECKOUT of the project and the
# vendored third-party actions, with their own manifests and test fixtures -
# was read as the project's source. Every oversized file was counted twice, and
# a vendored action's lockfiles produced dependency findings for package
# managers the project does not use. That last one could never be cleared by
# any action the reader could take, which is the part that does the damage: an
# unclearable warning teaches people to skip the hook's real findings.
#
# THIS IS THE INTERSECTION, NOT THE UNION. Merging the five arrays looks like
# the obvious fix and is the wrong one: 'logs' is excluded by three of them and
# NOT by Secrets-Check, and a secret scan that stops reading logs\ has lost
# exactly the coverage a leak guard exists for. Same for 'coverage' and
# '.cross-project-sync'. So the shared set is what all five genuinely agree on,
# plus the four CI directories and '.codebase-memory' (in the canonical
# protected ignore set, and rewritten wholesale on every index). Each hook adds
# its own extras beside it and keeps every directory it excluded before.
$script:HookMakerExcludedDirs = @(
    '.git', 'node_modules', 'vendor', 'dist', 'build', 'out', 'target',
    '__pycache__', '.venv', 'venv', '.ai', 'graphify-out', '.codebase-memory',
    '.claude', '.codex', 'bin', 'obj',
    '.ci-runner', '.ci-runner-win', '.ci-work', '.ci-cache'
)

# ---- project root ----------------------------------------------------------
# The repository a hook acts on, which is NOT always the hook input's `cwd`.
#
# THE DEFECT THIS EXISTS FOR (2026-09-26, seen in two projects the same day): a
# session whose working directory had drifted into a subfolder handed that
# subfolder to Ignore-Rules-Check, which then CREATED `logs\.gitignore` holding
# the whole protected set - rooted patterns that mean nothing relative to a
# subfolder - while the root .gitignore already carried every one of them.
# Secrets-Check keeps its registry beside the same `cwd`. Inside a git work tree
# the root is the top level; outside one the given folder is all there is, and
# that case keeps its old behaviour exactly.
function Resolve-HookProjectRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $Path }
    $top = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Path, 'rev-parse', '--show-toplevel'))
    if ($LASTEXITCODE -ne 0 -or $top.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$top[0])) { return $Path }
    $root = ([string]$top[0]).Trim().Replace('/', '\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $Path }
    return $root
}

# The shared base plus this hook's own extras, de-duplicated and order-stable.
function Get-HookExcludedDirs {
    param([string[]]$Extra = @())
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($script:HookMakerExcludedDirs) + @($Extra)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $result.Contains($name)) { [void]$result.Add($name) }
    }
    return $result.ToArray()
}

# ---- self-hosted runner facts (plan 012 step 6b, steering V38) --------------
# Self-hosted runners stay MANUAL: a workflow with a job on `runs-on:
# self-hosted` should be triggered only by workflow_dispatch. Read as DATA with
# a bounded line heuristic (no YAML parser is guaranteed here); an expression
# such as `${{ matrix.os }}` is not resolved and never counted as self-hosted.
function Get-WorkflowTopTriggers {
    param([AllowEmptyString()][string]$Text)
    $found = New-Object System.Collections.Generic.List[string]
    $lines = @($Text -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^["'']?on["'']?\s*:\s*(?<rest>.*)$') { continue }
        $rest = ($Matches['rest'] -replace '\s+#.*$', '').Trim()
        if ($rest -ne '') {
            foreach ($item in @($rest.Trim('[', ']') -split ',')) {
                $name = $item.Trim().Trim('"', "'")
                if ($name -match '^[A-Za-z_]+$') { [void]$found.Add($name) }
            }
            continue
        }
        $childIndent = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $next = $lines[$j]
            if ($next.Trim() -eq '' -or $next.Trim().StartsWith('#')) { continue }
            $nextIndent = $next.Length - $next.TrimStart(' ').Length
            if ($nextIndent -eq 0) { break }
            if ($childIndent -lt 0) { $childIndent = $nextIndent }
            if ($nextIndent -ne $childIndent) { continue }
            if ($next -match '^\s*-?\s*["'']?([A-Za-z_]+)["'']?\s*:?\s*(#.*)?$' -or $next -match '^\s*["'']?([A-Za-z_]+)["'']?\s*:') { [void]$found.Add($Matches[1]) }
        }
    }
    return @($found | Sort-Object -Unique)
}

function Test-WorkflowSelfHosted {
    param([AllowEmptyString()][string]$Text)
    $lines = @($Text -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^(?<indent>\s*)runs-on\s*:\s*(?<rest>.*)$') { continue }
        if ($Matches['rest'] -match '(?i)\bself-hosted\b') { return $true }
        if (($Matches['rest'] -replace '\s+#.*$', '').Trim() -ne '') { continue }
        $indent = $Matches['indent'].Length
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $next = $lines[$j]
            if ($next.Trim() -eq '') { continue }
            if (($next.Length - $next.TrimStart(' ').Length) -le $indent) { break }
            if ($next -match '(?i)\bself-hosted\b') { return $true }
        }
    }
    return $false
}

# One row per workflow file: name, whether a job runs self-hosted, triggers.
# Bounded: at most 50 files of at most 256 KB each.
function Get-WorkflowRunnerFacts {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $dir = Join-Path $ProjectRoot '.github\workflows'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yml', '.yaml') } | Sort-Object Name | Select-Object -First 50)) {
        if ($file.Length -gt 262144) { continue }
        $text = ''
        try { $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) } catch { continue }
        [void]$rows.Add([pscustomobject]@{ Name = $file.Name; SelfHosted = (Test-WorkflowSelfHosted $text); Triggers = @(Get-WorkflowTopTriggers $text) })
    }
    return $rows.ToArray()
}

# True when the repository runs a job on a self-hosted runner and NO workflow
# starts on its own (every trigger is workflow_dispatch or workflow_call): a
# push then starts no run by design, and the final run is dispatched by hand.
function Test-ManualSelfHostedRepo {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $facts = @(Get-WorkflowRunnerFacts -ProjectRoot $ProjectRoot)
    if (@($facts | Where-Object { $_.SelfHosted }).Count -eq 0) { return $false }
    return (@($facts | Where-Object { @($_.Triggers | Where-Object { $_ -cnotin @('workflow_dispatch', 'workflow_call') }).Count -gt 0 }).Count -eq 0)
}
