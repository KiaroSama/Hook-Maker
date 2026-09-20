# Secrets-Check: is this key/value a SECRET, ordinary PUBLIC CONFIGURATION, or
# UNKNOWN? This is the judgement the whole hook hangs on - what gets registered
# in secrets.md, what blocks a push, and what is only mentioned - so it is kept
# apart from the scanning, registry-writing and push-gate code that acts on it.
#
# Split out of Secrets-Check.ps1 at the 800-line ceiling; dot-sourced by it in
# the same position the block occupied, so the override lists below are still
# built from $config before the first classification call.
#
# It never handles a secret VALUE beyond deciding its shape: nothing here logs,
# echoes, persists or returns a value, and callers report key names and file
# paths only.
# ---------------------------------------------------------------------------

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
# Hook Maker's OWN documented configuration keys, treated as public config by
# default so that every installation does not have to rediscover that its own
# numeric ceilings are not credentials. A project that configures a hook has a
# .env full of these, and each one was previously reported as Unknown - an
# advisory asking the operator to classify keys this tool itself documents.
#
# WHY THIS IS SAFE, and it is the precedence in Get-KeyValueClassification that
# makes it so, not this list: the PUBLIC_CONFIG_KEYS tier is consulted only
# AFTER a definite credential VALUE format and after credential-like KEY
# evidence. A real token pasted into MAX_SCAN_ENTRIES is still classified
# Secret by its value. A project's own SECRET_KEYS is checked first of all, so
# any of these can still be forced back to Secret locally.
#
# ONLY keys whose documented default is a NUMBER or a BOOLEAN are listed - a
# value shape that categorically cannot carry a credential. Free-form keys of
# ours (DEPLOY_COMMAND, SYNC_PROJECTS, EXTRA_* patterns, the *_DIR paths, and
# SECRET_KEYS/PUBLIC_CONFIG_KEYS themselves) are deliberately ABSENT: their
# values are arbitrary text, so Unknown-and-advisory remains the honest answer.
# Generated from the shipped hooks/*/.env.example defaults; a key that appears
# anywhere with a free-form default is excluded even if another hook gives it a
# numeric one.
$script:BuiltInPublicConfigKeys = @(
    'AUTO_APPEND', 'COOLDOWN_MINUTES', 'ENABLE_SUBAGENT_STOP',
    'EXTERNAL_BLOCKER_RECHECK_MINUTES', 'EXTERNAL_BLOCKER_TTL_MINUTES',
    'FAILURE_COOLDOWN_MINUTES', 'LINE_THRESHOLD', 'MAX_CHANGED_FILES', 'MAX_CHARS',
    'MAX_DIRECTORIES', 'MAX_DOC_FILES', 'MAX_FILES', 'MAX_FINDINGS', 'MAX_SCAN_DEPTH',
    'MAX_SCAN_ENTRIES', 'MAX_SCAN_SECONDS', 'MIN_SECRET_LENGTH', 'PENDING_COOLDOWN_MINUTES',
    'PR_LIMIT', 'REQUIRE_ACKNOWLEDGEMENT', 'TEST_COMPLETION_ADVISORY_ONLY',
    'TEST_COMPLETION_ALWAYS_REQUIRE_NOTE', 'TEST_COMPLETION_COORDINATION_WAIT_SECONDS',
    'TEST_COMPLETION_EVIDENCE_MINUTES', 'TEST_GUARD_ADVISORY_ONLY',
    'TEST_GUARD_HEARTBEAT_SECONDS', 'TEST_GUARD_IDLE_TIMEOUT_SECONDS',
    'TEST_GUARD_MAX_BLIND_SLEEP_SECONDS', 'TEST_GUARD_MAX_MEMORY_MB',
    'TEST_GUARD_WALL_TIMEOUT_SECONDS', 'TEST_PLAN_ALWAYS_REPORT', 'TEST_PLAN_COOLDOWN_MINUTES',
    'TEST_PLAN_MAX_DIRS', 'TEST_PLAN_MAX_FILES', 'TEST_PLAN_MAX_FILE_KB',
    'TEST_PLAN_MAX_FINDINGS', 'TEST_PLAN_MAX_SCAN_SECONDS', 'UNUSED_SCAN_COOLDOWN_MINUTES',
    'UTF8_ADVISORY_ONLY', 'UTF8_MAX_DIRECTORIES', 'UTF8_MAX_FILES', 'UTF8_MAX_FILE_KB',
    'UTF8_MAX_FINDINGS', 'UTF8_MAX_SCAN_SECONDS'
)

$publicConfigKeysRaw = ''
if ($config.ContainsKey('PUBLIC_CONFIG_KEYS')) { $publicConfigKeysRaw = $config['PUBLIC_CONFIG_KEYS'] }
$secretKeyOverrides = @(Get-KeyOverrideList $secretKeysRaw)
# The project's own list first, then ours. @(...) around BOTH halves: this
# file already documents that a bare list return collapses to a scalar under
# StrictMode when it holds 0 or 1 items.
$publicConfigKeyOverrides = @(@(Get-KeyOverrideList $publicConfigKeysRaw) + @($script:BuiltInPublicConfigKeys))

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

