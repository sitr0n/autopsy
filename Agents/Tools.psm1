# Only export this function if it's strictly needed, but prefer creating clear purpose tool functions
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



function Replace-InFile {
    <#
    .SYNOPSIS
        Replaces exactly one literal occurrence of old_text with new_text in a file.
    .DESCRIPTION
        Throws if old_text is not found or is found more than once. The file is
        left unchanged on failure. Matching is exact: case-sensitive, not regex.
        The file's encoding and BOM are kept as they were.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$path,

        [Parameter(Mandatory)]
        [string]$old_text,          # Mandatory already rejects empty strings

        [Parameter(Mandatory)]
        [AllowEmptyString()]        # allow deleting text by replacing with ""
        [string]$new_text
    )

    # Get the full path. .NET methods use the process's working directory, not $PWD.
    $fullPath = (Resolve-Path -LiteralPath $path -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Replace-InFile: '$fullPath' is not a file."
    }

    # --- Read the file and detect its encoding from the BOM ---
    $bytes  = [System.IO.File]::ReadAllBytes($fullPath)
    $bomLen = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $encoding = [System.Text.UTF32Encoding]::new($false, $true); $bomLen = 4
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.UTF8Encoding]::new($true, $true); $bomLen = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $true); $bomLen = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $true); $bomLen = 2
    }
    else {
        # No BOM: assume UTF-8 without a BOM. Throw on invalid bytes instead of corrupting the file.
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    }

    try {
        $text = $encoding.GetString($bytes, $bomLen, $bytes.Length - $bomLen)
    }
    catch {
        throw "Replace-InFile: '$fullPath' could not be decoded as $($encoding.EncodingName): $($_.Exception.Message)"
    }

    # --- Count occurrences (ordinal = exact, case-sensitive, no regex) ---
    $ordinal = [System.StringComparison]::Ordinal
    $first   = $text.IndexOf($old_text, $ordinal)
    if ($first -lt 0) {
        throw "Replace-InFile: old_text was not found in '$fullPath'."
    }

    $count = 0
    $i = 0
    while (($i = $text.IndexOf($old_text, $i, $ordinal)) -ge 0) {
        $count++
        $i++          # step by 1 so overlapping matches are counted too
    }
    if ($count -gt 1) {
        throw "Replace-InFile: old_text was found $count times in '$fullPath'; it must appear exactly once. Add more surrounding text to make it unique."
    }

    # --- Replace using the index (no -replace, so no regex or '$' surprises) ---
    $result = $text.Substring(0, $first) + $new_text + $text.Substring($first + $old_text.Length)

    if ($PSCmdlet.ShouldProcess($fullPath, "Replace 1 occurrence of text")) {
        # WriteAllText writes the encoding's BOM only if the original file had one
        [System.IO.File]::WriteAllText($fullPath, $result, $encoding)
        $lineNo = $text.Substring(0, $first).Split("`n").Count
        $msg = "Replaced 1 occurrence at line $lineNo (character offset $first) in '$fullPath'."
        Write-Verbose $msg
        return $msg
    }
}
Export-ModuleMember -Function Replace-InFile


