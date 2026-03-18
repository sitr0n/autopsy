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

Write-Host "Core: $($PSVersionTable.PSVersion)"
Write-Host "Terminal: $((Get-Command powershell.exe).FileVersionInfo.FileVersion)"


# Import PowerShell modules recursively
function Load {
    param( [string]$directory = $pwd )

    if (-not (Test-Path -LiteralPath $directory)) {
        throw "Path '$directory' does not exist"
    }

    # Loop over all files
    Get-ChildItem -Path $directory -Recurse -File | ForEach-Object {

        # Import module files
        if ($_.Extension -eq ".psm1") {
            Import-Module $_.FullName -Force -DisableNameChecking
        }
    }
}
# Import local libraries
Load $PSScriptRoot


# Make this script available in the Windows Explorer context menu
function Install {

    # Modifying the Windows Registry requires admin privileges
    if (Test-IsElevated) { New-ContextScript $PSCommandPath 'Autopsy' -Icon "209"

    } else {
        Warn "Installation needs to be run as administrator"
        Run-Elevated $PSCommandPath
    }
}


# Assign an assistant
try { if ((Config "agent") -ne "off") { $assistant = New-Agent }

} catch { Warn "No assistant available: $_" }


# Clear window and chat history
function Restart {

    Clear-Host
    Open-Session $PSCommandPath
}




function Paste {
    
    $assistant.Message("user", (Get-Clipboard)) | Out-Null
}


# Display the available functions of the module
function Help {
    param( [string] $library = $PSCommandPath )

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
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Text
    )

    $extension = ""
    if ($Text.Count -gt 0 -and $Text[0] -eq 'powershell') {
        $extension = ".ps1"
    }

    if ($Text[0] -eq 'cpp' -or $Text[0] -eq 'c++') {
        $extension = "*.cpp,*.hpp"
    }


    if ($extension -eq "") {
        $begin = 0
    } else {
        $begin = 1
    }

    for ($index = $begin; $index -lt $Text.Count; $index++) {
        foreach ($file in Get-MatchingFiles (Get-Location) $Text[$index] $extension) {

            Write-Host "$file" -ForegroundColor Yellow
            $assistant.File($file)
        }
    }
}


# Switch assistant on/off
function Agent {
    param(
        [string] $choice = ""
    )

    if ($choice -eq "") {
        $current = Config "agent"
        $choices = @("on", "off")
        $choice = Prompt-Selection $choices $current
    }

    Config "agent" $choice
    if ($choice -eq "on") {
        $assistant = New-Agent
    }
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

