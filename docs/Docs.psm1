
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
#Export-ModuleMember -Function Get-Functions


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
#Export-ModuleMember -Function Show-Functions

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
#Export-ModuleMember -Function Help




function Read-File {
    <#
    .SYNOPSIS
    Reads a text file and returns its contents with line numbers. Use it to inspect code before editing.

    .DESCRIPTION
    Returns file contents in "cat -n" format: a right-aligned line number, a TAB, then the exact line
    content. The number and TAB are NOT part of the file. When writing an edit, match only the text
    after the TAB, including its leading whitespace.

    A header reports the resolved path, total line count, encoding, line-ending style and whether the
    file ends with a newline. Large files are paged: by default up to 2000 lines are returned starting
    at -Offset. A footer says how to get the next page. Very long lines (for example minified code)
    are cut off and marked.

    Binary files, directories and missing paths return a clear message instead of garbage output.

    .PARAMETER Path
    Path to the file. Absolute paths are best. Relative paths resolve against the current location.

    .PARAMETER Offset
    1-based line number to start reading from. Default is 1.

    .PARAMETER Limit
    Maximum number of lines to return. Default is 2000.

    .PARAMETER MaxLineLength
    Lines longer than this many characters are cut off and marked. Default is 2000.

    .EXAMPLE
    Read-File -Path C:\repo\src\app.ts

    .EXAMPLE
    Read-File -Path C:\repo\src\big.cs -Offset 1500 -Limit 200
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'FilePath')]
        [string]$Path,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$Offset = 1,

        [ValidateRange(1, 10000)]
        [int]$Limit = 2000,

        [ValidateRange(80, 100000)]
        [int]$MaxLineLength = 2000
    )

    process {
        # --- Resolve and validate the path -------------------------------------------------------
        try {
            $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        }
        catch {
            return "Error: invalid path '$Path': $($_.Exception.Message)"
        }

        if (Test-Path -LiteralPath $resolved -PathType Container) {
            return "Error: '$resolved' is a directory, not a file. Use Get-ChildItem to list its contents."
        }

        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $msg  = "Error: file not found: '$resolved'."
            $dir  = Split-Path -Path $resolved -Parent
            $stem = [IO.Path]::GetFileNameWithoutExtension($resolved)
            if ($dir -and $stem -and (Test-Path -LiteralPath $dir -PathType Container)) {
                $similar = Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$stem*" } |
                    Select-Object -First 5 -ExpandProperty Name
                if ($similar) { $msg += " Similar files in that directory: $($similar -join ', ')" }
            }
            return $msg
        }

        $file = Get-Item -LiteralPath $resolved -Force
        if ($file.Length -eq 0) {
            return "[File: $resolved | empty (0 bytes)]"
        }

        # --- Sniff the first bytes (encoding / binary) and the last bytes (trailing newline) ------
        $head = New-Object byte[] ([Math]::Min(65536, $file.Length))
        $tail = New-Object byte[] ([Math]::Min(4, $file.Length))
        $fs = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $headCount = $fs.Read($head, 0, $head.Length)
            [void]$fs.Seek(-$tail.Length, [IO.SeekOrigin]::End)
            [void]$fs.Read($tail, 0, $tail.Length)
        }
        finally { $fs.Dispose() }

        # Detect the encoding from the byte order mark (BOM)
        if ($headCount -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            $encoding = New-Object System.Text.UTF8Encoding($true);   $encName = 'utf-8 with BOM'
        }
        elseif ($headCount -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) {
            $encoding = [System.Text.Encoding]::Unicode;              $encName = 'utf-16 LE'
        }
        elseif ($headCount -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) {
            $encoding = [System.Text.Encoding]::BigEndianUnicode;     $encName = 'utf-16 BE'
        }
        else {
            $encoding = New-Object System.Text.UTF8Encoding($false);  $encName = 'utf-8'
        }
        $isUtf16 = $encName -like 'utf-16*'

        # Binary check: a NUL byte in a non-UTF-16 file almost always means binary content
        if (-not $isUtf16 -and ([Array]::IndexOf($head, [byte]0, 0, $headCount) -ge 0)) {
            $kb = [Math]::Round($file.Length / 1KB, 1)
            return "Error: '$resolved' looks like a binary file ($kb KB). Not showing its contents."
        }

        # Line-ending style (from the sample)
        $sample = $encoding.GetString($head, 0, $headCount)
        $crlf   = ([regex]::Matches($sample, "`r`n")).Count
        $lf     = ([regex]::Matches($sample, "(?<!`r)`n")).Count
        $eol = if ($crlf -and $lf) { "mixed (CRLF:$crlf LF:$lf in sample)" }
               elseif ($crlf)      { 'CRLF' }
               elseif ($lf)        { 'LF' }
               else                { 'none (single line)' }

        # Does the file end with a newline?
        $t = $tail.Length
        $endsWithNewline = switch ($encName) {
            'utf-16 LE' { $t -ge 2 -and $tail[$t - 2] -eq 0x0A -and $tail[$t - 1] -eq 0x00 }
            'utf-16 BE' { $t -ge 2 -and $tail[$t - 2] -eq 0x00 -and $tail[$t - 1] -eq 0x0A }
            default     { $tail[$t - 1] -eq 0x0A }
        }

        # --- Stream the file; keep only the requested window but count every line ----------------
        $sb        = New-Object System.Text.StringBuilder
        $lastLine  = $Offset + $Limit - 1
        $lineNo    = 0
        $shown     = 0
        $truncated = 0

        $reader = New-Object System.IO.StreamReader($resolved, $encoding, $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $lineNo++
                if ($lineNo -lt $Offset -or $lineNo -gt $lastLine) { continue }

                if ($line.Length -gt $MaxLineLength) {
                    $line = $line.Substring(0, $MaxLineLength) + " ... [line truncated: $($line.Length) chars total]"
                    $truncated++
                }
                [void]$sb.AppendFormat("{0,6}`t{1}`n", $lineNo, $line)
                $shown++
            }
        }
        finally { $reader.Dispose() }

        $total = $lineNo

        if ($Offset -gt $total) {
            return "Error: -Offset $Offset is past the end of '$resolved', which has $total lines."
        }

        # --- Build the output ---------------------------------------------------------------------
        $end    = $Offset + $shown - 1
        $range  = if ($Offset -eq 1 -and $end -eq $total) { "all $total lines" } else { "lines $Offset-$end of $total" }
        $finalNl = if ($endsWithNewline) { 'yes' } else { 'no' }
        $header = "[File: $resolved | $range | $encName | EOL: $eol | final newline: $finalNl]"

        $footer = @()
        if ($end -lt $total) {
            $footer += "[... $($total - $end) more lines. Call again with -Offset $($end + 1) to continue.]"
        }
        if ($truncated) {
            $footer += "[$truncated line(s) exceeded $MaxLineLength chars and were cut off; use -MaxLineLength to see more.]"
        }

        (@($header, $sb.ToString().TrimEnd("`n")) + $footer) -join "`n" | ForEach-Object { $_.TrimEnd() }
    }
}
Export-ModuleMember -Function Read-File

