BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../UntisPS.psd1') -Force
    . (Join-Path $PSScriptRoot 'helpers/FakeUntis.ps1')
}

AfterAll { Remove-Module UntisPS -Force -ErrorAction SilentlyContinue }

Describe 'Default views' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'shows a table grouped by day' {
        $text = Get-UntisTimetable -Today | Out-String -Width 120
        $text | Should -Match 'Date: \w+, 2026-11-04'
        $text | Should -Match '07:45\s+08:30\s+MA\s+MIL\s+A101\s+5a\s+Normal'
        $text | Should -Match '08:35\s+09:20\s+EN\s+HAR\s+B202\s+5a\s+Cancelled'
    }

    It 'keeps full DateTime values for custom Format-Table' {
        $text = Get-UntisTimetable -Today | Format-Table StartTime, EndTime, Subject, Teacher, Room, Status | Out-String -Width 160
        $text | Should -Match 'StartTime'
        $text | Should -Match 'Status'
    }

    It 'shows changes with old and new values' {
        $text = Get-UntisChanges -Today | Out-String -Width 140
        $text | Should -Match 'VOS -> OKO'
        $text | Should -Match 'C303 -> A101'
    }

    It 'stays usable in the pipeline after formatting views load' {
        (Get-UntisTimetable -Today | Where-Object IsCancelled | Select-Object -ExpandProperty Subject) | Should -Be 'EN'
        (Get-UntisTimetable -Today | Sort-Object Subject -Descending | Select-Object -First 1).Subject | Should -Be 'PH'
        ((Get-UntisTimetable -Today | ConvertTo-Json -Depth 4) | ConvertFrom-Json).Count | Should -Be 5
        @(Get-UntisTimetable -Today | ConvertTo-Csv -NoTypeInformation).Count | Should -Be 6
    }

    It 'has a view for <name>' -ForEach @(
        @{ name = 'exams'; block = { Get-UntisExam }; pattern = '2026-11-18\s+08:00\s+09:30\s+MA' }
        @{ name = 'lessons'; block = { Get-UntisLesson -Date '2026-11-04' }; pattern = 'MA\s+MIL\s+5a\s+2' }
        @{ name = 'resources'; block = { Get-UntisRoom A101 }; pattern = '41\s+A101\s+Room A101' }
        @{ name = 'diagnostics'; block = { Mock -ModuleName UntisPS Resolve-UntisHostAddress { '192.0.2.1' }; $global:UntisFake.Web['/WebUntis/'] = '{}'; Test-UntisConnection -Detailed }; pattern = 'Authentication\s+Pass' }
    ) {
        (& $block | Out-String -Width 120) | Should -Match $pattern
    }
}

Describe 'Format-UntisTimetable' {
    BeforeEach {
        Use-UntisFake
        Connect-UntisFake
        $script:entries = Get-UntisTimetable -Today
    }
    AfterEach { Disconnect-Untis }

    It 'renders an agenda with day headings and flags' {
        $lines = $script:entries | Format-UntisTimetable
        ($lines -join "`n") | Should -Match '2026-11-04'
        ($lines -join "`n") | Should -Match '  07:45-08:30  MA\s+MIL\s+A101'
        ($lines -join "`n") | Should -Match '\[Cancelled\]'
        ($lines -join "`n") | Should -Match '\[Substitution\]'
    }

    It 'renders a week grid with aligned columns' {
        $lines = @($script:entries | Format-UntisTimetable -View Week)
        $lines[0] | Should -Match '^Time\s+\|'
        $lines[1] | Should -Match '^-+-\+-'
        ($lines -join "`n") | Should -Match '\(EN\)'
        ($lines -join "`n") | Should -Match 'GE\*'
        ($lines | Where-Object { $_ -match '^\d\d:\d\d' } | ForEach-Object { $_.IndexOf('|') } | Select-Object -Unique) | Should -HaveCount 1
    }

    It 'puts each day in its own column' {
        $lines = @($script:entries | Format-UntisTimetable -View Week)
        ($lines[0] -split '\|').Count | Should -Be 3
    }

    It 'returns nothing for no input' {
        @() | Format-UntisTimetable | Should -BeNullOrEmpty
    }

    It 'rejects other objects' {
        { [pscustomobject]@{ A = 1 } | Format-UntisTimetable } | Should -Throw '*Get-UntisTimetable*'
    }
}

