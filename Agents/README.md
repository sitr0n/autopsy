This library interfaces the OpenAI GPT models

### Example

```powershell
$token = "eyJhbG.eyJzdW..and so on"
Set-Credentials $token

$model = "gpt-5.2"
$agent = New-Agent $model

# Add file contents as context
$agent.file("my_context.txt")

# Invoke chat completion
$reply = $agent.say("make soup")
```

### Limitation

`gpt-5.1` has to use the legacy endpoint `/chat/completions` for now, which limits the available model parameters. That means that we cannot adjust "reasoning effort" for gpt5.
