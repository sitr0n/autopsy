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
    Write-Host "$question`: " -NoNewLine

    $host.UI.RawUI.ForegroundColor = $primary_color
    return Read-Host
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


# Writes a single colored segment without a line break (private helper)
function Write-Segment {
    param(
        [string] $text,
        [System.ConsoleColor] $color = $primary_color,
        [System.ConsoleColor] $background = $backdrop_color
    )

    if ($text -ne '') {
        Write-Host $text -NoNewline -ForegroundColor $color -BackgroundColor $background
    }
}


# Writes the inline markdown of a single line: **bold**, *italic*, _italic_, `code` and [links](url)
function Write-MarkdownInline {
    param(
        [string] $text,
        [System.ConsoleColor] $color = $primary_color
    )

    $pattern = '(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|(?<![\w*])\*[^*\s][^*]*\*(?![\w*])|(?<!\w)_[^_\s][^_]*_(?!\w))'

    foreach ($token in [regex]::Split($text, $pattern)) {

        if ($token -eq '') { continue }

        if ($token -match '^\*\*(.+)\*\*$') {
            Write-Segment $Matches[1] $secondary_accent

        } elseif ($token -match '^`(.+)`$') {
            # Inverted colors make inline code stand out
            Write-Segment $Matches[1] $backdrop_color $primary_color

        } elseif ($token -match '^\[(.+)\]\((.+)\)$') {
            Write-Segment $Matches[1] $primary_accent

        } elseif ($token -match '^[*_](.+)[*_]$') {
            Write-Segment $Matches[1] $primary_accent

        } else {
            Write-Segment $token $color
        }
    }
}


function Show-Markdown {
    <#
    .SYNOPSIS
    Writes markdown text to the host using the module's color scheme.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $markdown
    )
    begin {
        $lines = [System.Collections.Generic.List[string]]::new()
    }

    process {
        
        foreach ($line in ($markdown -split '\r?\n')) {
            $lines.Add($line)
        }
    }

    end {
        $in_code_block = $false

        foreach ($line in $lines) {

            # Code fences
            if ($line -match '^\s*(```|~~~)') {
                $in_code_block = -not $in_code_block
                continue
            }

            if ($in_code_block) {
                Write-Segment "    $line" $primary_accent

            # Headings
            } elseif ($line -match '^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$') {
                Write-MarkdownInline $Matches[1] $primary_accent

            # Horizontal rules
            } elseif ($line -match '^\s{0,3}([-*_])(\s*\1){2,}\s*$') {
                $width = [Math]::Max(3, $host.UI.RawUI.WindowSize.Width - 1)
                Write-Segment ([string][char]0x2500 * $width) $secondary_accent

            # Unordered lists
            } elseif ($line -match '^(\s*)[-*+]\s+(.*)$') {
                $content = $Matches[2]
                Write-Segment "$($Matches[1])  $([char]0x2022) " $secondary_accent
                Write-MarkdownInline $content

            # Ordered lists
            } elseif ($line -match '^(\s*)(\d+)[.)]\s+(.*)$') {
                $content = $Matches[3]
                Write-Segment "$($Matches[1])  $($Matches[2]). " $secondary_accent
                Write-MarkdownInline $content

            # Block quotes
            } elseif ($line -match '^\s*>\s?(.*)$') {
                $content = $Matches[1]
                Write-Segment "  $([char]0x2502) " $secondary_accent
                Write-MarkdownInline $content $primary_accent

            } else {
                Write-MarkdownInline $line
            }

            Write-Host ''
        }
    }
}
Export-ModuleMember -Function Show-Markdown


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