function Write-File {
    <#
    .SYNOPSIS
        Creates or overwrites a file. If the file already exists, keeps its encoding
        (UTF-8 with or without BOM, UTF-16 LE/BE, UTF-32 LE/BE, or ANSI) and line endings (CRLF/LF).
    .EXAMPLE
        Write-File -Path .\config.ini -Content "a=1`nb=2`n"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [AllowEmptyString()]
        [string]$Content
    )

    # Get the full path relative to the current PowerShell location (.NET uses the process folder instead)
    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

    # Defaults for new files: UTF-8 without BOM, line endings left as given
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $newline  = $null

    if ([System.IO.File]::Exists($fullPath)) {
        $bytes  = [System.IO.File]::ReadAllBytes($fullPath)
        $bomLen = 0

        # --- Detect encoding from the BOM (check UTF-32 before UTF-16, since both start with FF FE) ---
        if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
            $encoding = New-Object System.Text.UTF32Encoding($false, $true); $bomLen = 4   # UTF-32 LE
        }
        elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
            $encoding = New-Object System.Text.UTF32Encoding($true, $true); $bomLen = 4    # UTF-32 BE
        }
        elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encoding = New-Object System.Text.UTF8Encoding($true); $bomLen = 3            # UTF-8 with BOM
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = New-Object System.Text.UnicodeEncoding($false, $true); $bomLen = 2 # UTF-16 LE
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encoding = New-Object System.Text.UnicodeEncoding($true, $true); $bomLen = 2  # UTF-16 BE
        }
        else {
            # No BOM: if the bytes are valid UTF-8, treat as UTF-8 without BOM; otherwise use the ANSI code page
            try {
                $strict = New-Object System.Text.UTF8Encoding($false, $true)   # throws on invalid bytes
                $null = $strict.GetString($bytes)
                $encoding = New-Object System.Text.UTF8Encoding($false)
            }
            catch {
                $ansiCp   = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
                $encoding = [System.Text.Encoding]::GetEncoding($ansiCp)
            }
        }

        # --- Detect line endings (whichever style appears most) ---
        $text  = $encoding.GetString($bytes, $bomLen, $bytes.Length - $bomLen)
        $crlf  = [regex]::Matches($text, "`r`n").Count
        $lf    = [regex]::Matches($text, "(?<!`r)`n").Count
        if ($crlf -gt 0 -or $lf -gt 0) {
            $newline = if ($crlf -ge $lf) { "`r`n" } else { "`n" }
        }
    }

    # --- Change the content's line endings to match the existing file ---
    if ($newline) {
        $Content = ($Content -replace "`r`n", "`n") -replace "`n", $newline
    }

    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write file')) { return }

    # Create the parent folder if it's missing
    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }

    # --- Write the BOM (if any) and the content ---
    $preamble = $encoding.GetPreamble()          # empty for UTF-8 without BOM and for ANSI
    $body     = $encoding.GetBytes($Content)

    # OpenOrCreate + SetLength(0) works on hidden files, unlike File.Create/WriteAllText
    $fs = New-Object System.IO.FileStream($fullPath, [System.IO.FileMode]::OpenOrCreate,
                                          [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.SetLength(0)
        $fs.Write($preamble, 0, $preamble.Length)
        $fs.Write($body, 0, $body.Length)
    }
    finally {
        $fs.Dispose()
    }
}
Export-ModuleMember -Function Write-File


function Insert-Lines {
    <#
    .SYNOPSIS
        Inserts one or more lines into a text file at a given line position.

    .PARAMETER Path
        The file to edit.

    .PARAMETER LineNumber
        1-based line position. The new content is inserted BEFORE this line,
        so the first inserted line ends up with this number.
        Use (line count + 1) to append to the end of the file.

    .PARAMETER Content
        The text to insert. This can be a single string (which may contain
        line breaks) or an array of strings.

    .EXAMPLE
        Insert-Lines -Path .\app.config -LineNumber 3 -Content '<add key="x" value="1" />'

    .EXAMPLE
        Insert-Lines .\script.ps1 1 "#Requires -Version 5.1", "Set-StrictMode -Version Latest"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$LineNumber,

        [Parameter(Mandatory, Position = 2, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]]$Content
    )

    begin   { $collected = [System.Collections.Generic.List[string]]::new() }
    process { $collected.AddRange($Content) }

    end {
        $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

        # Read the file and detect its encoding (checks for a BOM, defaults to UTF-8 without BOM)
        $reader = [System.IO.StreamReader]::new($fullPath, [System.Text.UTF8Encoding]::new($false), $true)
        try {
            $text     = $reader.ReadToEnd()
            $encoding = $reader.CurrentEncoding
        }
        finally { $reader.Dispose() }

        # Keep the file's existing line-ending style and trailing newline
        $newline = if ($text -match "`r`n") { "`r`n" }
                   elseif ($text -match "`n") { "`n" }
                   else { [Environment]::NewLine }
        $hasTrailingNewline = $text.EndsWith("`n")

        # Split the file into lines
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($text.Length -gt 0) {
            $lines.AddRange([string[]]($text -split "\r?\n"))
            if ($hasTrailingNewline) { $lines.RemoveAt($lines.Count - 1) }
        }

        if ($LineNumber -gt $lines.Count + 1) {
            throw "LineNumber $LineNumber is out of range. '$fullPath' has $($lines.Count) line(s); the maximum allowed is $($lines.Count + 1)."
        }

        # Split any multi-line strings in Content into separate lines
        $newLines = [string[]]@($collected | ForEach-Object { $_ -split "\r?\n" })

        $lines.InsertRange($LineNumber - 1, $newLines)

        $result = $lines -join $newline
        if ($hasTrailingNewline) { $result += $newline }

        if ($PSCmdlet.ShouldProcess($fullPath, "Insert $($newLines.Count) line(s) at line $LineNumber")) {
            [System.IO.File]::WriteAllText($fullPath, $result, $encoding)
        }
    }
}
Export-ModuleMember -Function Insert-Lines


