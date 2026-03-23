using module .\ChatAgent.psm1


# A chatting agent that interacts with the OpenAI API for 'chat completions'
class GPT : ChatAgent
{
    # Construct a GPT model interaction object
    GPT([string]$model, [string]$token)
        : base($model, "https://api.openai.com/v1/chat/completions")
    {
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
        # Attach the prompt to the chat context
        $this.Message("user", $prompt) | Out-Null

        # Query a chat completion from the OpenAI server
        $response = $this.Invoke($this.options)
        $reply = [string]$response.choices[0].message.content

        # Attach the reply to the chat context
        return $this.Message("assistant", $reply)
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

    [hashtable] $options
}