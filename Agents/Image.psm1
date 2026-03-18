class Image {

    # Set the access credentials and a model choice
    Image ([string]$model, [string]$token) {
        $this.model = $model
        $this.headers = @{ Authorization = "Bearer $token" }
    }


    # Generate an image from a prompt and write it to disk
    [string]Generate ([string]$prompt, [string]$path) {

        $body = @{
            model  = $this.model
            prompt = $prompt
        } | ConvertTo-Json -Depth 12

        $response = Invoke-RestMethod `
            -Uri $this.endpoint `
            -Method Post `
            -Headers $this.headers `
            -ContentType 'application/json; charset=utf-8' `
            -Body $body

        $b64 = [string]$response.data[0].b64_json
        if (-not $b64) {
            throw "No image data returned from API"
        }

        $bytes = [Convert]::FromBase64String($b64)
        [IO.File]::WriteAllBytes($path, $bytes)
        return $path
    }


    [string]$model
    [hashtable]$headers
    [string]$endpoint = "https://api.openai.com/v1/images/generations"
}