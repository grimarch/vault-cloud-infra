#!/bin/bash

# Define logging functions if they are not defined in the parent script
if ! type log_info >/dev/null 2>&1; then
  # Define colors for better readability
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color

  # Helper functions
  log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
  log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
  log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
  log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
fi

# Secure SSH setup function - creates temporary known_hosts file for host key verification
setup_secure_ssh() {
  local known_hosts_file="./.ssh_known_hosts_temp"
  
  log_info "🔐 Setting up secure SSH connection with host key verification..."
  
  # Collect SSH host key from the remote server
  if ssh-keyscan -p "${TF_VAR_ssh_port}" "${FLOATING_IP}" > "$known_hosts_file" 2>/dev/null; then
    if [ -s "$known_hosts_file" ]; then
      log_success "✅ SSH host key collected and verified"
      echo "$known_hosts_file"
      return 0
    else
      log_error "❌ SSH host key file is empty"
      rm -f "$known_hosts_file"
      return 1
    fi
  else
    log_error "❌ Failed to collect SSH host key from ${FLOATING_IP}:${TF_VAR_ssh_port}"
    rm -f "$known_hosts_file"
    return 1
  fi
}

# Cleanup function to remove temporary known_hosts file
cleanup_secure_ssh() {
  local known_hosts_file="./.ssh_known_hosts_temp"
  if [ -f "$known_hosts_file" ]; then
    rm -f "$known_hosts_file"
    log_info "🧹 Cleaned up temporary SSH known_hosts file"
  fi
}

# Get variables through get_tf_var.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_VAR_ssh_port="$("${SCRIPT_DIR}/get_tf_var.sh" TF_VAR_ssh_port ssh_port required)"
TF_VAR_ssh_private_key_path="$("${SCRIPT_DIR}/get_tf_var.sh" TF_VAR_ssh_private_key_path ssh_private_key_path required)"
FLOATING_IP="$("${SCRIPT_DIR}/get_tf_var.sh" FLOATING_IP floating_ip_address required)"

get_bootstrap_token() {
  local init_file=".vault_docker_lab_1_init"
  local encrypted_token_file="./bootstrap-token.enc"
  local encryption_key_file="./.encryption-key"
  local decrypted_token_file="./.bootstrap-token-decrypted"

  # Setup secure SSH connection
  local known_hosts_file
  known_hosts_file=$(setup_secure_ssh)
  if [ $? -ne 0 ]; then
    log_error "❌ Failed to setup secure SSH connection"
    return 1
  fi

  # Check and download init file
  if [ ! -f "$init_file" ]; then
    log_info "🔄 Local $init_file not found, downloading from remote server..."
    scp -P "${TF_VAR_ssh_port}" -o UserKnownHostsFile="$known_hosts_file" -i "${TF_VAR_ssh_private_key_path}" vaultadmin@"${FLOATING_IP}":/opt/vault_lab/"$init_file" "$init_file"
    if [ $? -eq 0 ]; then
      log_success "✅ Downloaded $init_file from remote server"
    else
      log_warning "⚠️ Failed to download $init_file"
      cleanup_secure_ssh
      return 1
    fi
  else
    log_info "✅ Local $init_file found, using it"
  fi

  # Try to get encrypted token
  log_info "🔐 Retrieving encrypted bootstrap token..."
  
  # Check if we already have encrypted files locally (downloaded by Terraform)
  if [ -f "$encrypted_token_file" ] && [ -f "$encryption_key_file" ]; then
    log_info "📄 Found local encrypted files, decrypting..."
  else
    log_info "📄 Local encrypted files not found, downloading from remote server..."
    
    # Check if encrypted files exist on remote server
    local ssh_check
    ssh_check=$(ssh -o UserKnownHostsFile="$known_hosts_file" -i "${TF_VAR_ssh_private_key_path}" -p "${TF_VAR_ssh_port}" vaultadmin@"${FLOATING_IP}" "[ -f /opt/vault_lab/backups/bootstrap-token.enc ] && echo exists || echo missing")
    
    if [[ "$ssh_check" == "missing" ]]; then
      log_error "❌ Encrypted bootstrap token file does not exist on the remote server"
      log_info "💡 Checking directory structure..."
      ssh -o UserKnownHostsFile="$known_hosts_file" -i "${TF_VAR_ssh_private_key_path}" -p "${TF_VAR_ssh_port}" vaultadmin@"${FLOATING_IP}" "ls -la /opt/vault_lab/backups/ || echo 'Directory does not exist'"
      cleanup_secure_ssh
      return 1
    fi

    # Download encrypted token file
    scp -P "${TF_VAR_ssh_port}" -o UserKnownHostsFile="$known_hosts_file" -i "${TF_VAR_ssh_private_key_path}" vaultadmin@"${FLOATING_IP}":/opt/vault_lab/backups/bootstrap-token.enc "$encrypted_token_file"
    
    # Download encryption key
    scp -P "${TF_VAR_ssh_port}" -o UserKnownHostsFile="$known_hosts_file" -i "${TF_VAR_ssh_private_key_path}" vaultadmin@"${FLOATING_IP}":/opt/vault_lab/backups/.encryption-key "$encryption_key_file"
    chmod 400 "$encryption_key_file"
  fi

  # Decrypt the token file
  if [ -f "$encrypted_token_file" ] && [ -f "$encryption_key_file" ]; then
    log_info "🔓 Decrypting bootstrap token..."
    local encryption_key
    encryption_key=$(cat "$encryption_key_file")
    
    # Decrypt using openssl
    if openssl enc -aes-256-cbc -d -salt -pbkdf2 -k "$encryption_key" -in "$encrypted_token_file" -out "$decrypted_token_file" 2>/dev/null; then
      local local_token
      local_token=$(grep 'Bootstrap Token:' "$decrypted_token_file" | awk '{print $3}')
      
      if [[ -n "$local_token" ]]; then
        log_success "✅ Successfully decrypted and retrieved bootstrap token"
        # shellcheck disable=SC2034  # VAULT_TOKEN used by external calling scripts
        VAULT_TOKEN="$local_token"
        
        # Clean up decrypted file for security
        rm -f "$decrypted_token_file"
        log_info "🧹 Cleaned up temporary decrypted file"
        
        # Clean up secure SSH setup
        cleanup_secure_ssh
        
        return 0
      else
        log_error "❌ Could not extract token from decrypted file"
        rm -f "$decrypted_token_file"
        cleanup_secure_ssh
        return 1
      fi
    else
      log_error "❌ Failed to decrypt bootstrap token file"
      cleanup_secure_ssh
      return 1
    fi
  else
    log_error "❌ Missing encrypted token file or encryption key"
    cleanup_secure_ssh
    return 1
  fi
}
