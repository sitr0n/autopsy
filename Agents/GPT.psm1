# A chatting agent that interfaces with the OpenAI API for 'chat completions'
class GPT {

    # Set the access credentials and a model choice
    GPT ([string]$model, [string]$token) {
        $this.model = $model
        $this.headers = @{ Authorization = "Bearer $token" }
    }



    # Set a rule for the chat session
    [void]Rule ([string]$command) {
        if ($this.Contains($command)) {
            return
        }
        $this.Message("system", $command) | Out-Null
    }


    # Add a file to the conversation context
    [void]File ([string]$path) {
        if ($this.Contains($path)) {
            return
        }
        $this.Rule("Code blocks shall be prepended with a file path and a new line if they have one")
        $this.Message("user", $this.MarkDown($path)) | Out-Null
    }


    # Ask the model for a reply
    [string]Say ([string]$message) {
        $this.Message("user", $message)
        return $this.Invoke(100)
    }


    # Parse the filesystem path into a message string
    [string]MarkDown ([string]$path) {

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
    [string]Invoke ([int]$MaxTokens) {

        # Set context for the chat completion
        $body = @{
            model    = $this.model
            messages = $this.messages
            store   = $false
            verbosity = "low" # "low" | "medium" | "high"
        } | ConvertTo-Json -Depth 12

        # Write model reply to disk
        $cache = [IO.Path]::GetTempFileName()
        try { Invoke-WebRequest $this.endpoint -Method Post -OutFile $cache `
                -Headers $this.headers `
                -ContentType 'application/json; charset=utf-8' `
                -Body $body

            # Convert the json text
            $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($cache))
            $obj  = $text | ConvertFrom-Json

            # Extract the reply from the model response
            $reply = [string]$obj.choices[0].message.content
            return $this.Message("assistant", $reply)

        # Clean up the file writing
        } finally { Remove-Item -LiteralPath $cache -ErrorAction SilentlyContinue }
    }

    
    # Register a message to the session context
    [string]Message ([string]$role, [string]$content) {

        # Append a 'who/what' pair to the conversation
        $this.messages.Add(@{
            role = $role
            content = $content
        }) | Out-Null
        return $content
    }


    # Check for duplicate chat context
    [bool]Contains ([string]$content ) { 
        return ($this.messages | Where-Object { $_.content -eq $content }).Count -gt 0
    }

    
    [string]$model
    [PSCustomObject]$headers
    [System.Collections.ArrayList]$messages = @()
    [string]$endpoint = "https://api.openai.com/v1/chat/completions"
}