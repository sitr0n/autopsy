# A base class for interfacing LLM model APIs that follow the 'responses' item model
class ResponsesApi
{
    ResponsesApi([string]$model, [string]$endpoint)
    {
        $this.model = $model
        $this.endpoint = $endpoint
    }


    # Set a rule for the session (developer instructions take precedence over user input)
    [void] Rule([string]$command)
    {
        if ($this.Contains($command)) {
            return
        }
        $this.Message("developer", $command) | Out-Null
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


    # Post the input items to the API
    [psobject] Invoke([hashtable]$options)
    {
        $body = @{
            model = $this.model
            input = $this.items
        }

        foreach ($key in $options.Keys) {
            $body[$key] = $options[$key]
        }

        $body = $body | ConvertTo-Json -Depth 20

        # Write model reply to disk
        $cache = [IO.Path]::GetTempFileName()
        try { Invoke-WebRequest $this.endpoint -Method Post -OutFile $cache `
                -Headers $this.headers `
                -ContentType 'application/json; charset=utf-8' `
                -Body $body

            # Convert the json text
            return [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($cache)) | ConvertFrom-Json

        # Clean up the file writing
        } finally {
            Remove-Item -LiteralPath $cache -ErrorAction SilentlyContinue
        }
    }


    # Register a plain text message item to the session context
    [string] Message([string]$role, [string]$content)
    {
        $this.items.Add(@{
            type    = "message"
            role    = $role
            content = $content
        }) | Out-Null
        return $content
    }


    # Register a raw input/output item (message, function_call, reasoning, ...) to the session context
    [void] RawItem([psobject]$item)
    {
        $this.items.Add($item) | Out-Null
    }


    # Check for duplicate text content in the session context
    [bool] Contains([string]$content)
    {
        foreach ($item in $this.items) {
            if (($item.content -is [string]) -and ($item.content -eq $content)) {
                return $true
            }
        }
        return $false
    }


    [string]$model
    [string]$endpoint
    [hashtable]$headers
    [hashtable]$options
    # Named 'items' rather than 'input' to avoid clashing with PowerShell's automatic $input variable
    [System.Collections.ArrayList]$items = @()
    [System.Collections.ArrayList]$tools = @()
    [hashtable]$toolHandlers = @{}
}