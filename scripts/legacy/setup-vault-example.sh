#!/bin/env bash

set -e

# Добавляем префикс проекта для уникальной идентификации ресурсов
PROJECT_NAME="learn-vault-lab"

# Проверка наличия адреса Vault
if [ -z "${VAULT_ADDR}" ]; then
  if [ -f "./backups/vault-addr" ]; then
    export VAULT_ADDR=$(cat ./backups/vault-addr | grep -oP 'VAULT_ADDR: \K.*')
    echo "Установлена переменная VAULT_ADDR=$VAULT_ADDR из файла"
  else
    export VAULT_ADDR="https://127.0.0.1:8200"
    echo "Установлена переменная VAULT_ADDR=$VAULT_ADDR по умолчанию"
  fi
fi

# Проверка наличия токена в переменной окружения
if [ -z "${VAULT_TOKEN}" ]; then
  echo "ОШИБКА: Переменная VAULT_TOKEN не установлена"
  echo "Используйте команду: export VAULT_TOKEN=\$(cat ./backups/bootstrap-token | grep -oP 'Bootstrap Token: \\K.*')"
  echo "или аутентифицируйтесь командой: vault login"
  exit 1
fi

# Проверка статуса токена
TOKEN_INFO=$(vault token lookup -format=json 2>/dev/null || echo '{"data":{"display_name":"error"}}')
DISPLAY_NAME=$(echo "$TOKEN_INFO" | jq -r .data.display_name)

if [ "$DISPLAY_NAME" == "error" ]; then
  echo "ОШИБКА: Невозможно прочитать информацию о токене. Токен недействителен или у него нет необходимых прав."
  exit 1
fi

echo "Использование токена: $DISPLAY_NAME"
echo "Настройка Vault для проекта: ${PROJECT_NAME}"

# Проверка и включение метода аутентификации AppRole
echo "Настройка AppRole..."
APPROLE_ENABLED=$(vault auth list -format=json 2>/dev/null | jq -r 'has("approle/")' 2>/dev/null || echo "false")
if [ "$APPROLE_ENABLED" != "true" ]; then
  echo "Включение метода аутентификации AppRole..."
  vault auth enable approle
  # Небольшая пауза после включения метода аутентификации
  sleep 2
else
  echo "AppRole уже включен"
fi

# Сначала включаем движок KV версии 2, если он еще не включен
echo "Проверка KV движка..."
vault secrets enable -path=secret kv-v2 2>/dev/null || echo "KV секреты уже включены"

# Затем создаем и применяем политику inline с уникальным именем проекта
echo "Создание политики для проекта..."
vault policy write ${PROJECT_NAME}-vault-agent-policy - << EOF
path "secret/data/${PROJECT_NAME}/*" {
  capabilities = ["read"]
}
EOF

# Создаем роль с уникальным именем для проекта
echo "Создание AppRole для проекта..."
vault write auth/approle/role/${PROJECT_NAME}-vault-agent \
    token_policies="${PROJECT_NAME}-vault-agent-policy" \
    token_ttl=1h \
    token_max_ttl=24h \
    secret_id_ttl=720h # 30 дней

# Создаем директорию для vault-agent, если она не существует
if [ ! -d "./vault-agent" ]; then
  mkdir -p ./vault-agent
fi

# Получаем role_id для этого проекта и записываем его в файл
echo "Получение Role ID..."
ROLE_ID=$(vault read -format=json auth/approle/role/${PROJECT_NAME}-vault-agent/role-id | jq -r .data.role_id)
echo "Role ID: ${ROLE_ID}"
echo -n "${ROLE_ID}" > ./vault-agent/auth/role-id
chmod 600 ./vault-agent/auth/role-id

# Получаем secret_id для этого проекта и записываем его в файл или используем wrapped token
echo "Получение Secret ID..."
if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  # Получаем wrapped secret_id с TTL в 15 минут
  WRAPPED_TOKEN=$(vault write -f -wrap-ttl=15m -format=json auth/approle/role/${PROJECT_NAME}-vault-agent/secret-id | jq -r .wrap_info.token)
  echo "Wrapped Token получен (TTL: 15 минут)"
  echo -n "${WRAPPED_TOKEN}" > ./vault-agent/auth/wrapped-secret-id
  chmod 600 ./vault-agent/auth/wrapped-secret-id
else 
  # Получаем обычный secret_id
  SECRET_ID=$(vault write -format=json -f auth/approle/role/${PROJECT_NAME}-vault-agent/secret-id | jq -r .data.secret_id)
  echo "Secret ID получен"
  echo -n "${SECRET_ID}" > ./vault-agent/auth/secret-id
  chmod 600 ./vault-agent/auth/secret-id
fi

# Создаем тестовый секрет в пространстве имен проекта
echo "Создание тестового секрета..."
vault kv put secret/${PROJECT_NAME}/myapp/config username=dbuser password=supersecret

# Логируем информацию об аудите
timestamp=$(date +"%Y-%m-%d %T")
echo "$timestamp - Настройка проекта $PROJECT_NAME выполнена пользователем $DISPLAY_NAME" >> vault_docker_lab.log

# Копируем role-id и secret-id в директорию backups для удобства
echo "Копирование учетных данных в директорию backups..."
cp ./vault-agent/auth/role-id ./backups/role-id
if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  cp ./vault-agent/auth/wrapped-secret-id ./backups/wrapped-secret-id
else
  cp ./vault-agent/auth/secret-id ./backups/secret-id
fi

echo ""
echo "Настройка Vault для проекта ${PROJECT_NAME} завершена успешно!"
echo "Используйте префикс '${PROJECT_NAME}' для всех ресурсов, связанных с этим проектом"
echo "Role ID записан в: ./vault-agent/auth/role-id и скопирован в ./backups/role-id"

if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  echo "Wrapped Token (для Secret ID) записан в: ./vault-agent/auth/wrapped-secret-id и скопирован в ./backups/wrapped-secret-id"
  echo "Для запуска Vault Agent с wrapped token, используйте:"
  echo "export VAULT_WRAPPED_SECRET_ID=\$(cat ./backups/wrapped-secret-id)"
else
  echo "Secret ID записан в: ./vault-agent/auth/secret-id и скопирован в ./backups/secret-id"
  echo "Для запуска Vault Agent, используйте:"
  echo "export VAULT_ROLE_ID=\$(cat ./backups/role-id)"
  echo "export VAULT_SECRET_ID=\$(cat ./backups/secret-id)"
fi

# Выводим команду для запуска Vault Agent с Docker
echo ""
echo "Для запуска Vault Agent в Docker контейнере, используйте:"
echo "export VAULT_ROLE_ID=\$(cat ./backups/role-id)"
if [ "${USE_WRAPPED_TOKEN:-false}" == "true" ]; then
  echo "export VAULT_WRAPPED_SECRET_ID=\$(cat ./backups/wrapped-secret-id)"
else
  echo "export VAULT_SECRET_ID=\$(cat ./backups/secret-id)"
fi
echo "docker-compose up -d vault-agent"
