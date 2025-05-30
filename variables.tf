// This file is based on learn-vault-docker-lab by HashiCorp Education.
// Modified by Denis Zwinger in 2025 for dynamic cluster configuration.
// Licensed under the Mozilla Public License 2.0.

// -----------------------------------------------------------------------------
// Vault Cloud Infra — Variables
// -----------------------------------------------------------------------------
// Defines input variables for customizing the cluster deployment:
// - Number of standby nodes
// - Vault image version
// - Vault edition (Community or Enterprise)
// -----------------------------------------------------------------------------

# -----------------------------------------------------------------------
# Global variables
# -----------------------------------------------------------------------

# Set TF_VAR_docker_host to override this
# tcp with hostname example:
# export TF_VAR_docker_host="tcp://docker:2345"

variable "docker_host" {
    default = "unix:///var/run/docker.sock"
}

# -----------------------------------------------------------------------
# Vault variables
# -----------------------------------------------------------------------

# Set TF_VAR_vault_version to override this
variable "vault_version" {
    default = "latest"
}

# Set TF_VAR_vault_edition to override this
variable "vault_edition" {
    default = "vault"
}

# Set TF_VAR_vault_license to override this
variable "vault_license" {
    default = "https://www.hashicorp.com/products/vault/pricing"
}

# Set TF_VAR_vault_log_level to override this
variable "vault_log_level" {
    default = "info"
}

variable "do_token" {
  description = "DigitalOcean API token."
  type        = string
  sensitive   = true
}

variable "do_region" {
  description = "The DigitalOcean region to deploy resources in."
  type        = string
  default     = "fra1" # Example: Frankfurt
}

variable "do_droplet_size" {
  description = "The size slug for the DigitalOcean Droplet."
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "do_droplet_image" {
  description = "The image slug for the DigitalOcean Droplet."
  type        = string
  default     = "ubuntu-22-04-x64" # Example: Ubuntu 22.04 LTS
}

variable "do_ssh_key_fingerprint" {
  description = "The fingerprint of the SSH key to add to the Droplet. Ensure this key exists in your DigitalOcean account."
  type        = string
  # Example: "b3:a8:f1:c2:1b:4c:3d:5e:6f:7a:8b:9c:0d:1e:2f:30"
  # No default to force user input or a .tfvars file.
}

variable "project_name" {
  description = "A name prefix for resources to ensure uniqueness and easy identification."
  type        = string
  default     = "vault-lab"
}

variable "do_droplet_name" {
  description = "Name for the DigitalOcean Droplet."
  type        = string
  default     = "vault-host"
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key used for connecting to the Droplet for provisioning. This key must correspond to one of the public keys authorized on the Droplet via `do_ssh_key_fingerprint`."
  type        = string
  # No default, must be provided by the user or via a .tfvars file.
  # e.g., "~/.ssh/id_rsa_digitalocean"
}

variable "droplet_ip" {
  description = "The floating IP address of the DigitalOcean droplet."
  type        = string
  default     = "" # Or remove default if it must always be provided
}

variable "num_vault_nodes" {
  description = "Number of Vault nodes in the cluster."
  type        = number
  default     = 5
  validation {
    condition     = var.num_vault_nodes >= 1 && var.num_vault_nodes <= 5
    error_message = "Number of Vault nodes must be between 1 and 5."
  }
}

variable "allowed_ssh_cidr_blocks" {
  description = "List of CIDR blocks that are allowed to access the instance via SSH."
  type        = list(string)
  default     = ["0.0.0.0/0"] # Default allows from any IP, should be overridden
}

variable "ssh_port" {
  description = "The port on which SSH service should listen."
  type        = number
  default     = 22
}