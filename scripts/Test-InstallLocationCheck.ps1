# Offline suite for Install-Location-Check - the advisory PreToolUse hook that
# asks for a user path before an install lands on the system drive.
#
# TWO LAYERS. Recognition, link silence and the once-per-package rule are
# driven IN-PROCESS through Get-InstallAdvisories with the seams in
# _physicalpath.ps1 set: the system drive is injected as 'C:', the resolver
# maps paths without any real cross-drive link, and the query seam answers
# npm/python prefixes without starting npm or python. The output SHAPE on both
# clients is asserted on a real child process. LOCALAPPDATA is redirected into
# the workspace so no real state file is read or written.
#
# Exit code is the number of failed assertions (0 = all passed).

[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$HooksRoot = Join-Path $ToolRoot 'hooks'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $ScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-installlocation'
$Hook = Join-Path $HooksRoot 'Install-Location-Check\Install-Location-Check.ps1'
$FakeLocalAppData = Join-Path $Work 'localappdata'
$StateDir = Join-Path $FakeLocalAppData 'HookMaker\state'
$Project = Join-Path $Work 'proj one'
New-Item -ItemType Directory -Path $Project -Force | Out-Null

# The hook script is dot-sourced: its entry block returns on '.', so only the
# functions load.
. $Hook

$script:QueryCalls = New-Object System.Collections.Generic.List[string]
$script:InstallLocationSystemDrive = 'C:'
# Paths under C:\Linked\ behave as a C: link to H:, the machine fact the rule
# is written around; everything else resolves to itself.
$script:InstallLocationResolver = { param($Path) if ($Path -like 'C:\Linked\*') { return ('H:\' + $Path.Substring(10)) } return $Path }
$script:QueryAnswers = @{ 'npm-prefix' = 'C:\Users\u\AppData\Roaming\npm'; 'python-prefix' = 'C:\Python312'; 'python-user' = 'C:\Users\u\AppData\Roaming\Python' }
$script:InstallLocationQuery = { param($Kind, $Program, $Arguments) [void]$script:QueryCalls.Add($Kind + '|' + $Program + '|' + (@($Arguments) -join ' ')); return $script:QueryAnswers[$Kind] }

$script:SessionCounter = 0
function Get-Advice {
    param([string]$Command, [string]$SessionId = '', [hashtable]$Env = @{})
    if ($SessionId -eq '') { $script:SessionCounter++; $SessionId = 'case-' + $script:SessionCounter }
    $saved = @{}
    foreach ($name in $Env.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $Env[$name]) }
    try { return @(Get-InstallAdvisories -Tokens @(Split-CommandTokens -Text $Command) -ProjectRoot $Project -SessionId $SessionId -StateDirectory $StateDir) }
    finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
}

# Every environment variable a family reads, cleared for the in-process cases
# so the developer's own settings cannot decide a result.
$familyEnv = @{}
foreach ($name in @('ChocolateyInstall', 'SCOOP', 'SCOOP_GLOBAL', 'npm_config_prefix', 'NPM_CONFIG_PREFIX', 'PNPM_HOME', 'PIPX_HOME', 'UV_TOOL_DIR',
        'UV_PYTHON_INSTALL_DIR', 'CARGO_HOME', 'GOBIN', 'GOPATH', 'HF_HUB_CACHE', 'HF_HOME', 'OLLAMA_MODELS', 'VIRTUAL_ENV')) { $familyEnv[$name] = $null }
$familyEnv['USERPROFILE'] = 'C:\Users\u'; $familyEnv['LOCALAPPDATA'] = 'C:\Users\u\AppData\Local'; $familyEnv['APPDATA'] = 'C:\Users\u\AppData\Roaming'
$familyEnv['ProgramFiles'] = 'C:\Program Files'; $familyEnv['ProgramData'] = 'C:\ProgramData'
$savedFamilyEnv = @{}
foreach ($name in $familyEnv.Keys) { $savedFamilyEnv[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $familyEnv[$name]) }

try {
    # =====================================================================
    Write-Host '--- every family fires when its target resolves to C: ---' -ForegroundColor Cyan
    $cases = @(
        @('winget install Git.Git', 'winget', 'Git.Git', 'C:\Program Files'),
        @('winget install --id Microsoft.PowerToys -e --scope user', 'winget', 'Microsoft.PowerToys', 'C:\Users\u\AppData\Local\Programs'),
        @('choco install 7zip -y', 'choco', '7zip', 'C:\ProgramData\chocolatey'),
        @('scoop install ripgrep', 'scoop', 'ripgrep', 'C:\Users\u\scoop'),
        @('pip install requests', 'pip', 'requests', 'C:\Python312'),
        @('py -3.12 -m pip install --user httpx', 'pip', 'httpx', 'C:\Users\u\AppData\Roaming\Python'),
        @('npm i -g typescript', 'npm', 'typescript', 'C:\Users\u\AppData\Roaming\npm'),
        @('pnpm add -g turbo', 'pnpm', 'turbo', 'C:\Users\u\AppData\Local\pnpm'),
        @('yarn global add serve', 'yarn', 'serve', 'C:\Users\u\AppData\Local\Yarn'),
        @('pipx install black', 'pipx', 'black', 'C:\Users\u\pipx'),
        @('uv tool install ruff', 'uv', 'ruff', 'C:\Users\u\AppData\Roaming\uv\data\tools'),
        @('uv python install 3.13', 'uv', 'python 3.13', 'C:\Users\u\AppData\Roaming\uv\data\python'),
        @('cargo install ripgrep', 'cargo', 'ripgrep', 'C:\Users\u\.cargo'),
        @('go install golang.org/x/tools/gopls@latest', 'go', 'golang.org/x/tools/gopls@latest', 'C:\Users\u\go\bin'),
        @('dotnet tool install -g dotnet-ef', 'dotnet', 'dotnet-ef', 'C:\Users\u\.dotnet\tools'),
        @('Install-Module -Name Pester -Scope AllUsers', 'PowerShell', 'Pester', 'C:\Program Files\PowerShell\Modules'),
        @('msiexec /i node.msi /qn', 'installer', 'node.msi', 'C:\Program Files'),
        @('.\tools\VSCodeSetup.exe /VERYSILENT', 'installer', 'VSCodeSetup.exe', 'C:\Program Files'),
        @('Start-Process -FilePath .\Git-2.50-installer.exe -ArgumentList "/SILENT"', 'installer', 'Git-2.50-installer.exe', 'C:\Program Files'),
        @('hf download meta-llama/Llama-3.2-1B', 'huggingface', 'meta-llama/Llama-3.2-1B', 'C:\Users\u\.cache\huggingface\hub'),
        @('ollama pull llama3', 'ollama', 'llama3', 'C:\Users\u\.ollama\models')
    )
    foreach ($case in $cases) {
        $lines = @(Get-Advice $case[0])
        $expected = 'INSTALL LOCATION: ' + $case[1] + ' would install ' + $case[2] + ' into ' + $case[3] + ' on C:.'
        Check ('fires: ' + $case[0]) ($lines.Count -eq 1 -and $lines[0].StartsWith($expected)) ($lines -join ' || ')
    }
    $line = @(Get-Advice 'winget install Git.Git')[0]
    Check 'advisory: carries the ask, the verify step and the rule reference' (
        $line -match 'Ask the user for the install path first, naming the package' -and $line -match 'verify where it landed' -and
        $line -match 'Rule: global-environment-rules\.md -> Install Locations\.') $line

    # =====================================================================
    Write-Host '--- silence: an answered location, a link, the project, an unknown command ---' -ForegroundColor Cyan
    Check 'silent: winget with an explicit off-C --location' (@(Get-Advice 'winget install X --location G:\Apps\X').Count -eq 0)
    Check 'silent: winget with -l= form off C:' (@(Get-Advice 'winget install X -l=D:\Apps\X').Count -eq 0)
    $script:QueryAnswers['npm-prefix'] = 'G:\Program Files\npm\global'
    Check 'silent: npm -g with a G: prefix' (@(Get-Advice 'npm i -g typescript').Count -eq 0)
    $script:QueryAnswers['npm-prefix'] = 'C:\Users\u\AppData\Roaming\npm'
    Check 'silent: a C: target that is a link to another drive' (@(Get-Advice 'ollama pull llama3' -Env @{ OLLAMA_MODELS = 'C:\Linked\models' }).Count -eq 0)
    $script:QueryAnswers['python-prefix'] = 'C:\Linked\Programs\Python\Python312'
    Check 'silent: a queried interpreter prefix that resolves off C:' (@(Get-Advice 'pip install x').Count -eq 0)
    $script:QueryAnswers['python-prefix'] = 'C:\Python312'
    Check 'silent: npm install without -g (project-local)' (@(Get-Advice 'npm install lodash').Count -eq 0)
    Check 'silent: pip through the project venv interpreter' (@(Get-Advice '.venv\Scripts\python.exe -m pip install requests').Count -eq 0)
    Check 'silent: pip after activating a venv in the same command' (@(Get-Advice '.venv\Scripts\activate && pip install requests').Count -eq 0)
    Check 'silent: pip --target into the project' (@(Get-Advice ('pip install x --target "' + (Join-Path $Project 'vendor') + '"')).Count -eq 0)
    Check 'silent: VIRTUAL_ENV inside the project' (@(Get-Advice 'pip install x' -Env @{ VIRTUAL_ENV = (Join-Path $Project '.venv') }).Count -eq 0)
    Check 'silent: hf download with --local-dir' (@(Get-Advice 'hf download org/m --local-dir C:\models').Count -eq 0)
    Check 'silent: dotnet local tool (no -g)' (@(Get-Advice 'dotnet tool install dotnet-ef').Count -eq 0)
    Check 'silent: winget upgrade --all' (@(Get-Advice 'winget upgrade --all').Count -eq 0)
    Check 'silent: an uninstaller is not an installer' (@(Get-Advice '.\unins000.exe /SILENT').Count -eq 0)
    foreach ($quiet in @('git status', 'npm test', 'pip list', 'python -m pytest', 'pwsh -Command "winget install Git.Git"', 'echo "npm i -g x"')) {
        Check ('silent: ' + $quiet) (@(Get-Advice $quiet).Count -eq 0)
    }
    $script:QueryAnswers['python-prefix'] = $null
    Check 'silent: a query that returns nothing (timeout, missing tool)' (@(Get-Advice 'pip install x').Count -eq 0)
    $script:QueryAnswers['python-prefix'] = 'C:\Python312'
    Check 'system drive is the injected one: C: paths are silent when the system drive is D:' $(
        try { $script:InstallLocationSystemDrive = 'D:'; @(Get-Advice 'winget install Git.Git').Count -eq 0 } finally { $script:InstallLocationSystemDrive = 'C:' })

    # =====================================================================
    Write-Host '--- once per package per session; quoting and chaining ---' -ForegroundColor Cyan
    $first = @(Get-Advice 'winget install Git.Git' -SessionId 'once-a')
    $second = @(Get-Advice 'winget install Git.Git' -SessionId 'once-a')
    $other = @(Get-Advice 'winget install Git.Git' -SessionId 'once-b')
    Check 'once: the same package in one session fires once' ($first.Count -eq 1 -and $second.Count -eq 0)
    Check 'once: a new session fires again' ($other.Count -eq 1)
    Check 'once: a different package in the same session still fires' (@(Get-Advice 'winget install GitHub.cli' -SessionId 'once-a').Count -eq 1)
    $seen = @(Get-ChildItem -LiteralPath $StateDir -Filter 'InstallLocation-*.txt' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
    Check 'state: fingerprints are hashed - no package or command text on disk' ($seen -notmatch 'Git|winget|GitHub') $seen
    $chained = @(Get-Advice 'git pull && winget install A.A B.B; ollama pull llama3 | Out-Null')
    Check 'chained: every install segment is found, one line per package' ($chained.Count -eq 3) ($chained -join ' || ')
    $quoted = @(Get-Advice 'winget install "Some App" --location "G:\Program Files\Some App"')
    Check 'quoted: a quoted off-C location with spaces is honoured' ($quoted.Count -eq 0)
    $quotedC = @(Get-Advice 'msiexec /i "C:\dl\my app.msi" INSTALLDIR="C:\Program Files\My App" /qn')
    Check 'quoted: an installer property with spaces is read whole' ($quotedC.Count -eq 1 -and $quotedC[0] -match 'into C:\\Program Files\\My App on C:') ($quotedC -join ' || ')
    $offMsi = @(Get-Advice 'msiexec /i app.msi INSTALLDIR="G:\Apps\My App"')
    Check 'installer: an off-C INSTALLDIR is silent' ($offMsi.Count -eq 0)
    Check 'queries: npm prefix is asked through the seam, python with its interpreter flags' (
        @($script:QueryCalls | Where-Object { $_ -eq 'python-user|py|-3.12' }).Count -ge 1 -and @($script:QueryCalls | Where-Object { $_ -like 'npm-prefix|*' }).Count -ge 1) ($script:QueryCalls -join ', ')

    # =====================================================================
    Write-Host '--- an explicit interpreter path is never executed, only a bare name is queried ---' -ForegroundColor Cyan
    $before = $script:QueryCalls.Count
    $offC = @(Get-Advice 'D:\downloads\python.exe -m pip install requests')
    Check 'explicit path off C: is silent and never queried' ($offC.Count -eq 0 -and $script:QueryCalls.Count -eq $before) ($script:QueryCalls -join ', ')
    $venvC = @(Get-Advice 'C:\Tools\venv\Scripts\python.exe -m pip install requests')
    Check 'explicit venv interpreter on C: fires with the Scripts parent as target, never queried' (
        $venvC.Count -eq 1 -and $venvC[0] -match 'requests into C:\\Tools\\venv on C:' -and $script:QueryCalls.Count -eq $before) ($venvC -join ' || ')
    $projectDrive = [System.IO.Path]::GetPathRoot($Project).TrimEnd('\')
    $relative = $(try { $script:InstallLocationSystemDrive = $projectDrive; @(Get-Advice '..\tools\py.exe -m pip install x') } finally { $script:InstallLocationSystemDrive = 'C:' })
    Check 'a relative interpreter path outside the project resolves against the project root, never queried' (
        $relative.Count -eq 1 -and $relative[0] -match ([regex]::Escape((Join-Path $Work 'tools'))) -and $script:QueryCalls.Count -eq $before) ($relative -join ' || ')
    $null = Get-Advice 'python -m pip install requests'
    Check 'a bare interpreter name is still queried once (PATH resolution, by design)' (
        $script:QueryCalls.Count -eq $before + 1 -and $script:QueryCalls[$before] -eq 'python-prefix|python|') ($script:QueryCalls -join ', ')

    # =====================================================================
    Write-Host '--- physical path: a real junction is followed, through a parent too ---' -ForegroundColor Cyan
    $script:InstallLocationResolver = $null
    $realTarget = Join-Path $Work 'real target'
    New-Item -ItemType Directory -Path (Join-Path $realTarget 'inner') -Force | Out-Null
    $junction = Join-Path $Work 'junction here'
    $null = New-Item -ItemType Junction -Path $junction -Target $realTarget
    Check 'resolve: a junction resolves to its target' ((Resolve-PhysicalPath $junction) -ieq $realTarget) (Resolve-PhysicalPath $junction)
    Check 'resolve: a path BELOW a junction re-joins its tail' ((Resolve-PhysicalPath (Join-Path $junction 'inner\not yet')) -ieq (Join-Path $realTarget 'inner\not yet')) (Resolve-PhysicalPath (Join-Path $junction 'inner\not yet'))
    Check 'resolve: a plain path is unchanged' ((Resolve-PhysicalPath $realTarget) -ieq $realTarget)
    [IO.Directory]::Delete($junction)
}
finally {
    foreach ($name in $savedFamilyEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedFamilyEnv[$name]) }
}

try {
    # =====================================================================
    Write-Host '--- the hook process: context only, never a decision, both clients ---' -ForegroundColor Cyan
    function Invoke-LocationHook {
        param([hashtable]$Payload, [string]$Client, [string]$Exe = 'pwsh')
        $json = ($Payload | ConvertTo-Json -Depth 8 -Compress)
        $saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; CLAUDE_PROJECT_DIR = $env:CLAUDE_PROJECT_DIR; HOOKMAKER_CLIENT = $env:HOOKMAKER_CLIENT; OLLAMA_MODELS = $env:OLLAMA_MODELS; SystemDrive = $env:SystemDrive }
        $env:LOCALAPPDATA = $FakeLocalAppData; $env:HOOKMAKER_CLIENT = $Client
        # A target on the real system drive whatever it is called on this runner.
        $env:OLLAMA_MODELS = Join-Path $Work 'ollama models'; $env:SystemDrive = $Work.Substring(0, 2)
        try {
            $out = ($json | & $Exe -NoProfile -NonInteractive -File $Hook 2>&1) -join "`n"
            return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
        }
        finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
    }
    foreach ($client in @('claude', 'codex')) {
        $r = Invoke-LocationHook -Client $client -Payload @{ hook_event_name = 'PreToolUse'; cwd = $Project; session_id = ('proc-' + $client); tool_name = 'Bash'; tool_input = @{ command = 'ollama pull llama3' } }
        $parsed = $null; try { $parsed = $r.Out | ConvertFrom-Json } catch { }
        Check ($client + ': exit 0') ($r.Exit -eq 0) ([string]$r.Exit)
        Check ($client + ': additionalContext carries the advisory') ($null -ne $parsed -and [string]$parsed.hookSpecificOutput.additionalContext -match '^INSTALL LOCATION: ollama would install llama3') $r.Out
        Check ($client + ': no permissionDecision - an advisory never approves or denies') ($r.Out -notmatch 'permissionDecision' -and $r.Out -notmatch '"decision"') $r.Out
        $again = Invoke-LocationHook -Client $client -Payload @{ hook_event_name = 'PreToolUse'; cwd = $Project; session_id = ('proc-' + $client); tool_name = 'Bash'; tool_input = @{ command = 'ollama pull llama3' } }
        Check ($client + ': the repeat in the same session is silent') ($again.Exit -eq 0 -and $again.Out.Trim() -eq '') $again.Out
    }
    $argv = Invoke-LocationHook -Client 'codex' -Payload @{ hook_event_name = 'PreToolUse'; cwd = $Project; session_id = 'proc-argv'; tool_name = 'shell'; tool_input = @{ command = @('ollama', 'pull', 'mistral') } }
    Check 'codex: an argv-array command is read as tokens' ($argv.Out -match 'ollama would install mistral') $argv.Out
    foreach ($quietEvent in @('PostToolUse', 'Stop', 'SessionStart')) {
        $q = Invoke-LocationHook -Client 'claude' -Payload @{ hook_event_name = $quietEvent; cwd = $Project; session_id = ('q-' + $quietEvent); tool_input = @{ command = 'ollama pull llama3' } }
        Check ('silent on ' + $quietEvent) ($q.Exit -eq 0 -and $q.Out.Trim() -eq '') $q.Out
    }
    $garbage = ('not json' | & pwsh -NoProfile -NonInteractive -File $Hook 2>&1) -join ''
    Check 'malformed input: silent, exit 0' ($LASTEXITCODE -eq 0 -and $garbage.Trim() -eq '') $garbage
    $r51 = Invoke-LocationHook -Exe 'powershell.exe' -Client 'claude' -Payload @{ hook_event_name = 'PreToolUse'; cwd = $Project; session_id = 'proc-51'; tool_input = @{ command = 'ollama pull phi3' } }
    Check 'Windows PowerShell 5.1 emits the same advisory' ($r51.Exit -eq 0 -and $r51.Out -match 'ollama would install phi3') $r51.Out
    foreach ($file in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -Filter '*.ps1') + @(Get-Item (Join-Path $HooksRoot '_commandtokens.ps1'))) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Check ('shipped source is pure ASCII: ' + $file.Name) (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0)
    }
}
finally {
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
