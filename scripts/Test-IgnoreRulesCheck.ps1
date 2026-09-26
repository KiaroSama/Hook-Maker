param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Ignore-Rules-Check\Ignore-Rules-Check.ps1'
$InstallScript = Join-Path $PSScriptRoot 'Install-Hook.ps1'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-ignoretest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
# Isolates Install-Hook.ps1's install registry away from this real checkout's
# own registry for every in-process & $InstallScript call below.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$env:HOOKMAKER_STATE_DIR = Join-Path $Work 'state'

function New-Repo {
    param([string]$Name)
    $repo = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    return $repo
}

function Fire {
    param([string]$Cwd, [string]$EventName = 'Stop', [string]$Exe = '', $RawStdin = $null, [string]$HookPath = $Hook)
    $payload = $RawStdin
    if ($null -eq $payload) {
        $payload = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName } | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    $file = if ([string]::IsNullOrWhiteSpace($Exe)) { (Get-Process -Id $PID).Path } else { $Exe }
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    $proc = Start-BoundedProcess -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Copies Ignore-Rules-Check.ps1 + its shared _hooklib.ps1 with a custom .env so a
# project-specific EXTRA_PATTERNS override can be tested in isolation.
function New-ConfiguredIgnoreHookCopy {
    param([hashtable]$EnvOverrides)
    $dir = Join-Path $Work ('ignorehookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Ignore-Rules-Check.ps1')
    # EVERY shared library, not a hand-picked one: the hook now also dot-sources
    # ..\_scope.ps1, and a copy that brought only _hooklib.ps1 would fail to load.
    Copy-TestRuntimeLibraries -SourceHookLib (Join-Path (Split-Path -Parent $Hook) '..\_hooklib.ps1') -Destination (Join-Path $Work '_hooklib.ps1')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
    [System.IO.File]::WriteAllText((Join-Path $dir '.env'), (($lines.ToArray() -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    return (Join-Path $dir 'Ignore-Rules-Check.ps1')
}

try {
    if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
        Write-Host 'Hook not found (expected RED before implementation).' -ForegroundColor Red
        exit 1
    }

    $repo = New-Repo 'auto'
    $rulesDir = Join-Path $repo '.claude\rules'
    New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $rulesDir 'local.md'), 'Keep `/private-cache/` local-only and git-ignored.', (New-Object System.Text.UTF8Encoding $false))

    $r = Fire -Cwd $repo -RawStdin ''
    Check 'empty stdin -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $repo -EventName 'UserPromptSubmit'
    Check 'unconfigured event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $repo -EventName 'SessionStart'
    $ignore = [System.IO.File]::ReadAllText((Join-Path $repo '.gitignore'))
    Check 'SessionStart auto-adds required protected patterns' ($ignore -match '(?m)^/\.ai/$' -and $ignore -match '(?m)^/AGENTS\.md$' -and $ignore -match '(?m)^\*\*/\.ignoreme$') $ignore
    Check 'SessionStart extracts a local-only path from project rules' ($ignore -match '(?m)^/private-cache/$') $ignore
    Check 'pre-task auto-fix reports context' ($r.Out -match '"hookSpecificOutput"' -and $r.Out -match 'Auto-added') $r.Out
    $r = Fire -Cwd $repo
    Check 'clean post-task Stop -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $post = New-Repo 'post'
    $r = Fire -Cwd $post
    $postIgnore = [System.IO.File]::ReadAllText((Join-Path $post '.gitignore'))
    Check 'Stop also auto-adds required protected patterns' ($postIgnore -match '(?m)^/\.ai/$') $postIgnore
    Check 'post-task auto-fix blocks once for review' ($r.Out -match '"decision":"block"' -and $r.Out -match 'Auto-added') $r.Out

    $tracked = New-Repo 'tracked'
    [System.IO.File]::WriteAllText((Join-Path $tracked 'AGENTS.md'), 'private', (New-Object System.Text.UTF8Encoding $false))
    & git -C $tracked add -f AGENTS.md
    & git -C $tracked commit -q -m c
    $r = Fire -Cwd $tracked
    Check 'tracked protected file blocks completion' ($r.Out -match 'TRACKED' -and $r.Out -match 'AGENTS.md') $r.Out

    # =====================================================================
    Write-Host '--- .env.example and other template files are allowed to stay tracked ---' -ForegroundColor Cyan

    # Root-level template files must be TRACKABLE, not falsely reported as
    # protected. Reproduced root cause: the built-in negation patterns
    # (!/.env.example, ...) were written ALPHABETICALLY SORTED, landing before
    # the /.env.* pattern they are meant to override - so the negation never
    # took effect (git check-ignore's last-match-wins picked /.env.* instead),
    # AND even when a negation DID match, the old code treated any pattern
    # found in the combined managed-pattern list (negations included) as
    # protected. Both are fixed: patterns are written in insertion order, and
    # a negation match is never protected.
    $envTemplates = New-Repo 'env-templates'
    $r0 = Fire -Cwd $envTemplates -EventName 'SessionStart'
    foreach ($tmpl in @('.env.example', '.env.sample', '.env.template', '.env.dist')) {
        [System.IO.File]::WriteAllText((Join-Path $envTemplates $tmpl), 'PLACEHOLDER_KEY=changeme', (New-Object System.Text.UTF8Encoding $false))
    }
    $addOutput = (& git -C $envTemplates add .env.example .env.sample .env.template .env.dist 2>&1 | Out-String)
    Check 'git add does not refuse root template files as ignored' ($addOutput -notmatch 'ignored') $addOutput
    & git -C $envTemplates commit -q -m 'track placeholder templates'
    $r = Fire -Cwd $envTemplates
    Check 'tracked placeholders-only .env.example is allowed (silent)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'tracked .env.sample/.env.template/.env.dist are allowed too' ($r.Out -notmatch '\.env\.sample' -and $r.Out -notmatch '\.env\.template' -and $r.Out -notmatch '\.env\.dist') $r.Out

    # A staged (not yet committed) template update is also allowed.
    [System.IO.File]::WriteAllText((Join-Path $envTemplates '.env.example'), 'PLACEHOLDER_KEY=changeme`nOTHER=1', (New-Object System.Text.UTF8Encoding $false))
    & git -C $envTemplates add .env.example
    $r = Fire -Cwd $envTemplates
    Check 'a staged template update is allowed (silent)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    & git -C $envTemplates commit -q -m 'update template'

    # The native pre-push chain allows a clean push whose only tracked env-ish
    # content is the safe .env.example template.
    & git -C $envTemplates config core.autocrlf false
    $envTemplatesRemote = Join-Path $Work 'env-templates-remote.git'
    & git init -q --bare $envTemplatesRemote
    & git -C $envTemplates remote add origin $envTemplatesRemote
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $envTemplates -CodexOnly *> $null
    $ErrorActionPreference = 'Continue'
    $templatePushOutput = (& git -C $envTemplates push -u origin main 2>&1 | Out-String)
    $templatePushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'a clean push containing only a safe tracked .env.example succeeds' ($templatePushExit -eq 0 -and $templatePushOutput -notmatch 'IGNORE RULES CHECK') $templatePushOutput

    # Real env files remain protected: tracked .env, .env.local, .env.production.
    foreach ($real in @('.env', '.env.local', '.env.production')) {
        [System.IO.File]::WriteAllText((Join-Path $envTemplates $real), 'REAL_SECRET=x', (New-Object System.Text.UTF8Encoding $false))
        & git -C $envTemplates add -f $real
    }
    & git -C $envTemplates commit -q -m 'force-track real env files (simulated pre-existing)'
    $r = Fire -Cwd $envTemplates
    Check 'tracked real .env is blocked' ($r.Out -match 'TRACKED' -and $r.Out -match '(?<!\.)\.env(?!\.\w)') $r.Out
    Check 'tracked .env.local is blocked' ($r.Out -match '\.env\.local') $r.Out
    Check 'tracked .env.production is blocked' ($r.Out -match '\.env\.production') $r.Out
    Check 'the still-allowed .env.example is not listed among the blocked paths' ($r.Out -notmatch '\.env\.example') $r.Out

    # A project rule that explicitly re-protects .env.example as a POSITIVE
    # pattern (added after the default negations via EXTRA_PATTERNS) still
    # blocks it - an explicit project override wins when the effective
    # gitignore result for that path is positive.
    $envOverride = New-Repo 'env-override'
    $overrideHook = New-ConfiguredIgnoreHookCopy -EnvOverrides @{ EXTRA_PATTERNS = '/.env.example' }
    $r0 = Fire -Cwd $envOverride -EventName 'SessionStart' -HookPath $overrideHook
    [System.IO.File]::WriteAllText((Join-Path $envOverride '.env.example'), 'PLACEHOLDER_KEY=changeme', (New-Object System.Text.UTF8Encoding $false))
    & git -C $envOverride add -f .env.example
    & git -C $envOverride commit -q -m 'track template despite explicit override'
    $r = Fire -Cwd $envOverride -HookPath $overrideHook
    Check 'an explicit project-specific positive rule still blocks .env.example' ($r.Out -match 'TRACKED' -and $r.Out -match '\.env\.example') $r.Out

    # =====================================================================
    Write-Host '--- the stable protected ignore set: presence AND semantic order ---' -ForegroundColor Cyan

    # The exact built-in set from Ignore-Rules-Check.ps1. Ordering here is
    # SEMANTIC, not cosmetic: gitignore is last-match-wins, so every `!` negation
    # must sit AFTER the broader positive pattern it un-ignores. Asserting only
    # presence would pass on a file where every negation is dead.
    # The 2026-09-19 additions sit in CANONICAL POSITIONS, not at the end: both
    # Spec Kit directories straight after /.ai/, the regenerated code index after
    # /graphify-out/, and the local plans directory after that. Appending them
    # instead would still pass a presence check while putting them on the wrong
    # side of a later negation, which is the failure this block exists to catch.
    $StableIgnoreSet = @(
        '/.ai/', '/.specify/', '/specs/', '/secrets.md', '/explain-AI.md', '/reference.md',
        '/CLAUDE.md', '/AGENTS.md',
        '/.agents/', '/.claude/', '/.kiro/', '/.codex/', '/.cursor/', '/.cline/', '/graphify-out/',
        '/.codebase-memory/', '/plans/',
        '.ignoreme', '**/.ignoreme', '/.env', '/.env.*', '!/.env.example', '!/.env.sample',
        '!/.env.template', '!/.env.dist'
    )

    function Get-IgnoreLines {
        param([string]$Repo)
        return @([System.IO.File]::ReadAllLines((Join-Path $Repo '.gitignore')) | ForEach-Object { $_.Trim() })
    }

    # Resolves what git ACTUALLY decides for a path - the only trustworthy check,
    # since a pattern can be present and still be overridden by a later match.
    function Test-GitIgnored {
        param([string]$Repo, [string]$RelPath)
        & git -C $Repo check-ignore -q --no-index -- $RelPath 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    $stable = New-Repo 'stable-ignore-set'
    $null = Fire -Cwd $stable -EventName 'SessionStart'
    $stableLines = Get-IgnoreLines $stable
    $missingStable = @($StableIgnoreSet | Where-Object { $stableLines -notcontains $_ })
    Check 'the full stable protected ignore set is present after the first run' ($missingStable.Count -eq 0) (($missingStable -join ', ') + ' | file: ' + ($stableLines -join ', '))

    # Relative order: every negation must come after the broader /.env.* it un-ignores.
    $broadEnvAt = [array]::LastIndexOf([string[]]$stableLines, '/.env.*')
    $negationsAfterBroad = @(@('!/.env.example', '!/.env.sample', '!/.env.template', '!/.env.dist') |
            Where-Object { [array]::LastIndexOf([string[]]$stableLines, $_) -lt $broadEnvAt })
    Check 'every .env negation is written AFTER the broader /.env.* it un-ignores' (
        $broadEnvAt -ge 0 -and $negationsAfterBroad.Count -eq 0) (($negationsAfterBroad -join ', ') + ' | /.env.* at ' + $broadEnvAt)

    # Order is only meaningful through its effect: prove git agrees.
    Check 'effective result: a real .env is ignored' (Test-GitIgnored -Repo $stable -RelPath '.env')
    Check 'effective result: a real .env.local is ignored' (Test-GitIgnored -Repo $stable -RelPath '.env.local')
    foreach ($tmpl in @('.env.example', '.env.sample', '.env.template', '.env.dist')) {
        Check ('effective result: the public template ' + $tmpl + ' is NOT ignored') (-not (Test-GitIgnored -Repo $stable -RelPath $tmpl))
    }

    # A negation placed BEFORE its broader rule is dead on arrival (last-match-wins).
    # Reproduced consequence: alphabetically sorting an existing .gitignore moves
    # every '!' line above '/.env.*' ('!' < '/' in ASCII), which both re-ignores the
    # public templates AND makes an already-tracked .env.example match the protected
    # /.env.* pattern - a false "TRACKED protected paths" block on a legitimately
    # public file. The hook must repair the precedence, never just accept presence.
    $sortedRepo = New-Repo 'sorted-gitignore'
    $null = Fire -Cwd $sortedRepo -EventName 'SessionStart'
    [System.IO.File]::WriteAllText((Join-Path $sortedRepo '.env.example'), 'PLACEHOLDER_KEY=changeme', (New-Object System.Text.UTF8Encoding $false))
    & git -C $sortedRepo add .env.example .gitignore
    & git -C $sortedRepo commit -q -m 'track the public template while ordering is correct'
    # Simulate any tool (or human) that sorts .gitignore alphabetically.
    $scrambled = @(Get-IgnoreLines $sortedRepo | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } | Sort-Object)
    Check 'the scrambled fixture really does place a negation before /.env.*' (
        [array]::LastIndexOf([string[]]$scrambled, '!/.env.example') -lt [array]::LastIndexOf([string[]]$scrambled, '/.env.*')) ($scrambled -join ', ')
    [System.IO.File]::WriteAllText((Join-Path $sortedRepo '.gitignore'), (($scrambled -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))

    $r = Fire -Cwd $sortedRepo
    $repairedLines = Get-IgnoreLines $sortedRepo
    Check 'a negation ordered before its broader rule is repaired, not accepted' (
        [array]::LastIndexOf([string[]]$repairedLines, '!/.env.example') -gt [array]::LastIndexOf([string[]]$repairedLines, '/.env.*')) ($repairedLines -join ', ')
    Check 'after repair the public template is genuinely un-ignored again' (-not (Test-GitIgnored -Repo $sortedRepo -RelPath '.env.example'))
    Check 'after repair a real .env is still ignored (no protection weakened)' (Test-GitIgnored -Repo $sortedRepo -RelPath '.env')
    $stillMissing = @($StableIgnoreSet | Where-Object { $repairedLines -notcontains $_ })
    Check 'the repair never drops, renames or weakens any protected pattern' ($stillMissing.Count -eq 0) ($stillMissing -join ', ')
    Check 'the tracked public template is NOT falsely reported as a protected path' ($r.Out -notmatch 'TRACKED') $r.Out

    # Idempotent: a second run must not keep re-appending the same negations.
    $r2 = Fire -Cwd $sortedRepo
    Check 'the order repair is idempotent (second run is silent)' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out

    # =====================================================================
    Write-Host '--- an ignored .venv stays ignored and untracked ---' -ForegroundColor Cyan

    # A required-for-deployment .venv is a git-protection concern only: the hook
    # must leave it ignored and untracked and must never un-ignore it. Whether a
    # deployment pipeline copies that directory is a SEPARATE concern this hook
    # neither authorizes nor decides.
    $venvRepo = New-Repo 'venv-ignored'
    $venvPkg = Join-Path $venvRepo '.venv\Lib\site-packages\thirdparty'
    New-Item -ItemType Directory -Path $venvPkg -Force | Out-Null
    # An opaque, token-SHAPED but obviously fake constant vendored by a package.
    [System.IO.File]::WriteAllText((Join-Path $venvPkg 'fixture_sample.py'),
        "SAMPLE_TOKEN = `"QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVoxMjM0NTY3ODkw`"`n", (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $venvRepo '.gitignore'), ".venv/`n", (New-Object System.Text.UTF8Encoding $false))
    $r = Fire -Cwd $venvRepo -EventName 'SessionStart'
    $venvLines = Get-IgnoreLines $venvRepo
    Check '.venv/ ignore rule is preserved by the auto-fix' ($venvLines -contains '.venv/') ($venvLines -join ', ')
    Check 'the hook never adds a negation that would un-ignore .venv' (
        -not @($venvLines | Where-Object { $_ -like '!*venv*' }).Count) ($venvLines -join ', ')
    Check '.venv is still ignored by git after the hook runs' (Test-GitIgnored -Repo $venvRepo -RelPath '.venv/Lib/site-packages/thirdparty/fixture_sample.py')
    $venvTracked = @(& git -C $venvRepo ls-files -- .venv | Where-Object { $_ })
    Check '.venv is never tracked as a side effect of the hook' ($venvTracked.Count -eq 0) ($venvTracked -join ', ')
    Check 'an ignored .venv containing a token-shaped constant does not block' ($r.Out -notmatch '\.venv') $r.Out

    $ps5 = New-Repo 'ps5'
    $r = Fire -Cwd $ps5 -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 auto-fix works' ($r.Exit -eq 0 -and (Test-Path -LiteralPath (Join-Path $ps5 '.gitignore'))) $r.Err

    Write-Host '--- batching: one git check-ignore per batch, not per file ---' -ForegroundColor Cyan
    # A git.ps1 shim on PATH (same convention as Test-CiStatusCheck.ps1's gh.ps1)
    # counts check-ignore spawns and forwards everything to the real git. The
    # directories holding git.exe are removed from PATH for the duration of
    # the fire, so the hook can only find the shim; the shim itself calls the
    # real binary by absolute path.
    $bigRepo = New-Repo 'big'
    for ($i = 0; $i -lt 300; $i++) {
        [System.IO.File]::WriteAllText((Join-Path $bigRepo ('file-' + $i + '.txt')), 'x', (New-Object System.Text.UTF8Encoding $false))
    }
    [System.IO.File]::WriteAllText((Join-Path $bigRepo 'AGENTS.md'), 'private', (New-Object System.Text.UTF8Encoding $false))
    & git -C $bigRepo add -A
    & git -C $bigRepo commit -q -m c
    $shimDir = Join-Path $Work 'gitshim'
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
    $callLog = Join-Path $Work 'check-ignore-calls.txt'
    # Git for Windows ships git.exe twice (cmd\ and mingw64\bin\), so Get-Command
    # returns BOTH; take the first, or the shim forwards to the two paths joined
    # by a space and every git call it wraps fails silently.
    $realGit = @(Get-Command git.exe -CommandType Application -ErrorAction Stop)[0].Source
    $shimBody = @(
        '# Counts check-ignore spawns, then forwards everything to the real git.',
        ("if (`$args -contains 'check-ignore') { [System.IO.File]::AppendAllText('" + $callLog + "', 'x' + [Environment]::NewLine) }"),
        ("& '" + $realGit + "' @args"),
        'exit $LASTEXITCODE'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $shimDir 'git.ps1'), $shimBody, (New-Object System.Text.UTF8Encoding $false))
    $savedPath = $env:PATH
    $pathWithoutRealGit = @($env:PATH -split ';' | Where-Object {
        $_ -ne '' -and -not (Test-Path -LiteralPath (Join-Path $_ 'git.exe') -PathType Leaf)
    })
    $env:PATH = (@($shimDir) + $pathWithoutRealGit) -join ';'
    try { $r = Fire -Cwd $bigRepo } finally { $env:PATH = $savedPath }
    $spawns = 0
    if (Test-Path -LiteralPath $callLog -PathType Leaf) { $spawns = @([System.IO.File]::ReadAllLines($callLog)).Count }
    Check 'batching: 301 tracked files need at most 3 check-ignore spawns' ($spawns -ge 1 -and $spawns -le 3) ('spawns=' + $spawns)
    Check 'batching: the tracked protected file is still reported' ($r.Out -match 'TRACKED' -and $r.Out -match 'AGENTS\.md') $r.Out
    Check 'batching: no unprotected file is reported' ($r.Out -notmatch 'file-\d+\.txt') $r.Out

    Write-Host '--- native git pre-push enforcement ---' -ForegroundColor Cyan
    $pushRepo = New-Repo 'pre push'
    & git -C $pushRepo config core.autocrlf false
    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'file.txt'), 'v1', (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add file.txt
    & git -C $pushRepo commit -q -m c1
    $nativeHook = Join-Path $pushRepo '.git\hooks\pre-push'
    [System.IO.File]::WriteAllText($nativeHook, "#!/bin/sh`necho previous > previous-hook.txt`n", (New-Object System.Text.UTF8Encoding $false))
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $pushRepo -CodexOnly *> $null
    $nativeBody = [System.IO.File]::ReadAllText($nativeHook)
    Check 'install creates a managed native pre-push hook' ((Test-Path -LiteralPath $nativeHook) -and ($nativeBody -match 'Hook Maker: Ignore-Rules-Check'))
    Check 'install preserves an existing pre-push hook' (Test-Path -LiteralPath ($nativeHook + '.hookmaker-existing'))
    $prePushRuntime = Join-Path $pushRepo '.git\hooks\Hook-Maker'
    $ignoreCommand = $nativeBody.IndexOf('Ignore-Rules-Check.ps1')
    $secretsCommand = $nativeBody.IndexOf('Secrets-Check.ps1')
    $previousCommand = $nativeBody.IndexOf('.hookmaker-existing')
    Check 'pre-push bundles only the two push-safety checks' (
        (Test-Path -LiteralPath (Join-Path $prePushRuntime 'Ignore-Rules-Check\Ignore-Rules-Check.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $prePushRuntime 'Secrets-Check\Secrets-Check.ps1')) -and
        -not (Test-Path -LiteralPath (Join-Path $prePushRuntime 'Large-File-Check')) -and
        $nativeBody -notmatch 'Large-File-Check\.ps1')
    Check 'pre-push order is Ignore then Secrets then previous hook' (
        $ignoreCommand -ge 0 -and $ignoreCommand -lt $secretsCommand -and $secretsCommand -lt $previousCommand)

    $customRepo = New-Repo 'custom hooks path'
    & git -C $customRepo config core.hooksPath '.config/hooks nested'
    $customHooks = Join-Path $customRepo '.config\hooks nested'
    New-Item -ItemType Directory -Path $customHooks -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $customHooks 'pre-push'), "#!/bin/sh`necho custom > custom-hook.txt`n", (New-Object System.Text.UTF8Encoding $false))
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $customRepo -CodexOnly *> $null
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $customRepo -CodexOnly *> $null
    $customBody = [System.IO.File]::ReadAllText((Join-Path $customHooks 'pre-push'))
    Check 'relative custom hooksPath receives managed runtime without hooks/hooks duplication' (
        (Test-Path (Join-Path $customHooks 'Hook-Maker\Ignore-Rules-Check\Ignore-Rules-Check.ps1')) -and
        -not (Test-Path (Join-Path $customHooks 'hooks\Hook-Maker')))
    Check 'custom pre-push is preserved exactly once across reinstall' (
        (Test-Path (Join-Path $customHooks 'pre-push.hookmaker-existing')) -and
        ([regex]::Matches($customBody, 'Hook Maker: Ignore-Rules-Check').Count -eq 1))

    $absoluteRepo = New-Repo 'absolute hooks repo'
    $absoluteHooks = Join-Path $Work 'absolute hooks path'
    New-Item -ItemType Directory -Path $absoluteHooks -Force | Out-Null
    & git -C $absoluteRepo config core.hooksPath $absoluteHooks
    & $InstallScript -CustomHook $Hook -Events @('Stop') -TargetProject $absoluteRepo -CodexOnly *> $null
    Check 'absolute custom hooksPath with spaces receives the managed chain' (
        (Test-Path (Join-Path $absoluteHooks 'pre-push')) -and
        (Test-Path (Join-Path $absoluteHooks 'Hook-Maker\Secrets-Check\Secrets-Check.ps1')))

    $remote = Join-Path $Work 'remote.git'
    & git init -q --bare $remote
    & git -C $pushRepo remote add origin $remote
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'first push is blocked after auto-fixing missing ignore rules' ($pushExit -ne 0 -and $pushOutput -match 'IGNORE RULES CHECK' -and (Test-Path -LiteralPath (Join-Path $pushRepo '.gitignore'))) $pushOutput

    & git -C $pushRepo add .gitignore
    & git -C $pushRepo commit -q -m c2
    [System.IO.File]::WriteAllText((Join-Path $pushRepo '.env'), 'API_KEY=fixture-value-123456789', (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'leak.txt'), 'fixture-value-123456789', (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add leak.txt
    & git -C $pushRepo commit -q -m c2b
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'Secrets-Check blocks before the previous hook' ($pushExit -ne 0 -and $pushOutput -match 'SECRETS CHECK' -and -not (Test-Path -LiteralPath (Join-Path $pushRepo 'previous-hook.txt'))) $pushOutput

    # Fully discard the leak commit from HISTORY (not just add a later
    # "remove it" commit on top) - the outgoing-commit scan correctly still
    # flags a secret sitting in ANY commit that remains part of what is about
    # to be pushed, even one a later commit deletes again; the only real fix
    # is for the leak to never be part of the pushed range in the first place.
    & git -C $pushRepo reset -q --hard HEAD~1
    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'use.txt'), 'placeholder', (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllLines((Join-Path $pushRepo 'big.ps1'), @(1..801 | ForEach-Object { '# line' }), (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add use.txt big.ps1
    & git -C $pushRepo commit -q -m c3
    $largeHook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Large-File-Check\Large-File-Check.ps1'
    $largePrePushOutput = (& $largeHook -GitPrePush 2>&1 | Out-String)
    Check 'Large-File-Check never decides whether a push may proceed' ($LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($largePrePushOutput)) $largePrePushOutput
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'large source files do not block push and the previous hook runs' ($pushExit -eq 0 -and $pushOutput -notmatch 'LARGE FILE CHECK' -and (Test-Path -LiteralPath (Join-Path $pushRepo 'previous-hook.txt'))) $pushOutput

    [System.IO.File]::WriteAllText((Join-Path $pushRepo 'big.ps1'), '# small', (New-Object System.Text.UTF8Encoding $false))
    & git -C $pushRepo add big.ps1
    & git -C $pushRepo commit -q -m c4
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $pushRepo push -u origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'clean push succeeds and still runs the previous hook' ($pushExit -eq 0 -and (Test-Path -LiteralPath (Join-Path $pushRepo 'previous-hook.txt'))) $pushOutput

    # =====================================================================
    Write-Host '--- isolation: the real user config is never touched ---' -ForegroundColor Cyan
    # GetTempPath() sits UNDER the real user profile on Windows, and this suite
    # runs Install-Hook.ps1 several times; a workspace path leaking into the real
    # ~\.claude or ~\.codex config is a realistic failure, not theory.
    $realUserConfigs = @(
        (Join-Path $env:USERPROFILE '.claude\settings.json'),
        (Join-Path $env:USERPROFILE '.claude\settings.local.json'),
        (Join-Path $env:USERPROFILE '.codex\config.toml')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $leaked = @($realUserConfigs | Where-Object { [System.IO.File]::ReadAllText($_) -like ('*' + $Work + '*') })
    Check 'no fixture path ever leaks into the real ~\.claude / ~\.codex config' ($leaked.Count -eq 0) ($leaked -join ', ')
    # =====================================================================
    Write-Host ''
    Write-Host '--- an anchored mid-file negation is EFFECTIVE, so nothing is added (2026-09-20) ---' -ForegroundColor Cyan
    # The old liveness rule compared the negation's position against EVERY managed
    # positive that precedes it in the canonical list - including ones that cannot
    # possibly re-ignore the path, such as /plans/. Because the hook appends its own
    # block at the END, its own positives landed after a user's correctly-anchored
    # negations, so every run judged them dead and appended again, for ever. It was
    # reported from a consumer project and reproduced in this repository's own
    # .gitignore the same day.
    $anchored = New-Repo 'anchored'
    $anchoredIgnore = Join-Path $anchored '.gitignore'
    # The negations sit immediately after the rule they negate - correct gitignore -
    # and a managed positive that CANNOT match .env.example sits AFTER them.
    Write-Utf8 $anchoredIgnore (@(
            '/.ai/', '/secrets.md', '/.claude/', '/graphify-out/', '/.codebase-memory/',
            '/.specify/', '/specs/', '/explain-AI.md', '/reference.md', '/CLAUDE.md',
            '/AGENTS.md', '/.agents/', '/.kiro/', '/.codex/', '/.cursor/', '/.cline/',
            '.ignoreme', '**/.ignoreme',
            '/.env', '/.env.*',
            '!/.env.example', '!/.env.sample', '!/.env.template', '!/.env.dist',
            '/plans/'
        ) -join "`n")
    $before = [System.IO.File]::ReadAllText($anchoredIgnore)
    $r = Fire -Cwd $anchored -EventName 'SessionStart'
    $after = [System.IO.File]::ReadAllText($anchoredIgnore)
    Check 'anchored: the hook reports no missing pattern' (
        $r.Out -notmatch 'Auto-added') $r.Out
    Check 'anchored: the file is not modified at all' ($before -eq $after) (
        'len ' + $before.Length + ' -> ' + $after.Length)
    Check 'anchored: exactly one copy of each negation remains' (
        ([regex]::Matches($after, [regex]::Escape('!/.env.example'))).Count -eq 1) $after

    # Idempotence: a second consecutive run must also change nothing. The reported
    # symptom was accumulation - three copies after two runs.
    $r2 = Fire -Cwd $anchored -EventName 'SessionStart'
    $after2 = [System.IO.File]::ReadAllText($anchoredIgnore)
    Check 'anchored: a second run is idempotent' ($after -eq $after2) (
        'copies: ' + ([regex]::Matches($after2, [regex]::Escape('!/.env.example'))).Count)
    Check 'anchored: still exactly one copy after two runs' (
        ([regex]::Matches($after2, [regex]::Escape('!/.env.example'))).Count -eq 1) $after2

    # The negative control: a negation that git says is NOT effective (sorted above
    # its own ignore rule) is still re-added, which is what the rule exists for.
    $sorted = New-Repo 'sorted'
    $sortedIgnore = Join-Path $sorted '.gitignore'
    Write-Utf8 $sortedIgnore (@(
            '!/.env.example', '!/.env.sample', '!/.env.template', '!/.env.dist',
            '/.env', '/.env.*'
        ) -join "`n")
    $rs = Fire -Cwd $sorted -EventName 'SessionStart'
    Check 'sorted: a negation hoisted above its ignore rule IS re-added' (
        $rs.Out -match 'Auto-added' -and $rs.Out -match '!/\.env\.example') $rs.Out

    # =====================================================================
    # A session whose cwd drifted into a SUBFOLDER (2026-09-26, two projects):
    # the hook created logs\.gitignore with the whole rooted protected set while
    # the root .gitignore already carried every pattern. The repository root is
    # the git top level, not the hook input's cwd.
    Write-Host '--- cwd drift: the repository root is the git top level ---' -ForegroundColor Cyan
    $drift = New-Repo 'drift'
    $null = Fire -Cwd $drift -EventName 'SessionStart'
    $driftRootIgnore = Join-Path $drift '.gitignore'
    $driftBefore = [System.IO.File]::ReadAllText($driftRootIgnore)
    $driftSub = Join-Path $drift 'logs'
    New-Item -ItemType Directory -Path $driftSub -Force | Out-Null
    $rd = Fire -Cwd $driftSub -EventName 'SessionStart'
    Check 'drift: a complete root .gitignore -> no .gitignore is created in the subfolder' (
        -not (Test-Path -LiteralPath (Join-Path $driftSub '.gitignore'))) $rd.Out
    Check 'drift: the root .gitignore is left byte-for-byte unchanged' (
        [System.IO.File]::ReadAllText($driftRootIgnore) -ceq $driftBefore) ''
    Check 'drift: nothing is auto-added when the root is already complete' ($rd.Out -notmatch 'Auto-added') $rd.Out
    $rd = Fire -Cwd $driftSub
    Check 'drift: Stop from the subfolder stays silent too' ($rd.Exit -eq 0 -and $rd.Out -eq '' -and
        -not (Test-Path -LiteralPath (Join-Path $driftSub '.gitignore'))) $rd.Out

    # An INCOMPLETE root reached from a subfolder is repaired AT THE ROOT.
    $driftIncomplete = New-Repo 'drift-incomplete'
    $driftDeep = Join-Path $driftIncomplete 'src\deep'
    New-Item -ItemType Directory -Path $driftDeep -Force | Out-Null
    $ri = Fire -Cwd $driftDeep -EventName 'SessionStart'
    $rootText = if (Test-Path -LiteralPath (Join-Path $driftIncomplete '.gitignore')) { [System.IO.File]::ReadAllText((Join-Path $driftIncomplete '.gitignore')) } else { '' }
    Check 'drift: missing patterns are added to the ROOT .gitignore' ($rootText -match '(?m)^/\.ai/$' -and $rootText -match '(?m)^/secrets\.md$') $ri.Out
    Check 'drift: and never to the subfolder the session was in' (
        -not (Test-Path -LiteralPath (Join-Path $driftDeep '.gitignore')) -and
        -not (Test-Path -LiteralPath (Join-Path $driftIncomplete 'src\.gitignore'))) $ri.Out
    Check 'drift: the report names the repository root, not the subfolder' (
        $ri.Out.Replace('\\', '\').Contains('IGNORE RULES CHECK (' + $driftIncomplete + ')')) $ri.Out

    # Outside a git work tree the hook keeps its old behaviour: it does nothing.
    $plainFolder = Join-Path $Work 'not-a-repo\sub'
    New-Item -ItemType Directory -Path $plainFolder -Force | Out-Null
    $rp = Fire -Cwd $plainFolder -EventName 'SessionStart'
    Check 'drift: a non-git folder is still left alone' ($rp.Exit -eq 0 -and $rp.Out -eq '' -and
        -not (Test-Path -LiteralPath (Join-Path $plainFolder '.gitignore'))) $rp.Out
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
