# HTTP transport and API clients.
# HttpClient is used directly on both PowerShell editions: it gives one code path, per-request
# timeouts, no automatic redirects (so a session cookie never follows a redirect) and manual
# control of the Cookie header. Certificate validation is left at the platform default.

$script:UntisRetryStatusCodes = @(408, 429, 500, 502, 503, 504)
$script:UntisMaxRetryAfterSeconds = 60
$script:UntisMaxBackoffMilliseconds = 30000

function Get-UntisHttpClient {
    [CmdletBinding()]
    param()
    if ($script:UntisHttpClient) { return $script:UntisHttpClient }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName System.Net.Http
        # Adds TLS 1.2 where the OS default still excludes it. Nothing is removed or weakened.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    if ($handler.SupportsAutomaticDecompression) {
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $script:UntisHttpClient = $client
    $client
}

function Invoke-UntisHttpRequest {
    <# One HTTP exchange. Non-2xx statuses are returned, only transport failures throw. Bodies and cookies are never logged. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [AllowNull()][string]$Body,
        [hashtable]$Headers = @{},
        [int]$TimeoutSeconds = 30
    )
    $client = Get-UntisHttpClient
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Uri)
    $cancellation = New-Object System.Threading.CancellationTokenSource([timespan]::FromSeconds($TimeoutSeconds))
    $response = $null
    try {
        [void]$request.Headers.TryAddWithoutValidation('User-Agent', "UntisPS/$script:UntisModuleVersion")
        [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json')
        [void]$request.Headers.TryAddWithoutValidation('Cache-Control', 'no-cache')
        [void]$request.Headers.TryAddWithoutValidation('X-Requested-With', 'XMLHttpRequest')
        foreach ($name in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) }
        if ($null -ne $Body) {
            $request.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json')
        }
        Write-Verbose "HTTP $Method $(([System.Uri]$Uri).AbsolutePath)"
        $response = $client.SendAsync($request, $cancellation.Token).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        $setCookies = @()
        if ($response.Headers.Contains('Set-Cookie')) { $setCookies = @($response.Headers.GetValues('Set-Cookie')) }
        $retryAfter = $null
        if ($response.Headers.RetryAfter) {
            if ($null -ne $response.Headers.RetryAfter.Delta) {
                $retryAfter = [int]$response.Headers.RetryAfter.Delta.TotalSeconds
            } elseif ($null -ne $response.Headers.RetryAfter.Date) {
                $retryAfter = [math]::Max(0, [int]($response.Headers.RetryAfter.Date.UtcDateTime - [datetime]::UtcNow).TotalSeconds)
            }
        }
        [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Body       = $text
            SetCookies = $setCookies
            RetryAfter = $retryAfter
        }
    } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $reason = if ($cancellation.IsCancellationRequested) { "timed out after $TimeoutSeconds seconds" } else { Protect-UntisText $inner.Message }
        throw (New-UntisErrorRecord -Kind 'Transport' -Category ConnectionError -Target ([System.Uri]$Uri).Host `
                -Message "Request to $(([System.Uri]$Uri).Host) failed: $reason")
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $cancellation.Dispose()
    }
}

function Wait-UntisRateLimit {
    [CmdletBinding()]
    param([int]$MinimumIntervalMs = 0)
    $now = [datetime]::UtcNow
    $earliest = $script:UntisThrottle.LastRequest.AddMilliseconds($MinimumIntervalMs)
    if ($script:UntisThrottle.NotBefore -gt $earliest) { $earliest = $script:UntisThrottle.NotBefore }
    if ($earliest -gt $now) { Invoke-UntisDelay -Milliseconds ([int]($earliest - $now).TotalMilliseconds) }
    $script:UntisThrottle.LastRequest = [datetime]::UtcNow
}

function Get-UntisBackoffMilliseconds {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$Attempt)
    $base = [math]::Min($script:UntisMaxBackoffMilliseconds, 500 * [math]::Pow(2, $Attempt))
    [int]($base + (Get-Random -Minimum 0 -Maximum 250))
}

function Invoke-UntisHttpWithRetry {
    <# Retries transient failures with exponential backoff and honours Retry-After. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Request,
        [Parameter(Mandatory)][hashtable]$Configuration,
        [string]$Target = 'request'
    )
    $maxRetries = [int]$Configuration['MaxRetries']
    for ($attempt = 0; ; $attempt++) {
        Wait-UntisRateLimit -MinimumIntervalMs ([int]$Configuration['MinRequestIntervalMs'])
        try {
            $response = Invoke-UntisHttpRequest @Request -TimeoutSeconds ([int]$Configuration['TimeoutSeconds'])
        } catch {
            if ((Get-UntisErrorKind $_) -ne 'Transport' -or $attempt -ge $maxRetries) { throw }
            Write-Verbose "Transient failure for $Target; retry $($attempt + 1) of $maxRetries."
            Invoke-UntisDelay -Milliseconds (Get-UntisBackoffMilliseconds -Attempt $attempt)
            continue
        }
        if ($response.StatusCode -notin $script:UntisRetryStatusCodes) { return $response }

        $retryAfter = $response.RetryAfter
        if ($null -ne $retryAfter) { $script:UntisThrottle.NotBefore = [datetime]::UtcNow.AddSeconds($retryAfter) }
        if ($attempt -ge $maxRetries -or ($retryAfter -gt $script:UntisMaxRetryAfterSeconds)) {
            if ($response.StatusCode -eq 429) {
                $wait = if ($null -ne $retryAfter) { " Retry after $retryAfter seconds." } else { '' }
                throw (New-UntisErrorRecord -Kind 'RateLimited' -Category LimitsExceeded -Target $Target -Code 429 -Message "WebUntis is rate limiting this client.$wait")
            }
            throw (New-UntisErrorRecord -Kind 'Http' -Category ConnectionError -Target $Target -Code $response.StatusCode `
                    -Message "WebUntis returned HTTP $($response.StatusCode) for $Target after $($attempt + 1) attempt(s).")
        }
        Write-Verbose "HTTP $($response.StatusCode) for $Target; retry $($attempt + 1) of $maxRetries."
        if ($null -ne $retryAfter) { Invoke-UntisDelay -Milliseconds ($retryAfter * 1000) }
        else { Invoke-UntisDelay -Milliseconds (Get-UntisBackoffMilliseconds -Attempt $attempt) }
    }
}