Describe 'Test-UntisConnection' {
    BeforeEach {
        Use-UntisFake
        Mock -ModuleName UntisPS Resolve-UntisHostAddress { '192.0.2.1' }
        $global:UntisFake.Web['/WebUntis/'] = '{}'
    }
    AfterEach { Disconnect-Untis }

    It 'is true for a working session' {
        Connect-UntisFake
        Test-UntisConnection | Should -BeTrue
    }

    It 'covers every step in detail' {
        Connect-UntisFake
        $results = Test-UntisConnection -Detailed
        $results.Step | Should -Be @('Configuration', 'DNS', 'HTTPS', 'Authentication', 'API access')
        ($results.Status | Select-Object -Unique) | Should -Be 'Pass'
    }

    It 'is false when not connected, and says why' {
        Test-UntisConnection -Server 'example.webuntis.com' -School 'S' | Should -BeFalse
        $results = Test-UntisConnection -Server 'example.webuntis.com' -School 'S' -Detailed
        ($results | Where-Object Step -eq 'Authentication').Status | Should -Be 'Skipped'
        ($results | Where-Object Step -eq 'HTTPS').Status | Should -Be 'Pass'
    }

    It 'reports a DNS failure and skips the rest' {
        Mock -ModuleName UntisPS Resolve-UntisHostAddress { throw 'no such host' }
        $results = Test-UntisConnection -Server 'missing.webuntis.com' -School 'S' -Detailed
        ($results | Where-Object Step -eq 'DNS').Status | Should -Be 'Fail'
        ($results | Where-Object Step -eq 'HTTPS').Status | Should -Be 'Skipped'
    }

    It 'reports an HTTPS failure' {
        Mock -ModuleName UntisPS Invoke-UntisHttpRequest { throw (& (Get-Module UntisPS) { New-UntisErrorRecord -Kind 'Transport' -Message 'Request failed: certificate rejected' }) }
        $results = Test-UntisConnection -Server 'example.webuntis.com' -School 'S' -Detailed
        ($results | Where-Object Step -eq 'HTTPS').Message | Should -Match 'certificate rejected'
    }

    It 'reports an invalid server' {
        $results = Test-UntisConnection -Server 'http://example.webuntis.com' -School 'S' -Detailed
        ($results | Where-Object Step -eq 'Configuration').Status | Should -Be 'Fail'
    }

    It 'tests a credential with a temporary login and logs out' {
        $credential = [pscredential]::new('a', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        Test-UntisConnection -Server 'example.webuntis.com' -School 'S' -Credential $credential | Should -BeTrue
        (Get-UntisFakeCalls 'logout').Count | Should -Be 1
        Get-UntisConnection | Should -BeNullOrEmpty
    }

    It 'reports a rejected credential' {
        $global:UntisFake.Rpc['authenticate'] = { param($r, $id) New-UntisFakeRpcError -Code -8504 -Message 'bad credentials' -Id $id }
        $credential = [pscredential]::new('a', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        $results = Test-UntisConnection -Server 'example.webuntis.com' -School 'S' -Credential $credential -Detailed
        ($results | Where-Object Step -eq 'Authentication').Status | Should -Be 'Fail'
    }
}

Describe 'Get-UntisCapability' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'reports what is available and what is refused' {
        $global:UntisFake.Rpc['getTeachers'] = { param($r, $id) New-UntisFakeRpcError -Code -8509 -Message 'no right' -Id $id }
        $global:UntisFake.Rpc.Remove('getHolidays')
        $global:UntisFake.Web.Remove('/WebUntis/api/exams')
        $results = Get-UntisCapability
        ($results | Where-Object Feature -eq 'Subjects').Status | Should -Be 'Available'
        ($results | Where-Object Feature -eq 'Teachers').Status | Should -Be 'NoPermission'
        ($results | Where-Object Feature -eq 'Holidays').Status | Should -Be 'NotOffered'
        ($results | Where-Object Method -eq '/WebUntis/api/exams').Status | Should -Be 'NotOffered'
        ($results | Where-Object Feature -eq 'Own timetable').Status | Should -Be 'Available'
    }

    It 'includes the failure text for other errors' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeRpcError -Code -9999 -Message 'boom' -Id $id }
        $result = Get-UntisCapability | Where-Object Feature -eq 'Rooms'
        $result.Status | Should -Be 'Error'
        $result.Detail | Should -Match 'boom'
    }

    It 'does not touch undocumented endpoints in JsonRpc mode' {
        Connect-UntisFake -ApiMode JsonRpc
        $global:UntisFake.Requests.Clear()
        (Get-UntisCapability | Where-Object Api -like 'Web*').Status | Select-Object -Unique | Should -Be 'Disabled'
        (Get-UntisFakeCalls '/WebUntis/api/exams').Count | Should -Be 0
    }
}

Describe 'Invoke-UntisApi' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'returns the raw result' {
        (Invoke-UntisApi -Method getRooms).Count | Should -Be 3
    }

    It 'passes parameters' {
        Invoke-UntisApi -Method getKlassen -Params @{ schoolyearId = 12 } | Out-Null
        (Get-UntisFakeCalls 'getKlassen')[0].Params.schoolyearId | Should -Be 12
    }

    It 'refuses <method>' -ForEach @(@{ method = 'authenticate' }, @{ method = 'logout' }, @{ method = 'setAnything' }) {
        { Invoke-UntisApi -Method $method } | Should -Throw
    }
}
