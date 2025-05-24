#!/bin/env bash

# Устанавливаем немедленный выход при ошибках
set -e

# Определяем путь до директории проекта (где находится скрипт)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="${SCRIPT_DIR}"

# Устанавливаем префикс проекта для уникальной идентификации ресурсов
PROJECT_NAME="grimwaves-api"

# Цвета для вывода
GREEN='\033[0;32m'
NC='\033[0m' # No Color
RED='\033[0;31m'

# Функция для отображения ошибок и выхода из скрипта
error_exit() {
  echo -e "${RED}ОШИБКА: $1${NC}" >&2
  exit 1
}

# Функция для отображения успешного завершения
success_print() {
  echo -e "${GREEN}УСПЕХ: $1${NC}"
}

# Проверка наличия адреса Vault
if [ -z "${VAULT_ADDR}" ]; then
  if [ -f "${PROJECT_DIR}/backups/vault-addr" ]; then
    export VAULT_ADDR=$(cat "${PROJECT_DIR}/backups/vault-addr" | grep -oP 'VAULT_ADDR: \K.*')
    success_print "Переменная VAULT_ADDR=$VAULT_ADDR установлена из файла"
  else
    export VAULT_ADDR="https://127.0.0.1:8200"
    success_print "Переменная VAULT_ADDR=$VAULT_ADDR установлена по умолчанию"
  fi
fi

# Проверка наличия токена в переменной окружения
if [ -z "${VAULT_TOKEN}" ]; then
  error_exit "Переменная VAULT_TOKEN не установлена. 
  Используйте команду: export VAULT_TOKEN=\$(cat ${PROJECT_DIR}/backups/bootstrap-token | grep -oP 'Bootstrap Token: \\K.*')
  или аутентифицируйтесь командой: vault login"
fi

# Проверка статуса токена
TOKEN_INFO=$(vault token lookup -format=json 2>/dev/null || echo '{"data":{"display_name":"error"}}')
DISPLAY_NAME=$(echo "$TOKEN_INFO" | jq -r .data.display_name)

if [ "$DISPLAY_NAME" == "error" ]; then
  error_exit "Невозможно прочитать информацию о токене. Токен недействителен или у него нет необходимых прав."
fi

success_print "Аутентификация успешна. Используется токен: $DISPLAY_NAME"
echo "Настройка Vault для проекта: ${PROJECT_NAME}"

# Проверка и включение метода аутентификации AppRole
echo "Настройка AppRole..."
APPROLE_ENABLED=$(vault auth list -format=json 2>/dev/null | jq -r 'has("approle/")' 2>/dev/null || echo "false")
if [ "$APPROLE_ENABLED" != "true" ]; then
  echo "Включение метода аутентификации AppRole..."
  vault auth enable approle || error_exit "Не удалось включить метод аутентификации AppRole"
  # Небольшая пауза после включения метода аутентификации
  sleep 2
  success_print "Метод аутентификации AppRole успешно включен"
else
  success_print "AppRole уже включен"
fi

# Сначала включаем движок KV версии 2, если он еще не включен
echo "Проверка KV движка..."
if vault secrets enable -path=secret kv-v2 2>/dev/null; then
  success_print "KV движок версии 2 успешно включен"
else 
  success_print "KV секреты уже включены"
fi

# Затем создаем и применяем политику inline с уникальным именем проекта
echo "Создание политики для проекта..."
vault policy write ${PROJECT_NAME}-vault-agent-policy - << EOF || error_exit "Не удалось создать политику"
path "secret/data/${PROJECT_NAME}/*" {
  capabilities = ["read"]
}
EOF
success_print "Политика ${PROJECT_NAME}-vault-agent-policy успешно создана"

# Создаем роль с уникальным именем для проекта
echo "Создание AppRole для проекта..."
vault write auth/approle/role/${PROJECT_NAME}-vault-agent \
    token_policies="${PROJECT_NAME}-vault-agent-policy" \
    token_ttl=1h \
    token_max_ttl=24h \
    secret_id_ttl=720h || error_exit "Не удалось создать AppRole" # 30 дней
success_print "AppRole ${PROJECT_NAME}-vault-agent успешно создана"

