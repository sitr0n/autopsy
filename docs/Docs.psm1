
function Get-Functions {
    [CmdletBinding()]
    param(
        #[Parameter(Mandatory)]
        [string] $Path = $PSCommandPath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    $text = Get-Content -LiteralPath $Path -Raw

    # Match optional comment block immediately above a function definition.
    # Supports:
    #   <# ... #> (block comment) directly above function
    #   one or more # line comments directly above function
    $rx = [regex]::new(
@"
(?msx)
(?: ^ \s* function \s+ (?<name> [A-Za-z_][\w\-]* ) \s* (?:\{| \() )
|
(?:
    (?<comment>
        ^ \s* <\# .*? \#> \s* \r?\n
      | (?: ^ \s* \# [^\r\n]* \r?\n )+
    )
    \s*
    ^ \s* function \s+ (?<name2> [A-Za-z_][\w\-]* ) \s* (?:\{| \()
)
"@
    )

    $pairs = foreach ($m in $rx.Matches($text)) {
        if ($m.Groups['name2'].Success) {
            [pscustomobject]@{
                Name    = $m.Groups['name2'].Value
                Comment = $m.Groups['comment'].Value.TrimEnd()
            }
        }
        elseif ($m.Groups['name'].Success) {
            [pscustomobject]@{
                Name    = $m.Groups['name'].Value
                Comment = $null
            }
        }
    }

    # If you only want ones that *have* an above comment, uncomment:
    # $pairs | Where-Object { $_.Comment }

    return $pairs
}
Export-ModuleMember -Function Get-Functions


# Display function information of a script file
function Show-Functions {
    param( [string] $file )

    # Look up information for each function in the script
    foreach ($function in Get-Functions -Path $file) {

        if ($function.Comment) {
            Write-Host $function.Comment.Trim() -ForegroundColor DarkGray
        }



        Write-Host $function.Name.Trim()
        Write-Host
    }
}
Export-ModuleMember -Function Show-Functions

# Display the available functions of a module
function Help([string] $library = $PSCommandPath)
{
    try { # opening the script file
        if ([IO.Path]::IsPathRooted($library)) {
            Show-Functions $library

        } else { # it could be a local module
            $location = Join-Path (Get-Location) $library

            if (Test-Path $location -PathType Container) {
                Show-Functions "$location\$library.psm1"
            }
        }
    } catch { Err $_ }
}
Export-ModuleMember -Function Help