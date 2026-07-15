function Check {
    param([string]$Name, [bool]$Condition, [string]$Actual = $null)
    if ($Condition) {
        $script:Pass++
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($env:HOOKMAKER_TEST_DEBUG -eq '1' -and $null -ne $Actual) {
            $preview = $Actual
            if ($preview.Length -gt $script:TestPreviewLength) {
                $preview = $preview.Substring(0, $script:TestPreviewLength)
            }
            Write-Host ('       actual: [' + $preview + ']') -ForegroundColor DarkGray
        }
    }
}
