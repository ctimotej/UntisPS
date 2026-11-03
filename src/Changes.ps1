# Timetable changes come from two sources with different scope:
#   Timetable      own or selected timetable; needs no extra right; only sees entries it can read.
#   Substitutions  getSubstitutions; school-wide; often refused for student accounts.

function Get-UntisChanges {
    <#
    .SYNOPSIS
        Gets cancellations, substitutions, room changes and other timetable changes.
    .DESCRIPTION
        By default the changes are read from your own timetable or the one you select, which works for
        most accounts. Use -Source Substitutions for the school-wide list, if the school allows it;
        only that source reports additional and shifted lessons and the new date of a rescheduled one.
    .PARAMETER Today
        Only today.
    .PARAMETER Tomorrow
        Only tomorrow.
    .PARAMETER Week
        Monday to Sunday of the current week.
    .PARAMETER WeekOffset
        Weeks to shift -Week by.
    .PARAMETER Date
        A single date.
    .PARAMETER FromDate
        First date of a range.
    .PARAMETER ToDate
        Last date of a range.
    .PARAMETER Source
        Auto uses the timetable when there is one to read, otherwise the substitution list.
    .PARAMETER Class
        Class name, long name or id.
    .PARAMETER Teacher
        Teacher name, long name or id.
    .PARAMETER Subject
        Filters by subject. Wildcards are allowed.
    .PARAMETER Room
        Room name, long name or id.
    .PARAMETER ChangeType
        Only returns changes of these types.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisChanges -Today
    .EXAMPLE
        Get-UntisChanges -Week -ChangeType Cancellation
    .EXAMPLE
        Get-UntisChanges -Source Substitutions -Today -Class 5a
    .OUTPUTS
        UntisPS.Change
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType('UntisPS.Change')]
    param(
        [Parameter(ParameterSetName = 'Today', Mandatory)][switch]$Today,
        [Parameter(ParameterSetName = 'Tomorrow', Mandatory)][switch]$Tomorrow,
        [Parameter(ParameterSetName = 'Week', Mandatory)][switch]$Week,
        [Parameter(ParameterSetName = 'Week')][int]$WeekOffset = 0,
        [Parameter(ParameterSetName = 'Date', Mandatory)][datetime]$Date,
        [Parameter(ParameterSetName = 'Range', Mandatory)][datetime]$FromDate,
        [Parameter(ParameterSetName = 'Range', Mandatory)][datetime]$ToDate,
        [ValidateSet('Auto', 'Timetable', 'Substitutions')][string]$Source = 'Auto',
        [string]$Class,
        [string]$Teacher,
        [string]$Subject,
        [string]$Room,
        [string[]]$ChangeType,
        [switch]$Force
    )
    try {
        $connection = Get-UntisActiveConnection
        $rangeParameters = @{ Default = 'Week' }
        foreach ($name in @('Today', 'Tomorrow', 'Week', 'WeekOffset', 'Date', 'FromDate', 'ToDate')) {
            if ($PSBoundParameters.ContainsKey($name)) { $rangeParameters[$name] = $PSBoundParameters[$name] }
        }
        $range = Resolve-UntisDateRange @rangeParameters

        $useSubstitutions = $Source -eq 'Substitutions'
        if ($Source -eq 'Auto') {
            $hasSelector = $Class -or $Teacher -or $Room
            $useSubstitutions = -not $hasSelector -and -not (Get-UntisOwnElement -Connection $connection)
        }

        if ($useSubstitutions) {
            $params = @{
                startDate    = ConvertTo-UntisDateNumber -Date $range.Start
                endDate      = ConvertTo-UntisDateNumber -Date $range.End
                departmentId = 0
            }
            $rows = Invoke-UntisRpc -Method 'getSubstitutions' -Params $params -CacheSeconds ([int]$connection.Settings['CacheSeconds']) -Force:$Force
            $lookup = @{}
            $nameStyle = [string]$connection.Settings['NameStyle']
            $changes = foreach ($row in $rows) {
                $change = ConvertTo-UntisSubstitutionChange -Raw $row -Lookup $lookup -NameStyle $nameStyle
                $keep = (-not $Class -or $change.Class -like "*$Class*") -and
                (-not $Teacher -or $change.Teacher -like "*$Teacher*" -or $change.OriginalTeacher -like "*$Teacher*") -and
                (-not $Subject -or $change.Subject -like "*$Subject*") -and
                (-not $Room -or $change.Room -like "*$Room*" -or $change.OriginalRoom -like "*$Room*")
                if ($keep) { $change }
            }
        } else {
            $entries = Get-UntisEntrySet -Start $range.Start -End $range.End -Class $Class -Teacher $Teacher -Subject $Subject -Room $Room -Force:$Force
            $changes = foreach ($entry in $entries) {
                if ($entry.Status -ne 'Normal') { ConvertTo-UntisTimetableChange -Entry $entry }
            }
        }
        if ($ChangeType) { $changes = $changes | Where-Object { $_.ChangeType -in $ChangeType } }
        $changes | Sort-Object -Property StartTime, Class
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
