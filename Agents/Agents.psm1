using module .\Claude.psm1
using module .\GPT.psm1
using module .\Image.psm1


# Get a list of all the models that has an implementation
function List-Models
{
    return @(
        "off",
        "claude-opus-4-8",
        "claude-fable-5",
        "gpt-5.5",
        "gpt-5.6-sol"
    )
}
Export-ModuleMember -Function List-Models


function Add-ToolsFromModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Agent,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $module = @(Import-Module $resolvedPath -Force -PassThru)[-1]

    $commonParameters = @(
        'Verbose', 'Debug', 'ErrorAction', 'WarningAction',
        'InformationAction', 'ProgressAction', 'ErrorVariable',
        'WarningVariable', 'InformationVariable', 'OutVariable',
        'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm'
    )

    foreach ($command in $module.ExportedFunctions.Values) {
        $properties = @{}
        $required = [System.Collections.Generic.List[string]]::new()

        foreach ($parameter in $command.Parameters.Values) {
            if ($parameter.Name -in $commonParameters) {
                continue
            }

            $type = $parameter.ParameterType
            $property = @{}

            if ($type -eq [bool] -or $type -eq [switch]) {
                $property.type = 'boolean'
            }
            elseif ($type.IsArray) {
                $property.type = 'array'
                $property.items = @{ type = 'string' }
            }
            elseif ($type -in @([byte], [int16], [int32], [int64])) {
                $property.type = 'integer'
            }
            elseif ($type -in @([single], [double], [decimal])) {
                $property.type = 'number'
            }
            elseif ([System.Collections.IDictionary].IsAssignableFrom($type)) {
                $property.type = 'object'
            }
            else {
                $property.type = 'string'
            }

            $parameterAttribute = $parameter.Attributes |
                Where-Object { $_ -is [Management.Automation.ParameterAttribute] } |
                Select-Object -First 1

            if ($parameterAttribute.HelpMessage) {
                $property.description = $parameterAttribute.HelpMessage
            }

            $validateSet = $parameter.Attributes |
                Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } |
                Select-Object -First 1

            if ($validateSet) {
                $property.enum = @($validateSet.ValidValues)
            }

            if ($parameter.Attributes | Where-Object {
                $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory
            }) {
                $required.Add($parameter.Name)
            }

            $properties[$parameter.Name] = $property
        }

        $schema = @{
            type       = 'object'
            properties = $properties
            required   = @($required)
        }

        $help = Get-Help "$($module.Name)\$($command.Name)" -ErrorAction SilentlyContinue
        $description = [string]$help.Synopsis

        if ([string]::IsNullOrWhiteSpace($description)) {
            $description = "Executes the $($command.Name) PowerShell function."
        }

        # Capture a separate CommandInfo for each closure.
        $toolCommand = $command
        $handler = {
            param($toolArgs)

            $invokeArgs = @{}

            if ($toolArgs -is [System.Collections.IDictionary]) {
                foreach ($key in $toolArgs.Keys) {
                    $invokeArgs[$key] = $toolArgs[$key]
                }
            }
            elseif ($null -ne $toolArgs) {
                foreach ($property in $toolArgs.PSObject.Properties) {
                    $invokeArgs[$property.Name] = $property.Value
                }
            }

            & $toolCommand @invokeArgs
        }.GetNewClosure()

        # Claude and OpenAI tool names are safer with underscores.
        $toolName = $command.Name -replace '-', '_'

        $Agent.Tool($toolName, $description, $schema, $handler)
    }

    return $Agent
}
Export-ModuleMember -Function Add-ToolsFromModule


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
    Write-Host "1"
    $gpt = [GPT]::new("gpt-5.5", ( Get-Credentials "gpt" ))
    Write-Host "2"
    Add-ToolsFromModule -Agent $gpt -Path ".\Tools.psm1" | Out-Null
    Write-Host "3"

    $gpt.Say('What is the size of C:\code\autopsy\Agents\GPT.psm1?')
}
Export-ModuleMember -Function Test


# Generate an image from a description
function New-Image {
    param (
      [string] $prompt
    )

    $generator = [Image]::new("gpt-image-2", ( Get-Credentials "gpt" ))
    $file_name = $prompt -replace '\s', '_'
    $generator.Generate($prompt, "$file_name.png")
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