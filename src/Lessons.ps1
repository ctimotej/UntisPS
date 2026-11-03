# Lesson-level views built on timetable entries. WebUntis has no separate lesson list for normal
# accounts, so a lesson here is the set of periods that share a lesson number.

function Get-UntisLesson {
    <#
    .SYNOPSIS
        Groups timetable periods into lessons, or shows the details of one period.
    .DESCRIPTION
        Each result is one lesson with its period count, cancellations and next occurrence. The
        individual periods with their full details are in the Periods property. With -Id, the matching
        period is returned directly.
    .PARAMETER Week
        Current week. This is the default range.
    .PARAMETER WeekOffset
        Weeks to shift -Week by.
    .PARAMETER Date
        A single date.
    .PARAMETER FromDate
        First date of a range.
    .PARAMETER ToDate
        Last date of a range.
    .PARAMETER Id
        Period id from a timetable entry.
    .PARAMETER Class
        Class name, long name or id.
    .PARAMETER Teacher
        Teacher name, long name or id.
    .PARAMETER Student
        Student name or id.
    .PARAMETER Subject
        Filters by subject. Wildcards are allowed.
    .PARAMETER Room
        Room name, long name or id.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisLesson
    .EXAMPLE
        (Get-UntisLesson -Subject MA).Periods
    .EXAMPLE
        Get-UntisLesson -Id 1001 -Date 2026-11-04 | Format-List *
    .OUTPUTS
        UntisPS.Lesson
    #>
    [CmdletBinding(DefaultParameterSetName = 'Week')]
    [OutputType('UntisPS.Lesson', 'UntisPS.TimetableEntry')]
    param(
        [Parameter(ParameterSetName = 'Week')][switch]$Week,
        [Parameter(ParameterSetName = 'Week')][int]$WeekOffset = 0,
        [Parameter(ParameterSetName = 'Date', Mandatory)][datetime]$Date,
        [Parameter(ParameterSetName = 'Range', Mandatory)][datetime]$FromDate,
        [Parameter(ParameterSetName = 'Range', Mandatory)][datetime]$ToDate,
        [long]$Id,
        [string]$Class,
        [string]$Teacher,
        [string]$Student,
        [string]$Subject,
        [string]$Room,
        [switch]$Force
    )
    try {
        $rangeParameters = @{ Default = 'Week' }
        foreach ($name in @('WeekOffset', 'Date', 'FromDate', 'ToDate')) {
            if ($PSBoundParameters.ContainsKey($name)) { $rangeParameters[$name] = $PSBoundParameters[$name] }
        }
        $range = Resolve-UntisDateRange @rangeParameters
        $entries = @(Get-UntisEntrySet -Start $range.Start -End $range.End -Class $Class -Teacher $Teacher -Student $Student `
                -Subject $Subject -Room $Room -Force:$Force)

        if ($PSBoundParameters.ContainsKey('Id')) {
            $match = @($entries | Where-Object { $_.Id -eq $Id })
            if ($match.Count -eq 0) {
                throw (New-UntisErrorRecord -Kind 'NotFound' -Category ObjectNotFound -Target $Id -Message "No period with id $Id in $($range.Start.ToString('yyyy-MM-dd')) to $($range.End.ToString('yyyy-MM-dd')).")
            }
            return $match
        }

        $now = Get-UntisNow
        $groups = $entries | Group-Object -Property {
            if ($_.LessonNumber) { "n$($_.LessonNumber)" } else { "$($_.Subject)|$($_.Teacher)|$($_.Class)" }
        }
        $lessons = foreach ($group in $groups) {
            $periods = @($group.Group | Sort-Object StartTime)
            $upcoming = @($periods | Where-Object { $_.StartTime -gt $now -and -not $_.IsCancelled })
            $first = $periods[0]
            [pscustomobject]@{
                PSTypeName     = 'UntisPS.Lesson'
                LessonNumber   = $first.LessonNumber
                Subject        = $first.Subject
                Teacher        = (@($periods.Teacher | Where-Object { $_ } | Select-Object -Unique) -join ', ')
                Class          = $first.Class
                LessonType     = $first.LessonType
                LessonText     = $first.LessonText
                PeriodCount    = $periods.Count
                CancelledCount = @($periods | Where-Object { $_.IsCancelled }).Count
                FirstPeriod    = $first.StartTime
                LastPeriod     = $periods[-1].StartTime
                NextPeriod     = if ($upcoming.Count) { $upcoming[0].StartTime } else { $null }
                Periods        = $periods
            }
        }
        $lessons | Sort-Object -Property Subject, Class
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-UntisNextLesson {
    <#
    .SYNOPSIS
        Gets the next lesson that has not started yet.
    .DESCRIPTION
        Looks ahead one week at a time. A date the server does not allow, such as the end of the school
        year, ends the search without an error. Times are compared with this computer's clock, so run
        it in the time zone of the school.
    .PARAMETER Count
        Number of lessons to return.
    .PARAMETER LookAheadDays
        How many days to search, from today.
    .PARAMETER IncludeCurrent
        Also returns a lesson that is in progress.
    .PARAMETER IncludeCancelled
        Also returns cancelled lessons.
    .PARAMETER Class
        Class name, long name or id.
    .PARAMETER Teacher
        Teacher name, long name or id.
    .PARAMETER Student
        Student name or id.
    .PARAMETER Subject
        Filters by subject. Wildcards are allowed.
    .PARAMETER Room
        Room name, long name or id.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisNextLesson
    .EXAMPLE
        Get-UntisNextLesson -Count 3 -Subject MA
    .OUTPUTS
        UntisPS.TimetableEntry, with an added StartsIn time span.
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.TimetableEntry')]
    param(
        [ValidateRange(1, 100)][int]$Count = 1,
        [ValidateRange(1, 366)][int]$LookAheadDays = 21,
        [switch]$IncludeCurrent,
        [switch]$IncludeCancelled,
        [string]$Class,
        [string]$Teacher,
        [string]$Student,
        [string]$Subject,
        [string]$Room,
        [switch]$Force
    )
    try {
        $now = Get-UntisNow
        $found = New-Object System.Collections.Generic.List[object]
        $lastDay = $now.Date.AddDays($LookAheadDays)
        $start = $now.Date
        while ($start -le $lastDay -and $found.Count -lt $Count) {
            $end = $start.AddDays(6)
            if ($end -gt $lastDay) { $end = $lastDay }
            try {
                $entries = @(Get-UntisEntrySet -Start $start -End $end -Class $Class -Teacher $Teacher -Student $Student `
                        -Subject $Subject -Room $Room -Force:$Force)
            } catch {
                if ((Get-UntisErrorKind $_) -ne 'DateNotAllowed') { throw }
                Write-Verbose "Stopping at $($start.ToString('yyyy-MM-dd')): the server does not allow later dates."
                break
            }
            foreach ($entry in $entries) {
                if ($found.Count -ge $Count) { break }
                if ($entry.IsCancelled -and -not $IncludeCancelled) { continue }
                $isUpcoming = $entry.StartTime -gt $now
                $isCurrent = $IncludeCurrent -and ($entry.StartTime -le $now) -and ($entry.EndTime -gt $now)
                if ($isUpcoming -or $isCurrent) { $found.Add($entry) }
            }
            $start = $end.AddDays(1)
        }
        foreach ($entry in $found) {
            $entry | Add-Member -NotePropertyName 'StartsIn' -NotePropertyValue ($entry.StartTime - $now) -Force -PassThru
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
