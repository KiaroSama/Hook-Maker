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
# COORDINATION with Graph-Read-Check: when CBM is installed AND this project
# is indexed, that hook stays silent - the CBM graph is the primary code
# graph, and two hooks asking for two different graphs on the same prompt is
# noise, not redundancy.
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
        'CBM READ CHECK - this project is indexed in Codebase Memory MCP. For any codebase understanding (architecture, "where is X used", callers, impact, refactor scope) query the graph BEFORE browsing files:',
        '- get_architecture for orientation, search_graph to find symbols, trace_path for callers/callees, get_code_snippet for exact source, detect_changes for blast radius.',
        '- Coverage is best-effort, never proof: check_index_coverage every path you cite, and confirm important findings in the source before acting.',
        '- Isolated edits, docs, config, or a small local fix need no query - not querying is a fine and expected outcome.'
    ) -join "`n"
}
else {
    $inspectCommand = Get-CbmCliAdvice -Service $service -Arguments @('allow-root', '--list')
    $approveCommand = Get-CbmCliAdvice -Service $service -Arguments @('allow-root', '--approve-sensitive', $cwd)
    $manualAdvice = if ($inspectCommand -ne '') {
        "Manual inspection in an authorized owner-account shell (the hook never executes it):`n  " + $inspectCommand +
        "`nOnly for an absent approval of THIS user-authorized root, and only if it is classified as sensitive:`n  " + $approveCommand
    }
    else { 'No safe raw CLI invocation was resolved. Use the connected MCP tools or verify the configured launcher and its CLI arguments in an authorized owner-account shell; do not guess an executable or launcher mode.' }
    $rootJson = $cwd | ConvertTo-Json -Compress
    $note = @(
        ('CBM READ CHECK - this project has no Codebase Memory index yet (expected at ' + $dbPath + ').'),
        ('Unless this session is documentation-only, index it once now: index_repository(repo_path=' + $rootJson + ', mode="moderate", persistence=true). A background watcher normally keeps it fresh.'),
        'Then query the graph before browsing files: get_architecture, search_graph, trace_path, get_code_snippet.',
        'If indexing refuses, diagnose the specific cause using global-mcp-rules.md, Windows CMM installation and correct usage:',
        '- Outside the allowed root / absent approval: verify the selected service environment and exact project root. Enroll only a root the user authorized; a hook reminder never authorizes wider access.',
        '- Approved but still sensitive on 0.10.8: approval equality is separator-sensitive. Compare backslash and forward-slash spellings and the approval marker. Preserve every grant; add only the equivalent spelling of the same approved root, with a backup, concurrent-change detection and atomic publication. Do not move project sources or use parent grants/junction escapes.',
        '- OS/sandbox access denial: a shell refusal does not prove the connected MCP service is broken. Use the connected tool or authorized escalation; do not grant sandbox identities write access to the private service.',
        '- cache-private / untrusted identity / secure-coordination failure: inspect the exact path and SID in the newest worker log, including cache/runtime ancestor ACLs. Keep the private service outside writable workspaces; repeatedly tightening a workspace ACL or weakening security checks is not a repair.',
        $manualAdvice,
        'CMM 0.10.8 reads grants during authorization; approval alone does not require a restart. Reload a client only when evidence shows obsolete executable/environment settings or a dead connection. Confirm recovery with an actual tool result, index_status and a scoped query; parser warnings still require source inspection.'
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
