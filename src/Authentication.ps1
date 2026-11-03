# Login, logout, session recovery and credential storage.

function Get-UntisSecretName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$School
    )
    "UntisPS:$($Server.ToLowerInvariant()):$($School.ToLowerInvariant())"
}

function Test-UntisSecretManagement {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [bool](Get-Command -Name 'Set-Secret' -ErrorAction SilentlyContinue)
}

function Get-UntisCredentialFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SecretName)
    $safeName = ($SecretName -replace '[^A-Za-z0-9._-]', '_')
    Join-Path (Get-UntisConfigDirectory) "$safeName.credential.xml"
}

function Get-UntisStoredCredential {
    <# Looks in SecretManagement, then in the Windows DPAPI file. Returns nothing if not stored. #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$School
    )
    $name = Get-UntisSecretName -Server $Server -School $School
    if (Test-UntisSecretManagement) {
        $stored = Get-Secret -Name $name -ErrorAction SilentlyContinue
        if ($stored -is [pscredential]) { return $stored }
    }
    if (Test-UntisIsWindows) {
        $path = Get-UntisCredentialFilePath -SecretName $name
        if (Test-Path -LiteralPath $path) { return (Import-Clixml -LiteralPath $path) }
    }
}

function Save-UntisCredential {
    <#
    .SYNOPSIS
        Stores a WebUntis credential securely for later Connect-Untis calls.
    .DESCRIPTION
        Uses Microsoft.PowerShell.SecretManagement when it is installed with a registered vault. On
        Windows without it, the credential is written with DPAPI (Export-Clixml), which only the same
        user on the same computer can decrypt. On Linux and macOS without SecretManagement the command
        refuses, because there is no encrypted store to fall back on.
    .PARAMETER Credential
        WebUntis user name and password. Prompts if omitted.
    .PARAMETER Server
        WebUntis host name. Defaults to the configured server.
    .PARAMETER School
        School identifier. Defaults to the configured school.
    .EXAMPLE
        Save-UntisCredential -Server example.webuntis.com -School ExampleSchool
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [pscredential]$Credential,
        [string]$Server,
        [string]$School
    )
    $settings = Get-UntisEffectiveConfiguration
    if (-not $Server) { $Server = $settings['Server'] }
    if (-not $School) { $School = $settings['School'] }
    if (-not $Server -or -not $School) {
        throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Message 'Specify -Server and -School, or configure them with Set-UntisConfiguration.')
    }
    $Server = ConvertTo-UntisServerName -Server $Server
    if (-not $Credential) { $Credential = Get-Credential -Message "WebUntis login for $School" }
    $name = Get-UntisSecretName -Server $Server -School $School

    if (Test-UntisSecretManagement) {
        if ($PSCmdlet.ShouldProcess($name, 'Store credential in SecretManagement vault')) { Set-Secret -Name $name -Secret $Credential }
        return
    }
    if (Test-UntisIsWindows) {
        $path = Get-UntisCredentialFilePath -SecretName $name
        if ($PSCmdlet.ShouldProcess($path, 'Store DPAPI-protected credential')) {
            $directory = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            $Credential | Export-Clixml -LiteralPath $path
        }
        return
    }
    throw (New-UntisErrorRecord -Kind 'Configuration' -Category NotInstalled `
            -Message 'No secure credential store is available. Install Microsoft.PowerShell.SecretManagement with a vault such as Microsoft.PowerShell.SecretStore, then try again.')
}

function Remove-UntisCredential {
    <#
    .SYNOPSIS
        Deletes a credential stored by Save-UntisCredential.
    .PARAMETER Server
        WebUntis host name. Defaults to the configured server.
    .PARAMETER School
        School identifier. Defaults to the configured school.
    .EXAMPLE
        Remove-UntisCredential
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [string]$Server,
        [string]$School
    )
    $settings = Get-UntisEffectiveConfiguration
    if (-not $Server) { $Server = $settings['Server'] }
    if (-not $School) { $School = $settings['School'] }
    if (-not $Server -or -not $School) {
        throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Message 'Specify -Server and -School, or configure them with Set-UntisConfiguration.')
    }
    $name = Get-UntisSecretName -Server (ConvertTo-UntisServerName -Server $Server) -School $School
    if ((Test-UntisSecretManagement) -and $PSCmdlet.ShouldProcess($name, 'Remove from SecretManagement vault')) {
        Remove-Secret -Name $name -ErrorAction SilentlyContinue
    }
    $path = Get-UntisCredentialFilePath -SecretName $name
    if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Delete credential file')) {
        Remove-Item -LiteralPath $path -Force
    }
}

function ConvertFrom-UntisBase32 {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][string]$Value)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $buffer = 0
    $bitCount = 0
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($character in ($Value.ToUpperInvariant().TrimEnd('=') -replace '[\s-]', '').ToCharArray()) {
        $index = $alphabet.IndexOf($character)
        if ($index -lt 0) {
            throw (New-UntisErrorRecord -Kind 'Argument' -Category InvalidArgument -Message 'The WebUntis secret is not valid Base32.')
        }
        $buffer = (($buffer -shl 5) -bor $index) -band 0xFFFF
        $bitCount += 5
        if ($bitCount -ge 8) {
            $bitCount -= 8
            $bytes.Add([byte](($buffer -shr $bitCount) -band 0xFF))
        }
    }
    , $bytes.ToArray()
}

function New-UntisTotp {
    <# RFC 6238 code with the common defaults: HMAC-SHA1, 30 second step, 6 digits. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][long]$UnixSeconds
    )
    $counter = [long][math]::Floor($UnixSeconds / 30)
    $counterBytes = [System.BitConverter]::GetBytes($counter)
    if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($counterBytes) }
    $hmac = [System.Security.Cryptography.HMACSHA1]::new($Key)
    try { $hash = $hmac.ComputeHash($counterBytes) } finally { $hmac.Dispose() }
    $offset = $hash[$hash.Length - 1] -band 0x0F
    $code = (([long]($hash[$offset] -band 0x7F)) * 16777216) + (([long]$hash[$offset + 1]) * 65536) + (([long]$hash[$offset + 2]) * 256) + [long]$hash[$offset + 3]
    ($code % 1000000).ToString('D6')
}

function Invoke-UntisPasswordLogin {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$Connection)
    $params = @{
        user     = $Connection.Credential.UserName
        password = $Connection.Credential.GetNetworkCredential().Password
        client   = 'UntisPS'
    }
    $result = Invoke-UntisRpcRequest -Connection $Connection -Method 'authenticate' -Params $params
    $params = $null
    if ($result.code) {
        throw (New-UntisErrorRecord -Kind 'Authentication' -Category AuthenticationError -Target 'authenticate' -Code $result.code -Message "WebUntis refused the login with code $($result.code).")
    }
    if (-not $result.sessionId) {
        throw (New-UntisErrorRecord -Kind 'Authentication' -Category AuthenticationError -Target 'authenticate' -Message 'WebUntis did not return a session.')
    }
    $Connection.SessionId = $result.sessionId
    $Connection.PersonId = [int]$result.personId
    $Connection.PersonType = [int]$result.personType
    $Connection.ClassId = [int]$result.klasseId
}

function Invoke-UntisSecretLogin {
    <#
    Login with the personal secret from the WebUntis profile (the data in the "Untis Mobile" QR code).
    This uses the internal app endpoint, which is undocumented; the flow follows community clients.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$Connection)
    $userName = $Connection.Credential.UserName
    $key = ConvertFrom-UntisBase32 -Value $Connection.Credential.GetNetworkCredential().Password
    $unixMilliseconds = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $otp = New-UntisTotp -Key $key -UnixSeconds ([long][math]::Floor($unixMilliseconds / 1000))
    $body = @{
        id      = 'UntisPS'
        method  = 'getUserData2017'
        params  = @(@{ auth = @{ clientTime = $unixMilliseconds; user = $userName; otp = $otp } })
        jsonrpc = '2.0'
    } | ConvertTo-Json -Depth 10 -Compress
    $request = @{
        Method = 'POST'
        Uri    = (Get-UntisRpcUri -Connection $Connection -Path '/WebUntis/jsonrpc_intern.do' -ExtraQuery 'm=getUserData2017&v=i2.2')
        Body   = $body
    }
    $response = Invoke-UntisHttpWithRetry -Request $request -Configuration $Connection.Settings -Target 'secret login'
    $envelope = ConvertFrom-UntisJson -Text $response.Body -Target 'secret login'
    if ($envelope.error) {
        throw (New-UntisErrorRecord -Kind 'Authentication' -Category AuthenticationError -Target 'secret login' -Code $envelope.error.code `
                -Message "WebUntis refused the secret login: $(Protect-UntisText ([string]$envelope.error.message))")
    }
    $sessionId = $null
    foreach ($cookie in $response.SetCookies) {
        if ($cookie -match '(?:^|;\s*)JSESSIONID=([^;]+)') { $sessionId = $Matches[1] }
    }
    if (-not $sessionId) {
        throw (New-UntisErrorRecord -Kind 'Authentication' -Category AuthenticationError -Target 'secret login' -Message 'WebUntis did not return a session cookie.')
    }
    $Connection.SessionId = $sessionId

    $config = Invoke-UntisWebRequestOnce -Connection $Connection -Path '/WebUntis/api/app/config'
    $user = $config.loginServiceConfig.user
    $person = @($user.persons | Where-Object { $_.id -eq $user.personId }) | Select-Object -First 1
    if ($person) {
        $Connection.PersonId = [int]$user.personId
        $Connection.PersonType = [int]$person.type
    }
    try {
        $dayConfig = Invoke-UntisWebRequestOnce -Connection $Connection -Path '/WebUntis/api/daytimetable/config'
        if ($dayConfig.klasseId) { $Connection.ClassId = [int]$dayConfig.klasseId }
    } catch {
        Write-Verbose 'Class id is not available for this account.'
    }
}

