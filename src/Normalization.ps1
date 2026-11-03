# Converts raw API payloads into stable objects with real DateTime values.

$script:UntisLessonTypes = @{
    ls = 'Lesson'
    oh = 'OfficeHour'
    sb = 'Standby'
    bs = 'BreakSupervision'
    ex = 'Exam'
}

$script:UntisSubstitutionTypes = @{
    cancel = 'Cancellation'
    subst  = 'Substitution'
    add    = 'Additional'
    shift  = 'Shifted'
    rmchg  = 'RoomChange'
}

function ConvertTo-UntisElementList {
    <# Normalizes the kl/te/su/ro arrays. orgid/orgname mark the element that was originally planned. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()][object[]]$Items,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$NameStyle
    )
    foreach ($item in $Items) {
        $short = $item.name
        $long = $item.longname
        if (-not $short -and $item.id) {
            $known = Get-UntisLookupItem -Lookup $Lookup -Type $Type -Id $item.id
            if ($known) { $short = $known.name; $long = $known.longName }
        }
        $display = Get-UntisElementDisplayName -ShortName $short -LongName $long -NameStyle $NameStyle
        if (-not $display -and $item.id) { $display = "#$($item.id)" }

        $original = $null
        if ($item.orgname -or $item.orgid) {
            $originalShort = $item.orgname
            $originalLong = $item.orglongname
            if (-not $originalShort -and $item.orgid) {
                $known = Get-UntisLookupItem -Lookup $Lookup -Type $Type -Id $item.orgid
                if ($known) { $originalShort = $known.name; $originalLong = $known.longName }
            }
            $original = Get-UntisElementDisplayName -ShortName $originalShort -LongName $originalLong -NameStyle $NameStyle
            if (-not $original -and $item.orgid) { $original = "#$($item.orgid)" }
        }
        [pscustomobject]@{
            Id       = $item.id
            Name     = $short
            LongName = $long
            Display  = $display
            Original = $original
        }
    }
}

function Join-UntisDisplay {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object[]]$Elements)
    (@($Elements | ForEach-Object { $_.Display } | Where-Object { $_ }) -join ', ')
}

function Join-UntisOriginal {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object[]]$Elements)
    $names = @($Elements | ForEach-Object { $_.Original } | Where-Object { $_ })
    if ($names.Count -eq 0) { return $null }
    $names -join ', '
}

function Get-UntisEntryStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$Code,
        [AllowNull()][string]$OriginalTeacher,
        [AllowNull()][string]$OriginalRoom
    )
    if ($Code -eq 'cancelled') { return 'Cancelled' }
    if ($OriginalTeacher) { return 'Substitution' }
    if ($OriginalRoom) { return 'RoomChange' }
    if ($Code -eq 'irregular') { return 'Irregular' }
    'Normal'
}

function ConvertTo-UntisTimetableEntry {
    [CmdletBinding()]
    [OutputType('UntisPS.TimetableEntry')]
    param(
        [Parameter(Mandatory)][object]$Raw,
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$NameStyle
    )
    $date = ConvertFrom-UntisDate -Value $Raw.date
    $common = @{ Lookup = $Lookup; NameStyle = $NameStyle }
    $classes = @(ConvertTo-UntisElementList -Items $Raw.kl -Type 'Class' @common)
    $teachers = @(ConvertTo-UntisElementList -Items $Raw.te -Type 'Teacher' @common)
    $subjects = @(ConvertTo-UntisElementList -Items $Raw.su -Type 'Subject' @common)
    $rooms = @(ConvertTo-UntisElementList -Items $Raw.ro -Type 'Room' @common)

    $originalTeacher = Join-UntisOriginal -Elements $teachers
    $originalRoom = Join-UntisOriginal -Elements $rooms
    $status = Get-UntisEntryStatus -Code $Raw.code -OriginalTeacher $originalTeacher -OriginalRoom $originalRoom
    $lessonCode = if ($Raw.lstype) { [string]$Raw.lstype } else { 'ls' }
    $lessonType = $script:UntisLessonTypes[$lessonCode]
    if (-not $lessonType) { $lessonType = $lessonCode }

    [pscustomobject]@{
        PSTypeName       = 'UntisPS.TimetableEntry'
        Id               = $Raw.id
        Date             = $date
        StartTime        = ConvertFrom-UntisTime -Date $date -Time $Raw.startTime
        EndTime          = ConvertFrom-UntisTime -Date $date -Time $Raw.endTime
        Subject          = Join-UntisDisplay -Elements $subjects
        Teacher          = Join-UntisDisplay -Elements $teachers
        Room             = Join-UntisDisplay -Elements $rooms
        Class            = Join-UntisDisplay -Elements $classes
        LessonType       = $lessonType
        Status           = $status
        IsCancelled      = ($status -eq 'Cancelled')
        OriginalRoom     = $originalRoom
        OriginalTeacher  = $originalTeacher
        OriginalSubject  = Join-UntisOriginal -Elements $subjects
        LessonNumber     = $Raw.lsnumber
        ActivityType     = $Raw.activityType
        LessonText       = $Raw.lstext
        Info             = $Raw.info
        SubstitutionText = $Raw.substText
        StudentGroup     = $Raw.sg
        Subjects         = $subjects
        Teachers         = $teachers
        Rooms            = $rooms
        Classes          = $classes
    }
}

