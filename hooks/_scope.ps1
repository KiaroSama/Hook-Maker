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

. (Join-Path $PSScriptRoot '_manualworkflow.ps1')

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

# Current user text only: examples and pasted output are not workflow requests.
function Get-ActionPromptText {
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt.Length -gt 32768) { return '' }
    try {
        $options = [Text.RegularExpressions.RegexOptions]::Multiline
        $text = [regex]::new('(?s)<([A-Za-z][A-Za-z0-9_-]*)\b[^>]*>.*?</\1\s*>', $options, [TimeSpan]::FromMilliseconds(100)).Replace($Prompt, ' ')
        if ($text -match '</?[A-Za-z][A-Za-z0-9_-]*\b[^>]*>') { return '' }
        $text = [regex]::new('(?ms)^[ \t]*(`{3,}|~{3,})[^\r\n]*\r?\n.*?(?:^[ \t]*\1[ \t]*$|\z)', $options, [TimeSpan]::FromMilliseconds(100)).Replace($text, ' ')
        $text = [regex]::new('(?m)^(?:[ \t]*>| {0,3}\t| {4})[^\r\n]*$', $options, [TimeSpan]::FromMilliseconds(100)).Replace($text, ' ')
        $text = [regex]::new('(?s)(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)', $options, [TimeSpan]::FromMilliseconds(100)).Replace($text, ' ')
        return [regex]::new('"[^"\r\n]*"|''[^''\r\n]*''', $options, [TimeSpan]::FromMilliseconds(100)).Replace($text, ' ').Trim()
    }
    catch { return '' }
}

function Test-ExplicitResearchPrompt {
    param([string]$Prompt)
    # A leading actual token, never one revealed by removing a quoted preamble.
    if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt.Length -gt 32768) { return $false }
    return ($Prompt.TrimStart() -match '^::deep-research(?:\s|[.,;!?]|$)' -and (Get-ActionPromptText $Prompt) -match '^::deep-research(?:\s|[.,;!?]|$)')
}

function Get-ResearchWorkflowReminder {
    param([switch]$Skills)
    if ($Skills) {
        return 'RESEARCH: BEFORE selection global-research-workflows.md/global-connected-skill-contracts.md/exact catalogue job FULL. Native /deep-research distinct; partial UNKNOWN, no simulation/action/spend.'
    }
    return '::deep-research: BEFORE work read CODEWORDS.md/global-research-workflows.md FULL (scope/budgets/stop/evidence/citations/claims). Routing only, not native/Gemini parity or action/agent/spend consent; reply user-language.'
}

