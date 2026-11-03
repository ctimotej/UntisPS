# UntisPS module loader. Source files stay ASCII so Windows PowerShell 5.1 reads them correctly.
$script:UntisModuleVersion = '0.1.0'
$script:UntisConnection = $null
$script:UntisCache = @{}
$script:UntisHttpClient = $null
$script:UntisThrottle = @{ NotBefore = [datetime]::MinValue; LastRequest = [datetime]::MinValue }

$sourceFiles = @(
    'Common', 'Configuration', 'Cache', 'ApiClient', 'Authentication', 'MasterData', 'Normalization',
    'Timetable', 'Lessons', 'Changes', 'Exams', 'Absences', 'Resources', 'Formatting', 'Diagnostics'
)
foreach ($sourceFile in $sourceFiles) {
    . (Join-Path (Join-Path $PSScriptRoot 'src') "$sourceFile.ps1")
}

New-Alias -Name 'Get-UntisChange' -Value 'Get-UntisChanges' -Force

$ExecutionContext.SessionState.Module.OnRemove = {
    try { Disconnect-Untis -ErrorAction SilentlyContinue } catch { Write-Verbose 'Logout during module removal failed.' }
    if ($script:UntisHttpClient) { $script:UntisHttpClient.Dispose() }
}

$manifest = Join-Path $PSScriptRoot 'UntisPS.psd1'
$publicFunctions = (Import-PowerShellDataFile -LiteralPath $manifest).FunctionsToExport
Export-ModuleMember -Function $publicFunctions -Alias 'Get-UntisChange'