function Delete-Lines {
    <#
    .SYNOPSIS
        Deletes one or more lines from a text file, starting at a given line position.

    .PARAMETER Path
        The file to edit.

    .PARAMETER LineNumber
        1-based number of the first line to delete.

    .PARAMETER Count
        How many lines to delete, starting at LineNumber. Default is 1.

    .EXAMPLE
        Delete-Lines -Path .\app.config -LineNumber 3

    .EXAMPLE
        Delete-Lines .\script.ps1 10 5     # deletes lines 10-14
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$LineNumber,

        [Parameter(Position = 2)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Count = 1
    )

    $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

    # Read the file and detect its encoding (checks for a BOM, defaults to UTF-8 without BOM)
    $reader = [System.IO.StreamReader]::new($fullPath, [System.Text.UTF8Encoding]::new($false), $true)
    try {
        $text     = $reader.ReadToEnd()
        $encoding = $reader.CurrentEncoding
    }
    finally { $reader.Dispose() }

    # Keep the file's existing line-ending style and trailing newline
    $newline = if ($text -match "`r`n") { "`r`n" }
               elseif ($text -match "`n") { "`n" }
               else { [Environment]::NewLine }
    $hasTrailingNewline = $text.EndsWith("`n")

    # Split the file into lines
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($text.Length -gt 0) {
        $lines.AddRange([string[]]($text -split "\r?\n"))
        if ($hasTrailingNewline) { $lines.RemoveAt($lines.Count - 1) }
    }

    # Check the range
    $lastLine = $LineNumber + $Count - 1
    if ($LineNumber -gt $lines.Count) {
        throw "LineNumber $LineNumber is out of range. '$fullPath' has $($lines.Count) line(s)."
    }
    if ($lastLine -gt $lines.Count) {
        throw "Cannot delete lines $LineNumber-$lastLine. '$fullPath' has only $($lines.Count) line(s)."
    }

    $description = if ($Count -eq 1) { "Delete line $LineNumber" } else { "Delete lines $LineNumber-$lastLine" }

    if ($PSCmdlet.ShouldProcess($fullPath, $description)) {
        foreach ($removed in $lines.GetRange($LineNumber - 1, $Count)) {
            Write-Verbose "Removing: $removed"
        }

        $lines.RemoveRange($LineNumber - 1, $Count)

        $result = $lines -join $newline
        # Add the trailing newline back only if lines remain, so an emptied file stays empty
        if ($hasTrailingNewline -and $lines.Count -gt 0) { $result += $newline }

        [System.IO.File]::WriteAllText($fullPath, $result, $encoding)
    }
}
Export-ModuleMember -Function Delete-Lines


