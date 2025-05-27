#!/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Extract floating_ip from command line arguments
FLOATING_IP=""
for arg in "$@"; do
  case $arg in
    --floating_ip=*|--floating-ip=*)
      FLOATING_IP="${arg#*=}"
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Base directory on the remote server
REMOTE_BASE_DIR="/opt/vault_lab"

echo "INFO: Running init-bootstrap script. Base directory set to: $REMOTE_BASE_DIR"

echo "==== Script to setup secure management of Vault through Bootstrap token ===="
echo "WARNING: This script assumes that Vault is already initialized and unsealed!"
echo "Tokens for management will be saved in ${REMOTE_BASE_DIR}/backups - please protect this directory"
echo ""

# Check if bootstrap was already done
if [ -f "${REMOTE_BASE_DIR}/.vault_bootstrap_done" ]; then
  echo "Bootstrap already done. Exiting."
  exit 0
fi

# Check directory for backups
BACKUPS_DIR="${REMOTE_BASE_DIR}/backups"
if [ ! -d "$BACKUPS_DIR" ]; then
  mkdir -p "$BACKUPS_DIR"
  # Permissions will be set by the script later or should be managed by how files are written
fi

# Check Vault status
VAULT_STATUS=$(VAULT_TOKEN="$VAULT_TOKEN" vault status -format=json 2>/dev/null || echo '{"initialized":"error","sealed":"error"}')
INIT_STATUS=$(echo "$VAULT_STATUS" | jq -r .initialized 2>/dev/null || echo "error")
SEAL_STATUS=$(echo "$VAULT_STATUS" | jq -r .sealed 2>/dev/null || echo "error")

if [ "$INIT_STATUS" == "error" ]; then
  echo "Error connecting to Vault. Check VAULT_ADDR and server availability."
  exit 1
elif [ "$INIT_STATUS" != "true" ]; then
  echo "Vault not initialized. Terraform should have done this."
  exit 1
elif [ "$SEAL_STATUS" != "false" ]; then
  echo "Vault sealed. Terraform should have unsealed it."
  exit 1
fi

# Save VAULT_ADDR to a variable for further use
# VAULT_ADDR will be set by the caller (terraform remote-exec)
if [ -z "${VAULT_ADDR:-}" ]; then # set -u safe check
  export VAULT_ADDR="https://127.0.0.1:8200" # Default if not set by caller
  echo "VAULT_ADDR not set by caller, using default: $VAULT_ADDR"
fi
echo "VAULT_ADDR used: $VAULT_ADDR"

# Get Root Token
# VAULT_TOKEN should be set by the caller (terraform remote-exec)
# This check handles the case where it's not set and tries to get it from a file.
if [ -z "${VAULT_TOKEN:-}" ]; then # set -u safe check for VAULT_TOKEN
    echo "VAULT_TOKEN (containing Root Token) not set by caller. Trying to get from file..."
    INIT_FILE_PATH="${REMOTE_BASE_DIR}/.vault_docker_lab_1_init"
    if [ -f "$INIT_FILE_PATH" ]; then
      ROOT_TOKEN_FROM_FILE=$(grep 'Initial Root Token' "$INIT_FILE_PATH" | awk '{print $NF}')
      if [ -z "$ROOT_TOKEN_FROM_FILE" ]; then # Standard check is fine here, as it's after assignment
        echo "ERROR: Unable to extract Root Token from file $INIT_FILE_PATH."
        exit 1
      fi
      export VAULT_TOKEN="$ROOT_TOKEN_FROM_FILE" # Export for subsequent vault commands in this script
      echo "Found and set Root Token from file $INIT_FILE_PATH"
    else
      echo "ERROR: File $INIT_FILE_PATH with Root Token not found."
      exit 1
    fi
fi

# Check token
echo "Checking Root token (current VAULT_TOKEN)..."
# Make sure VAULT_TOKEN is not empty before calling vault token lookup
if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "ERROR: VAULT_TOKEN is empty or not set before checking token."
  exit 1
fi
TOKEN_CHECK=$(VAULT_TOKEN="$VAULT_TOKEN" vault token lookup -format=json 2>/dev/null || echo '{"data":{"policies":[]}}')
POLICIES=$(echo "$TOKEN_CHECK" | jq -r '.data.policies | join(",")' 2>/dev/null || echo "error")

if [[ "$POLICIES" != *"root"* ]]; then
  echo "ERROR: VAULT_TOKEN (Root Token) is invalid. Policies: $POLICIES"
  exit 1
fi

echo "Authentication with Root Token successful. Setting up secure management of Vault..."

# Create bootstrap policy for further automation
echo "Creating bootstrap policy..."
VAULT_TOKEN="$VAULT_TOKEN" vault policy write bootstrap-policy - << EOF
# Permissions for managing auth methods
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Permissions for setting up auth methods
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Permissions for reading list of auth methods
path "sys/auth" {
  capabilities = ["read", "list"]
}

