using module .\ChatAgent.psm1


# A chatting agent that interacts with the Anthropic Messages API
class Claude : ChatAgent
{
    # Construct a Claude model interaction object
    Claude([string]$model, [string]$token)
        : base($model, "https://api.anthropic.com/v1/messages")
    {
        if ([string]::IsNullOrWhiteSpace($model)) {
            throw "Model name cannot be empty."
        }

        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Anthropic API token cannot be empty."
        }

        $this.headers = @{
            "x-api-key"         = $token
            "anthropic-version" = "2023-06-01"
        }

        # Verify that the requested model exists / is accessible
        $escapedModel = [Uri]::EscapeDataString($model)
        $modelUri = "https://api.anthropic.com/v1/models/$escapedModel"

        try {
            $null = Invoke-RestMethod `
                -Uri $modelUri `
                -Method Get `
                -Headers $this.headers `
                -ErrorAction Stop
        }
        catch {
            $message = $_.Exception.Message

            if ($_.ErrorDetails.Message) {
                $message = $_.ErrorDetails.Message
            }

            throw "Anthropic model '$model' is not available or could not be validated: $message"
        }

        $this.options = @{
            max_tokens = 10000
        }
    }


    # Set a rule for the chat session
    [void] Rule([string]$command)
    {
        $this.options["system"] = $command
    }


    # Ask the Claude model for a reply
    [string] Say([string]$prompt)
    {
        $this.Message("user", $prompt) | Out-Null

        $requestOptions = @{}
        foreach ($key in $this.options.Keys) {
            $requestOptions[$key] = $this.options[$key]
        }

        if ($this.tools.Count -gt 0) {
            $requestOptions["tools"] = $this.tools
        }

        for ($i = 0; $i -lt 8; $i++) {
            $response = $this.Invoke($requestOptions)

            if (-not $response.content -or $response.content.Count -lt 1) {
                throw "Anthropic response did not contain any content."
            }

            $contentBlocks = @($response.content)
            $toolUses = @($contentBlocks | Where-Object { $_.type -eq "tool_use" })

            # If the model wants tools, execute them and continue.
            if ($toolUses.Count -gt 0) {
                $this.RawMessage(@{
                    role    = "assistant"
                    content = $contentBlocks
                })

                $toolResults = [System.Collections.ArrayList]@()

                foreach ($toolUse in $toolUses) {
                    $toolName = [string]$toolUse.name
                    $arguments = $toolUse.input

                    Write-Host "Calling $toolName"
                    Write-Host ($arguments | ConvertTo-Json -Depth 12)

                    if (-not $this.toolHandlers.ContainsKey($toolName)) {
                        throw "Model requested unknown tool: $toolName"
                    }

                    try {
                        $result = & $this.toolHandlers[$toolName] $arguments
                    }
                    catch {
                        $result = @{
                            error = $_.Exception.Message
                        }
                    }

                    if ($null -eq $result) {
                        $toolContent = "null"
                    }
                    elseif ($result -is [string]) {
                        $toolContent = $result
                    }
                    else {
                        $toolContent = $result | ConvertTo-Json -Depth 12
                    }

                    $toolResults.Add(@{
                        type        = "tool_result"
                        tool_use_id = [string]$toolUse.id
                        content     = $toolContent
                    }) | Out-Null
                }

                $this.RawMessage(@{
                    role    = "user"
                    content = $toolResults
                })

                continue
            }

            $textBlocks = @(
                $contentBlocks |
                    Where-Object {
                        $_.type -eq "text" -and
                        -not [string]::IsNullOrWhiteSpace([string]$_.text)
                    }
            )

            $reply = ($textBlocks | ForEach-Object { [string]$_.text }) -join "`n"

            if ([string]::IsNullOrWhiteSpace($reply)) {
                throw "Anthropic response did not contain text content. Stop reason: $($response.stop_reason)"
            }

            return $this.Message("assistant", $reply)
        }

        throw "Tool call loop exceeded maximum iterations."
    }


    # Add a file to the conversation context
    [void] File([string]$path)
    {
        $markdown = $this.MarkDown($path)

        if ($this.Contains($markdown)) {
            return
        }

        $this.Rule("Code blocks shall be prepended with a file path and a new line if they have one")
        $this.Message("user", $markdown) | Out-Null
    }


    # Add an image to the conversation context
    [void] Image([string]$path, [string]$prompt)
    {
        if (-not (Test-Path $path -PathType Leaf)) {
            throw "Image not found: $path"
        }

        $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()

        $mime = switch ($extension) {
            ".png"  { "image/png" }
            ".jpg"  { "image/jpeg" }
            ".jpeg" { "image/jpeg" }
            ".webp" { "image/webp" }
            ".gif"  { "image/gif" }
            default { throw "Unsupported image type: $extension" }
        }

        $bytes = [IO.File]::ReadAllBytes($path)
        $base64 = [Convert]::ToBase64String($bytes)

        $this.messages.Add(@{
            role    = "user"
            content = @(
                @{
                    type = "text"
                    text = $prompt
                },
                @{
                    type   = "image"
                    source = @{
                        type       = "base64"
                        media_type = $mime
                        data       = $base64
                    }
                }
            )
        }) | Out-Null
    }


    # Register a callable tool
    [void] Tool(
        [string]$name,
        [string]$description,
        [hashtable]$parameters,
        [scriptblock]$handler
    )
    {
        if ($this.toolHandlers.ContainsKey($name)) {
            throw "Tool already registered: $name"
        }

        $this.tools.Add(@{
            name         = $name
            description  = $description
            input_schema = $parameters
        }) | Out-Null

        $this.toolHandlers[$name] = $handler
    }
}