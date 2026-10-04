#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for Show-Markdown (Host.psm1)

    Run with:  Invoke-Pester .\Host.Tests.ps1 -Output Detailed

    Write-Host writes to the information stream (6), so the output of
    Show-Markdown is captured with 6>&1. Each record is a
    HostInformationMessage that carries the text, colors and NoNewLine flag,
    so no mocking is needed.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\Host.psm1" -Force

    $script:White   = [System.ConsoleColor]::White
    $script:Black   = [System.ConsoleColor]::Black
    $script:Cyan    = [System.ConsoleColor]::Cyan
    $script:Magenta = [System.ConsoleColor]::Magenta

    # Groups the captured Write-Host records into rendered lines of colored segments
    function ConvertTo-RenderedLines {
        param([object[]] $Records)

        $segments = [System.Collections.Generic.List[object]]::new()

        foreach ($record in $Records) {
            $message = $record.MessageData
            if ($message -isnot [System.Management.Automation.HostInformationMessage]) { continue }

            if ($message.Message -ne '') {
                $segments.Add([pscustomobject]@{
                    Text       = [string] $message.Message
                    Foreground = $message.ForegroundColor
                    Background = $message.BackgroundColor
                })
            }

            if (-not $message.NoNewLine) {
                [pscustomobject]@{
                    Text     = -join ($segments | ForEach-Object Text)
                    Segments = $segments.ToArray()
                }
                $segments.Clear()
            }
        }
    }

    function Invoke-ShowMarkdown {
        param([AllowEmptyString()][string] $Markdown)
        ConvertTo-RenderedLines @(Show-Markdown $Markdown 6>&1)
    }
}

AfterAll {
    #Remove-Module Host -Force -ErrorAction SilentlyContinue
}

