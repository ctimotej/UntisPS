# Shared helpers: errors, clock, date conversion, input validation, secret scrubbing.

function New-UntisErrorRecord {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Message,
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::NotSpecified,
        [object]$Target,
        [object]$Code,
        [System.Exception]$InnerException
    )
    $exception = New-Object System.InvalidOperationException($Message, $InnerException)
    $exception.Data['UntisErrorKind'] = $Kind
    if ($null -ne $Code) { $exception.Data['UntisErrorCode'] = $Code }
    New-Object System.Management.Automation.ErrorRecord($exception, "UntisPS.$Kind", $Category, $Target)
}

function Get-UntisErrorKind {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    [string]$ErrorRecord.Exception.Data['UntisErrorKind']
}

function Protect-UntisText {
    <# Removes anything that looks like a credential before text reaches an error or log. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    $Text = $Text -replace '(?i)(JSESSIONID=)[^;\s"'']+', '$1<redacted>'
    $Text = $Text -replace '(?i)("?(sessionId|password|otp|token|secret)"?\s*[:=]\s*"?)[^",;\s}]+', '$1<redacted>'
    $Text = $Text -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+', '$1<redacted>'
    $Text
}

function Get-UntisNow {
    <# Single clock source so tests can pin the current time. #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param()
    [datetime]::Now
}

function Invoke-UntisDelay {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Milliseconds)
    if ($Milliseconds -gt 0) { Start-Sleep -Milliseconds $Milliseconds }
}

function Test-UntisIsWindows {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function ConvertTo-UntisDateNumber {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][datetime]$Date)
    [int]$Date.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-UntisDate {
    <# Accepts yyyyMMdd as number or string; dates arrive in either form depending on the server. #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or "$Value" -eq '' -or "$Value" -eq '0') { return $null }
    if ($Value -is [datetime]) { return $Value.Date }
    [datetime]::ParseExact(
        "$Value".Trim(), 'yyyyMMdd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None)
}

function ConvertFrom-UntisTime {
    <# Combines a date with an Hmm/HHmm value such as 745 or 1430. #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][datetime]$Date,
        [AllowNull()][object]$Time
    )
    if ($null -eq $Time -or "$Time" -eq '') { return $null }
    $number = [int]"$Time"
    $Date.Date.AddHours([math]::Floor($number / 100)).AddMinutes($number % 100)
}

function Resolve-UntisDateRange {
    <# Turns the shared date parameters into a start and end date (inclusive). #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch]$Today,
        [switch]$Tomorrow,
        [switch]$Week,
        [int]$WeekOffset = 0,
        [Nullable[datetime]]$Date,
        [Nullable[datetime]]$FromDate,
        [Nullable[datetime]]$ToDate,
        [ValidateSet('Today', 'Tomorrow', 'Week')][string]$Default = 'Today'
    )
    $now = (Get-UntisNow).Date
    if ($FromDate -or $ToDate) {
        if (-not ($FromDate -and $ToDate)) {
            throw (New-UntisErrorRecord -Kind 'Argument' -Message 'Specify both -FromDate and -ToDate.' -Category InvalidArgument)
        }
        if ($FromDate.Date -gt $ToDate.Date) {
            throw (New-UntisErrorRecord -Kind 'Argument' -Message '-FromDate must not be later than -ToDate.' -Category InvalidArgument)
        }
        return @{ Start = $FromDate.Date; End = $ToDate.Date }
    }
    if ($Date) { return @{ Start = $Date.Date; End = $Date.Date } }
    $selection = $Default
    if ($Today) { $selection = 'Today' } elseif ($Tomorrow) { $selection = 'Tomorrow' } elseif ($Week) { $selection = 'Week' }
    switch ($selection) {
        'Today' { return @{ Start = $now; End = $now } }
        'Tomorrow' { return @{ Start = $now.AddDays(1); End = $now.AddDays(1) } }
        'Week' {
            # ISO week: Monday to Sunday. [DayOfWeek]::Sunday is 0, so shift it to 7.
            $dayNumber = [int]$now.DayOfWeek
            if ($dayNumber -eq 0) { $dayNumber = 7 }
            $monday = $now.AddDays(1 - $dayNumber).AddDays(7 * $WeekOffset)
            return @{ Start = $monday; End = $monday.AddDays(6) }
        }
    }
}

function ConvertTo-UntisServerName {
    <#
    Validates user input and reduces it to a host name. A pasted https:// URL is accepted; any other
    scheme, embedded credentials and bare IP addresses are refused so requests only ever go to a
    named host over verified TLS.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Server)

    $value = $Server.Trim()
    if ($value -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        if ($value -notmatch '^(?i)https://') {
            throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Target $Server `
                    -Message "Server '$Server' does not use HTTPS. UntisPS only connects over HTTPS.")
        }
        $uri = $null
        if (-not [System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri)) {
            throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Target $Server -Message "Server '$Server' is not a valid URL.")
        }
        if ($uri.UserInfo) {
            throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Target 'Server' -Message 'Server URLs must not contain a user name or password.')
        }
        $value = $uri.Authority
    }
    $hostPattern = '^(?=.{1,253}(:|$))([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9](:[0-9]{1,5})?$'
    if ($value -notmatch $hostPattern) {
        throw (New-UntisErrorRecord -Kind 'Configuration' -Category InvalidArgument -Target $Server `
                -Message "Server '$Server' is not a valid host name. Expected something like 'example.webuntis.com'.")
    }
    $value.ToLowerInvariant()
}

function Test-UntisSchoolName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$School)
    ($School.Length -ge 1) -and ($School.Length -le 128) -and ($School -notmatch '[\x00-\x1F\x7F]')
}
