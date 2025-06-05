// This file is based on learn-vault-docker-lab by HashiCorp Education.
// Modified by Denis Zwinger in 2025 for cloud deployment, dynamic node configuration, and logging.
// Licensed under the Mozilla Public License 2.0.

// -----------------------------------------------------------------------------
// Vault Cloud Infra
// -----------------------------------------------------------------------------
// This file defines the Vault cluster infrastructure for local Docker use,
// extended for cloud provisioning on DigitalOcean with automation features.
//
// Enhancements include:
// - Dynamic standby node count via variables
// - Structured logging of deployment process
// - cloud-init support for VM bootstrapping
// - bootstrap scripting for Vault initialization
// -----------------------------------------------------------------------------

#  _   __          ____    ___           __             __        __ 
# | | / /__ ___ __/ / /_  / _ \___  ____/ /_____ ____  / /  ___ _/ / 
# | |/ / _ `/ // / / __/ / // / _ \/ __/  '_/ -_) __/ / /__/ _ `/ _ \
# |___/\_,_/\_,_/_/\__/ /____/\___/\__/_/\_\\__/_/   /____/\_,_/_.__/
#                                                                    
# Vault Docker Lab is a minimal Vault cluster Terraformed on Docker
# It is useful for development and testing, but not for production.

// -----------------------------------------------------------------------------
// Local File Placeholders
// These resources ensure expected files exist on first run and prevent
// "file not found" errors. Provisioners will later overwrite them.
// -----------------------------------------------------------------------------

resource "local_file" "vault_init_placeholder" {
  filename = "${path.module}/.vault_docker_lab_1_init"
  content  = "" # Initial empty content, will be populated by active_node_init
}

# -----------------------------------------------------------------------
# SSH Host Key Management for Security
# -----------------------------------------------------------------------

# Collect SSH host key from the remote server for secure connections
resource "null_resource" "collect_ssh_hostkey" {
  depends_on = [digitalocean_droplet.vault_cloud_infra]

  triggers = {
    droplet_id = digitalocean_droplet.vault_cloud_infra.id
    ssh_port   = var.ssh_port
    droplet_ip = var.droplet_ip
  }

  # Create SSH known_hosts file with the server's host key
  provisioner "local-exec" {
    command = <<EOT
      echo "Collecting SSH host key for secure connections..."
      mkdir -p ./.ssh_temp
      ssh-keyscan -p ${var.ssh_port} ${var.droplet_ip} > ./.ssh_temp/known_hosts 2>/dev/null || {
        echo "Warning: Failed to collect SSH host key, retrying..."
        sleep 5
        ssh-keyscan -p ${var.ssh_port} ${var.droplet_ip} > ./.ssh_temp/known_hosts 2>/dev/null
      }
      if [ -s ./.ssh_temp/known_hosts ]; then
        echo "SSH host key collected successfully"
      else
        echo "Error: Failed to collect SSH host key"
        exit 1
      fi
    EOT
  }
}

# -----------------------------------------------------------------------
# Provider configuration
# -----------------------------------------------------------------------

# Docker provider removed - we'll use docker-compose on the remote host instead

# -----------------------------------------------------------------------
# Docker network
# -----------------------------------------------------------------------

# Docker provider removed - we'll use docker-compose on the remote host instead

# -----------------------------------------------------------------------
# Vault container configuration (used for unseal logic)
# -----------------------------------------------------------------------