function Get-OperationMcpReminder {
    param($HookInput, [string]$Client, [string]$ProjectRoot, [string]$StateDir)
    $text = Get-ActionPromptText ([string](Get-Field $HookInput 'prompt'))
    if ($text -eq '') { return '' }
    $notes = New-Object 'System.Collections.Generic.List[string]'
    if ($text -match '(?i)\b(scrapling|scraplingserver|scrap[eiy]\w*|crawl\w*)\b') {
        [void]$notes.Add('SCRAPLING: BEFORE use global-research-workflows.md Scrapling FULL + skill/schema.')
    }
    # Retain provider-specific context/approval routes lost by the historical restore.
    if ($text -match '(?i)\bcontext-mode\b') {
        [void]$notes.Add('CONTEXT-MODE: BEFORE use global-mcp-server-contracts.md FULL/schema. Not a sandbox.')
    }
    if ($text -match '(?i)\bomniroute(?:-ccr)?\b') {
        [void]$notes.Add('OMNIROUTE: global-mcp-server-contracts.md FULL; exposed!=authorized. Missing scope/401/403: blocked, not broken; report; no retry/grant/token/endpoint/config/install/restart/probe/provider repair.')
    }
    if ($text -match '(?i)\bREA\b|mcp__REA__') {
        [void]$notes.Add('REA: BEFORE use global-rea-summary.md -> global-rea-rules.md FULL. Missing controls BLOCK; reconcile timeout.')
    }
    if ($text -match '(?i)\btelegram(?:-mcp|-operator)?\b') {
        [void]$notes.Add('TELEGRAM: BEFORE use global-connected-skill-contracts.md Telegram Operator FULL/job/schema. No deletion.')
    }
    if ($notes.Count -eq 0) { return '' }
    [void]$notes.Add('Hook grants no actions/spend; UNKNOWN: reconcile, no retry. Availability!=execution/proof; failure!=absence.')
    $note = $notes.ToArray() -join "`n"
    $path = Join-Path $StateDir ('McpUsageCheck-operation-' + $Client + '-' + (Get-ShortHash $ProjectRoot.ToLowerInvariant()) + '.claims.json')
    $claim = Invoke-DeliveryClaim -Path $path -Identity (Get-DeliveryIdentity $HookInput) -Fingerprint (Get-ShortHash ($text + '|' + $note))
    if (-not $claim.Ok) { return 'Operation reminder reservation is unverified; no consent or action was recorded.' }
    if (-not $claim.Admitted) { return '' }
    return $note
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

# Project-structure advice must not turn private planning archives into active
# dependencies. This scope belongs ONLY to the two advisory manifest scanners;
# ignoredness is never evidence for secrets, outgoing objects or CI input safety.
function Get-AdvisoryProjectFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string[]]$ExcludedDirs = @(),
        [ValidateRange(1,4000)][int]$MaxDirectories = 4000,
        [ValidateRange(1,50000)][int]$MaxEntries = 50000,
        [ValidateRange(0,32)][int]$MaxDepth = 32,
        [ValidateRange(0,5000)][int]$TimeoutMilliseconds = 5000
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    if (Get-Command Get-HookRemainingSeconds -ErrorAction SilentlyContinue) {
        $TimeoutMilliseconds = [Math]::Min($TimeoutMilliseconds, (Get-HookRemainingSeconds) * 1000)
    }
    $files = New-Object 'System.Collections.Generic.List[string]'
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@($ProjectRoot, 0))
    $directories = 0; $entries = 0
    while ($stack.Count -gt 0) {
        if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { [void]$reasons.Add('timeLimit'); break }
        if ($directories -ge $MaxDirectories) { [void]$reasons.Add('directoryLimit'); break }
        $frame = $stack.Pop(); $directory = [string]$frame[0]; $depth = [int]$frame[1]
        $directories++
        try {
            if ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) { [void]$reasons.Add('reparseRoot'); continue }
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { [void]$reasons.Add('timeLimit'); break }
                if ($entries -ge $MaxEntries) { [void]$reasons.Add('entryLimit'); break }
                $entries++
                $attributes = [IO.File]::GetAttributes($entry)
                if ($attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($attributes -band [IO.FileAttributes]::Directory) {
                    $name = [IO.Path]::GetFileName($entry)
                    if ($ExcludedDirs -contains $name) { continue }
                    # Root anchors matter: src/plans can be real production code.
                    if ($depth -eq 0 -and $name -in @('plans', 'specs', '.specify')) { continue }
                    if (Test-IsMarkerPrunedDirectory $entry) { continue }
                    if ($depth -ge $MaxDepth) { [void]$reasons.Add('depthLimit'); continue }
                    if (($directories + $stack.Count) -ge $MaxDirectories) { [void]$reasons.Add('directoryLimit'); continue }
                    $stack.Push(@($entry, ($depth + 1)))
                }
                else { [void]$files.Add($entry) }
            }
        }
        catch { [void]$reasons.Add('readError') }
        if ($reasons -contains 'entryLimit' -or $reasons -contains 'timeLimit') { break }
    }
    return [pscustomobject]@{ Files = $files.ToArray(); Complete = ($reasons.Count -eq 0); Reasons = @($reasons | Select-Object -Unique) }
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

