BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../UntisPS.psd1') -Force
    . (Join-Path $PSScriptRoot 'helpers/FakeUntis.ps1')
}

AfterAll { Remove-Module UntisPS -Force -ErrorAction SilentlyContinue }

Describe 'JSON-RPC errors' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'maps <code> to <kind>' -ForEach @(
        @{ code = -8509; kind = 'NoRight' }
        @{ code = -7004; kind = 'DateNotAllowed' }
        @{ code = -8507; kind = 'DateNotAllowed' }
        @{ code = -32601; kind = 'MethodNotFound' }
        @{ code = -9999; kind = 'Rpc' }
    ) {
        $global:UntisFake.Rpc['getRooms'] = [scriptblock]::Create("param(`$r, `$id) New-UntisFakeRpcError -Code $code -Message 'server says no' -Id `$id")
        $caught = $null
        try { Get-UntisRoom } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['UntisErrorKind'] | Should -Be $kind
        $caught.Exception.Data['UntisErrorCode'] | Should -Be $code
        $caught.Exception.Message | Should -Match 'server says no'
    }

    It 'gives a clear error for a non-JSON body' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -Body '<html>maintenance</html>' }
        { Get-UntisRoom } | Should -Throw '*did not return JSON*'
    }

    It 'rejects a response with the wrong id' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -Body '{"id":"other","result":[]}' }
        { Get-UntisRoom } | Should -Throw '*mismatched*'
    }

    It 'accepts a response without an id' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -Body '{"result":[]}' }
        { Get-UntisRoom } | Should -Not -Throw
    }

    It 'fails if the envelope has no result' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -Body '{"jsonrpc":"2.0"}' }
        { Get-UntisRoom } | Should -Throw '*no result*'
    }

    It 'treats an HTTP redirect on JSON-RPC as an error' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -StatusCode 302 }
        { Get-UntisRoom } | Should -Throw '*HTTP 302*'
    }
}

Describe 'Retries' {
    BeforeEach {
        Use-UntisFake
        Connect-UntisFake
        $global:UntisFakeCount = 0
    }
    AfterEach { Disconnect-Untis }

    It 'retries a transient <status>' -ForEach @(
        @{ status = 408 }, @{ status = 500 }, @{ status = 502 }, @{ status = 503 }, @{ status = 504 }
    ) {
        $global:UntisFakeStatus = $status
        $global:UntisFake.Rpc['getRooms'] = {
            param($r, $id)
            $global:UntisFakeCount++
            if ($global:UntisFakeCount -le 2) { New-UntisFakeResponse -StatusCode $global:UntisFakeStatus } else { 'rooms' }
        }
        (Get-UntisRoom).Count | Should -Be 3
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 3
    }

    It 'gives up after the configured retries' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -StatusCode 503 }
        { Get-UntisRoom } | Should -Throw '*HTTP 503*after 4 attempt*'
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 4
    }

    It 'does not retry a client error' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -StatusCode 400 }
        { Get-UntisRoom } | Should -Throw '*HTTP 400*'
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 1
    }

    It 'retries transport failures and reports the last one' {
        Mock -ModuleName UntisPS Invoke-UntisHttpRequest {
            $global:UntisFakeCount++
            throw (& (Get-Module UntisPS) { New-UntisErrorRecord -Kind 'Transport' -Message 'Request failed: timed out after 30 seconds' })
        }
        { Get-UntisRoom } | Should -Throw '*timed out*'
        $global:UntisFakeCount | Should -Be 4
    }

    It 'waits for the Retry-After value on 429' {
        $global:UntisFake.Rpc['getRooms'] = {
            param($r, $id)
            $global:UntisFakeCount++
            if ($global:UntisFakeCount -eq 1) { New-UntisFakeResponse -StatusCode 429 -RetryAfter 7 } else { 'rooms' }
        }
        Get-UntisRoom | Out-Null
        Should -Invoke -ModuleName UntisPS Invoke-UntisDelay -ParameterFilter { $Milliseconds -eq 7000 }
    }

    It 'does not sit through a very long Retry-After' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeResponse -StatusCode 429 -RetryAfter 900 }
        { Get-UntisRoom } | Should -Throw '*rate limiting*Retry after 900 seconds*'
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 1
    }

    It 'holds later requests until a rate limit has passed' {
        InModuleScope UntisPS {
            $script:UntisThrottle.NotBefore = [datetime]::UtcNow.AddSeconds(5)
            Wait-UntisRateLimit
            Should -Invoke Invoke-UntisDelay -ParameterFilter { $Milliseconds -gt 4000 -and $Milliseconds -le 5000 }
            $script:UntisThrottle.NotBefore = [datetime]::MinValue
        }
    }

    It 'grows the backoff and caps it' {
        InModuleScope UntisPS {
            Get-UntisBackoffMilliseconds -Attempt 0 | Should -BeLessThan 751
            Get-UntisBackoffMilliseconds -Attempt 3 | Should -BeGreaterOrEqual 4000
            Get-UntisBackoffMilliseconds -Attempt 20 | Should -BeLessThan 30251
        }
    }
}