function Apply-Patch {
    <#
    .SYNOPSIS
        Applies a unified diff (git diff / diff -u) to multiple files. All or nothing.
    .EXAMPLE
        Get-Content .\change.diff -Raw | Apply-Patch
    .EXAMPLE
        Apply-Patch -Patch $diffText -BasePath C:\src\repo -Strip 1 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()] [AllowEmptyCollection()]
        [string[]]$Patch,

        [string]$BasePath = (Get-Location).ProviderPath,

        # Like `patch -pN`: number of leading path parts to strip (a/, b/ => 1)
        [ValidateRange(0, 100)]
        [int]$Strip = 1,

        # Treat whitespace differences as equal when matching context lines
        [switch]$IgnoreWhitespace
    )

    begin   { $buffer = [System.Collections.Generic.List[string]]::new() }
    process { foreach ($p in $Patch) { $buffer.Add($p) } }

    end {
        $ErrorActionPreference = 'Stop'
        $sep   = [IO.Path]::DirectorySeparatorChar
        $base  = [IO.Path]::GetFullPath($BasePath).TrimEnd($sep)
        $lines = ($buffer -join "`n") -split "\r?\n"

        # ---------------------------------------------------------------- helpers
        function Resolve-PatchPath([string]$raw) {
            $p = ($raw -split "`t")[0].Trim()                      # drop timestamps
            if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) {
                $p = $p.Substring(1, $p.Length - 2)
            }
            if ($p -eq '/dev/null') { return $null }
            $parts = $p -split '/'
            if ($parts.Count -le $Strip) { throw "Cannot strip $Strip path component(s) from '$p'." }
            $rel  = $parts[$Strip..($parts.Count - 1)] -join $sep
            $full = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $rel))
            if (-not $full.StartsWith($base + $sep, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Patch path '$p' resolves outside base path '$base'."
            }
            $full
        }

        function Read-TextFile([string]$path) {
            $reader = [IO.StreamReader]::new($path, [Text.UTF8Encoding]::new($false), $true)
            try   { [pscustomobject]@{ Text = $reader.ReadToEnd(); Encoding = $reader.CurrentEncoding } }
            finally { $reader.Dispose() }
        }

        function Find-Hunk($orig, $old, [int]$expected, [int]$min) {
            $max = $orig.Count - $old.Count
            if ($max -lt $min) { return -1 }
            $expected = [Math]::Min([Math]::Max($expected, $min), $max)
            for ($d = 0; $d -le ($max - $min); $d++) {
                foreach ($pos in @($expected + $d, $expected - $d) | Select-Object -Unique) {
                    if ($pos -lt $min -or $pos -gt $max) { continue }
                    $ok = $true
                    for ($j = 0; $j -lt $old.Count; $j++) {
                        $a = $orig[$pos + $j]; $b = $old[$j]
                        if ($IgnoreWhitespace) { $a = ($a.Trim() -replace '\s+', ' '); $b = ($b.Trim() -replace '\s+', ' ') }
                        if ($a -cne $b) { $ok = $false; break }
                    }
                    if ($ok) { return $pos }
                }
            }
            -1
        }

        # ---------------------------------------------------------------- 1. parse
        $filePatches = [System.Collections.Generic.List[object]]::new()
        $i = 0
        while ($i -lt $lines.Count) {
            if ($lines[$i].StartsWith('--- ') -and ($i + 1) -lt $lines.Count -and $lines[$i + 1].StartsWith('+++ ')) {
                $fp = [pscustomobject]@{
                    OldPath = Resolve-PatchPath $lines[$i].Substring(4)
                    NewPath = Resolve-PatchPath $lines[$i + 1].Substring(4)
                    Hunks   = [System.Collections.Generic.List[object]]::new()
                }
                if (-not $fp.OldPath -and -not $fp.NewPath) { throw "Both sides are /dev/null at line $($i + 1)." }
                $i += 2

                while ($i -lt $lines.Count -and $lines[$i] -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
                    $oldCount = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
                    $newCount = if ($Matches[4]) { [int]$Matches[4] } else { 1 }
                    $h = [pscustomobject]@{
                        Header   = $lines[$i]
                        OldStart = [int]$Matches[1]
                        OldLines = [System.Collections.Generic.List[string]]::new()
                        NewLines = [System.Collections.Generic.List[string]]::new()
                        OldNoEol = $false
                        NewNoEol = $false
                    }
                    $i++; $o = 0; $n = 0; $last = ' '

                    while ($o -lt $oldCount -or $n -lt $newCount -or
                           ($i -lt $lines.Count -and $lines[$i].StartsWith('\'))) {
                        if ($i -ge $lines.Count) { throw "Unexpected end of patch inside hunk '$($h.Header)'." }
                        $l    = $lines[$i]
                        $tag  = if ($l.Length) { $l.Substring(0, 1) } else { ' ' }   # blank line = empty context
                        $text = if ($l.Length) { $l.Substring(1) }    else { '' }
                        switch -CaseSensitive ($tag) {
                            ' '  { $h.OldLines.Add($text); $h.NewLines.Add($text); $o++; $n++ }
                            '-'  { $h.OldLines.Add($text); $o++ }
                            '+'  { $h.NewLines.Add($text); $n++ }
                            '\'  { # "\ No newline at end of file"
                                   if ($last -ne '+') { $h.OldNoEol = $true }
                                   if ($last -ne '-') { $h.NewNoEol = $true } }
                            default { throw "Malformed line in hunk '$($h.Header)': '$l'" }
                        }
                        if ($tag -ne '\') { $last = $tag }
                        $i++
                    }
                    if ($o -ne $oldCount -or $n -ne $newCount) { throw "Hunk '$($h.Header)' line counts do not match its header." }
                    $fp.Hunks.Add($h)
                }
                $filePatches.Add($fp)
            }
            else { $i++ }   # skip "diff --git", "index ...", and other noise
        }
        if ($filePatches.Count -eq 0) { throw 'No file patches found in input.' }

        # ---------------------------------------------------------------- 2. apply in memory
        $plan    = [System.Collections.Generic.List[object]]::new()
        $claimed = @{}
        foreach ($fp in $filePatches) {
            $src = $fp.OldPath; $dst = $fp.NewPath
            foreach ($p in @($src, $dst) | Where-Object { $_ } | Select-Object -Unique) {
                if ($claimed.ContainsKey($p)) { throw "File '$p' appears more than once in the patch." }
                $claimed[$p] = $true
            }

            if ($src) {
                if (-not [IO.File]::Exists($src)) { throw "File to patch not found: $src" }
                $file = Read-TextFile $src
            } else {
                if ([IO.File]::Exists($dst)) { throw "Patch creates '$dst' but it already exists." }
                $file = [pscustomobject]@{ Text = ''; Encoding = [Text.UTF8Encoding]::new($false) }
            }

            $text = $file.Text
            $eol  = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
            $hadFinalEol = $text.EndsWith("`n")
            $body = if ($text.EndsWith("`r`n")) { $text.Substring(0, $text.Length - 2) }
                    elseif ($hadFinalEol)       { $text.Substring(0, $text.Length - 1) }
                    else                        { $text }
            [string[]]$orig = if ($text.Length -eq 0) { @() } else { $body -split "\r?\n" }

            $out      = [System.Collections.Generic.List[string]]::new()
            $cursor   = 0
            $finalEol = $hadFinalEol -or (-not $src)
            $label    = if ($dst) { $dst } else { $src }

            foreach ($h in $fp.Hunks) {
                $expected = if ($h.OldLines.Count -eq 0) { $h.OldStart } else { $h.OldStart - 1 }
                $pos = Find-Hunk $orig $h.OldLines $expected $cursor
                if ($pos -lt 0) { throw "Hunk '$($h.Header)' does not apply to '$label'." }
                for ($k = $cursor; $k -lt $pos; $k++) { $out.Add($orig[$k]) }
                $out.AddRange($h.NewLines)
                $cursor = $pos + $h.OldLines.Count
                if     ($h.NewNoEol) { $finalEol = $false }
                elseif ($h.OldNoEol) { $finalEol = $true }
            }
            for ($k = $cursor; $k -lt $orig.Count; $k++) { $out.Add($orig[$k]) }

            $action = if (-not $src) { 'Create' } elseif (-not $dst) { 'Delete' }
                      elseif ($src -ne $dst) { 'Rename' } else { 'Modify' }
            if ($action -eq 'Delete' -and $out.Count -gt 0) {
                throw "Patch deletes '$src' but its hunks do not remove the whole file."
            }
            $content = ($out -join $eol) + $(if ($finalEol -and $out.Count) { $eol } else { '' })

            $plan.Add([pscustomobject]@{
                Action = $action; Source = $src; Target = $dst
                Content = $content; Encoding = $file.Encoding; Hunks = $fp.Hunks.Count
            })
        }

        if (-not $PSCmdlet.ShouldProcess("$($plan.Count) file(s) under $base", 'Apply patch')) { return }

        # ---------------------------------------------------------------- 3. commit transactionally
        $txId    = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $temps   = @{}                                             # target -> temp file
        $backups = @{}                                             # original -> backup file
        $created = [System.Collections.Generic.List[string]]::new()
        $newDirs = [System.Collections.Generic.List[string]]::new()

        try {
            # a) stage new contents beside each target
            foreach ($item in $plan | Where-Object Target) {
                $dir = [IO.Path]::GetDirectoryName($item.Target)
                $d = $dir
                while ($d -and -not [IO.Directory]::Exists($d)) { $newDirs.Add($d); $d = [IO.Path]::GetDirectoryName($d) }
                [void][IO.Directory]::CreateDirectory($dir)
                $tmp = [IO.Path]::Combine($dir, ".$([IO.Path]::GetFileName($item.Target)).$txId.tmp")
                [IO.File]::WriteAllText($tmp, $item.Content, $item.Encoding)
                $temps[$item.Target] = $tmp
            }

            # b) back up every existing file that will be overwritten or removed
            foreach ($item in $plan) {
                foreach ($p in @($item.Source, $item.Target)) {
                    if ($p -and -not $backups.ContainsKey($p) -and [IO.File]::Exists($p)) {
                        $bak = "$p.$txId.bak"
                        [IO.File]::Copy($p, $bak)
                        $backups[$p] = $bak
                    }
                }
            }

            # c) swap everything into place
            foreach ($item in $plan) {
                if ($item.Target) {
                    if ([IO.File]::Exists($item.Target)) { [IO.File]::Delete($item.Target) }
                    else { $created.Add($item.Target) }
                    [IO.File]::Move($temps[$item.Target], $item.Target)
                    $temps.Remove($item.Target)
                }
                if ($item.Source -and $item.Source -ne $item.Target) { [IO.File]::Delete($item.Source) }
            }
        }
        catch {
            $err = $_
            foreach ($t in @($temps.Values)) { try { if ([IO.File]::Exists($t)) { [IO.File]::Delete($t) } } catch {} }
            foreach ($c in $created)         { try { if ([IO.File]::Exists($c)) { [IO.File]::Delete($c) } } catch {} }
            foreach ($kv in @($backups.GetEnumerator())) {
                try { [IO.File]::Copy($kv.Value, $kv.Key, $true); [IO.File]::Delete($kv.Value) }
                catch { Write-Warning "ROLLBACK FAILED for '$($kv.Key)'. Backup kept at '$($kv.Value)'." }
            }
            foreach ($d in $newDirs) {
                try { if (-not [IO.Directory]::EnumerateFileSystemEntries($d).GetEnumerator().MoveNext()) { [IO.Directory]::Delete($d) } } catch {}
            }
            throw "Patch failed and was rolled back: $($err.Exception.Message)"
        }

        foreach ($bak in $backups.Values) { try { [IO.File]::Delete($bak) } catch {} }

        $plan | ForEach-Object {
            [pscustomobject]@{
                Action = $_.Action
                Path   = if ($_.Target) { $_.Target } else { $_.Source }
                From   = if ($_.Action -eq 'Rename') { $_.Source } else { $null }
                Hunks  = $_.Hunks
            }
        }
    }
}
#Export-ModuleMember -Function Apply-Patch


