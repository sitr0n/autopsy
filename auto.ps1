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


# Load PowerShell modules recursively
function Load {
    [CmdletBinding()]
    param(
        [string]$directory = $pwd
    )

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
    if (Test-IsElevated) { New-ContextScript $PSCommandPath 'Autopsy' "209"

    } else {
        Write-Host "Installation needs to be run as administrator" -ForegroundColor Yellow
        Run-Elevated $PSCommandPath
    }
}


$assistant = New-Agent


# Add a file to the assistants chat context
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


# Switch assistant replies on/off
function Debug {
    $current = config debug
    if ($current -eq "") {
        $current = "off"
    }
    $choices = @("on", "off")
    $choice = Prompt-Selection $choices $current

    if ($choice -eq "off") {
        $choice = ""
    }
    config debug $choice
}


# Loop over user input
try { while ($prompt = Read-Input) {

        # Execute valid language commands
        try { (Invoke-Expression $prompt -ErrorAction Stop | Out-String).TrimEnd()
            continue

        # or inspect error if debug is enabled
        } catch { if (Config debug) {
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

} catch { Write-Host $_.Exception.Message
    Restart
}