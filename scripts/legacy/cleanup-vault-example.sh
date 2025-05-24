#!/bin/env bash

set -e

# Скрипт для отката конфигурации Vault
# Удаляет все ресурсы, созданные в скрипте setup-vault.sh

# Префикс проекта, который был использован при настройке
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

# Проверка наличия токена
if [ -z "${VAULT_TOKEN}" ]; then
  if [ -f "./backups/bootstrap-token" ]; then
    export VAULT_TOKEN=$(cat ./backups/bootstrap-token | grep -oP 'Bootstrap Token: \K.*')
    echo "Используется Bootstrap Token из файла ./backups/bootstrap-token"
  else
    echo "ОШИБКА: Переменная VAULT_TOKEN не установлена и файл ./backups/bootstrap-token не найден"
    echo "Используйте команду: export VAULT_TOKEN=<ваш_токен>"
    echo "или создайте bootstrap токен выполнив: ./init-bootstrap.sh"
    exit 1
  fi
fi

# Проверка прав доступа у текущего токена
echo "Проверка прав токена..."
TOKEN_INFO=$(vault token lookup -format=json 2>/dev/null || echo '{"data":{"display_name":"error"}}')
DISPLAY_NAME=$(echo "$TOKEN_INFO" | jq -r .data.display_name)

if [ "$DISPLAY_NAME" == "error" ]; then
  echo "ОШИБКА: Невозможно прочитать информацию о токене. Токен недействителен или у него нет необходимых прав."
  exit 1
fi

echo "Использование токена: $DISPLAY_NAME"

# Удаляем секрет, созданный для проекта
echo "Удаляем секрет ${PROJECT_NAME}/myapp/config..."
vault kv metadata delete secret/${PROJECT_NAME}/myapp/config

# Очищаем все секреты с префиксом проекта (опционально)
# echo "Проверяем наличие других секретов с префиксом ${PROJECT_NAME}..."
# Добавьте здесь команду для листинга и удаления всех секретов с префиксом проекта, если необходимо

# Удаляем файлы учетных данных AppRole
echo "Удаляем локальные файлы учетных данных..."
rm -f ./vault-agent/role-id ./vault-agent/secret-id ./vault-agent/vault-token
rm -f ./backups/role-id ./backups/secret-id
rm -f ./vault-agent/rendered/*.txt
rm -f ./vault-agent/rendered/*.json

# Удаляем роль AppRole
echo "Удаляем роль AppRole ${PROJECT_NAME}-vault-agent..."
vault delete auth/approle/role/${PROJECT_NAME}-vault-agent

# Удаляем политику
echo "Удаляем политику ${PROJECT_NAME}-vault-agent-policy..."
vault policy delete ${PROJECT_NAME}-vault-agent-policy

# Опционально: отключаем движок KV, если он использовался только для этого проекта
# ВНИМАНИЕ: это удалит все секреты, хранящиеся в этом движке!
# echo "⚠️ ⚠️ ⚠️  Отключаем движок KV..."
# vault secrets disable secret

echo "Отката конфигурации Vault для проекта ${PROJECT_NAME} завершена!"
echo "Все ресурсы, связанные с проектом, были удалены."