function Get-UntisCookieHeader {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][pscustomobject]$Connection)
    $schoolBytes = [System.Text.Encoding]::UTF8.GetBytes($Connection.School)
    $schoolCookie = [System.Uri]::EscapeDataString('_' + [System.Convert]::ToBase64String($schoolBytes))
    @{ Cookie = "JSESSIONID=$($Connection.SessionId); schoolname=$schoolCookie" }
}

function Get-UntisRpcUri {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [string]$Path = '/WebUntis/jsonrpc.do',
        [string]$ExtraQuery
    )
    $uri = "$($Connection.BaseUri)$($Path)?school=$([System.Uri]::EscapeDataString($Connection.School))"
    if ($ExtraQuery) { $uri = "$uri&$ExtraQuery" }
    $uri
}

function ConvertFrom-UntisJson {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$Target
    )
    try {
        if (-not $Text) { throw 'empty' }
        return ($Text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw (New-UntisErrorRecord -Kind 'InvalidResponse' -Category InvalidData -Target $Target `
                -Message "WebUntis did not return JSON for $Target. Check -Server and -School; the server may also be in maintenance.")
    }
}

function Get-UntisRpcError {
    <# Maps JSON-RPC error codes. Unlisted codes keep the server's own message. #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)][object]$RpcError,
        [Parameter(Mandatory)][string]$Method
    )
    $code = $RpcError.code
    $serverMessage = Protect-UntisText ([string]$RpcError.message)
    switch ($code) {
        -8504 { return (New-UntisErrorRecord -Kind 'Authentication' -Category AuthenticationError -Target $Method -Code $code -Message "WebUntis rejected the credentials ($serverMessage). Accounts with two-factor authentication cannot use the JSON-RPC API; see docs/AUTHENTICATION.md.") }
        -8520 { return (New-UntisErrorRecord -Kind 'SessionExpired' -Category AuthenticationError -Target $Method -Code $code -Message "The WebUntis session is not valid ($serverMessage).") }
        -8509 { return (New-UntisErrorRecord -Kind 'NoRight' -Category PermissionDenied -Target $Method -Code $code -Message "This account has no right to use '$Method' ($serverMessage). Access is set by the school.") }
        -7004 { return (New-UntisErrorRecord -Kind 'DateNotAllowed' -Category InvalidArgument -Target $Method -Code $code -Message "WebUntis does not allow this date range ($serverMessage). Ranges usually have to stay inside a school year the account can see.") }
        -8507 { return (New-UntisErrorRecord -Kind 'DateNotAllowed' -Category InvalidArgument -Target $Method -Code $code -Message "WebUntis does not allow this date range ($serverMessage). Ranges usually have to stay inside a school year the account can see.") }
        -32601 { return (New-UntisErrorRecord -Kind 'MethodNotFound' -Category NotImplemented -Target $Method -Code $code -Message "This WebUntis server does not offer '$Method' ($serverMessage).") }
    }
    New-UntisErrorRecord -Kind 'Rpc' -Category InvalidResult -Target $Method -Code $code -Message "WebUntis returned error $code for '$Method': $serverMessage"
}

function Invoke-UntisRpcRequest {
    <# Sends a single JSON-RPC call for a given connection without any session recovery. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{}
    )
    $id = [guid]::NewGuid().ToString()
    $body = @{ id = $id; method = $Method; params = $Params; jsonrpc = '2.0' } | ConvertTo-Json -Depth 10 -Compress
    $headers = @{}
    if ($Method -ne 'authenticate' -and $Connection.SessionId) { $headers = Get-UntisCookieHeader -Connection $Connection }
    $request = @{ Method = 'POST'; Uri = (Get-UntisRpcUri -Connection $Connection); Body = $body; Headers = $headers }
    $response = Invoke-UntisHttpWithRetry -Request $request -Configuration $Connection.Settings -Target $Method

    if ($response.StatusCode -ge 300) {
        throw (New-UntisErrorRecord -Kind 'Http' -Category InvalidResult -Target $Method -Code $response.StatusCode `
                -Message "WebUntis returned HTTP $($response.StatusCode) for '$Method'. Check -Server and -School.")
    }
    $envelope = ConvertFrom-UntisJson -Text $response.Body -Target $Method
    if ($envelope.id -and ([string]$envelope.id -ne $id)) {
        throw (New-UntisErrorRecord -Kind 'InvalidResponse' -Category InvalidData -Target $Method -Message "WebUntis answered '$Method' with a mismatched request id.")
    }
    if ($envelope.error) { throw (Get-UntisRpcError -RpcError $envelope.error -Method $Method) }
    if ($null -eq $envelope.PSObject.Properties['result']) {
        throw (New-UntisErrorRecord -Kind 'InvalidResponse' -Category InvalidData -Target $Method -Message "WebUntis sent no result for '$Method'.")
    }
    , $envelope.result
}

