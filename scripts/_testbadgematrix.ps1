# Badge format (steering V92-V93) and release build matrix (V85-V88) cases for
# Test-GithubBaselineCheck.ps1 (spec 041). Dot-sourced; uses the suite's Fire,
# New-GitRepo, Check and $BaselineHook.

function Invoke-BadgeFormatRegression {
    $utf8 = [Text.UTF8Encoding]::new($false)
    function Write-Readme { param([string]$Repo, [string[]]$Badges) [IO.File]::WriteAllText((Join-Path $Repo 'README.md'), "<div align=`"center`">`n`n" + ($Badges -join "`n") + "`n`n</div>`n`n# Title`n`n## Donate`n`nFixture.`n", $utf8) }
    $good = @(
        '[![CI](https://img.shields.io/badge/CI-manual-1f6feb)](.github/workflows/ci.yml)',
        '[![Rust 1.99](https://img.shields.io/badge/rust-1.99-8b5cf6)](Cargo.toml)',
        '[![Runs on Windows and Linux](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-0891b2)](#install)',
        '[![Repo size 120 kB](https://img.shields.io/badge/repo%20size-120%20kB-ca8a04)](#)',
        '[![Support donations](https://img.shields.io/badge/Support-donations-d04a9a)](#donate)'
    )
    $repo = New-GitRepo 'badgefmt-good' -GithubRemote:$false
    Write-Readme $repo $good
    $r = Fire -HookPath $BaselineHook -Cwd $repo
    Check 'badge format: mandatory four by reserved colour, donations last, flat-square -> no format note' ($r.Out -notmatch 'Badge format:') $r.Out
    Check 'V102 badge guidance notes live/tag-linked section-synced badges and Author -> License -> Donate order' (
        $r.Out -match 'live/tag-linked section-synced' -and $r.Out -match '## Author -> brief ## License -> ## Donate last') $r.Out

    $liveGood = @(
        '[![CI](https://img.shields.io/github/actions/workflow/status/o/r/ci.yml?style=flat-square&color=1f6feb)](.github/workflows/ci.yml)',
        '[![Tag](https://img.shields.io/github/v/tag/o/r?style=flat-square&color=0f766e)](https://github.com/o/r/tags)',
        '[![Rust 1.99](https://img.shields.io/badge/rust-1.99-8b5cf6)](Cargo.toml)',
        '[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-0891b2)](#install)',
        '[![Repo size](https://img.shields.io/github/repo-size/o/r?style=flat-square&color=ca8a04)](#)',
        '[![Support donations](https://img.shields.io/badge/Support-donations-d04a9a)](#donate)'
    )
    $repoLive = New-GitRepo 'badgefmt-live' -GithubRemote:$false
    Write-Readme $repoLive $liveGood
    $rLive = Fire -HookPath $BaselineHook -Cwd $repoLive
    Check 'V102 live GitHub flat-square dynamic badges with hex color pass without false format warnings' ($rLive.Out -notmatch 'Badge format:') $rLive.Out

    $bad = @(
        '[![Support donations](https://img.shields.io/badge/Support-donations-d04a9a)](#donate)',
        '[![CI](https://img.shields.io/badge/CI-manual-blue?style=for-the-badge)](https://img.shields.io/badge/CI-manual-blue)',
        '[![a](https://img.shields.io/badge/a-1-123456)](#a)',
        '[![b](https://img.shields.io/badge/b-2-123456)](#b)'
    )
    $repo = New-GitRepo 'badgefmt-bad' -GithubRemote:$false
    Write-Readme $repo $bad
    $r = Fire -HookPath $BaselineHook -Cwd $repo
    Check 'badge format: missing mandatory badges are named with their reserved colours' ($r.Out -match 'mandatory missing: language-version #8b5cf6, platform #0891b2, repo-size #ca8a04') $r.Out
    Check 'badge format: donations not last is named' ($r.Out -match 'donations badge not last') $r.Out
    Check 'badge format: a styled/keyword-colour URL is not plain flat-square' ($r.Out -match '1 not plain flat-square') $r.Out
    Check 'badge format: a shared colour is named' ($r.Out -match 'shared colour\(s\) 123456') $r.Out
    Check 'badge format: a badge linking to its own image is named' ($r.Out -match '1 linking to the image') $r.Out
    Check 'badge format: advisory only' ($r.Out -notmatch '"decision"') $r.Out
}

function Invoke-ReleaseMatrixRegression {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $repo = New-GitRepo 'matrix-bad' -GithubRemote:$false
    $dir = Join-Path $repo '.github/workflows'; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'release.yml'), "name: Release`non: workflow_dispatch`njobs:`n  build:`n    strategy:`n      matrix:`n        include:`n          - { os: windows-latest, target: x86_64-pc-windows-msvc }`n          - { os: windows-latest, target: i686-pc-windows-msvc }`n          - { os: ubuntu-latest, target: x86_64-unknown-linux-gnu }`n          - { os: macos-14, target: aarch64-apple-darwin }`n    runs-on: `${{ matrix.os }}`n    steps:`n      - run: cargo build --release --target `${{ matrix.target }}`n", $utf8)
    $r = Fire -HookPath $BaselineHook -Cwd $repo
    Check 'release matrix: 32-bit, macOS and missing arm64 targets are named' ($r.Out -match 'RELEASE MATRIX' -and $r.Out -match 'release\.yml: 32-bit i686' -and $r.Out -match 'macOS macos-14' -and $r.Out -match 'no Windows arm64' -and $r.Out -match 'no Linux arm64') $r.Out
    Check 'release matrix: advisory only' ($r.Out -notmatch '"decision"') $r.Out
    Check 'V103 release matrix: missing signed asset upload is named and the signed-release reminder is present' ($r.Out -match 'no signed asset upload' -and $r.Out -match 'ready-to-download signed binaries/archives for every matrix target plus SHA256SUMS, \.sig, and attestations') $r.Out
    $r = Fire -HookPath $BaselineHook -Cwd $repo
    Check 'release matrix: the same finding set is said once per project' ($r.Out -notmatch 'RELEASE MATRIX') $r.Out

    $repo = New-GitRepo 'matrix-good' -GithubRemote:$false
    $dir = Join-Path $repo '.github/workflows'; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'release.yml'), "name: Release`non: workflow_dispatch`njobs:`n  build:`n    strategy:`n      matrix:`n        include:`n          - { os: windows-latest, target: x86_64-pc-windows-msvc }`n          - { os: windows-11-arm, target: aarch64-pc-windows-msvc }`n          - { os: ubuntu-latest, target: x86_64-unknown-linux-gnu }`n          - { os: ubuntu-24.04-arm, target: aarch64-unknown-linux-gnu }`n    runs-on: `${{ matrix.os }}`n    steps:`n      - run: gh release upload `$TAG dist/* SHA256SUMS`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $dir 'ci.yml'), "name: CI`non: workflow_dispatch`njobs:`n  t:`n    runs-on: macos-14`n", $utf8)
    $r = Fire -HookPath $BaselineHook -Cwd $repo
    Check 'release matrix: the default four targets -> silent; a non-release macOS CI job is not judged' ($r.Out -notmatch 'RELEASE MATRIX') $r.Out
}

function Invoke-GitleaksPushSkipRegression {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $cases = @(
        @{ Name = 'gl-if'; Body = "name: Gitleaks`non:`n  push:`n  workflow_dispatch:`njobs:`n  gitleaks:`n    name: Gitleaks secret scan`n    if: github.event_name != 'push' || github.ref_name == github.event.repository.default_branch`n    runs-on: ubuntu-24.04`n"; Defect = $true },
        @{ Name = 'gl-paths'; Body = "name: Gitleaks`non:`n  push:`n    paths:`n      - 'src/**'`n  workflow_dispatch:`njobs:`n  gitleaks:`n    runs-on: ubuntu-24.04`n"; Defect = $true },
        @{ Name = 'gl-clean'; Body = "name: Gitleaks`non:`n  push:`n  pull_request:`n    paths:`n      - 'src/**'`n  workflow_dispatch:`njobs:`n  gitleaks:`n    name: Gitleaks secret scan`n    runs-on: ubuntu-24.04`n    steps:`n      - if: always()`n        run: echo scan`n"; Defect = $false }
    )
    foreach ($case in $cases) {
        $repo = New-GitRepo $case.Name
        $dir = Join-Path $repo '.github/workflows'; [void][IO.Directory]::CreateDirectory($dir)
        [IO.File]::WriteAllText((Join-Path $dir 'gitleaks.yml'), $case.Body, $utf8)
        $r = Fire -HookPath $BaselineHook -Cwd $repo
        $hit = ($r.Out -match 'push-skip defect: Gitleaks secret scan \(push\) must run green, never skipped')
        Check ('V103 gitleaks workflow ' + $case.Name + ': push-skip defect ' + $(if ($case.Defect) { 'flagged' } else { 'not flagged' })) ($hit -eq $case.Defect) $r.Out
    }
}
