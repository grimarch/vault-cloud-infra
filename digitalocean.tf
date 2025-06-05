// DigitalOcean resources will be defined here in subsequent steps.
// This file is created to satisfy checklist item 1.1.1.
// SSH Key Management (Checklist item 1.2):
// We will use an existing SSH key from the DigitalOcean account.
// The fingerprint of this key is provided via the 'do_ssh_key_fingerprint' variable.
// This key will be associated with the Droplet when it's created.

data "digitalocean_ssh_key" "existing_key" {
  name = var.do_ssh_key_fingerprint
  # In DO, you can name your key by its fingerprint or give it a custom name.
  # If you used a custom name when adding the key to DO, use that name here.
  # For this setup, we assume the key *name* in DO might be its fingerprint or a custom name
  # matching the fingerprint variable for simplicity, or user ensures `do_ssh_key_fingerprint` holds the *name*.
  # A more robust approach might involve searching by fingerprint if API supports, or requiring key ID directly.
  # DigitalOcean provider's `digitalocean_ssh_key` data source looks up by NAME.
  # Let's assume `var.do_ssh_key_fingerprint` is actually the NAME of the key in DO for now as per DO provider docs.
  # If user provides fingerprint, they must ensure a key with that NAME (fingerprint as name) exists.
}

resource "digitalocean_droplet" "vault_cloud_infra" {
  image    = var.do_droplet_image
  name     = var.do_droplet_name
  region   = var.do_region
  size     = var.do_droplet_size
  ssh_keys = [data.digitalocean_ssh_key.existing_key.id]
  user_data = templatefile("${path.module}/scripts/cloud-init.sh", {
    network_utils_content = file("${path.module}/scripts/utils/network.sh")
    docker_utils_content  = file("${path.module}/scripts/utils/docker.sh")
    agent_utils_content   = file("${path.module}/scripts/utils/agent.sh")
    ssh_port              = var.ssh_port
  })

  # 1. Wait for cloud-init to create directories
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to create directories (marker: /tmp/cloud_init_done)...'",
      "while [ ! -f /tmp/cloud_init_done ]; do sleep 5; printf '.'; done",
      "echo 'Cloud-init directory creation completed.'"
    ]
    connection {
      type        = "ssh"
      user        = "vaultadmin"
      host        = self.ipv4_address
      private_key = file(var.ssh_private_key_path)
      timeout     = "20m"
      port        = var.ssh_port
    }
  }

  provisioner "remote-exec" {
    inline = ["sudo tail -5 /var/log/cloud-init-output.log"]
    connection {
      type        = "ssh"
      user        = "vaultadmin"
      host        = self.ipv4_address
      private_key = file(var.ssh_private_key_path)
      timeout     = "20m"
      port        = var.ssh_port
    }
  }

  provisioner "remote-exec" {
    inline = [
      "if command -v docker &> /dev/null; then docker --version && echo 'Docker is installed.'; else echo 'ERROR: Docker is NOT installed!'; exit 1; fi"
    ]
    connection {
      type        = "ssh"
      user        = "vaultadmin"
      host        = self.ipv4_address
      private_key = file(var.ssh_private_key_path)
      timeout     = "20m"
      port        = var.ssh_port
    }
  }

  # 2. Upload CA certificate to its final intended place (as cloud-init would have used)
  provisioner "file" {
    source      = "containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem" # Assuming this is your CA cert
    destination = "/tmp/vault_docker_lab_ca.crt"
    connection {
      type        = "ssh"
      user        = "vaultadmin"
      private_key = file(var.ssh_private_key_path)
      host        = self.ipv4_address
      port        = var.ssh_port
    }
  }

  # 3. Install CA certificate and create final done marker
  provisioner "remote-exec" {
    inline = [
      "echo 'Installing Vault CA certificate...'",
      "sudo mv /tmp/vault_docker_lab_ca.crt /usr/local/share/ca-certificates/vault_docker_lab_ca.crt",
      "sudo update-ca-certificates",
      "echo 'Vault CA certificate installed.'",
    ]
    connection {
      type        = "ssh"
      user        = "vaultadmin"
      private_key = file(var.ssh_private_key_path)
      host        = self.ipv4_address
      port        = var.ssh_port
    }
  }

  # 4. Provisioners to copy Vault configurations for all nodes
  # These will run after the CA cert is installed and directories are confirmed to exist.
  provisioner "file" {
    source      = "${path.module}/containers/" # IMPORTANT: added slash and path.module
    destination = "/opt/vault_lab/containers"

    connection {
      type        = "ssh"
      user        = "vaultadmin"
      private_key = file(var.ssh_private_key_path)
      host        = self.ipv4_address
      port        = var.ssh_port
    }
  }

  tags = ["vault-lab", "${var.project_name}"]
}

// TLS/SSL Certificate Strategy (Checklist item 3.3):
// This deployment uses the existing self-signed certificates from the `./containers` directory.
// - Vault CLI operations within Terraform (`null_resource` provisioners) are configured 
//   to use the local CA certificate (`VAULT_CACERT`).
// - `curl` commands for initial checks use the installed CA certificate (`--cacert`) for proper TLS verification.
// - For browser access to the Vault UI, users will encounter a TLS warning.
//   To resolve this, users can either add a browser exception or import the
//   `./containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem` into their OS/browser trust store.
// - Let's Encrypt integration is out of scope for this initial deployment phase.