function Invoke-UntisLogin {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$Connection)
    if ($Connection.AuthMethod -eq 'Secret') { Invoke-UntisSecretLogin -Connection $Connection }
    else { Invoke-UntisPasswordLogin -Connection $Connection }
    $Connection.ConnectedAt = Get-UntisNow
    $Connection.LastActivity = $Connection.ConnectedAt
    $Connection.ReauthenticationBlocked = $false
}

function Invoke-UntisReauthentication {
    <# Called after session expiry. A failed attempt blocks further logins so an account cannot be locked by repeated tries. #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$Connection)
    if ($Connection.ReauthenticationBlocked) {
        throw (New-UntisErrorRecord -Kind 'Authentication' -Category AuthenticationError -Message 'A previous automatic login failed. Run Connect-Untis again.')
    }
    try {
        Invoke-UntisLogin -Connection $Connection
    } catch {
        $Connection.ReauthenticationBlocked = $true
        $Connection.SessionId = $null
        throw
    }
}

function New-UntisConnectionObject {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$School,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$ApiMode,
        [Parameter(Mandatory)][string]$AuthMethod,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    [pscustomobject]@{
        Key                     = "$Server|$School|$($Credential.UserName)"
        Server                  = $Server
        BaseUri                 = "https://$Server"
        School                  = $School
        UserName                = $Credential.UserName
        Credential              = $Credential
        AuthMethod              = $AuthMethod
        ApiMode                 = $ApiMode
        Settings                = $Settings
        SessionId               = $null
        PersonId                = 0
        PersonType              = 0
        ClassId                 = 0
        ConnectedAt             = $null
        LastActivity            = $null
        ReauthenticationBlocked = $false
    }
}

