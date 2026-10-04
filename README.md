## 🔍 Autopsy

`auto.ps1` is a `PowerShell` script designed to interact with a chat agent in the Windows terminal.

### 💻 Host

```powershell
$restriction = Get-ExecutionPolicy
Set-ExecutionPolicy Unrestricted
PowerShell.exe -File "auto.ps1"
Install-Shortcut
Set-ExecutionPolicy $restriction
```

Running a `PowerShell` script file on a modern Windows computer requires a relaxed policy on script execution. Temporarily set it to unrestricted before invoking the script file "auto.ps1". Create a shortcut to this script in the users context menu by typing `Install-Shortcut`.

---

<img src="./Docs/installed_to.png" style="width:44%; height:auto;" alt="Shortcut location">

---

Shift-right click on the background of `Windows File Explorer` and select `🔍 Autopsy` when you want to come back to this script. The file system location you clicked on will be used as the working directory.

### 🤖 Agents

```powershell
$token = Get-Clipboard
Set-Credentials "gpt" $token

$model = "gpt-5.2"
$agent = New-Agent $model

# Add file contents as context
$agent.file("my_context.txt")

# Invoke chat completion
$reply = $agent.say("make soup")
```

Obtain an access key from [OpenAI](https://platform.openai.com/api-keys) or [Anthropic](https://platform.claude.com/settings/keys) and feed it to the `Agents` module with the function `Set-Credentials`.

### 📁 Docs

Inspect the current state of the repository using functions from the `Docs` module.
