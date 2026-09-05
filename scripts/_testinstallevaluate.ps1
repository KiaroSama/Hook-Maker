# Dot-sourced scenario block of Test-InstallRegistry.ps1: the update-plan
# evaluator - one read-only verdict per record, and the two schedulers that
# produce them. Pins the exact skip reasons a user reads in the plan, that the
# printed ORDER matches the input (the plan is numbered and selected by number),
# and that the parallel scheduler agrees with the sequential one record for
# record. NOT a standalone suite: dot-sourced into the entry suite's scope and
# relies on its harness (Check, $script:Pass/$script:Fail) and workspace.

    # =====================================================================
    Write-Host '--- update evaluation: worker count is bounded and overridable DOWN only ---' -ForegroundColor Cyan
    $evalWorkersDefault = Get-UpdateEvaluationWorkerCount
    Check 'evaluate: the default worker count is at least 2' ($evalWorkersDefault -ge 2) ([string]$evalWorkersDefault)
    Check 'evaluate: the default worker count never exceeds 8' ($evalWorkersDefault -le 8) ([string]$evalWorkersDefault)
    $evalPriorWorkers = $env:HOOKMAKER_MAX_UPDATE_WORKERS
    try {
        $env:HOOKMAKER_MAX_UPDATE_WORKERS = '1'
        Check 'evaluate: the override can lower the worker count' ((Get-UpdateEvaluationWorkerCount) -eq 1) ([string](Get-UpdateEvaluationWorkerCount))
        # A machine cannot ask for MORE than the resource-aware ceiling: the
        # point of the cap is not to compete with everything else running.
        $env:HOOKMAKER_MAX_UPDATE_WORKERS = '512'
        Check 'evaluate: the override can NEVER raise it above the cap' ((Get-UpdateEvaluationWorkerCount) -eq $evalWorkersDefault) ([string](Get-UpdateEvaluationWorkerCount))
        $env:HOOKMAKER_MAX_UPDATE_WORKERS = 'not-a-number'
        Check 'evaluate: a non-numeric override is ignored, not fatal' ((Get-UpdateEvaluationWorkerCount) -eq $evalWorkersDefault) ([string](Get-UpdateEvaluationWorkerCount))
    }
    finally { $env:HOOKMAKER_MAX_UPDATE_WORKERS = $evalPriorWorkers }

    # =====================================================================
    Write-Host '--- update evaluation: every skip names its own cause ---' -ForegroundColor Cyan
    $evalWork = New-TestWorkspace -Prefix 'hookmaker-evaluate'
    try {
        $evalProject = Join-Path $evalWork 'Project'
        New-Item -ItemType Directory -Path $evalProject -Force | Out-Null
        $evalScript = Join-Path $evalWork 'source\Fixture-Hook\Fixture-Hook.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $evalScript) -Force | Out-Null
        Write-Utf8 $evalScript '# fixture'

        function New-EvalRecord {
            param(
                [string]$Id = 'eval00000',
                [string]$Source = '',
                [string]$Project = '',
                [string]$HookType = 'CustomHook',
                [string]$ConfigPath = '',
                [string]$ProfileId = ''
            )
            if ([string]::IsNullOrEmpty($Source)) { $Source = $evalScript }
            if ([string]::IsNullOrEmpty($Project)) { $Project = $evalProject }
            return [pscustomobject]@{
                id                = $Id
                schema            = 2
                internalName      = 'Fixture-Hook'
                friendlyName      = 'Fixture-Hook'
                hookType          = $HookType
                sourceScript      = $Source
                sourceDir         = (Split-Path -Parent $Source)
                toolRoot          = $ToolRoot
                scope             = 'project'
                targetProjectRoot = $Project
                profile           = $ProfileId
                configPath        = $ConfigPath
                sourceManifest    = @()
                clients           = [pscustomobject]@{}
            }
        }

        $evalMissingSource = Get-RecordUpdateState -Record (New-EvalRecord -Source (Join-Path $evalWork 'gone\Gone.ps1')) -ToolRoot $ToolRoot
        Check 'evaluate: a missing source script is skipped by name' (
            $evalMissingSource.Status -eq 'skip' -and $evalMissingSource.Detail -match 'source script no longer found') $evalMissingSource.Detail

        $evalMissingProject = Get-RecordUpdateState -Record (New-EvalRecord -Project (Join-Path $evalWork 'no-such-project')) -ToolRoot $ToolRoot
        Check 'evaluate: a missing target project is skipped by name' (
            $evalMissingProject.Status -eq 'skip' -and $evalMissingProject.Detail -match 'target project no longer found') $evalMissingProject.Detail

        # A profile id is required for the record to be VALID at all - without
        # one it is rejected as malformed and never reaches the config check.
        $evalMissingConfig = Get-RecordUpdateState -Record (New-EvalRecord -HookType 'Engine' -ProfileId 'some-profile' -ConfigPath (Join-Path $evalWork 'no-such-config.json')) -ToolRoot $ToolRoot
        Check 'evaluate: an engine with no sync config is skipped by name' (
            $evalMissingConfig.Status -eq 'skip' -and $evalMissingConfig.Detail -match 'sync config no longer found') $evalMissingConfig.Detail

        $evalConfig = Join-Path $evalWork 'sync.json'
        Write-Utf8 $evalConfig (@{ version = 1; profiles = @(@{ id = 'kept-profile'; name = 'Kept'; routes = @() }) } | ConvertTo-Json -Depth 8)
        $evalGoneProfile = Get-RecordUpdateState -Record (New-EvalRecord -HookType 'Engine' -ConfigPath $evalConfig -ProfileId 'deleted-profile') -ToolRoot $ToolRoot
        Check 'evaluate: an engine whose profile is gone is skipped by name' (
            $evalGoneProfile.Status -eq 'skip' -and $evalGoneProfile.Detail -match 'profile no longer exists') $evalGoneProfile.Detail

        # The reason per-record isolation exists: one malformed record must not
        # end a 600-record run, so it becomes a reported skip and never throws.
        $evalBroken = Get-RecordUpdateState -Record ([pscustomobject]@{ id = 'broken' }) -ToolRoot $ToolRoot
        Check 'evaluate: a malformed record is a reported skip, never a throw' ($evalBroken.Status -eq 'skip') $evalBroken.Detail

        # =====================================================================
        Write-Host '--- update evaluation: both schedulers agree, and order is the contract ---' -ForegroundColor Cyan
        # The plan is printed numbered and the user selects BY that number, so a
        # scheduler that reorders records would hand them a different hook than
        # the one they read. 40 records is over MinimumForParallel, so the
        # parallel path really runs here.
        $evalRecords = @(0..39 | ForEach-Object {
                if ($_ % 3 -eq 0) { New-EvalRecord -Id ('eval' + $_.ToString('00000')) -Source (Join-Path $evalWork ('gone\Gone' + $_ + '.ps1')) }
                elseif ($_ % 3 -eq 1) { New-EvalRecord -Id ('eval' + $_.ToString('00000')) -Project (Join-Path $evalWork ('no-project-' + $_)) }
                else { New-EvalRecord -Id ('eval' + $_.ToString('00000')) }
            })
        $evalSequential = @(Get-UpdateEvaluationPlan -Records $evalRecords -ToolRoot $ToolRoot -MinimumForParallel 999999)
        $evalParallel = @(Get-UpdateEvaluationPlan -Records $evalRecords -ToolRoot $ToolRoot -MinimumForParallel 4)
        Check 'evaluate: one plan entry per record, sequentially' ($evalSequential.Count -eq $evalRecords.Count) ([string]$evalSequential.Count)
        Check 'evaluate: one plan entry per record, in parallel' ($evalParallel.Count -eq $evalRecords.Count) ([string]$evalParallel.Count)

        $evalOrderOk = $true
        $evalAgree = $true
        $evalFirstDifference = ''
        for ($evalIndex = 0; $evalIndex -lt $evalRecords.Count; $evalIndex++) {
            if ([string]$evalSequential[$evalIndex].Record.id -ne [string]$evalRecords[$evalIndex].id -or
                [string]$evalParallel[$evalIndex].Record.id -ne [string]$evalRecords[$evalIndex].id) { $evalOrderOk = $false }
            if ([string]$evalSequential[$evalIndex].Status -ne [string]$evalParallel[$evalIndex].Status -or
                [string]$evalSequential[$evalIndex].Detail -ne [string]$evalParallel[$evalIndex].Detail) {
                $evalAgree = $false
                if ($evalFirstDifference -eq '') {
                    $evalFirstDifference = ('#' + $evalIndex + ': ' + $evalSequential[$evalIndex].Status + ' / ' + $evalParallel[$evalIndex].Status)
                }
            }
        }
        Check 'evaluate: both schedulers keep the input order' $evalOrderOk
        Check 'evaluate: the parallel verdict matches the sequential one, record for record' $evalAgree $evalFirstDifference

        # A worker count of 1 is a supported escape hatch, not a broken state.
        $evalPriorWorkers = $env:HOOKMAKER_MAX_UPDATE_WORKERS
        try {
            $env:HOOKMAKER_MAX_UPDATE_WORKERS = '1'
            $evalSingle = @(Get-UpdateEvaluationPlan -Records $evalRecords -ToolRoot $ToolRoot -MinimumForParallel 4)
            Check 'evaluate: one worker falls back to sequential and still returns every record' (
                $evalSingle.Count -eq $evalRecords.Count -and
                [string]$evalSingle[0].Status -eq [string]$evalSequential[0].Status) ([string]$evalSingle.Count)
        }
        finally { $env:HOOKMAKER_MAX_UPDATE_WORKERS = $evalPriorWorkers }

        Check 'evaluate: no records means an empty plan, not a crash' (
            @(Get-UpdateEvaluationPlan -Records @() -ToolRoot $ToolRoot).Count -eq 0)
    }
    finally {
        if (-not (Remove-TestWorkspace $evalWork)) { $script:Fail++ }
    }
