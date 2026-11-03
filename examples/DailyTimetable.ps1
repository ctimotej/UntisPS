<#
.SYNOPSIS
    Shows today's timetable, and what comes next.
.EXAMPLE
    ./DailyTimetable.ps1 -Server example.webuntis.com -School ExampleSchool
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$School
)
Import-Module (Join-Path $PSScriptRoot '../UntisPS.psd1')

$connection = @{}
if ($Server) { $connection['Server'] = $Server }
if ($School) { $connection['School'] = $School }
Connect-Untis @connection
try {
    Get-UntisTimetable -Today | Format-UntisTimetable

    $next = Get-UntisNextLesson
    if ($next) {
        ''
        'Next: {0} in {1} at {2:HH:mm}' -f $next.Subject, $next.Room, $next.StartTime
    }
} finally {
    Disconnect-Untis
}
