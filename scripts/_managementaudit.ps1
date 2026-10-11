# Management diagnostics only; never copied into installed hook runtimes.
function Get-ManagementAuditIdentity {
    $identity = [ordered]@{
        runId = [guid]::NewGuid().ToString('N'); accountState = 'unknown'; account = 'unknown'; sid = 'unknown'
        processId = $PID; processStartUtc = 'unknown'; parentState = 'unknown'; parentId = 0
        parentStartUtc = 'unknown'; parentName = 'unknown'; origin = 'unknown'; originTrust = 'unverified'
        originClaim = 'unknown'; runtime = $PSVersionTable.PSVersion.ToString()
    }
    $account = $null; $process = $null; $parent = $null
    try {
        $account = [Security.Principal.WindowsIdentity]::GetCurrent()
        $identity.account = $account.Name; $identity.sid = $account.User.Value
        $identity.accountState = 'observed'
    } catch { } finally { if ($null -ne $account) { $account.Dispose() } }
    $claim = [string]$env:HOOKMAKER_CALLER_ORIGIN
    if (@('human','claude','codex','automation','unknown') -ccontains $claim) { $identity.originClaim = $claim }
    try {
        $process = [Diagnostics.Process]::GetCurrentProcess()
        $start = $process.StartTime.ToUniversalTime()
        $identity.processStartUtc = $start.ToString('o')
        # A finite local snapshot avoids WMI provider waits. A name is evidence,
        # not authenticated human/agent attribution; PID reuse stays unknown.
        if ($null -eq ('HookMaker.ManagementParent' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace HookMaker {
    public static class ManagementParent {
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        struct Entry {
            public uint Size, Usage, Id; public IntPtr Heap; public uint Module, Threads, Parent;
            public int Priority; public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Name;
        }
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint id);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32FirstW(IntPtr handle, ref Entry entry);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32NextW(IntPtr handle, ref Entry entry);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public static int Find(int id) {
            IntPtr handle = CreateToolhelp32Snapshot(2, 0);
            if (handle == new IntPtr(-1)) return 0;
            try {
                Entry entry = new Entry(); entry.Size = (uint)Marshal.SizeOf(typeof(Entry));
                Stopwatch clock = Stopwatch.StartNew();
                if (!Process32FirstW(handle, ref entry)) return 0;
                for (int count=0; count<32768 && clock.ElapsedMilliseconds<250; count++) {
                    if (entry.Id == (uint)id) return (int)entry.Parent;
                    if (!Process32NextW(handle, ref entry)) break;
                }
                return 0;
            } finally { CloseHandle(handle); }
        }
    }
}
'@ -ErrorAction Stop
        }
        $parentId = [HookMaker.ManagementParent]::Find($PID)
        if ($parentId -gt 0 -and $parentId -ne $PID) {
            $parent = [Diagnostics.Process]::GetProcessById($parentId)
            $parentStart = $parent.StartTime.ToUniversalTime()
            if ($parentStart -le $start -and -not $parent.HasExited) {
                $identity.parentId = $parentId; $identity.parentStartUtc = $parentStart.ToString('o')
                $identity.parentName = $parent.ProcessName; $identity.parentState = 'observed'
            }
        }
    } catch { } finally {
        if ($null -ne $parent) { $parent.Dispose() }
        if ($null -ne $process) { $process.Dispose() }
    }
    return [pscustomobject]$identity
}

function New-ManagementLogFile {
    param([string]$Directory, [string]$Name)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }
    $base = Join-Path $Directory ($Name + '_' + [DateTime]::UtcNow.ToString('yyyy-MM-dd_HH-mm-ss') + '_UTC')
    for ($i = 0; $i -lt 1000; $i++) {
        $path = $base + $(if ($i -eq 0) { '' } else { '_' + $i }) + '.log'
        try {
            $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $stream.Dispose()
            return $path
        } catch [IO.IOException] { if (-not [IO.File]::Exists($path)) { throw } }
    }
    throw 'Could not allocate a distinct management log.'
}

function Start-ManagementAudit {
    param([string]$ToolRoot, [string]$Name, [string]$Path = '')
    $script:ManagementAuditIdentity = Get-ManagementAuditIdentity
    $script:ManagementAuditWarning = $false
    $script:ManagementAuditPath = $Path
    if ([string]::IsNullOrWhiteSpace($Path)) {
        try {
            $directory = Join-Path $ToolRoot 'logs'
            if (-not [string]::IsNullOrWhiteSpace($env:HOOKMAKER_LOG_DIR)) { $directory = $env:HOOKMAKER_LOG_DIR }
            $script:ManagementAuditPath = New-ManagementLogFile -Directory $directory -Name $Name
        } catch { $script:ManagementAuditPath = ''; Write-ManagementAuditWarning }
    }
    Write-ManagementAudit -Event 'execution' -Data @{ tool = $Name; identity = $script:ManagementAuditIdentity }
}