function Move-File {
    <#
    .SYNOPSIS
        Moves a file, using 'git mv' when possible so git keeps the file's history.

    .DESCRIPTION
        Uses 'git mv' if all of these are true:
          - git is installed
          - the source file is tracked by git
          - the source and destination are in the same repository (same work tree)
        Otherwise it falls back to Move-Item.

    .EXAMPLE
        Move-File .\src\old.ps1 .\src\lib\new.ps1

    .EXAMPLE
        Get-ChildItem *.md | Move-File -Destination .\docs\ -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [string]$Destination,

        # Overwrite the destination if it already exists
        [switch]$Force,

        # Output the moved file
        [switch]$PassThru
    )

    begin {
        $gitAvailable = [bool](Get-Command git -ErrorAction SilentlyContinue)
        if (-not $gitAvailable) {
            Write-Verbose 'git not found; files will be moved with Move-Item.'
        }

        function Get-GitRoot([string]$Directory) {
            if (-not $gitAvailable) { return $null }
            $root = git -C $Directory rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $root) {
                # git returns forward slashes; this normalizes them
                return [IO.Path]::GetFullPath($root)
            }
            return $null
        }
    }

    process {
        # Resolve the source
        $source = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-Error "'$source' is not a file."
            return
        }

        # Resolve the destination (it doesn't have to exist yet)
        $target = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Destination)
        if ((Test-Path -LiteralPath $target -PathType Container) -or $Destination -match '[\\/]$') {
            $target = Join-Path $target (Split-Path $source -Leaf)
        }
        $targetDir = Split-Path $target -Parent

        # A rename that only changes letter case (e.g. readme.md -> README.md) is allowed
        $caseOnlyRename = ($source -ieq $target) -and ($source -cne $target)

        if ((Test-Path -LiteralPath $target) -and -not $caseOnlyRename -and -not $Force) {
            Write-Error "Destination '$target' already exists. Use -Force to overwrite."
            return
        }

        if (-not $PSCmdlet.ShouldProcess($source, "Move to '$target'")) { return }

        # git mv won't create missing folders, so create them first
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        # Decide whether git can do the move
        $useGit  = $false
        $srcRoot = Get-GitRoot (Split-Path $source -Parent)
        if ($srcRoot) {
            $dstRoot = Get-GitRoot $targetDir
            if ($dstRoot -and $srcRoot -eq $dstRoot) {
                git -C $srcRoot ls-files --error-unmatch -- $source *> $null
                $useGit = ($LASTEXITCODE -eq 0)
                if (-not $useGit) { Write-Verbose "'$source' is not tracked by git." }
            }
            else {
                Write-Verbose 'Source and destination are in different repositories (or submodules).'
            }
        }

        if ($useGit) {
            $gitArgs = @('-C', $srcRoot, 'mv')
            if ($Force) { $gitArgs += '-f' }
            $gitArgs += @('--', $source, $target)

            Write-Verbose "git $($gitArgs -join ' ')"
            $output = git @gitArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "git mv failed ($output). Falling back to Move-Item."
                $useGit = $false
            }
        }

        if (-not $useGit) {
            Write-Verbose "Move-Item '$source' -> '$target'"
            Move-Item -LiteralPath $source -Destination $target -Force:$Force -ErrorAction Stop
        }

        if ($PassThru) { Get-Item -LiteralPath $target }
    }
}
Export-ModuleMember -Function Move-File


