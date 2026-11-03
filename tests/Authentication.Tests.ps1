BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../UntisPS.psd1') -Force
    . (Join-Path $PSScriptRoot 'helpers/FakeUntis.ps1')
}

AfterAll { Remove-Module UntisPS -Force -ErrorAction SilentlyContinue }

Describe 'Connect-Untis' {
    BeforeEach { Use-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'logs in over JSON-RPC and stores person details' {
        Connect-UntisFake
        $connection = Get-UntisConnection
        $connection.Server | Should -Be 'example.webuntis.com'
        $connection.PersonType | Should -Be 'Student'
        $connection.PersonId | Should -Be 1201
        $connection.ClassId | Should -Be 51
    }

    It 'posts to jsonrpc.do with the school in the query' {
        Connect-UntisFake
        $call = (Get-UntisFakeCalls 'authenticate')[0]
        $call.Uri | Should -Be 'https://example.webuntis.com/WebUntis/jsonrpc.do?school=ExampleSchool'
        $call.Params.user | Should -Be 'jamie.doe'
        $call.Params.client | Should -Be 'UntisPS'
    }

    It 'URL-encodes a school name with spaces' {
        $secure = ConvertTo-SecureString 'x' -AsPlainText -Force
        Connect-Untis -Server 'example.webuntis.com' -School 'Example School' -Credential ([pscredential]::new('a', $secure))
        (Get-UntisFakeCalls 'authenticate')[0].Uri | Should -Match 'school=Example%20School$'
    }

    It 'sends session and school cookies on later calls' {
        Connect-UntisFake
        Get-UntisRoom | Out-Null
        $cookie = (Get-UntisFakeCalls 'getRooms')[0].Headers.Cookie
        $cookie | Should -Match 'JSESSIONID=FAKE-SESSION-0001'
        $expected = [System.Uri]::EscapeDataString('_' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ExampleSchool')))
        $cookie | Should -Match ([regex]::Escape("schoolname=$expected"))
    }

    It 'does not send a cookie with the login request' {
        Connect-UntisFake
        (Get-UntisFakeCalls 'authenticate')[0].Headers.Keys | Should -Not -Contain 'Cookie'
    }

    It 'reports bad credentials and does not retry them' {
        $global:UntisFake.Rpc['authenticate'] = { param($r, $id) New-UntisFakeRpcError -Code -8504 -Message 'bad credentials' -Id $id }
        { Connect-UntisFake } | Should -Throw '*rejected the credentials*two-factor*'
        (Get-UntisFakeCalls 'authenticate').Count | Should -Be 1
        Get-UntisConnection | Should -BeNullOrEmpty
    }

    It 'treats a code inside the result as a failed login' {
        $global:UntisFake.Rpc['authenticate'] = '{"code":4010}'
        { Connect-UntisFake } | Should -Throw '*code 4010*'
    }

    It 'fails when no session id is returned' {
        $global:UntisFake.Rpc['authenticate'] = '{}'
        { Connect-UntisFake } | Should -Throw '*did not return a session*'
    }

    It 'requires server and school' {
        $secure = ConvertTo-SecureString 'x' -AsPlainText -Force
        { Connect-Untis -Credential ([pscredential]::new('a', $secure)) } | Should -Throw '*Specify -Server and -School*'
    }

    It 'warns before sending a password to a host outside webuntis.com' {
        $secure = ConvertTo-SecureString 'x' -AsPlainText -Force
        Connect-Untis -Server 'untis.example.org' -School 'S' -Credential ([pscredential]::new('a', $secure)) -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -Match 'not a webuntis.com host'
    }

    It 'uses a stored credential when none is passed' {
        Mock -ModuleName UntisPS Get-UntisStoredCredential { [pscredential]::new('stored.user', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
        Connect-Untis -Server 'example.webuntis.com' -School 'ExampleSchool'
        (Get-UntisConnection).UserName | Should -Be 'stored.user'
    }
}

Describe 'Server validation' {
    It 'accepts <value>' -ForEach @(
        @{ value = 'example.webuntis.com'; expected = 'example.webuntis.com' }
        @{ value = 'EXAMPLE.WebUntis.com'; expected = 'example.webuntis.com' }
        @{ value = 'https://example.webuntis.com/WebUntis/?school=x#/login'; expected = 'example.webuntis.com' }
        @{ value = '  example.webuntis.com '; expected = 'example.webuntis.com' }
    ) {
        InModuleScope UntisPS -Parameters @{ value = $value; expected = $expected } {
            ConvertTo-UntisServerName -Server $value | Should -Be $expected
        }
    }

    It 'rejects <value>' -ForEach @(
        @{ value = 'http://example.webuntis.com' }
        @{ value = 'ftp://example.webuntis.com' }
        @{ value = 'https://user:pass@example.webuntis.com' }
        @{ value = 'example.webuntis.com/path' }
        @{ value = 'example webuntis com' }
        @{ value = 'localhost' }
        @{ value = '127.0.0.1' }
        @{ value = 'evil.example.com@webuntis.com' }
    ) {
        InModuleScope UntisPS -Parameters @{ value = $value } {
            { ConvertTo-UntisServerName -Server $value } | Should -Throw
        }
    }
}

Describe 'Session management' {
    BeforeEach { Use-UntisFake; Connect-UntisFake }
    AfterEach { Disconnect-Untis }

    It 'logs in again once when the session expired, and repeats the call' {
        $global:UntisFakeCount = 0
        $global:UntisFake.Rpc['getRooms'] = {
            param($r, $id)
            $global:UntisFakeCount++
            if ($global:UntisFakeCount -eq 1) { New-UntisFakeRpcError -Code -8520 -Message 'not authenticated' -Id $id }
            else { 'rooms' }
        }
        (Get-UntisRoom).Count | Should -Be 3
        (Get-UntisFakeCalls 'authenticate').Count | Should -Be 2
    }

    It 'stops after one recovery if the session keeps expiring' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeRpcError -Code -8520 -Message 'not authenticated' -Id $id }
        { Get-UntisRoom } | Should -Throw '*not valid*'
        (Get-UntisFakeCalls 'authenticate').Count | Should -Be 2
        (Get-UntisFakeCalls 'getRooms').Count | Should -Be 2
    }

    It 'blocks further logins after a failed recovery' {
        $global:UntisFake.Rpc['getRooms'] = { param($r, $id) New-UntisFakeRpcError -Code -8520 -Message 'not authenticated' -Id $id }
        $global:UntisFake.Rpc['authenticate'] = { param($r, $id) New-UntisFakeRpcError -Code -8504 -Message 'bad credentials' -Id $id }
        { Get-UntisRoom } | Should -Throw '*rejected the credentials*'
        { Get-UntisRoom -Force } | Should -Throw '*Run Connect-Untis again*'
        (Get-UntisFakeCalls 'authenticate').Count | Should -Be 2
    }
}

Describe 'Disconnect-Untis' {
    BeforeEach { Use-UntisFake }

    It 'logs out and clears session, credential and cache' {
        Connect-UntisFake
        Get-UntisRoom | Out-Null
        Disconnect-Untis
        (Get-UntisFakeCalls 'logout').Count | Should -Be 1
        Get-UntisConnection | Should -BeNullOrEmpty
        InModuleScope UntisPS { $script:UntisConnection | Should -BeNullOrEmpty; $script:UntisCache.Count | Should -Be 0 }
    }

    It 'still clears local state when the logout request fails' {
        Connect-UntisFake
        $global:UntisFake.Rpc['logout'] = { param($r, $id) New-UntisFakeResponse -StatusCode 400 }
        { Disconnect-Untis } | Should -Not -Throw
        Get-UntisConnection | Should -BeNullOrEmpty
    }

    It 'does nothing when not connected' {
        { Disconnect-Untis } | Should -Not -Throw
        (Get-UntisFakeCalls 'logout').Count | Should -Be 0
    }

    It 'makes commands fail with a clear message' {
        { Get-UntisTimetable -Today } | Should -Throw '*Run Connect-Untis first*'
    }
}

Describe 'Secret login' {
    It 'generates RFC 6238 codes for <time>' -ForEach @(
        @{ time = 59; expected = '287082' }
        @{ time = 1111111109; expected = '081804' }
        @{ time = 2000000000; expected = '279037' }
    ) {
        InModuleScope UntisPS -Parameters @{ time = $time; expected = $expected } {
            $key = ConvertFrom-UntisBase32 -Value 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
            [System.Text.Encoding]::ASCII.GetString($key) | Should -Be '12345678901234567890'
            New-UntisTotp -Key $key -UnixSeconds $time | Should -Be $expected
        }
    }

    It 'rejects a secret that is not Base32' {
        InModuleScope UntisPS { { ConvertFrom-UntisBase32 -Value 'not!valid' } | Should -Throw '*Base32*' }
    }

    Context 'against the fake server' {
        BeforeEach {
            Use-UntisFake
            $global:UntisFake.Rpc['getUserData2017'] = {
                param($r, $id)
                New-UntisFakeResponse -Body '{"jsonrpc":"2.0","result":{}}' -SetCookies @('JSESSIONID=SECRET-SESSION-1; Path=/WebUntis; Secure; HttpOnly')
            }
            $global:UntisFake.Web['/WebUntis/api/app/config'] = '{"data":{"loginServiceConfig":{"user":{"personId":1201,"persons":[{"id":1201,"type":5}]}}}}'
            $global:UntisFake.Web['/WebUntis/api/daytimetable/config'] = '{"data":{"klasseId":51}}'
            $script:secret = ConvertTo-SecureString 'GEZDGNBVGY3TQOJQ' -AsPlainText -Force
        }
        AfterEach { Disconnect-Untis }

        It 'reads the session cookie and person details' {
            Connect-Untis -Server 'example.webuntis.com' -School 'ExampleSchool' -UserName 'jamie.doe' -Secret $script:secret
            $connection = Get-UntisConnection
            $connection.AuthMethod | Should -Be 'Secret'
            $connection.PersonId | Should -Be 1201
            $connection.ClassId | Should -Be 51
            $call = (Get-UntisFakeCalls 'getUserData2017')[0]
            $call.Path | Should -Be '/WebUntis/jsonrpc_intern.do'
            $call.Uri | Should -Match 'm=getUserData2017&v=i2.2'
            $call.Params[0].auth.user | Should -Be 'jamie.doe'
            $call.Params[0].auth.otp | Should -Match '^\d{6}$'
            (Get-UntisFakeCalls 'authenticate').Count | Should -Be 0
        }

        It 'never sends the raw secret' {
            Connect-Untis -Server 'example.webuntis.com' -School 'ExampleSchool' -UserName 'jamie.doe' -Secret $script:secret
            ($global:UntisFake.Requests | ForEach-Object { $_.Uri + $_.Body }) -join '' | Should -Not -Match 'GEZDGNBVGY3TQOJQ'
        }

        It 'fails when the server refuses' {
            $global:UntisFake.Rpc['getUserData2017'] = { param($r, $id) New-UntisFakeResponse -Body '{"error":{"code":-8504,"message":"invalid otp"}}' }
            { Connect-Untis -Server 'example.webuntis.com' -School 'ExampleSchool' -UserName 'a' -Secret $script:secret } | Should -Throw '*invalid otp*'
        }
    }
}

Describe 'Credential storage' {
    BeforeEach {
        Use-UntisFake
        $script:credential = [pscredential]::new('jamie.doe', (ConvertTo-SecureString 'x' -AsPlainText -Force))
    }

    It 'refuses to store without a secure backend on non-Windows' -Skip:($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        Mock -ModuleName UntisPS Test-UntisSecretManagement { $false }
        { Save-UntisCredential -Server 'example.webuntis.com' -School 'ExampleSchool' -Credential $script:credential } | Should -Throw '*No secure credential store*'
    }

    It 'stores through SecretManagement when available' {
        function global:Set-Secret { param($Name, $Secret) $global:UntisSavedSecret = @{ Name = $Name; Secret = $Secret } }
        try {
            Save-UntisCredential -Server 'example.webuntis.com' -School 'ExampleSchool' -Credential $script:credential
            $global:UntisSavedSecret.Name | Should -Be 'UntisPS:example.webuntis.com:exampleschool'
            $global:UntisSavedSecret.Secret | Should -BeOfType [pscredential]
        } finally {
            Remove-Item function:global:Set-Secret
        }
    }
}
