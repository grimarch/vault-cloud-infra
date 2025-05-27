#!/bin/bash

get_bootstrap_token() {
  local init_file=".vault_docker_lab_1_init"
  local token_file="./.bootstrap-token"

  # Проверка и загрузка init файла
  if [ ! -f "$init_file" ]; then
    log_info "🔄 Local $init_file not found, downloading from remote server..."
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${TF_VAR_ssh_private_key_path}" root@"${FLOATING_IP}":/opt/vault_lab/"$init_file" "$init_file"
    if [ $? -eq 0 ]; then
      log_success "✅ Downloaded $init_file from remote server"
    else
      log_warning "⚠️ Failed to download $init_file"
    fi
  else
    log_info "✅ Local $init_file found, using it"
  fi

  # Попытка получить токен
  log_info "🔐 Retrieving bootstrap token..."

  if [ -f "$token_file" ]; then
    log_info "📄 Found local bootstrap token file, checking content..."
    local local_token
    local_token=$(grep 'Bootstrap Token:' "$token_file" | awk '{print $3}')
    if [[ -n "$local_token" ]]; then
      log_success "✅ Successfully retrieved bootstrap token from local file ./.bootstrap-token"
      VAULT_TOKEN="$local_token"
      return 0
    else
      log_warning "⚠️ Could not extract token from local file, trying remote server..."
    fi
  else
    log_info "📄 Local bootstrap token file not found, trying remote server..."
  fi

  # Получение токена с удалённого сервера
  local ssh_check
  ssh_check=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${TF_VAR_ssh_private_key_path}" root@"${FLOATING_IP}" "[ -f /opt/vault_lab/backups/bootstrap-token ] && echo exists || echo missing")
  if [[ "$ssh_check" == "missing" ]]; then
    log_error "❌ File /opt/vault_lab/backups/bootstrap-token does not exist on the remote server"
    log_info "💡 Checking directory structure..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${TF_VAR_ssh_private_key_path}" root@"${FLOATING_IP}" "ls -la /opt/vault_lab/backups/ || echo 'Directory does not exist'"
    return 1
  fi

  local remote_content
  remote_content=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${TF_VAR_ssh_private_key_path}" root@"${FLOATING_IP}" "cat /opt/vault_lab/backups/bootstrap-token")
  log_info "📄 Remote bootstrap token file content: ${remote_content}"

  local remote_token
  remote_token=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${TF_VAR_ssh_private_key_path}" root@"${FLOATING_IP}" "grep 'Bootstrap Token:' /opt/vault_lab/backups/bootstrap-token | awk '{print \$3}'")

  if [[ -n "$remote_token" ]]; then
    log_success "✅ Successfully retrieved bootstrap token from remote server: ${remote_token}"
    echo "$remote_content" > "$token_file"
    log_info "💾 Saved bootstrap token to local file $token_file"
    VAULT_TOKEN="$remote_token"
    return 0
  else
    log_error "❌ Unable to extract VAULT_TOKEN from the bootstrap-token file. Check file format."
    return 1
  fi
}
