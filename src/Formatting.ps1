# Text renderings of timetable entries. Default table views live in UntisPS.Format.ps1xml.

function Format-UntisAgenda {
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]]$Entries)
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    foreach ($day in ($Entries | Group-Object -Property { $_.Date.ToString('yyyy-MM-dd') } | Sort-Object Name)) {
        $first = $day.Group[0]
        $first.Date.ToString('dddd, yyyy-MM-dd', $culture)
        foreach ($entry in ($day.Group | Sort-Object StartTime)) {
            $line = '  {0}-{1}  {2,-8} {3,-10} {4,-8}' -f $entry.StartTime.ToString('HH:mm'), $entry.EndTime.ToString('HH:mm'),
            $entry.Subject, $entry.Teacher, $entry.Room
            if ($entry.Status -ne 'Normal') { $line = "$line [$($entry.Status)]" }
            $line.TrimEnd()
        }
    }
}

function Format-UntisWeekGrid {
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]]$Entries)
    $days = @($Entries | Group-Object -Property { $_.Date.ToString('yyyy-MM-dd') } | Sort-Object Name)
    $slots = @($Entries | ForEach-Object { $_.StartTime.ToString('HH:mm') } | Sort-Object -Unique)
    $headers = @('Time') + @($days | ForEach-Object { $_.Group[0].Date.ToString('ddd dd.MM.', [System.Globalization.CultureInfo]::CurrentCulture) })
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($slot in $slots) {
        $cells = New-Object System.Collections.Generic.List[string]
        $cells.Add($slot)
        foreach ($day in $days) {
            $names = foreach ($entry in ($day.Group | Where-Object { $_.StartTime.ToString('HH:mm') -eq $slot })) {
                if ($entry.IsCancelled) { "($($entry.Subject))" }
                elseif ($entry.Status -ne 'Normal') { "$($entry.Subject)*" }
                else { $entry.Subject }
            }
            $cells.Add((@($names) -join '/'))
        }
        $rows.Add($cells.ToArray())
    }
    $widths = for ($column = 0; $column -lt $headers.Count; $column++) {
        $widest = ([string]$headers[$column]).Length
        foreach ($row in $rows) {
            if (([string]$row[$column]).Length -gt $widest) { $widest = ([string]$row[$column]).Length }
        }
        $widest
    }
    $renderRow = {
        param($values)
        $parts = for ($column = 0; $column -lt $values.Count; $column++) { ([string]$values[$column]).PadRight($widths[$column]) }
        ($parts -join ' | ').TrimEnd()
    }
    & $renderRow $headers
    ($widths | ForEach-Object { '-' * $_ }) -join '-+-'
    foreach ($row in $rows) { & $renderRow $row }
    ''
    '(x) cancelled   x* changed'
}

function Format-UntisTimetable {
    <#
    .SYNOPSIS
        Renders timetable entries as readable text.
    .DESCRIPTION
        Takes the output of Get-UntisTimetable and returns text lines. Use it at the end of a pipeline,
        because the result is strings and not objects. Agenda lists lessons by day. Week draws a grid
        with one column per day.
    .PARAMETER InputObject
        Timetable entries.
    .PARAMETER View
        Agenda or Week.
    .EXAMPLE
        Get-UntisTimetable -Week | Format-UntisTimetable -View Week
    .EXAMPLE
        Get-UntisTimetable -Today | Format-UntisTimetable
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][psobject]$InputObject,
        [ValidateSet('Agenda', 'Week')][string]$View = 'Agenda'
    )
    begin { $entries = New-Object System.Collections.Generic.List[object] }
    process {
        if ($InputObject.PSObject.TypeNames -notcontains 'UntisPS.TimetableEntry') {
            $PSCmdlet.ThrowTerminatingError((New-UntisErrorRecord -Kind 'Argument' -Category InvalidType -Target $InputObject -Message 'Format-UntisTimetable accepts output from Get-UntisTimetable.'))
        }
        $entries.Add($InputObject)
    }
    end {
        if ($entries.Count -eq 0) { return }
        if ($View -eq 'Week') { Format-UntisWeekGrid -Entries $entries.ToArray() }
        else { Format-UntisAgenda -Entries $entries.ToArray() }
    }
}