# Permissions for managing policies
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Permissions for managing secret engines
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Permissions for managing secrets in KV storage
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Permissions for managing project-wide settings
path "secret/data/projects/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Permissions for revoking tokens
path "auth/token/revoke" {
  capabilities = ["update"]
}

# Permissions for audit
path "sys/audit*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Permissions for creating tokens
path "auth/token/create" {
  capabilities = ["create", "update"]
}
EOF

# Create admin policy
echo "Creating admin policy..."
VAULT_TOKEN="$VAULT_TOKEN" vault policy write admin-policy - << EOF
# Permissions for managing auth methods
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Permissions for managing policies
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Permissions for managing KV secrets
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Permissions for viewing system status
path "sys/health" {
  capabilities = ["read", "sudo"]
}

# Permissions for managing audit
path "sys/audit*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

# Enable audit logging (if not already enabled)
# Terraform resource null_resource.enable_audit_device should have already done this.
# This check is here for idempotency or if the script is run separately.
echo "Checking audit setup (for idempotency)..."
# Expect Terraform to have already setup audit, but check
# Use "vault audit list -format=json" and check if "file/" exists
AUDIT_FILE_ENABLED=$(VAULT_TOKEN="$VAULT_TOKEN" vault audit list -format=json 2>/dev/null | jq -e '."file/"' >/dev/null 2>&1; echo $?)
if [ "$AUDIT_FILE_ENABLED" != "0" ]; then
  echo "Audit 'file' not found. Trying to enable audit in /vault/logs/vault_audit.log..."
  VAULT_TOKEN="$VAULT_TOKEN" vault audit enable file file_path=/vault/logs/vault_audit.log || echo "Warning: Unable to enable audit. It may already be enabled in another way or insufficient permissions."
else
  echo "Audit 'file' already setup."
fi

# Enable KV v2 engine if not already enabled
echo "Checking KV engine (secret/)..."
if ! VAULT_TOKEN="$VAULT_TOKEN" vault secrets list -format=json | jq -e '."secret/"' > /dev/null; then
  echo "Enabling KV-v2 engine on path secret/..."
  VAULT_TOKEN="$VAULT_TOKEN" vault secrets enable -path=secret kv-v2
else
  echo "KV engine on path secret/ already enabled."
fi

# Enable userpass authentication method
echo "Checking userpass authentication method..."
if ! VAULT_TOKEN="$VAULT_TOKEN" vault auth list -format=json | jq -e '."userpass/"' > /dev/null; then
  echo "Enabling userpass authentication method..."
  VAULT_TOKEN="$VAULT_TOKEN" vault auth enable userpass
else
  echo "Userpass authentication method already enabled."
fi

# Generate random password for admin
ADMIN_PASSWORD=$(openssl rand -base64 16)
echo "Creating/updating admin user with admin-policy..."
VAULT_TOKEN="$VAULT_TOKEN" vault write auth/userpass/users/admin \
    password="$ADMIN_PASSWORD" \
    policies="admin-policy"

# Create bootstrap token with limited TTL (24 hours)
echo "Creating bootstrap token..."
BOOTSTRAP_TOKEN_JSON=$(VAULT_TOKEN="$VAULT_TOKEN" vault token create -policy=bootstrap-policy -display-name="bootstrap-token" -ttl=24h -format=json)
BOOTSTRAP_TOKEN=$(echo "$BOOTSTRAP_TOKEN_JSON" | jq -r .auth.client_token)

# Save tokens and passwords to protected files
echo "Saving credentials to $BACKUPS_DIR..."
echo "Bootstrap Token: $BOOTSTRAP_TOKEN" > "${BACKUPS_DIR}/bootstrap-token"
echo "Admin Username: admin" > "${BACKUPS_DIR}/admin-credentials"
echo "Admin Password: $ADMIN_PASSWORD" >> "${BACKUPS_DIR}/admin-credentials"
chmod 600 "${BACKUPS_DIR}/bootstrap-token" "${BACKUPS_DIR}/admin-credentials"

# Save VAULT_ADDR via floating_ip for future use
echo "VAULT_ADDR: https://${FLOATING_IP}:8200" > "${BACKUPS_DIR}/vault-addr"
chmod 600 "${BACKUPS_DIR}/vault-addr"

echo "Bootstrap completed. Creating flag file..."
touch "${REMOTE_BASE_DIR}/.vault_bootstrap_done"

echo ""
echo "==== Setup completed ===="
echo "Bootstrap Token saved in: ${BACKUPS_DIR}/bootstrap-token"
echo "Admin credentials saved in: ${BACKUPS_DIR}/admin-credentials"
echo "Vault address saved in: ${BACKUPS_DIR}/vault-addr"
echo ""
echo "IMPORTANT! For security reasons:"
echo "1. Bootstrap Token is valid for 24 hours. Use it to setup projects."
echo "2. After setup, use admin account instead of Root Token."
echo "3. It is recommended to revoke Root Token after all setup is complete."
