function Restart {
    [CmdletBinding()]
    param([switch]$Elevated)
    $exe  = (Get-Process -Id $PID).Path
    $argv = @('-NoProfile', '-File', $PSCommandPath) + $args
    $splat = @{
        FilePath         = $exe
        ArgumentList     = $argv
        WorkingDirectory = (Get-Location)
        NoNewWindow      = $true
        PassThru         = $true
        Wait             = $true
    }
    if ($Elevated) { $splat['Verb'] = 'RunAs' }
    $p = Start-Process @splat
    exit $p.ExitCode
}
Export-ModuleMember -Function Restart


# List available colors
function Colors {

    # For each console color
    [Enum]::GetValues([System.ConsoleColor]) | ForEach-Object {

        # Showcase name in its color
        Write-Host "$_" -ForegroundColor $_
    }
}
Export-ModuleMember -Function Colors


function Timed-Run {
    [CmdletBinding()]
    param(
        [string]$app,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$args
    )
    $out = Join-Path $env:TEMP "$app.out"
    $err = Join-Path $env:TEMP "$app.err"

    if ($args) {
        #Write-Host "got args.."
        $p = Start-Process $app -ArgumentList $args `
            -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru

        #pause
    } else {
        #Write-Host "no args.. $app"
        $p = Start-Process $app `
            -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    }

    # open with shared read to avoid file locks
    $fsOut = [System.IO.File]::Open($out,'OpenOrCreate','Read','ReadWrite')
    $fsErr = [System.IO.File]::Open($err,'OpenOrCreate','Read','ReadWrite')
    $srOut = New-Object System.IO.StreamReader($fsOut)
    $srErr = New-Object System.IO.StreamReader($fsErr)

    # Loop while the application is running
    $start = Get-Date
    try { while (-not $p.HasExited) {

            # Measure the time spent running the application
            $duration = (Get-Date) - $start
            $timer = $duration.ToString("mm\:ss")

            # Cancel application when 'Escape' is pressed
            if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Escape')) {
                
                # Display status cancelled
                Write-Host "[$timer] $app $args " -ForegroundColor Red
                throw
            }


            Write-Host "[$timer] $app $args " -ForegroundColor Blue
            Start-Sleep -Milliseconds 100

            if ([Console]::CursorTop -gt 0) {
                $y = [Console]::CursorTop - 1
                [Console]::SetCursorPosition(0, $y)
                [Console]::Write("".PadRight([Console]::WindowWidth))
                [Console]::SetCursorPosition(0, $y)
            }

            # read newly appended chunks without blocking
            if (-not $srOut.EndOfStream) {
                $chunk = $srOut.ReadToEnd()
                if ($chunk -and ( Config verbose ) -eq $true ) { Write-Host $chunk -NoNewline}
            }
            if (-not $srErr.EndOfStream) {
                $chunk = $srErr.ReadToEnd()
                if ($chunk) { Write-Host $chunk -NoNewline -ForegroundColor Red}
            } 
        }

        # final drain
        $rem = $srOut.ReadToEnd(); if ($rem) { Write-Host $rem -NoNewline }
        $rem = $srErr.ReadToEnd(); if ($rem) { Write-Host $rem -NoNewline -ForegroundColor Red }
    
    # Exit when user has pressed 'Esc'
    } catch { throw $_
    
    # Clean up output files
    } finally { $srOut.Close(); $srErr.Close(); $fsOut.Close(); $fsErr.Close() }

    $p.WaitForExit()
    $p.Refresh()

    Write-Host "[$timer] $app $args $($p.ExitCode)" -ForegroundColor Green
}
Export-ModuleMember -Function Timed-Run


# TODO: Fix exit code reading
function Run {
    [CmdletBinding()] # Discontinue multi word inputs
    param(
        [string]$app,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$args
    )

    # Find the build output directory
    $root = Split-Path (Find-GitRoot) -Parent
    $build_directory = Get-ChildItem -Path $root -Directory -Recurse -Filter 'build' -Force -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $build_directory) {
        Write-Host "build directory not found" -ForegroundColor Red
        return
    }

    $exe = Join-Path $build_directory "$(Config build-type)\apps\$app\Debug\$app.exe"
    if (-not (Test-Path $exe)) {
        Write-Host "executable not found: $exe" -ForegroundColor Red
        return
    }


    $out = Join-Path $env:TEMP "worker.out"
    $err = Join-Path $env:TEMP "worker.err"

    if ($args) {
        $p = Start-Process $exe -ArgumentList $args `
            -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    } else {
        $p = Start-Process $exe `
            -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    }

    # open with shared read to avoid file locks
    $fsOut = [System.IO.File]::Open($out,'OpenOrCreate','Read','ReadWrite')
    $fsErr = [System.IO.File]::Open($err,'OpenOrCreate','Read','ReadWrite')
    $srOut = New-Object System.IO.StreamReader($fsOut)
    $srErr = New-Object System.IO.StreamReader($fsErr)

    #Clear-Host
    $start = Get-Date
    try {
        while (-not $p.HasExited) {

            $duration = (Get-Date) - $start
            $timer = $duration.ToString("mm\:ss")
            Write-Host "[$timer] $( Split-Path $exe -Leaf) " -ForegroundColor Blue
            Start-Sleep -Milliseconds 100

            if ([Console]::CursorTop -gt 0) {
                $y = [Console]::CursorTop - 1
                [Console]::SetCursorPosition(0, $y)
                [Console]::Write("".PadRight([Console]::WindowWidth))
                [Console]::SetCursorPosition(0, $y)
            }

            # read newly appended chunks without blocking
            if (-not $srOut.EndOfStream) {
                $chunk = $srOut.ReadToEnd()
                if ($chunk) { Write-Host $chunk -NoNewline}
            }
            if (-not $srErr.EndOfStream) {
                $chunk = $srErr.ReadToEnd()
                if ($chunk) { Write-Host $chunk -NoNewline -ForegroundColor Red}
            }
        }

        # final drain
        $rem = $srOut.ReadToEnd(); if ($rem) { Write-Host $rem -NoNewline }
        $rem = $srErr.ReadToEnd(); if ($rem) { Write-Host $rem -NoNewline -ForegroundColor Red }
    }
    catch {
        Write-Host "Exception: $_"
    }
    finally {
        $srOut.Close(); $srErr.Close(); $fsOut.Close(); $fsErr.Close()
    }

    $p.WaitForExit()
    $p.Refresh()

    Write-Host "[$timer] $( Split-Path $exe -Leaf) $($p.ExitCode)" -ForegroundColor Green
}
Export-ModuleMember -Function Run