# Создаем директорию для vault-agent, если она не существует
if [ ! -d "${PROJECT_DIR}/vault-agent" ]; then
  mkdir -p "${PROJECT_DIR}/vault-agent" || error_exit "Не удалось создать директорию vault-agent"
  success_print "Директория vault-agent успешно создана"
else
  success_print "Директория vault-agent уже существует"
fi

# Получаем role_id для этого проекта и записываем его в файл
echo "Получение Role ID..."
ROLE_ID=$(vault read -format=json auth/approle/role/${PROJECT_NAME}-vault-agent/role-id | jq -r .data.role_id) || error_exit "Не удалось получить Role ID"
echo "Role ID: ${ROLE_ID}"
echo -n "${ROLE_ID}" > "${PROJECT_DIR}/vault-agent/auth/role-id" || error_exit "Не удалось записать Role ID в файл"
chmod 600 "${PROJECT_DIR}/vault-agent/auth/role-id" || error_exit "Не удалось установить права доступа для файла role-id"
success_print "Role ID успешно получен и сохранен"

# Получаем secret_id для этого проекта и записываем его в файл или используем wrapped token
echo "Получение Secret ID..."
if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  # Получаем wrapped secret_id с TTL в 15 минут
  WRAPPED_TOKEN=$(vault write -f -wrap-ttl=15m -format=json auth/approle/role/${PROJECT_NAME}-vault-agent/secret-id | jq -r .wrap_info.token) || error_exit "Не удалось получить Wrapped Token"
  echo "Wrapped Token получен (TTL: 15 минут)"
  echo -n "${WRAPPED_TOKEN}" > "${PROJECT_DIR}/vault-agent/auth/wrapped-secret-id" || error_exit "Не удалось записать Wrapped Token в файл"
  chmod 600 "${PROJECT_DIR}/vault-agent/auth/wrapped-secret-id" || error_exit "Не удалось установить права доступа для файла wrapped-secret-id"
  success_print "Wrapped Token успешно получен и сохранен"
else 
  # Получаем обычный secret_id
  SECRET_ID=$(vault write -format=json -f auth/approle/role/${PROJECT_NAME}-vault-agent/secret-id | jq -r .data.secret_id) || error_exit "Не удалось получить Secret ID"
  echo "Secret ID получен"
  echo -n "${SECRET_ID}" > "${PROJECT_DIR}/vault-agent/auth/secret-id" || error_exit "Не удалось записать Secret ID в файл"
  chmod 600 "${PROJECT_DIR}/vault-agent/auth/secret-id" || error_exit "Не удалось установить права доступа для файла secret-id"
  success_print "Secret ID успешно получен и сохранен"
fi

# Запрос и добавление Spotify API ключей
echo ""
echo "=== Настройка Spotify API ключей для проекта ${PROJECT_NAME} ==="
echo "Вам необходимо предоставить API ключи Spotify для интеграции с сервисом потоковой музыки."
echo ""

# Безопасный запрос значений секретов (без отображения ввода)
echo -n "Введите Client ID для Spotify API: "
read -r CLIENT_ID
if [ -z "$CLIENT_ID" ]; then
  error_exit "Client ID не может быть пустым"
fi

echo -n "Введите Client Secret для Spotify API (ввод скрыт): "
read -rs CLIENT_SECRET
echo "" # Добавление переноса строки после скрытого ввода
if [ -z "$CLIENT_SECRET" ]; then
  error_exit "Client Secret не может быть пустым"
fi

# Сохранение секретов в Vault и проверка результата
echo "Сохранение Spotify API ключей в Vault..."
if vault kv put secret/${PROJECT_NAME}/dev/streaming/spotify \
       client_id="$CLIENT_ID" \
       client_secret="$CLIENT_SECRET"; then
    success_print "Секреты Spotify API успешно сохранены в Vault по пути secret/${PROJECT_NAME}/dev/streaming/spotify"
else
    error_exit "Не удалось сохранить секреты Spotify API в Vault"
fi

# Проверка, что секреты действительно записаны
echo "Проверка записи секретов..."
if ! vault kv get -format=json secret/${PROJECT_NAME}/dev/streaming/spotify > /dev/null; then
    error_exit "Не удалось проверить наличие секретов в Vault. Возможно, они не были корректно сохранены."
fi
success_print "Секреты успешно проверены"

