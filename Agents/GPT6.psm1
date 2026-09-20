using module .\ResponsesApi.psm1


# A chatting agent that interacts with the OpenAI API for 'responses'
class GPT6 : ResponsesApi
{
    GPT6([string]$model, [string]$token)
        : base($model, "https://api.openai.com/v1/responses")
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

        $this.options = @{
            # Nothing is stored server side, so reasoning must round-trip encrypted with the input
            store   = $false
            include = @("reasoning.encrypted_content")
            text    = @{
                verbosity = "low"
            }
            #reasoning = @{ effort = "low" }
        }
    }


    # Ask the model for a reply
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

            if ($response.error) {
                throw "OpenAI returned an error: $($response.error.code) - $($response.error.message)"
            }

            if ($response.status -eq "incomplete") {
                throw "OpenAI response was incomplete: $($response.incomplete_details.reason)"
            }

            if (-not $response.output -or $response.output.Count -lt 1) {
                throw "OpenAI response did not contain any output items."
            }

            $calledTool = $false
            $reply = [Text.StringBuilder]::new()

            foreach ($item in $response.output) {
                # Echo every output item (reasoning, message, function_call) back into the context
                $this.RawItem($item)

                switch ($item.type) {
                    "message" {
                        foreach ($part in $item.content) {
                            if ($part.type -eq "refusal") {
                                throw "OpenAI refused the request: $($part.refusal)"
                            }
                            if ($part.type -eq "output_text") {
                                $reply.Append($part.text) | Out-Null
                            }
                        }
                    }
                    "function_call" {
                        $calledTool = $true
                        $this.RawItem(@{
                            type    = "function_call_output"
                            call_id = $item.call_id
                            output  = $this.CallTool([string]$item.name, [string]$item.arguments)
                        })
                    }
                }
            }

            # The model wants tool results before it can answer
            if ($calledTool) {
                continue
            }

            $text = $reply.ToString()

            if ([string]::IsNullOrWhiteSpace($text)) {
                throw "OpenAI response did not contain message content. Status: $($response.status)"
            }

            return $text
        }

        throw "Tool call loop exceeded maximum iterations."
    }


    # Execute a registered tool handler and serialize its result for the model
    [string] CallTool([string]$name, [string]$argumentsJson)
    {
        Write-Host "Calling $name"
        Write-Host $argumentsJson

        if (-not $this.toolHandlers.ContainsKey($name)) {
            throw "Model requested unknown tool: $name"
        }

        $arguments = $null
        if (-not [string]::IsNullOrWhiteSpace($argumentsJson)) {
            $arguments = $argumentsJson | ConvertFrom-Json
        }

        try {
            $result = & $this.toolHandlers[$name] $arguments
        }
        catch {
            $result = @{
                error = $_.Exception.Message
            }
        }

        if ($result -is [string]) {
            return $result
        }

        return ($result | ConvertTo-Json -Depth 12)
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
        $dataUrl = "data:$mime;base64,$base64"

        $this.RawItem(@{
            type    = "message"
            role    = "user"
            content = @(
                @{
                    type = "input_text"
                    text = $prompt
                },
                @{
                    type      = "input_image"
                    image_url = $dataUrl
                    detail    = "auto"
                }
            )
        })
    }


    # Register a callable tool (Responses API uses a flat function definition)
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
            type        = "function"
            name        = $name
            description = $description
            parameters  = $parameters
        }) | Out-Null

        $this.toolHandlers[$name] = $handler
    }
}