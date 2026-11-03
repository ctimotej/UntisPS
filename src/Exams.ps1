# Exams: getExams (JSON-RPC) first; in ApiMode Auto the web client's /api/exams is the fallback.

function Get-UntisExam {
    <#
    .SYNOPSIS
        Gets exams in a date range.
    .DESCRIPTION
        Tries the JSON-RPC method getExams. If the school does not allow it and ApiMode is Auto, it
        uses the endpoint of the WebUntis web client, which is undocumented but often open to students
        and returns more detail. The Source property shows which one answered. Without dates the next
        30 days are searched.
    .PARAMETER FromDate
        First date of the range.
    .PARAMETER ToDate
        Last date of the range.
    .PARAMETER Subject
        Only exams whose subject matches. Wildcards are allowed.
    .PARAMETER Class
        Only exams whose class matches. Wildcards are allowed.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisExam
    .EXAMPLE
        Get-UntisExam -FromDate 2026-11-01 -ToDate 2026-11-30
    .OUTPUTS
        UntisPS.Exam
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Exam')]
    param(
        [datetime]$FromDate,
        [datetime]$ToDate,
        [string]$Subject,
        [string]$Class,
        [switch]$Force
    )
    try {
        $connection = Get-UntisActiveConnection
        $today = (Get-UntisNow).Date
        if (-not $PSBoundParameters.ContainsKey('FromDate')) { $FromDate = $today }
        if (-not $PSBoundParameters.ContainsKey('ToDate')) { $ToDate = $FromDate.Date.AddDays(30) }
        if ($FromDate.Date -gt $ToDate.Date) {
            throw (New-UntisErrorRecord -Kind 'Argument' -Category InvalidArgument -Message '-FromDate must not be later than -ToDate.')
        }
        $start = ConvertTo-UntisDateNumber -Date $FromDate
        $end = ConvertTo-UntisDateNumber -Date $ToDate
        $exams = $null
        try {
            $rows = Invoke-UntisRpc -Method 'getExams' -Params @{ startDate = $start; endDate = $end; examTypeId = 0 } `
                -CacheSeconds ([int]$connection.Settings['CacheSeconds']) -Force:$Force
            $lookup = @{}
            $nameStyle = [string]$connection.Settings['NameStyle']
            $exams = foreach ($row in $rows) { ConvertTo-UntisRpcExam -Raw $row -Lookup $lookup -NameStyle $nameStyle }
        } catch {
            $kind = Get-UntisErrorKind $_
            if ($kind -notin @('NoRight', 'MethodNotFound') -or $connection.ApiMode -ne 'Auto') { throw }
            Write-Verbose 'getExams is not available; using the web client endpoint.'
            $data = Invoke-UntisWebApi -Path '/WebUntis/api/exams' -Query @{
                startDate = $start; endDate = $end; klasseId = -1; withGrades = 'false'
            }
            $exams = foreach ($row in $data.exams) { ConvertTo-UntisWebExam -Raw $row }
        }
        $exams | Where-Object {
            (-not $Subject -or $_.Subject -like $Subject) -and (-not $Class -or $_.Class -like "*$Class*")
        } | Sort-Object -Property StartTime
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
