BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../UntisPS.psd1') -Force
    . (Join-Path $PSScriptRoot 'helpers/FakeUntis.ps1')
}

AfterAll { Remove-Module UntisPS -Force -ErrorAction SilentlyContinue }

Describe 'Date handling' {
    BeforeEach { Use-UntisFake }

    It 'converts <value> to a date' -ForEach @(
        @{ value = 20261104 }, @{ value = '20261104' }
    ) {
        InModuleScope UntisPS -Parameters @{ value = $value } {
            ConvertFrom-UntisDate -Value $value | Should -Be ([datetime]'2026-11-04')
        }
    }

    It 'returns nothing for an empty date' {
        InModuleScope UntisPS { ConvertFrom-UntisDate -Value $null | Should -BeNullOrEmpty; ConvertFrom-UntisDate -Value 0 | Should -BeNullOrEmpty }
    }

    It 'reads time <time> as <expected>' -ForEach @(
        @{ time = 745; expected = '07:45' }, @{ time = 1430; expected = '14:30' }, @{ time = 0; expected = '00:00' }, @{ time = '905'; expected = '09:05' }
    ) {
        InModuleScope UntisPS -Parameters @{ time = $time; expected = $expected } {
            (ConvertFrom-UntisTime -Date ([datetime]'2026-11-04') -Time $time).ToString('HH:mm') | Should -Be $expected
        }
    }

    It 'resolves <name>' -ForEach @(
        @{ name = 'Today'; args = @{ Today = $true }; start = '2026-11-04'; end = '2026-11-04' }
        @{ name = 'Tomorrow'; args = @{ Tomorrow = $true }; start = '2026-11-05'; end = '2026-11-05' }
        @{ name = 'Week'; args = @{ Week = $true }; start = '2026-11-02'; end = '2026-11-08' }
        @{ name = 'Next week'; args = @{ Week = $true; WeekOffset = 1 }; start = '2026-11-09'; end = '2026-11-15' }
        @{ name = 'A date'; args = @{ Date = [datetime]'2026-12-01T13:30:00' }; start = '2026-12-01'; end = '2026-12-01' }
        @{ name = 'A range'; args = @{ FromDate = [datetime]'2026-11-03'; ToDate = [datetime]'2026-11-07' }; start = '2026-11-03'; end = '2026-11-07' }
        @{ name = 'The default'; args = @{}; start = '2026-11-04'; end = '2026-11-04' }
    ) {
        $inner = @{ a = $args2 = $_.args; s = $start; e = $end }
        InModuleScope UntisPS -Parameters $inner {
            $range = Resolve-UntisDateRange @a
            $range.Start | Should -Be ([datetime]$s)
            $range.End | Should -Be ([datetime]$e)
        }
    }

    It 'treats Sunday as the end of its week' {
        Mock -ModuleName UntisPS Get-UntisNow { [datetime]'2026-11-08T12:00:00' }
        InModuleScope UntisPS { (Resolve-UntisDateRange -Week).Start | Should -Be ([datetime]'2026-11-02') }
    }

    It 'rejects a reversed range' {
        InModuleScope UntisPS { { Resolve-UntisDateRange -FromDate '2026-11-05' -ToDate '2026-11-01' } | Should -Throw '*later than*' }
    }

    It 'is not affected by the current culture' {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('th-TH')
            InModuleScope UntisPS { ConvertTo-UntisDateNumber -Date ([datetime]::new(2026, 11, 4)) | Should -Be 20261104 }
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
    }
}

