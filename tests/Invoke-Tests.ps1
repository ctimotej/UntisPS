<#
.SYNOPSIS
    Runs the Pester suite. Needs Pester 5.3 or later. Uses no network and no credentials.
#>
[CmdletBinding()]
param([ValidateSet('None', 'Normal', 'Detailed')][string]$Output = 'Normal')
Import-Module Pester -MinimumVersion 5.3 -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = $Output
Invoke-Pester -Configuration $configuration
