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
# Provider configuration
# -----------------------------------------------------------------------

provider "docker" {
  // host = var.docker_host # Removed to allow DOCKER_HOST environment variable to take precedence
}
# -----------------------------------------------------------------------
# Docker network
# -----------------------------------------------------------------------

resource "docker_network" "vault_docker_lab_network" {
  name            = "vault_docker_lab_network"
  attachable      = true
  check_duplicate = true
  ipam_config {
    subnet = "10.1.42.0/24"
  }
}

# -----------------------------------------------------------------------
# Vault image
# -----------------------------------------------------------------------

resource "docker_image" "vault" {
  name         = "hashicorp/${var.vault_edition}:${var.vault_version}"
  keep_locally = true // Keep true for local dev, for droplet this might not be necessary or could be false
}

# -----------------------------------------------------------------------
# Vault container resources
# -----------------------------------------------------------------------

locals {
  vault_addr_node1 = "${digitalocean_floating_ip.vault_fip.ip_address}:8200"

  # Step 1: Pre-calculate attributes for each node to avoid repetition
  _vault_node_precalcs = {
    for idx in range(var.num_vault_nodes) :
    "vault_docker_lab_${idx + 1}" => {
      node_key_val              = "vault_docker_lab_${idx + 1}"
      ipv4_address_val          = "10.1.42.${101 + idx}"
      # Calculate the external port string once
      external_port_str_val     = format("%d", 8200 + ((idx == 0) ? 0 : ((idx == 1) ? 20 : (((idx - 1) * 10) + 20))))
      cluster_addr_val          = "https://10.1.42.${101 + idx}:8201" # Uses the calculated IPv4 part
    }
  }

  # Step 2: Construct the final vault_containers map using the pre-calculated values
  vault_containers = {
    for node_key, calcs in local._vault_node_precalcs : node_key => {
      ipv4_address = calcs.ipv4_address_val
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

resource "docker_container" "vault-docker-lab" {
  for_each = local.vault_containers
  name     = each.key
  hostname = each.key
  env      = each.value.env
  command = ["vault",
    "server",
    "-config",
    "/vault/config/server.hcl",
    "-log-level",
    var.vault_log_level
  ]
  image    = docker_image.vault.name
  must_run = true
  rm       = false # Set to false to allow inspection of failed containers, true for production

  capabilities {
    add = ["IPC_LOCK", "SYSLOG"] # IPC_LOCK is recommended by HashiCorp for Vault
  }

  healthcheck {
    test         = ["CMD", "vault", "status"] # Basic health check
    interval     = "10s"
    timeout      = "2s"
    start_period = "10s" # Give Vault some time to start before health checks begin
    retries      = 2
  }

  networks_advanced {
    name         = docker_network.vault_docker_lab_network.name
    ipv4_address = each.value.ipv4_address
  }

  ports {
    internal = each.value.internal_port
    external = each.value.external_port
    protocol = "tcp"
  }

  volumes {
    host_path      = each.value.host_path_certs
    container_path = "/vault/certs"
  }

  volumes {
    host_path      = each.value.host_path_config
    container_path = "/vault/config"
  }

  volumes {
    host_path      = each.value.host_path_logs
    container_path = "/vault/logs"
  }

  # Ensure the Droplet is ready and cloud-init is done before creating containers
  depends_on = [digitalocean_droplet.vault_host]
}

# -----------------------------------------------------------------------
# Vault initialization and unsealing logic
# -----------------------------------------------------------------------

# Initialize the first Vault node
resource "null_resource" "active_node_init" {
  depends_on = [
    docker_container.vault-docker-lab["vault_docker_lab_1"],
    local_file.vault_init_placeholder
  ]

  triggers = {
    vault_node1_container_id = docker_container.vault-docker-lab["vault_docker_lab_1"].id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      # Ждём, пока Vault запустится
      "until curl --insecure --fail --silent https://127.0.0.1:8200/v1/sys/seal-status --output /dev/null; do printf '.'; sleep 4; done",
      # Выполняем инициализацию Vault
      "vault operator init -key-shares=1 -key-threshold=1 > /opt/vault_lab/.vault_docker_lab_1_init"
    ]
  }
}


# Unseal the first Vault node
resource "null_resource" "active_node_unseal" {
  depends_on = [
    null_resource.active_node_init,
    docker_container.vault-docker-lab["vault_docker_lab_1"]
  ]

  triggers = {
    vault_node1_container_id = docker_container.vault-docker-lab["vault_docker_lab_1"].id
    init_resource_id         = null_resource.active_node_init.id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
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
    docker_container.vault-docker-lab # Depends on all Vault containers
  ]

  triggers = {
    # Re-run if the active node unseal process changes or the specific standby container changes
    active_node_unsealed_id   = null_resource.active_node_unseal.id
    standby_node_container_id = docker_container.vault-docker-lab[each.key].id
    # Re-run this resource if the content of the script file changes
    script_hash               = filemd5("${path.module}/scripts/unseal-standby-node.sh")
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
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
    user        = "root"
    private_key = file(var.ssh_private_key_path)
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
    script_hash        = filemd5("${path.module}/scripts/init-bootstrap.sh")
    audit_device_trigger = null_resource.enable_audit_device.id 
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
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
    null_resource.all_nodes_configured_marker
  ]

  triggers = {
    # Re-run when the configuration is complete
    nodes_configured = null_resource.all_nodes_configured_marker.id
  }

  connection {
    type        = "ssh"
    host        = var.droplet_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "2m"
  }

  # First, check if files exist on remote server
  provisioner "remote-exec" {
    inline = [
      "if [ ! -f /opt/vault_lab/.vault_docker_lab_1_init ]; then echo 'Init file not found on remote server!'; exit 1; fi",
      "if [ ! -f /opt/vault_lab/backups/bootstrap-token ]; then echo 'Bootstrap token file not found on remote server!'; exit 1; fi",
      "echo 'Required files exist on remote server.'"
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
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key_path} root@${var.droplet_ip}:/opt/vault_lab/.vault_docker_lab_1_init ./.vault_docker_lab_1_init
      if [ $? -eq 0 ]; then
        echo "Vault init file downloaded to .vault_docker_lab_1_init"
      else
        echo "Failed to download vault init file"
      fi
    EOT
  }

  # Download bootstrap token file
  provisioner "local-exec" {
    command = <<EOT
      echo "Downloading bootstrap token file..."
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key_path} root@${var.droplet_ip}:/opt/vault_lab/backups/bootstrap-token ./.bootstrap-token
      if [ $? -eq 0 ]; then
        echo "Bootstrap token file downloaded to ./.bootstrap-token"
      else
        echo "Failed to download bootstrap token file"
      fi
    EOT
  }
}

# # --- Outputs ---
# # (Your existing outputs)
