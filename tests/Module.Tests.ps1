BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'UntisPS.psd1') -Force
    . (Join-Path $PSScriptRoot 'helpers/FakeUntis.ps1')
    $script:sources = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'src') -Filter *.ps1) + @(Get-Item (Join-Path $script:root 'UntisPS.psm1'))
}

AfterAll { Remove-Module UntisPS -Force -ErrorAction SilentlyContinue }

Describe 'Module' {
    It 'has a valid manifest' {
        $manifest = Test-ModuleManifest -Path (Join-Path $script:root 'UntisPS.psd1')
        $manifest.Version | Should -Be '0.1.0'
    }

    It 'exports every command in the specification' {
        $exported = (Get-Command -Module UntisPS).Name
        foreach ($name in 'Connect-Untis', 'Disconnect-Untis', 'Get-UntisConnection', 'Test-UntisConnection', 'Get-UntisTimetable', 'Get-UntisExam',
            'Get-UntisChanges', 'Get-UntisLesson', 'Get-UntisSubject', 'Get-UntisTeacher', 'Get-UntisRoom', 'Get-UntisClass', 'Get-UntisNextLesson') {
            $exported | Should -Contain $name
        }
    }

    It 'keeps helpers private' {
        (Get-Command -Module UntisPS).Name | Should -Not -Contain 'Invoke-UntisHttpRequest'
        (Get-Command -Module UntisPS).Name | Should -Not -Contain 'Invoke-UntisLogin'
    }

    It 'matches the module version in the loader and the manifest' {
        $version = InModuleScope UntisPS { $script:UntisModuleVersion }
        $version | Should -Be (Get-Module UntisPS).Version.ToString()
    }

    It 'documents <_.Name>' -ForEach @(Get-Command -Module UntisPS -CommandType Function) {
        $help = Get-Help $_.Name -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match '^\s*$'
        @($help.examples.example).Count | Should -BeGreaterThan 0
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        foreach ($parameter in $_.Parameters.Keys) {
            if ($parameter -in $common) { continue }
            $documented = @($help.parameters.parameter | Where-Object { $_.name -eq $parameter })[0]
            ($documented.description | Out-String).Trim() | Should -Not -BeNullOrEmpty -Because "-$parameter needs a description"
        }
    }
}

