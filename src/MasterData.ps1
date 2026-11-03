# Master data access and name resolution for classes, teachers, subjects, rooms and students.

$script:UntisElementTypes = @{
    Class   = @{ Code = 1; Method = 'getKlassen' }
    Teacher = @{ Code = 2; Method = 'getTeachers' }
    Subject = @{ Code = 3; Method = 'getSubjects' }
    Room    = @{ Code = 4; Method = 'getRooms' }
    Student = @{ Code = 5; Method = 'getStudents' }
}

function Get-UntisPersonTypeName {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$PersonType)
    switch ($PersonType) {
        2 { 'Teacher' }
        5 { 'Student' }
        0 { 'Unknown' }
        default { "Type$PersonType" }
    }
}

function Get-UntisMasterData {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('Class', 'Teacher', 'Subject', 'Room', 'Student')][string]$Type,
        [switch]$Force
    )
    $connection = Get-UntisActiveConnection
    $seconds = [int]$connection.Settings['MasterDataCacheSeconds']
    $result = Invoke-UntisRpc -Method $script:UntisElementTypes[$Type].Method -CacheSeconds $seconds -Force:$Force
    , @($result)
}

function Resolve-UntisElement {
    <# Turns a name, long name or numeric id into an element for getTimetable. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('Class', 'Teacher', 'Subject', 'Room', 'Student')][string]$Type,
        [Parameter(Mandatory)][string]$Value
    )
    $code = $script:UntisElementTypes[$Type].Code
    $number = 0
    $isNumber = [int]::TryParse($Value, [ref]$number) -and $number -gt 0
    # Names are checked first because rooms and classes are often named with plain numbers.
    try {
        $items = Get-UntisMasterData -Type $Type
    } catch {
        if ($isNumber -and (Get-UntisErrorKind $_) -eq 'NoRight') { return @{ Id = $number; Type = $code; Label = $Value } }
        throw
    }
    $found = @($items | Where-Object { $_.name -eq $Value -or $_.longName -eq $Value })
    if ($found.Count -eq 0 -and $isNumber) { return @{ Id = $number; Type = $code; Label = $Value } }
    if ($found.Count -eq 0) {
        $found = @($items | Where-Object {
                $_.name -like $Value -or $_.longName -like $Value -or
                (($_.foreName) -and ("$($_.foreName) $($_.longName)" -like $Value))
            })
    }
    if ($found.Count -eq 0) {
        throw (New-UntisErrorRecord -Kind 'NotFound' -Category ObjectNotFound -Target $Value -Message "No $($Type.ToLowerInvariant()) named '$Value' was found.")
    }
    if ($found.Count -gt 1) {
        $names = ($found | Select-Object -First 8 | ForEach-Object { $_.name }) -join ', '
        throw (New-UntisErrorRecord -Kind 'Ambiguous' -Category InvalidArgument -Target $Value -Message "'$Value' matches several entries: $names. Use the exact name or the id.")
    }
    @{ Id = [int]$found[0].id; Type = $code; Label = [string]$found[0].name }
}

function Get-UntisLookupItem {
    <#
    Per-command id-to-name lookup. Each list is fetched at most once and only when needed.
    A list the account may not read stays empty, so callers fall back to showing the id.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][object]$Id
    )
    if (-not $Lookup.ContainsKey($Type)) {
        $table = @{}
        try {
            foreach ($item in (Get-UntisMasterData -Type $Type)) { $table[[string]$item.id] = $item }
        } catch {
            if ((Get-UntisErrorKind $_) -notin @('NoRight', 'MethodNotFound')) { throw }
            Write-Verbose "Names for $Type are not available to this account."
        }
        $Lookup[$Type] = $table
    }
    $Lookup[$Type][[string]$Id]
}

function Get-UntisElementDisplayName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$ShortName,
        [AllowNull()][string]$LongName,
        [Parameter(Mandatory)][string]$NameStyle
    )
    if ($NameStyle -eq 'Long' -and $LongName) { return $LongName }
    if ($ShortName) { return $ShortName }
    $LongName
}
