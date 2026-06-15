using module .\ChatAgent.psm1


# A chatting agent that interacts with the OpenAI API for 'chat completions'
class GPT : ChatAgent
{
    GPT([string]$model, [string]$token)
        : base($model, "https://api.openai.com/v1/chat/completions")
    {
        if ([string]::IsNullOrWhiteSpace($model)) {
            throw "Model name cannot be empty."
        }

        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "OpenAI API token cannot be empty."
        }

        $this.headers = @{
            Authorization = "Bearer $token"
        }

        # Verify that the requested model exists / is accessible
        $escapedModel = [Uri]::EscapeDataString($model)
        $modelUri = "https://api.openai.com/v1/models/$escapedModel"

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

            throw "OpenAI model '$model' is not available or could not be validated: $message"
        }
        
        $this.headers = @{
            Authorization = "Bearer $token"
        }
        $this.options = @{
            store     = $false
            verbosity = "low"
        }
    }


    # Ask the GPT model for a reply
    [string] Say([string]$prompt)
    {
        $this.Message("user", $prompt) | Out-Null

        $requestOptions = @{}
        foreach ($key in $this.options.Keys) {
            $requestOptions[$key] = $this.options[$key]
        }

        if ($this.tools.Count -gt 0) {
            $requestOptions["tools"] = $this.tools
            $requestOptions["tool_choice"] = "auto"
        }

        for ($i = 0; $i -lt 8; $i++) {
            $response = $this.Invoke($requestOptions)

            if (-not $response.choices -or $response.choices.Count -lt 1) {
                throw "OpenAI response did not contain any choices."
            }

            $choice = $response.choices[0]
            $message = $choice.message

            if ($message.refusal) {
                throw "OpenAI refused the request: $($message.refusal)"
            }

            # If the model wants tools, execute them and continue.
            if ($message.tool_calls -and $message.tool_calls.Count -gt 0) {
                $this.RawMessage(@{
                    role = "assistant"
                    content = $message.content
                    tool_calls = $message.tool_calls
                })

                foreach ($toolCall in $message.tool_calls) {
                    $toolName = [string]$toolCall.function.name
                    $argumentsJson = [string]$toolCall.function.arguments

                    Write-Host "Calling $toolName"
                    Write-Host $argumentsJson

                    if (-not $this.toolHandlers.ContainsKey($toolName)) {
                        throw "Model requested unknown tool: $toolName"
                    }

                    $arguments = $null
                    if (-not [string]::IsNullOrWhiteSpace($argumentsJson)) {
                        $arguments = $argumentsJson | ConvertFrom-Json
                    }

                    try {
                        $result = & $this.toolHandlers[$toolName] $arguments
                    }
                    catch {
                        $result = @{
                            error = $_.Exception.Message
                        }
                    }

                    if ($result -is [string]) {
                        $toolContent = $result
                    }
                    else {
                        $toolContent = $result | ConvertTo-Json -Depth 12
                    }

                    $this.RawMessage(@{
                        role = "tool"
                        tool_call_id = $toolCall.id
                        content = $toolContent
                    })
                }

                continue
            }

            $reply = [string]$message.content

            if ([string]::IsNullOrWhiteSpace($reply)) {
                throw "OpenAI response did not contain message content. Finish reason: $($choice.finish_reason)"
            }

            return $this.Message("assistant", $reply)
        }

        throw "Tool call loop exceeded maximum iterations."
    }


    # Add a file to the conversation context
    [void] File([string] $path)
    {
        if ($this.Contains($path)) {
            return
        }
        $this.Rule("Code blocks shall be prepended with a file path and a new line if they have one")
        $this.Message("user", $this.MarkDown($path)) | Out-Null
    }


    # Add an image to the conversation context
    [void] Image([string] $path, [string] $prompt)
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
        $dataUrl = "data:$mime;base64,$base64"

        $this.messages.Add(@{
            role = "user"
            content = @(
                @{
                    type = "text"
                    text = $prompt
                },
                @{
                    type = "image_url"
                    image_url = @{
                        url = $dataUrl
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
            type = "function"
            function = @{
                name = $name
                description = $description
                parameters = $parameters
            }
        }) | Out-Null

        $this.toolHandlers[$name] = $handler
    }

    [hashtable] $options
    [System.Collections.ArrayList] $tools = @()
    [hashtable] $toolHandlers = @{}
}