locals {
  vault_addr_node1 = "${digitalocean_floating_ip.vault_fip.ip_address}:8200"

  # Step 1: Pre-calculate attributes for each node to avoid repetition
  _vault_node_precalcs = {
    for idx in range(var.num_vault_nodes) :
    "vault_docker_lab_${idx + 1}" => {
      node_key_val     = "vault_docker_lab_${idx + 1}"
      ipv4_address_val = "10.1.42.${101 + idx}"
      # Calculate the external port string once
      external_port_str_val = format("%d", 8200 + ((idx == 0) ? 0 : ((idx == 1) ? 20 : (((idx - 1) * 10) + 20))))
      cluster_addr_val      = "https://10.1.42.${101 + idx}:8201" # Uses the calculated IPv4 part
    }
  }

  # Step 2: Construct the final vault_containers map using the pre-calculated values
  vault_containers = {
    for node_key, calcs in local._vault_node_precalcs : node_key => {
      ipv4_address  = calcs.ipv4_address_val
      external_port = calcs.external_port_str_val # Use pre-calculated external port string
      env = [
        "VAULT_LICENSE=${var.vault_license}",
        "VAULT_CLUSTER_ADDR=${calcs.cluster_addr_val}",
        # Use pre-calculated external port string here for VAULT_REDIRECT_ADDR
        "VAULT_REDIRECT_ADDR=https://${digitalocean_floating_ip.vault_fip.ip_address}:${calcs.external_port_str_val}",
        "VAULT_CACERT=/vault/certs/vault_docker_lab_ca.pem"
      ],
      internal_port    = "8200", # Internal port for Vault server remains 8200
      host_path_certs  = "/opt/vault_lab/containers/${calcs.node_key_val}/certs",
      host_path_config = "/opt/vault_lab/containers/${calcs.node_key_val}/config",
      host_path_logs   = "/opt/vault_lab/containers/${calcs.node_key_val}/logs"
    }
  }

  # Helper local for standby nodes (all nodes except the first one)
  # This remains the same, but now depends on the final `vault_containers`
  standby_vault_nodes = {
    for k, v in local.vault_containers : k => v
    if k != "vault_docker_lab_1" # Exclude the first node
  }
}

# -----------------------------------------------------------------------
# Deploy Docker containers via docker-compose
# -----------------------------------------------------------------------

resource "null_resource" "deploy_docker_compose" {
  depends_on = [digitalocean_droplet.vault_cloud_infra]

  triggers = {
    generate_script_hash = filemd5("${path.module}/scripts/generate-docker-compose.sh")
    num_nodes            = var.num_vault_nodes
    droplet_id           = digitalocean_droplet.vault_cloud_infra.id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "vaultadmin"
    private_key = file(var.ssh_private_key_path)
    port        = var.ssh_port
    timeout     = "5m"
  }

  # Copy the docker-compose generation script to the server
  provisioner "file" {
    source      = "${path.module}/scripts/generate-docker-compose.sh"
    destination = "/tmp/generate-docker-compose.sh"
  }

  # Generate docker-compose.yml and start containers
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/generate-docker-compose.sh",
      "/tmp/generate-docker-compose.sh ${var.num_vault_nodes} ${digitalocean_floating_ip.vault_fip.ip_address} /opt/vault_lab/docker-compose.yml",
      "cd /opt/vault_lab",
      "docker-compose pull",
      "docker-compose up -d --remove-orphans",
      "echo 'Waiting for containers to start...'",
      "sleep 10",
      "docker-compose ps"
    ]
  }
}

# -----------------------------------------------------------------------
# Vault initialization and unsealing logic
# -----------------------------------------------------------------------

# Initialize the first Vault node
resource "null_resource" "active_node_init" {
  depends_on = [
    null_resource.deploy_docker_compose,
    local_file.vault_init_placeholder
  ]

  triggers = {
    docker_compose_deployed = null_resource.deploy_docker_compose.id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "vaultadmin"
    private_key = file(var.ssh_private_key_path)
    port        = var.ssh_port
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      # Ждём, пока Vault запустится, используя установленный CA сертификат вместо --insecure
      "until curl --cacert /usr/local/share/ca-certificates/vault_docker_lab_ca.crt --fail --silent https://127.0.0.1:8200/v1/sys/seal-status --output /dev/null; do printf '.'; sleep 4; done",
      # Выполняем инициализацию Vault
      "vault operator init -key-shares=1 -key-threshold=1 > /opt/vault_lab/.vault_docker_lab_1_init"
    ]
  }
}


# Unseal the first Vault node
resource "null_resource" "active_node_unseal" {
  depends_on = [
    null_resource.active_node_init,
    null_resource.deploy_docker_compose
  ]

  triggers = {
    docker_compose_deployed = null_resource.deploy_docker_compose.id
    init_resource_id        = null_resource.active_node_init.id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "vaultadmin"
    private_key = file(var.ssh_private_key_path)
    port        = var.ssh_port
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      # Ждём появления файла с ключами и выполняем unseal
      "while [ ! -f /opt/vault_lab/.vault_docker_lab_1_init ]; do printf '.'; sleep 1; done",
      "UNSEAL_KEY=$(grep 'Unseal Key 1' /opt/vault_lab/.vault_docker_lab_1_init | awk '{print $NF}')",
      "export VAULT_ADDR=https://127.0.0.1:8200",
      "vault operator unseal $UNSEAL_KEY"
    ]
  }
}

