using module .\Claude.psm1
using module .\GPT.psm1
using module .\Image.psm1


# Get a list of all the models that has an implementation
function List-Models
{
    return @(
        "off",
        "claude-opus-4-8",
        "gpt-5.5"
    )
}
Export-ModuleMember -Function List-Models


# Chat agent factory
function New-Agent {
    param (
      [Parameter(Mandatory = $true)]
      [string] $model
    )

    if ($model -like 'claude-*') {
        return [Claude]::new($model, ( Get-Credentials "claude" ) )
    }

    if ($model -like 'gpt-*') {
        return [GPT]::new($model, ( Get-Credentials "gpt" ))
    }

    throw "Couldn't find an implementation for the model: $model"
}
Export-ModuleMember -Function New-Agent


function Test
{
    $gpt = [GPT]::new("gpt-5.5", ( Get-Credentials "gpt" ))
    $gpt.Tool(
        "get_file_info",
        "Gets basic information about a local file.",
        @{
            type = "object"
            properties = @{
                path = @{
                    type = "string"
                    description = "The local filesystem path."
                }
            }
            required = @("path")
        },
        {
            param($toolArgs)

            Write-Host "called with $($toolArgs.path)"
            $item = Get-Item -LiteralPath $toolArgs.path

            return @{
                path = $item.FullName
                length = $item.Length
                lastWriteTime = $item.LastWriteTimeUtc
            }
        }
    )

    try {
        $gpt.Say("What is the size of C:\code\autopsy\Agents\GPT.psm1?")
    } catch {
        Write-Host "Crashed:("
        Write-Host $_
    }
}
Export-ModuleMember -Function Test


# Generate an image from a description
function New-Image {
    param (
      [string] $prompt
    )

    $generator = [Image]::new("gpt-image-1", ( Get-Credentials "gpt" ))
    $generator.Generate($prompt, ".\output.png")
}
Export-ModuleMember -Function New-Image


# Save a named API token
function Set-Credentials {
    [CmdletBinding()]
    param (
      [Parameter(Mandatory = $true)]
      [ValidateSet('claude', 'gpt')]
      [string] $Name,

      [Parameter(Mandatory = $true)]
      [string] $Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw "Token cannot be empty"
    }

    $credentialsPath = Join-Path -Path $PSScriptRoot -ChildPath 'credentials.json'

    $data = @{}
    if (Test-Path -LiteralPath $credentialsPath) {
        try {
            $existing = Get-Content -LiteralPath $credentialsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($existing) {
                foreach ($property in $existing.PSObject.Properties) {
                    $data[$property.Name] = $property.Value
                }
            }
        } catch {
            throw "Failed to read existing credentials from '$credentialsPath': $($_.Exception.Message)"
        }
    }

    $data[$Name] = [PSCustomObject]@{
        token   = $Token
        updated = (Get-Date).ToString('o')
    }

    try {
        $data | ConvertTo-Json -Depth 5 | Set-Content -Path $credentialsPath -Encoding UTF8 -NoNewline
    } catch {
        throw "Failed to write credentials to '$credentialsPath': $($_.Exception.Message)"
    }
}
Export-ModuleMember -Function Set-Credentials


# Read a named API token
function Get-Credentials {
    [CmdletBinding()]
    param(
      [Parameter(Mandatory = $true)]
      [ValidateSet('claude', 'gpt')]
      [string] $Name
    )

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

    if (-not $data -or -not $data.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace($data.$Name.token)) {
        throw "Token '$Name' not found in '$credentialsPath'"
    }

    return [string]$data.$Name.token
}
Export-ModuleMember -Function Get-Credentials