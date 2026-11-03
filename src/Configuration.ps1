# Configuration precedence: command parameter > environment variable > config file > default.
# The config file never holds secrets; see Save-UntisCredential for credential storage.

$script:UntisConfigDefaults = [ordered]@{
    Server                 = $null
    School                 = $null
    UserName               = $null
    ApiMode                = 'Auto'
    DefaultRange           = 'Today'
    NameStyle              = 'Short'
    HideCancelled          = $false
    CacheSeconds           = 60
    MasterDataCacheSeconds = 3600
    TimeoutSeconds         = 30
    MaxRetries             = 3
    MinRequestIntervalMs   = 100
}

$script:UntisConfigEnvironment = @{
    Server       = 'UNTIS_SERVER'
    School       = 'UNTIS_SCHOOL'
    UserName     = 'UNTIS_USERNAME'
    ApiMode      = 'UNTIS_API_MODE'
    CacheSeconds = 'UNTIS_CACHE_SECONDS'
}

function Get-UntisConfigDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:UNTIS_CONFIG_PATH) { return (Split-Path -Parent $env:UNTIS_CONFIG_PATH) }
    if (Test-UntisIsWindows) { return (Join-Path $env:APPDATA 'UntisPS') }
    $base = $env:XDG_CONFIG_HOME
    if (-not $base) { $base = Join-Path $HOME '.config' }
    Join-Path $base 'UntisPS'
}

function Get-UntisConfigPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:UNTIS_CONFIG_PATH) { return $env:UNTIS_CONFIG_PATH }
    Join-Path (Get-UntisConfigDirectory) 'config.json'
}

function Read-UntisConfigFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $values = @{}
    $path = Get-UntisConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $values }
    try {
        $parsed = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Ignoring unreadable UntisPS configuration file '$path'."
        return $values
    }
    foreach ($property in $parsed.PSObject.Properties) {
        if ($script:UntisConfigDefaults.Contains($property.Name)) {
            $values[$property.Name] = $property.Value
        } else {
            Write-Warning "Ignoring unknown setting '$($property.Name)' in '$path'."
        }
    }
    $values
}

function Get-UntisEffectiveConfiguration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $effective = @{}
    foreach ($key in $script:UntisConfigDefaults.Keys) { $effective[$key] = $script:UntisConfigDefaults[$key] }
    $fileValues = Read-UntisConfigFile
    foreach ($key in $fileValues.Keys) { $effective[$key] = $fileValues[$key] }
    foreach ($key in $script:UntisConfigEnvironment.Keys) {
        $value = [Environment]::GetEnvironmentVariable($script:UntisConfigEnvironment[$key])
        if ($value) {
            if ($key -eq 'CacheSeconds') {
                $parsed = 0
                if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge 0) { $effective[$key] = $parsed }
                else { Write-Warning "Ignoring invalid value in environment variable $($script:UntisConfigEnvironment[$key])." }
            } else {
                $effective[$key] = $value
            }
        }
    }
    if ($effective['ApiMode'] -notin @('Auto', 'JsonRpc')) {
        Write-Warning "Unknown ApiMode '$($effective['ApiMode'])'; using Auto."
        $effective['ApiMode'] = 'Auto'
    }
    $effective
}

function Get-UntisConfiguration {
    <#
    .SYNOPSIS
        Shows the effective UntisPS settings.
    .DESCRIPTION
        Combines environment variables, the configuration file and defaults. Parameters given to
        individual commands still take priority over what is shown here.
    .EXAMPLE
        Get-UntisConfiguration
    .OUTPUTS
        UntisPS.Configuration
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Configuration')]
    param()
    $effective = Get-UntisEffectiveConfiguration
    $output = [ordered]@{}
    foreach ($key in $script:UntisConfigDefaults.Keys) { $output[$key] = $effective[$key] }
    $output['ConfigPath'] = Get-UntisConfigPath
    $object = [pscustomobject]$output
    $object.PSObject.TypeNames.Insert(0, 'UntisPS.Configuration')
    $object
}