# Unseal each standby Vault node (nodes 2 to N)
resource "null_resource" "unseal_standby_node" {
  # Create one instance of this resource for each standby node
  # Runs only if var.num_vault_nodes > 1
  for_each = var.num_vault_nodes > 1 ? local.standby_vault_nodes : {}

  depends_on = [
    null_resource.active_node_unseal,
    null_resource.deploy_docker_compose # Depends on docker-compose deployment
  ]

  triggers = {
    # Re-run if the active node unseal process changes or docker-compose changes
    active_node_unsealed_id = null_resource.active_node_unseal.id
    docker_compose_deployed = null_resource.deploy_docker_compose.id
    # Re-run this resource if the content of the script file changes
    script_hash = filemd5("${path.module}/scripts/unseal-standby-node.sh")
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "vaultadmin"
    private_key = file(var.ssh_private_key_path)
    port        = var.ssh_port
    timeout     = "5m"
  }

  # 1. Copy the unseal script to the Droplet
  # This provisioner runs before remote-exec
  provisioner "file" {
    source      = "${path.module}/scripts/unseal-standby-node.sh"
    destination = "/tmp/unseal-standby-node.sh" # Destination path on the Droplet
  }

  # 2. Make the script executable and run it
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/unseal-standby-node.sh",
      "echo '[Vault unseal] Executing /tmp/unseal-standby-node.sh for node ${each.key} with port ${each.value.external_port} on Droplet...'",
      # Pass the external port of the current node as an argument to the script
      # The script will use this port to target the correct Vault instance via 127.0.0.1:PORT on the Droplet
      "/tmp/unseal-standby-node.sh ${each.value.external_port}"
    ]
  }
}

# This resource acts as a gate: it completes only when all configured nodes are unsealed.
resource "null_resource" "all_nodes_unsealed_gate" {
  depends_on = [
    null_resource.active_node_unseal,
    null_resource.unseal_standby_node, # Depend on the entire map of standby unseal operations
    # Terraform will wait for all instances if they are created.
    # If num_vault_nodes = 1, unseal_standby_node creates no instances,
    # and this dependency is correctly handled.
  ]

  triggers = {
    active_unseal_id = null_resource.active_node_unseal.id
    # The trigger needs to correctly reference the IDs of the standby nodes if they exist.
    # We iterate over the map of 'unseal_standby_node' resources (if it exists) to get their IDs.
    standby_unseal_ids_json = var.num_vault_nodes > 1 ? jsonencode({ for k, v in null_resource.unseal_standby_node : k => v.id }) : ""
  }

  provisioner "local-exec" {
    when    = create
    command = "echo '--- all_nodes_unsealed_gate: All ${var.num_vault_nodes} configured Vault node(s) are presumed to be unsealed. ---'"
  }
}

resource "null_resource" "enable_audit_device" {
  depends_on = [
    null_resource.all_nodes_unsealed_gate # Depend on the gate resource
  ]

  triggers = {
    all_nodes_unsealed_trigger = null_resource.all_nodes_unsealed_gate.id # Trigger on the gate's ID
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "vaultadmin"
    private_key = file(var.ssh_private_key_path)
    port        = var.ssh_port
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Enabling audit device via remote-exec...'",
      "while [ ! -f /opt/vault_lab/.vault_docker_lab_1_init ]; do echo 'Waiting for init file on droplet...'; sleep 2; done",
      "ROOT_TOKEN=$(grep 'Initial Root Token' /opt/vault_lab/.vault_docker_lab_1_init | awk '{print $NF}')",
      "if [ -z \"$ROOT_TOKEN\" ]; then echo 'Error: Could not extract ROOT_TOKEN from /opt/vault_lab/.vault_docker_lab_1_init'; exit 1; fi",
      "VAULT_ADDR='https://127.0.0.1:8200' VAULT_TOKEN=$ROOT_TOKEN vault audit enable file file_path=/vault/logs/vault_audit.log || echo 'Warning: Failed to enable audit device, but continuing...'",
      "echo 'Audit device enablement attempted via remote-exec.'"
    ]
  }
}