resource "digitalocean_floating_ip" "vault_fip" {
  region = digitalocean_droplet.vault_cloud_infra.region
}

resource "digitalocean_floating_ip_assignment" "vault_fip_assign" {
  ip_address = digitalocean_floating_ip.vault_fip.ip_address
  droplet_id = digitalocean_droplet.vault_cloud_infra.id
}

output "droplet_public_ip" {
  description = "Public IP address of the Vault host Droplet."
  value       = digitalocean_droplet.vault_cloud_infra.ipv4_address
}

output "floating_ip_address" {
  description = "The provisioned Floating IP address for the Vault host."
  value       = digitalocean_floating_ip.vault_fip.ip_address
}

// DNS Configuration (Checklist item 1.4.3):
// DNS A-record for the Vault host should be manually configured 
// to point to the `floating_ip_address` output by this Terraform configuration.
// If not using a Floating IP, point to `droplet_public_ip`.
// Automatic DNS record creation via `digitalocean_record` is not implemented
// to maintain flexibility across different DNS providers.

resource "digitalocean_firewall" "vault_firewall" {
  name = "${var.project_name}-vault-firewall"

  droplet_ids = [digitalocean_droplet.vault_cloud_infra.id]

  # Inbound rules
  inbound_rule {
    protocol         = "tcp"
    port_range       = var.ssh_port                # SSH on non-standard port
    source_addresses = var.allowed_ssh_cidr_blocks # Only from allowed IPs
  }

  # Enable emergency global SSH access if flag is true
  dynamic "inbound_rule" {
    for_each = var.emergency_ssh_access ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = var.ssh_port
      source_addresses = ["0.0.0.0/0"]
    }
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "8200"                      # Vault API vault_docker_lab_1
    source_addresses = var.allowed_ssh_cidr_blocks # Only from allowed IPs
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8220"                      # Vault API vault_docker_lab_2
    source_addresses = var.allowed_ssh_cidr_blocks # Only from allowed IPs
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8230"                      # Vault API vault_docker_lab_3
    source_addresses = var.allowed_ssh_cidr_blocks # Only from allowed IPs
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8240"                      # Vault API vault_docker_lab_4
    source_addresses = var.allowed_ssh_cidr_blocks # Only from allowed IPs
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8250"                      # Vault API vault_docker_lab_5
    source_addresses = var.allowed_ssh_cidr_blocks # Only from allowed IPs
  }
  # Add 8201 if it needs to be exposed for external cluster communication, 
  # but for single-droplet setup, inter-container communication via Docker network is typical.

  # DNS resolution - STRICTLY LIMITED to trusted public DNS servers  
  outbound_rule {
    protocol   = "udp"
    port_range = "53"
    destination_addresses = [
      "8.8.8.8/32", # Google DNS Primary
      "8.8.4.4/32", # Google DNS Secondary  
      "1.1.1.1/32", # Cloudflare DNS Primary
      "1.0.0.1/32"  # Cloudflare DNS Secondary
    ]
  }
  outbound_rule {
    protocol   = "tcp"
    port_range = "53"
    destination_addresses = [
      "8.8.8.8/32", # Google DNS Primary
      "8.8.4.4/32", # Google DNS Secondary
      "1.1.1.1/32", # Cloudflare DNS Primary  
      "1.0.0.1/32"  # Cloudflare DNS Secondary
    ]
  }

  # HTTP (80) - SECURITY COMPROMISE: Open to internet due to dynamic CDN IPs
  # ⚠️ RISK: Docker Hub, Ubuntu repos use AWS ELB with changing IPs
  # ⚠️ Static IP restrictions would break package installations
  outbound_rule {
    protocol              = "tcp"
    port_range            = "80"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS (443) - SECURITY COMPROMISE: Open to internet due to dynamic CDN IPs  
  # ⚠️ RISK: Same as HTTP - modern services use dynamic IPs via CDN
  # ⚠️ Alternative: Use corporate proxy/registry (Nexus, Artifactory)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "443"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # NTP (123) - STRICTLY LIMITED to verified government time servers
  outbound_rule {
    protocol   = "udp"
    port_range = "123"
    destination_addresses = [
      "129.6.15.28/32",  # time-a-g.nist.gov
      "129.6.15.29/32",  # time-b-g.nist.gov  
      "129.6.15.30/32",  # time-c-g.nist.gov
      "132.163.97.1/32", # time-a-wwv.nist.gov
      "132.163.97.2/32"  # time-b-wwv.nist.gov
    ]
  }

  tags = ["vault-lab", "${var.project_name}"]
}

output "ssh_port" {
  description = "The port on which SSH service should listen."
  value       = var.ssh_port
}

output "ssh_private_key_path" {
  description = "Path to the SSH private key used for connecting to the Droplet."
  value       = var.ssh_private_key_path
} 