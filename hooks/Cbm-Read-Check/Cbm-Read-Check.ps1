# Cbm-Read-Check - query the Codebase Memory index before browsing files.
#
# ROLE: ADVISORY (global-hook-rules.md SS Hook Roles). It never blocks, never
# runs the CBM binary, and never writes anything outside its own state file.
# The only thing it touches is the filesystem: <cache>\_config.db to learn
# whether CBM exists at all, and <cache>\<project>.db to learn whether THIS
# project is indexed. Running the binary was measured at ~1.9 s per call,
# which no hook budget can afford - the same reason the Graphify hooks only
# test for graphify-out\graph.json.
#
# EVENTS: SessionStart (orientation once per session) and UserPromptSubmit
# (relevance-gated). Not Stop - reading is a before-the-work activity, and
# Cbm-Update-Check owns the after.
#
# WHY IT SUGGESTS INDEXING AND Graph-Read-Check DOES NOT: a CBM index takes
# seconds, is local, and a background watcher keeps it fresh afterwards, so
# "index it once" is cheap advice for any code project. A graphify graph is a
# heavier, deliberate artifact, so that hook only reacts to one that exists.
#
# COORDINATION with Graph-Read-Check: every project carries BOTH graphs, so
# that hook keeps speaking in an indexed project too. The two answer different
# questions on one prompt - this one for code structure, that one for the
# material graphify alone covers and its cross-cutting views.
#
# KNOWN LIMITATION, deliberately not worked around: a caller may override the
# project name with index_repository(name=...). A hook cannot see that, so
# such a project reads as un-indexed here. It fails toward suggesting an index
# that already exists - a wasted sentence, never a wrong claim about the code.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
try { if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 } } catch { exit 0 }

# Silent on a machine with no Codebase Memory server. Nagging about a tool the
# user has not installed is the fastest way to teach them to ignore hooks.
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$service = Get-CbmServiceConfig -Config $config -ProjectRoot $cwd
$cacheDir = $service.Environment['CBM_CACHE_DIR']
if (-not (Test-CbmInstalled -CacheDir $cacheDir)) { exit 0 }

$dbPath = Get-CbmProjectDbPath -ProjectRoot $cwd -CacheDir $cacheDir
$indexed = $false
try { $indexed = Test-Path -LiteralPath $dbPath -PathType Leaf } catch { $indexed = $false }

# UserPromptSubmit only speaks when the prompt actually needs codebase-wide
# understanding. The definition is shared with Graph-Read-Check so the two can
# never disagree about whether the same prompt was structural.
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    if (-not (Test-CodebaseStructurePrompt -Prompt $prompt)) { exit 0 }
}

if ($indexed) {
    $note = @(
        'CBM READ CHECK: indexed. Structure: get_architecture/search_graph/trace_path/get_code_snippet/detect_changes FIRST.',
        'Citations: check_index_coverage + source confirmation. Isolated edits exempt.'
    ) -join "`n"
}
else {
    $inspectCommand = Get-CbmCliAdvice -Service $service -Arguments @('allow-root', '--list')
    $approveCommand = Get-CbmCliAdvice -Service $service -Arguments @('allow-root', '--approve-sensitive', $cwd)
    $manualAdvice = if ($inspectCommand -ne '') {
        "Authorized owner shell inspection ONLY (not hook execution):`n  " + $inspectCommand +
        "`nAbsent approval + authorized exact sensitive root ONLY:`n" + $approveCommand
    }
    else { 'CLI unresolved: connected MCP or verify launcher/args in authorized owner shell; never guess executable/mode.' }
    $rootJson = $cwd | ConvertTo-Json -Compress
    $note = @(
        ('CBM READ CHECK: index absent; expected ' + $dbPath + '.'),
        ('Non-doc: index_repository(repo_path=' + $rootJson + ', mode="moderate", persistence=true) once; watcher freshness UNVERIFIED, check index_status.'),
        'Before browsing: get_architecture/search_graph/trace_path/get_code_snippet.',
        'Refusal: BEFORE recovery global-mcp-windows-cmm.md FULL. Shell denial!=MCP failure; no wider grants/path bypass/security weakening.',
        $manualAdvice,
        'Approval!=restart. Reload only proven stale binary/env/dead connection; verify source/index_status/query/parser warnings.'
    ) -join "`n"
}

# One message per (session, project, index state). Indexing the project during
# the session CHANGES that state, so the follow-up "now query it" note is not
# suppressed by the earlier "index it" note.
$sessionId = [string](Get-Field $hookInput 'session_id')
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$fingerprint = Get-ShortHash ($sessionId + '|' + $eventName + '|' + [string]$indexed + '|' + $dbPath + '|' + $note)
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('CbmReadCheck-' + $projectKey + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 } } catch { }
}
try {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($statePath, $fingerprint)
}
catch { }

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
exit $emit.ExitCode
