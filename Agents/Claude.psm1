using module .\ChatAgent.psm1


# A chatting agent that interacts with the Anthropic Messages API
class Claude : ChatAgent
{
    # Construct a Claude model interaction object
    Claude([string]$model, [string]$token)
        : base($model, "https://api.anthropic.com/v1/messages")
    {
        $this.headers = @{
            "x-api-key"         = $token
            "anthropic-version" = "2023-06-01"
        }
        $this.options = @{
            max_tokens = 1000
        }
    }

    # Ask the CLaude model for a reply
    [string] Say([string]$prompt)
    {
        # Attach the prompt to the chat context
        $this.Message("user", $prompt) | Out-Null

        # Query a chat completion from the Anthropic server
        $response = $this.Invoke($this.options)
        $reply = [string]$response.content[0].text

        # Attach the reply to the chat context
        return $this.Message("assistant", $reply)
    }

    [hashtable] $options
}

