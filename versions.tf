// This file is based on learn-vault-docker-lab by HashiCorp Education.
// Modified by Denis Zwinger in 2025 for updated provider constraints.
// Licensed under the Mozilla Public License 2.0.

// -----------------------------------------------------------------------------
// Vault Cloud Infra — Provider Versions
// -----------------------------------------------------------------------------
// Specifies provider and Terraform version constraints for deployment.
// Updated for compatibility with Docker, DigitalOcean, and future expansion.
// -----------------------------------------------------------------------------

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.0.2"
    }
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}
