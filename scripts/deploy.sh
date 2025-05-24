#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Get the directory where the script is located
SCRIPT_DIR_REAL=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# Assume the project root is one level up from the script's directory
PROJECT_ROOT=$(cd "${SCRIPT_DIR_REAL}/.." &>/dev/null && pwd)

# Change to the project root directory so all subsequent commands run from there
cd "$PROJECT_ROOT" || { echo "ERROR: Could not change to project root directory: $PROJECT_ROOT"; exit 1; }

echo "INFO: Running deploy script from project root: $PROJECT_ROOT"

# 🔖 Подготовка
export TF_CLI_ARGS="-no-color" # disable color output for terraform
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOGDIR="logs"
SCRIPT_LOGFILE="${LOGDIR}/${TIMESTAMP}-script.log"
mkdir -p "$LOGDIR"

# 📝 Запись всего вывода в лог + вывод на экран
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

# 🎨 Настраиваем отображение команд
export PS4='[RUN] '
set -x

log_info "📦 ==== Скрипт настройки Terraform и Vault ===="

# Check for required tools
for cmd in terraform vault jq ssh docker; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Команда '$cmd' не найдена. Пожалуйста, установите необходимые зависимости."
        exit 1
    fi
done

# ❓ Вопрос пользователю
read -rp "🧨 Хотите выполнить 'terraform destroy' и полностью очистить конфигурацию? (y/N): " CONFIRM_DESTROY
if [[ "$CONFIRM_DESTROY" =~ ^[Yy]$ ]]; then
    log_info "🧹 Выполняем очистку и terraform destroy..."
    terraform destroy -auto-approve || {
        log_error "❌ Ошибка при destroy. Проверьте вывод ошибок выше."
        exit 1
    }
    log_info "Удаление файлов состояния и артефактов..."
    rm -rfv .terraform \
        terraform.tfstate \
        terraform.tfstate.backup \
        .terraform.lock.hcl \
        .vault_docker_lab_1_init \
        .vault_docker_lab_1_init.json \
        .vault-setup-info.txt \
        .vault_keys.json \
        stage1.tfplan \
        stage2.tfplan
    log_success "✅ Очистка завершена"
fi

log_info "🚧 Stage 1: Создание Droplet и Floating IP..."

log_info "🔧 Инициализация Terraform..."
terraform init -upgrade || { 
    log_error "❌ Ошибка terraform init. Проверьте наличие прав доступа и сетевое подключение."; 
    exit 1; 
}

log_info "📝 Планирование и применение инфраструктуры DigitalOcean..."
STAGE1_PLAN_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-plan-stage1.log"
terraform plan -out=stage1.tfplan \
  -target=digitalocean_droplet.vault_host \
  -target=digitalocean_floating_ip.vault_fip \
  -target=digitalocean_floating_ip_assignment.vault_fip_assign \
  -target=local_file.vault_init_placeholder \
  > "$STAGE1_PLAN_LOGFILE" || {
    log_error "❌ Ошибка terraform plan (stage1). Проверьте вывод ошибок в $STAGE1_PLAN_LOGFILE"
    exit 1
  }

log_info "🚀 Применение stage1.tfplan..."
STAGE1_APPLY_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-apply-stage1.log"
terraform apply stage1.tfplan 2>&1 | tee -a "$STAGE1_APPLY_LOGFILE" || {
    log_error "❌ Ошибка terraform apply (stage1). Проверьте вывод ошибок в $STAGE1_APPLY_LOGFILE"
    exit 1
}

log_info "🌐 Настройка переменных окружения..."

# Получаем IP-адреса с обработкой ошибок
FLOATING_IP=$(terraform output -raw floating_ip_address 2>/dev/null)
DROPLET_IP=$(terraform output -raw droplet_public_ip 2>/dev/null)

if [[ -z "$FLOATING_IP" ]]; then
    log_warning "⚠️ Не удалось получить floating_ip_address из Terraform output, пробуем использовать droplet_public_ip"
    if [[ -z "$DROPLET_IP" ]]; then
        log_error "❌ Не удалось получить ни floating_ip_address, ни droplet_public_ip из Terraform output"
        exit 1
    fi
    FLOATING_IP="$DROPLET_IP"
    log_warning "⚠️ Используем IP адрес Droplet вместо Floating IP: $FLOATING_IP"
fi

log_info "🔐 Настраиваем переменные окружения..."
export FLOATING_IP
export DOCKER_HOST="tcp://${FLOATING_IP}:2375"
export TF_VAR_docker_host="tcp://${FLOATING_IP}:2375"
export TF_VAR_droplet_ip="${FLOATING_IP}"
export TF_VAR_ssh_private_key_path="/home/archie/.ssh/id_ed25519_personal"

echo "FLOATING_IP=${FLOATING_IP}"
echo "DOCKER_HOST=${DOCKER_HOST}"
echo "TF_VAR_docker_host=${TF_VAR_docker_host}"
echo "TF_VAR_droplet_ip=${TF_VAR_droplet_ip}"
echo "TF_VAR_ssh_private_key_path=${TF_VAR_ssh_private_key_path}"

log_info "🚧 Stage 2: Настройка Vault по упрощенному алгоритму..."

STAGE2_PLAN_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-plan-stage2.log"
log_info "🔧 Планирование остальных ресурсов (Docker, Vault init/unseal)..."
terraform plan -out=stage2.tfplan 2>&1 | tee -a "$STAGE2_PLAN_LOGFILE" || {
    log_error "❌ Ошибка terraform plan (stage2). Проверьте вывод ошибок в $STAGE2_PLAN_LOGFILE"
    exit 1
}

log_info "🚀 Применение stage2.tfplan для остальных ресурсов..."
STAGE2_APPLY_LOGFILE="${LOGDIR}/${TIMESTAMP}-terraform-apply-stage2.log"
terraform apply -auto-approve stage2.tfplan 2>&1 | tee -a "$STAGE2_APPLY_LOGFILE" || {
    log_error "❌ Ошибка при применении stage2.tfplan. Проверьте лог $STAGE2_APPLY_LOGFILE"
    exit 1
}

log_success "✅ Настройка Vault завершена успешно!"
log_info "👉 Для доступа к Vault используйте:"
log_info "   export VAULT_ADDR=https://${FLOATING_IP}:8200"
log_info "   export VAULT_SKIP_VERIFY=true"

echo ""
log_info "📄 ==== Сводка логов ===="
log_info "🗂️  Основной лог скрипта:             $SCRIPT_LOGFILE"
log_info "📘 Terraform план (stage 1):          $STAGE1_PLAN_LOGFILE"
log_info "📗 Terraform применение (stage 1):    $STAGE1_APPLY_LOGFILE"
log_info "📘 Terraform применение (stage 2):    $STAGE2_APPLY_LOGFILE"
log_info "📙 Информация о настройке Vault:      .vault-setup-info.txt"

echo ""
log_success "✅ Скрипт завершён без ошибок."
log_info "🔍 Просмотреть логи:  less $SCRIPT_LOGFILE"
