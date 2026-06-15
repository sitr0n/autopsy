# A base class for interfacing LLM model APIs
class ChatAgent
{
    ChatAgent([string]$model, [string]$endpoint)
    {
        $this.model = $model
        $this.endpoint = $endpoint
    }


    # Set a rule for the chat session
    [void] Rule([string]$command)
    {
        if ($this.Contains($command)) {
            return
        }
        $this.Message("system", $command) | Out-Null
    }


    # Parse the filesystem path into a message string
    [string] MarkDown([string]$path)
    {

        # Ensure the file exists
        if (-not (Test-Path $path -PathType Leaf)) {
            throw "File not found: $path"
        }

        # Read file content
        $content = Get-Content -Raw -Path $path

        # Format the output string
        return "$path`n```````n$content`n``````"
    }


# Post the conversation to the API
[psobject] Invoke([hashtable]$options)
{
    $body = @{
        model    = $this.model
        messages = $this.messages
    }

    foreach ($key in $options.Keys) {
        $body[$key] = $options[$key]
    }

    $json = $body | ConvertTo-Json -Depth 12

    try {
        return Invoke-RestMethod `
            -Uri $this.endpoint `
            -Method Post `
            -Headers $this.headers `
            -ContentType 'application/json; charset=utf-8' `
            -Body $json `
            -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message

        if ($_.ErrorDetails.Message) {
            $message = $_.ErrorDetails.Message
        }

        throw "OpenAI API request failed: $message"
    }
}

    
    # Register a message to the session context
    [string] Message([string]$role, [string]$content)
    {
        # Append a 'who/what' pair to the conversation
        $this.messages.Add(@{
            role = $role
            content = $content
        }) | Out-Null
        return $content
    }


    # Register a raw message object to the session context
    [void] RawMessage([hashtable]$message)
    {
        $this.messages.Add($message) | Out-Null
    }


    # Check for duplicate chat context
    [bool] Contains([string]$content)
    { 
        return ($this.messages | Where-Object { $_.content -eq $content }).Count -gt 0
    }

    
    [string]$model
    [string]$endpoint
    [hashtable]$headers
    [System.Collections.ArrayList]$messages = @()
}