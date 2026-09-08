

function Open-Session {
    param( [string] $script)
    
    $exe  = (Get-Process -Id $PID).Path
    $argv = @('-NoProfile', '-File', $script) + $args
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
Export-ModuleMember -Function Open-Session


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


function Options {
    [CmdletBinding()]
    param(
        #[Parameter(Mandatory)]
        [string]$Path = $PSCommandPath
    )

    

    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count) {
        throw ("Parse errors:`n" + ($errors | ForEach-Object Message | Out-String))
    }

    $funcs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    $funcs 
    #$funcs | Sort-Object { $_.Extent.StartOffset } | ForEach-Object { $_.Name }
}
Export-ModuleMember -Function Options

function Warn {
    [CmdletBinding()]
    param(
        [string] $message
    )
    
    # Don't throw on empty warnings
    if (-not $message) { return }

    # Display colored warning
    Write-Host $message -ForegroundColor DarkYellow
}
Export-ModuleMember -Function Warn

function Err {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $message
    )

    Write-Host $message -ForegroundColor DarkRed
}
Export-ModuleMember -Function Err


function Get-Psm1ExportedFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [string] $Path
    )

    begin {
        function Test-UnderFunctionDefinition {
            param([System.Management.Automation.Language.Ast] $Ast)

            $p = $Ast.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    return $true
                }
                $p = $p.Parent
            }
            return $false
        }

        function ConvertFrom-CommandArg {
            param([System.Management.Automation.Language.ExpressionAst] $Ast)

            if ($null -eq $Ast) { return @() }

            if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                return @($Ast.Value)
            }

            if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                $Ast.NestedExpressions.Count -eq 0) {
                return @($Ast.Value)
            }

            if ($Ast -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                return @($Ast.Elements | ForEach-Object { ConvertFrom-CommandArg $_ })
            }

            return @()
        }

        function Get-ExportedFunctionPatterns {
            param([System.Management.Automation.Language.CommandAst[]] $Commands)

            $patterns = [System.Collections.Generic.List[string]]::new()

            foreach ($cmd in $Commands) {
                $elements = @($cmd.CommandElements)
                $currentParam = $null

                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $e = $elements[$i]

                    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ('Function'.StartsWith($e.ParameterName, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $currentParam = 'Function'

                            if ($e.Argument) {
                                foreach ($s in ConvertFrom-CommandArg $e.Argument) {
                                    [void] $patterns.Add($s)
                                }
                            }
                        }
                        else {
                            $currentParam = 'Other'
                        }

                        continue
                    }

                    # Positional arguments to Export-ModuleMember bind to -Function.
                    if ($null -eq $currentParam -or $currentParam -eq 'Function') {
                        foreach ($s in ConvertFrom-CommandArg $e) {
                            [void] $patterns.Add($s)
                        }
                    }
                }
            }

            $patterns.ToArray()
        }
    }

    process {
        $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $resolvedPath,
            [ref] $tokens,
            [ref] $parseErrors
        )

        if ($parseErrors) {
            throw ($parseErrors | ForEach-Object {
                "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber): $($_.Message)"
            } | Out-String)
        }

        $functionAsts = @(
            $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) |
            Where-Object { -not (Test-UnderFunctionDefinition $_) } |
            Sort-Object { $_.Extent.StartOffset }
        )

        # If a function is defined more than once, the last definition wins.
        $byName = [System.Collections.Generic.Dictionary[
            string,
            System.Management.Automation.Language.FunctionDefinitionAst
        ]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($f in $functionAsts) {
            $byName[$f.Name] = $f
        }

        $effectiveFunctions = @(
            foreach ($f in $functionAsts) {
                if ([object]::ReferenceEquals($byName[$f.Name], $f)) {
                    $f
                }
            }
        )

        $exportCommands = @(
            $ast.FindAll({
                param($n)

                if ($n -isnot [System.Management.Automation.Language.CommandAst]) {
                    return $false
                }

                $name = $n.GetCommandName()
                if (-not $name) { return $false }

                (($name -split '\\')[-1]) -eq 'Export-ModuleMember'
            }, $true) |
            Where-Object { -not (Test-UnderFunctionDefinition $_) }
        )

        if ($exportCommands.Count -eq 0) {
            $exportedFunctions = $effectiveFunctions
        }
        else {
            $patterns = @(Get-ExportedFunctionPatterns $exportCommands)

            $exportedFunctions = @(
                foreach ($f in $effectiveFunctions) {
                    foreach ($pattern in $patterns) {
                        if ($f.Name -like $pattern) {
                            $f
                            break
                        }
                    }
                }
            )
        }

        foreach ($f in $exportedFunctions) {
            [pscustomobject]@{
                Name        = $f.Name
                ScriptBlock = $f.Body.GetScriptBlock()
                Path        = $resolvedPath
            }
        }
    }
}
Export-ModuleMember -Function Get-Psm1ExportedFunction