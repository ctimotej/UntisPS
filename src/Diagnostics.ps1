# Connection tests, capability discovery and a read-only escape hatch.

function New-UntisDiagnosticResult {
    [CmdletBinding()]
    [OutputType('UntisPS.DiagnosticResult')]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'Skipped')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ PSTypeName = 'UntisPS.DiagnosticResult'; Step = $Step; Status = $Status; Message = $Message }
}

function Resolve-UntisHostAddress {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$HostName)
    @([System.Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { $_.ToString() })
}

function Test-UntisConnection {
    <#
    .SYNOPSIS
        Checks DNS, HTTPS, authentication and API access.
    .DESCRIPTION
        Returns $true only when an authenticated API call works. With -Detailed it returns one result
        per step and explains what failed. Without an active connection, DNS and HTTPS can still be
        checked by passing -Server. With -Credential, a temporary login is made and logged out again;
        the active connection is not touched.
    .PARAMETER Detailed
        Returns one result per step instead of $true or $false.
    .PARAMETER Server
        Host to test. Defaults to the active connection, then the configuration.
    .PARAMETER School
        School to test. Defaults to the active connection, then the configuration.
    .PARAMETER Credential
        Credential for a temporary test login.
    .EXAMPLE
        Test-UntisConnection
    .EXAMPLE
        Test-UntisConnection -Detailed
    .EXAMPLE
        Test-UntisConnection -Server example.webuntis.com -School ExampleSchool -Credential (Get-Credential) -Detailed
    .OUTPUTS
        System.Boolean, or UntisPS.DiagnosticResult with -Detailed
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [OutputType('UntisPS.DiagnosticResult')]
    param(
        [switch]$Detailed,
        [string]$Server,
        [string]$School,
        [pscredential]$Credential
    )
    $results = New-Object System.Collections.Generic.List[object]
    $settings = Get-UntisEffectiveConfiguration
    $active = $script:UntisConnection
    if (-not $Server -and $active) { $Server = $active.Server }
    if (-not $Server) { $Server = $settings['Server'] }
    if (-not $School -and $active) { $School = $active.School }
    if (-not $School) { $School = $settings['School'] }

    $serverName = $null
    if ($Server) {
        try {
            $serverName = ConvertTo-UntisServerName -Server $Server
            $results.Add((New-UntisDiagnosticResult -Step 'Configuration' -Status 'Pass' -Message "Server $serverName, school '$School'."))
        } catch {
            $results.Add((New-UntisDiagnosticResult -Step 'Configuration' -Status 'Fail' -Message $_.Exception.Message))
        }
    } else {
        $results.Add((New-UntisDiagnosticResult -Step 'Configuration' -Status 'Fail' -Message 'No server configured. Use -Server or Set-UntisConfiguration.'))
    }

    $reachable = $false
    if ($serverName) {
        $hostOnly = ($serverName -split ':')[0]
        try {
            $addresses = @(Resolve-UntisHostAddress -HostName $hostOnly)
            $results.Add((New-UntisDiagnosticResult -Step 'DNS' -Status 'Pass' -Message "Resolved to $($addresses.Count) address(es)."))
            try {
                $base = "https://$serverName"
                if ($active -and $active.Server -eq $serverName) { $base = $active.BaseUri }
                $probe = Invoke-UntisHttpRequest -Method 'GET' -Uri "$base/WebUntis/" -TimeoutSeconds ([int]$settings['TimeoutSeconds'])
                if ($probe.StatusCode -ge 500) {
                    $results.Add((New-UntisDiagnosticResult -Step 'HTTPS' -Status 'Fail' -Message "Server answered HTTP $($probe.StatusCode)."))
                } else {
                    $reachable = $true
                    $results.Add((New-UntisDiagnosticResult -Step 'HTTPS' -Status 'Pass' -Message "TLS verified, server answered HTTP $($probe.StatusCode)."))
                }
            } catch {
                $results.Add((New-UntisDiagnosticResult -Step 'HTTPS' -Status 'Fail' -Message $_.Exception.Message))
            }
        } catch {
            $results.Add((New-UntisDiagnosticResult -Step 'DNS' -Status 'Fail' -Message "Could not resolve $hostOnly."))
            $results.Add((New-UntisDiagnosticResult -Step 'HTTPS' -Status 'Skipped' -Message 'DNS failed.'))
        }
    } else {
        $results.Add((New-UntisDiagnosticResult -Step 'DNS' -Status 'Skipped' -Message 'No valid server.'))
        $results.Add((New-UntisDiagnosticResult -Step 'HTTPS' -Status 'Skipped' -Message 'No valid server.'))
    }

    $authenticated = $false
    $apiWorks = $false
    if (-not $reachable) {
        $results.Add((New-UntisDiagnosticResult -Step 'Authentication' -Status 'Skipped' -Message 'Server is not reachable.'))
        $results.Add((New-UntisDiagnosticResult -Step 'API access' -Status 'Skipped' -Message 'Server is not reachable.'))
    } elseif ($Credential) {
        $temporary = New-UntisConnectionObject -Server $serverName -School $School -Credential $Credential -ApiMode 'JsonRpc' -AuthMethod 'Password' -Settings $settings
        try {
            Invoke-UntisLogin -Connection $temporary
            $authenticated = $true
            $results.Add((New-UntisDiagnosticResult -Step 'Authentication' -Status 'Pass' -Message "Logged in as $(Get-UntisPersonTypeName -PersonType $temporary.PersonType)."))
            try {
                [void](Invoke-UntisRpcRequest -Connection $temporary -Method 'getLatestImportTime')
                $apiWorks = $true
                $results.Add((New-UntisDiagnosticResult -Step 'API access' -Status 'Pass' -Message 'getLatestImportTime answered.'))
            } catch {
                $results.Add((New-UntisDiagnosticResult -Step 'API access' -Status 'Fail' -Message $_.Exception.Message))
            }
        } catch {
            $results.Add((New-UntisDiagnosticResult -Step 'Authentication' -Status 'Fail' -Message $_.Exception.Message))
            $results.Add((New-UntisDiagnosticResult -Step 'API access' -Status 'Skipped' -Message 'Login failed.'))
        } finally {
            if ($temporary.SessionId) {
                try { [void](Invoke-UntisRpcRequest -Connection $temporary -Method 'logout') } catch { Write-Verbose 'Test logout failed.' }
            }
            $temporary.Credential = $null
        }
    } elseif ($active -and $active.Server -eq $serverName) {
        try {
            [void](Invoke-UntisRpc -Method 'getLatestImportTime')
            $authenticated = $true
            $apiWorks = $true
            $results.Add((New-UntisDiagnosticResult -Step 'Authentication' -Status 'Pass' -Message "Session is valid for $($active.UserName)."))
            $results.Add((New-UntisDiagnosticResult -Step 'API access' -Status 'Pass' -Message 'getLatestImportTime answered.'))
        } catch {
            $results.Add((New-UntisDiagnosticResult -Step 'Authentication' -Status 'Fail' -Message $_.Exception.Message))
            $results.Add((New-UntisDiagnosticResult -Step 'API access' -Status 'Skipped' -Message 'No valid session.'))
        }
    } else {
        $results.Add((New-UntisDiagnosticResult -Step 'Authentication' -Status 'Skipped' -Message 'Not connected. Run Connect-Untis or pass -Credential.'))
        $results.Add((New-UntisDiagnosticResult -Step 'API access' -Status 'Skipped' -Message 'Not connected.'))
    }

    if ($Detailed) { return $results.ToArray() }
    $authenticated -and $apiWorks
}

