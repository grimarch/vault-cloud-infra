#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Parse command line arguments
DEBUG_MODE=false
for arg in "$@"; do
  case $arg in
    --debug|-d)
      DEBUG_MODE=true
      shift
      ;;
  esac
done

# Get the directory where the script is located
SCRIPT_DIR_REAL=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# Assume the project root is one level up from the script's directory
PROJECT_ROOT=$(cd "${SCRIPT_DIR_REAL}/.." &>/dev/null && pwd)

# Change to the project root directory so all subsequent commands run from there
cd "$PROJECT_ROOT" || { echo "ERROR: Could not change to project root directory: $PROJECT_ROOT"; exit 1; }

echo "INFO: Running deploy script from project root: $PROJECT_ROOT"

# 🔖 Preparation
export TF_CLI_ARGS="-no-color" # disable color output for terraform
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOGDIR="logs"
SCRIPT_LOGFILE="${LOGDIR}/${TIMESTAMP}-script.log"
mkdir -p "$LOGDIR"

# 📝 Write all output to log + display on screen
exec > >(tee -a "$SCRIPT_LOGFILE") 2>&1

# Define colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 🎨 Set debug mode only if --debug flag is provided
if [ "$DEBUG_MODE" = true ]; then
  log_info "🐛 Enabled debug mode - commands will be displayed"
  export PS4='[RUN] '
  set -x
fi

log_info "📦 ==== Script for Terraform and Vault setup in Digital Ocean ===="

# Check for required tools
for cmd in terraform vault jq ssh docker; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Command '$cmd' not found. Please install the necessary dependencies on your local machine."
        exit 1
    fi
done

# 👤 Ask user for confirmation
read -rp "🧨 Do you want to execute 'terraform destroy' and completely clean up the configuration? (y/N): " CONFIRM_DESTROY
if [[ "$CONFIRM_DESTROY" =~ ^[Yy]$ ]]; then
    log_info "🧹 Executing cleanup and terraform destroy..."
    terraform destroy -auto-approve || {
        log_error "❌ Error during destroy. Please check the output above."
        exit 1
    }
    log_info "Deleting state and artifacts..."
    rm -rfv .terraform \
        terraform.tfstate \
        terraform.tfstate.backup \
        .terraform.lock.hcl \
        .vault_docker_lab_1_init \
        stage1.tfplan \
        stage2.tfplan
    log_success "✅ Cleanup completed"
fi

log_info "🚧 Stage 1: Creating Droplet and Floating IP..."

log_info "🔧 Terraform initialization..."
terraform init -upgrade || { 
    log_error "❌ Error during terraform init. Please check the output above."; 
    exit 1; 
}

log_info "📝 Planning and applying infrastructure in DigitalOcean..."
STAGE1_PLAN_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-plan-stage1.log"
terraform plan -out=stage1.tfplan \
  -target=digitalocean_droplet.vault_cloud_infra \
  -target=digitalocean_floating_ip.vault_fip \
  -target=digitalocean_floating_ip_assignment.vault_fip_assign \
  -target=local_file.vault_init_placeholder \
  > "$STAGE1_PLAN_LOGFILE" || {
    log_error "❌ Error during terraform plan (stage1). Please check the output in $STAGE1_PLAN_LOGFILE"
    exit 1
  }

log_info "🚀 Applying stage1.tfplan..."
STAGE1_APPLY_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-apply-stage1.log"
terraform apply stage1.tfplan 2>&1 | tee -a "$STAGE1_APPLY_LOGFILE" || {
    log_error "❌ Error during terraform apply (stage1). Please check the output in $STAGE1_APPLY_LOGFILE"
    exit 1
}

log_info "🌐 Setting up environment variables..."

# Get IP addresses with error handling
FLOATING_IP=$(terraform output -raw floating_ip_address 2>/dev/null)
DROPLET_IP=$(terraform output -raw droplet_public_ip 2>/dev/null)

if [[ -z "$FLOATING_IP" ]]; then
    log_warning "⚠️ Unable to get floating_ip_address from Terraform output, trying to use droplet_public_ip"
    if [[ -z "$DROPLET_IP" ]]; then
        log_error "❌ Unable to get floating_ip_address or droplet_public_ip from Terraform output"
        exit 1
    fi
    FLOATING_IP="$DROPLET_IP"
    log_warning "⚠️ Using Droplet IP instead of Floating IP: $FLOATING_IP"
fi

log_info "🔐 Setting up environment variables..."
export FLOATING_IP
export TF_VAR_droplet_ip="${FLOATING_IP}"

