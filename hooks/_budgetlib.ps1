# The hook's own deadline, derived from the timeout the installer registered
# (`timeoutSeconds` in the runtime's .hookmaker-runtime.json). A child process
# that outlives the registered timeout is killed together with the hook by the
# client, and the hook then says nothing at all; bounding every child by the
# time LEFT keeps the hook able to report. Loaded sibling-first by the hooks that
# adopt it; absent on an older runtime, so every consumer keeps a fallback.

$script:HookDeadlineUtc = $null

function Get-HookRegisteredTimeoutSeconds {
    param([string]$RuntimeDirectory)
    $path = Join-Path $RuntimeDirectory '.hookmaker-runtime.json'
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $doc = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['timeoutSeconds']) {
                $value = [int]$doc.timeoutSeconds
                if ($value -ge 5 -and $value -le 600) { return $value }
            }
        }
    }
    catch { }
    return 60   # the installer's default when nothing (valid) is recorded
}

function Initialize-HookDeadline {
    param([string]$RuntimeDirectory, [int]$MarginSeconds = 5)
    $timeout = Get-HookRegisteredTimeoutSeconds -RuntimeDirectory $RuntimeDirectory
    $script:HookDeadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $timeout - $MarginSeconds))
}

function Get-HookRemainingSeconds {
    if ($null -eq $script:HookDeadlineUtc) { return 20 }
    return [int][Math]::Max(0, [Math]::Floor(($script:HookDeadlineUtc - [DateTime]::UtcNow).TotalSeconds))
}

# Invoke-QuietCommand bounded by the smaller of the requested timeout and what is
# left of the hook's own deadline. Over budget: no process is started and
# $LASTEXITCODE is 124, the code the guarded runner uses for "terminated".
function Invoke-BoundedCommand {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$ArgumentList, [int]$TimeoutSeconds = 20)
    $remaining = Get-HookRemainingSeconds
    if ($remaining -lt 1) { $global:LASTEXITCODE = 124; return @() }
    return (Invoke-QuietCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds ([Math]::Min($TimeoutSeconds, $remaining)))
}