function List-Directory {
    <#
    .SYNOPSIS
        Lists a directory as a compact tree, tuned for exploring and editing code repositories.

    .DESCRIPTION
        - Inside a git work tree it uses `git ls-files` to list files, so .gitignore is respected.
          It includes untracked files that aren't ignored, and leaves out tracked files that
          have been deleted.
        - Outside git it walks the file system itself and skips well-known noise folders.
        - Folders below -Depth are folded into one line with a file count, so big trees
          stay readable.
        - Paths are relative and use '/', so you can paste them straight into edit or read tools.
        - Output is sorted the same way every run: folders first, then files, case-insensitive.

    .EXAMPLE
        List-Directory
    .EXAMPLE
        List-Directory src -Depth 4 -Filter *.cs, *.csproj
    .EXAMPLE
        List-Directory -NoIgnore -ExcludeDir @() -AsObject | Where-Object Size -gt 1MB
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string] $Path = '.',

        # How many levels to show. Deeper content is collapsed into "[+N files]".
        [ValidateRange(1, 64)]
        [int] $Depth = 2,

        # Wildcards matched against file names. Folders only appear if they contain matches.
        [string[]] $Filter = @('*'),

        # Folder names that are always skipped, at any level. Pass @() to turn this off.
        [string[]] $ExcludeDir = @(
            '.git', 'node_modules', 'bin', 'obj', '.vs', '.idea', 'dist', 'build', 'out',
            'target', '__pycache__', '.venv', 'venv', '.next', '.nuxt', 'coverage', '.gradle'
        ),

        # Don't use git / .gitignore. Walk the file system instead.
        [switch] $NoIgnore,

        # Maximum number of lines to print. A final note says how many were left out.
        [ValidateRange(1, 1000000)]
        [int] $MaxEntries = 300,

        # Return objects instead of text lines.
        [switch] $AsObject
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "Not a directory: $Path" }

    $root      = $item.FullName
    $prefixLen = $root.TrimEnd('\', '/').Length + 1
    $excl      = [System.Collections.Generic.HashSet[string]]::new(
                     [string[]]@($ExcludeDir), [StringComparer]::OrdinalIgnoreCase)

    # ---- 1. Collect relative file paths ('/'-separated) ---------------------------------
    $files  = $null
    $source = 'filesystem'

    if (-not $NoIgnore -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $inside = git -C $root rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0 -and $inside -eq 'true') {
            $raw = git -C $root -c core.quotepath=off ls-files -z --cached --others --exclude-standard 2>$null
            if ($LASTEXITCODE -eq 0) {
                $deleted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $del = git -C $root -c core.quotepath=off ls-files -z --deleted 2>$null
                foreach ($d in (($del -join "`n") -split "`0")) { if ($d) { [void]$deleted.Add($d) } }

                $files  = (($raw -join "`n") -split "`0") | Where-Object { $_ -and -not $deleted.Contains($_) }
                $source = 'git'
            }
        }
    }

    if ($null -eq $files) {
        # Walk the tree ourselves so excluded folders are skipped entirely (never entered).
        $list  = [System.Collections.Generic.List[string]]::new()
        $stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
        $stack.Push([System.IO.DirectoryInfo]$item)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try   { $children = $dir.GetFileSystemInfos() }
            catch { Write-Verbose "Skipping unreadable folder: $($dir.FullName)"; continue }
            foreach ($c in $children) {
                if ($c -is [System.IO.DirectoryInfo]) {
                    $isLink = $c.Attributes -band [System.IO.FileAttributes]::ReparsePoint
                    if (-not $isLink -and -not $excl.Contains($c.Name)) { $stack.Push($c) }
                }
                else {
                    $list.Add($c.FullName.Substring($prefixLen).Replace('\', '/'))
                }
            }
        }
        $files = $list
    }

    # ---- 2. Build tree entries ---------------------------------------------------------
    $entries = [System.Collections.Generic.Dictionary[string, psobject]]::new([StringComparer]::Ordinal)
    $matched = 0

    foreach ($f in $files) {
        $segs = $f.Split('/')
        $n    = $segs.Count

        $skip = $false
        for ($i = 0; $i -lt $n - 1; $i++) { if ($excl.Contains($segs[$i])) { $skip = $true; break } }
        if ($skip) { continue }

        $name = $segs[-1]
        $hit  = $false
        foreach ($pat in $Filter) { if ($name -like $pat) { $hit = $true; break } }
        if (-not $hit) { continue }
        $matched++

        # Sort key: '0' prefix for folders, '1' for files, so folders come first at each level.
        $key   = ''
        $limit = [Math]::Min($n - 1, $Depth)
        for ($i = 0; $i -lt $limit; $i++) {
            $rel = $segs[0..$i] -join '/'
            $key = if ($i) { "$key/0$($segs[$i])" } else { "0$($segs[$i])" }
            if (-not $entries.ContainsKey($rel)) {
                $entries[$rel] = [pscustomobject]@{
                    Path = "$rel/"; Name = $segs[$i]; Type = 'Dir'; Level = $i + 1
                    Size = $null; FileCount = 0; Collapsed = $false; SortKey = $key
                }
            }
            $e = $entries[$rel]
            $e.FileCount++
            if ($i + 1 -eq $Depth -and $n -gt $Depth) { $e.Collapsed = $true }
        }

        if ($n -le $Depth) {
            $entries[$f] = [pscustomobject]@{
                Path = $f; Name = $name; Type = 'File'; Level = $n
                Size = $null; FileCount = $null; Collapsed = $false
                SortKey = if ($key) { "$key/1$name" } else { "1$name" }
            }
        }
    }

    # ---- 3. Sort (ordinal, same result on every machine), truncate, add sizes ----------
    $arr  = [object[]]@($entries.Values)
    $keys = [string[]]@($arr | ForEach-Object SortKey)
    [Array]::Sort($keys, $arr, [StringComparer]::OrdinalIgnoreCase)

    $omitted = [Math]::Max(0, $arr.Count - $MaxEntries)
    $shown   = if ($omitted) { $arr[0..($MaxEntries - 1)] } else { $arr }

    foreach ($e in $shown) {
        if ($e.Type -eq 'File') {
            $fi = [System.IO.FileInfo]::new([System.IO.Path]::Combine($root, $e.Path))
            if ($fi.Exists) { $e.Size = $fi.Length }
        }
    }

    if ($AsObject) {
        return $shown | Select-Object Path, Type, Level, Size, FileCount, Collapsed
    }

    # ---- 4. Text output ----------------------------------------------------------------
    $fmtSize = {
        param($b)
        if     ($null -eq $b) { '?' }
        elseif ($b -ge 1MB)   { '{0:N1} MB' -f ($b / 1MB) }
        elseif ($b -ge 1KB)   { '{0:N1} KB' -f ($b / 1KB) }
        else                  { "$b B" }
    }

    "$root  [source: $source, depth: $Depth, files: $matched]"
    if ($matched -eq 0) { '  (no matching files)'; return }

    foreach ($e in $shown) {
        $indent = '  ' * $e.Level
        if ($e.Type -eq 'Dir') {
            if ($e.Collapsed) { "$indent$($e.Name)/  [+$($e.FileCount) files]" }
            else              { "$indent$($e.Name)/" }
        }
        else {
            "$indent$($e.Name)  ($(& $fmtSize $e.Size))"
        }
    }

    if ($omitted) {
        "  ... $omitted more entries not shown (narrow with -Path, -Filter, or a lower -Depth)"
    }
}
Export-ModuleMember -Function List-Directory