function Get-UntisActiveConnection {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    if (-not $script:UntisConnection) {
        throw (New-UntisErrorRecord -Kind 'NotConnected' -Category ConnectionError -Message 'Not connected to WebUntis. Run Connect-Untis first.')
    }
    $script:UntisConnection
}

function Invoke-UntisWithSessionRecovery {
    <# Runs an API call and, if the session expired, logs in again and retries exactly once. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][scriptblock]$Call
    )
    try {
        $result = & $Call
    } catch {
        if ((Get-UntisErrorKind $_) -ne 'SessionExpired') { throw }
        Write-Verbose 'WebUntis session expired; logging in again.'
        Invoke-UntisReauthentication -Connection $Connection
        $result = & $Call
    }
    $Connection.LastActivity = Get-UntisNow
    , $result
}

function Invoke-UntisRpc {
    <# Standard entry point for JSON-RPC: requires a connection, adds caching and session recovery. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$CacheSeconds = 0,
        [switch]$Force
    )
    $connection = Get-UntisActiveConnection
    $cacheKey = "$($connection.Key)|rpc|$Method|$($Params | ConvertTo-Json -Depth 10 -Compress)"
    if ($CacheSeconds -gt 0 -and -not $Force) {
        $cached = Get-UntisCacheEntry -Key $cacheKey
        if ($cached) {
            Write-Verbose "Cache hit for $Method."
            return , $cached.Value
        }
    }
    $result = Invoke-UntisWithSessionRecovery -Connection $connection -Call {
        , (Invoke-UntisRpcRequest -Connection $connection -Method $Method -Params $Params)
    }
    Set-UntisCacheEntry -Key $cacheKey -Value $result -Seconds $CacheSeconds -WhatIf:$false
    , $result
}