# ---- fast Win32 directory traversal with cross-platform .NET fallback --------
# On Windows, FindFirstFileExW (FindExInfoBasic | FIND_FIRST_EX_LARGE_FETCH)
# returns names, directory/reparse attributes and marker-file presence in a
# single kernel call per directory instead of separate EnumerateFiles +
# EnumerateDirectories + Get-Item + File.Exists syscalls. Non-Windows hosts and
# constrained runtimes fall back to pure .NET System.IO with identical rules.
function Initialize-FastFsScope {
    if ($env:OS -ne 'Windows_NT') { return $false }
    if ($null -ne ('HookMaker.FastFsScope' -as [type])) { return $true }
    $csSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace HookMaker {
    public static class FastFsScope {
        private const int FILE_ATTRIBUTE_DIRECTORY = 0x10;
        private const int FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
        private const int FIND_FIRST_EX_LARGE_FETCH = 2;
        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WIN32_FIND_DATAW {
            public int dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
            public int nFileSizeHigh;
            public int nFileSizeLow;
            public int dwReserved0;
            public int dwReserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
            public string cAlternateFileName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileExW(
            string lpFileName, int fInfoLevelId, out WIN32_FIND_DATAW lpFindFileData,
            int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATAW lpFindFileData);

        [DllImport("kernel32.dll")]
        private static extern bool FindClose(IntPtr hFindFile);

        private static string ToSearchPattern(string dir) {
            string p = dir.EndsWith("\\") ? (dir + "*") : (dir + "\\*");
            if (!p.StartsWith("\\\\?\\") && p.Length >= 248) p = "\\\\?\\" + p;
            return p;
        }

        public static bool ReadDirectory(
            string dirPath, string[] excludedDirs, string[] markerFiles, bool checkMarkers,
            out string[] subDirs, out string[] filePaths, out bool markerPruned) {
            var excl = new HashSet<string>(excludedDirs ?? new string[0], StringComparer.OrdinalIgnoreCase);
            var markers = new HashSet<string>(markerFiles ?? new string[0], StringComparer.OrdinalIgnoreCase);
            var dList = new List<string>();
            var fList = new List<string>();
            markerPruned = false;
            WIN32_FIND_DATAW fd;
            IntPtr h = FindFirstFileExW(ToSearchPattern(dirPath), 1, out fd, 0, IntPtr.Zero, FIND_FIRST_EX_LARGE_FETCH);
            if (h == INVALID_HANDLE_VALUE) {
                int err = Marshal.GetLastWin32Error();
                subDirs = new string[0];
                filePaths = new string[0];
                return (err == 2 || err == 18);
            }
            string prefix = dirPath.EndsWith("\\") ? dirPath : (dirPath + "\\");
            try {
                do {
                    string name = fd.cFileName;
                    if (name == "." || name == "..") continue;
                    int attr = fd.dwFileAttributes;
                    if ((attr & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                        if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) continue;
                        if (excl.Contains(name)) continue;
                        dList.Add(prefix + name);
                    } else {
                        if (checkMarkers && markers.Contains(name)) {
                            markerPruned = true;
                        }
                        fList.Add(prefix + name);
                    }
                } while (FindNextFileW(h, out fd));
            } finally {
                FindClose(h);
            }
            if (markerPruned) {
                subDirs = new string[0];
                filePaths = new string[0];
                return true;
            }
            subDirs = dList.ToArray();
            filePaths = fList.ToArray();
            return true;
        }

        public static string[] FindEnvFiles(string root, string[] excludedDirs, string[] markerFiles) {
            var excl = new HashSet<string>(excludedDirs ?? new string[0], StringComparer.OrdinalIgnoreCase);
            var markers = new HashSet<string>(markerFiles ?? new string[0], StringComparer.OrdinalIgnoreCase);
            var queue = new ConcurrentQueue<string>();
            var bag = new ConcurrentBag<string>();
            int pending = 1;
            queue.Enqueue(root);
            using (var done = new ManualResetEventSlim(false)) {
                int workers = Math.Min(4, Math.Max(1, Environment.ProcessorCount));
                var threads = new Thread[workers];
                for (int w = 0; w < workers; w++) {
                    threads[w] = new Thread(() => {
                        var subDirs = new List<string>(32);
                        var envHere = new List<string>(4);
                        while (!done.IsSet) {
                            string cur;
                            if (!queue.TryDequeue(out cur)) {
                                done.Wait(1);
                                continue;
                            }
                            try {
                                subDirs.Clear();
                                envHere.Clear();
                                bool isRoot = string.Equals(cur, root, StringComparison.OrdinalIgnoreCase);
                                bool hasMarker = false;
                                WIN32_FIND_DATAW fd;
                                IntPtr h = FindFirstFileExW(ToSearchPattern(cur), 1, out fd, 0, IntPtr.Zero, FIND_FIRST_EX_LARGE_FETCH);
                                if (h != INVALID_HANDLE_VALUE) {
                                    string prefix = cur.EndsWith("\\") ? cur : (cur + "\\");
                                    try {
                                        do {
                                            string name = fd.cFileName;
                                            if (name == "." || name == "..") continue;
                                            int attr = fd.dwFileAttributes;
                                            if ((attr & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                                                if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) continue;
                                                if (excl.Contains(name)) continue;
                                                subDirs.Add(prefix + name);
                                            } else {
                                                if (!isRoot && markers.Contains(name)) {
                                                    hasMarker = true;
                                                } else if (name.StartsWith(".env", StringComparison.OrdinalIgnoreCase)) {
                                                    envHere.Add(prefix + name);
                                                }
                                            }
                                        } while (FindNextFileW(h, out fd));
                                    } finally {
                                        FindClose(h);
                                    }
                                }
                                if (!hasMarker) {
                                    for (int i = 0; i < envHere.Count; i++) bag.Add(envHere[i]);
                                    if (subDirs.Count > 0) {
                                        Interlocked.Add(ref pending, subDirs.Count);
                                        for (int i = 0; i < subDirs.Count; i++) queue.Enqueue(subDirs[i]);
                                    }
                                }
                            } finally {
                                if (Interlocked.Decrement(ref pending) == 0) done.Set();
                            }
                        }
                    });
                    threads[w].IsBackground = true;
                    threads[w].Start();
                }
                done.Wait();
                for (int w = 0; w < workers; w++) threads[w].Join();
            }
            var result = bag.ToArray();
            Array.Sort(result, StringComparer.OrdinalIgnoreCase);
            return result;
        }
    }
}
'@
    try { Add-Type -Language CSharp -TypeDefinition $csSource -ErrorAction Stop; return $true } catch { return $false }
}

function Get-ProjectEnvFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string[]]$ExcludedDirs = @()
    )
    $rootFull = (Get-Item -LiteralPath $ProjectRoot).FullName.TrimEnd('\', '/')
    $markerNames = if (Get-Variable -Name PruneMarkerFiles -Scope Script -ErrorAction SilentlyContinue) { @($script:PruneMarkerFiles) } else { @('pyvenv.cfg', 'CACHEDIR.TAG') }
    $rawPaths = $null
    if (Initialize-FastFsScope) {
        try { $rawPaths = [HookMaker.FastFsScope]::FindEnvFiles($rootFull, $ExcludedDirs, $markerNames) } catch { $rawPaths = $null }
    }
    if ($null -eq $rawPaths) {
        $exclSet = @{}
        foreach ($d in @($ExcludedDirs)) { if (-not [string]::IsNullOrWhiteSpace($d)) { $exclSet[$d.ToLowerInvariant()] = $true } }
        $collected = New-Object System.Collections.Generic.List[string]
        $dirStack = New-Object System.Collections.Generic.Stack[string]
        $dirStack.Push($rootFull)
        while ($dirStack.Count -gt 0) {
            $cur = $dirStack.Pop()
            try {
                foreach ($fp in [System.IO.Directory]::EnumerateFiles($cur, '.env*', [System.IO.SearchOption]::TopDirectoryOnly)) {
                    [void]$collected.Add($fp)
                }
                foreach ($dp in [System.IO.Directory]::EnumerateDirectories($cur)) {
                    $attr = [System.IO.File]::GetAttributes($dp)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $leafName = [System.IO.Path]::GetFileName($dp)
                    if ($exclSet.ContainsKey($leafName.ToLowerInvariant())) { continue }
                    if (Test-IsMarkerPrunedDirectory $dp) { continue }
                    $dirStack.Push($dp)
                }
            }
            catch { }
        }
        $rawPaths = $collected.ToArray()
    }
    $envItems = New-Object System.Collections.Generic.List[object]
    foreach ($filePath in $rawPaths) {
        $leaf = [System.IO.Path]::GetFileName($filePath)
        if ($leaf -notmatch '(?i)\.(example|sample|template|dist)$') {
            $relative = $filePath.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            [void]$envItems.Add([pscustomobject]@{ FullName = $filePath; Name = $relative })
        }
    }
    return @($envItems.ToArray() | Sort-Object Name)
}
