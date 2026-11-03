<#
.SYNOPSIS
    Prints a week grid and lists this week's changes.
.PARAMETER WeekOffset
    0 is this week, 1 is next week.
.PARAMETER Class
    Shows this class instead of your own timetable.
.PARAMETER CsvPath
    Also exports the week to this file.
.EXAMPLE
    ./WeeklyTimetable.ps1 -WeekOffset 1 -CsvPath ./week.csv
#>
[CmdletBinding()]
param(
    [int]$WeekOffset = 0,
    [string]$Class,
    [string]$CsvPath
)
Import-Module (Join-Path $PSScriptRoot '../UntisPS.psd1')

Connect-Untis
try {
    $selection = @{}
    if ($Class) { $selection['Class'] = $Class }
    $entries = @(Get-UntisTimetable -Week -WeekOffset $WeekOffset @selection)
    if ($entries.Count -eq 0) {
        'No lessons found.'
        return
    }
    $entries | Format-UntisTimetable -View Week

    $changed = @($entries | Where-Object Status -ne 'Normal')
    if ($changed.Count -gt 0) {
        ''
        'Changes:'
        $changed | Format-Table StartTime, Subject, Status, OriginalTeacher, Teacher, OriginalRoom, Room -AutoSize
    }
    if ($CsvPath) {
        $entries |
            Select-Object Date, StartTime, EndTime, Subject, Teacher, Room, Class, LessonType, Status |
            Export-Csv -LiteralPath $CsvPath -NoTypeInformation
    }
} finally {
    Disconnect-Untis
}
