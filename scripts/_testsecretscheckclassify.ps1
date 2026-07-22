# Test-SecretsCheck.ps1 scenario block: key/value CLASSIFICATION - PublicConfig
# keys never register or block, credential evidence beats public prefixes,
# value-shape forcing, Unknown-is-advisory, explicit SECRET_KEYS /
# PUBLIC_CONFIG_KEYS overrides, stale-registry cleanup, the overridable entropy
# heuristic, value-grouped leak reporting, and AUTH/OAUTH boundary matching.
#
# Dot-sourced by Test-SecretsCheck.ps1 into the caller's scope (uses its
# harness, helpers, and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- classification: PublicConfig keys never register or block ---' -ForegroundColor Cyan
    $projPub = New-GitProj 'PublicConfigKeys'
    Write-Utf8 (Join-Path $projPub '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projPub '.env') "NEXT_PUBLIC_APP_URL=https://example.com`r`nR2_BUCKET=public-assets`r`n"
    Write-Utf8 (Join-Path $projPub 'wrangler.toml') "name = ""demo""`r`nR2_BUCKET = ""public-assets""`r`n"
    Add-Commit $projPub 'tracked config referencing the same public values'
    $r = Fire -Cwd $projPub
    Check 'NEXT_PUBLIC_APP_URL is not auto-added to secrets.md' ($r.Out -notlike '*NEXT_PUBLIC_APP_URL*') $r.Out
    Check 'R2_BUCKET is not auto-added to secrets.md' ($r.Out -notlike '*R2_BUCKET*') $r.Out
    Check 'no secrets.md was created for public-only config' (-not (Test-Path (Join-Path $projPub 'secrets.md')))
    Check 'tracked reuse of the same public value is not reported as a leak' ($r.Out -notlike '*appears in a git-tracked file*') $r.Out
    Check 'nothing blocks (exit 0) for public config alone' ($r.Exit -eq 0)

    # Same shape through the real native pre-push path.
    $projPubPush = New-PushableRepo 'PublicConfigPush'
    Write-Utf8 (Join-Path $projPubPush '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projPubPush '.env') "NEXT_PUBLIC_APP_URL=https://example.com`r`nR2_BUCKET=public-assets`r`n"
    Write-Utf8 (Join-Path $projPubPush 'wrangler.toml') "R2_BUCKET = ""public-assets""`r`n"
    Add-Commit $projPubPush 'seed'
    Push-Repo $projPubPush
    $rPush = FireGitPrePush -Cwd $projPubPush -StdinText (Get-RefUpdateLine -Repo $projPubPush)
    Check 'a normal push with only public config is NOT blocked' ($rPush.Exit -eq 0) $rPush.Err

    # =====================================================================
    Write-Host '--- classification: a public-prefixed key with credential evidence still blocks ---' -ForegroundColor Cyan
    $projPubToken = New-GitProj 'PublicPrefixCredential'
    Write-Utf8 (Join-Path $projPubToken '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projPubToken '.env') "PUBLIC_API_TOKEN=zzcredentiallikevalue123456`r`n"
    Write-Utf8 (Join-Path $projPubToken 'notes.txt') "token: zzcredentiallikevalue123456`r`n"
    Add-Commit $projPubToken 'seed'
    $r = Fire -Cwd $projPubToken
    Check 'PUBLIC_API_TOKEN (key semantics: TOKEN) still classifies as Secret and is auto-added' ($r.Out -like '*Auto-added*PUBLIC_API_TOKEN*') $r.Out
    Check 'PUBLIC_API_TOKEN leaking into a tracked file still blocks' ($r.Out -like '*PUBLIC_API_TOKEN*appears in a git-tracked file*notes.txt*') $r.Out

    $projPubKey = New-GitProj 'NextPublicApiKey'
    Write-Utf8 (Join-Path $projPubKey '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projPubKey '.env') "NEXT_PUBLIC_API_KEY=sk_live_abcdefghij1234567890`r`n"
    Write-Utf8 (Join-Path $projPubKey 'notes.txt') "sk_live_abcdefghij1234567890`r`n"
    Add-Commit $projPubKey 'seed'
    $r = Fire -Cwd $projPubKey
    Check 'NEXT_PUBLIC_API_KEY with a live-looking key value still classifies as Secret' ($r.Out -like '*Auto-added*NEXT_PUBLIC_API_KEY*') $r.Out
    Check 'NEXT_PUBLIC_API_KEY leak still blocks despite the public prefix' ($r.Out -like '*NEXT_PUBLIC_API_KEY*appears in a git-tracked file*notes.txt*') $r.Out

    # =====================================================================
    Write-Host '--- classification: value shape can force Secret or PublicConfig regardless of key wording ---' -ForegroundColor Cyan
    $projConn = New-GitProj 'ConnectionStringSecret'
    Write-Utf8 (Join-Path $projConn '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projConn '.env') "DATABASE_URL=postgres://dbuser:dbpass1234@db.example.com:5432/app`r`n"
    Write-Utf8 (Join-Path $projConn 'notes.txt') "postgres://dbuser:dbpass1234@db.example.com:5432/app`r`n"
    Add-Commit $projConn 'seed'
    $r = Fire -Cwd $projConn
    Check 'a *_URL key with an embedded username:password still classifies as Secret' ($r.Out -like '*Auto-added*DATABASE_URL*') $r.Out
    Check 'the embedded-credential connection string still blocks as a leak' ($r.Out -like '*DATABASE_URL*appears in a git-tracked file*notes.txt*') $r.Out

    $projPlainUrl = New-GitProj 'PlainPublicUrl'
    Write-Utf8 (Join-Path $projPlainUrl '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projPlainUrl '.env') "API_ORIGIN_URL=https://api.example.com`r`n"
    Write-Utf8 (Join-Path $projPlainUrl 'notes.txt') "https://api.example.com`r`n"
    Add-Commit $projPlainUrl 'seed'
    $r = Fire -Cwd $projPlainUrl
    Check 'a public URL with no embedded credentials is not registered or blocked' ($r.Out -notlike '*API_ORIGIN_URL*' -and $r.Exit -eq 0) $r.Out

    # =====================================================================
    Write-Host '--- classification: Unknown is advisory only, never a confirmed leak from a bare match ---' -ForegroundColor Cyan
    $projUnknown = New-GitProj 'UnknownConfig'
    Write-Utf8 (Join-Path $projUnknown '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projUnknown '.env') "WIDGET_ID=abc123`r`n"
    Write-Utf8 (Join-Path $projUnknown 'notes.txt') "abc123`r`n"
    Add-Commit $projUnknown 'seed'
    $r = Fire -Cwd $projUnknown
    Check 'an ambiguous key is reported as needing classification, not auto-added' ($r.Out -like '*Classification unclear*WIDGET_ID*' -and $r.Out -notlike '*Auto-added*WIDGET_ID*') $r.Out
    Check 'the ambiguous key is never treated as a confirmed leak from a bare value match' ($r.Out -notlike '*WIDGET_ID*appears in a git-tracked file*') $r.Out
    Check 'the ambiguous-key advisory does not block the task' ($r.Exit -eq 0)

    # =====================================================================
    Write-Host '--- classification: explicit local overrides ---' -ForegroundColor Cyan
    $projOverrideSecret = New-GitProj 'OverrideForcesSecret'
    Write-Utf8 (Join-Path $projOverrideSecret '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projOverrideSecret '.env') "INTERNAL_CODE=abc123`r`n"
    $overrideSecretHook = New-ConfiguredHookCopy @{ SECRET_KEYS = 'INTERNAL_CODE' }
    $r = Fire -Cwd $projOverrideSecret -HookPath $overrideSecretHook
    Check 'SECRET_KEYS override forces an otherwise-ambiguous key to classify as Secret' ($r.Out -like '*Auto-added*INTERNAL_CODE*') $r.Out

    $projOverridePublic = New-GitProj 'OverrideForcesPublic'
    Write-Utf8 (Join-Path $projOverridePublic '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projOverridePublic '.env') "WIDGET_ID=abc123`r`n"
    $overridePublicHook = New-ConfiguredHookCopy @{ PUBLIC_CONFIG_KEYS = 'WIDGET_ID' }
    $r = Fire -Cwd $projOverridePublic -HookPath $overridePublicHook
    Check 'PUBLIC_CONFIG_KEYS override allows an otherwise-unknown key with no advisory at all' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $projOverrideConflict = New-GitProj 'OverrideConflict'
    Write-Utf8 (Join-Path $projOverrideConflict '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projOverrideConflict '.env') "WIDGET_ID=abc123`r`n"
    $overrideConflictHook = New-ConfiguredHookCopy @{ SECRET_KEYS = 'WIDGET_ID'; PUBLIC_CONFIG_KEYS = 'WIDGET_ID' }
    $r = Fire -Cwd $projOverrideConflict -HookPath $overrideConflictHook
    Check 'SECRET_KEYS wins over PUBLIC_CONFIG_KEYS on the same key' ($r.Out -like '*Auto-added*WIDGET_ID*') $r.Out

    # =====================================================================
    Write-Host '--- classification: conservative registry cleanup for stale auto-added public config ---' -ForegroundColor Cyan
    $projCleanup = New-GitProj 'RegistryCleanup'
    Write-Utf8 (Join-Path $projCleanup '.gitignore') "secrets.md`n"
    $staleContent = "# Secrets`n`nLocal-only registry.`n`n## NEXT_PUBLIC_APP_URL`n- Purpose: TODO`n- Used by: (auto-detected from .env; update if used elsewhere)`n- Source: x`n- Created: 2026-01-01 (auto-added by Secrets-Check)`n- Value: https://example.com`n`n## MANUAL_SECRET`n- Purpose: a real, user-authored secret`n- Value: keepme123`n"
    Write-Utf8 (Join-Path $projCleanup 'secrets.md') $staleContent
    Write-Utf8 (Join-Path $projCleanup '.env') "NEXT_PUBLIC_APP_URL=https://example.com`r`n"
    $r = Fire -Cwd $projCleanup
    $cleanedContent = [System.IO.File]::ReadAllText((Join-Path $projCleanup 'secrets.md'))
    Check 'a stale auto-added PublicConfig entry is removed from secrets.md' ($cleanedContent -notmatch 'NEXT_PUBLIC_APP_URL') $cleanedContent
    Check 'a user-authored entry is never touched by the cleanup' ($cleanedContent -match 'MANUAL_SECRET' -and $cleanedContent -match 'keepme123') $cleanedContent
    Check 'the cleanup is reported' ($r.Out -like '*Removed*NEXT_PUBLIC_APP_URL*') $r.Out

    # =====================================================================
    Write-Host '--- classification: an opaque value under a public-looking prefix stays Unknown ---' -ForegroundColor Cyan
    $projOpaquePublic = New-GitProj 'OpaquePublicPrefix'
    Write-Utf8 (Join-Path $projOpaquePublic '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projOpaquePublic '.env') "NEXT_PUBLIC_SESSION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`r`n"
    Add-Commit $projOpaquePublic 'seed'
    $r = Fire -Cwd $projOpaquePublic
    Check 'NEXT_PUBLIC_SESSION with an opaque repeated-letter value is NOT auto-classified PublicConfig' ($r.Out -notlike '*Auto-added*NEXT_PUBLIC_SESSION*') $r.Out
    Check 'the opaque public-prefixed value is instead reported as needing classification (Unknown)' ($r.Out -like '*Classification unclear*NEXT_PUBLIC_SESSION*') $r.Out

    # =====================================================================
    Write-Host '--- classification: PUBLIC_CONFIG_KEYS can never declassify a real credential ---' -ForegroundColor Cyan
    $projNoDeclassifyValue = New-GitProj 'NoDeclassifyCredentialValue'
    Write-Utf8 (Join-Path $projNoDeclassifyValue '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projNoDeclassifyValue '.env') "API_TOKEN=ghp_abcdefghijklmnopqrst1234`r`n"
    $noDeclassifyValueHook = New-ConfiguredHookCopy @{ PUBLIC_CONFIG_KEYS = 'API_TOKEN' }
    $r = Fire -Cwd $projNoDeclassifyValue -HookPath $noDeclassifyValueHook
    Check 'PUBLIC_CONFIG_KEYS cannot declassify a credential-shaped VALUE (a real GitHub token)' ($r.Out -like '*Auto-added*API_TOKEN*') $r.Out

    $projNoDeclassifyKey = New-GitProj 'NoDeclassifyCredentialKey'
    Write-Utf8 (Join-Path $projNoDeclassifyKey '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projNoDeclassifyKey '.env') "SERVICE_PASSWORD=abc123`r`n"
    $noDeclassifyKeyHook = New-ConfiguredHookCopy @{ PUBLIC_CONFIG_KEYS = 'SERVICE_PASSWORD' }
    $r = Fire -Cwd $projNoDeclassifyKey -HookPath $noDeclassifyKeyHook
    Check 'PUBLIC_CONFIG_KEYS cannot declassify credential-like KEY semantics (PASSWORD)' ($r.Out -like '*Auto-added*SERVICE_PASSWORD*') $r.Out

    # =====================================================================
    # Regression: a real push in a Next.js/Vercel project was blocked by 42
    # CRITICAL lines, all from ONE e-mail address held under three keys. The
    # address was force-classified Secret by the entropy heuristic ("24+ chars,
    # mixed case, has a digit"), which sat ABOVE the PUBLIC_CONFIG_KEYS
    # override - so the block was unclearable by any configuration and the hook
    # was deleted from that project instead. The heuristic is a guess, not an
    # identification, and it now sits below the override.
    Write-Host '--- classification: the entropy HEURISTIC is overridable; identified credentials are not ---' -ForegroundColor Cyan

    # An address is never a credential, whatever its length/charset.
    $projEmail = New-GitProj 'AdminEmailNotSecret'
    Write-Utf8 (Join-Path $projEmail '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projEmail '.env') "ADMIN_EMAIL=Admin.Owner2024@Example.com`r`n"
    Write-Utf8 (Join-Path $projEmail 'authz.ts') "const OWNER = 'Admin.Owner2024@Example.com';`r`n"
    Add-Commit $projEmail 'seed'
    $r = Fire -Cwd $projEmail
    Check 'an admin e-mail is NOT auto-added to secrets.md as a secret' ($r.Out -notlike '*Auto-added*ADMIN_EMAIL*') $r.Out
    Check 'an admin e-mail in a tracked file is NOT reported as a leak' ($r.Out -notlike '*appears in a git-tracked file*') $r.Out
    Check 'the e-mail is reported as needing classification instead (Unknown, advisory)' ($r.Out -like '*Classification unclear*ADMIN_EMAIL*') $r.Out

    # ... and an address under a credential-named key is still Secret: the
    # e-mail exclusion only removes the heuristic, never key evidence.
    $projEmailPwd = New-Proj 'EmailUnderCredentialKey'
    Write-Utf8 (Join-Path $projEmailPwd '.env') "SMTP_PASSWORD=Admin.Owner2024@Example.com`r`n"
    $r = Fire -Cwd $projEmailPwd
    Check 'an address under a *_PASSWORD key is still Secret (key evidence is unoverridable)' ($r.Out -like '*Auto-added*SMTP_PASSWORD*') $r.Out

    # A public-by-design high-entropy value (Turnstile SITE key shape): Secret
    # by default, but now correctable per key.
    $turnstileEnv = "NEXT_PUBLIC_TURNSTILE_SITE_KEY=0xAAB4cDeF9gHiJk2LmNoPqRsT`r`n"
    $projSiteKeyDefault = New-Proj 'SiteKeyDefaultSecret'
    Write-Utf8 (Join-Path $projSiteKeyDefault '.env') $turnstileEnv
    $r = Fire -Cwd $projSiteKeyDefault
    Check 'DEFAULT is unchanged: a heuristic-only value with no override is still Secret' ($r.Out -like '*Auto-added*NEXT_PUBLIC_TURNSTILE_SITE_KEY*') $r.Out

    $projSiteKeyOverride = New-GitProj 'SiteKeyDeclassified'
    Write-Utf8 (Join-Path $projSiteKeyOverride '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projSiteKeyOverride '.env') $turnstileEnv
    Write-Utf8 (Join-Path $projSiteKeyOverride 'widget.tsx') "const siteKey = '0xAAB4cDeF9gHiJk2LmNoPqRsT';`r`n"
    Add-Commit $projSiteKeyOverride 'seed'
    $siteKeyHook = New-ConfiguredHookCopy @{ PUBLIC_CONFIG_KEYS = 'NEXT_PUBLIC_TURNSTILE_SITE_KEY' }
    $r = Fire -Cwd $projSiteKeyOverride -HookPath $siteKeyHook
    Check 'PUBLIC_CONFIG_KEYS CAN declassify a heuristic-only value (the escape hatch is reachable)' ($r.Out -notlike '*Auto-added*NEXT_PUBLIC_TURNSTILE_SITE_KEY*') $r.Out
    Check 'the declassified site key in tracked client code no longer blocks' ($r.Out -notlike '*appears in a git-tracked file*') $r.Out

    # =====================================================================
    # One value under several keys is scanned once and reported once. Before
    # this, 3 keys x 14 files produced 42 duplicate CRITICAL lines for a single
    # value - the volume that made the hook look broken rather than useful.
    Write-Host '--- leak scan is grouped BY VALUE, not per key ---' -ForegroundColor Cyan
    $projShared = New-GitProj 'SharedSecretValue'
    Write-Utf8 (Join-Path $projShared '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projShared '.env') (
        "PRIMARY_API_TOKEN=zzsharedcredential1234567`r`n" +
        "BACKUP_API_TOKEN=zzsharedcredential1234567`r`n" +
        "LEGACY_API_TOKEN=zzsharedcredential1234567`r`n")
    Write-Utf8 (Join-Path $projShared 'notes.txt') "zzsharedcredential1234567`r`n"
    Add-Commit $projShared 'seed'
    $r = Fire -Cwd $projShared
    $leakLines = @(($r.Out -split '\r?\n') | Where-Object { $_ -like '*appears in a git-tracked file*' })
    Check 'one shared value produces exactly ONE leak line, not one per key' ($leakLines.Count -eq 1) ($leakLines -join ' | ')
    Check 'that single line names every key holding the value' (
        $leakLines.Count -eq 1 -and $leakLines[0] -like '*BACKUP_API_TOKEN*' -and
        $leakLines[0] -like '*LEGACY_API_TOKEN*' -and $leakLines[0] -like '*PRIMARY_API_TOKEN*') ($leakLines -join ' | ')
    Check 'the shared secret VALUE is still never printed' ($r.Out -notlike '*zzsharedcredential1234567*') $r.Out

    # =====================================================================
    Write-Host '--- classification: AUTH/OAUTH token-boundary matching (not a raw substring) ---' -ForegroundColor Cyan
    $projAuthSecret = New-Proj 'AuthBoundarySecret'
    Write-Utf8 (Join-Path $projAuthSecret '.env') (
        "AUTH_TOKEN=abcdefghij1234567890`r`n" +
        "AUTH_SECRET=abcdefghij1234567890`r`n" +
        "AUTH_PASSWORD=abcdefghij1234567890`r`n" +
        "AUTH_CREDENTIAL=abcdefghij1234567890`r`n" +
        "AUTH_KEY=abcdefghij1234567890`r`n" +
        "BASIC_AUTH_PASSWORD=abcdefghij1234567890`r`n" +
        "OAUTH_CLIENT_SECRET=abcdefghij1234567890`r`n"
    )
    $r = Fire -Cwd $projAuthSecret
    foreach ($k in @('AUTH_TOKEN', 'AUTH_SECRET', 'AUTH_PASSWORD', 'AUTH_CREDENTIAL', 'AUTH_KEY', 'BASIC_AUTH_PASSWORD', 'OAUTH_CLIENT_SECRET')) {
        Check ($k + ' classifies as Secret and is auto-added') ($r.Out -like ('*Auto-added*' + $k + '*')) $r.Out
    }

    $projAuthNotSecret = New-Proj 'AuthBoundaryNotSecret'
    Write-Utf8 (Join-Path $projAuthNotSecret '.env') (
        "AUTHOR_NAME=Jane-Doe`r`n" +
        "AUTH0_DOMAIN=example.auth0.com`r`n" +
        "NEXT_PUBLIC_AUTH_URL=https://example.com/auth`r`n" +
        "AUTH_CALLBACK_URL=https://example.com/callback`r`n"
    )
    $r = Fire -Cwd $projAuthNotSecret
    foreach ($k in @('AUTHOR_NAME', 'AUTH0_DOMAIN', 'NEXT_PUBLIC_AUTH_URL', 'AUTH_CALLBACK_URL')) {
        Check ($k + ' never classifies as Secret merely for containing the letters AUTH') ($r.Out -notlike ('*Auto-added*' + $k + '*')) $r.Out
    }
