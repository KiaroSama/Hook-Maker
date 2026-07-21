# Secrets-Check - keeps a project's secrets.md registry accurate and safe.
#
# Every discovered .env* key is classified before anything else applies:
#   Secret       - registered in secrets.md, scanned for leaks, can block a push.
#   PublicConfig - ordinary public configuration (a public URL, a public bucket
#                  name, a region, ...) - never registered, never leak-scanned,
#                  never blocks a push merely for appearing in tracked files.
#   Unknown      - mixed/insufficient evidence - reported as an ADVISORY asking
#                  for explicit classification (SECRET_KEYS/PUBLIC_CONFIG_KEYS
#                  in .env), never silently treated as safe, never a confirmed
#                  leak from a bare value match alone, and NEVER blocking on
#                  its own (only a real critical finding - a confirmed leak,
#                  tracked/staged secrets.md or real .env*, or a fail-closed
#                  outgoing scan - can produce decision:block on Stop).
# Classification order (precedence, strongest first):
#   SECRET_KEYS override > DEFINITE credential VALUE format > credential-like
#   KEY evidence > PUBLIC_CONFIG_KEYS override > entropy-HEURISTIC value
#   evidence > inferred public config (public-looking key AND a recognized
#   public value shape) > Unknown.
# The two value tiers are split on purpose. A definite format (private key,
# JWT, sk_live_, AKIA, user:pass@host, ...) IDENTIFIES a credential and is
# never overridable. "Long, opaque, mixed charset" only GUESSES, and it fires
# on values that are public by design - a Turnstile SITE key, a Cloudflare
# account ID, a publishable key - so it sits below PUBLIC_CONFIG_KEYS and can
# be corrected per key. Its default answer is unchanged (still Secret).
# A key prefix (NEXT_PUBLIC_, PUBLIC_, VITE_, REACT_APP_) is never sufficient
# by itself to call something safe - it requires BOTH a public-looking key
# AND a recognizable public value shape (Test-PublicConfigValue); an opaque
# unrecognized value under a "public" prefix stays Unknown, never PublicConfig.
# Real credential evidence (key semantics like TOKEN/SECRET/API_KEY/PASSWORD,
# or a credential-shaped value) always wins and classifies as Secret
# regardless of a "public" prefix, and PUBLIC_CONFIG_KEYS can never declassify
# it (credential evidence is checked before the override is ever consulted).
# Key-semantic matching is token/boundary-aware, not a raw substring match:
# AUTHOR_NAME, AUTH0_DOMAIN, NEXT_PUBLIC_AUTH_URL, and AUTH_CALLBACK_URL are
# never Secret merely for containing the letters "AUTH" - a bare AUTH/OAUTH
# token only counts when paired with another credential token in the same key
# (AUTH_TOKEN, BASIC_AUTH_PASSWORD, OAUTH_CLIENT_SECRET).
#
# Checks (pre-task SessionStart + post-task Stop):
# - secrets.md exists but is NOT git-ignored, or is tracked/staged in git -> CRITICAL.
# - Any real .env* file (not a .example/.sample/.template) is itself tracked -> CRITICAL.
# - A discovered secret VALUE turns up inside a git-TRACKED file elsewhere in the
#   repo (git grep across BOTH the working tree and the index/staged content,
#   merged and deduplicated by path; filenames only, value never printed). The
#   scan is grouped BY VALUE, not by key, so several keys holding one value
#   (ADMIN_EMAIL/OWNER_EMAIL/KYC_ADMIN_EMAIL) produce ONE finding naming all of
#   them, instead of the same file list repeated per key ->
#   CRITICAL "possible leak". The index scan catches a value that is staged but
#   already removed from the working copy, or committed and later edited away
#   locally without staging that edit - either state stays invisible to a
#   working-tree-only grep.
# - -GitPrePush ALSO scans the exact commits about to be pushed, resolved from
#   git's real pre-push ref-update stdin ("<local ref> <local sha> <remote ref>
#   <remote sha>"), not just the current working tree/index - a value can be
#   fully cleaned up locally (working tree AND index) while an earlier commit
#   still being pushed keeps it, or a value can be introduced and removed again
#   entirely within the outgoing range and still ship as reachable history.
#   New branches (remote sha all-zero) are scoped to commits not already on any
#   remote-tracking ref; deletions (local sha all-zero) push nothing and are
#   skipped; force-pushes/non-fast-forwards use the same `<remote>..<local>`
#   range, which does not require fast-forward ancestry. The outgoing scan does
#   NOT exclude .env*/secrets.md (unlike the current-file scan): a committed
#   real .env or registry file in outgoing history is itself a leak even if it
#   was later deleted/untracked before the push. It FAILS CLOSED - the whole
#   range is scanned in bounded batches (no commit cap), and if any ref range
#   cannot be resolved or a batch grep errors, the push is BLOCKED with a safe
#   message rather than being treated as clean.
#   LIMITATION: this is a value-based leak guard, not a full entropy/pattern/
#   history secret scanner - it can only search for values it currently knows,
#   and the ONLY source of those values is the active .env* files. secrets.md
#   is read to check whether a key is already DOCUMENTED and for the unused-key
#   scan; its recorded values are never themselves leak-scanned. So a secret
#   that lives only in secrets.md or only in the deployment secret store - one
#   rotated out of .env, or never kept there - is invisible to this scan. A
#   secret introduced and later removed from BOTH outgoing history AND every current
#   source is no longer known and cannot be matched; use a dedicated
#   historical secret scanner in CI for unknown credentials.
# - Secret KEYs found in .env* files but missing from secrets.md are AUTO-APPENDED
#   to secrets.md (created if absent) with their real value copied in - never
#   printed, logged, or echoed anywhere, only the KEY NAME appears in reports/logs.
# - Values that look like empty placeholders (TODO, changeme, xxx, <...>, ...)
#   are flagged by key name.
# - Periodically (long cooldown - this is a heavier scan, not a per-session one):
#   secrets.md entries (## KEY headings) that are never referenced anywhere else
#   in the tracked project are flagged as possibly unused. NEVER auto-removed -
#   a false positive would destroy an unrecoverable credential, so removal is
#   always the AI's call, same as every other advisory hook in this project.
#
# This hook never makes network calls and never tests a secret against its real
# service (that would risk rate limits/unintended use); "valid" here means
# "non-placeholder and still referenced in the project", not "live-tested".
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES               minutes between repeated non-critical reports (default 60)
#   UNUSED_SCAN_COOLDOWN_MINUTES    minutes between the heavier unused-secret scan (default 10080 = 7 days)
#   AUTO_APPEND                    true/false - write missing secrets into secrets.md (default true)
#   MIN_SECRET_LENGTH              values shorter than this are skipped in the leak scan (default 8)