function Set-ConsoleLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [int]$LineOffset = 0,

        [Parameter(Mandatory = $false)]
        [ConsoleColor]$Color = $Host.UI.RawUI.ForegroundColor
    )

    # Save current cursor and color
    $rawUI     = $Host.UI.RawUI
    $origPos   = $rawUI.CursorPosition
    $origColor = $rawUI.ForegroundColor

    try {
        # Calculate target position
        $targetPos = $origPos
        $targetPos.Y = [Math]::Max(0, $origPos.Y + $LineOffset)
        $targetPos.X = 0

        # Move cursor
        $rawUI.CursorPosition = $targetPos

        # Set color and write text, overwriting the line
        $rawUI.ForegroundColor = $Color
        $width = $rawUI.WindowSize.Width

        # Pad / trim to fill the line so previous content is overwritten
        $lineText = $Text
        if ($lineText.Length -lt $width) {
            $lineText = $lineText.PadRight($width)
        } else {
            $lineText = $lineText.Substring(0, $width)
        }

        [Console]::Write($lineText)

        # Restore cursor to original line (start of it)
        $rawUI.CursorPosition = $origPos
    }
    finally {
        # Restore original color
        $rawUI.ForegroundColor = $origColor
    }
}
Export-ModuleMember -Function Set-ConsoleLine


function Prompt-Selection {
    [CmdletBinding()]
    param(
        [String[]]$pool = @(),
        [string]$active = ""
    )

    if ($pool.count -lt 1) {
        return
    }

    for ($i = 0; $i -lt $pool.count; $i++) {
        $item = $pool[$i]

        if ($active -eq $item) {
            $branch_index = $i
        }
        
        Write-Host $item
    }

    # Highlight the current item
    if ($null -ne $branch_index) {

        $line = $pool[$branch_index]
        Set-ConsoleLine $line -Color Cyan -LineOffset ($branch_index - $pool.Count)
    }

    # For each keyboard press
    while (-not [Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true).Key

        if (($key -eq 'UpArrow' -or $key -eq 'W') -and $branch_index -gt 0) {

            if ($null -ne $branch_index) {

                $line = $pool[$branch_index]
                Set-ConsoleLine $line -LineOffset ($branch_index - $pool.Count)

                $branch_index--
            } else {
                $branch_index = 0
            }

            $line = $pool[$branch_index]
            Set-ConsoleLine $line -Color Cyan -LineOffset ($branch_index - $pool.Count)
        }
        
        if (($key -eq 'DownArrow' -or $key -eq 'S') -and $branch_index -lt $pool.Count - 1) {

            if ($null -ne $branch_index) {

                # Reset current line
                $line = $pool[$branch_index]
                Set-ConsoleLine $line -LineOffset ($branch_index - $pool.Count)

                $branch_index++
            } else {
                $branch_index = 0
            }

            $line = $pool[$branch_index]
            Set-ConsoleLine $line -Color Cyan -LineOffset ($branch_index - $pool.Count)
        }

        # Checkout the selected branch
        if ($key -eq 'Enter' -and $null -ne $branch_index) {

            return $pool[$branch_index]
        }

        if ($key -eq 'Escape') {
            
            if ($null -ne $branch_index) {
                $line = $pool[$branch_index]
                Set-ConsoleLine $line -LineOffset ($branch_index - $pool.Count)
            }

            return
        }
    }
}
Export-ModuleMember -Function Prompt-Selection


function Get-MatchingFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$NameFragment,
        [string]$Extension
    )

    $filter = "*$NameFragment*"
    Get-ChildItem -LiteralPath $Directory -Include $Extension -Recurse -File -Filter $filter |

        Where-Object { $_.FullName -notmatch '(?i)(\\|/)build(\\|/)' } |
        Select-Object -ExpandProperty FullName
}
Export-ModuleMember -Function Get-MatchingFiles


function Read-Input {
    param (
        [string] $message = (Split-Path -Leaf $pwd),
        [System.ConsoleColor] $color = [System.ConsoleColor]::Green
    )

    $host.UI.RawUI.ForegroundColor = $color
    $prompt = Read-Host $message
    $host.UI.RawUI.ForegroundColor = [System.ConsoleColor]::White

    return $prompt
}
Export-ModuleMember -Function Read-Input