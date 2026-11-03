# Timetable retrieval. Other commands build on Get-UntisEntrySet.

function Get-UntisOwnElement {
    <# The element of the logged-in person, or nothing for shared and parent accounts. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][pscustomobject]$Connection)
    if ($Connection.PersonId -gt 0 -and $Connection.PersonType -in @(2, 5)) {
        return @{ Id = $Connection.PersonId; Type = $Connection.PersonType; Label = 'own' }
    }
    if ($Connection.ClassId -gt 0) { return @{ Id = $Connection.ClassId; Type = 1; Label = 'own class' } }
}

function Invoke-UntisTimetableRequest {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Element,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End,
        [switch]$Force
    )
    $connection = Get-UntisActiveConnection
    $fields = @('id', 'name', 'longname', 'externalkey')
    $options = @{
        element       = @{ id = $Element.Id; type = $Element.Type }
        startDate     = ConvertTo-UntisDateNumber -Date $Start
        endDate       = ConvertTo-UntisDateNumber -Date $End
        showLsText    = $true
        showStudentgroup = $true
        showLsNumber  = $true
        showSubstText = $true
        showInfo      = $true
        showBooking   = $true
        klasseFields  = $fields
        roomFields    = $fields
        subjectFields = $fields
        teacherFields = $fields
    }
    $result = Invoke-UntisRpc -Method 'getTimetable' -Params @{ options = $options } -CacheSeconds ([int]$connection.Settings['CacheSeconds']) -Force:$Force
    , @($result)
}

function Test-UntisEntryNameMatch {
    <# Wildcard match against short and long names, so -Teacher Smith finds SMI / Smith. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][object[]]$Elements,
        [Parameter(Mandatory)][string]$Pattern
    )
    foreach ($element in $Elements) {
        foreach ($candidate in @($element.Name, $element.LongName, $element.Display, [string]$element.Id)) {
            if ($candidate -and $candidate -like $Pattern) { return $true }
        }
    }
    $false
}

function Test-UntisEntryFilter {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][hashtable]$Filters
    )
    if ($Filters['Class'] -and -not (Test-UntisEntryNameMatch -Elements $Entry.Classes -Pattern $Filters['Class'])) { return $false }
    if ($Filters['Teacher'] -and -not (Test-UntisEntryNameMatch -Elements $Entry.Teachers -Pattern $Filters['Teacher'])) { return $false }
    if ($Filters['Subject'] -and -not (Test-UntisEntryNameMatch -Elements $Entry.Subjects -Pattern $Filters['Subject'])) { return $false }
    if ($Filters['Room'] -and -not (Test-UntisEntryNameMatch -Elements $Entry.Rooms -Pattern $Filters['Room'])) { return $false }
    $true
}

