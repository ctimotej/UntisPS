# Absences are personal data, so responses here are never cached.

function Get-UntisAbsence {
    <#
    .SYNOPSIS
        Gets recorded absences in a date range.
    .DESCRIPTION
        Tries the JSON-RPC method getTimetableWithAbsences. If the school does not allow it and ApiMode
        is Auto, it uses the endpoint of the WebUntis web client, limited to the logged-in student. The
        Source property shows which one answered. Without dates the last 30 days are read.
    .PARAMETER FromDate
        First date of the range.
    .PARAMETER ToDate
        Last date of the range.
    .PARAMETER Excused
        Only returns absences WebUntis marks as excused. Needs the web client source.
    .PARAMETER Unexcused
        Only returns absences WebUntis marks as not excused. Needs the web client source.
    .EXAMPLE
        Get-UntisAbsence
    .EXAMPLE
        Get-UntisAbsence -FromDate 2026-09-01 -ToDate 2026-11-30 -Unexcused
    .OUTPUTS
        UntisPS.Absence
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType('UntisPS.Absence')]
    param(
        [datetime]$FromDate,
        [datetime]$ToDate,
        [Parameter(ParameterSetName = 'Excused')][switch]$Excused,
        [Parameter(ParameterSetName = 'Unexcused')][switch]$Unexcused
    )
    try {
        $connection = Get-UntisActiveConnection
        $today = (Get-UntisNow).Date
        if (-not $PSBoundParameters.ContainsKey('ToDate')) { $ToDate = $today }
        if (-not $PSBoundParameters.ContainsKey('FromDate')) { $FromDate = $ToDate.Date.AddDays(-30) }
        if ($FromDate.Date -gt $ToDate.Date) {
            throw (New-UntisErrorRecord -Kind 'Argument' -Category InvalidArgument -Message '-FromDate must not be later than -ToDate.')
        }
        $start = ConvertTo-UntisDateNumber -Date $FromDate
        $end = ConvertTo-UntisDateNumber -Date $ToDate
        $absences = $null
        try {
            $result = Invoke-UntisRpc -Method 'getTimetableWithAbsences' -Params @{ options = @{ startDate = $start; endDate = $end } }
            $lookup = @{}
            $nameStyle = [string]$connection.Settings['NameStyle']
            $absences = foreach ($row in $result.periodsWithAbsences) { ConvertTo-UntisRpcAbsence -Raw $row -Lookup $lookup -NameStyle $nameStyle }
        } catch {
            $kind = Get-UntisErrorKind $_
            if ($kind -notin @('NoRight', 'MethodNotFound') -or $connection.ApiMode -ne 'Auto') { throw }
            if ($connection.PersonId -le 0) { throw }
            Write-Verbose 'getTimetableWithAbsences is not available; using the web client endpoint.'
            $data = Invoke-UntisWebApi -Path '/WebUntis/api/classreg/absences/students' -Query @{
                startDate = $start; endDate = $end; studentId = $connection.PersonId; excuseStatusId = -1
            }
            $absences = foreach ($row in $data.absences) { ConvertTo-UntisWebAbsence -Raw $row }
        }
        if ($Excused) { $absences = $absences | Where-Object { $_.IsExcused -eq $true } }
        if ($Unexcused) { $absences = $absences | Where-Object { $_.IsExcused -eq $false } }
        $absences | Sort-Object -Property StartTime
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
