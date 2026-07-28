

function Get-FileInfo {
    <#
    .SYNOPSIS
    Gets basic information about a local file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, HelpMessage = 'The local filesystem path.')]
        [string] $Path
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop

    @{
        path          = $item.FullName
        length        = $item.Length
        lastWriteTime = $item.LastWriteTimeUtc
    }
}
Export-ModuleMember -Function Get-FileInfo


function Execute-Command
{
    param (
        [string] $command
    )

    try {
        $result = Invoke-Expression $command -ErrorAction Stop | Out-String
        return $result.TrimEnd()
    } catch {
        Write-Host "Error executing command: $_" -ForegroundColor Red
        return $null
    }
}
#Export-ModuleMember -Function Execute-Command