# --- Vault Bootstrap --- 
resource "null_resource" "vault_bootstrap" {
  depends_on = [
    null_resource.enable_audit_device # Ensure audit is enabled and all nodes are unsealed
  ]

  triggers = {
    # Re-run bootstrap if the script changes or if the audit device resource changes
    script_hash          = filemd5("${path.module}/scripts/init-bootstrap.sh")
    audit_device_trigger = null_resource.enable_audit_device.id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "vaultadmin"
    private_key = file(var.ssh_private_key_path)
    port        = var.ssh_port
    timeout     = "5m" # Increased timeout for bootstrap script
  }

  # 1. Copy the bootstrap script to the Droplet
  provisioner "file" {
    source      = "${path.module}/scripts/init-bootstrap.sh"
    destination = "/tmp/init-bootstrap.sh"
  }

  # 2. Make the script executable and run it
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/init-bootstrap.sh",
      # Pass VAULT_ADDR and ROOT_TOKEN as environment variables to the script
      # The script itself will use /opt/vault_lab/.vault_docker_lab_1_init as a fallback for ROOT_TOKEN if VAULT_TOKEN is not set
      "echo 'Running Vault bootstrap script from /tmp/init-bootstrap.sh...'",
      "export VAULT_ADDR='https://127.0.0.1:8200'", # Ensure script uses the main node
      "export ROOT_TOKEN=$(grep 'Initial Root Token' /opt/vault_lab/.vault_docker_lab_1_init | awk '{print $NF}')",
      "if [ -z \"$ROOT_TOKEN\" ]; then echo 'Error: ROOT_TOKEN could not be extracted on droplet for bootstrap.'; exit 1; fi",
      "export VAULT_TOKEN=$ROOT_TOKEN", # Set VAULT_TOKEN for the script
      # Pass floating_ip as an argument to the bootstrap script
      "/tmp/init-bootstrap.sh --floating_ip=${digitalocean_floating_ip.vault_fip.ip_address}"
    ]
  }
}

# Marker resource to indicate all nodes are configured.
resource "null_resource" "all_nodes_configured_marker" {
  # Depends on all standby nodes successfully joining if there are any
  depends_on = [
    null_resource.vault_bootstrap # Changed from enable_audit_device to vault_bootstrap
  ]

  triggers = {
    # Используем фиксированное значение для предотвращения конфликтов
    nodes_configured = timestamp()
  }

  provisioner "local-exec" {
    when    = create
    command = <<EOT
      echo "--- all_nodes_configured_marker: All Vault nodes are presumed to be configured and joined/unsealed. ---"
      echo "Cluster setup complete according to Terraform resource dependencies."
      # Final check: List peers from the leader node
      # Ensure VAULT_ADDR is set to the leader for this command.
      # This requires `vault` CLI to be configured with appropriate auth if needed (e.g. token or TLS certs)
      # For now, just an echo indicating completion.
      # VAULT_ADDR="https://${var.droplet_ip}:8200" vault operator raft list-peers || echo "Could not list raft peers, but Terraform steps completed."
    EOT
  }
}

