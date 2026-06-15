#[CmdletBinding()]
#param([System.Management.Automation.ActionPreference]$DebugPreference = 'SilentlyContinue')

try {
    # Prefer UTF-8 in all hosts
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

    # On older consoles, also set the active code page to UTF-8 (suppresses output)
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $null = chcp 65001
    }

    # Helps some redirection scenarios
    $script:OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
    # Non-fatal: continue with best effort
}



Write-Debug "Core: $($PSVersionTable.PSVersion)"
Write-Debug "Terminal: $((Get-Command powershell.exe).FileVersionInfo.FileVersion)"


# Import PowerShell modules recursively
function Load([string]$directory = $pwd, [switch]$strict)
{
    if (-not (Test-Path -LiteralPath $directory)) {
        throw "Path '$directory' does not exist"
    }

    # For all module files under the working directory
    Get-ChildItem -Path $directory -Recurse -File -Filter "*.psm1" | ForEach-Object {

        $proper = [string]::Equals($_.BaseName, $_.Directory.Name, [System.StringComparison]::OrdinalIgnoreCase)
        if ($strict -and -not $proper) {

            Write-Debug "Skipping $($_.FullName)"
            return
        }

        Write-Debug "Loading $($_.FullName)"
        Import-Module $_.FullName -Force -DisableNameChecking
    }
}
# Import local libraries
Load $PSScriptRoot -Strict


# Make this script available in the Windows Explorer context menu
function Install
{
    # Modifying the Windows Registry requires admin privileges
    if (Test-IsElevated) { New-ContextScript $PSCommandPath 'Autopsy' -Icon "209"

    } else {
        Warn "Installation needs to be run as administrator"
        Run-Elevated $PSCommandPath
    }
}


# Assign an assistant
try { if ((Config "agent") -ne "off") { $assistant = New-Agent (Config "agent")}

} catch { Warn "No assistant available: $_" }


# Clear window and chat history
function Restart
{
    Clear-Host
    Open-Session $PSCommandPath
}


# Dump your clipboard to the model context
function Paste
{
    Write-Debug $assistant.Message("user", (Get-Clipboard))
}


# Display the available functions of a module
function Help([string] $library = $PSCommandPath)
{
    try { # opening the script file
        if ([IO.Path]::IsPathRooted($library)) {
            Show-Functions $library

        } else { # it could be a local module
            $location = Join-Path (Get-Location) $library

            if (Test-Path $location -PathType Container) {
                Show-Functions "$location\$library.psm1"
            }
        }
    } catch { Err $_ }
}


# Introduce a file to the chat assistants context
function Add {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Keyword
    )

    if (-not $global:assistant) {
        throw "Global variable `$assistant is not set."
    }

    $imageExtensions = @(".png", ".jpg", ".jpeg", ".webp", ".gif")

    $files = Get-ChildItem -Path (Get-Location) -File -Recurse |
        Where-Object {
            $_.Name -like "*$Keyword*"
        }

    if (-not $files) {
        Write-Warning "No files found matching '$Keyword'."
        return
    }

    foreach ($file in $files) {
        $path = $file.FullName
        $extension = $file.Extension.ToLowerInvariant()

        if ($imageExtensions -contains $extension) {
            $global:assistant.Image($path, "Image file: $path")
        }
        else {
            $global:assistant.File($path)
        }

        Write-Host "Added $path"
    }
}


# Select the current model
function Agent([string] $choice = "")
{
    if ($choice -eq "") {
        $current = Config "agent"
        $choice = Prompt-Selection $(List-Models) $current
    }

    Config "agent" $choice
    if ($choice -ne "off") {
        $assistant = New-Agent $choice
    }
    
    Open-Session $PSCommandPath
}



# Loop over user input
while ($prompt = Read-Input) {

    # Execute valid language commands
    try { (Invoke-Expression $prompt -ErrorAction Stop | Out-String).TrimEnd()
        continue

    # or inspect error if agent is disabled
    } catch { if ( -not $assistant ) {
            Write-Host $_
            continue
        }
    }

    # or ask the assistant
    Write-Host "$($assistant.Model): " -NoNewline -ForegroundColor Blue
    $reply = $assistant.say($prompt)

    # then display the reply
    Play "new_message"
    Write-Host $reply -ForegroundColor Cyan

    Write-Host # new line
}

