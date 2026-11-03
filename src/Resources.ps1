# Public master data commands.

function Get-UntisResourceList {
    [CmdletBinding()]
    [OutputType('UntisPS.Resource')]
    param(
        [Parameter(Mandatory)][string]$Type,
        [string]$Name,
        [switch]$Force
    )
    $items = Get-UntisMasterData -Type $Type -Force:$Force
    foreach ($item in $items) {
        $isMatch = (-not $Name) -or ($item.name -like $Name) -or ($item.longName -like $Name) -or
        ($Name -eq [string]$item.id)
        if ($isMatch) { ConvertTo-UntisResource -Raw $item -Type $Type }
    }
}

function Get-UntisSubject {
    <#
    .SYNOPSIS
        Gets subjects.
    .PARAMETER Name
        Short name, long name or id. Wildcards are allowed.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisSubject M*
    .OUTPUTS
        UntisPS.Subject
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Subject')]
    param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    try { Get-UntisResourceList -Type 'Subject' -Name $Name -Force:$Force } catch { $PSCmdlet.ThrowTerminatingError($_) }
}

function Get-UntisTeacher {
    <#
    .SYNOPSIS
        Gets teachers. Many schools refuse this for student accounts.
    .PARAMETER Name
        Short name, long name or id. Wildcards are allowed.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisTeacher Smi*
    .OUTPUTS
        UntisPS.Teacher
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Teacher')]
    param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    try { Get-UntisResourceList -Type 'Teacher' -Name $Name -Force:$Force } catch { $PSCmdlet.ThrowTerminatingError($_) }
}

function Get-UntisRoom {
    <#
    .SYNOPSIS
        Gets rooms.
    .PARAMETER Name
        Short name, long name or id. Wildcards are allowed.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisRoom A1*
    .OUTPUTS
        UntisPS.Room
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Room')]
    param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    try { Get-UntisResourceList -Type 'Room' -Name $Name -Force:$Force } catch { $PSCmdlet.ThrowTerminatingError($_) }
}

function Get-UntisClass {
    <#
    .SYNOPSIS
        Gets classes.
    .PARAMETER Name
        Short name, long name or id. Wildcards are allowed.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisClass 5*
    .OUTPUTS
        UntisPS.Class
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Class')]
    param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    try { Get-UntisResourceList -Type 'Class' -Name $Name -Force:$Force } catch { $PSCmdlet.ThrowTerminatingError($_) }
}

function Get-UntisStudent {
    <#
    .SYNOPSIS
        Gets students. Normally limited to staff accounts.
    .PARAMETER Name
        Short name, long name or id. Wildcards are allowed.
    .PARAMETER Force
        Bypasses the cache.
    .EXAMPLE
        Get-UntisStudent Doe*
    .OUTPUTS
        UntisPS.Student
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Student')]
    param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    try { Get-UntisResourceList -Type 'Student' -Name $Name -Force:$Force } catch { $PSCmdlet.ThrowTerminatingError($_) }
}

function Get-UntisSchoolYear {
    <#
    .SYNOPSIS
        Gets school years.
    .PARAMETER Current
        Only the current school year.
    .EXAMPLE
        Get-UntisSchoolYear -Current
    .OUTPUTS
        UntisPS.SchoolYear
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.SchoolYear')]
    param([switch]$Current)
    try {
        $connection = Get-UntisActiveConnection
        $method = if ($Current) { 'getCurrentSchoolyear' } else { 'getSchoolyears' }
        $rows = Invoke-UntisRpc -Method $method -CacheSeconds ([int]$connection.Settings['MasterDataCacheSeconds'])
        foreach ($row in $rows) {
            [pscustomobject]@{
                PSTypeName = 'UntisPS.SchoolYear'
                Id         = $row.id
                Name       = $row.name
                StartDate  = ConvertFrom-UntisDate -Value $row.startDate
                EndDate    = ConvertFrom-UntisDate -Value $row.endDate
            }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-UntisHoliday {
    <#
    .SYNOPSIS
        Gets school holidays.
    .EXAMPLE
        Get-UntisHoliday | Where-Object EndDate -ge (Get-Date)
    .OUTPUTS
        UntisPS.Holiday
    #>
    [CmdletBinding()]
    [OutputType('UntisPS.Holiday')]
    param()
    try {
        $connection = Get-UntisActiveConnection
        $rows = Invoke-UntisRpc -Method 'getHolidays' -CacheSeconds ([int]$connection.Settings['MasterDataCacheSeconds'])
        foreach ($row in $rows) {
            [pscustomobject]@{
                PSTypeName = 'UntisPS.Holiday'
                Id         = $row.id
                Name       = $row.name
                LongName   = $row.longName
                StartDate  = ConvertFrom-UntisDate -Value $row.startDate
                EndDate    = ConvertFrom-UntisDate -Value $row.endDate
            }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
