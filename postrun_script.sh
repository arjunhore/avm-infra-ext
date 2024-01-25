#!/bin/bash

# Check if .env file exists
if [ -f .env ]; then
    echo "Sourcing environment variables from .env file"
    source "$(pwd)/.env"
else
    echo "Error: .env file not found. Please create one with the necessary environment variables."
    exit 1
fi

echo "Enter the serverApiKey which is displayed in the terraform output:"
read serverApiKey

json_payload='{
    "openAiApiKey": "'"$openAiApiKey"'",
    "cohereApiKey": "'"$cohereApiKey"'",
    "azureApiKey": "'"$azureApiKey"'",
    "skipOrgCreate": false,
    "organization": {
        "name": "Terratest",
        "domain": "Terratest",
        "providerId": "saml.terratest",
        "website": "terratest.com"
    },
    "users": [
        {
            "email": "ratnam.sundaram@firebirds.ai"
        }
    ]
}'

# Execute the curl command
curl_output=$(curl -k --location "https://api.$workspace_name.$TF_VAR_root_domain_name:443/v1/admin/add-default-data" \
    --header "Api-Key: $serverApiKey" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload" 2>&1)

# Display the output
echo "Curl Output:"
echo "$curl_output"