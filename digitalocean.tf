// DigitalOcean resources will be defined here in subsequent steps.
// This file is created to satisfy checklist item 1.1.1.
// SSH Key Management (Checklist item 1.2):
// We will use an existing SSH key from the DigitalOcean account.
// The fingerprint of this key is provided via the 'do_ssh_key_fingerprint' variable.
// This key will be associated with the Droplet when it's created.

data "digitalocean_ssh_key" "existing_key" {
  name = var.do_ssh_key_fingerprint # In DO, you can name your key by its fingerprint or give it a custom name.
                                   # If you used a custom name when adding the key to DO, use that name here.
                                   # For this setup, we assume the key *name* in DO might be its fingerprint or a custom name
                                   # matching the fingerprint variable for simplicity, or user ensures `do_ssh_key_fingerprint` holds the *name*.
                                   # A more robust approach might involve searching by fingerprint if API supports, or requiring key ID directly.
                                   # DigitalOcean provider's `digitalocean_ssh_key` data source looks up by NAME.
                                   # Let's assume `var.do_ssh_key_fingerprint` is actually the NAME of the key in DO for now as per DO provider docs.
                                   # If user provides fingerprint, they must ensure a key with that NAME (fingerprint as name) exists.
}

resource "digitalocean_droplet" "vault_host" {
  image     = var.do_droplet_image
  name      = var.do_droplet_name
  region    = var.do_region
  size      = var.do_droplet_size
  ssh_keys  = [data.digitalocean_ssh_key.existing_key.id]
  user_data = templatefile("${path.module}/scripts/cloud-init.sh", {
    network_utils_content = file("${path.module}/scripts/utils/network.sh")
    docker_utils_content  = file("${path.module}/scripts/utils/docker.sh")
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
      user        = "root"
      private_key = file(var.ssh_private_key_path)
      host        = self.ipv4_address
      timeout     = "10m" # Increased timeout for cloud-init completion
    }
  }

  # 2. Upload CA certificate to its final intended place (as cloud-init would have used)
  provisioner "file" {
    source      = "containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem" # Assuming this is your CA cert
    destination = "/usr/local/share/ca-certificates/vault_docker_lab_ca.crt"
    connection {
      type        = "ssh"
      user        = "root"
      private_key = file(var.ssh_private_key_path)
      host        = self.ipv4_address
    }
  }

  # 3. Install CA certificate and create final done marker
  provisioner "remote-exec" {
    inline = [
      "echo 'Installing Vault CA certificate...'",
      "update-ca-certificates",
      "echo 'Vault CA certificate installed.'",
    ]
    connection {
      type        = "ssh"
      user        = "root"
      private_key = file(var.ssh_private_key_path)
      host        = self.ipv4_address
    }
  }

  # 4. Provisioners to copy Vault configurations for all nodes
  # These will run after the CA cert is installed and directories are confirmed to exist.
  provisioner "file" {
    source      = "${path.module}/containers/" # ВАЖНО: добавлена косая черта и path.module
    destination = "/opt/vault_lab/containers"

    connection {
      type        = "ssh"
      user        = "root"
      private_key = file(var.ssh_private_key_path)
      host        = self.ipv4_address
    }
  }

  tags = ["vault-lab", "${var.project_name}"]
}

// TLS/SSL Certificate Strategy (Checklist item 3.3):
// This deployment uses the existing self-signed certificates from the `./containers` directory.
// - Vault CLI operations within Terraform (`null_resource` provisioners) are configured 
//   to use the local CA certificate (`VAULT_CACERT`).
// - `curl` commands for initial checks might use `--insecure`.
// - For browser access to the Vault UI, users will encounter a TLS warning.
//   To resolve this, users can either add a browser exception or import the
//   `./containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem` into their OS/browser trust store.
// - Let's Encrypt integration is out of scope for this initial deployment phase.

resource "digitalocean_floating_ip" "vault_fip" {
  region     = digitalocean_droplet.vault_host.region
}

resource "digitalocean_floating_ip_assignment" "vault_fip_assign" {
  ip_address = digitalocean_floating_ip.vault_fip.ip_address
  droplet_id = digitalocean_droplet.vault_host.id
}

output "droplet_public_ip" {
  description = "Public IP address of the Vault host Droplet."
  value       = digitalocean_droplet.vault_host.ipv4_address
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

  droplet_ids = [digitalocean_droplet.vault_host.id]

  # Inbound rules
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22" # SSH
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8200" # Vault API vault_docker_lab_1
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8220" # Vault API vault_docker_lab_2
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8230" # Vault API vault_docker_lab_3
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8240" # Vault API vault_docker_lab_4
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8250" # Vault API vault_docker_lab_5
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  # Add 8201 if it needs to be exposed for external cluster communication, 
  # but for single-droplet setup, inter-container communication via Docker network is typical.

  # Outbound rules (allow all by default, can be restricted if needed)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  tags = ["vault-lab", "${var.project_name}"]
} 