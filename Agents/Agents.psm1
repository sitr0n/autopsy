# Load the OpenAI interaction class
using module .\GPT.psm1


# Agent factory function
function New-Agent {
    param (
      [string] $model = "gpt-5.2"
    )

    return [GPT]::new($model, ( Get-Credentials ))
}
Export-ModuleMember -Function New-Agent


# Save the OpenAI API token
function Set-Credentials {
    [CmdletBinding()]
    param (
      [Parameter(Mandatory = $true)]
      [string] $token
    )

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Token cannot be empty"
    }

    # Persist to JSON file
    $credentialsPath = Join-Path -Path $PSScriptRoot -ChildPath 'credentials.json'
    $payload = [PSCustomObject]@{
        token   = $token
        updated = (Get-Date).ToString('o')
    }

    try {
        $null = New-Item -ItemType File -Path $credentialsPath -Force -ErrorAction Stop
        $payload | ConvertTo-Json -Depth 3 | Set-Content -Path $credentialsPath -Encoding UTF8 -NoNewline
    } catch {
        throw "Failed to write credentials to '$credentialsPath': $($_.Exception.Message)"
    }
}
Export-ModuleMember -Function Set-Credentials


# Read the OpenAI API token
function Get-Credentials {
    [CmdletBinding()]
    param()

    $credentialsPath = Join-Path -Path $PSScriptRoot -ChildPath 'credentials.json'

    if (-not (Test-Path -LiteralPath $credentialsPath)) {
        throw "Credentials file not found at '$credentialsPath'. Run Set-Credentials first."
    }

    try {
        $data = Get-Content -LiteralPath $credentialsPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to read credentials from '$credentialsPath': $($_.Exception.Message)"
    }

    if (-not $data -or [string]::IsNullOrWhiteSpace($data.token)) {
        throw "Token not found in '$credentialsPath'"
    }

    return [string]$data.token
}
Export-ModuleMember -Function Get-Credentials