function Set-UntisConfiguration {
    <#
    .SYNOPSIS
        Saves UntisPS settings to the local configuration file.
    .DESCRIPTION
        Only the parameters you pass are changed. Passwords are not accepted here; use
        Save-UntisCredential for those.
    .PARAMETER Server
        WebUntis host name, for example example.webuntis.com.
    .PARAMETER School
        School identifier as shown in the WebUntis login URL.
    .PARAMETER UserName
        Default user name. Not a secret, but still personal data.
    .PARAMETER ApiMode
        Auto allows fallback to the undocumented web-client endpoints. JsonRpc stays on the JSON-RPC API.
    .PARAMETER DefaultRange
        Range used when a command is called without a date parameter.
    .PARAMETER NameStyle
        Short shows abbreviations such as MA. Long shows full names such as Mathematics.
    .PARAMETER HideCancelled
        Hide cancelled lessons from Get-UntisTimetable.
    .PARAMETER CacheSeconds
        In-memory cache lifetime for timetable data. 0 disables it.
    .PARAMETER MasterDataCacheSeconds
        In-memory cache lifetime for teachers, classes, rooms and subjects. 0 disables it.
    .PARAMETER TimeoutSeconds
        Timeout for each HTTP request.
    .PARAMETER MaxRetries
        Retries after a transient failure. Failed logins are never retried.
    .PARAMETER MinRequestIntervalMs
        Minimum gap between requests.
    .EXAMPLE
        Set-UntisConfiguration -Server example.webuntis.com -School ExampleSchool -NameStyle Long
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('UntisPS.Configuration')]
    param(
        [string]$Server,
        [string]$School,
        [string]$UserName,
        [ValidateSet('Auto', 'JsonRpc')][string]$ApiMode,
        [ValidateSet('Today', 'Tomorrow', 'Week')][string]$DefaultRange,
        [ValidateSet('Short', 'Long')][string]$NameStyle,
        [bool]$HideCancelled,
        [ValidateRange(0, 86400)][int]$CacheSeconds,
        [ValidateRange(0, 604800)][int]$MasterDataCacheSeconds,
        [ValidateRange(1, 300)][int]$TimeoutSeconds,
        [ValidateRange(0, 10)][int]$MaxRetries,
        [ValidateRange(0, 60000)][int]$MinRequestIntervalMs
    )
    if ($PSBoundParameters.ContainsKey('Server')) { $PSBoundParameters['Server'] = ConvertTo-UntisServerName -Server $Server }
    if ($PSBoundParameters.ContainsKey('School') -and -not (Test-UntisSchoolName -School $School)) {
        throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Message 'School must be 1 to 128 printable characters.')
    }
    $values = Read-UntisConfigFile
    foreach ($key in $script:UntisConfigDefaults.Keys) {
        if ($PSBoundParameters.ContainsKey($key)) { $values[$key] = $PSBoundParameters[$key] }
    }
    Write-UntisConfigFile -Values $values
    Get-UntisConfiguration
}

function Write-UntisConfigFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Values)
    $path = Get-UntisConfigPath
    if (-not $PSCmdlet.ShouldProcess($path, 'Write UntisPS configuration')) { return }
    $directory = Split-Path -Parent $path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force -WhatIf:$false | Out-Null
    }
    $temporary = "$path.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporary, ($Values | ConvertTo-Json -Depth 3), $encoding)
    Move-Item -LiteralPath $temporary -Destination $path -Force -WhatIf:$false
}

function Reset-UntisConfiguration {
    <#
    .SYNOPSIS
        Deletes the local configuration file and returns to defaults.
    .EXAMPLE
        Reset-UntisConfiguration
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param()
    $path = Get-UntisConfigPath
    if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Delete UntisPS configuration')) {
        Remove-Item -LiteralPath $path -Force
    }
}