function Get-UntisCapability {
    <#
    .SYNOPSIS
        Shows which API features this account can use at this school.
    .DESCRIPTION
        WebUntis rights differ per school and role, and not everything is documented. This command
        calls each read-only method once and reports the result. Use it to see what a command will be
        able to return, and include the output in bug reports. It contains no school data.
    .EXAMPLE
        Get-UntisCapability
    .EXAMPLE
        Get-UntisCapability | Where-Object Status -ne Available
    .OUTPUTS
        UntisPS.Capability
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Capability')]
    param()
    try {
        $connection = Get-UntisActiveConnection
        $today = (Get-UntisNow).Date
        $todayNumber = ConvertTo-UntisDateNumber -Date $today
        $dateParams = @{ startDate = $todayNumber; endDate = $todayNumber }
        $probes = @(
            @{ Feature = 'Subjects'; Api = 'JSON-RPC'; Name = 'getSubjects'; Params = @{} }
            @{ Feature = 'Teachers'; Api = 'JSON-RPC'; Name = 'getTeachers'; Params = @{} }
            @{ Feature = 'Classes'; Api = 'JSON-RPC'; Name = 'getKlassen'; Params = @{} }
            @{ Feature = 'Rooms'; Api = 'JSON-RPC'; Name = 'getRooms'; Params = @{} }
            @{ Feature = 'Students'; Api = 'JSON-RPC'; Name = 'getStudents'; Params = @{} }
            @{ Feature = 'School years'; Api = 'JSON-RPC'; Name = 'getSchoolyears'; Params = @{} }
            @{ Feature = 'Holidays'; Api = 'JSON-RPC'; Name = 'getHolidays'; Params = @{} }
            @{ Feature = 'School-wide changes'; Api = 'JSON-RPC'; Name = 'getSubstitutions'; Params = ($dateParams + @{ departmentId = 0 }) }
            @{ Feature = 'Exams'; Api = 'JSON-RPC'; Name = 'getExams'; Params = ($dateParams + @{ examTypeId = 0 }) }
            @{ Feature = 'Absences'; Api = 'JSON-RPC'; Name = 'getTimetableWithAbsences'; Params = @{ options = $dateParams } }
        )
        $own = Get-UntisOwnElement -Connection $connection
        if ($own) {
            $probes += @{
                Feature = 'Own timetable'; Api = 'JSON-RPC'; Name = 'getTimetable'
                Params  = @{ options = ($dateParams + @{ element = @{ id = $own.Id; type = $own.Type } }) }
            }
        }
        foreach ($probe in $probes) {
            $status = 'Available'
            $detail = ''
            try {
                [void](Invoke-UntisRpc -Method $probe.Name -Params $probe.Params)
            } catch {
                $failure = $_
                switch (Get-UntisErrorKind $failure) {
                    'NoRight' { $status = 'NoPermission' }
                    'MethodNotFound' { $status = 'NotOffered' }
                    default { $status = 'Error'; $detail = $failure.Exception.Message }
                }
            }
            [pscustomobject]@{ PSTypeName = 'UntisPS.Capability'; Feature = $probe.Feature; Api = $probe.Api; Method = $probe.Name; Status = $status; Detail = $detail }
        }

        $webProbes = @(
            @{ Feature = 'Exams'; Path = '/WebUntis/api/exams'; Query = @{ startDate = $todayNumber; endDate = $todayNumber; klasseId = -1; withGrades = 'false' } }
            @{ Feature = 'Absences'; Path = '/WebUntis/api/classreg/absences/students'; Query = @{ startDate = $todayNumber; endDate = $todayNumber; studentId = $connection.PersonId; excuseStatusId = -1 } }
        )
        foreach ($probe in $webProbes) {
            $status = 'Available'
            $detail = ''
            if ($connection.ApiMode -ne 'Auto') {
                $status = 'Disabled'
                $detail = 'ApiMode is JsonRpc.'
            } else {
                try {
                    [void](Invoke-UntisWebApi -Path $probe.Path -Query $probe.Query)
                } catch {
                    $failure = $_
                    switch (Get-UntisErrorKind $failure) {
                        'NoRight' { $status = 'NoPermission' }
                        'MethodNotFound' { $status = 'NotOffered' }
                        default { $status = 'Error'; $detail = $failure.Exception.Message }
                    }
                }
            }
            [pscustomobject]@{ PSTypeName = 'UntisPS.Capability'; Feature = $probe.Feature; Api = 'Web client (undocumented)'; Method = $probe.Path; Status = $status; Detail = $detail }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Invoke-UntisApi {
    <#
    .SYNOPSIS
        Calls a read-only JSON-RPC method directly and returns the raw result.
    .DESCRIPTION
        For methods UntisPS does not wrap, and for inspecting raw responses. Only methods starting with
        get are accepted, so this cannot change data.
    .PARAMETER Method
        JSON-RPC method name, for example getStatusData.
    .PARAMETER Params
        Parameters for the method.
    .EXAMPLE
        Invoke-UntisApi -Method getStatusData
    .EXAMPLE
        Invoke-UntisApi -Method getKlassen -Params @{ schoolyearId = 12 }
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidatePattern('^get[A-Z][A-Za-z0-9]*$')][string]$Method,
        [Parameter(Position = 1)][hashtable]$Params = @{}
    )
    try {
        $result = Invoke-UntisRpc -Method $Method -Params $Params
        $result
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