param([switch]$GitPrePush)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = if ($GitPrePush) {
    [pscustomobject]@{ cwd = (Get-Location).Path; hook_event_name = 'GitPrePush' }
}
else {
    Read-HookInput
}
if ($null -eq $hookInput) {
    exit 0
}
# Native `pre-push` hooks receive ref-update lines on stdin:
# "<local ref> <local sha1> <remote ref> <remote sha1>", one per pushed ref -
# NOT JSON, so this reads raw text instead of Read-HookInput. The managed
# pre-push wrapper tees the real stdin into a temp file and feeds the SAME
# file to every stage, so reading it here does not consume it for the rest
# of the chain or the preserved previous hook.
$refUpdateLines = @()
if ($GitPrePush) {
    try {
        $rawRefUpdates = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($rawRefUpdates)) {
            $refUpdateLines = @($rawRefUpdates -split '\r?\n' | Where-Object { $_.Trim() -ne '' })
        }
    }
    catch { }
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) {
    $eventName = 'SessionStart'
}
$isStopEvent = ($GitPrePush -or $eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')
if (-not $GitPrePush -and $isStopEvent -and (Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 60
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}
$unusedScanCooldownMinutes = 10080
if ($config.ContainsKey('UNUSED_SCAN_COOLDOWN_MINUTES')) {
    try { $unusedScanCooldownMinutes = [int]$config['UNUSED_SCAN_COOLDOWN_MINUTES'] } catch { }
}
$autoAppend = $true
if ($config.ContainsKey('AUTO_APPEND') -and $config['AUTO_APPEND'] -match '^(false|0|no)$') {
    $autoAppend = $false
}
$minSecretLength = 8
if ($config.ContainsKey('MIN_SECRET_LENGTH')) {
    try { $minSecretLength = [int]$config['MIN_SECRET_LENGTH'] } catch { }
}

# ---- Secret / PublicConfig / Unknown classification ----
# A key living in .env* is not automatically a credential: NEXT_PUBLIC_APP_URL
# and R2_BUCKET are ordinary public configuration, not secrets. Classification
# considers BOTH key semantics and value shape - a key prefix alone (PUBLIC_,
# NEXT_PUBLIC_, VITE_, ...) is never sufficient to call something safe, and it
# never overrides real credential evidence (PUBLIC_API_TOKEN, NEXT_PUBLIC_API_KEY
# with a live-looking key still classify as Secret).
function Get-KeyOverrideList {
    param([string]$Raw)
    # Caller always wraps the call with @(...) - never rely on the internal
    # return value alone: a bare `return $list` collapses to a scalar (no
    # array semantics) under StrictMode when the list holds 0 or 1 items.
    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $result.ToArray() }
    foreach ($tok in $Raw.Split(',')) {
        $t = $tok.Trim().ToUpperInvariant()
        if ($t -eq '' -or $t -eq '*') { continue }    # reject empty/overly broad
        [void]$result.Add($t)
    }
    return $result.ToArray()
}
function Test-KeyMatchesOverride {
    param([string]$UpperKey, [string[]]$Overrides)
    foreach ($entry in $Overrides) {
        if ($entry.EndsWith('*')) {
            if ($UpperKey.StartsWith($entry.TrimEnd('*'))) { return $true }
        }
        elseif ($UpperKey -eq $entry) { return $true }
    }
    return $false
}
$secretKeysRaw = ''
if ($config.ContainsKey('SECRET_KEYS')) { $secretKeysRaw = $config['SECRET_KEYS'] }
$publicConfigKeysRaw = ''
if ($config.ContainsKey('PUBLIC_CONFIG_KEYS')) { $publicConfigKeysRaw = $config['PUBLIC_CONFIG_KEYS'] }
$secretKeyOverrides = @(Get-KeyOverrideList $secretKeysRaw)
$publicConfigKeyOverrides = @(Get-KeyOverrideList $publicConfigKeysRaw)

$script:PublicKeyPrefixes = @('NEXT_PUBLIC_', 'PUBLIC_', 'VITE_', 'REACT_APP_')
$script:PublicKeySuffixes = @(
    '_URL', '_ORIGIN', '_HOST', '_HOSTNAME', '_PORT', '_REGION', '_BUCKET', '_BUCKET_NAME',
    '_ENV', '_ENVIRONMENT', '_PUBLIC_ID', '_PROJECT_ID', '_APP_ID', '_SITE_ID', '_WORKER_NAME', '_SERVICE_NAME'
)
$script:PublicKeyContains = @('FEATURE')

# Value-shape evidence, in TWO TIERS that are deliberately not equally strong.
#
# STRONG (-StrongOnly): a definite FORMAT match - private-key material,
# bearer/JWT tokens, known live-credential formats (Stripe/GitHub/Slack/AWS/
# Google), a connection string with an embedded username:password, or a
# token/password query parameter. These identify a credential by its published
# shape, so they are never overridable: PUBLIC_CONFIG_KEYS must not be able to
# declassify a real private key because someone listed the wrong key name.
#
# HEURISTIC (the default, second tier): "long, no whitespace, mixes
# upper/lower/digit, not a URL". That is a GUESS, not an identification, and it
# has a large false-positive surface - a Cloudflare Turnstile SITE key (public
# by design, meant to be rendered into client HTML), a Cloudflare account ID
# (public in R2/worker URLs), a publishable API key, or any 24+ character
# public identifier trips it. Because it is a guess it sits BELOW the
# PUBLIC_CONFIG_KEYS override in Get-KeyValueClassification, so a project can
# declassify a specific key it knows to be public. Its default answer is
# unchanged: with no override, a heuristic match is still Secret.
#
# An e-mail address is excluded from the heuristic outright: an address is not
# a credential under any definition, and a 24+ character address with a digit
# and a capital is ordinary. A credential that merely CONTAINS an address
# (user:pass@host) is caught by the strong tier above and does not reach here;
# a secret stored under a credential-named key (SMTP_PASSWORD) is caught by
# Test-CredentialLikeKey, which is also unoverridable.
function Test-CredentialLikeValue {
    param([string]$Value, [switch]$StrongOnly)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') { return $true }
    if ($Value -match '^Bearer\s+\S+') { return $true }
    if ($Value -match '^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { return $true }
    if ($Value -match '^(sk|pk|rk)_(live|test)_[A-Za-z0-9]{10,}$') { return $true }
    if ($Value -match '^gh[pousr]_[A-Za-z0-9]{20,}$' -or $Value -match '^github_pat_[A-Za-z0-9_]{20,}$') { return $true }
    if ($Value -match '^xox[baprs]-[A-Za-z0-9-]{10,}$') { return $true }
    if ($Value -match '^AKIA[0-9A-Z]{16}$') { return $true }
    if ($Value -match '^AIza[0-9A-Za-z_-]{35}$') { return $true }
    if ($Value -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/@\s]+:[^/@\s]+@') { return $true }
    if ($Value -match '(?i)[?&](token|access_token|api_key|apikey|password|secret)=[^&\s]+') { return $true }
    if ($StrongOnly) { return $false }
    if ($Value -match '^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$') { return $false }    # an address is not a credential
    if ($Value -notmatch '\s' -and $Value.Length -ge 24 -and
        $Value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://' -and
        $Value -match '[A-Z]' -and $Value -match '[a-z]' -and $Value -match '[0-9]') {
        return $true
    }
    return $false
}

# Token/boundary-aware key-semantic matcher (never a raw substring): the key
# is split on separators (_ - .) into whole tokens, so AUTHOR_NAME, AUTH0_DOMAIN,
# NEXT_PUBLIC_AUTH_URL, and AUTH_CALLBACK_URL never match merely for containing
# the letters "AUTH" - "AUTHOR" and "AUTH0" are each a DIFFERENT whole token
# than "AUTH", and a bare AUTH/OAUTH token only counts when it co-occurs with
# another credential-indicating token (AUTH_TOKEN, BASIC_AUTH_PASSWORD,
# OAUTH_CLIENT_SECRET) - "AUTH" alone (paired only with CALLBACK/URL/etc.) is
# not enough.
function Test-CredentialLikeKey {
    param([string]$UpperKey)
    $tokens = @($UpperKey -split '[_\-.]' | Where-Object { $_ -ne '' })
    $tokenSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($t in $tokens) { [void]$tokenSet.Add($t) }

    # Credential-indicating on their own, as an exact separator-bound token.
    foreach ($word in @('SECRET', 'TOKEN', 'PASSWORD', 'PASSWD', 'CREDENTIAL', 'CREDENTIALS')) {
        if ($tokenSet.Contains($word)) { return $true }
    }
    # AUTH/OAUTH alone is not sufficient - only Secret when paired with
    # another credential-indicating token in the same key.
    if ($tokenSet.Contains('AUTH') -or $tokenSet.Contains('OAUTH')) {
        foreach ($word in @('TOKEN', 'SECRET', 'PASSWORD', 'PASSWD', 'CREDENTIAL', 'CREDENTIALS', 'KEY')) {
            if ($tokenSet.Contains($word)) { return $true }
        }
    }
    # Compound established names, still boundary-aware (a whole `_`-delimited
    # phrase, not a raw Contains).
    foreach ($pattern in @('PRIVATE_KEY', 'CLIENT_SECRET', 'API_KEY', 'ACCESS_KEY', 'SIGNING_KEY', 'WEBHOOK_SECRET', 'SESSION_KEY', 'ENCRYPTION_KEY')) {
        if ($UpperKey -match ('(^|_)' + $pattern + '($|_)')) { return $true }
    }
    return $false
}

# True only for a clearly non-sensitive, recognizable PUBLIC configuration
# value shape. A public-looking KEY is never enough by itself (see
# Get-KeyValueClassification) - the VALUE must also look like real public
# config, so an opaque unrecognized value (e.g. a bare 32-character opaque
# string) stays Unknown even under a NEXT_PUBLIC_/PUBLIC_ prefix.
function Test-PublicConfigValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '\s') { return $false }
    if (Test-CredentialLikeValue $Value) { return $false }    # never public if it looks like a credential

    if ($Value -match '^(?i:true|false)$') { return $true }    # boolean

    if ($Value -match '^\d{1,5}$') {    # numeric port
        $portNum = [int]$Value
        if ($portNum -ge 1 -and $portNum -le 65535) { return $true }
    }

    if ($Value -match '^(?i:development|dev|test|staging|preview|production|prod)$') { return $true }

    if ($Value -match '^(\d{1,3}\.){3}\d{1,3}$') { return $true }    # IPv4

    if ($Value -match '^https?://') { return $true }    # embedded creds/credential query params already excluded above

    # hostname/domain (dotted labels, no scheme, no path/spaces)
    if ($Value.Length -le 253 -and $Value -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$') { return $true }

    # short opaque alphabetic code - typical of region/environment shorthand
    # (weur, enam, apac, ...); length alone is what distinguishes a real short
    # code from a long opaque placeholder value.
    if ($Value -match '^[a-z]{2,6}$') { return $true }

    # bounded bucket/container/service/worker/project-id name: must show real
    # word-like structure (a separator or a digit) - a bare long repeated/
    # opaque run of letters (e.g. 32 "a"s) is NOT a recognized public shape
    # and falls through to Unknown.
    if ($Value.Length -ge 3 -and $Value.Length -le 63 -and
        $Value -match '^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$' -and
        ($Value -match '[-._]' -or $Value -match '\d')) {
        return $true
    }

    return $false
}

# Classification order. PUBLIC_CONFIG_KEYS can never override IDENTIFIED
# credential evidence - a definite value format or credential key semantics -
# but it CAN override the entropy heuristic, which is only a guess:
#   1. Explicit SECRET_KEYS override
#   2. Definite credential VALUE format          (unoverridable)
#   3. Credential-like KEY evidence              (unoverridable)
#   4. Explicit PUBLIC_CONFIG_KEYS override
#   5. Entropy-heuristic VALUE evidence          (default Secret, overridable by 4)
#   6. Public-looking key semantics AND a recognized public value shape
#   7. Unknown
#
# Steps 2 and 3 sit above the override on purpose: PUBLIC_CONFIG_KEYS must
# never be able to declassify a private key, a live token, or a value stored
# under a name like DB_PASSWORD. Step 5 sits below it because "long and opaque"
# is not an identification - it is exactly where the public site keys, public
# account IDs and publishable keys land, and before this ordering a project had
# NO way to correct that: the block was unclearable by any configuration.
# Default behaviour is unchanged - with no override set, step 5 still returns
# Secret, so nothing becomes silently unprotected.
function Get-KeyValueClassification {
    param([string]$Key, [string]$Value)
    $upperKey = $Key.ToUpperInvariant()
    if (Test-KeyMatchesOverride $upperKey $secretKeyOverrides) { return 'Secret' }
    if (Test-CredentialLikeValue $Value -StrongOnly) { return 'Secret' }
    if (Test-CredentialLikeKey $upperKey) { return 'Secret' }
    if (Test-KeyMatchesOverride $upperKey $publicConfigKeyOverrides) { return 'PublicConfig' }
    if (Test-CredentialLikeValue $Value) { return 'Secret' }
    $isPublicShape = $false
    foreach ($prefix in $script:PublicKeyPrefixes) { if ($upperKey.StartsWith($prefix)) { $isPublicShape = $true; break } }
    if (-not $isPublicShape) {
        foreach ($suffix in $script:PublicKeySuffixes) { if ($upperKey.EndsWith($suffix)) { $isPublicShape = $true; break } }
    }
    if (-not $isPublicShape) {
        foreach ($contains in $script:PublicKeyContains) { if ($upperKey.Contains($contains)) { $isPublicShape = $true; break } }
    }
    if ($isPublicShape -and (Test-PublicConfigValue $Value)) { return 'PublicConfig' }
    return 'Unknown'
}

# Conservative cleanup of entries THIS hook itself previously auto-added (the
# "(auto-added by Secrets-Check)" marker) that now classify as PublicConfig.
# Never touches a user-authored entry, and never removes anything whose
# provenance is unclear - only exact auto-added blocks for a key that
# currently classifies as PublicConfig are dropped.
function Remove-StalePublicConfigEntries {
    param([string]$Content, [hashtable]$Discovered)
    if ($Content -notmatch '\(auto-added by Secrets-Check\)') {
        return [pscustomobject]@{ Content = $Content; Removed = @() }
    }
    $parts = [regex]::Split($Content, '(?=(?m)^## )')
    $removed = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($part in $parts) {
        if ($part -notmatch '(?m)^## (\S+)') { [void]$kept.Add($part); continue }
        $blockKey = $Matches[1]
        $isAutoAdded = $part -match '\(auto-added by Secrets-Check\)'
        $classification = if ($Discovered.ContainsKey($blockKey)) { $Discovered[$blockKey].Classification } else { $null }
        if ($isAutoAdded -and $classification -eq 'PublicConfig') {
            [void]$removed.Add($blockKey)
            continue
        }
        [void]$kept.Add($part)
    }
    if ($removed.Count -eq 0) { return [pscustomobject]@{ Content = $Content; Removed = @() } }
    return [pscustomobject]@{ Content = ($kept.ToArray() -join ''); Removed = @($removed.ToArray()) }
}

# ---- discover real .env* files in active project trees ----
$excludedDirs = @('.git', 'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target', 'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env', '.ai', 'graphify-out', '.claude', '.codex', '.agents', 'bin', 'obj')
$envFiles = New-Object System.Collections.Generic.List[object]
$rootFull = (Get-Item -LiteralPath $cwd).FullName.TrimEnd('\', '/')
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($rootFull)
while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    try {
        foreach ($filePath in [System.IO.Directory]::EnumerateFiles($current, '.env*', [System.IO.SearchOption]::TopDirectoryOnly)) {
            $leaf = Split-Path -Leaf $filePath
            if ($leaf -notmatch '(?i)\.(example|sample|template|dist)$') {
                $relative = $filePath.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
                [void]$envFiles.Add([pscustomobject]@{ FullName = $filePath; Name = $relative })
            }
        }
        foreach ($dirPath in [System.IO.Directory]::EnumerateDirectories($current)) {
            $dir = Get-Item -LiteralPath $dirPath -Force -ErrorAction SilentlyContinue
            if ($null -eq $dir -or ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
            if ($excludedDirs -notcontains $dir.Name.ToLowerInvariant()) { $stack.Push($dir.FullName) }
        }
    }
    catch { }
}
$envFiles = @($envFiles.ToArray() | Sort-Object Name)

$secretsPath = Join-Path $cwd 'secrets.md'
$secretsExists = Test-Path -LiteralPath $secretsPath -PathType Leaf

# Nothing to look at: no candidate secret files and no existing registry -> silent.
# EXCEPTION: a -GitPrePush invocation with real ref-update lines still continues,
# so an unresolvable/incomplete outgoing range fails closed (blocks the push)
# even when there are no known secret values to search for - a security gate
# must not authorize a push it could not actually scan.
if ($envFiles.Count -eq 0 -and -not $secretsExists -and -not ($GitPrePush -and $refUpdateLines.Count -gt 0)) {
    exit 0
}

# ---- collect discovered secrets: KEY -> {Value, SourceFile, Classification} (later file wins) ----
$discovered = @{}
foreach ($file in $envFiles) {
    $values = Read-HookEnv $file.FullName
    foreach ($key in $values.Keys) {
        $discovered[$key] = [pscustomobject]@{
            Value = $values[$key]; Source = $file.Name; SourcePath = $file.FullName
            Classification = (Get-KeyValueClassification -Key $key -Value $values[$key])
        }
    }
}

function Test-PlaceholderValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $Value -match '^(todo|changeme|change_me|change-me|your[-_].*|x{3,}|<.*>|\.\.\.|test|example|placeholder|fixme|redacted|n/a|none|null)$'
}

$secretsContent = ''
if ($secretsExists) {
    try { $secretsContent = [System.IO.File]::ReadAllText($secretsPath, [System.Text.Encoding]::UTF8) } catch { }
}

function Test-KeyDocumented {
    param([string]$Key, [string]$Content)
    if ($Content -eq '') { return $false }
    return [regex]::IsMatch($Content, '\b' + [regex]::Escape($Key) + '\b')
}

# ---- conservative cleanup: drop this hook's own stale auto-added PublicConfig entries ----
$removedPublicConfigKeys = @()
if ($secretsExists) {
    $cleanup = Remove-StalePublicConfigEntries -Content $secretsContent -Discovered $discovered
    if (@($cleanup.Removed).Count -gt 0) {
        try {
            [System.IO.File]::WriteAllText($secretsPath, $cleanup.Content, [System.Text.UTF8Encoding]::new($false))
            $secretsContent = $cleanup.Content
            $removedPublicConfigKeys = @($cleanup.Removed)
        }
        catch { }    # could not write - do not claim a removal that did not happen
    }
}

# ---- auto-append missing SECRETS only (additive only - never overwrites/removes).
# PublicConfig keys are never registry material; Unknown keys are never
# silently added either - they need an explicit classification first. ----
$added = New-Object System.Collections.Generic.List[string]
$missingUndocumented = New-Object System.Collections.Generic.List[string]
$needsClassification = New-Object System.Collections.Generic.List[string]
foreach ($key in @($discovered.Keys | Sort-Object)) {
    $classification = $discovered[$key].Classification
    if ($classification -eq 'PublicConfig') { continue }
    if ($classification -eq 'Unknown') {
        if (-not (Test-KeyDocumented -Key $key -Content $secretsContent)) { [void]$needsClassification.Add($key) }
        continue
    }
    if (Test-KeyDocumented -Key $key -Content $secretsContent) { continue }
    if ($autoAppend) {
        [void]$added.Add($key)
    }
    else {
        [void]$missingUndocumented.Add($key)
    }
}
if ($added.Count -gt 0) {
    if (-not $secretsExists) {
        $header = "# Secrets`n`nLocal-only registry of real secrets for this project. This file must stay" +
            " git-ignored and must never be committed, printed, or shared.`n"
        $secretsContent = $header
    }
    $entryLines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $added) {
        $entry = $discovered[$key]
        [void]$entryLines.Add('')
        [void]$entryLines.Add('## ' + $key)
        [void]$entryLines.Add('- Purpose: TODO - describe what this secret is used for')
        [void]$entryLines.Add('- Used by: (auto-detected from ' + $entry.Source + '; update if used elsewhere)')
        [void]$entryLines.Add('- Source: ' + $entry.SourcePath)
        [void]$entryLines.Add('- Created: ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd') + ' (auto-added by Secrets-Check)')
        [void]$entryLines.Add('- Value: ' + $entry.Value)
    }
    $newContent = $secretsContent.TrimEnd() + "`n" + ($entryLines.ToArray() -join "`n") + "`n"
    try {
        [System.IO.File]::WriteAllText($secretsPath, $newContent, [System.Text.UTF8Encoding]::new($false))
        $secretsExists = $true
        $secretsContent = $newContent
    }
    catch {
        # Could not write (permissions, read-only, ...) - fall back to reporting only.
        [void]$missingUndocumented.AddRange($added)
        $added.Clear()
    }
}

