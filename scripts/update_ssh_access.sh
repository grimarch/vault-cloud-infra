#!/usr/bin/env bash
set -euo pipefail

# Script to update allowed IP addresses for SSH
# Can be run locally before connecting if you have a dynamic IP

# Get current public IPv4 address
CURRENT_IP=""
for svc in "ipv4.icanhazip.com" "api.ipify.org" "ifconfig.me" "ipinfo.io/ip"; do
    ip=$(curl -s "$svc" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
    if [ -n "$ip" ]; then
        CURRENT_IP="$ip"
        break
    fi
done

if [ -z "$CURRENT_IP" ]; then
    echo "❌ Unable to determine your public IPv4 address"
    exit 1
fi

echo "✅ Determined your current public IPv4 address: $CURRENT_IP"

# Path to terraform.tfvars file
TFVARS_FILE="terraform.tfvars"

# Check if the file exists
if [ ! -f "$TFVARS_FILE" ]; then
    echo "❌ File $TFVARS_FILE not found"
    exit 1
fi

# Update allowed_ssh_cidr_blocks in terraform.tfvars
if grep -q "allowed_ssh_cidr_blocks" "$TFVARS_FILE"; then
    # If the variable already exists, update it
    sed -i "s|allowed_ssh_cidr_blocks=.*|allowed_ssh_cidr_blocks=[\"$CURRENT_IP/32\"]|" "$TFVARS_FILE"
else
    # If the variable doesn't exist, add it
    echo "allowed_ssh_cidr_blocks=[\"$CURRENT_IP/32\"]" >> "$TFVARS_FILE"
fi

echo "✅ Updated $TFVARS_FILE with your current IP: $CURRENT_IP/32"

# Ask user if they want to apply changes
read -p "Apply changes via terraform apply? (y/n): " APPLY

if [[ "$APPLY" =~ ^[Yy]$ ]]; then
    # Do terraform apply to update firewall rules
    echo "🔄 Applying changes..."
    terraform apply -target=digitalocean_firewall.vault_firewall -auto-approve
    echo "✅ Firewall rules updated"

    # Get SSH port and key path through terraform output, with fallback to defaults
    SSH_PORT=$(terraform output -raw ssh_port 2>/dev/null)
    SSH_KEY_PATH=$(terraform output -raw ssh_private_key_path 2>/dev/null)
    DROPLET_IP=$(terraform output -raw droplet_public_ip 2>/dev/null)

    echo "📋 Now you can connect via SSH using:"
    echo "ssh -i ${SSH_KEY_PATH} -p ${SSH_PORT} root@${DROPLET_IP}"
    echo "scp -P ${SSH_PORT} -i ${SSH_KEY_PATH} somefile root@${DROPLET_IP}:/tmp/"

else
    echo "❌ Changes for droplet firewall not applied"
fi
