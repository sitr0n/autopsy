# Play an audio file from the resources directory
function Play {
    param(
        [Parameter(Mandatory)]
        [string]$file
    )

    $sp = New-Object System.Media.SoundPlayer "$PSScriptRoot\resources\$file.wav"
    $sp.Play()
}
Export-ModuleMember -Function Play