Describe 'Get-UntisTimetable' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'requests the own timetable with the documented parameters' {
        Get-UntisTimetable -Today | Out-Null
        $options = (Get-UntisFakeCalls 'getTimetable')[0].Params.options
        $options.element.id | Should -Be 1201
        $options.element.type | Should -Be 5
        $options.startDate | Should -Be 20261104
        $options.endDate | Should -Be 20261104
        $options.teacherFields | Should -Contain 'longname'
        $options.showSubstText | Should -BeTrue
    }

    It 'sends the Monday to Sunday range for -Week' {
        Get-UntisTimetable -Week | Out-Null
        $options = (Get-UntisFakeCalls 'getTimetable')[0].Params.options
        $options.startDate | Should -Be 20261102
        $options.endDate | Should -Be 20261108
    }

    It 'accepts date strings' {
        Get-UntisTimetable -Date '2026-11-04' | Out-Null
        Get-UntisTimetable -FromDate '2026-11-03' -ToDate '2026-11-07' | Out-Null
        (Get-UntisFakeCalls 'getTimetable')[1].Params.options.endDate | Should -Be 20261107
    }

    It 'rejects -Today combined with -Week' {
        { Get-UntisTimetable -Today -Week } | Should -Throw
    }

    It 'returns typed objects with real dates' {
        $entry = (Get-UntisTimetable -Today)[0]
        $entry.PSObject.TypeNames | Should -Contain 'UntisPS.TimetableEntry'
        $entry.Date | Should -BeOfType [datetime]
        $entry.StartTime | Should -Be ([datetime]'2026-11-04T07:45:00')
        $entry.EndTime | Should -Be ([datetime]'2026-11-04T08:30:00')
        $entry.Subject | Should -Be 'MA'
        $entry.Teacher | Should -Be 'MIL'
        $entry.Room | Should -Be 'A101'
        $entry.Class | Should -Be '5a'
        $entry.LessonType | Should -Be 'Lesson'
        $entry.Status | Should -Be 'Normal'
        $entry.IsCancelled | Should -BeFalse
    }

    It 'exposes every field from the specification' {
        $names = (Get-UntisTimetable -Today)[0].PSObject.Properties.Name
        foreach ($name in 'Date', 'StartTime', 'EndTime', 'Subject', 'Teacher', 'Room', 'Class', 'LessonType', 'Status', 'IsCancelled', 'OriginalRoom', 'OriginalTeacher') {
            $names | Should -Contain $name
        }
    }

    It 'sorts by start time' {
        $global:UntisFake.Rpc['getTimetable'] = '[{"id":2,"date":20261104,"startTime":1000,"endTime":1045},{"id":1,"date":20261104,"startTime":800,"endTime":845}]'
        (Get-UntisTimetable -Today).Id | Should -Be @(1, 2)
    }

    It 'returns nothing for an empty day' {
        $global:UntisFake.Rpc['getTimetable'] = '[]'
        Get-UntisTimetable -Today | Should -BeNullOrEmpty
    }

    It 'handles lessons with several teachers' {
        $global:UntisFake.Rpc['getTimetable'] = '[{"id":1,"date":20261104,"startTime":800,"endTime":845,"te":[{"id":1,"name":"AAA"},{"id":2,"name":"BBB"}]}]'
        (Get-UntisTimetable -Today).Teacher | Should -Be 'AAA, BBB'
    }

    Context 'status and changes' {
        BeforeEach { $script:entries = @(Get-UntisTimetable -Today) }

        It 'marks cancelled lessons' {
            $entry = $script:entries | Where-Object Id -eq 9002
            $entry.Status | Should -Be 'Cancelled'
            $entry.IsCancelled | Should -BeTrue
            $entry.Info | Should -Be 'Excursion'
        }

        It 'reports the original teacher and room' {
            $entry = $script:entries | Where-Object Id -eq 9003
            $entry.Status | Should -Be 'Substitution'
            $entry.Teacher | Should -Be 'OKO'
            $entry.OriginalTeacher | Should -Be 'VOS'
            $entry.OriginalRoom | Should -Be 'C303'
            $entry.SubstitutionText | Should -Be 'Bring your atlas'
        }

        It 'resolves an original room given only by id' {
            $entry = $script:entries | Where-Object Id -eq 9004
            $entry.Status | Should -Be 'RoomChange'
            $entry.OriginalRoom | Should -Be 'A101'
        }

        It 'maps lesson types' {
            ($script:entries | Where-Object Id -eq 9005).LessonType | Should -Be 'Exam'
        }

        It 'fills names missing from the response using master data' {
            ($script:entries | Where-Object Id -eq 9005).Subject | Should -Be 'PH'
        }

        It 'treats date strings the same as numbers' {
            ($script:entries | Where-Object Id -eq 9005).Date | Should -Be ([datetime]'2026-11-05')
        }

        It 'leaves a masked teacher empty' {
            ($script:entries | Where-Object Id -eq 9005).Teacher | Should -BeNullOrEmpty
        }
    }

    It 'shows the id when names cannot be read' {
        $global:UntisFake.Rpc['getSubjects'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right' -Id $id }
        (Get-UntisTimetable -Today | Where-Object Id -eq 9005).Subject | Should -Be '#34'
    }

    It 'can hide cancelled lessons' {
        (Get-UntisTimetable -Today -ExcludeCancelled).Id | Should -Not -Contain 9002
    }

    It 'honours the HideCancelled setting' {
        InModuleScope UntisPS { $script:UntisConnection.Settings['HideCancelled'] = $true }
        (Get-UntisTimetable -Today).Id | Should -Not -Contain 9002
    }

    It 'honours the DefaultRange setting' {
        InModuleScope UntisPS { $script:UntisConnection.Settings['DefaultRange'] = 'Week' }
        Get-UntisTimetable | Out-Null
        (Get-UntisFakeCalls 'getTimetable')[0].Params.options.startDate | Should -Be 20261102
    }

    It 'shows long names when configured' {
        InModuleScope UntisPS { $script:UntisConnection.Settings['NameStyle'] = 'Long' }
        $entry = (Get-UntisTimetable -Today)[0]
        $entry.Subject | Should -Be 'Mathematics'
        $entry.Teacher | Should -Be 'Miller'
    }

    Context 'selectors and filters' {
        It 'requests a class by name' {
            Get-UntisTimetable -Today -Class 5b | Out-Null
            $element = (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element
            $element.id | Should -Be 52
            $element.type | Should -Be 1
        }

        It 'requests a teacher by long name' {
            Get-UntisTimetable -Today -Teacher Harper | Out-Null
            $element = (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element
            $element.id | Should -Be 22
            $element.type | Should -Be 2
        }

        It 'requests a room' {
            Get-UntisTimetable -Today -Room B202 | Out-Null
            (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element.type | Should -Be 4
        }

        It 'prefers a room called 101 over id 101' {
            Get-UntisTimetable -Today -Room 101 | Out-Null
            (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element.id | Should -Be 44
        }

        It 'treats an unmatched number as an id' {
            Get-UntisTimetable -Today -Class 777 | Out-Null
            (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element.id | Should -Be 777
        }

        It 'requests a student, using the id when names cannot be read' {
            $global:UntisFake.Rpc['getStudents'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right' -Id $id }
            Get-UntisTimetable -Today -Student 1300 | Out-Null
            $element = (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element
            $element.id | Should -Be 1300
            $element.type | Should -Be 5
        }

        It 'fails for an unknown name' {
            { Get-UntisTimetable -Today -Class 9z } | Should -Throw "*No class named '9z'*"
        }

        It 'lists candidates for an ambiguous pattern' {
            { Get-UntisTimetable -Today -Class '5*' } | Should -Throw '*several entries: 5a, 5b*'
        }

        It 'filters the own timetable by subject without a school-wide request' {
            $entries = @(Get-UntisTimetable -Today -Subject MA)
            $entries.Count | Should -Be 2
            (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element.type | Should -Be 5
        }

        It 'matches a subject by long name and wildcard' {
            @(Get-UntisTimetable -Today -Subject 'Math*').Count | Should -Be 2
        }

        It 'filters on a second selector client-side' {
            $entries = @(Get-UntisTimetable -Today -Class 5a -Room A101)
            $entries.Id | Should -Be @(9001, 9003)
            (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element.type | Should -Be 1
        }

        It 'takes pipeline input from resource commands' {
            Get-UntisRoom A101 | Get-UntisTimetable -Today | Out-Null
            $element = (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element
            $element.id | Should -Be 41
            $element.type | Should -Be 4
        }

        It 'handles several piped resources' {
            Get-UntisClass '5*' | Get-UntisTimetable -Today | Out-Null
            (Get-UntisFakeCalls 'getTimetable').Count | Should -Be 2
        }

        It 'rejects unrelated pipeline input' {
            { [pscustomobject]@{ Foo = 1 } | Get-UntisTimetable -Today } | Should -Throw '*Pipeline input*'
        }
    }

    Context 'accounts with limited rights' {
        It 'falls back to filtering the own timetable when teachers cannot be read' {
            $global:UntisFake.Rpc['getTeachers'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right for getTeachers()' -Id $id }
            $entries = @(Get-UntisTimetable -Today -Teacher MIL -WarningVariable warnings -WarningAction SilentlyContinue)
            $entries.Id | Should -Be @(9001, 9004)
            $warnings | Should -Match 'cannot look up teacher'
        }

        It 'falls back to the class for shared accounts' {
            $global:UntisFake.Rpc['getTimetable'] = {
                param($r, $id)
                if ($r.Params.options.element.type -eq 5) { New-UntisFakeRpcError -Code -8509 -Message 'no right for timetable' -Id $id } else { 'timetable' }
            }
            $entries = @(Get-UntisTimetable -Today -WarningVariable warnings -WarningAction SilentlyContinue)
            $entries.Count | Should -Be 5
            (Get-UntisFakeCalls 'getTimetable')[1].Params.options.element.id | Should -Be 51
            $warnings | Should -Match 'timetable of your class'
        }

        It 'does not fall back for an explicit selector' {
            $global:UntisFake.Rpc['getTimetable'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right for timetable' -Id $id }
            { Get-UntisTimetable -Today -Class 5b } | Should -Throw '*no right*'
            (Get-UntisFakeCalls 'getTimetable').Count | Should -Be 1
        }

        It 'explains what to do when there is no personal timetable' {
            InModuleScope UntisPS { $script:UntisConnection.PersonId = 0; $script:UntisConnection.PersonType = 0; $script:UntisConnection.ClassId = 0 }
            { Get-UntisTimetable -Today } | Should -Throw '*no personal timetable*'
        }

        It 'uses the class id of parent accounts' {
            InModuleScope UntisPS { $script:UntisConnection.PersonType = 12 }
            Get-UntisTimetable -Today | Out-Null
            (Get-UntisFakeCalls 'getTimetable')[0].Params.options.element.type | Should -Be 1
        }

        It 'explains a date outside the allowed range' {
            $global:UntisFake.Rpc['getTimetable'] = { param($r, $id) New-UntisFakeRpcError -Code -7004 -Message 'no allowed date' -Id $id }
            { Get-UntisTimetable -Today } | Should -Throw '*school year*'
        }
    }
}

Describe 'Get-UntisNextLesson' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'returns the first lesson that has not started' {
        $next = Get-UntisNextLesson
        $next.Id | Should -Be 9003
        $next.StartsIn | Should -Be ([timespan]::FromMinutes(60))
    }

    It 'skips cancelled lessons by default' {
        Mock -ModuleName UntisPS Get-UntisNow { [datetime]'2026-11-04T08:00:00' }
        (Get-UntisNextLesson).Id | Should -Be 9003
        (Get-UntisNextLesson -IncludeCancelled).Id | Should -Be 9002
    }

    It 'can include the lesson in progress' {
        Mock -ModuleName UntisPS Get-UntisNow { [datetime]'2026-11-04T07:50:00' }
        (Get-UntisNextLesson -IncludeCurrent).Id | Should -Be 9001
    }

    It 'returns several lessons' {
        (Get-UntisNextLesson -Count 2).Id | Should -Be @(9003, 9004)
    }

    It 'keeps looking in later weeks' {
        $global:UntisFakeCount = 0
        $global:UntisFake.Rpc['getTimetable'] = {
            param($r, $id)
            $global:UntisFakeCount++
            if ($global:UntisFakeCount -eq 1) { '[]' } else { '[{"id":5,"date":20261112,"startTime":800,"endTime":845}]' }
        }
        (Get-UntisNextLesson).Id | Should -Be 5
    }

    It 'stops quietly at the end of the allowed dates' {
        $global:UntisFake.Rpc['getTimetable'] = { param($r, $id) New-UntisFakeRpcError -Code -7004 -Message 'no allowed date' -Id $id }
        Get-UntisNextLesson | Should -BeNullOrEmpty
    }

    It 'stays inside the look-ahead window' {
        $global:UntisFake.Rpc['getTimetable'] = '[]'
        Get-UntisNextLesson -LookAheadDays 3 | Should -BeNullOrEmpty
        (Get-UntisFakeCalls 'getTimetable')[-1].Params.options.endDate | Should -Be 20261107
    }
}

Describe 'Get-UntisLesson' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'groups periods by lesson number' {
        $lesson = Get-UntisLesson | Where-Object Subject -eq 'MA'
        $lesson.PeriodCount | Should -Be 2
        $lesson.Periods.Count | Should -Be 2
        $lesson.LessonNumber | Should -Be 3100
    }

    It 'counts cancellations and finds the next period' {
        Mock -ModuleName UntisPS Get-UntisNow { [datetime]'2026-11-04T08:00:00' }
        $lesson = Get-UntisLesson | Where-Object Subject -eq 'EN'
        $lesson.CancelledCount | Should -Be 1
        $lesson.NextPeriod | Should -BeNullOrEmpty
        (Get-UntisLesson | Where-Object Subject -eq 'MA').NextPeriod | Should -Be ([datetime]'2026-11-04T11:50:00')
    }

    It 'returns one period by id' {
        (Get-UntisLesson -Id 9003 -Date '2026-11-04').SubstitutionText | Should -Be 'Bring your atlas'
    }

    It 'fails for an unknown id' {
        { Get-UntisLesson -Id 1 -Date '2026-11-04' } | Should -Throw '*No period with id 1*'
    }
}

Describe 'Get-UntisChanges' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'derives personal changes from the timetable' {
        $changes = @(Get-UntisChanges -Today)
        $changes.ChangeType | Should -Be @('Cancellation', 'Substitution', 'RoomChange')
        ($changes.Source | Select-Object -Unique) | Should -Be 'Timetable'
        (Get-UntisFakeCalls 'getSubstitutions').Count | Should -Be 0
    }

    It 'carries the old and new teacher and room' {
        $change = Get-UntisChanges -Today | Where-Object ChangeType -eq 'Substitution'
        $change.OriginalTeacher | Should -Be 'VOS'
        $change.OriginalRoom | Should -Be 'C303'
        $change.Text | Should -Be 'Bring your atlas'
    }

    It 'covers the current week by default' {
        Get-UntisChanges | Out-Null
        (Get-UntisFakeCalls 'getTimetable')[0].Params.options.startDate | Should -Be 20261102
    }

    It 'filters by change type' {
        @(Get-UntisChanges -Today -ChangeType Cancellation).Count | Should -Be 1
    }

    It 'reads the school-wide list on request' {
        $changes = @(Get-UntisChanges -Source Substitutions -Week)
        $changes.Count | Should -Be 3
        $changes[0].ChangeType | Should -Be 'Shifted'
        $changes[0].RescheduledStart | Should -Be ([datetime]'2026-11-06T10:00:00')
        $call = (Get-UntisFakeCalls 'getSubstitutions')[0]
        $call.Params.departmentId | Should -Be 0
        $call.Params.startDate | Should -Be 20261102
    }

    It 'filters the school-wide list' {
        @(Get-UntisChanges -Source Substitutions -Week -Class 5b).Count | Should -Be 1
    }

    It 'reports when the school-wide list is not allowed' {
        $global:UntisFake.Rpc['getSubstitutions'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right' -Id $id }
        { Get-UntisChanges -Source Substitutions } | Should -Throw '*no right*'
    }

    It 'uses the school-wide list for accounts without a timetable' {
        InModuleScope UntisPS { $script:UntisConnection.PersonId = 0; $script:UntisConnection.PersonType = 0; $script:UntisConnection.ClassId = 0 }
        @(Get-UntisChanges -Week).Count | Should -Be 3
    }

    It 'is also available in the singular' {
        (Get-Alias Get-UntisChange).Definition | Should -Be 'Get-UntisChanges'
    }
}

Describe 'Get-UntisExam' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'uses getExams and resolves ids to names' {
        $exam = Get-UntisExam
        $exam.Source | Should -Be 'JsonRpc'
        $exam.Subject | Should -Be 'MA'
        $exam.Class | Should -Be '5a'
        $exam.Teacher | Should -Be 'MIL'
        $exam.StartTime | Should -Be ([datetime]'2026-11-18T08:00:00')
    }

    It 'searches 30 days by default' {
        Get-UntisExam | Out-Null
        $params = (Get-UntisFakeCalls 'getExams')[0].Params
        $params.startDate | Should -Be 20261104
        $params.endDate | Should -Be 20261204
        $params.examTypeId | Should -Be 0
    }

    It 'passes an explicit range' {
        Get-UntisExam -FromDate '2026-11-01' -ToDate '2026-11-30' | Out-Null
        (Get-UntisFakeCalls 'getExams')[0].Params.endDate | Should -Be 20261130
    }

    Context 'without the right for getExams' {
        BeforeEach { $global:UntisFake.Rpc['getExams'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right for getExams()' -Id $id } }

        It 'falls back to the web client in Auto mode' {
            $exams = @(Get-UntisExam)
            $exams.Count | Should -Be 2
            $exams[0].Name | Should -Be 'Book report'
            $exams[0].Class | Should -Be '5a, 5b'
            $exams[1].ExamType | Should -Be 'Test'
            $exams[1].Source | Should -Be 'WebApi'
            (Get-UntisFakeCalls '/WebUntis/api/exams')[0].Uri | Should -Match 'klasseId=-1'
        }

        It 'stays on JSON-RPC in JsonRpc mode' {
            Connect-UntisFake -ApiMode JsonRpc
            { Get-UntisExam } | Should -Throw '*no right*'
            (Get-UntisFakeCalls '/WebUntis/api/exams').Count | Should -Be 0
        }

        It 'filters by subject and class' {
            @(Get-UntisExam -Subject 'Math*').Count | Should -Be 1
            @(Get-UntisExam -Class 5b).Count | Should -Be 1
        }
    }

    It 'does not hide unrelated server errors behind the fallback' {
        $global:UntisFake.Rpc['getExams'] = { param($r, $id) New-UntisFakeRpcError -Code -9999 -Message 'boom' -Id $id }
        { Get-UntisExam } | Should -Throw '*boom*'
    }
}

Describe 'Get-UntisAbsence' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'uses the JSON-RPC method first' {
        $absence = Get-UntisAbsence
        $absence.Source | Should -Be 'JsonRpc'
        $absence.Subject | Should -Be 'MA'
        $absence.Reason | Should -Be 'Illness'
        (Get-UntisFakeCalls 'getTimetableWithAbsences')[0].Params.options.startDate | Should -Be 20261005
    }

    Context 'without the right' {
        BeforeEach { $global:UntisFake.Rpc['getTimetableWithAbsences'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right' -Id $id } }

        It 'falls back to the web client for the logged-in student' {
            $absences = @(Get-UntisAbsence)
            $absences.Count | Should -Be 2
            $absences[0].IsExcused | Should -BeTrue
            $absences[1].StartTime | Should -Be ([datetime]'2026-10-20T08:00:00')
            $absences[1].EndTime | Should -Be ([datetime]'2026-10-21T10:00:00')
            (Get-UntisFakeCalls '/WebUntis/api/classreg/absences/students')[0].Uri | Should -Match 'studentId=1201'
        }

        It 'filters by excuse state' {
            (Get-UntisAbsence -Unexcused).Id | Should -Be 8002
            (Get-UntisAbsence -Excused).Id | Should -Be 8001
        }

        It 'stays on JSON-RPC in JsonRpc mode' {
            Connect-UntisFake -ApiMode JsonRpc
            { Get-UntisAbsence } | Should -Throw '*no right*'
        }
    }
}

Describe 'Resource commands' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'returns <command>' -ForEach @(
        @{ command = 'Get-UntisClass'; count = 3; type = 'UntisPS.Class' }
        @{ command = 'Get-UntisTeacher'; count = 2; type = 'UntisPS.Teacher' }
        @{ command = 'Get-UntisSubject'; count = 3; type = 'UntisPS.Subject' }
        @{ command = 'Get-UntisRoom'; count = 3; type = 'UntisPS.Room' }
    ) {
        $items = @(& $command)
        $items.Count | Should -Be $count
        $items[0].PSObject.TypeNames | Should -Contain $type
        $items[0].PSObject.TypeNames | Should -Contain 'UntisPS.Resource'
    }

    It 'filters by wildcard, long name and id' {
        (Get-UntisClass '5*').Count | Should -Be 2
        (Get-UntisSubject 'Math*').Name | Should -Be 'MA'
        (Get-UntisRoom 42).Name | Should -Be 'B202'
    }

    It 'maps resource details' {
        $teacher = Get-UntisTeacher HAR
        $teacher.ForeName | Should -Be 'Theo'
        $teacher.Title | Should -Be 'Dr.'
        (Get-UntisRoom A101).Building | Should -Be 'Main'
        (Get-UntisClass 6a).IsActive | Should -BeFalse
    }

    It 'does not expose sensitive student fields' {
        $global:UntisFake.Rpc['getStudents'] = '[{"id":1,"name":"doe","key":"K1","foreName":"Jamie","longName":"Doe","gender":"f"}]'
        (Get-UntisStudent).PSObject.Properties.Name | Should -Not -Contain 'gender'
    }

    It 'reports missing rights clearly' {
        $global:UntisFake.Rpc['getTeachers'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right for getTeachers()' -Id $id }
        { Get-UntisTeacher } | Should -Throw '*no right*set by the school*'
    }

    It 'returns school years with dates' {
        $years = @(Get-UntisSchoolYear)
        $years[1].StartDate | Should -Be ([datetime]'2025-09-08')
        (Get-UntisSchoolYear -Current).Name | Should -Be '2026/2027'
    }

    It 'returns holidays' {
        (Get-UntisHoliday).EndDate | Should -Be ([datetime]'2026-10-30')
    }
}