Describe 'Web client endpoints' {
    BeforeEach { Use-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'are refused in JsonRpc mode without a request' {
        Connect-UntisFake -ApiMode JsonRpc
        InModuleScope UntisPS { { Invoke-UntisWebApi -Path '/WebUntis/api/exams' } | Should -Throw '*ApiMode*' }
        (Get-UntisFakeCalls '/WebUntis/api/exams').Count | Should -Be 0
    }

    It 'reports a 404 as not offered' {
        Connect-UntisFake
        InModuleScope UntisPS { { Invoke-UntisWebApi -Path '/WebUntis/api/missing' } | Should -Throw '*does not offer*' }
    }

    It 'maps the not-allowed date key' {
        Connect-UntisFake
        $global:UntisFake.Web['/WebUntis/api/x'] = '{"data":{"error":{"data":{"messageKey":"ERR_TTVIEW_NOTALLOWED_ONDATE"}}}}'
        InModuleScope UntisPS { { Invoke-UntisWebApi -Path '/WebUntis/api/x' } | Should -Throw '*does not allow this date range*' }
    }

    It 'logs in again after a redirect, then reports missing rights if still refused' {
        Connect-UntisFake
        $global:UntisFake.Web['/WebUntis/api/x'] = { param($r, $id) New-UntisFakeResponse -StatusCode 302 }
        InModuleScope UntisPS { { Invoke-UntisWebApi -Path '/WebUntis/api/x' } | Should -Throw '*lacks the permission*' }
        (Get-UntisFakeCalls 'authenticate').Count | Should -Be 2
    }

    It 'encodes query values' {
        Connect-UntisFake
        $global:UntisFake.Web['/WebUntis/api/x'] = '{"data":{}}'
        InModuleScope UntisPS { Invoke-UntisWebApi -Path '/WebUntis/api/x' -Query @{ a = 'b c'; d = 1 } | Out-Null }
        (Get-UntisFakeCalls '/WebUntis/api/x')[0].Uri | Should -BeLike '*?a=b%20c&d=1'
    }
}

Describe 'Cache' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'serves repeated master data from memory' {
        Get-UntisRoom | Out-Null
        Get-UntisRoom | Out-Null
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 1
    }

    It 'bypasses the cache with -Force and stores the fresh result' {
        Get-UntisRoom | Out-Null
        Get-UntisRoom -Force | Out-Null
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 2
    }

    It 'expires entries' {
        Get-UntisTimetable -Today | Out-Null
        Mock -ModuleName UntisPS Get-UntisNow { [datetime]'2026-11-04T10:01:01' }
        Get-UntisTimetable -Today | Out-Null
        (Get-UntisFakeCalls 'getTimetable').Count | Should -Be 2
    }

    It 'keeps different parameters apart' {
        Get-UntisTimetable -Today | Out-Null
        Get-UntisTimetable -Tomorrow | Out-Null
        (Get-UntisFakeCalls 'getTimetable').Count | Should -Be 2
    }

    It 'is emptied by Clear-UntisCache' {
        Get-UntisRoom | Out-Null
        Clear-UntisCache
        Get-UntisRoom | Out-Null
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 2
    }

    It 'can be turned off' {
        InModuleScope UntisPS { $script:UntisConnection.Settings['CacheSeconds'] = 0 }
        Get-UntisTimetable -Today | Out-Null
        Get-UntisTimetable -Today | Out-Null
        (Get-UntisFakeCalls 'getTimetable').Count | Should -Be 2
    }

    It 'never caches absences' {
        Get-UntisAbsence | Out-Null
        Get-UntisAbsence | Out-Null
        (Get-UntisFakeCalls 'getTimetableWithAbsences').Count | Should -Be 2
    }

    It 'does not cache errors' {
        $global:UntisFakeCount = 0
        $global:UntisFake.Rpc['getRooms'] = {
            param($r, $id)
            $global:UntisFakeCount++
            if ($global:UntisFakeCount -eq 1) { New-UntisFakeRpcError -Code -8509 -Message 'no right' -Id $id } else { 'rooms' }
        }
        { Get-UntisRoom } | Should -Throw
        (Get-UntisRoom).Count | Should -Be 3
    }
}

