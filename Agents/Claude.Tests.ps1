#requires -Modules Pester
using module .\Claude.psm1

Describe 'Claude' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'ChatAgent.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'Claude.psm1') -Force

        $credentialsPath = Join-Path $PSScriptRoot 'credentials.json'
        $credentials = Get-Content -LiteralPath $credentialsPath -Raw | ConvertFrom-Json
        $script:ClaudeTests_Token = [string]$credentials.claude.token

        if ($credentials.claude.model) {
            $script:ClaudeTests_Model = [string]$credentials.claude.model
        }
        else {
            $script:ClaudeTests_Model = "claude-haiku-4-5-20251001"
        }

        if ([string]::IsNullOrWhiteSpace($script:ClaudeTests_Token)) {
            throw "Claude token not found in $credentialsPath"
        }

        function New-TestClaude {
            [Claude]::new($script:ClaudeTests_Model, $script:ClaudeTests_Token)
        }
    }

    Context 'constructor' {
        It 'rejects an empty model name' {
            { [Claude]::new('', 'test-token') } |
                Should -Throw -ExpectedMessage '*Model name cannot be empty*'
        }

        It 'rejects an empty API token' {
            { [Claude]::new('claude-test', '') } |
                Should -Throw -ExpectedMessage '*Anthropic API token cannot be empty*'
        }

        It 'sets endpoint, headers, and default options' {
            $agent = New-TestClaude

            $agent.model | Should -Be $script:ClaudeTests_Model
            $agent.endpoint | Should -Be 'https://api.anthropic.com/v1/messages'
            $agent.headers['x-api-key'] | Should -Be $script:ClaudeTests_Token
            $agent.headers['anthropic-version'] | Should -Be '2023-06-01'
            $agent.options['max_tokens'] | Should -Be 1000
        }
    }

    Context 'Say' {
        It 'posts the prompt to the real API and stores the assistant reply' {
            $agent = New-TestClaude

            $reply = $agent.Say('Reply with exactly this text and nothing else: autopsy claude test')

            $reply | Should -Not -BeNullOrEmpty
            $reply.Trim() | Should -Be 'autopsy claude test'

            $agent.messages.Count | Should -Be 2
            $agent.messages[0]['role'] | Should -Be 'user'
            $agent.messages[0]['content'] | Should -Be 'Reply with exactly this text and nothing else: autopsy claude test'
            $agent.messages[1]['role'] | Should -Be 'assistant'
            $agent.messages[1]['content'] | Should -Be $reply
        }
    }

    Context 'tools' {
        It 'registers a tool, lets the model call it, and stores the tool result' {
            $agent = New-TestClaude

            $path = Join-Path $PSScriptRoot 'Claude.psm1'
            $expectedItem = Get-Item -LiteralPath $path
            $expectedLength = $expectedItem.Length

            $script:ClaudeTests_ToolWasCalled = $false
            $script:ClaudeTests_ToolPath = $null

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

                    $script:ClaudeTests_ToolWasCalled = $true
                    $script:ClaudeTests_ToolPath = [string]$toolArgs.path

                    $item = Get-Item -LiteralPath $toolArgs.path

                    return @{
                        path = $item.FullName
                        length = $item.Length
                        lastWriteTime = $item.LastWriteTimeUtc.ToString('o')
                    }
                }
            )

            $reply = $agent.Say("Use the get_file_info tool to get information about '$path'. Reply with exactly the file length integer and nothing else.")

            $script:ClaudeTests_ToolWasCalled | Should -BeTrue
            $script:ClaudeTests_ToolPath | Should -Be $path

            $reply | Should -Not -BeNullOrEmpty
            $reply.Trim() | Should -Be ([string]$expectedLength)

            $agent.tools.Count | Should -Be 1
            $agent.toolHandlers.ContainsKey("get_file_info") | Should -BeTrue
            $assistantToolMessages = @(
                $agent.messages |
                    Where-Object {
                        $_['role'] -eq 'assistant' -and
                        @($_['content'] | Where-Object { $_.type -eq 'tool_use' }).Count -gt 0
                    }
            )

            $assistantToolMessages.Count | Should -Be 1

            $toolResultMessages = @(
                $agent.messages |
                    Where-Object {
                        $_['role'] -eq 'user' -and
                        @($_['content'] | Where-Object { $_.type -eq 'tool_result' }).Count -gt 0
                    }
            )

            $toolResultMessages.Count | Should -Be 1

            $toolResults = @($toolResultMessages[0]['content'] | Where-Object { $_.type -eq 'tool_result' })
            $toolResults.Count | Should -Be 1

            $toolResult = $toolResults[0].content | ConvertFrom-Json
            $toolResult.length | Should -Be $expectedLength
            $toolResult.path | Should -Be $expectedItem.FullName
        }
    }
}