# Resource for downloading necessary files from remote server
resource "null_resource" "download_vault_files" {
  depends_on = [
    null_resource.all_nodes_configured_marker,
    null_resource.collect_ssh_hostkey
  ]

  triggers = {
    # Re-run when the configuration is complete
    nodes_configured      = null_resource.all_nodes_configured_marker.id
    ssh_hostkey_collected = null_resource.collect_ssh_hostkey.id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "vaultadmin"
    private_key = file(var.ssh_private_key_path)
    port        = var.ssh_port
    timeout     = "2m"
  }

  # First, check if files exist on remote server
  provisioner "remote-exec" {
    inline = [
      "if [ ! -f /opt/vault_lab/.vault_docker_lab_1_init ]; then echo 'Init file not found on remote server!'; exit 1; fi",
      "if [ ! -f /opt/vault_lab/backups/bootstrap-token.enc ]; then echo 'Encrypted bootstrap token file not found on remote server!'; exit 1; fi",
      "if [ ! -f /opt/vault_lab/backups/.encryption-key ]; then echo 'Encryption key file not found on remote server!'; exit 1; fi",
      "echo 'Required encrypted files exist on remote server.'"
    ]
  }

  # Create local backup directory
  provisioner "local-exec" {
    command = "mkdir -p ./backups"
  }

  # Download vault init file
  provisioner "local-exec" {
    command = <<EOT
      echo "Downloading Vault init file from remote server..."
      scp -P ${var.ssh_port} -o UserKnownHostsFile=./.ssh_temp/known_hosts -i ${var.ssh_private_key_path} vaultadmin@${var.droplet_ip}:/opt/vault_lab/.vault_docker_lab_1_init ./.vault_docker_lab_1_init
      if [ $? -eq 0 ]; then
        echo "Vault init file downloaded to .vault_docker_lab_1_init"
      else
        echo "Failed to download vault init file"
      fi
    EOT
  }

  # Download encrypted bootstrap token file
  provisioner "local-exec" {
    command = <<EOT
      echo "Downloading encrypted bootstrap token file..."
      scp -P ${var.ssh_port} -o UserKnownHostsFile=./.ssh_temp/known_hosts -i ${var.ssh_private_key_path} vaultadmin@${var.droplet_ip}:/opt/vault_lab/backups/bootstrap-token.enc ./bootstrap-token.enc
      if [ $? -eq 0 ]; then
        echo "Encrypted bootstrap token file downloaded to ./bootstrap-token.enc"
      else
        echo "Failed to download encrypted bootstrap token file"
      fi
    EOT
  }

  # Download encrypted admin credentials file
  provisioner "local-exec" {
    command = <<EOT
      echo "Downloading encrypted admin credentials file..."
      scp -P ${var.ssh_port} -o UserKnownHostsFile=./.ssh_temp/known_hosts -i ${var.ssh_private_key_path} vaultadmin@${var.droplet_ip}:/opt/vault_lab/backups/admin-credentials.enc ./admin-credentials.enc
      if [ $? -eq 0 ]; then
        echo "Encrypted admin credentials file downloaded to ./admin-credentials.enc"
      else
        echo "Failed to download encrypted admin credentials file"
      fi
    EOT
  }

  # Download encryption key (WARNING: This is sensitive!)
  provisioner "local-exec" {
    command = <<EOT
      echo "⚠️  WARNING: Downloading encryption key - handle with extreme care!"
      scp -P ${var.ssh_port} -o UserKnownHostsFile=./.ssh_temp/known_hosts -i ${var.ssh_private_key_path} vaultadmin@${var.droplet_ip}:/opt/vault_lab/backups/.encryption-key ./.encryption-key
      if [ $? -eq 0 ]; then
        chmod 400 ./.encryption-key
        echo "Encryption key downloaded to ./.encryption-key (permissions: 400)"
        echo "🚨 SECURITY REMINDER: Delete this file after extracting needed credentials!"
      else
        echo "Failed to download encryption key"
      fi
    EOT
  }

  # Download decryption helper script
  provisioner "local-exec" {
    command = <<EOT
      echo "Downloading decryption helper script..."
      scp -P ${var.ssh_port} -o UserKnownHostsFile=./.ssh_temp/known_hosts -i ${var.ssh_private_key_path} vaultadmin@${var.droplet_ip}:/opt/vault_lab/backups/decrypt-credentials.sh ./decrypt-credentials.sh
      if [ $? -eq 0 ]; then
        chmod 700 ./decrypt-credentials.sh
        echo "Decryption helper script downloaded to ./decrypt-credentials.sh"
        echo "Usage: ./decrypt-credentials.sh <encrypted-file>"
      else
        echo "Failed to download decryption helper script"
      fi
    EOT
  }

  # SECURITY: Delete encryption key from server after successful download
  provisioner "remote-exec" {
    inline = [
      "echo '[SECURITY] Deleting .encryption-key from server for safety...'",
      "if [ -f /opt/vault_lab/backups/.encryption-key ]; then",
      "  sudo shred -u /opt/vault_lab/backups/.encryption-key",
      "  echo '[SECURITY] .encryption-key securely deleted from server.'",
      "else",
      "  echo '[SECURITY] .encryption-key already deleted or not found on server.'",
      "fi"
    ]
  }
}

# # --- Outputs ---
# # (Your existing outputs)
