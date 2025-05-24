#!/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Base directory on the remote server
REMOTE_BASE_DIR="/opt/vault_lab"

echo "INFO: Running init-bootstrap script. Base directory set to: $REMOTE_BASE_DIR"

echo "==== Скрипт настройки безопасного управления Vault через Bootstrap токен ===="
echo "ВНИМАНИЕ: Этот скрипт предполагает, что Vault уже инициализирован и распечатан!"
echo "Токены для управления будут сохранены в ${REMOTE_BASE_DIR}/backups - обязательно защитите эту директорию"
echo ""

# Проверка, выполнялся ли bootstrap ранее
if [ -f "${REMOTE_BASE_DIR}/.vault_bootstrap_done" ]; then
  echo "Bootstrap уже выполнен ранее. Прерывание."
  exit 0
fi

# Проверка директории для резервных копий
BACKUPS_DIR="${REMOTE_BASE_DIR}/backups"
if [ ! -d "$BACKUPS_DIR" ]; then
  mkdir -p "$BACKUPS_DIR"
  # Permissions will be set by the script later or should be managed by how files are written
fi

# Проверяем статус Vault
VAULT_STATUS=$(VAULT_TOKEN="$VAULT_TOKEN" vault status -format=json 2>/dev/null || echo '{"initialized":"error","sealed":"error"}')
INIT_STATUS=$(echo "$VAULT_STATUS" | jq -r .initialized 2>/dev/null || echo "error")
SEAL_STATUS=$(echo "$VAULT_STATUS" | jq -r .sealed 2>/dev/null || echo "error")

if [ "$INIT_STATUS" == "error" ]; then
  echo "Ошибка подключения к Vault. Проверьте переменную VAULT_ADDR и доступность сервера."
  exit 1
elif [ "$INIT_STATUS" != "true" ]; then
  echo "Vault не инициализирован. Terraform должен был это сделать."
  exit 1
elif [ "$SEAL_STATUS" != "false" ]; then
  echo "Vault запечатан. Terraform должен был его распечатать."
  exit 1
fi

# Сохраняем VAULT_ADDR в переменную для дальнейшего использования
# VAULT_ADDR будет установлен вызывающей стороной (terraform remote-exec)
if [ -z "${VAULT_ADDR:-}" ]; then # set -u safe check
  export VAULT_ADDR="https://127.0.0.1:8200" # Default if not set by caller
  echo "Переменная VAULT_ADDR не была установлена извне, используется по умолчанию: $VAULT_ADDR"
fi
echo "VAULT_ADDR используется: $VAULT_ADDR"


# Получение Root Token
# VAULT_TOKEN должен быть установлен вызывающей стороной (terraform remote-exec)
# Эта проверка обрабатывает случай, если он не установлен, и пытается получить его из файла.
if [ -z "${VAULT_TOKEN:-}" ]; then # set -u safe check for VAULT_TOKEN
    echo "Переменная VAULT_TOKEN (содержащая Root Token) не установлена извне. Попытка получить из файла..."
    INIT_FILE_PATH="${REMOTE_BASE_DIR}/.vault_docker_lab_1_init"
    if [ -f "$INIT_FILE_PATH" ]; then
      ROOT_TOKEN_FROM_FILE=$(grep 'Initial Root Token' "$INIT_FILE_PATH" | awk '{print $NF}')
      if [ -z "$ROOT_TOKEN_FROM_FILE" ]; then # Standard check is fine here, as it's after assignment
        echo "ОШИБКА: Не удалось извлечь Root Token из файла $INIT_FILE_PATH."
        exit 1
      fi
      export VAULT_TOKEN="$ROOT_TOKEN_FROM_FILE" # Export for subsequent vault commands in this script
      echo "Найден и установлен Root Token из файла $INIT_FILE_PATH"
    else
      echo "ОШИБКА: Файл $INIT_FILE_PATH с Root Token не найден."
      exit 1
    fi
fi

# Проверка работы токена
echo "Проверка Root токена (текущего VAULT_TOKEN)..."
# Убедимся, что VAULT_TOKEN не пуст перед вызовом vault token lookup
if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "ОШИБКА: VAULT_TOKEN пуст или не установлен перед проверкой токена."
  exit 1
fi
TOKEN_CHECK=$(VAULT_TOKEN="$VAULT_TOKEN" vault token lookup -format=json 2>/dev/null || echo '{"data":{"policies":[]}}')
POLICIES=$(echo "$TOKEN_CHECK" | jq -r '.data.policies | join(",")' 2>/dev/null || echo "error")

if [[ "$POLICIES" != *"root"* ]]; then
  echo "ОШИБКА: VAULT_TOKEN (Root Token) недействителен. Политики: $POLICIES"
  exit 1
fi

echo "Аутентификация с Root Token успешна. Настраиваем безопасное управление Vault..."

# Создание bootstrap политики для дальнейшей автоматизации
echo "Создание bootstrap политики..."
VAULT_TOKEN="$VAULT_TOKEN" vault policy write bootstrap-policy - << EOF
# Права для управления auth методами
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Права для настройки auth методов
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Права для чтения списка auth методов
path "sys/auth" {
  capabilities = ["read", "list"]
}

