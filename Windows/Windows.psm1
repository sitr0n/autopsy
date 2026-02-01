# Check if the current session has administrator privileges
function Test-IsElevated {

    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [Security.Principal.WindowsPrincipal]::new($id)

    return $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
Export-ModuleMember -Function Test-IsElevated


# Invoke a PowerShell script file as administrator
function Run-Elevated {
    param(
        [Parameter(Mandatory)]
        [string]$script
    )

    $path = (Resolve-Path $script).Path

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$path`""
}
Export-ModuleMember -Function Run-Elevated


# Overwrite a directory background action in the Windows Registry
function New-BackgroundContext {
    param (
        [Parameter(Mandatory = $true)] [string] $name,
        [Parameter(Mandatory = $true)] [string] $command,
        [string] $icon = ""
    )

    if (-not (Test-IsElevated)) {
        throw "Session must be run as administrator"
    }

    # HKCR doesn't exist by defualt in PSDrives, so it needs to be created
    New-PSDrive -PSProvider Registry -Root HKEY_CLASSES_ROOT -Name HKCR

    # Set ContextMenu key
    New-Item -Path HKCR:\Directory\Background\shell -Name $name -Force |
    Set-ItemProperty -Name '(Default)' -Value $name

    ## Pass location of call as an argument
    $command += " `"%V`""

    # Set ContextMenu action
    New-Item -Path HKCR:\Directory\Background\shell\$name\command -Force |
    Set-ItemProperty -Name '(Default)' -Value $command

    # Set ContextMenu icon
    if (-not [string]::IsNullOrWhiteSpace($icon)) {
        $icon = "C:\Windows\system32\shell32.dll,$icon"
        Set-ItemProperty -Path HKCR:\Directory\Background\shell\$name -Name 'Icon' -Value $icon
    }
}
Export-ModuleMember -Function New-BackgroundContext


# Add a script shortcut to the Windows Explorer context menu
function New-ContextScript {
    param(
        [Parameter(Mandatory)] [string]$path,
        [string]$name = "",
        [string]$icon = "210"
    )

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = (Get-Item -LiteralPath $path).Name
    }

    try {
        $command = 'PowerShell.exe -File "' + "$path" + "`""
        New-BackgroundContext $name $command $icon  | Out-Null

    } catch {
        Write-Host "Exception: $_" -ForegroundColor Yellow
    }
}
Export-ModuleMember -Function New-ContextScript