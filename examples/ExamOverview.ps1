<#
.SYNOPSIS
    Lists upcoming exams with the days left until each.
.PARAMETER Days
    How far ahead to look.
.EXAMPLE
    ./ExamOverview.ps1 -Days 60
#>
[CmdletBinding()]
param([ValidateRange(1, 366)][int]$Days = 30)
Import-Module (Join-Path $PSScriptRoot '../UntisPS.psd1')

Connect-Untis
try {
    $today = (Get-Date).Date
    $exams = @(Get-UntisExam -FromDate $today -ToDate $today.AddDays($Days))
    if ($exams.Count -eq 0) {
        "No exams in the next $Days days."
        return
    }
    $exams |
        Select-Object @{ Name = 'In days'; Expression = { ($_.Date - $today).Days } }, Date, Subject, ExamType, Name, Room |
        Format-Table -AutoSize
} finally {
    Disconnect-Untis
}
