#!/bin/bash
set -euxo pipefail # Halt on error and undefined variables

export DEBIAN_FRONTEND=noninteractive

# --- BEGIN INJECTED NETWORK UTILS ---
${network_utils_content}
# --- END INJECTED NETWORK UTILS ---

# --- BEGIN INJECTED DOCKER UTILS ---
${docker_utils_content}
# --- END INJECTED DOCKER UTILS ---

# --- Main script execution ---

# Perform network checks first
perform_network_checks

# System updates and essential packages
echo "Starting system updates and package installation..."
apt-get update -yq
apt-get install -yq curl unzip jq tree vim net-tools dnsutils docker.io docker-compose glances htop ncdu ca-certificates software-properties-common
echo "✅ Essential packages (including docker.io) installed."

# Add HashiCorp GPG key
echo "Adding HashiCorp GPG key..."
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
echo "✅ HashiCorp GPG key added."

# Add HashiCorp repository
echo "Adding HashiCorp repository..."
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
echo "✅ HashiCorp repository added."

# Update package list again and install Vault
echo "Updating package list and installing Vault..."
apt-get update -yq
apt-get install -yq vault
echo "✅ Vault installed."

echo "✅ Finished system updates and package installation (including Vault)."

# Docker post-installation steps
echo "Configuring Docker group for 'ubuntu' and 'root' users..."
usermod -aG docker ubuntu || echo "[Warning] User 'ubuntu' not found, skipping add to docker group."
if id -u "root" >/dev/null 2>&1; then
    usermod -aG docker root || echo "[Warning] Failed to add 'root' to docker group."
fi
echo "✅ Docker group configuration attempted."
# Note: A logout/login or newgrp docker is needed for group changes to apply to current shell.
# For services/scripts started after this, it should be fine.

# --- Docker Setup using injected functions ---
ensure_docker_installed_and_running
configure_docker_tcp_listening
reload_and_restart_docker
verify_docker_setup
# --- End of Docker Setup ---

echo "✅ Docker successfully configured and verified to listen on port 2375."

# Create base directory for Vault configurations and data on the Droplet
echo "Creating base directories for Vault..."
mkdir -p /opt/vault_lab/containers
chmod -R 755 /opt/vault_lab

# Create subdirectories for each Vault instance
echo "Creating subdirectories for Vault instances..."
for i in {1..5}
  do
    mkdir -p /opt/vault_lab/containers/vault_docker_lab_"$${i}"/logs
    mkdir -p /opt/vault_lab/containers/vault_docker_lab_"$${i}"/config
    mkdir -p /opt/vault_lab/containers/vault_docker_lab_"$${i}"/certs
    chown -R root:root /opt/vault_lab/containers/vault_docker_lab_"$${i}"
    chmod -R 755 /opt/vault_lab/containers/vault_docker_lab_"$${i}"
  done
echo "✅ Vault directories created."

# Signal that cloud-init basic setup (dirs, packages) has finished
echo "✅ Cloud-init script (packages and directories) finished successfully."
touch /tmp/cloud_init_done 