function Write-ManagementAuditWarning {
    if (-not $script:ManagementAuditWarning) {
        $script:ManagementAuditWarning = $true
        try { Write-Warning 'Management audit logging is unavailable; the action outcome is unchanged.' -WarningAction Continue } catch { }
    }
}

function Write-ManagementAudit {
    param([string]$Event, [System.Collections.IDictionary]$Data = @{})
    if (-not (Get-Variable ManagementAuditIdentity -Scope Script -ErrorAction SilentlyContinue)) { return }
    if ([string]::IsNullOrWhiteSpace($script:ManagementAuditPath)) { Write-ManagementAuditWarning; return }
    try {
        # Only callers' diagnostic projections enter here, never raw arguments,
        # config bodies, environment or exception messages. JSON escapes controls.
        $entry = [ordered]@{ event = $Event; runId = $script:ManagementAuditIdentity.runId; data = (ConvertTo-ManagementAuditData $Data) }
        $json = $entry | ConvertTo-Json -Compress -Depth 12
        $line = '[' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC] [INFO] [AUDIT] ' + $json + "`r`n"
        [IO.File]::AppendAllText($script:ManagementAuditPath,$line,[Text.UTF8Encoding]::new($false))
    } catch { Write-ManagementAuditWarning }
}

function ConvertTo-ManagementAuditData {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 10) { return '[TRUNCATED]' }
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long]) { return $Value }
    if ($Value -is [string]) {
        $text = [regex]::Replace($Value, '[\x00-\x1f\x7f]', ' ')
        $text = [regex]::Replace($text, '(?i)(?:token|password|secret|api[_-]?key|authorization)\s*[:=]\s*\S+', '[REDACTED]')
        $text = [regex]::Replace($text, '(?i)\b(?:sk-[a-z0-9_-]{16,}|gh[pousr]_[a-z0-9]{20,})\b', '[REDACTED]')
        $text = [regex]::Replace($text, '(?i)\b[a-z][a-z0-9+.-]*://[^/\s]*@', '[REDACTED]://')
        if ($text.Length -gt 2048) { return $text.Substring(0,2048) + '[TRUNCATED]' }
        return $text
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = ConvertTo-ManagementAuditData $Value[$key] ($Depth + 1) }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(); foreach ($item in $Value) { $items += (ConvertTo-ManagementAuditData $item ($Depth + 1)) }
        return ,$items
    }
    $properties = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) { $properties[$property.Name] = ConvertTo-ManagementAuditData $property.Value ($Depth + 1) }
    return $properties
}

function Get-ManagementField {
    param($Object,[string]$Name)
    if ($null -eq $Object) { return '' }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return [string]$Object[$Name] }; return '' }
    if ($null -eq $Object.PSObject.Properties[$Name]) { return '' }
    return [string]$Object.$Name
}

function Get-ManagementRecordId {
    param([string]$Id)
    # Registry-safe syntax alone cannot make arbitrary supplied text non-secret.
    # Managed IDs are hashes; discovered IDs may have a conventional prefix.
    if ($Id -match '^(?:[a-f0-9]{10}|disc-[a-f0-9]{10,64})$') { return $Id }
    return 'unknown'
}

function Get-ManagementProfileSummary {
    param($Profile)
    $members = @{}; $state = 'observed'
    $id = Get-ManagementField $Profile 'id'
    if ($id -eq '') { $id = 'unknown'; $state = 'partial' }
    $routes = @()
    if ($null -ne $Profile -and $null -ne $Profile.PSObject.Properties['routes']) { $routes = @($Profile.routes) } else { $state = 'partial' }
    foreach ($route in $routes) {
        foreach ($side in @('source','destination')) {
            if ($null -eq $route -or $null -eq $route.PSObject.Properties[$side]) { $state = 'partial'; continue }
            $endpoint = $route.$side
            $root = Get-ManagementField $endpoint 'root'
            if ($root -eq '') { $state = 'partial'; continue }
            $name = Get-ManagementField $endpoint 'name'
            if ($name -eq '') { $name = Split-Path -Leaf $root; $state = 'partial' }
            $members[$root.ToLowerInvariant()] = [ordered]@{ name = $name; root = $root }
        }
    }
    return [ordered]@{ id = $id; members = @($members.Values | Sort-Object { $_.root }); state = $state }
}

function Write-ManagementComponentAudit {
    param([string]$Component,[string]$Status,[string]$ReasonCode)
    Write-ManagementAudit -Event 'component' -Data @{ component = $Component; status = $Status; reason = $ReasonCode }
}
