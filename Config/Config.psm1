# Read and write values to and from a file
function Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(ValueFromPipeline)]
        $Value,

        [string]$Path = "$env:APPDATA\TextRegistry.json"
    )


    if (-not (Test-Path -LiteralPath $Path)) {
        '{}' | Set-Content -LiteralPath $Path -Encoding utf8
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8

    # ensure $store is a hashtable on any PowerShell version
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $store = ConvertFrom-Json -InputObject $raw -AsHashtable
        } else {
            $tmp   = $raw | ConvertFrom-Json
            $store = @{}
            foreach ($prop in $tmp.psobject.Properties) {
                $store[$prop.Name] = $prop.Value
            }
        }
    } catch {
        $store = @{}
    }

    if ($PSBoundParameters.ContainsKey('Value')) {
        $store[$Key] = $Value
        $json = $store | ConvertTo-Json -Compress
        $temp = [IO.Path]::GetTempFileName()
        $json | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $Path -Force
        return
    }

    $store[$Key]
}
Export-ModuleMember -Function Config