function Rename-File {
    <#
    .SYNOPSIS
        Renames a file, using 'git mv' when possible so git keeps the file's history.

    .DESCRIPTION
        Uses 'git mv' if git is installed and the file is tracked by git.
        Otherwise it falls back to Move-Item.
        The file stays in its current folder. To move it somewhere else, use Move-File.

    .EXAMPLE
        Rename-File .\src\old.ps1 new.ps1

    .EXAMPLE
        Rename-File .\readme.md README.md          # case-only rename

    .EXAMPLE
        Get-ChildItem *.txt | Rename-File -NewName { $_.BaseName + '.md' } -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        # New file name only (no folder). You can pass a script block when piping files in.
        [Parameter(Mandatory, Position = 1, ValueFromPipelineByPropertyName)]
        [string]$NewName,

        # Overwrite a file that already has the new name
        [switch]$Force,

        # Output the renamed file
        [switch]$PassThru
    )

    begin {
        $gitAvailable = [bool](Get-Command git -ErrorAction SilentlyContinue)
        if (-not $gitAvailable) {
            Write-Verbose 'git not found; files will be renamed with Move-Item.'
        }
    }

    process {
        # Resolve the source
        $source = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-Error "'$source' is not a file."
            return
        }

        # Check the new name
        if ($NewName -match '[\\/]' -or
            $NewName -in '.', '..' -or
            $NewName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            Write-Error "'$NewName' is not a valid file name. Give a name only, without a folder (use Move-File to move a file)."
            return
        }

        $dir     = Split-Path $source -Parent
        $oldName = Split-Path $source -Leaf
        $target  = Join-Path $dir $NewName

        if ($oldName -ceq $NewName) {
            Write-Verbose "'$source' already has that name."
            if ($PassThru) { Get-Item -LiteralPath $source }
            return
        }

        # Look for a different file that already has this exact name.
        # (On Windows, Test-Path also finds the source itself when only the letter case changes.)
        $caseOnly  = $oldName -ieq $NewName
        $collision = (Test-Path -LiteralPath $target) -and
                     [bool](Get-ChildItem -LiteralPath $dir -Force | Where-Object Name -ceq $NewName)

        if ($collision -and -not $Force) {
            Write-Error "A file named '$NewName' already exists in '$dir'. Use -Force to overwrite."
            return
        }

        if (-not $PSCmdlet.ShouldProcess($source, "Rename to '$NewName'")) { return }

        # Check whether git tracks the file. This also fails if the folder isn't in a repo.
        $useGit = $false
        if ($gitAvailable) {
            git -C $dir ls-files --error-unmatch -- $oldName *> $null
            $useGit = ($LASTEXITCODE -eq 0)
            if (-not $useGit) { Write-Verbose "'$source' is not tracked by git." }
        }

        if ($useGit) {
            $gitArgs = @('-C', $dir, 'mv')
            if ($Force) { $gitArgs += '-f' }
            $gitArgs += @('--', $oldName, $NewName)

            Write-Verbose "git $($gitArgs -join ' ')"
            $output = git @gitArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "git mv failed ($output). Falling back to Move-Item."
                $useGit = $false
            }
        }

        if (-not $useGit) {
            if ($caseOnly -and -not $collision) {
                # Case-only renames can fail on case-insensitive file systems
                # (Windows PowerShell 5.1 refuses them), so rename through a temporary name.
                $temp = Join-Path $dir ('.rename-' + [guid]::NewGuid().ToString('N'))
                Write-Verbose "Case-only rename via '$temp'"
                Move-Item -LiteralPath $source -Destination $temp -ErrorAction Stop
                Move-Item -LiteralPath $temp   -Destination $target -ErrorAction Stop
            }
            else {
                Write-Verbose "Move-Item '$source' -> '$target'"
                # Move-Item -Force replaces an existing file; Rename-Item -Force doesn't
                Move-Item -LiteralPath $source -Destination $target -Force:$Force -ErrorAction Stop
            }
        }

        if ($PassThru) { Get-Item -LiteralPath $target }
    }
}
Export-ModuleMember -Function Rename-File


