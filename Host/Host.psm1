using module .\Sounds.psm1
using module .\Window.psm1
using module .\Windows.psm1

$primary_color = [System.ConsoleColor]::White
$backdrop_color = [System.ConsoleColor]::Black
$primary_accent = [System.ConsoleColor]::Cyan
$secondary_accent = [System.ConsoleColor]::Magenta


function Ask-User {
    <#
    .SYNOPSIS
    Prompts the user to give an input.
    #>
    param(
        [string] $question
    )

    Play "new_message"
    $host.UI.RawUI.ForegroundColor = $secondary_accent
    $answer = Read-Host $question

    $host.UI.RawUI.ForegroundColor = $primary_color
    return $answer
}
Export-ModuleMember -Function Ask-User


function Ask-Selection {
    <#
    .SYNOPSIS
    Prompts the user to choose in a multiple choice question.
    #>
    [CmdletBinding()]
    param(
        [String[]]$choices = @(),
        [string]$active = ""
    )

    if ($choices.count -lt 1) {
        return
    }

    for ($i = 0; $i -lt $choices.count; $i++) {
        $item = $choices[$i]

        if ($active -eq $item) {
            $branch_index = $i
        }
        
        Write-Host $item
    }

    # Highlight the current item
    if ($null -ne $branch_index) {

        $line = $choices[$branch_index]
        Set-ConsoleLine $line -Color Cyan -LineOffset ($branch_index - $choices.Count)
    }

    # For each keyboard press
    while (-not [Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true).Key

        if (($key -eq 'UpArrow' -or $key -eq 'W') -and $branch_index -gt 0) {

            if ($null -ne $branch_index) {

                $line = $choices[$branch_index]
                Set-ConsoleLine $line -LineOffset ($branch_index - $choices.Count)

                $branch_index--
            } else {
                $branch_index = 0
            }

            $line = $choices[$branch_index]
            Set-ConsoleLine $line -Color Cyan -LineOffset ($branch_index - $choices.Count)
        }
        
        if (($key -eq 'DownArrow' -or $key -eq 'S') -and $branch_index -lt $choices.Count - 1) {

            if ($null -ne $branch_index) {

                # Reset current line
                $line = $choices[$branch_index]
                Set-ConsoleLine $line -LineOffset ($branch_index - $choices.Count)

                $branch_index++
            } else {
                $branch_index = 0
            }

            $line = $choices[$branch_index]
            Set-ConsoleLine $line -Color Cyan -LineOffset ($branch_index - $choices.Count)
        }

        # Checkout the selected branch
        if ($key -eq 'Enter' -and $null -ne $branch_index) {

            return $choices[$branch_index]
        }

        if ($key -eq 'Escape') {
            
            if ($null -ne $branch_index) {
                $line = $choices[$branch_index]
                Set-ConsoleLine $line -LineOffset ($branch_index - $choices.Count)
            }

            return
        }
    }
}
Export-ModuleMember -Function Ask-Selection


function Exit-Session {
    <#
    .SYNOPSIS
    Ends this session and starts a new one.
    #>
    param( [string] $message)
    
    $exe  = (Get-Process -Id $PID).Path
    $argv = @('-NoProfile', '-File', $message) + $args
    $splat = @{
        FilePath         = $exe
        ArgumentList     = $argv
        WorkingDirectory = (Get-Location)
        NoNewWindow      = $true
        PassThru         = $true
        Wait             = $true
    }
    $p = Start-Process @splat
    exit $p.ExitCode
}
Export-ModuleMember -Function Exit-Session


# Make this script available in the Windows Explorer context menu
function Install-Shortcut
{
    <#
    .SYNOPSIS
    Puts a shortcut to this script on the users desktop.
    #>

    # Modifying the Windows Registry requires admin privileges
    if (Test-IsElevated) { New-ContextScript $PSCommandPath 'Autopsy' -Icon "209"

    } else {
        Write-Warning "Installation needs to be run as administrator"
        Run-Elevated $PSCommandPath
    }
}
Export-ModuleMember -Function Install-Shortcut