# Права для управления политиками
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Права для управления секретными движками
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Права для управления секретами в KV хранилище
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Права на управление общими настройками проекта
path "secret/data/projects/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Права для отзыва токенов
path "auth/token/revoke" {
  capabilities = ["update"]
}

# Права для аудита
path "sys/audit*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Права для создания токенов
path "auth/token/create" {
  capabilities = ["create", "update"]
}
EOF

# Создание административной политики
echo "Создание admin политики..."
VAULT_TOKEN="$VAULT_TOKEN" vault policy write admin-policy - << EOF
# Права для управления auth методами
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Права для управления политиками
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Права для управления KV секретами
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Просмотр статуса системы
path "sys/health" {
  capabilities = ["read", "sudo"]
}

# Управление аудитом
path "sys/audit*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

# Включение audit logging (если еще не включен)
# Terraform ресурс null_resource.enable_audit_device уже должен был это сделать.
# Эта проверка здесь для идемпотентности или если скрипт запускается отдельно.
echo "Проверка настройки аудита (для идемпотентности)..."
# Ожидаем, что Terraform уже настроил аудит, но проверяем
# Используем \`vault audit list -format=json\` и проверяем, есть ли \`file/\`
AUDIT_FILE_ENABLED=$(VAULT_TOKEN="$VAULT_TOKEN" vault audit list -format=json 2>/dev/null | jq -e '."file/"' >/dev/null 2>&1; echo $?)
if [ "$AUDIT_FILE_ENABLED" != "0" ]; then
  echo "Аудит 'file' не найден. Попытка включения аудита в /vault/logs/vault_audit.log..."
  VAULT_TOKEN="$VAULT_TOKEN" vault audit enable file file_path=/vault/logs/vault_audit.log || echo "Предупреждение: Не удалось включить аудит. Возможно, он уже включен другим способом или недостаточно прав."
else
  echo "Аудит 'file' уже настроен."
fi

# Включение движка KV версии 2, если он еще не включен
echo "Проверка KV движка (secret/)..."
if ! VAULT_TOKEN="$VAULT_TOKEN" vault secrets list -format=json | jq -e '."secret/"' > /dev/null; then
  echo "Включение KV-v2 движка на путь secret/..."
  VAULT_TOKEN="$VAULT_TOKEN" vault secrets enable -path=secret kv-v2
else
  echo "KV движок на пути secret/ уже включен."
fi

# Включение метода аутентификации userpass
echo "Проверка метода аутентификации userpass..."
if ! VAULT_TOKEN="$VAULT_TOKEN" vault auth list -format=json | jq -e '."userpass/"' > /dev/null; then
  echo "Включение метода аутентификации userpass..."
  VAULT_TOKEN="$VAULT_TOKEN" vault auth enable userpass
else
  echo "Метод аутентификации userpass уже включен."
fi

# Генерация случайного пароля для админа
ADMIN_PASSWORD=$(openssl rand -base64 16)
echo "Создание/обновление пользователя admin с admin-policy..."
VAULT_TOKEN="$VAULT_TOKEN" vault write auth/userpass/users/admin \
    password="$ADMIN_PASSWORD" \
    policies="admin-policy"

# Создание bootstrap токена с ограниченным сроком действия (24 часа)
echo "Создание bootstrap токена..."
BOOTSTRAP_TOKEN_JSON=$(VAULT_TOKEN="$VAULT_TOKEN" vault token create -policy=bootstrap-policy -display-name="bootstrap-token" -ttl=24h -format=json)
BOOTSTRAP_TOKEN=$(echo "$BOOTSTRAP_TOKEN_JSON" | jq -r .auth.client_token)

# Сохраняем токены и пароли в защищенные файлы
echo "Сохранение учетных данных в $BACKUPS_DIR..."
echo "Bootstrap Token: $BOOTSTRAP_TOKEN" > "${BACKUPS_DIR}/bootstrap-token"
echo "Admin Username: admin" > "${BACKUPS_DIR}/admin-credentials"
echo "Admin Password: $ADMIN_PASSWORD" >> "${BACKUPS_DIR}/admin-credentials"
chmod 600 "${BACKUPS_DIR}/bootstrap-token" "${BACKUPS_DIR}/admin-credentials"

# Сохраняем также VAULT_ADDR для использования в будущем
echo "VAULT_ADDR: $VAULT_ADDR" > "${BACKUPS_DIR}/vault-addr"
chmod 600 "${BACKUPS_DIR}/vault-addr"

echo "Bootstrap завершён. Создаём флаг-файл..."
touch "${REMOTE_BASE_DIR}/.vault_bootstrap_done"

echo ""
echo "==== Настройка завершена ===="
echo "Bootstrap Token сохранен в: ${BACKUPS_DIR}/bootstrap-token"
echo "Учетные данные администратора сохранены в: ${BACKUPS_DIR}/admin-credentials"
echo "Адрес Vault сохранен в: ${BACKUPS_DIR}/vault-addr"
echo ""
echo "ВАЖНО! В целях безопасности:"
echo "1. Bootstrap Token действителен в течение 24 часов. Используйте его для настройки проектов."
echo "2. После завершения настройки используйте admin учетную запись вместо Root Token."
echo "3. Рекомендуется отозвать Root Token после завершения всех настроек."
# Убрана рекомендация запускать setup-vault.sh, так как это часть bootstrap логики
# Для других проектов, используйте сохраненный bootstrap токен.