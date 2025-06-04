# 🔐 Vault Cloud Infra

> Infrastructure-as-Code project for automated HashiCorp Vault deployment in Docker and DigitalOcean  
> **Built with Terraform, cloud-init, bootstrap scripting, and audit logging**

![Terraform](https://img.shields.io/badge/Terraform-1.5+-623CE4?logo=terraform)
![License: MPL-2.0](https://img.shields.io/badge/license-MPL_2.0-brightgreen)
![Status: Pet Project](https://img.shields.io/badge/status-pet--project-blue)
![Platform: DigitalOcean](https://img.shields.io/badge/platform-DigitalOcean-0080FF?logo=digitalocean)

## 🧠 About

This project demonstrates how to automate the provisioning and initialization of a secure HashiCorp Vault cluster using:

- 🔧 **Terraform** — infrastructure as code for creating cloud VMs and orchestrating deployment
- ☁️ **DigitalOcean** — deploy Vault to a cloud instance with pre-configuration
- 🐳 **Docker Compose** — container orchestration for Vault nodes via SSH-based provisioning
- ⚙️ **cloud-init** — for installing required dependencies on remote machines
- 🚀 **Bootstrap scripts** — initialize and unseal Vault with AppRole setup
- 🪵 **Logging and audit** — full CLI logging and state archive during deployment
- 📁 **Modular structure** — supports CI/CD integration and future expansion
- 🔒 **Security focused** — hardened configuration with enhanced isolation and proper TLS validation

## 📌 Key Features

- ✅ Deploy Vault in Docker on cloud (DigitalOcean) instances
- ✅ Configure number of standby nodes dynamically via Terraform
- ✅ Log and archive all provisioning and bootstrap output
- ✅ Securely initialize Vault with temporary tokens for AppRole auth
- ✅ Ready-to-use scripts for development, testing, or PoC
- ✅ Enhanced security with docker-compose and local socket access only
- ✅ Automated Vault cluster configuration with raft storage
- ✅ Secure non-root deployment using dedicated `vaultadmin` user
- ✅ **Secure TLS configuration** with proper certificate validation (no VAULT_SKIP_VERIFY needed)
- ✅ Modular cloud-init: DigitalOcean droplet-agent is configured via a dedicated utility script (`scripts/utils/agent.sh`) for safe SSH Console access

## 🔐 Configuration

### Prerequisites

1. **DigitalOcean Account** with an API token
2. **SSH Key** uploaded to your DigitalOcean account
3. **Terraform** installed locally

### Setup

1. Copy the example configuration file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. **Set your DigitalOcean API token** using environment variable (recommended):
   ```bash
   export TF_VAR_do_token="your_digitalocean_api_token"
   ```
   
   ⚠️ **NEVER** commit your API token to version control!

3. Edit `terraform.tfvars` and configure:
   - `do_ssh_key_fingerprint` - Your SSH key name or fingerprint from DigitalOcean
   - `ssh_private_key_path` - Path to your local private SSH key
   - `num_vault_nodes` - Number of Vault nodes (1-5)
   - `ssh_port` - Optional: SSH port to use (default: 2222)

   > ⚠️ **Important**: The `ssh_private_key_path` and `ssh_port` settings from `terraform.tfvars` will be 
   > automatically used by deployment scripts. Do not hardcode these values in scripts.

### Security Setup (Optional but Recommended)

Enable git hooks to prevent accidental token commits:
```bash
git config core.hooksPath .githooks
```

This will activate pre-commit checks that prevent committing DigitalOcean API tokens.

### Dynamic IP Management

If you have a dynamic IP address, you'll need to update the allowed SSH IP addresses whenever your IP changes:

1. Run the update script before connecting:
   ```bash
   ./scripts/update_ssh_access.sh
   ```

This script:
- Automatically detects your current public IP address
- Updates the `allowed_ssh_cidr_blocks` in terraform.tfvars
- Applies the changes to the firewall rules (after confirmation)

Alternatively, you can use a VPN with a static IP for connecting to your infrastructure.

### SSH Access

The deployment creates a dedicated `vaultadmin` user for secure, non-root access:
- SSH root login is completely disabled for security
- All operations are performed via the `vaultadmin` user with sudo privileges
- SSH connections use the non-standard port configured in terraform.tfvars

To connect to your instance:
```bash
ssh -i <your_private_key> -p <ssh_port> vaultadmin@<droplet_ip>
```

#### DigitalOcean Console (droplet-agent) Security

- Cloud-init now configures the DigitalOcean droplet-agent using a dedicated utility script:

```bash
scripts/utils/agent.sh
```

This script automatically configures the droplet-agent to work with a custom SSH port and restarts the service to ensure the DigitalOcean Console remains functional even with non-standard SSH settings. All logic is moved to a separate, template-injected module, similar to the network and docker utilities.

**Benefits:**
- Secure automation of droplet-agent configuration
- Flexible support for any SSH port
- Simplified audit and maintenance of cloud-init

#### Emergency SSH Access Control

For disaster recovery or troubleshooting, you can temporarily enable SSH access from any IP address using the following Makefile targets:

- `make emergency-ssh-on` — Enables emergency SSH access from `0.0.0.0/0` (all IPs) by updating the firewall and Terraform configuration. **Use only if you lose access via your allowed IPs!**
- `make emergency-ssh-off` — Disables emergency SSH access and restores the firewall to only allow SSH from your configured `allowed_ssh_cidr_blocks`.

Both commands will prompt for confirmation before making changes. Always remember to disable emergency access after resolving your issue to maintain security.

## 🚀 Usage

The `Makefile` simplifies deployment and cleanup operations. Below are the key commands:

### 📦 Deploy Vault (cloud)

```bash
make deploy
```

This will:

- Deploy infrastructure using Terraform in Digital Ocean cloud
- Run cloud-init
- Bootstrap Vault and unseal nodes
- Enable audit logging
- Output `droplet_public_ip`, `floating_ip_address` and instructions how to use and access Vault

If you want to see each executing command by script:
```bash
make deploy-debug
```

To destroy your droplet with all Vault configuration and (optionally) cleanup Terraform configuration:

```bash
make destroy
```

### 🔧 Configuration Options (via environment variables)


You can override default behavior using `TF_VAR_*` variables:

| Variable                         | Description                                                                 |
|----------------------------------|-----------------------------------------------------------------------------|
| `TF_VAR_do_token`                | DigitalOcean API token. **Required** - Use environment variable only!      |
| `TF_VAR_do_region`               | The DigitalOcean region to deploy resources in. Default "fra1"              |
| `TF_VAR_do_droplet_size`         | The size slug for the DigitalOcean Droplet. Default "s-1vcpu-2gb"           |
| `TF_VAR_do_droplet_image`        | The image slug for the DigitalOcean Droplet. Deafult "ubuntu-22-04-x64"     |
| `TF_VAR_do_ssh_key_fingerprint`  | The fingerprint of the SSH key to add to the Droplet.                       |
| `TF_VAR_do_droplet_name`         | Name for the DigitalOcean Droplet. Default "vault-cloud-infra"                     |


## 🔒 TLS Security

This project implements **secure TLS configuration** with proper certificate validation, eliminating the need for `VAULT_SKIP_VERIFY=true`.

### 🛡️ How It Works

The deployment uses self-signed certificates generated with HashiCorp Vault PKI engine:
- **CA Certificate**: `vault-docker-lab.lan`
- **Server Certificate**: `vault-docker-lab1.vault-docker-lab.lan`
- **IP SAN**: `127.0.0.1, 10.1.42.101` (internal IPs)

### 🌐 Accessing Vault Securely

After deployment, the script will provide instructions like this:

```bash
# Step 1: Add DNS mapping to /etc/hosts
echo '<FLOATING_IP> vault-docker-lab1.vault-docker-lab.lan' | sudo tee -a /etc/hosts

# Step 2: Set environment variables
export VAULT_ADDR=https://vault-docker-lab1.vault-docker-lab.lan:8200
export VAULT_TOKEN=<your_token>
export VAULT_CACERT=/path/to/project/containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem
```

### 🔐 Security Benefits

- ✅ **Full TLS certificate validation** (CN + CA signature)
- ✅ **Protection from MITM attacks** in network
- ✅ **No browser security warnings**
- ✅ **Works with curl, vault CLI, and browsers**

### 📋 Alternative: System-wide CA Trust

For convenience, you can install the CA certificate system-wide:

```bash
# Linux/macOS
sudo cp /path/to/project/containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem /usr/local/share/ca-certificates/vault_docker_lab_ca.crt
sudo update-ca-certificates

# Then use without VAULT_CACERT
export VAULT_ADDR=https://vault-docker-lab1.vault-docker-lab.lan:8200
```


## 🛠 Tech Stack

- Terraform (`.tf` + provisioners)
- DigitalOcean provider
- Docker Compose for container orchestration
- Docker-based Vault cluster (official image)
- cloud-init for VM provisioning
- Shell scripts (`generate-docker-compose.sh`, `init-bootstrap.sh`, `cloud-init.sh`)
- SSH-based remote configuration
- Audit logging and backup

## 🧪 Use Cases

- ✔️ DevSecOps training & demonstration
- ✔️ CI/CD integration prototype
- ✔️ Pet project for learning infrastructure-as-code patterns
- ✔️ Secure secret management at small scale

## ⚠️ Secure handling of .encryption-key

- The encryption key (.encryption-key) is automatically and securely deleted from the server after deployment and from your local machine after decryption.
- You MUST manually save the contents of .encryption-key to a secure password manager (e.g., KeepassXC) immediately after deployment.
- If you lose this key, you will not be able to decrypt your Vault credentials in the future.
- Never store .encryption-key in plaintext on disk or in backups.
- To decrypt secrets in the future, temporarily export the key from your password manager, use it, and let the script delete the file after use.

## 📜 License

This project is based on [learn-vault-docker-lab](https://github.com/hashicorp-education/learn-vault-docker-lab) by HashiCorp Education  
Modified and extended by **Denis Zwinger** in 2025  
Licensed under [Mozilla Public License 2.0](./LICENSE)

---

⬇️ Original `README.md` by HashiCorp follows (for compatibility and usage instructions)

# Vault Docker Lab

```plaintext
 _   __          ____    ___           __             __        __ 
| | / /__ ___ __/ / /_  / _ \___  ____/ /_____ ____  / /  ___ _/ / 
| |/ / _ `/ // / / __/ / // / _ \/ __/  '_/ -_) __/ / /__/ _ `/ _ \
|___/\_,_/\_,_/_/\__/ /____/\___/\__/_/\_\\__/_/   /____/\_,_/_.__/
                                                                   
Vault Docker Lab is a minimal Vault cluster Terraformed onto Docker containers.
It is useful for development and testing, but not for production.
```

## What?

Vault Docker Lab is a minimal 5-node [Vault](https://www.vaultproject.io) cluster running the official [Vault Docker image](https://hub.docker.com/_/vault/) with [Integrated Storage](https://developer.hashicorp.com/vault/docs/configuration/storage/raft) on [Docker](https://www.docker.com/products/docker-desktop/). It is powered by a `Makefile`, [Terraform CLI](https://developer.hashicorp.com/terraform/cli), and the [Terraform Docker Provider](https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs).

## Why?

To quickly establish a local Vault cluster with [Integrated Storage](https://developer.hashicorp.com/vault/docs/configuration/storage/raft) for development, education, and testing.

## How?

You can make your own Vault Docker Lab with Docker, Terraform, and the Terraform Docker provider.

## Prerequisites

To make a Vault Docker Lab, your host computer must have the following software installed:

- [Docker](https://www.docker.com/products/docker-desktop/) (tested with Docker Desktop version 4.22.1 on macOS version 13.5.1)

- [Terraform CLI](https://developer.hashicorp.com/terraform/downloads) binary installed in your system PATH (tested with version 1.5.6 darwin_arm64 on macOS version 13.5.1)

> **NOTE:** Vault Docker Lab is currently known to function on Linux (last tested on Ubuntu 22.04) and macOS with Intel or Apple silicon processors.

## Make your own Vault Docker Lab

There are just a handful of steps to make your own Vault Docker Lab.

1. Clone this repository.

   ```shell
   git clone https://github.com/hashicorp-education/learn-vault-docker-lab.git
   ```

1. Change into the lab directory.

   ```shell
   cd learn-vault-docker-lab
   ```

1. Add the Vault Docker Lab Certificate Authority certificate to your operating system trust store.

   - For macOS:

     ```shell
     sudo security add-trusted-cert -d -r trustAsRoot \
        -k /Library/Keychains/System.keychain \
        ./containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem
     ```

     > **NOTE**: You will be prompted for your user password and sometimes could be prompted twice; enter your user password as needed to add the certificate.

   - For Linux:

     - **Alpine**

        Update the package cache and install the `ca-certificates` package.

        ```shell
        sudo apk update && sudo apk add ca-certificates
        fetch https://dl-cdn.alpinelinux.org/alpine/v3.14/main/aarch64/APKINDEX.tar.gz
        fetch https://dl-cdn.alpinelinux.org/alpine/v3.14/community/aarch64/APKINDEX.tar.gz
        v3.14.8-86-g0df2022316 [https://dl-cdn.alpinelinux.org/alpine/v3.14/main]
        v3.14.8-86-g0df2022316 [https://dl-cdn.alpinelinux.org/alpine/v3.14/community]
        OK: 14832 distinct packages available
        OK: 9 MiB in 19 packages
        ```

        From within this repository directory, copy the Vault Docker Lab CA certificate to the `/usr/local/share/ca-certificates` directory.

        ```shell
        sudo cp ./containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem \
            /usr/local/share/ca-certificates/vault_docker_lab_ca.crt
        # No output expected
        ```

        Append the certificates to the file `/etc/ssl/certs/ca-certificates.crt`.

        ```shell
        sudo sh -c "cat /usr/local/share/ca-certificates/vault_docker_lab_ca.crt >> /etc/ssl/certs/ca-certificates.crt"
        # No output expected
        ```

        Update certificates.

        ```shell
        sudo sudo update-ca-certificates
        # No output expected
        ```

     - **Debian & Ubuntu**

        Install the `ca-certificates` package.

        ```shell
        sudo apt-get install -y ca-certificates
         Reading package lists... Done
         ...snip...
         Updating certificates in /etc/ssl/certs...
         0 added, 0 removed; done.
         Running hooks in /etc/ca-certificates/update.d...
         done.
        ```

       Copy the Vault Docker Lab CA certificate to `/usr/local/share/ca-certificates`.

       ```shell
       sudo cp containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem \
           /usr/local/share/ca-certificates/vault_docker_lab_ca.crt
       # No output expected
       ```

       Update certificates.

       ```shell
       sudo update-ca-certificates
       Updating certificates in /etc/ssl/certs...
       1 added, 0 removed; done.
       Running hooks in /etc/ca-certificates/update.d...
       done.
       ```

     - **RHEL**

       From within this repository directory, copy the Vault Docker Lab CA certificate to the `/etc/pki/ca-trust/source/anchors` directory.

        ```shell
        sudo cp ./containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem \
            /etc/pki/ca-trust/source/anchors/vault_docker_lab_ca.crt
        # No output expected
        ```

        Update CA trust.

        ```shell
        sudo update-ca-trust
        # No output expected
        ```

       From within this repository directory, copy the Vault Docker Lab CA certificate to the `/usr/local/share/ca-certificates` directory.

        ```shell
        sudo cp ./containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem \
            /usr/local/share/ca-certificates/vault_docker_lab_ca.crt
        # No output expected
        ```

        Update certificates.

        ```shell
        sudo update-ca-certificates
        # No output expected
        ```

1. Type `make` and press `[return]`; successful output resembles this example, and includes the initial root token value (for the sake of convenience and ease of use).

   ```plaintext
   [vault-docker-lab] Initializing Terraform workspace ...Done.
   [vault-docker-lab] Applying Terraform configuration ...Done.
   [vault-docker-lab] Checking Vault active node status ...Done.
   [vault-docker-lab] Checking Vault initialization status ...Done.
   [vault-docker-lab] Unsealing cluster nodes .....vault_docker_lab_2. vault_docker_lab_3. vault_docker_lab_4. vault_docker_lab_5. Done.
   [vault-docker-lab] Enable audit device ...Done.
   [vault-docker-lab] Export VAULT_ADDR for the active node: export VAULT_ADDR=https://127.0.0.1:8200
   [vault-docker-lab] Login to Vault with initial root token: vault login hvs.euAmS2Wc0ff3339uxTKYVtqK
   ```

1. Follow the instructions to set an appropriate `VAULT_ADDR` environment variable, and login to Vault with the initial root token value.

> **⚠️ NOTE for Cloud Deployment**: The above instructions are for local Docker setup. For DigitalOcean cloud deployment, follow the TLS Security instructions provided by the deployment script, which include setting up `/etc/hosts` mapping for proper certificate validation.

## Notes

The following notes should help you better understand the container structure Vault Docker Lab uses, along with tips on commonly used features.

### Configuration, data & logs

The configuration, data, and audit device log files live in a subdirectory under `containers` that is named after the server. For example, here is the structure of the first server, _vault_docker_lab_1_ as it appears when active.

```shell
$ tree containers/vault_docker_lab_1
containers/vault_docker_lab_1
├── certs
│   ├── server_cert.pem
│   ├── server_key.pem
│   ├── vault_docker_lab_ca.pem
│   └── vault_docker_lab_ca_chain.pem
├── config
│   └── server.hcl
├── data
│   ├── raft
│   │   ├── raft.db
│   │   └── snapshots
│   └── vault.db
└── logs

7 directories, 7 files
```

### Run a specific Vault version

Vault Docker Lab tries to keep current and offer the latest available Vault Docker image version, but you can also run a specific version of Vault for which an image exists with the `TF_VAR_vault_version` environment variable like this:. 

```shell
TF_VAR_vault_version=1.11.0 make
```