# Test-LargeFileCheck.ps1 scenario block: A PROJECT-OWNED CI RUNNER IS NOT THE
# PROJECT'S SOURCE.
#
# THE REPORTED DEFECT. A project that keeps its self-hosted runner inside its
# own root - which global-environment-rules.md requires - has a SECOND CHECKOUT
# of itself under the runner's work directory, plus the vendored third-party
# actions the runner downloaded. This hook walked straight into both, so every
# oversized file was reported twice and the count was inflated about 2.4x. The
# reporting project saw 12 where a scan of its own tracked files finds 5.
#
# Two hooks already excluded `.ci-runner` and three did not, and none of the
# five excluded `.ci-runner-win`, `.ci-work` or `.ci-cache`. That drift is what
# the shared base in hooks\_scope.ps1 exists to stop, so the assertions here are
# about the OBSERVED COUNT, not about the contents of a list - a list assertion
# would have passed on the day the drift appeared.
#
# The scan runs on Stop, not SessionStart: SessionStart carries the preventive
# policy and has no file list to be wrong about.
#
# Dot-sourced by Test-LargeFileCheck.ps1 into its scope (uses its harness,
# helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- a project-owned CI runner is not the project''s own source ---' -ForegroundColor Cyan
    $hcCi = New-IsolatedHookCopy
    $projCi = New-Proj 'CiRunnerScope'

    # The project's own oversized file - the one finding that is real.
    New-SourceFile (Join-Path $projCi 'src\storage.py') 900

    # The same file again, inside the runner's own checkout of this project, and
    # once more under each of the other three project-owned CI directory names.
    # Before the shared base this hook excluded none of the four.
    foreach ($relative in @(
            '.ci-runner\windows\_work\Proj\Proj\src\storage.py',
            '.ci-runner-win\_work\Proj\Proj\src\storage.py',
            '.ci-work\windows\Proj\src\storage.py',
            '.ci-cache\npm\Proj\src\storage.py')) {
        New-SourceFile (Join-Path $projCi $relative) 900
    }

    $rCi = Fire -HookPath $hcCi.Script -Cwd $projCi -EventName 'Stop' -LocalAppData $hcCi.LocalAppData
    $msgCi = Get-Advisory $rCi.Out
    Check 'the project''s own oversized file is still reported' ($msgCi -match 'storage\.py') $msgCi
    # THE ASSERTION THAT WOULD HAVE CAUGHT THE DEFECT: one file, counted once,
    # with four identical copies sitting under the runner directories.
    Check 'an oversized file duplicated under every CI directory is counted ONCE, not five times' (
        $msgCi -match '\b1 source file\(s\) exceed' -and $msgCi -notmatch '\b5 source file\(s\) exceed') $msgCi
    foreach ($ci in @('.ci-runner', '.ci-runner-win', '.ci-work', '.ci-cache')) {
        Check ('no finding names anything under ' + $ci) ($msgCi -notmatch [regex]::Escape($ci)) $msgCi
    }

    # The regenerated code index joined the shared base for the same reason: it
    # is rewritten wholesale on every index and is never the project's source.
    $projIdx = New-Proj 'CiRunnerScopeIndex'
    New-SourceFile (Join-Path $projIdx '.codebase-memory\cache\big.py') 900
    $rIdx = Fire -HookPath $hcCi.Script -Cwd $projIdx -EventName 'Stop' -LocalAppData $hcCi.LocalAppData
    Check 'a project whose ONLY oversized file is inside the regenerated index reports nothing' (
        (Get-Advisory $rIdx.Out) -notmatch 'big\.py') $rIdx.Out
