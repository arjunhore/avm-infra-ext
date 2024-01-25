#!/bin/bash

# Function to check and exit on error
check_error() {
    local exit_code=$1
    local error_message=$2

    if [ $exit_code -ne 0 ]; then
        echo "Error: $error_message"
        exit $exit_code
    fi
}

# Check if .env file exists
if [ -f .env ]; then
    echo "Sourcing environment variables from .env file"
    source "$(pwd)/.env"
else
    echo "Error: .env file not found. Please create one with the necessary environment variables."
    exit 1
fi

# Terraform initialization
echo "Initializing Terraform..."
terraform init
check_error $? "Terraform initialization failed."

# Check if workspace exists
existing_workspace=$(terraform workspace list | grep -w "$workspace_name")

if [ -n "$existing_workspace" ]; then
    echo "Workspace '$workspace_name' already exists. Selecting..."
    terraform workspace select "$workspace_name"
else
    # Create Terraform workspace
    echo "Creating Terraform workspace..."
    terraform workspace new "$workspace_name"
    check_error $? "Terraform workspace creation failed."

    # Select Terraform workspace
    echo "Selecting Terraform workspace..."
    terraform workspace select "$workspace_name"
    check_error $? "Terraform workspace selection failed."
fi

# Apply Terraform changes
echo "Applying Terraform changes..."
terraform apply
check_error $? "Terraform apply failed."