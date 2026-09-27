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
Export-ModuleMember -Function Apply-Patch


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

