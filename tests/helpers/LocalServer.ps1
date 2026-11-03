# Small real HTTP server for wire-level tests. Runs in its own runspace on 127.0.0.1 and answers
# like WebUntis does: session cookie checks, an expiring session, a 503 and a 429 with Retry-After.
param()

function global:Start-UntisLocalServer {
    param([Parameter(Mandatory)][string]$FixtureRoot)
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()

    $state = [hashtable]::Synchronized(@{
            Port = $port; FixtureRoot = $FixtureRoot; Stop = $false; Ready = $false; Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            ExpireNext = $false; Fail503 = 0; Fail429 = 0; Fail429Date = 0; Logins = 0
        })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('state', $state)
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript({
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$($state.Port)/")
            $listener.Start()
            $state.Ready = $true
            $sessionId = $null
            while (-not $state.Stop) {
                $pending = $listener.BeginGetContext($null, $null)
                while (-not $pending.AsyncWaitHandle.WaitOne(100)) { if ($state.Stop) { break } }
                if ($state.Stop) { break }
                $context = $listener.EndGetContext($pending)
                $request = $context.Request
                $response = $context.Response
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $cookie = $request.Headers['Cookie']
                $call = if ($body) { $body | ConvertFrom-Json } else { $null }
                [void]$state.Log.Add([pscustomobject]@{ Path = $request.Url.AbsolutePath; Query = $request.Url.Query; Cookie = $cookie; UserAgent = $request.UserAgent; Method = $call.method })

                $status = 200
                $text = ''
                if ($state.Fail503 -gt 0) {
                    $state.Fail503 = $state.Fail503 - 1
                    $status = 503
                } elseif ($state.Fail429 -gt 0) {
                    $state.Fail429 = $state.Fail429 - 1
                    $status = 429
                    $response.Headers.Add('Retry-After', '1')
                } elseif ($state.Fail429Date -gt 0) {
                    $state.Fail429Date = $state.Fail429Date - 1
                    $status = 429
                    $response.Headers.Add('Retry-After', [datetime]::UtcNow.AddSeconds(2).ToString('r'))
                } elseif ($request.Url.AbsolutePath -eq '/slow') {
                    Start-Sleep -Seconds 2
                } elseif ($call.method -eq 'authenticate') {
                    $state.Logins = $state.Logins + 1
                    $sessionId = "LOCAL-SESSION-$($state.Logins)"
                    $text = '{"jsonrpc":"2.0","id":"' + $call.id + '","result":{"sessionId":"' + $sessionId + '","personType":5,"personId":1201,"klasseId":51}}'
                } elseif ($call) {
                    if ($state.ExpireNext) { $state.ExpireNext = $false; $sessionId = 'EXPIRED' }
                    if (-not $cookie -or $cookie -notmatch "JSESSIONID=$sessionId(;|$)") {
                        $text = '{"jsonrpc":"2.0","id":"' + $call.id + '","error":{"code":-8520,"message":"not authenticated"}}'
                    } elseif ($call.method -eq 'getTimetable') {
                        $fixture = Get-Content -LiteralPath (Join-Path $state.FixtureRoot 'timetable.json') -Raw
                        $text = '{"jsonrpc":"2.0","id":"' + $call.id + '","result":' + $fixture + '}'
                    } else {
                        $text = '{"jsonrpc":"2.0","id":"' + $call.id + '","result":{}}'
                    }
                } elseif ($request.Url.AbsolutePath -eq '/WebUntis/api/exams') {
                    if ($cookie -match "JSESSIONID=$sessionId(;|$)") {
                        $text = Get-Content -LiteralPath (Join-Path $state.FixtureRoot 'exams-web.json') -Raw
                    } else {
                        $status = 302
                        $response.Headers.Add('Location', '/WebUntis/index.do')
                    }
                } elseif ($request.Url.AbsolutePath -eq '/redirect') {
                    $status = 302
                    $response.Headers.Add('Location', 'http://127.0.0.1:1/never-followed')
                } else {
                    $status = 404
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                $response.StatusCode = $status
                $response.ContentType = 'application/json; charset=utf-8'
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.Close()
            }
            $listener.Close()
        })
    $handle = $shell.BeginInvoke()
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while (-not $state.Ready -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
    if (-not $state.Ready) { throw 'Local test server did not start.' }
    [pscustomobject]@{ State = $state; Shell = $shell; Runspace = $runspace; Handle = $handle; BaseUri = "http://127.0.0.1:$port" }
}

function global:Stop-UntisLocalServer {
    param([Parameter(Mandatory)]$Server)
    $Server.State.Stop = $true
    [void]$Server.Handle.AsyncWaitHandle.WaitOne(3000)
    $Server.Shell.Dispose()
    $Server.Runspace.Dispose()
}