function Connect-Untis {
    <#
    .SYNOPSIS
        Logs in to WebUntis and starts a session.
    .DESCRIPTION
        Values not given as parameters come from environment variables and then the configuration
        file. The credential comes from -Credential, then from a stored credential, then from a prompt.
        It is kept in memory for the session so UntisPS can log in again when WebUntis drops an idle
        session. Accounts with two-factor authentication cannot use password login; see -Secret.
    .PARAMETER Server
        WebUntis host name, for example example.webuntis.com. A pasted https URL also works.
    .PARAMETER School
        School identifier from the WebUntis login URL.
    .PARAMETER Credential
        User name and password.
    .PARAMETER UserName
        User name for a prompt, or for -Secret.
    .PARAMETER Secret
        Personal app secret from the WebUntis profile, as a SecureString. Uses an undocumented app
        endpoint.
    .PARAMETER ApiMode
        Auto allows fallback to undocumented web-client endpoints. JsonRpc does not.
    .PARAMETER Save
        After a successful login, saves server, school and user name to the configuration file and
        the credential to secure storage.
    .PARAMETER PassThru
        Returns the connection object.
    .EXAMPLE
        Connect-Untis -Server example.webuntis.com -School ExampleSchool
    .EXAMPLE
        Connect-Untis -Server example.webuntis.com -School ExampleSchool -Credential (Get-Credential) -Save
    .OUTPUTS
        UntisPS.Connection, with -PassThru
    #>
    [CmdletBinding(DefaultParameterSetName = 'Password')]
    [OutputType('UntisPS.Connection')]
    param(
        [Parameter(Position = 0)][string]$Server,
        [Parameter(Position = 1)][string]$School,
        [Parameter(ParameterSetName = 'Password')][pscredential]$Credential,
        [Parameter(ParameterSetName = 'Password')]
        [Parameter(ParameterSetName = 'Secret', Mandatory)][string]$UserName,
        [Parameter(ParameterSetName = 'Secret', Mandatory)][securestring]$Secret,
        [ValidateSet('Auto', 'JsonRpc')][string]$ApiMode,
        [switch]$Save,
        [switch]$PassThru
    )
    try {
        $settings = Get-UntisEffectiveConfiguration
        if (-not $Server) { $Server = $settings['Server'] }
        if (-not $School) { $School = $settings['School'] }
        if (-not $ApiMode) { $ApiMode = $settings['ApiMode'] }
        if (-not $UserName) { $UserName = $settings['UserName'] }
        if (-not $Server -or -not $School) {
            throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument `
                    -Message 'Specify -Server and -School, or configure them with Set-UntisConfiguration.')
        }
        $Server = ConvertTo-UntisServerName -Server $Server
        if (-not (Test-UntisSchoolName -School $School)) {
            throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Message 'School must be 1 to 128 printable characters.')
        }
        if ($Server -notmatch '\.webuntis\.com(:\d+)?$') {
            Write-Warning "'$Server' is not a webuntis.com host. Your password will be sent to it; make sure you trust it."
        }

        $authMethod = 'Password'
        if ($Secret) {
            $authMethod = 'Secret'
            $Credential = New-Object System.Management.Automation.PSCredential($UserName, $Secret)
        }
        if (-not $Credential) { $Credential = Get-UntisStoredCredential -Server $Server -School $School }
        if (-not $Credential) {
            $promptParameters = @{ Message = "WebUntis login for $School on $Server" }
            if ($UserName) { $promptParameters['UserName'] = $UserName }
            $Credential = Get-Credential @promptParameters
        }
        if (-not $Credential) {
            throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Message 'No credential was provided.')
        }

        if ($script:UntisConnection) { Disconnect-Untis }
        $connection = New-UntisConnectionObject -Server $Server -School $School -Credential $Credential `
            -ApiMode $ApiMode -AuthMethod $authMethod -Settings $settings
        Invoke-UntisLogin -Connection $connection
        $script:UntisConnection = $connection

        if ($Save) {
            $values = Read-UntisConfigFile
            $values['Server'] = $Server
            $values['School'] = $School
            $values['UserName'] = $Credential.UserName
            Write-UntisConfigFile -Values $values
            if ($authMethod -eq 'Password') { Save-UntisCredential -Server $Server -School $School -Credential $Credential }
            else { Write-Warning '-Secret values are not saved. Keep yours in a SecretManagement vault and pass it in.' }
        }
        if ($PassThru) { Get-UntisConnection }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Disconnect-Untis {
    <#
    .SYNOPSIS
        Logs out and removes the session, credential and cached data from memory.
    .EXAMPLE
        Disconnect-Untis
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    $connection = $script:UntisConnection
    if (-not $connection) {
        Write-Verbose 'No active WebUntis connection.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($connection.Server, 'Log out of WebUntis')) { return }
    try {
        if ($connection.SessionId) { [void](Invoke-UntisRpcRequest -Connection $connection -Method 'logout') }
    } catch {
        Write-Verbose 'Logout request failed; the server will expire the session.'
    }
    $connection.SessionId = $null
    $connection.Credential = $null
    $script:UntisConnection = $null
    Clear-UntisCache -WhatIf:$false
}

function Get-UntisConnection {
    <#
    .SYNOPSIS
        Shows the current connection. Secrets and the session id are never included.
    .EXAMPLE
        Get-UntisConnection
    .OUTPUTS
        UntisPS.Connection
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Connection')]
    param()
    $connection = $script:UntisConnection
    if (-not $connection) { return }
    [pscustomobject]@{
        PSTypeName   = 'UntisPS.Connection'
        Server       = $connection.Server
        School       = $connection.School
        UserName     = $connection.UserName
        AuthMethod   = $connection.AuthMethod
        ApiMode      = $connection.ApiMode
        PersonType   = Get-UntisPersonTypeName -PersonType $connection.PersonType
        PersonId     = $connection.PersonId
        ClassId      = $connection.ClassId
        ConnectedAt  = $connection.ConnectedAt
        LastActivity = $connection.LastActivity
    }
}
