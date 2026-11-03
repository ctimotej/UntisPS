# In-memory fake of the WebUntis HTTP layer. All names, ids and sessions are fictional.
# Functions are global because Pester runs mock bodies inside the module's scope.

$global:UntisFixtureRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures'

function global:Get-UntisFixtureText {
    param([Parameter(Mandatory)][string]$Name)
    Get-Content -LiteralPath (Join-Path $global:UntisFixtureRoot "$Name.json") -Raw
}

function global:New-UntisFakeResponse {
    param([int]$StatusCode = 200, [string]$Body = '', [string[]]$SetCookies = @(), $RetryAfter = $null)
    [pscustomobject]@{ StatusCode = $StatusCode; Body = $Body; SetCookies = $SetCookies; RetryAfter = $RetryAfter }
}

function global:New-UntisFakeRpcResult {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ResultJson, [string]$Id)
    New-UntisFakeResponse -Body ('{"jsonrpc":"2.0","id":"' + $Id + '","result":' + $ResultJson + '}')
}

function global:New-UntisFakeRpcError {
    param([int]$Code, [string]$Message, [string]$Id)
    New-UntisFakeResponse -Body ('{"jsonrpc":"2.0","id":"' + $Id + '","error":{"code":' + $Code + ',"message":"' + $Message + '"}}')
}

function global:Reset-UntisFake {
    $global:UntisFake = @{
        Requests = New-Object System.Collections.Generic.List[object]
        Rpc      = @{
            authenticate             = 'authenticate'
            logout                   = '{}'
            getTimetable             = 'timetable'
            getKlassen               = 'klassen'
            getTeachers              = 'teachers'
            getSubjects              = 'subjects'
            getRooms                 = 'rooms'
            getStudents              = '[]'
            getSubstitutions         = 'substitutions'
            getExams                 = 'exams-rpc'
            getTimetableWithAbsences = 'absences-rpc'
            getSchoolyears           = 'schoolyears'
            getCurrentSchoolyear     = '{"id":12,"name":"2026/2027","startDate":20260907,"endDate":20270625}'
            getHolidays              = 'holidays'
            getLatestImportTime      = '1793800000000'
        }
        Web      = @{
            '/WebUntis/api/exams'                       = 'exams-web'
            '/WebUntis/api/classreg/absences/students'  = 'absences-web'
        }
    }
}

function global:Invoke-UntisFakeHttp {
    param($Method, $Uri, $Body, $Headers)
    $parsedBody = $null
    if ($Body) { $parsedBody = $Body | ConvertFrom-Json }
    $path = ([System.Uri]$Uri).AbsolutePath
    $rpcMethod = if ($parsedBody) { $parsedBody.method } else { $null }
    $record = [pscustomobject]@{
        Method = $Method; Uri = $Uri; Path = $path; RpcMethod = $rpcMethod
        Params = $(if ($parsedBody) { $parsedBody.params } else { $null })
        Headers = $Headers; Body = $Body
    }
    $global:UntisFake.Requests.Add($record)

    $key = if ($rpcMethod) { $rpcMethod } else { $path }
    $table = if ($rpcMethod) { $global:UntisFake.Rpc } else { $global:UntisFake.Web }
    $handler = $table[$key]
    $id = if ($parsedBody) { $parsedBody.id } else { '' }
    if ($handler -is [scriptblock]) { $handler = & $handler $record $id }
    if ($handler -is [pscustomobject]) { return $handler }
    if ($null -eq $handler) {
        if ($rpcMethod) { return (New-UntisFakeRpcError -Code -32601 -Message 'method not found' -Id $id) }
        return (New-UntisFakeResponse -StatusCode 404)
    }
    $fixturePath = Join-Path $global:UntisFixtureRoot "$handler.json"
    $text = if (Test-Path -LiteralPath $fixturePath) { Get-Content -LiteralPath $fixturePath -Raw } else { [string]$handler }
    if ($rpcMethod) { return (New-UntisFakeRpcResult -ResultJson $text -Id $id) }
    New-UntisFakeResponse -Body $text
}

function global:Get-UntisFakeCalls {
    param([string]$Name)
    @($global:UntisFake.Requests | Where-Object { $_.RpcMethod -eq $Name -or $_.Path -eq $Name })
}

function global:Connect-UntisFake {
    param([string]$ApiMode = 'Auto', [string]$Password = 'not-a-real-password-1')
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential('jamie.doe', $secure)
    Connect-Untis -Server 'example.webuntis.com' -School 'ExampleSchool' -Credential $credential -ApiMode $ApiMode
}

# Sets up the mocks shared by the test files. Call from BeforeEach. Pins "now" to Wednesday 2026-11-04 10:00.
function global:Use-UntisFake {
    Reset-UntisFake
    $env:UNTIS_CONFIG_PATH = Join-Path ([System.IO.Path]::GetTempPath()) "untisps-tests-$PID/config.json"
    Mock -ModuleName UntisPS Invoke-UntisHttpRequest { Invoke-UntisFakeHttp -Method $Method -Uri $Uri -Body $Body -Headers $Headers }
    Mock -ModuleName UntisPS Invoke-UntisDelay {}
    Mock -ModuleName UntisPS Get-UntisNow { [datetime]'2026-11-04T10:00:00' }
}
