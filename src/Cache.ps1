# In-memory response cache. Nothing is written to disk, so school data does not outlive the session.

function Get-UntisCacheEntry {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Key)
    $entry = $script:UntisCache[$Key]
    if (-not $entry) { return $null }
    if ($entry.Expires -le (Get-UntisNow)) {
        $script:UntisCache.Remove($Key)
        return $null
    }
    $entry
}

function Set-UntisCacheEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][int]$Seconds
    )
    if ($Seconds -le 0) { return }
    if ($PSCmdlet.ShouldProcess($Key, 'Cache response')) {
        $script:UntisCache[$Key] = @{ Value = $Value; Expires = (Get-UntisNow).AddSeconds($Seconds) }
    }
}

function Clear-UntisCache {
    <#
    .SYNOPSIS
        Empties the in-memory response cache.
    .EXAMPLE
        Clear-UntisCache
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    if ($PSCmdlet.ShouldProcess('UntisPS cache', 'Clear')) { $script:UntisCache = @{} }
}