function Delete-File {
    <#
    .SYNOPSIS
        Deletes a file, using 'git rm' when the file is tracked by git.

    .DESCRIPTION
        If the file is tracked by git, 'git rm' deletes it and stages the deletion.
        git refuses if the file has uncommitted changes (use -Force to override).
        If the file isn't tracked, or git isn't installed, it uses Remove-Item.

        Use -KeepLocal to stop tracking the file in git but keep it on disk
        (for example, a config file that should have been in .gitignore).

    .EXAMPLE
        Delete-File .\src\obsolete.ps1

    .EXAMPLE
        Delete-File .\appsettings.local.json -KeepLocal     # untrack only

    .EXAMPLE
        Get-ChildItem *.bak | Delete-File -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        # Delete even with uncommitted changes (git), or when the file is hidden or read-only (Remove-Item)
        [switch]$Force,

        # Stop tracking the file in git, but leave it on disk
        [switch]$KeepLocal
    )

    begin {
        $gitAvailable = [bool](Get-Command git -ErrorAction SilentlyContinue)
        if (-not $gitAvailable) {
            Write-Verbose 'git not found; files will be deleted with Remove-Item.'
        }
    }

    process {
        # Resolve the file
        $source = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-Error "'$source' is not a file."
            return
        }

        $dir  = Split-Path $source -Parent
        $name = Split-Path $source -Leaf

        # Check whether git tracks the file. This also fails if the folder isn't in a repo.
        $tracked = $false
        if ($gitAvailable) {
            git -C $dir ls-files --error-unmatch -- $name *> $null
            $tracked = ($LASTEXITCODE -eq 0)
            if (-not $tracked) { Write-Verbose "'$source' is not tracked by git." }
        }

        if ($KeepLocal -and -not $tracked) {
            Write-Warning "'$source' is not tracked by git, so there's nothing to untrack. The file was left in place."
            return
        }

        $action = if ($KeepLocal) { 'Stop tracking in git (keep the file on disk)' }
                  elseif ($tracked) { 'Delete (git rm)' }
                  else { 'Delete permanently (not tracked by git)' }

        if (-not $PSCmdlet.ShouldProcess($source, $action)) { return }

        if ($tracked) {
            $gitArgs = @('-C', $dir, 'rm', '--quiet')
            if ($Force)     { $gitArgs += '-f' }
            if ($KeepLocal) { $gitArgs += '--cached' }
            $gitArgs += @('--', $name)

            Write-Verbose "git $($gitArgs -join ' ')"
            $output = git @gitArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                # Don't fall back to Remove-Item: git refused for a reason
                # (usually uncommitted changes that would be lost).
                Write-Error "git rm failed for '$source': $($output -join ' ') Use -Force to override."
                return
            }
        }
        else {
            Write-Verbose "Remove-Item '$source'"
            Remove-Item -LiteralPath $source -Force:$Force -ErrorAction Stop
        }
    }
}
Export-ModuleMember -Function Delete-File

