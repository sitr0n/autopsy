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


# Assign an assistant
try {
    if ((Config "agent") -ne "off") {
        $assistant = New-Agent (Config "agent")

        Add-ToolsFromModule -Agent $assistant -Path "$PSScriptRoot\Agents\Tools.psm1" | Out-Null
        Add-ToolsFromModule -Agent $assistant -Path "$PSScriptRoot\Host\Host.psm1" | Out-Null
        Add-ToolsFromModule -Agent $assistant -Path "$PSScriptRoot\Docs\Docs.psm1" | Out-Null
    }
} catch { Write-Warning "No assistant available: $_" }


# Add tools from modules named after their parent directory to the assistant
function Tools([string]$directory = $pwd, [object]$agent = $assistant)
{
    if (-not $agent) {
        throw "No assistant available"
    }

    if (-not (Test-Path -LiteralPath $directory)) {
        throw "Path '$directory' does not exist"
    }

    # For all module files matching their parent directory name
    Get-ChildItem -Path $directory -Recurse -File -Filter "*.psm1" |
        Where-Object { [string]::Equals($_.BaseName, $_.Directory.Name, [System.StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            $module = $_.FullName
            try {
                Add-ToolsFromModule -Agent $agent -Path $module | Out-Null
                Write-Host "Added tools from $module"

            } catch { Write-Warning "Failed to add tools from ${module}: $_" }
        }
}
#Tools -Agent $assistant -Path "$PSScriptRoot\Host\Host.psm1" | Out-Null


# Clear window and chat history
function Restart
{
    Clear-Host
    Exit-Session $PSCommandPath
}


# Dump your clipboard to the model context
function Paste
{
    Write-Debug $assistant.Message("user", (Get-Clipboard))
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
        try {

            $choice = Ask-Selection $(List-Models) $current
        } catch {
            Write-Host $_
        }
    }

    Config "agent" $choice
    if ($choice -ne "off") {
        try {
            $assistant = New-Agent $choice

        } catch {
            Write-Host "What: $_"
        }
    }
    
    Exit-Session $PSCommandPath
}


# Loop over user input
while ($prompt = Ask-User (Split-Path -Leaf $pwd)) {

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

    Show-Markdown $assistant.say($prompt)
    Show-Markdown "___"
}