Describe 'Configuration' {
    BeforeEach {
        Use-UntisFake
        $env:UNTIS_CONFIG_PATH = Join-Path $TestDrive 'nested/config.json'
        foreach ($name in 'UNTIS_SERVER', 'UNTIS_SCHOOL', 'UNTIS_USERNAME', 'UNTIS_API_MODE', 'UNTIS_CACHE_SECONDS') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
    }
    AfterEach {
        foreach ($name in 'UNTIS_SERVER', 'UNTIS_SCHOOL', 'UNTIS_API_MODE', 'UNTIS_CACHE_SECONDS') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
        Disconnect-Untis
    }

    It 'has sensible defaults' {
        $config = Get-UntisConfiguration
        $config.ApiMode | Should -Be 'Auto'
        $config.DefaultRange | Should -Be 'Today'
        $config.CacheSeconds | Should -Be 60
    }

    It 'saves settings and creates the folder' {
        Set-UntisConfiguration -Server 'https://Example.webuntis.com/WebUntis' -School 'ExampleSchool' -CacheSeconds 5 | Out-Null
        $config = Get-UntisConfiguration
        $config.Server | Should -Be 'example.webuntis.com'
        $config.CacheSeconds | Should -Be 5
    }

    It 'keeps earlier values when setting others' {
        Set-UntisConfiguration -School 'ExampleSchool' | Out-Null
        Set-UntisConfiguration -NameStyle Long | Out-Null
        (Get-UntisConfiguration).School | Should -Be 'ExampleSchool'
    }

    It 'prefers environment variables over the file' {
        Set-UntisConfiguration -School 'FromFile' | Out-Null
        $env:UNTIS_SCHOOL = 'FromEnv'
        (Get-UntisConfiguration).School | Should -Be 'FromEnv'
    }

    It 'lets Connect-Untis parameters win over everything' {
        $env:UNTIS_SERVER = 'env.webuntis.com'
        Connect-UntisFake
        (Get-UntisConnection).Server | Should -Be 'example.webuntis.com'
    }

    It 'lets Connect-Untis use configured values' {
        Set-UntisConfiguration -Server 'example.webuntis.com' -School 'ExampleSchool' | Out-Null
        Connect-Untis -Credential ([pscredential]::new('a', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
        (Get-UntisConnection).School | Should -Be 'ExampleSchool'
    }

    It 'survives a corrupt file' {
        New-Item -ItemType Directory -Force (Split-Path $env:UNTIS_CONFIG_PATH) | Out-Null
        Set-Content -LiteralPath $env:UNTIS_CONFIG_PATH -Value '{not json'
        $config = Get-UntisConfiguration 3>$null
        $config.ApiMode | Should -Be 'Auto'
    }

    It 'ignores keys it does not know, such as a pasted password' {
        New-Item -ItemType Directory -Force (Split-Path $env:UNTIS_CONFIG_PATH) | Out-Null
        Set-Content -LiteralPath $env:UNTIS_CONFIG_PATH -Value '{"Password":"oops","School":"S"}'
        $config = Get-UntisConfiguration 3>$null
        $config.PSObject.Properties.Name | Should -Not -Contain 'Password'
        $config.School | Should -Be 'S'
    }

    It 'has no parameter that accepts a password' {
        (Get-Command Set-UntisConfiguration).Parameters.Keys | Should -Not -Contain 'Password'
    }

    It 'never writes the password when saving a connection' {
        function global:Set-Secret { param($Name, $Secret) }
        try {
            Connect-Untis -Server 'example.webuntis.com' -School 'ExampleSchool' -Save `
                -Credential ([pscredential]::new('jamie.doe', (ConvertTo-SecureString 'not-a-real-password-2' -AsPlainText -Force)))
            $text = Get-Content -LiteralPath $env:UNTIS_CONFIG_PATH -Raw
            $text | Should -Match 'jamie.doe'
            $text | Should -Not -Match 'not-a-real-password-2'
        } finally {
            Remove-Item function:global:Set-Secret
        }
    }

    It 'resets to defaults' {
        Set-UntisConfiguration -School 'ExampleSchool' | Out-Null
        Reset-UntisConfiguration -Confirm:$false
        (Get-UntisConfiguration).School | Should -BeNullOrEmpty
    }
}

Describe 'Wire-level behaviour against a real HTTP server' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'helpers/LocalServer.ps1')
        $script:server = Start-UntisLocalServer -FixtureRoot $global:UntisFixtureRoot
        $env:UNTIS_CONFIG_PATH = Join-Path $TestDrive 'config.json'
    }
    AfterAll { Stop-UntisLocalServer -Server $script:server }

    BeforeEach {
        # The module only accepts https hosts, so tests inject the loopback address directly.
        InModuleScope UntisPS -Parameters @{ baseUri = $script:server.BaseUri } {
            $settings = Get-UntisEffectiveConfiguration
            $settings['MinRequestIntervalMs'] = 0
            $settings['TimeoutSeconds'] = 5
            $credential = [pscredential]::new('jamie.doe', (ConvertTo-SecureString 'not-a-real-password-3' -AsPlainText -Force))
            $connection = New-UntisConnectionObject -Server 'example.webuntis.com' -School 'Example School' -Credential $credential -ApiMode 'Auto' -AuthMethod 'Password' -Settings $settings
            $connection.BaseUri = $baseUri
            Invoke-UntisLogin -Connection $connection
            $script:UntisConnection = $connection
            $script:UntisCache = @{}
            $script:UntisThrottle.NotBefore = [datetime]::MinValue
        }
    }
    AfterEach { Disconnect-Untis }

    It 'completes login and a timetable call over real HTTP' {
        $entries = @(Get-UntisTimetable -Date '2026-11-04')
        $entries.Count | Should -Be 5
        $entries[0].Subject | Should -Be 'MA'
        $last = $script:server.State.Log[$script:server.State.Log.Count - 1]
        $last.Query | Should -Match 'school=Example(%20| )School'
        $last.Cookie | Should -Match 'JSESSIONID=LOCAL-SESSION-\d+; schoolname='
        $last.UserAgent | Should -Match '^UntisPS/'
    }

    It 'recovers from an expired session' {
        $before = $script:server.State.Logins
        $script:server.State.ExpireNext = $true
        @(Get-UntisTimetable -Date '2026-11-04').Count | Should -Be 5
        $script:server.State.Logins | Should -Be ($before + 1)
    }

    It 'retries a real 503' {
        $script:server.State.Fail503 = 1
        @(Get-UntisTimetable -Date '2026-11-04').Count | Should -Be 5
    }

    It 'reads a real Retry-After header' {
        $script:server.State.Fail429 = 1
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        @(Get-UntisTimetable -Date '2026-11-04').Count | Should -Be 5
        $watch.ElapsedMilliseconds | Should -BeGreaterOrEqual 900
    }

    It 'reads a Retry-After date' {
        $script:server.State.Fail429Date = 1
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        @(Get-UntisTimetable -Date '2026-11-04').Count | Should -Be 5
        $watch.ElapsedMilliseconds | Should -BeGreaterOrEqual 500
    }

    It 'enforces the request timeout' {
        InModuleScope UntisPS -Parameters @{ baseUri = $script:server.BaseUri } {
            { Invoke-UntisHttpRequest -Method GET -Uri "$baseUri/slow" -TimeoutSeconds 1 } | Should -Throw '*timed out after 1 seconds*'
        }
    }

    It 'does not follow redirects' {
        InModuleScope UntisPS -Parameters @{ baseUri = $script:server.BaseUri } {
            (Invoke-UntisHttpRequest -Method GET -Uri "$baseUri/redirect").StatusCode | Should -Be 302
        }
    }

    It 'reports a refused connection as a transport failure' {
        InModuleScope UntisPS {
            { Invoke-UntisHttpRequest -Method GET -Uri 'http://127.0.0.1:1/' -TimeoutSeconds 2 } | Should -Throw '*failed:*'
        }
    }

    It 'handles a web endpoint redirect through session recovery' {
        InModuleScope UntisPS { $script:UntisConnection.SessionId = 'STALE' }
        $data = InModuleScope UntisPS { Invoke-UntisWebApi -Path '/WebUntis/api/exams' }
        @($data.exams).Count | Should -Be 2
    }
}
