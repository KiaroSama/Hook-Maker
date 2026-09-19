# Is a script path one of THIS TOOL'S OWN hook scripts?
#
# Why this exists. Recognition matches a leaf of `Test-<safe>.ps1`, which is
# right for this repository's suites (Test-Wizard.ps1, Test-SecretsCheck.ps1)
# and wrong for its hooks. `Test-` is an approved PowerShell VERB meaning
# "evaluate a condition" - Test-Path, Test-Connection - so Test-Plan-Check.ps1,
# Test-Run-Guard.ps1 and Test-Completion-Check.ps1 all match a pattern that was
# never about them. See CONTEXT.md: "test command" vs "condition script".
#
# The damage was not cosmetic. Test-Completion-Check prints a recovery command
# naming the incident to resolve; the guard refused that command for having no
# bounded runner, and running it wrapped exited 1 (the hook rejects those
# arguments under a runner), which filed a NEW failed record. Following the
# printed instruction therefore manufactured a fresh permanent block.
#
# The test, and why it is this one. A hook lives in a directory named after
# itself - `hooks\Test-Plan-Check\Test-Plan-Check.ps1` in source, and
# `.claude\hooks\Hook-Maker\Test-Plan-Check\Test-Plan-Check.ps1` once installed.
# A suite never is: `scripts\Test-Wizard.ps1` sits in `scripts`. So the parent
# directory name equalling the file's base name identifies a hook in BOTH
# layouts with one comparison and no path list to keep in sync.
#
# The `hooks` segment is required as well, deliberately. Parent-equals-basename
# alone would also exclude a user's own `tests\Test-Foo\Test-Foo.ps1`, and
# failing to guard a real suite is a safety loss. Both conditions together
# cannot reach outside a hooks tree.

function Test-IsOwnHookScript {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    # Normalise separators without touching the filesystem: the path may name a
    # script that does not exist here (a command captured on another machine),
    # and Resolve-Path would throw on it.
    $normalised = $Path.Replace('/', [string][char]92)
    $segments = @($normalised.Split([char]92) | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 3) { return $false }

    $leaf = $segments[$segments.Count - 1]
    if ($leaf -notmatch '\.ps1$') { return $false }
    $baseName = $leaf.Substring(0, $leaf.Length - 4)
    $parent = $segments[$segments.Count - 2]
    if ($parent -ne $baseName) { return $false }

    # A `hooks` directory anywhere above it - covers the source layout and both
    # client runtimes without naming either.
    for ($i = 0; $i -lt $segments.Count - 2; $i++) {
        if ($segments[$i].ToLowerInvariant() -eq 'hooks') { return $true }
    }
    return $false
}