function Find-Files {
    <#
    .SYNOPSIS
        Finds files by glob pattern (e.g. '**/*.cs', 'src/**/*.{ts,tsx}', 'Program.cs').

    .DESCRIPTION
        Glob syntax (matched against the path relative to -Path, using '/'):
          *        any characters except '/'
          **       any number of folders (as its own segment: '**/x', 'a/**/b', 'a/**')
          ?        one character except '/'
          [abc]    character class; [!abc] or [^abc] negates; [*] matches a literal '*'
          {a,b}    alternatives, can be nested: '*.{cs,csproj}'
        A pattern with no '/' matches the file name at any depth, so '*.cs' = '**/*.cs'.
        A leading '/' anchors the pattern to the root, so '/README.md' only matches at the top.
        A trailing '/' means everything below: 'src/' = 'src/**'.

        - Inside a git work tree it gets files from `git ls-files`, so .gitignore is respected.
        - Outside git (or with -NoIgnore) it walks the file system and never enters -ExcludeDir folders.
        - The fixed folder part of a pattern ('src/app' in 'src/app/**/*.cs') limits the search
          to that folder, so narrow patterns are fast even in big repos.
        - A folder named literally in a pattern is not excluded: '**/bin/*.dll' searches 'bin' folders.

    .EXAMPLE
        Find-Files '**/*.cs'
    .EXAMPLE
        Find-Files 'src/**/*.{ts,tsx}' -Exclude '**/*.test.*', '**/*.spec.*'
    .EXAMPLE
        Find-Files * -SortBy Modified -MaxResults 10        # recently changed files
    .EXAMPLE
        Find-Files '**/bin/**/*.dll' -NoIgnore -AsObject | Format-Table Path, Size
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]] $Pattern,

        [Parameter(Position = 1)]
        [string] $Path = '.',

        # Glob patterns to leave out (same syntax as -Pattern).
        [string[]] $Exclude = @(),

        # Folder names skipped at any level unless a pattern names them. Pass @() to turn off.
        [string[]] $ExcludeDir = @(
            '.git', 'node_modules', 'bin', 'obj', '.vs', '.idea', 'dist', 'build', 'out',
            'target', '__pycache__', '.venv', 'venv', '.next', '.nuxt', 'coverage', '.gradle'
        ),

        # Don't use git / .gitignore. Walk the file system instead.
        [switch] $NoIgnore,

        [switch] $CaseSensitive,

        # Path = alphabetical; Modified = newest first; Size = largest first.
        [ValidateSet('Path', 'Modified', 'Size')]
        [string] $SortBy = 'Path',

        [ValidateRange(1, 1000000)]
        [int] $MaxResults = 200,

        # Return objects (Path, Size, Modified, FullName) instead of relative path strings.
        [switch] $AsObject
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "Not a directory: $Path" }

    $root      = $item.FullName
    $prefixLen = $root.TrimEnd('\', '/').Length + 1
    $wild      = [char[]]'*?[{'

    $opts = [Text.RegularExpressions.RegexOptions]::CultureInvariant
    if (-not $CaseSensitive) { $opts = $opts -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }

    # ---- 1. Turn globs into regexes ------------------------------------------------------
    $compile = {
        param([string] $glob)

        $g = $glob.Trim().Replace('\', '/')
        while ($g.StartsWith('./')) { $g = $g.Substring(2) }
        if     ($g.StartsWith('/'))    { $g = $g.TrimStart('/') }   # anchored to root
        elseif (-not $g.Contains('/')) { $g = "**/$g" }             # bare name: any depth
        if ($g.EndsWith('/')) { $g += '**' }
        if (-not $g) { throw "Empty pattern: '$glob'" }

        $sb = [Text.StringBuilder]::new('^')
        $braces = 0
        $i = 0
        while ($i -lt $g.Length) {
            $c = $g[$i]
            if ($c -eq '*') {
                $segStart = ($i -eq 0) -or ($g[$i - 1] -eq '/')
                if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
                    if ($segStart -and $i + 2 -lt $g.Length -and $g[$i + 2] -eq '/') {
                        [void]$sb.Append('(?:.*/)?'); $i += 3; continue      # '**/' = zero or more folders
                    }
                    if ($segStart -and $i + 2 -eq $g.Length) {
                        [void]$sb.Append('.*'); $i += 2; continue            # trailing '**'
                    }
                    [void]$sb.Append('[^/]*'); $i += 2; continue             # 'a**b' acts like '*'
                }
                [void]$sb.Append('[^/]*')
            }
            elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
            elseif ($c -eq '[') {
                $j   = $i + 1
                $neg = $j -lt $g.Length -and ($g[$j] -eq '!' -or $g[$j] -eq '^')
                if ($neg) { $j++ }
                $bodyStart = $j
                if ($j -lt $g.Length -and $g[$j] -eq ']') { $j++ }            # ']' first = literal
                $close = if ($j -lt $g.Length) { $g.IndexOf(']', $j) } else { -1 }
                if ($close -lt 0) {
                    [void]$sb.Append('\[')                                   # unclosed: literal '['
                }
                else {
                    $body = $g.Substring($bodyStart, $close - $bodyStart).Replace('[', '\[').Replace(']', '\]')
                    [void]$sb.Append($(if ($neg) { '[^' } else { '[' })).Append($body).Append(']')
                    $i = $close
                }
            }
            elseif ($c -eq '{')                      { $braces++; [void]$sb.Append('(?:') }
            elseif ($c -eq '}' -and $braces -gt 0)   { $braces--; [void]$sb.Append(')') }
            elseif ($c -eq ',' -and $braces -gt 0)   { [void]$sb.Append('|') }
            else                                     { [void]$sb.Append([regex]::Escape([string]$c)) }
            $i++
        }
        if ($braces) { throw "Unbalanced '{' in pattern: '$glob'" }
        [void]$sb.Append('$')

        # Fixed leading folders (to limit the search) and all literal segments (to un-exclude).
        $segs   = $g.Split('/')
        $prefix = [Collections.Generic.List[string]]::new()
        for ($k = 0; $k -lt $segs.Count - 1; $k++) {
            if ($segs[$k].IndexOfAny($wild) -ge 0) { break }
            $prefix.Add($segs[$k])
        }
        $literals = @($segs | Where-Object { $_ -and $_.IndexOfAny($wild) -lt 0 })

        [pscustomobject]@{
            Regex    = [regex]::new($sb.ToString(), $opts)
            Prefix   = [string[]]$prefix.ToArray()
            Literals = $literals
        }
    }

    $include   = @(foreach ($p in $Pattern) { & $compile $p })
    $incRx     = [regex[]]@($include | ForEach-Object Regex)
    $excludeRx = [regex[]]@(foreach ($p in $Exclude) { (& $compile $p).Regex })

    # The folder prefix shared by all patterns is the narrowest place to search.
    $common = @($include[0].Prefix)
    foreach ($inc in $include) {
        $n = 0
        while ($n -lt $common.Count -and $n -lt $inc.Prefix.Count -and $common[$n] -eq $inc.Prefix[$n]) { $n++ }
        $common = if ($n) { @($common[0..($n - 1)]) } else { @() }
    }
    $searchPrefix = $common -join '/'

    $excl = [Collections.Generic.HashSet[string]]::new([string[]]@($ExcludeDir), [StringComparer]::OrdinalIgnoreCase)
    foreach ($inc in $include) { foreach ($l in $inc.Literals) { [void]$excl.Remove($l) } }

    # ---- 2. Collect candidate files -----------------------------------------------------
    $files  = $null
    $source = 'filesystem'

    if (-not $NoIgnore -and (Get-Command git -ErrorAction SilentlyContinue)) {
        # git writes UTF-8; read it that way so non-ASCII file names come through correctly.
        $git = {
            $prev = [Console]::OutputEncoding
            try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
            try     { & git -C $root -c core.quotepath=off @args 2>$null }
            finally { try { [Console]::OutputEncoding = $prev } catch { } }
        }

        $inside = & $git rev-parse --is-inside-work-tree
        if ($LASTEXITCODE -eq 0 -and "$inside".Trim() -eq 'true') {
            $spec = @()
            if ($searchPrefix) {
                $magic = if ($CaseSensitive) { 'literal' } else { 'literal,icase' }
                $spec  = @('--', ":($magic)$searchPrefix")
            }
            $raw = & $git ls-files -z --cached --others --exclude-standard @spec
            if ($LASTEXITCODE -eq 0) {
                $deleted = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $del = & $git ls-files -z --deleted @spec
                foreach ($d in (($del -join "`n") -split "`0")) { if ($d) { [void]$deleted.Add($d) } }

                $list = [Collections.Generic.List[string]]::new()
                foreach ($f in (($raw -join "`n") -split "`0")) {
                    if ($f -and -not $deleted.Contains($f)) { $list.Add($f) }
                }
                if ($list.Count) { $files = $list; $source = 'git' }
                else { Write-Verbose 'git listed no files here (ignored folder?); walking the file system instead.' }
            }
        }
    }

    if ($null -eq $files) {
        $start = $root
        if ($searchPrefix) {
            $candidate = [IO.Path]::Combine($root, $searchPrefix)
            if ([IO.Directory]::Exists($candidate)) { $start = $candidate }
        }

        $list  = [Collections.Generic.List[string]]::new()
        $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $stack.Push([IO.DirectoryInfo]::new($start))
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try   { $children = $dir.GetFileSystemInfos() }
            catch { Write-Verbose "Skipping unreadable folder: $($dir.FullName)"; continue }
            foreach ($c in $children) {
                if ($c -is [IO.DirectoryInfo]) {
                    $isLink = $c.Attributes -band [IO.FileAttributes]::ReparsePoint
                    if (-not $isLink -and -not $excl.Contains($c.Name)) { $stack.Push($c) }
                }
                else {
                    $list.Add($c.FullName.Substring($prefixLen).Replace('\', '/'))
                }
            }
        }
        $files = $list
    }
    Write-Verbose "Source: $source; candidates: $($files.Count); search prefix: '$searchPrefix'"

    # ---- 3. Match ------------------------------------------------------------------------
    $hits = [Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        if (-not $f) { continue }

        $ok = $false
        foreach ($rx in $incRx) { if ($rx.IsMatch($f)) { $ok = $true; break } }
        if (-not $ok) { continue }

        foreach ($rx in $excludeRx) { if ($rx.IsMatch($f)) { $ok = $false; break } }
        if (-not $ok) { continue }

        $segs = $f.Split('/')
        for ($k = 0; $k -lt $segs.Count - 1; $k++) {
            if ($excl.Contains($segs[$k])) { $ok = $false; break }
        }
        if ($ok) { $hits.Add($f) }
    }

    $total = $hits.Count
    if ($total -eq 0) {
        $hint = if ($source -eq 'git') { ' .gitignore and -ExcludeDir apply; try -NoIgnore.' } else { ' -ExcludeDir applies.' }
        Write-Warning "No files matched '$($Pattern -join "', '")' under $root (source: $source).$hint"
        return
    }

    # ---- 4. Sort, truncate, output ----------------------------------------------------
    $toObj = {
        param($rel)
        $fi = [IO.FileInfo]::new([IO.Path]::Combine($root, $rel))
        [pscustomobject]@{
            Path     = $rel
            Size     = if ($fi.Exists) { $fi.Length } else { $null }
            Modified = if ($fi.Exists) { $fi.LastWriteTime } else { $null }
            FullName = $fi.FullName
        }
    }

    if ($SortBy -eq 'Path') {
        $hits.Sort([StringComparer]::OrdinalIgnoreCase)
        $shown = if ($total -gt $MaxResults) { $hits.GetRange(0, $MaxResults) } else { $hits }
        if ($AsObject) { foreach ($h in $shown) { & $toObj $h } } else { $shown }
    }
    else {
        $objs = foreach ($h in $hits) { & $toObj $h }
        $objs = $objs |
            Sort-Object @{ Expression = $SortBy; Descending = $true }, @{ Expression = 'Path'; Descending = $false } |
            Select-Object -First $MaxResults
        if ($AsObject) { $objs } else { $objs | ForEach-Object Path }
    }

    if ($total -gt $MaxResults) {
        Write-Warning "Showing $MaxResults of $total matches. Narrow the pattern or -Path, or raise -MaxResults."
    }
}
Export-ModuleMember -Function Find-Files


function Search-Code {
    <#
    .SYNOPSIS
        Searches file contents with a regex (or literal text), ripgrep-style, with line numbers and context.

    .DESCRIPTION
        - Files come from Find-Files, so .gitignore, -ExcludeDir and glob filters work the same way.
        - Smart case (like rg -S): case-insensitive unless the pattern contains an uppercase letter.
        - Skips binary files (a NUL byte in the first 8 KB) and files larger than -MaxFileSize.
        - Reads UTF-8 (with or without BOM) and UTF-16 with a BOM. Handles both CRLF and LF.
        - Text output: file heading, then 'N:' for matching lines and 'N-' for context lines,
          with '--' between groups of lines that aren't next to each other.
        - Long lines (e.g. minified files) are cut down around the match in the text output.
        - Matching is line by line: a pattern can't match across a line break.

    .EXAMPLE
        Search-Code 'TODO|FIXME'
    .EXAMPLE
        Search-Code 'class \w+Service' -Include '*.cs' -Context 3
    .EXAMPLE
        Search-Code 'Dispose(' -Literal -FilesWithMatches
    .EXAMPLE
        Search-Code 'connectionString' -AsObject | Group-Object Path
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Pattern,

        # Folder to search, or a single file.
        [Parameter(Position = 1)]
        [string] $Path = '.',

        # Glob(s) choosing which files to search (Find-Files syntax), e.g. '*.cs', 'src/**/*.{ts,tsx}'.
        [string[]] $Include = @('*'),

        # Glob(s) of files to skip.
        [string[]] $Exclude = @(),

        # Treat the pattern as plain text, not a regex.
        [switch] $Literal,

        # Only match whole words.
        [switch] $WordMatch,

        # Override smart case.
        [switch] $CaseSensitive,
        [switch] $IgnoreCase,

        # Lines of context before and after each match. -Before / -After override this.
        [ValidateRange(0, 100)] [int] $Context = 2,
        [ValidateRange(-1, 100)] [int] $Before = -1,
        [ValidateRange(-1, 100)] [int] $After = -1,

        # Don't use git / .gitignore (passed through to Find-Files).
        [switch] $NoIgnore,

        # Stop after this many matching lines in total.
        [ValidateRange(1, 1000000)] [int] $MaxResults = 200,

        # Maximum matching lines per file (0 = no limit).
        [ValidateRange(0, 1000000)] [int] $MaxPerFile = 0,

        [long] $MaxFileSize = 1MB,

        # Lines longer than this are cut down around the match (text output only).
        [ValidateRange(40, 100000)] [int] $MaxLineLength = 300,

        # Output only the paths of files that match (like rg -l).
        [switch] $FilesWithMatches,

        # Output 'path:count' for each matching file (like rg -c).
        [switch] $Count,

        # Return one object per matching line: Path, Line, Column, Match, Text, Before, After.
        [switch] $AsObject
    )

    if ($CaseSensitive -and $IgnoreCase) { throw 'Use either -CaseSensitive or -IgnoreCase, not both.' }
    if ($FilesWithMatches -and $Count)   { throw 'Use either -FilesWithMatches or -Count, not both.' }

    $nBefore = if ($Before -ge 0) { $Before } else { $Context }
    $nAfter  = if ($After  -ge 0) { $After  } else { $Context }

    # ---- 1. Build the regex --------------------------------------------------------------
    $src = if ($Literal) { [regex]::Escape($Pattern) } else { $Pattern }
    if ($WordMatch) { $src = "(?<!\w)(?:$src)(?!\w)" }   # also works when the text starts/ends with a symbol

    $sensitive =
        if     ($CaseSensitive) { $true }
        elseif ($IgnoreCase)    { $false }
        else {
            # Smart case: ignore escapes like \S, \W, \p{Lu} when looking for uppercase letters.
            $plain = if ($Literal) { $Pattern } else { $Pattern -creplace '\\[pP]\{[^}]*\}|\\.', '' }
            $plain -cmatch '\p{Lu}'
        }

    $opts = [Text.RegularExpressions.RegexOptions]'CultureInvariant, Multiline'
    if (-not $sensitive) { $opts = $opts -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }

    try   { $rx = [regex]::new($src, $opts, [TimeSpan]::FromSeconds(2)) }
    catch { throw "Invalid regex '$Pattern': $($_.Exception.InnerException.Message) (use -Literal for plain text)" }

    # Quick check on the whole file before splitting it into lines. Turned off for anchors or
    # lookarounds that could behave differently on the whole text than on a single line.
    $prefilter = $Literal -or ($Pattern -notmatch '\\[AzZG]|\(\?<?!')

    # ---- 2. Choose files -----------------------------------------------------------------
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        if (-not (Get-Command Find-Files -ErrorAction SilentlyContinue)) {
            throw 'Search-Code needs Find-Files to be loaded to search a folder.'
        }
        $root = $item.FullName
        $ff = @{
            Pattern = $Include; Path = $root; Exclude = $Exclude; NoIgnore = $NoIgnore
            MaxResults = 1000000; WarningAction = 'SilentlyContinue'
        }
        $files = @(Find-Files @ff)
    }
    else {
        $root  = $item.DirectoryName
        $files = @($item.Name)
    }

    if ($files.Count -eq 0) {
        Write-Warning "No files to search under $Path (Include: $($Include -join ', '))."
        return
    }

    # ---- 3. Search -----------------------------------------------------------------------
    $utf8       = [Text.UTF8Encoding]::new($false, $false)
    $perFile    = if ($FilesWithMatches) { 1 } else { $MaxPerFile }
    $limit      = if ($Count) { [int]::MaxValue } else { $MaxResults }
    $total      = 0
    $matchFiles = 0
    $searched   = 0
    $skipped    = 0
    $stopped    = $false
    $firstFile  = $true

    $clip = {
        param([string] $s, [int] $col)
        if ($s.Length -le $MaxLineLength) { return $s }
        $start = [Math]::Max(0, [Math]::Min($col - [int]($MaxLineLength / 3), $s.Length - $MaxLineLength))
        $pre   = if ($start -gt 0) { '...' } else { '' }
        $post  = if ($start + $MaxLineLength -lt $s.Length) { '...' } else { '' }
        "$pre$($s.Substring($start, $MaxLineLength))$post"
    }

    foreach ($rel in $files) {
        if ($stopped) { break }
        $full = [IO.Path]::Combine($root, $rel)

        try {
            $fi = [IO.FileInfo]::new($full)
            if (-not $fi.Exists) { continue }
            if ($fi.Length -gt $MaxFileSize) { $skipped++; Write-Verbose "Too large, skipped: $rel"; continue }
            $bytes = [IO.File]::ReadAllBytes($full)
        }
        catch { $skipped++; Write-Verbose "Unreadable, skipped: $rel"; continue }

        # Decode: BOM first, then treat NUL bytes as binary, otherwise UTF-8.
        $len = $bytes.Length
        if     ($len -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $text = $utf8.GetString($bytes, 3, $len - 3) }
        elseif ($len -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $len - 2) }
        elseif ($len -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $len - 2) }
        else {
            if ([Array]::IndexOf($bytes, [byte]0, 0, [Math]::Min($len, 8000)) -ge 0) {
                $skipped++; Write-Verbose "Binary, skipped: $rel"; continue
            }
            $text = $utf8.GetString($bytes)
        }
        $searched++

        $text = $text.Replace("`r`n", "`n")
        $hitIdx   = [Collections.Generic.List[int]]::new()
        $hitMatch = [Collections.Generic.Dictionary[int, Text.RegularExpressions.Match]]::new()

        try {
            if ($prefilter -and -not $rx.IsMatch($text)) { continue }

            $lines = $text.Split("`n")
            $n = $lines.Count
            if ($n -gt 1 -and $lines[$n - 1] -eq '') { $n-- }      # final newline doesn't count as a line

            for ($i = 0; $i -lt $n; $i++) {
                $m = $rx.Match($lines[$i])
                if (-not $m.Success) { continue }
                $hitIdx.Add($i)
                $hitMatch[$i] = $m
                if ($perFile -and $hitIdx.Count -ge $perFile) { break }
                if ($total + $hitIdx.Count -ge $limit) { $stopped = $true; break }
            }
        }
        catch [Text.RegularExpressions.RegexMatchTimeoutException] {
            Write-Warning "Regex timed out on $rel; file skipped. Simplify the pattern."
            continue
        }

        if ($hitIdx.Count -eq 0) { continue }
        $matchFiles++
        $total += $hitIdx.Count

        # ---- 4. Output -----------------------------------------------------------------
        if ($FilesWithMatches) {
            if ($AsObject) { [pscustomobject]@{ Path = $rel; FullName = $full } } else { $rel }
            continue
        }
        if ($Count) {
            if ($AsObject) { [pscustomobject]@{ Path = $rel; Count = $hitIdx.Count } } else { "${rel}:$($hitIdx.Count)" }
            continue
        }

        if ($AsObject) {
            foreach ($i in $hitIdx) {
                $bs = [Math]::Max(0, $i - $nBefore)
                $ae = [Math]::Min($n - 1, $i + $nAfter)
                [pscustomobject]@{
                    Path   = $rel
                    Line   = $i + 1
                    Column = $hitMatch[$i].Index + 1
                    Match  = $hitMatch[$i].Value
                    Text   = $lines[$i]
                    Before = @(if ($i -gt $bs) { $lines[$bs..($i - 1)] })
                    After  = @(if ($ae -gt $i) { $lines[($i + 1)..$ae] })
                }
            }
            continue
        }

        if ($firstFile) { $firstFile = $false } else { '' }
        $rel

        $blockEnd = $null
        foreach ($i in $hitIdx) {
            $s = [Math]::Max(0, $i - $nBefore)
            $e = [Math]::Min($n - 1, $i + $nAfter)
            if ($null -ne $blockEnd) {
                if ($s -gt $blockEnd + 1) { '--' } else { $s = $blockEnd + 1 }   # join groups that overlap or touch
            }
            for ($k = $s; $k -le $e; $k++) {
                if ($hitMatch.ContainsKey($k)) { "$($k + 1):$(& $clip $lines[$k] $hitMatch[$k].Index)" }
                else                           { "$($k + 1)-$(& $clip $lines[$k] 0)" }
            }
            $blockEnd = if ($null -eq $blockEnd) { $e } else { [Math]::Max($blockEnd, $e) }
        }
    }

    # ---- 5. Summary ----------------------------------------------------------------------
    Write-Verbose "$total matching lines in $matchFiles files; $searched files searched, $skipped skipped (binary/large/unreadable)."

    if ($total -eq 0) {
        Write-Warning ("No matches for '$Pattern' in $searched files" +
            $(if ($skipped) { " ($skipped binary/large/unreadable skipped)" }) +
            ". Smart case: $(if ($sensitive) { 'case-sensitive' } else { 'ignoring case' }).")
    }
    elseif ($stopped) {
        Write-Warning "Stopped after $total matching lines (-MaxResults $MaxResults). Narrow the pattern or -Include, or raise -MaxResults."
    }
}
Export-ModuleMember -Function Search-Code