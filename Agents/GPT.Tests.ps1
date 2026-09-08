#requires -Modules Pester
using module .\GPT.psm1

Describe 'GPT' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'ChatAgent.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'GPT.psm1') -Force

        $credentialsPath = Join-Path $PSScriptRoot 'credentials.json'
        $credentials = Get-Content -LiteralPath $credentialsPath -Raw | ConvertFrom-Json
        $script:GPTTests_Token = [string]$credentials.gpt.token
        $script:GPTTests_Model = "gpt-5.4"

        if ([string]::IsNullOrWhiteSpace($script:GPTTests_Token)) {
            throw "GPT token not found in $credentialsPath"
        }

        function New-TestGPT {
            [GPT]::new($script:GPTTests_Model, $script:GPTTests_Token)
        }
    }

    Context 'constructor' {
        It 'rejects an empty model name' {
            { [GPT]::new('', 'test-token') } |
                Should -Throw -ExpectedMessage '*Model name cannot be empty*'
        }

        It 'rejects an empty API token' {
            { [GPT]::new('gpt-test', '') } |
                Should -Throw -ExpectedMessage '*OpenAI API token cannot be empty*'
        }

        It 'sets endpoint, headers, and default options' {
            $agent = New-TestGPT

            $agent.model | Should -Be $script:GPTTests_Model
            $agent.endpoint | Should -Be 'https://api.openai.com/v1/chat/completions'
            $agent.headers['Authorization'] | Should -Be "Bearer $script:GPTTests_Token"
            $agent.options['store'] | Should -BeFalse
            $agent.options['verbosity'] | Should -Be 'low'
        }
    }

    Context 'Say' {
        It 'posts the prompt to the real API and stores the assistant reply' {
            $agent = New-TestGPT

            $reply = $agent.Say('Reply with exactly this text and nothing else: autopsy gpt test')

            $reply | Should -Not -BeNullOrEmpty
            $reply.Trim() | Should -Be 'autopsy gpt test'

            $agent.messages.Count | Should -Be 2
            $agent.messages[0]['role'] | Should -Be 'user'
            $agent.messages[0]['content'] | Should -Be 'Reply with exactly this text and nothing else: autopsy gpt test'
            $agent.messages[1]['role'] | Should -Be 'assistant'
            $agent.messages[1]['content'] | Should -Be $reply
        }
    }

    Context 'tools' {
        It 'registers a tool, lets the model call it, and stores the tool result' {
            $agent = New-TestGPT

            $path = Join-Path $PSScriptRoot 'GPT.psm1'
            $expectedItem = Get-Item -LiteralPath $path
            $expectedLength = $expectedItem.Length

            $script:GPTTests_ToolWasCalled = $false
            $script:GPTTests_ToolPath = $null

            $agent.Tool(
                "get_file_info",
                "Gets basic information about a local file.",
                @{
                    type = "object"
                    properties = @{
                        path = @{
                            type = "string"
                            description = "The local filesystem path."
                        }
                    }
                    required = @("path")
                },
                {
                    param($toolArgs)

                    $script:GPTTests_ToolWasCalled = $true
                    $script:GPTTests_ToolPath = [string]$toolArgs.path

                    $item = Get-Item -LiteralPath $toolArgs.path

                    return @{
                        path = $item.FullName
                        length = $item.Length
                        lastWriteTime = $item.LastWriteTimeUtc.ToString('o')
                    }
                }
            )

            $reply = $agent.Say("Use the get_file_info tool to get information about '$path'. Reply with exactly the file length integer and nothing else.")

            $script:GPTTests_ToolWasCalled | Should -BeTrue
            $script:GPTTests_ToolPath | Should -Be $path

            $reply | Should -Not -BeNullOrEmpty
            $reply.Trim() | Should -Be ([string]$expectedLength)

            $agent.tools.Count | Should -Be 1
            $agent.toolHandlers.ContainsKey("get_file_info") | Should -BeTrue

            $toolMessages = @($agent.messages | Where-Object { $_['role'] -eq 'tool' })
            $toolMessages.Count | Should -Be 1

            $toolResult = $toolMessages[0]['content'] | ConvertFrom-Json
            $toolResult.length | Should -Be $expectedLength
            $toolResult.path | Should -Be $expectedItem.FullName
        }
    }
}