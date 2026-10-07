param([Parameter(Mandatory=$true)][string]$PlanFile)
$ErrorActionPreference = 'Stop'
$taskPlan = Get-Content -LiteralPath $PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json
$taskJob = [IO.Path]::GetFullPath((Split-Path -Parent $PlanFile))
$taskDone = [Collections.Generic.List[object]]::new()
$taskResult = 'failed'
$taskError = ''
try {
    if ($taskPlan.schema -ne 1) { throw 'Invalid update plan' }
    $taskTarget = [IO.Path]::GetFullPath($taskPlan.target)
    $taskStage = [IO.Path]::GetFullPath($taskPlan.stage)
    $taskBackup = [IO.Path]::GetFullPath($taskPlan.backup)
    if (-not $taskStage.StartsWith($taskJob + '\', [StringComparison]::OrdinalIgnoreCase) -or -not $taskBackup.StartsWith($taskJob + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid staging paths' }
    if ($taskPlan.pid -gt 0) {
        $taskParent = Get-Process -Id $taskPlan.pid -ErrorAction SilentlyContinue
        if ($taskParent -and -not $taskParent.WaitForExit(60000)) { throw 'Launcher did not exit within 60 seconds' }
    }
    Start-Sleep -Milliseconds 1000
    New-Item -ItemType Directory -Force -Path $taskBackup | Out-Null
    foreach ($taskName in $taskPlan.names) {
        if ($taskName -match '[\\/:]' -or $taskName -in @('versions','instances','cache','trash','state.json','launcher-paths.json') -or $taskName -in @('.','..')) { throw 'Invalid runtime path' }
        $taskSource = Join-Path $taskStage $taskName
        $taskDest = Join-Path $taskTarget $taskName
        $taskSaved = Join-Path $taskBackup $taskName
        if (-not (Test-Path -LiteralPath $taskSource)) { throw 'Missing staged runtime file' }
        if ((Get-Item -LiteralPath $taskSource -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked stage rejected' }
        $taskHadOld = Test-Path -LiteralPath $taskDest
        if ($taskHadOld) {
            if ((Get-Item -LiteralPath $taskDest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked destination rejected' }
            for ($taskAttempt=0; ; $taskAttempt++) {
                try { Move-Item -LiteralPath $taskDest -Destination $taskSaved; break }
                catch { if ($taskAttempt -ge 19) { throw }; Start-Sleep -Milliseconds 500 }
            }
        }
        $taskDone.Add([pscustomobject]@{ Name=$taskName; HadOld=$taskHadOld })
        Copy-Item -LiteralPath $taskSource -Destination $taskDest -Recurse
    }
    $taskResult = 'installed'
} catch {
    $taskError = $_.Exception.Message
    for ($taskIndex=$taskDone.Count-1; $taskIndex -ge 0; $taskIndex--) {
        $taskRecord = $taskDone[$taskIndex]
        $taskDest = Join-Path $taskTarget $taskRecord.Name
        $taskSaved = Join-Path $taskBackup $taskRecord.Name
        try {
            if (Test-Path -LiteralPath $taskDest) { Move-Item -LiteralPath $taskDest -Destination (Join-Path $taskJob ('failed-' + $taskRecord.Name)) }
            if ($taskRecord.HadOld) { Move-Item -LiteralPath $taskSaved -Destination $taskDest }
        } catch { $taskResult = 'restore-failed'; $taskError += '; rollback: ' + $_.Exception.Message }
    }
    if ($taskResult -ne 'restore-failed') { $taskResult = 'rolled-back' }
}
@{status=$taskResult;version=$taskPlan.version;error=$taskError;backup=$taskPlan.backup} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskJob 'result.json') -Encoding UTF8
if ($taskPlan.restart -and $taskResult -ne 'restore-failed') {
    Start-Process -FilePath (Join-Path $taskPlan.target 'Aegisub Launcher.exe') -WorkingDirectory $taskPlan.target -WindowStyle Hidden
}
if ($taskResult -ne 'installed') { exit 1 }