function ConvertTo-UntisResource {
    [CmdletBinding()]
    [OutputType('UntisPS.Resource')]
    param(
        [Parameter(Mandatory)][object]$Raw,
        [Parameter(Mandatory)][ValidateSet('Class', 'Teacher', 'Subject', 'Room', 'Student')][string]$Type
    )
    $output = [ordered]@{
        Id          = $Raw.id
        ElementType = $Type
        Name        = $Raw.name
        LongName    = $Raw.longName
    }
    switch ($Type) {
        'Teacher' { $output['ForeName'] = $Raw.foreName; $output['Title'] = $Raw.title }
        'Student' { $output['ForeName'] = $Raw.foreName }
        'Room' { $output['Building'] = $Raw.building }
    }
    if ($null -ne $Raw.active) { $output['IsActive'] = [bool]$Raw.active }
    else { $output['IsActive'] = $null }
    $object = [pscustomobject]$output
    $object.PSObject.TypeNames.Insert(0, 'UntisPS.Resource')
    $object.PSObject.TypeNames.Insert(0, "UntisPS.$Type")
    $object
}

function ConvertTo-UntisSubstitutionChange {
    <# Normalizes one getSubstitutions row. #>
    [CmdletBinding()]
    [OutputType('UntisPS.Change')]
    param(
        [Parameter(Mandatory)][object]$Raw,
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$NameStyle
    )
    $date = ConvertFrom-UntisDate -Value $Raw.date
    $common = @{ Lookup = $Lookup; NameStyle = $NameStyle }
    $classes = @(ConvertTo-UntisElementList -Items $Raw.kl -Type 'Class' @common)
    $teachers = @(ConvertTo-UntisElementList -Items $Raw.te -Type 'Teacher' @common)
    $subjects = @(ConvertTo-UntisElementList -Items $Raw.su -Type 'Subject' @common)
    $rooms = @(ConvertTo-UntisElementList -Items $Raw.ro -Type 'Room' @common)
    $changeType = $script:UntisSubstitutionTypes[[string]$Raw.type]
    if (-not $changeType) { $changeType = [string]$Raw.type }

    $rescheduledStart = $null
    $rescheduledEnd = $null
    if ($Raw.reschedule -and $Raw.reschedule.date) {
        $newDate = ConvertFrom-UntisDate -Value $Raw.reschedule.date
        $rescheduledStart = ConvertFrom-UntisTime -Date $newDate -Time $Raw.reschedule.startTime
        $rescheduledEnd = ConvertFrom-UntisTime -Date $newDate -Time $Raw.reschedule.endTime
    }
    [pscustomobject]@{
        PSTypeName       = 'UntisPS.Change'
        Date             = $date
        StartTime        = ConvertFrom-UntisTime -Date $date -Time $Raw.startTime
        EndTime          = ConvertFrom-UntisTime -Date $date -Time $Raw.endTime
        ChangeType       = $changeType
        IsCancelled      = ($changeType -eq 'Cancellation')
        Subject          = Join-UntisDisplay -Elements $subjects
        Teacher          = Join-UntisDisplay -Elements $teachers
        OriginalTeacher  = Join-UntisOriginal -Elements $teachers
        Room             = Join-UntisDisplay -Elements $rooms
        OriginalRoom     = Join-UntisOriginal -Elements $rooms
        Class            = Join-UntisDisplay -Elements $classes
        Text             = $Raw.txt
        RescheduledStart = $rescheduledStart
        RescheduledEnd   = $rescheduledEnd
        Source           = 'Substitutions'
    }
}

function ConvertTo-UntisTimetableChange {
    <# Builds a change record from a timetable entry that differs from the plan. #>
    [CmdletBinding()]
    [OutputType('UntisPS.Change')]
    param([Parameter(Mandatory)][object]$Entry)
    $changeType = switch ($Entry.Status) {
        'Cancelled' { 'Cancellation' }
        default { $Entry.Status }
    }
    $text = $Entry.SubstitutionText
    if (-not $text) { $text = $Entry.Info }
    [pscustomobject]@{
        PSTypeName       = 'UntisPS.Change'
        Date             = $Entry.Date
        StartTime        = $Entry.StartTime
        EndTime          = $Entry.EndTime
        ChangeType       = $changeType
        IsCancelled      = $Entry.IsCancelled
        Subject          = $Entry.Subject
        Teacher          = $Entry.Teacher
        OriginalTeacher  = $Entry.OriginalTeacher
        Room             = $Entry.Room
        OriginalRoom     = $Entry.OriginalRoom
        Class            = $Entry.Class
        Text             = $text
        RescheduledStart = $null
        RescheduledEnd   = $null
        Source           = 'Timetable'
    }
}

