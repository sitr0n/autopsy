

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