$placeholders = New-Object System.Collections.Generic.List[string]
foreach ($key in @($discovered.Keys | Sort-Object)) {
    if ($discovered[$key].Classification -ne 'Secret') { continue }
    if (Test-PlaceholderValue $discovered[$key].Value) {
        [void]$placeholders.Add($key)
    }
}

# Resolves the COMPLETE set of commits about to be pushed from real pre-push
# ref-update lines: "<local ref> <local sha1> <remote ref> <remote sha1>". A
# deletion (local sha all-zero) pushes nothing and is skipped. A brand-new ref
# (remote sha all-zero) is scoped to commits reachable from local but not from
# ANY existing remote ref (avoids rescanning old, already-reviewed history).
# Otherwise it is exactly `<remote>..<local>` - reachable from local, not from
# remote - correct for normal updates AND force-pushes/non-fast-forwards alike
# (git range syntax does not require fast-forward ancestry). Multiple ref lines
# are unioned and deduped.
#
# This is a security-authorization boundary, so it FAILS CLOSED: there is no
# commit cap (a huge range is scanned in bounded batches by the caller, not
# truncated), and any ref whose range cannot be resolved - a `rev-list`
# failure, or a remote sha that is not a resolvable commit object locally -
# is recorded in .Errors instead of being silently skipped. The caller turns
# a non-empty .Errors into a hard block, so an incomplete scan can never be
# mistaken for a clean one.
function Get-OutgoingCommits {
    param([string]$Cwd, [string[]]$RefUpdateLines)
    $allZero = '0' * 40
    $commits = New-Object System.Collections.Generic.HashSet[string]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($line in $RefUpdateLines) {
        $parts = @($line.Trim() -split '\s+')
        if ($parts.Count -lt 4) { continue }
        $localRef = $parts[0]
        $localSha = $parts[1]
        $remoteSha = $parts[3]
        if ($localSha -eq $allZero) { continue }    # deletion - nothing pushed
        if ($remoteSha -eq $allZero) {
            $revs = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'rev-list', $localSha, '--not', '--remotes') | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                [void]$errors.Add('new ref ' + $localRef + ' - outgoing commits could not be resolved (rev-list failed); refusing to treat it as clean')
                continue
            }
        }
        else {
            # The remote sha must be a locally-resolvable commit to bound the
            # range; if it is not (unknown object), fail closed rather than
            # scanning an unbounded or wrong range.
            $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'rev-parse', '--verify', '--quiet', ($remoteSha + '^{commit}'))
            if ($LASTEXITCODE -ne 0) {
                $shortRemote = if ($remoteSha.Length -gt 7) { $remoteSha.Substring(0, 7) } else { $remoteSha }
                [void]$errors.Add('ref ' + $localRef + ' - remote commit ' + $shortRemote + ' is not resolvable locally, so the outgoing range cannot be bounded; refusing to treat it as clean')
                continue
            }
            $revs = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'rev-list', ($remoteSha + '..' + $localSha)) | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                [void]$errors.Add('ref ' + $localRef + ' - outgoing commits could not be resolved (rev-list failed); refusing to treat it as clean')
                continue
            }
        }
        foreach ($rev in $revs) { [void]$commits.Add([string]$rev) }
    }
    return [pscustomobject]@{ Commits = @($commits); Errors = @($errors) }
}