# Логируем информацию об аудите
timestamp=$(date +"%Y-%m-%d %T")
echo "$timestamp - Настройка проекта $PROJECT_NAME выполнена пользователем $DISPLAY_NAME" >> vault_docker_lab.log || error_exit "Не удалось записать лог"
success_print "Информация об операции записана в журнал аудита"

# Копируем role-id и secret-id в директорию backups для удобства
echo "Копирование учетных данных в директорию backups..."
if [ ! -d "${PROJECT_DIR}/backups" ]; then
  mkdir -p "${PROJECT_DIR}/backups" || error_exit "Не удалось создать директорию backups"
  chmod 700 "${PROJECT_DIR}/backups" || error_exit "Не удалось установить права доступа для директории backups"
  success_print "Директория backups успешно создана"
else
  success_print "Директория backups уже существует"
fi

cp "${PROJECT_DIR}/vault-agent/auth/role-id" "${PROJECT_DIR}/backups/role-id" || error_exit "Не удалось скопировать role-id в backups"
if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  cp "${PROJECT_DIR}/vault-agent/auth/wrapped-secret-id" "${PROJECT_DIR}/backups/wrapped-secret-id" || error_exit "Не удалось скопировать wrapped-secret-id в backups"
  success_print "Wrapped Token скопирован в директорию backups"
else
  cp "${PROJECT_DIR}/vault-agent/auth/secret-id" "${PROJECT_DIR}/backups/secret-id" || error_exit "Не удалось скопировать secret-id в backups"
  success_print "Secret ID скопирован в директорию backups"
fi

echo ""
echo "======================================================"
success_print "Настройка Vault для проекта ${PROJECT_NAME} завершена успешно!"
echo "Используйте префикс '${PROJECT_NAME}' для всех ресурсов, связанных с этим проектом"
echo ""
echo "Созданы следующие ресурсы:"
echo "1. Политика ${PROJECT_NAME}-vault-agent-policy"
echo "2. AppRole с именем ${PROJECT_NAME}-vault-agent"
echo "3. Секреты Spotify API по пути secret/${PROJECT_NAME}/dev/streaming/spotify"
echo ""
echo "Учетные данные сохранены:"
echo "Role ID записан в: ${PROJECT_DIR}/vault-agent/auth/role-id и скопирован в ${PROJECT_DIR}/backups/role-id"

if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  echo "Wrapped Token (для Secret ID) записан в: ${PROJECT_DIR}/vault-agent/auth/wrapped-secret-id и скопирован в ${PROJECT_DIR}/backups/wrapped-secret-id"
  echo ""
  echo "Для запуска Vault Agent с wrapped token, используйте:"
  echo "export VAULT_PROJECT_NAME=${PROJECT_NAME}"
  echo "export VAULT_ROLE_ID=\$(cat ${PROJECT_DIR}/backups/role-id)"
  echo "export VAULT_WRAPPED_SECRET_ID=\$(cat ${PROJECT_DIR}/backups/wrapped-secret-id)"
else
  echo "Secret ID записан в: ${PROJECT_DIR}/vault-agent/auth/secret-id и скопирован в ${PROJECT_DIR}/backups/secret-id"
  echo ""
  echo "Для запуска Vault Agent, используйте:"
  echo "export VAULT_PROJECT_NAME=${PROJECT_NAME}"
  echo "export VAULT_ROLE_ID=\$(cat ${PROJECT_DIR}/vault-agent/auth/role-id)"
  echo "export VAULT_SECRET_ID=\$(cat ${PROJECT_DIR}/vault-agent/auth/secret-id)"
fi

# Выводим команду для запуска Vault Agent с Docker
echo ""
echo "Для запуска Vault Agent в Docker контейнере, используйте:"
echo "export VAULT_PROJECT_NAME=${PROJECT_NAME}"
echo "export VAULT_ROLE_ID=\$(cat ${PROJECT_DIR}/vault-agent/auth/role-id)"
if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  echo "export VAULT_WRAPPED_SECRET_ID=\$(cat ${PROJECT_DIR}/vault-agent/auth/wrapped-secret-id)"
else
  echo "export VAULT_SECRET_ID=\$(cat ${PROJECT_DIR}/vault-agent/auth/secret-id)"
fi
echo "docker-compose up -d vault-agent"
echo "======================================================"