function Invoke-UntisWebRequestOnce {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{}
    )
    $pairs = foreach ($key in ($Query.Keys | Sort-Object)) {
        '{0}={1}' -f [System.Uri]::EscapeDataString($key), [System.Uri]::EscapeDataString([string]$Query[$key])
    }
    $uri = "$($Connection.BaseUri)$Path"
    if ($pairs) { $uri = "$uri`?$($pairs -join '&')" }
    $request = @{ Method = 'GET'; Uri = $uri; Headers = (Get-UntisCookieHeader -Connection $Connection) }
    $response = Invoke-UntisHttpWithRetry -Request $request -Configuration $Connection.Settings -Target $Path

    # The web client answers an expired session with 401/403 or a redirect to the login page.
    if ($response.StatusCode -in @(301, 302, 303, 307, 308, 401, 403)) {
        throw (New-UntisErrorRecord -Kind 'SessionExpired' -Category AuthenticationError -Target $Path -Code $response.StatusCode -Message "WebUntis refused '$Path' (HTTP $($response.StatusCode)).")
    }
    if ($response.StatusCode -eq 404) {
        throw (New-UntisErrorRecord -Kind 'MethodNotFound' -Category NotImplemented -Target $Path -Code 404 -Message "This WebUntis server does not offer '$Path'.")
    }
    if ($response.StatusCode -ge 300) {
        throw (New-UntisErrorRecord -Kind 'Http' -Category InvalidResult -Target $Path -Code $response.StatusCode -Message "WebUntis returned HTTP $($response.StatusCode) for '$Path'.")
    }
    $envelope = ConvertFrom-UntisJson -Text $response.Body -Target $Path
    $messageKey = $envelope.data.error.data.messageKey
    if ($messageKey -eq 'ERR_TTVIEW_NOTALLOWED_ONDATE') {
        throw (New-UntisErrorRecord -Kind 'DateNotAllowed' -Category InvalidArgument -Target $Path -Code $messageKey -Message "WebUntis does not allow this date range ($messageKey).")
    }
    if ($messageKey) {
        throw (New-UntisErrorRecord -Kind 'Rpc' -Category InvalidResult -Target $Path -Code $messageKey -Message "WebUntis returned '$messageKey' for '$Path'.")
    }
    if ($null -eq $envelope.data) {
        throw (New-UntisErrorRecord -Kind 'InvalidResponse' -Category InvalidData -Target $Path -Message "WebUntis sent no data for '$Path'.")
    }
    , $envelope.data
}

function Invoke-UntisWebApi {
    <#
    GET against the undocumented endpoints used by the WebUntis web client. Only reachable in ApiMode
    Auto, because these paths can change without notice. A refusal that survives a fresh login means
    the account lacks the permission.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{}
    )
    $connection = Get-UntisActiveConnection
    if ($connection.ApiMode -ne 'Auto') {
        throw (New-UntisErrorRecord -Kind 'NoRight' -Category PermissionDenied -Target $Path -Message "'$Path' is an undocumented web-client endpoint and ApiMode is $($connection.ApiMode). Use ApiMode Auto to allow it.")
    }
    try {
        return (Invoke-UntisWithSessionRecovery -Connection $connection -Call {
                , (Invoke-UntisWebRequestOnce -Connection $connection -Path $Path -Query $Query)
            })
    } catch {
        if ((Get-UntisErrorKind $_) -eq 'SessionExpired') {
            throw (New-UntisErrorRecord -Kind 'NoRight' -Category PermissionDenied -Target $Path -Message "WebUntis refused '$Path' even with a fresh session; this account probably lacks the permission.")
        }
        throw
    }
}