# Runs the exact-value `git grep` across a set of outgoing commit trees in
# BOUNDED batches (never one giant command line), so an arbitrarily large
# outgoing range is fully scanned without truncation. Returns the matching
# "<sha>:<path>" lines and a hard-error flag: `git grep` exit >1 is a real
# error (not "no match", which is exit 1) and must fail the scan closed.
function Invoke-OutgoingGrepBatched {
    param([string]$Cwd, [string]$Value, [string[]]$Commits, [int]$BatchSize = 200)
    $hits = New-Object System.Collections.Generic.List[string]
    $hadError = $false
    for ($i = 0; $i -lt $Commits.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize, $Commits.Count) - 1
        $batch = @($Commits[$i..$end])
        # -e marks $Value as the pattern so a value starting with '-' (a PEM
        # "-----BEGIN..." header, a Django key like "-Abc123...") can't be parsed
        # as a git option. Unlike the sibling scans below, $batch here is trailing
        # REVISIONS, not pathspecs - '--' would push them past a pathspec boundary
        # instead, so the outgoing commits would silently NOT be searched (fail
        # OPEN). '-e' keeps $batch as revisions while still disambiguating $Value.
        $out = Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $Cwd, 'grep', '-Il', '-F', '-e', $Value) + $batch)
        $code = $LASTEXITCODE
        if ($code -gt 1) { $hadError = $true; continue }
        foreach ($m in @($out | Where-Object { $_ })) { [void]$hits.Add([string]$m) }
    }
    return [pscustomobject]@{ Hits = @($hits); HadError = $hadError }
}