Describe 'Show-Markdown' {

    Context 'Plain text and line handling' {

        It 'writes plain text in the primary color on the backdrop color' {
            $lines = @(Invoke-ShowMarkdown 'Hello world')

            $lines.Count | Should -Be 1
            $lines[0].Segments.Count | Should -Be 1
            $lines[0].Segments[0].Text | Should -Be 'Hello world'
            $lines[0].Segments[0].Foreground | Should -Be $White
            $lines[0].Segments[0].Background | Should -Be $Black
        }

        It 'writes a single empty line for an empty string' {
            $lines = @(Invoke-ShowMarkdown '')

            $lines.Count | Should -Be 1
            $lines[0].Segments.Count | Should -Be 0
        }

        It 'splits text on LF and CRLF line endings' {
            $lines = @(Invoke-ShowMarkdown "one`ntwo`r`nthree")

            $lines.Count | Should -Be 3
            $lines.Text | Should -Be @('one', 'two', 'three')
        }

        It 'preserves blank lines between paragraphs' {
            $lines = @(Invoke-ShowMarkdown "first`n`nsecond")

            $lines.Count | Should -Be 3
            $lines[1].Text | Should -Be ''
        }
    }

    Context 'Pipeline input' {

        It 'accepts multiple strings from the pipeline' {
            $lines = @(ConvertTo-RenderedLines @('a', 'b', 'c' | Show-Markdown 6>&1))

            $lines.Text | Should -Be @('a', 'b', 'c')
        }

        It 'keeps code block state across pipeline items' {
            $lines = @(ConvertTo-RenderedLines @('```', '**code**', '```' | Show-Markdown 6>&1))

            $lines.Count | Should -Be 1
            $lines[0].Text | Should -Be '    **code**'
        }
    }

    Context 'Headings' {

        It 'renders "<Markdown>" as "<Expected>" in the primary accent' -TestCases @(
            @{ Markdown = '# Title';         Expected = 'Title' }
            @{ Markdown = '###### Deep';     Expected = 'Deep' }
            @{ Markdown = '## Closed ##';    Expected = 'Closed' }
            @{ Markdown = '   ### Indented'; Expected = 'Indented' }
        ) {
            $lines = @(Invoke-ShowMarkdown $Markdown)

            $lines.Count | Should -Be 1
            $lines[0].Text | Should -Be $Expected
            $lines[0].Segments[0].Foreground | Should -Be $Cyan
        }

        It 'does not treat seven hashes as a heading' {
            $lines = @(Invoke-ShowMarkdown '####### x')

            $lines[0].Text | Should -Be '####### x'
            $lines[0].Segments[0].Foreground | Should -Be $White
        }

        It 'does not treat a hash without a following space as a heading' {
            $lines = @(Invoke-ShowMarkdown '#hashtag')

            $lines[0].Text | Should -Be '#hashtag'
            $lines[0].Segments[0].Foreground | Should -Be $White
        }

        It 'renders inline markdown inside a heading' {
            $lines = @(Invoke-ShowMarkdown '# Use `code`')
            $segments = $lines[0].Segments

            $segments[0].Text | Should -Be 'Use '
            $segments[0].Foreground | Should -Be $Cyan
            $segments[1].Text | Should -Be 'code'
            $segments[1].Foreground | Should -Be $Black
            $segments[1].Background | Should -Be $White
        }
    }

    Context 'Inline formatting' {

        It 'renders **bold** in the secondary accent' {
            $segments = @(Invoke-ShowMarkdown 'a **b** c')[0].Segments

            $segments.Text | Should -Be @('a ', 'b', ' c')
            $segments[0].Foreground | Should -Be $White
            $segments[1].Foreground | Should -Be $Magenta
            $segments[2].Foreground | Should -Be $White
        }

        It 'renders <Markdown> italics in the primary accent' -TestCases @(
            @{ Markdown = 'an *italic* word' }
            @{ Markdown = 'an _italic_ word' }
        ) {
            $segments = @(Invoke-ShowMarkdown $Markdown)[0].Segments

            $segments.Text | Should -Be @('an ', 'italic', ' word')
            $segments[1].Foreground | Should -Be $Cyan
        }

        It 'renders `code` with inverted colors' {
            $segments = @(Invoke-ShowMarkdown 'run `ls -la` now')[0].Segments

            $segments.Text | Should -Be @('run ', 'ls -la', ' now')
            $segments[1].Foreground | Should -Be $Black
            $segments[1].Background | Should -Be $White
        }

        It 'renders only the text of a [link](url)' {
            $lines = @(Invoke-ShowMarkdown 'see [the docs](https://example.com) here')
            $segments = $lines[0].Segments

            $lines[0].Text | Should -Be 'see the docs here'
            $segments[1].Text | Should -Be 'the docs'
            $segments[1].Foreground | Should -Be $Cyan
        }

        It 'does not treat underscores inside words as italics' {
            $segments = @(Invoke-ShowMarkdown 'my_snake_case_name')[0].Segments

            $segments.Count | Should -Be 1
            $segments[0].Text | Should -Be 'my_snake_case_name'
            $segments[0].Foreground | Should -Be $White
        }

        It 'does not treat an arithmetic asterisk as italics' {
            $segments = @(Invoke-ShowMarkdown '2 * 3 * 4')[0].Segments

            ($segments | ForEach-Object Text) -join '' | Should -Be '2 * 3 * 4'
            $segments | ForEach-Object { $_.Foreground | Should -Be $White }
        }

        It 'renders multiple inline styles on one line' {
            $lines = @(Invoke-ShowMarkdown '**bold** and `code` and *italic*')

            $lines[0].Text | Should -Be 'bold and code and italic'
            $lines[0].Segments.Count | Should -Be 5
        }
    }

    Context 'Lists' {

        It 'renders "<Marker>" unordered list items with a bullet' -TestCases @(
            @{ Marker = '-' }
            @{ Marker = '*' }
            @{ Marker = '+' }
        ) {
            $segments = @(Invoke-ShowMarkdown "$Marker item")[0].Segments

            $segments[0].Text | Should -Be "  $([char]0x2022) "
            $segments[0].Foreground | Should -Be $Magenta
            $segments[1].Text | Should -Be 'item'
            $segments[1].Foreground | Should -Be $White
        }

        It 'keeps the indentation of nested list items' {
            $segments = @(Invoke-ShowMarkdown '  - nested')[0].Segments

            $segments[0].Text | Should -Be "    $([char]0x2022) "
        }

        It 'renders inline markdown inside list items' {
            $segments = @(Invoke-ShowMarkdown '- **important**')[0].Segments

            $segments[1].Text | Should -Be 'important'
            $segments[1].Foreground | Should -Be $Magenta
        }

        It 'renders ordered list item "<Markdown>" with prefix "<Prefix>"' -TestCases @(
            @{ Markdown = '1. first';  Prefix = '  1. ' }
            @{ Markdown = '2) second'; Prefix = '  2. ' }
            @{ Markdown = '10. tenth'; Prefix = '  10. ' }
        ) {
            $segments = @(Invoke-ShowMarkdown $Markdown)[0].Segments

            $segments[0].Text | Should -Be $Prefix
            $segments[0].Foreground | Should -Be $Magenta
            $segments[1].Foreground | Should -Be $White
        }
    }

    Context 'Block quotes' {

        It 'renders a quote with a bar and primary accent text' {
            $segments = @(Invoke-ShowMarkdown '> quoted text')[0].Segments

            $segments[0].Text | Should -Be "  $([char]0x2502) "
            $segments[0].Foreground | Should -Be $Magenta
            $segments[1].Text | Should -Be 'quoted text'
            $segments[1].Foreground | Should -Be $Cyan
        }

        It 'renders a quote without a space after the marker' {
            $segments = @(Invoke-ShowMarkdown '>tight')[0].Segments

            $segments[1].Text | Should -Be 'tight'
        }
    }

    Context 'Horizontal rules' {

        It 'renders "<Markdown>" as a line of box drawing characters' -TestCases @(
            @{ Markdown = '---' }
            @{ Markdown = '***' }
            @{ Markdown = '___' }
            @{ Markdown = '- - -' }
            @{ Markdown = '----------' }
        ) {
            $lines = @(Invoke-ShowMarkdown $Markdown)
            $segment = $lines[0].Segments[0]

            $lines[0].Segments.Count | Should -Be 1
            $segment.Text | Should -Match "^$([char]0x2500){3,}$"
            $segment.Foreground | Should -Be $Magenta
        }

        It 'does not treat two dashes as a horizontal rule' {
            $lines = @(Invoke-ShowMarkdown '--')

            $lines[0].Text | Should -Be '--'
        }
    }

    Context 'Code blocks' {

        It 'hides <Fence> fences and indents the code in the primary accent' -TestCases @(
            @{ Fence = '```' }
            @{ Fence = '~~~' }
            @{ Fence = '```powershell' }
        ) {
            $lines = @(Invoke-ShowMarkdown "$Fence`nGet-Item .`n$($Fence.Substring(0, 3))")

            $lines.Count | Should -Be 1
            $lines[0].Segments.Count | Should -Be 1
            $lines[0].Segments[0].Text | Should -Be '    Get-Item .'
            $lines[0].Segments[0].Foreground | Should -Be $Cyan
        }

        It 'does not parse markdown inside a code block' {
            $fence = '```'
            $markdown = "$fence`n# not a heading`n- not a list`n**not bold**`n$fence"
            $lines = @(Invoke-ShowMarkdown $markdown)

            $lines.Text | Should -Be @('    # not a heading', '    - not a list', '    **not bold**')
            $lines | ForEach-Object { $_.Segments.Count | Should -Be 1 }
        }

        It 'resumes markdown parsing after the closing fence' {
            $fence = '```'
            $lines = @(Invoke-ShowMarkdown "$fence`ncode`n$fence`n# Heading")

            $lines.Count | Should -Be 2
            $lines[1].Text | Should -Be 'Heading'
            $lines[1].Segments[0].Foreground | Should -Be $Cyan
        }

        It 'renders empty lines inside a code block' {
            $fence = '```'
            $lines = @(Invoke-ShowMarkdown "$fence`na`n`nb`n$fence")

            $lines.Text | Should -Be @('    a', '    ', '    b')
        }
    }

    Context 'Parameters' {

        It 'has a mandatory markdown parameter' {
            $parameter = (Get-Command Show-Markdown).Parameters['markdown']
            $attribute = $parameter.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }

            $attribute.Mandatory | Should -BeTrue
            $attribute.ValueFromPipeline | Should -BeTrue
        }

        It 'writes nothing to the success output stream' {
            $output = Show-Markdown "# Title`n- item" 6>$null

            $output | Should -BeNullOrEmpty
        }
    }
}