function Resolve-UntisIdNames {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object[]]$Ids,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$NameStyle
    )
    $names = foreach ($id in $Ids) {
        $known = Get-UntisLookupItem -Lookup $Lookup -Type $Type -Id $id
        $display = $null
        if ($known) { $display = Get-UntisElementDisplayName -ShortName $known.name -LongName $known.longName -NameStyle $NameStyle }
        if ($display) { $display } else { "#$id" }
    }
    @($names) -join ', '
}

function ConvertTo-UntisRpcExam {
    <# Normalizes a getExams row, whose references are numeric ids. #>
    [CmdletBinding()]
    [OutputType('UntisPS.Exam')]
    param(
        [Parameter(Mandatory)][object]$Raw,
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$NameStyle
    )
    $date = ConvertFrom-UntisDate -Value $Raw.date
    $common = @{ Lookup = $Lookup; NameStyle = $NameStyle }
    $subject = $null
    if ($Raw.subject) { $subject = Resolve-UntisIdNames -Ids @($Raw.subject) -Type 'Subject' @common }
    [pscustomobject]@{
        PSTypeName = 'UntisPS.Exam'
        Id         = $Raw.id
        Date       = $date
        StartTime  = ConvertFrom-UntisTime -Date $date -Time $Raw.startTime
        EndTime    = ConvertFrom-UntisTime -Date $date -Time $Raw.endTime
        Subject    = $subject
        ExamType   = $null
        Name       = $null
        Text       = $null
        Teacher    = Resolve-UntisIdNames -Ids @($Raw.teachers) -Type 'Teacher' @common
        Room       = $null
        Class      = Resolve-UntisIdNames -Ids @($Raw.classes) -Type 'Class' @common
        Source     = 'JsonRpc'
    }
}

function ConvertTo-UntisWebExam {
    <# Normalizes a row from the web client's /api/exams endpoint, which already carries names. #>
    [CmdletBinding()]
    [OutputType('UntisPS.Exam')]
    param([Parameter(Mandatory)][object]$Raw)
    $date = ConvertFrom-UntisDate -Value $Raw.examDate
    [pscustomobject]@{
        PSTypeName = 'UntisPS.Exam'
        Id         = $Raw.id
        Date       = $date
        StartTime  = ConvertFrom-UntisTime -Date $date -Time $Raw.startTime
        EndTime    = ConvertFrom-UntisTime -Date $date -Time $Raw.endTime
        Subject    = $Raw.subject
        ExamType   = $Raw.examType
        Name       = $Raw.name
        Text       = $Raw.text
        Teacher    = (@($Raw.teachers) -join ', ')
        Room       = (@($Raw.rooms) -join ', ')
        Class      = (@($Raw.studentClass) -join ', ')
        Source     = 'WebApi'
    }
}

function ConvertTo-UntisRpcAbsence {
    <# Normalizes a periodsWithAbsences row from getTimetableWithAbsences. #>
    [CmdletBinding()]
    [OutputType('UntisPS.Absence')]
    param(
        [Parameter(Mandatory)][object]$Raw,
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$NameStyle
    )
    $date = ConvertFrom-UntisDate -Value $Raw.date
    $subject = $null
    if ($Raw.subjectId) { $subject = Resolve-UntisIdNames -Ids @($Raw.subjectId) -Type 'Subject' -Lookup $Lookup -NameStyle $NameStyle }
    [pscustomobject]@{
        PSTypeName   = 'UntisPS.Absence'
        Id           = $Raw.id
        Student      = $Raw.studentId
        StartTime    = ConvertFrom-UntisTime -Date $date -Time $Raw.startTime
        EndTime      = ConvertFrom-UntisTime -Date $date -Time $Raw.endTime
        Subject      = $subject
        Reason       = $Raw.absenceReason
        ExcuseStatus = $Raw.excuseStatus
        IsExcused    = $null
        Text         = $null
        Source       = 'JsonRpc'
    }
}

function ConvertTo-UntisWebAbsence {
    <# Normalizes a row from the web client's absences endpoint. #>
    [CmdletBinding()]
    [OutputType('UntisPS.Absence')]
    param([Parameter(Mandatory)][object]$Raw)
    $startDate = ConvertFrom-UntisDate -Value $Raw.startDate
    $endDate = ConvertFrom-UntisDate -Value $Raw.endDate
    [pscustomobject]@{
        PSTypeName   = 'UntisPS.Absence'
        Id           = $Raw.id
        Student      = $Raw.studentName
        StartTime    = ConvertFrom-UntisTime -Date $startDate -Time $Raw.startTime
        EndTime      = ConvertFrom-UntisTime -Date $endDate -Time $Raw.endTime
        Subject      = $null
        Reason       = $Raw.reason
        ExcuseStatus = $Raw.excuseStatus
        IsExcused    = $Raw.isExcused
        Text         = $Raw.text
        Source       = 'WebApi'
    }
}
