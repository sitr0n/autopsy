## 🔍 Autopsy

A `PowerShell` script to interact with OpenAI GPT models in the terminal.

### Install

Temporarily disable the script execution restriction by typing `Set-ExecutionPolicy Unrestricted` in a PowerShell terminal and then run the script file `auto.ps1`. Invoke the local function `install` from any file system location to make this script file available in the `Windows File Explorer` shift-right-click menu.

### Load

Invoke the function `load` to import the PowerShell modules located in the current directory and sub-directories, making the exported functions available for this shell.

### Add

Use the `add` function with a file name argument to attach the contents of that file to the chat context of the GPT interaction, then ask your question.