function Get-UntisEntrySet {
    <#
    Shared query logic. WebUntis returns one element's timetable per request, so the first of
    Student, Class, Teacher, Room becomes the request element and the rest filter the result.
    -Subject filters the person's own timetable; a school-wide subject timetable is only requested
    when the account has no own timetable.
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.TimetableEntry')]
    param(
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End,
        [string]$Class,
        [string]$Teacher,
        [string]$Student,
        [string]$Subject,
        [string]$Room,
        [object]$Element,
        [switch]$Force
    )
    $connection = Get-UntisActiveConnection
    $filters = @{ Class = $Class; Teacher = $Teacher; Subject = $Subject; Room = $Room }
    $target = $null

    if ($Element) {
        $type = [string]$Element.ElementType
        if (-not $script:UntisElementTypes.ContainsKey($type) -or -not $Element.Id) {
            throw (New-UntisErrorRecord -Kind 'Argument' -Category InvalidArgument -Message 'Pipeline input must come from Get-UntisClass, Get-UntisTeacher, Get-UntisRoom, Get-UntisSubject or Get-UntisStudent.')
        }
        $target = @{ Id = [int]$Element.Id; Type = $script:UntisElementTypes[$type].Code; Label = [string]$Element.Name }
    }
    if (-not $target) {
        foreach ($selector in @('Student', 'Class', 'Teacher', 'Room')) {
            $value = Get-Variable -Name $selector -ValueOnly
            if (-not $value) { continue }
            try {
                $target = Resolve-UntisElement -Type $selector -Value $value
                if ($selector -ne 'Student') { $filters[$selector] = $null }
                break
            } catch {
                # Students often cannot read teacher or room lists. Their own timetable can still be filtered.
                $canFilterOwn = ((Get-UntisErrorKind $_) -eq 'NoRight') -and ($selector -ne 'Student') -and (Get-UntisOwnElement -Connection $connection)
                if (-not $canFilterOwn) { throw }
                Write-Warning "This account cannot look up $($selector.ToLowerInvariant()) names, so '$value' only filters your own timetable."
            }
        }
    }
    $isOwnElement = $false
    if (-not $target) {
        $target = Get-UntisOwnElement -Connection $connection
        $isOwnElement = [bool]$target
    }
    if (-not $target -and $Subject) {
        $target = Resolve-UntisElement -Type 'Subject' -Value $Subject
        $filters['Subject'] = $null
    }
    if (-not $target) {
        throw (New-UntisErrorRecord -Kind 'Argument' -Category InvalidArgument `
                -Message 'This account has no personal timetable. Choose one with -Class, -Teacher, -Room or -Student.')
    }

    try {
        $rawEntries = Invoke-UntisTimetableRequest -Element $target -Start $Start -End $End -Force:$Force
    } catch {
        # Shared class accounts are refused their personal timetable but can read the class one.
        $useClass = ((Get-UntisErrorKind $_) -eq 'NoRight') -and $isOwnElement -and ($target.Type -ne 1) -and ($connection.ClassId -gt 0)
        if (-not $useClass) { throw }
        Write-Warning 'No right to read a personal timetable; showing the timetable of your class instead.'
        $rawEntries = Invoke-UntisTimetableRequest -Element @{ Id = $connection.ClassId; Type = 1; Label = 'own class' } -Start $Start -End $End -Force:$Force
    }

    $lookup = @{}
    $nameStyle = [string]$connection.Settings['NameStyle']
    $entries = foreach ($raw in $rawEntries) {
        $entry = ConvertTo-UntisTimetableEntry -Raw $raw -Lookup $lookup -NameStyle $nameStyle
        if (Test-UntisEntryFilter -Entry $entry -Filters $filters) { $entry }
    }
    $entries | Sort-Object -Property StartTime, Subject
}

function Get-UntisTimetable {
    <#
    .SYNOPSIS
        Gets timetable entries for a day, a week or a date range.
    .DESCRIPTION
        Without a selector this returns the timetable of the logged-in person. Without a date
        parameter it uses the configured DefaultRange. Each result is one period, with DateTime
        values, so output can be sorted, filtered and piped.
    .PARAMETER Today
        Only today.
    .PARAMETER Tomorrow
        Only tomorrow.
    .PARAMETER Week
        Monday to Sunday of the current week.
    .PARAMETER WeekOffset
        Weeks to shift -Week by. 1 is next week.
    .PARAMETER Date
        A single date.
    .PARAMETER FromDate
        First date of a range.
    .PARAMETER ToDate
        Last date of a range.
    .PARAMETER Class
        Class name, long name or id.
    .PARAMETER Teacher
        Teacher name, long name or id.
    .PARAMETER Student
        Student name or id. Usually needs extra rights.
    .PARAMETER Subject
        Filters by subject. Wildcards are allowed.
    .PARAMETER Room
        Room name, long name or id.
    .PARAMETER InputObject
        An object from Get-UntisClass, Get-UntisTeacher, Get-UntisRoom, Get-UntisSubject or Get-UntisStudent.
    .PARAMETER ExcludeCancelled
        Leaves out cancelled lessons.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisTimetable -Today
    .EXAMPLE
        Get-UntisTimetable -Date 2026-11-04 -Class 5a
    .EXAMPLE
        Get-UntisTimetable -FromDate 2026-11-03 -ToDate 2026-11-07 -Subject MA
    .EXAMPLE
        Get-UntisRoom A101 | Get-UntisTimetable -Week
    .EXAMPLE
        Get-UntisTimetable -Week | Format-UntisTimetable -View Week
    .OUTPUTS
        UntisPS.TimetableEntry
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType('UntisPS.TimetableEntry')]
    param(
        [Parameter(ParameterSetName = 'Today', Mandatory)][switch]$Today,
        [Parameter(ParameterSetName = 'Tomorrow', Mandatory)][switch]$Tomorrow,
        [Parameter(ParameterSetName = 'Week', Mandatory)][switch]$Week,
        [Parameter(ParameterSetName = 'Week')][int]$WeekOffset = 0,
        [Parameter(ParameterSetName = 'Date', Mandatory, Position = 0)][datetime]$Date,
        [Parameter(ParameterSetName = 'Range', Mandatory)][datetime]$FromDate,
        [Parameter(ParameterSetName = 'Range', Mandatory)][datetime]$ToDate,
        [string]$Class,
        [string]$Teacher,
        [string]$Student,
        [string]$Subject,
        [string]$Room,
        [Parameter(ValueFromPipeline)][psobject]$InputObject,
        [switch]$ExcludeCancelled,
        [switch]$Force
    )
    process {
        try {
            $connection = Get-UntisActiveConnection
            $rangeParameters = @{ Default = [string]$connection.Settings['DefaultRange'] }
            foreach ($name in @('Today', 'Tomorrow', 'Week', 'WeekOffset', 'Date', 'FromDate', 'ToDate')) {
                if ($PSBoundParameters.ContainsKey($name)) { $rangeParameters[$name] = $PSBoundParameters[$name] }
            }
            $range = Resolve-UntisDateRange @rangeParameters
            $entries = Get-UntisEntrySet -Start $range.Start -End $range.End -Class $Class -Teacher $Teacher -Student $Student `
                -Subject $Subject -Room $Room -Element $InputObject -Force:$Force
            $hide = $ExcludeCancelled -or [bool]$connection.Settings['HideCancelled']
            foreach ($entry in $entries) {
                if (-not ($hide -and $entry.IsCancelled)) { $entry }
            }
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}