# ---- git-based checks: ignore/tracked/staged/leak/outgoing (skipped outside a git repo) ----
$critical = New-Object System.Collections.Generic.List[string]
$inGitRepo = $false
if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
    $inGitRepo = ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
}
$outgoingCommits = @()
$outgoingResolveErrors = @()
if ($inGitRepo -and $GitPrePush -and $refUpdateLines.Count -gt 0) {
    $outgoing = Get-OutgoingCommits -Cwd $cwd -RefUpdateLines $refUpdateLines
    $outgoingCommits = @($outgoing.Commits)
    $outgoingResolveErrors = @($outgoing.Errors)
}
$outgoingScanFailedClosed = $false

if ($inGitRepo) {
    if ($secretsExists) {
        $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'check-ignore', '-q', '--', 'secrets.md')
        if ($LASTEXITCODE -ne 0) {
            [void]$critical.Add('secrets.md exists but is NOT covered by .gitignore.')
        }
        $tracked = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'ls-files', '--', 'secrets.md')
        if ($LASTEXITCODE -eq 0 -and @($tracked | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add('secrets.md is TRACKED by git.')
        }
        $staged = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff', '--cached', '--name-only', '--', 'secrets.md')
        if ($LASTEXITCODE -eq 0 -and @($staged | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add('secrets.md is STAGED for commit.')
        }
    }
    foreach ($file in $envFiles) {
        $relPath = $file.Name
        $tracked = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'ls-files', '--', $relPath)
        if ($LASTEXITCODE -eq 0 -and @($tracked | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add($relPath + ' (contains real secrets) is TRACKED by git.')
        }
        $staged = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff', '--cached', '--name-only', '--', $relPath)
        if ($LASTEXITCODE -eq 0 -and @($staged | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add($relPath + ' (contains real secrets) is STAGED for commit.')
        }
    }
    $excludeNames = @('secrets.md') + @($envFiles | ForEach-Object { $_.Name.Replace('\', '/') })
    # Grouped BY VALUE, not by key. Several keys legitimately hold the same
    # value (ADMIN_EMAIL / OWNER_EMAIL / KYC_ADMIN_EMAIL pointing at one
    # address, a URL reused under two names), and scanning per key reported the
    # same finding once per key: 3 keys x 14 files = 42 CRITICAL lines for a
    # SINGLE value. That volume is itself a defect - a wall of duplicated
    # criticals is what makes someone delete the hook instead of reading it.
    # One value is scanned once and reported once, naming every key that holds
    # it.
    #
    # Only high-confidence Secrets participate in exact-value leak matching.
    # PublicConfig (e.g. NEXT_PUBLIC_APP_URL, R2_BUCKET) is expected to appear
    # in tracked config/code/workflows and must never block a push for that
    # reason alone. Unknown stays advisory (see $needsClassification) rather
    # than being treated as a confirmed leak from a bare value match.
    $secretValueGroups = [ordered]@{}
    foreach ($key in @($discovered.Keys | Sort-Object)) {
        if ($discovered[$key].Classification -ne 'Secret') { continue }
        $groupValue = $discovered[$key].Value
        if ($groupValue.Length -lt $minSecretLength) { continue }
        if (-not $secretValueGroups.Contains($groupValue)) {
            $secretValueGroups[$groupValue] = New-Object System.Collections.Generic.List[string]
        }
        [void]$secretValueGroups[$groupValue].Add($key)
    }
    foreach ($value in @($secretValueGroups.Keys)) {
        $key = ($secretValueGroups[$value].ToArray() -join ', ')
        # Merge working-tree (git grep) and index/staged (git grep --cached) hits.
        # A value staged then cleaned from the working copy only - or committed
        # and later edited away locally without staging that edit - is invisible
        # to a working-tree-only scan but is still what would actually be pushed
        # or committed next; only the union of both scans is trustworthy.
        $matchPaths = New-Object System.Collections.Generic.List[string]
        $worktreeHits = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'grep', '-Il', '-F', '--', $value)
        if ($LASTEXITCODE -eq 0) {
            foreach ($m in @($worktreeHits | Where-Object { $_ })) { [void]$matchPaths.Add([string]$m) }
        }
        $indexHits = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'grep', '--cached', '-Il', '-F', '--', $value)
        if ($LASTEXITCODE -eq 0) {
            foreach ($m in @($indexHits | Where-Object { $_ })) { [void]$matchPaths.Add([string]$m) }
        }
        foreach ($matchFile in @($matchPaths.ToArray() | Sort-Object -Unique)) {
            if ($excludeNames -contains ([string]$matchFile).Replace('\', '/')) { continue }
            [void]$critical.Add('Value of ' + $key + ' appears in a git-tracked file: ' + $matchFile)
        }

        # Outgoing-commit scan: the actual push-safety boundary. A value can
        # be absent from BOTH the working tree and the index (already cleaned
        # up, staged clean, just not yet committed) while an EARLIER commit
        # still part of this push contains it - `git grep` across those exact
        # commit trees catches that, and also a value introduced and fully
        # removed again within the outgoing range (still pushed as reachable
        # history). Unlike the working-tree/index scan, the outgoing scan does
        # NOT exclude .env*/secrets.md: a committed real .env or registry file
        # sitting in outgoing history IS a leak, even if it was later
        # deleted/untracked before the push.
        if ($outgoingCommits.Count -gt 0) {
            $grepResult = Invoke-OutgoingGrepBatched -Cwd $cwd -Value $value -Commits $outgoingCommits
            if ($grepResult.HadError) { $outgoingScanFailedClosed = $true }
            $seenOutgoingPaths = New-Object System.Collections.Generic.HashSet[string]
            foreach ($hit in @($grepResult.Hits)) {
                $hitText = [string]$hit
                $sep = $hitText.IndexOf(':')
                if ($sep -lt 0) { continue }
                $hitSha = $hitText.Substring(0, $sep)
                $hitPath = $hitText.Substring($sep + 1)
                if (-not $seenOutgoingPaths.Add($hitPath)) { continue }    # dedupe by path across commits
                $hitSha7 = $hitSha
                if ($hitSha7.Length -gt 7) { $hitSha7 = $hitSha7.Substring(0, 7) }
                [void]$critical.Add('Value of ' + $key + ' appears in outgoing commit ' + $hitSha7 + ': ' + $hitPath)
            }
        }
    }
    # Fail closed: an outgoing range that could not be resolved, or a grep that
    # errored mid-scan, means "unknown", not "clean" - block the push.
    foreach ($resolveError in $outgoingResolveErrors) {
        [void]$critical.Add('Outgoing history could not be fully scanned: ' + $resolveError + '.')
    }
    if ($outgoingScanFailedClosed) {
        [void]$critical.Add('Outgoing history could not be fully scanned: git grep failed on at least one commit batch; refusing to authorize the push as clean.')
    }
}

# ---- periodic (heavy) unused-secret scan: long cooldown, git-only ----
$unusedStateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$unusedStatePath = Join-Path $unusedStateDir ('Secrets-Check-Unused-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$runUnusedScan = $true
if (-not $GitPrePush -and (Test-Path -LiteralPath $unusedStatePath -PathType Leaf)) {
    try {
        $lastUnused = [DateTime]::Parse(([System.IO.File]::ReadAllText($unusedStatePath)).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $lastUnused.ToUniversalTime()).TotalMinutes -lt $unusedScanCooldownMinutes) {
            $runUnusedScan = $false
        }
    }
    catch { }
}
$unused = New-Object System.Collections.Generic.List[string]
if (-not $GitPrePush -and $runUnusedScan -and $inGitRepo -and $secretsExists) {
    $documentedKeys = @([regex]::Matches($secretsContent, '(?m)^##\s+(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
    foreach ($key in @($documentedKeys | Sort-Object -Unique)) {
        $grepHits = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'grep', '-Il', '-F', '--', $key)
        $usedElsewhere = $false
        if ($LASTEXITCODE -eq 0) {
            foreach ($matchFile in @($grepHits | Where-Object { $_ })) {
                $leaf = Split-Path -Leaf $matchFile
                if ($leaf -eq 'secrets.md') { continue }
                if (@($envFiles | ForEach-Object { $_.Name }) -contains $leaf) { continue }
                $usedElsewhere = $true
                break
            }
        }
        if (-not $usedElsewhere) {
            [void]$unused.Add($key)
        }
    }
    if (-not $GitPrePush) {
        try {
            if (-not (Test-Path -LiteralPath $unusedStateDir -PathType Container)) {
                New-Item -ItemType Directory -Path $unusedStateDir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($unusedStatePath, [DateTime]::UtcNow.ToString('o'))
        }
        catch { }
    }
}

# ---- nothing at all to report -> silent ----
if ($critical.Count -eq 0 -and $added.Count -eq 0 -and $missingUndocumented.Count -eq 0 -and $placeholders.Count -eq 0 -and
    $unused.Count -eq 0 -and $needsClassification.Count -eq 0 -and $removedPublicConfigKeys.Count -eq 0) {
    exit 0
}

if ($GitPrePush -and $critical.Count -eq 0) {
    exit 0
}

# ---- non-critical fingerprint + cooldown (critical findings always bypass this) ----
$fingerprintSource = (@($added) -join ',') + '|' + (@($missingUndocumented) -join ',') + '|' + (@($placeholders) -join ',') + '|' + (@($unused) -join ',') +
    '|' + (@($needsClassification.ToArray()) -join ',') + '|' + (@($removedPublicConfigKeys) -join ',')
$fingerprint = Get-ShortHash $fingerprintSource
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('Secrets-Check-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if ($critical.Count -eq 0 -and -not $GitPrePush) {
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $lines = [System.IO.File]::ReadAllLines($statePath)
            if ($lines.Count -ge 2 -and $lines[0].Trim() -eq $fingerprint) {
                $lastTime = [DateTime]::Parse($lines[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if (([DateTime]::UtcNow - $lastTime.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
                    exit 0
                }
            }
        }
        catch { }
    }
}
if (-not $GitPrePush) {
    try {
        if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllLines($statePath, @($fingerprint, [DateTime]::UtcNow.ToString('o')))
    }
    catch { }
}

# ---- build the report (key names / file paths only - NEVER a secret value) ----
$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('SECRETS CHECK (' + $cwd + '):')
if ($critical.Count -gt 0) {
    [void]$lines.Add('CRITICAL:')
    foreach ($item in $critical) { [void]$lines.Add('- ' + $item) }
}
if ($added.Count -gt 0) {
    [void]$lines.Add('Auto-added ' + $added.Count + ' new secret(s) to secrets.md (fill in Purpose/Used by): ' + ($added.ToArray() -join ', '))
}
if ($missingUndocumented.Count -gt 0) {
    [void]$lines.Add('Found in .env but NOT in secrets.md (AUTO_APPEND is off): ' + ($missingUndocumented.ToArray() -join ', '))
}
if ($placeholders.Count -gt 0) {
    [void]$lines.Add('Value looks like an empty placeholder: ' + ($placeholders.ToArray() -join ', '))
}
if ($unused.Count -gt 0) {
    [void]$lines.Add('In secrets.md but not referenced elsewhere in the tracked project (verify before removing - never auto-removed): ' + ($unused.ToArray() -join ', '))
}
if ($needsClassification.Count -gt 0) {
    [void]$lines.Add('Classification unclear (neither confirmed Secret nor confirmed PublicConfig) - not registered, not treated as a confirmed leak, and never blocking on its own: ' + ($needsClassification.ToArray() -join ', ') + '. Classify explicitly via SECRET_KEYS or PUBLIC_CONFIG_KEYS in .env if this recurs.')
}
if ($removedPublicConfigKeys.Count -gt 0) {
    [void]$lines.Add('Removed ' + $removedPublicConfigKeys.Count + ' previously auto-added secrets.md entr' + $(if ($removedPublicConfigKeys.Count -eq 1) { 'y' } else { 'ies' }) + ' now classified as public config, not a secret: ' + ($removedPublicConfigKeys -join ', ') + '.')
}
[void]$lines.Add('Never print, log, or commit a secret value. Rotate anything that may have leaked. Removing a secrets.md entry is always your call, not automated.')
$message = $lines.ToArray() -join "`n"

if ($GitPrePush) {
    [Console]::Error.WriteLine($message)
    exit 1
}

# Only a real blocking/critical finding (confirmed leak, tracked/staged
# secrets.md or real .env*, an incomplete/fail-closed outgoing scan) may use
# decision:block. Advisory-only findings (Unknown classification, placeholder,
# unused registry entry, a stale-entry cleanup, a successful auto-add) never
# block completion on their own - Stop reports them as non-blocking context,
# client-aware exactly like every other advisory hook in this project.
$hasBlockingFindings = ($critical.Count -gt 0)
if ($isStopEvent -and $hasBlockingFindings) {
    @{ decision = 'block'; reason = $message } | ConvertTo-Json -Compress
    exit 0
}
if ($isStopEvent) {
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) {
        @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } | ConvertTo-Json -Depth 5 -Compress
    }
    else {
        @{ systemMessage = $message } | ConvertTo-Json -Compress
    }
    exit 0
}

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