Describe 'Windows PowerShell 5.1 compatibility' {
    It '<_.Name> avoids PowerShell 7 syntax' -ForEach @(Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') -Filter *.ps1) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true) | Should -BeNullOrEmpty
        $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.PipelineChainAst] }, $true) | Should -BeNullOrEmpty
        $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and $node.Operator -eq 'QuestionQuestion' }, $true) | Should -BeNullOrEmpty
        $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($node.Operator)" -eq 'QuestionQuestionEquals' }, $true) | Should -BeNullOrEmpty
        ($tokens | Where-Object { $_.Kind -in @('QuestionDot', 'QuestionLBracket') }) | Should -BeNullOrEmpty
    }

    It '<_.Name> is plain ASCII, so 5.1 reads it without a BOM' -ForEach @(Get-ChildItem (Split-Path -Parent $PSScriptRoot) -Include *.ps1, *.psm1, *.psd1, *.ps1xml -Recurse) {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'does not use parameters missing from 5.1' {
        $text = ($script:sources | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $text | Should -Not -Match '-SkipHttpErrorCheck|-AsHashtable|-ResponseHeadersVariable|-NoEnumerate'
    }
}

Describe 'Security' {
    BeforeAll {
        $script:text = ($script:sources | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    }

    It 'has no way to disable certificate validation' {
        $script:text | Should -Not -Match 'SkipCertificateCheck|ServerCertificateValidationCallback|ServerCertificateCustomValidationCallback|DangerousAcceptAnyServerCertificateValidator|TrustAllCertsPolicy'
    }

    It 'only builds https base addresses' {
        $script:text | Should -Match 'BaseUri\s+= "https://\$Server"'
        $script:text | Should -Not -Match '"http://'
    }

    It 'has no password environment variable' {
        $script:text | Should -Not -Match 'UNTIS_PASSWORD|UNTIS_SECRET'
    }

    It 'does not use a browser or scraping fallback' {
        $script:text | Should -Not -Match 'Selenium|Playwright|ParsedHtml|j_spring_security_check'
    }

    It 'never logs request bodies, headers or query strings' {
        $verboseLines = [regex]::Matches($script:text, 'Write-Verbose [^\n]+') | ForEach-Object { $_.Value }
        $safeUriForm = '$(([System.Uri]$Uri).AbsolutePath)'
        ($verboseLines -join "`n").Replace($safeUriForm, '') | Should -Not -Match '\$Body|\$Headers|\$Params|\$Uri|\$Connection\.|Password|sessionId|Cookie'
    }

    It 'redacts <name>' -ForEach @(
        @{ name = 'a session cookie'; text = 'Cookie: JSESSIONID=ABC123; x=y'; secret = 'ABC123' }
        @{ name = 'a JSON session id'; text = '{"sessionId":"ABC123"}'; secret = 'ABC123' }
        @{ name = 'a JSON password'; text = '{"password":"hunter2"}'; secret = 'hunter2' }
        @{ name = 'a bearer token'; text = 'Authorization: Bearer abc.def.ghi'; secret = 'abc.def.ghi' }
    ) {
        InModuleScope UntisPS -Parameters @{ text = $text; secret = $secret } {
            Protect-UntisText $text | Should -Not -Match ([regex]::Escape($secret))
        }
    }

    Context 'at runtime' {
        BeforeEach {
            Use-UntisFake
            $script:password = 'not-a-real-password-4'
            $script:session = 'FAKE-SESSION-0001'
        }
        AfterEach { Disconnect-Untis }

        It 'keeps secrets out of verbose, warning and information output' {
            $captured = & {
                $VerbosePreference = 'Continue'
                $InformationPreference = 'Continue'
                Connect-UntisFake -Password $script:password
                Get-UntisTimetable -Today | Out-Null
                Get-UntisConnection | Format-List * | Out-String
            } *>&1 | Out-String
            $captured | Should -Not -Match $script:password
            $captured | Should -Not -Match $script:session
        }

        It 'keeps secrets out of the connection object' {
            Connect-UntisFake -Password $script:password
            $json = Get-UntisConnection | ConvertTo-Json -Depth 5
            $json | Should -Not -Match $script:session
            $json | Should -Not -Match $script:password
            (Get-UntisConnection).PSObject.Properties.Name | Should -Not -Contain 'SessionId'
            (Get-UntisConnection).PSObject.Properties.Name | Should -Not -Contain 'Credential'
        }

        It 'keeps secrets out of error messages from the server' {
            $global:UntisFake.Rpc['authenticate'] = { param($r, $id) New-UntisFakeRpcError -Code -9999 -Message 'failure for sessionId=ABC123 password=hunter2' -Id $id }
            $caught = $null
            try { Connect-UntisFake } catch { $caught = $_ }
            "$caught" | Should -Not -Match 'ABC123'
            "$caught" | Should -Not -Match 'hunter2'
        }

        It 'does not put secrets in any request URL' {
            Connect-UntisFake -Password $script:password
            Get-UntisTimetable -Today | Out-Null
            ($global:UntisFake.Requests.Uri -join ' ') | Should -Not -Match $script:password
            ($global:UntisFake.Requests.Uri -join ' ') | Should -Not -Match $script:session
        }

        It 'sends no password after login' {
            Connect-UntisFake -Password $script:password
            Get-UntisTimetable -Today | Out-Null
            $later = $global:UntisFake.Requests | Where-Object RpcMethod -ne 'authenticate'
            ($later.Body -join ' ') | Should -Not -Match $script:password
        }
    }
}
