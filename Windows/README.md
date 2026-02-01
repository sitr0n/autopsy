This library contains Windows operating system specific functions

### Example

```powershell
$script = $MyInvocation.MyCommand.Path
$name = "Open $script"

# Modifying the Windows Registry requires administrator privileges
if (Test-IsElevated) {

    # Add a new action when shift right-clicking the Windows Explorer background
    New-ContextScript -Path $script -Name $name -Icon '209'

} else {

    # Open a new session as administrator
    Run-Elevated $script
}
```