echo "FLOATING_IP=${FLOATING_IP}"
echo "TF_VAR_droplet_ip=${TF_VAR_droplet_ip}"

log_info "🚧 Stage 2: Setting up Vault..."

STAGE2_PLAN_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-plan-stage2.log"
log_info "🔧 Planning remaining resources (Docker, Vault init/unseal)..."
terraform plan -out=stage2.tfplan 2>&1 | tee -a "$STAGE2_PLAN_LOGFILE" || {
    log_error "❌ Error during terraform plan (stage2). Please check the output in $STAGE2_PLAN_LOGFILE"
    exit 1
}

log_info "🚀 Applying stage2.tfplan for remaining resources..."
STAGE2_APPLY_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-apply-stage2.log"
terraform apply -auto-approve stage2.tfplan 2>&1 | tee -a "$STAGE2_APPLY_LOGFILE" || {
    log_error "❌ Error during terraform apply (stage2). Please check the output in $STAGE2_APPLY_LOGFILE"
    exit 1
}

log_success "✅ Vault setup completed successfully!"


# Get SSH port and key path through terraform output
SSH_PORT=$(terraform output -raw ssh_port 2>/dev/null)
SSH_KEY_PATH=$(terraform output -raw ssh_private_key_path 2>/dev/null)
export TF_VAR_ssh_port="$SSH_PORT"
export TF_VAR_ssh_private_key_path="$SSH_KEY_PATH"
echo "TF_VAR_ssh_private_key_path=${TF_VAR_ssh_private_key_path}"
echo "TF_VAR_ssh_port=${TF_VAR_ssh_port}"

# Export variables to make them available for vault_token.sh
export SSH_PORT
export SSH_KEY_PATH

# Call the script with the absolute path
source "${PROJECT_ROOT}/scripts/utils/vault_token.sh"
get_bootstrap_token

# If still no token, exit
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  log_error "❌ Could not retrieve VAULT_TOKEN from either local or remote sources"
  exit 1
fi

log_info "🔐 [SECURITY NOTICE] The .encryption-key is automatically and securely deleted from the server after deployment."
log_info "🔐 [SECURITY NOTICE] The .encryption-key is also automatically deleted from your local machine after decryption (see decrypt-credentials.sh)."
log_info "🔐 [SECURITY NOTICE] You MUST manually save the contents of .encryption-key to a secure password manager (e.g., KeepassXC) immediately after deployment. If you lose this key, you will not be able to decrypt your Vault credentials in the future."

log_info "👉 For access to Vault use:" > /dev/tty
    echo "" > /dev/tty
    echo "   # Step 1: Add DNS mapping to /etc/hosts" > /dev/tty
    echo "   echo '${FLOATING_IP} vault-docker-lab1.vault-docker-lab.lan' | sudo tee -a /etc/hosts" > /dev/tty
    echo "" > /dev/tty
    echo "   # Step 2: Set environment variables" > /dev/tty
    echo "   export VAULT_ADDR=https://vault-docker-lab1.vault-docker-lab.lan:8200" > /dev/tty
    echo "   export VAULT_TOKEN=${VAULT_TOKEN}" > /dev/tty
    echo "   export VAULT_CACERT=${PWD}/containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem" > /dev/tty
    echo "" > /dev/tty
    echo "   # Alternative: Trust the CA system-wide (Linux/macOS):" > /dev/tty
    echo "   # sudo cp ${PWD}/containers/vault_docker_lab_1/certs/vault_docker_lab_ca.pem /usr/local/share/ca-certificates/vault_docker_lab_ca.crt" > /dev/tty
    echo "   # sudo update-ca-certificates" > /dev/tty
    echo "   # (then use VAULT_ADDR=https://vault-docker-lab1.vault-docker-lab.lan:8200 without VAULT_CACERT)" > /dev/tty

echo ""
log_info "📄 ==== Logs summary ===="
log_info "🗂️  Main script log:             $SCRIPT_LOGFILE"
log_info "📘 Terraform plan  (stage 1):    $STAGE1_PLAN_LOGFILE"
log_info "📗 Terraform apply (stage 1):    $STAGE1_APPLY_LOGFILE"
log_info "📘 Terraform plan  (stage 2):    $STAGE2_PLAN_LOGFILE"
log_info "📗 Terraform apply (stage 2):    $STAGE2_APPLY_LOGFILE"

echo ""
log_success "✅ Script completed successfully."
log_info "🔍 View logs:  less $SCRIPT_LOGFILE"
