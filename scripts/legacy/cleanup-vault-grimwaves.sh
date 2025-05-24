#!/bin/env bash

# Устанавливаем немедленный выход при ошибках
set -e

# Скрипт для отката конфигурации Vault
# Удаляет все ресурсы, созданные в скрипте setup-vault-grimwaves.sh

# Цвета для вывода
GREEN='\033[0;32m'
NC='\033[0m' # No Color
RED='\033[0;31m'

# Функция для отображения ошибок и выхода из скрипта
error_exit() {
  echo -e "${RED}ОШИБКА: $1${NC}" >&2
  exit 1
}

# Функция для отображения сообщений об успешном выполнении
success_print() {
  echo -e "${GREEN}УСПЕХ: $1${NC}"
}

# Префикс проекта, который был использован при настройке
PROJECT_NAME="grimwaves-api"

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
    error_exit "Переменная VAULT_TOKEN не установлена и файл ./backups/bootstrap-token не найден. 
    Используйте команду: export VAULT_TOKEN=<ваш_токен>
    или создайте bootstrap токен выполнив: ./init-bootstrap.sh"
  fi
fi

# Проверка прав доступа у текущего токена
echo "Проверка прав токена..."
TOKEN_INFO=$(vault token lookup -format=json 2>/dev/null || echo '{"data":{"display_name":"error"}}')
DISPLAY_NAME=$(echo "$TOKEN_INFO" | jq -r .data.display_name)

if [ "$DISPLAY_NAME" == "error" ]; then
  error_exit "Невозможно прочитать информацию о токене. Токен недействителен или у него нет необходимых прав."
fi

success_print "Аутентификация успешна. Использование токена: $DISPLAY_NAME"

# Удаляем секреты Spotify API
echo "Удаляем секреты Spotify API из ${PROJECT_NAME}/dev/streaming/spotify..."
if vault kv metadata delete secret/${PROJECT_NAME}/dev/streaming/spotify; then
  success_print "Секреты Spotify API успешно удалены"
else
  echo "Предупреждение: Не удалось удалить секреты Spotify API. Возможно, они уже были удалены."
fi

# Очищаем все секреты с префиксом проекта (опционально)
echo "Проверяем наличие других секретов с префиксом ${PROJECT_NAME}..."
# Здесь мы можем добавить дополнительную логику для поиска и удаления всех секретов с префиксом проекта
# Однако из соображений безопасности лучше ограничиться только теми, что мы точно знаем

# Удаляем файлы учетных данных AppRole
echo "Удаляем локальные файлы учетных данных..."
rm -f ./vault-agent/auth/role-id ./vault-agent/auth/secret-id ./vault-agent/auth/vault-token 2>/dev/null || true
rm -f ./backups/role-id ./backups/secret-id 2>/dev/null || true
rm -f ./vault-agent/rendered/*.txt ./vault-agent/rendered/*.json 2>/dev/null || true
success_print "Локальные файлы учетных данных удалены"

# Удаляем роль AppRole
echo "Удаляем роль AppRole ${PROJECT_NAME}-vault-agent..."
if vault delete auth/approle/role/${PROJECT_NAME}-vault-agent 2>/dev/null; then
  success_print "Роль AppRole ${PROJECT_NAME}-vault-agent успешно удалена"
else
  echo "Предупреждение: Не удалось удалить роль AppRole. Возможно, она уже была удалена."
fi

# Удаляем политику
echo "Удаляем политику ${PROJECT_NAME}-vault-agent-policy..."
if vault policy delete ${PROJECT_NAME}-vault-agent-policy 2>/dev/null; then
  success_print "Политика ${PROJECT_NAME}-vault-agent-policy успешно удалена"
else
  echo "Предупреждение: Не удалось удалить политику. Возможно, она уже была удалена."
fi

# Удаляем vault-token
echo "Удаляем vault-token..."
if rm -f ./vault-agent/token/vault-token 2>/dev/null; then
  success_print "vault-token успешно удалён"
else
  echo "Предупреждение: Не удалось удалить vault-token. Возможно, он уже был удалён."
fi

# Логируем информацию об аудите
timestamp=$(date +"%Y-%m-%d %T")
echo "$timestamp - Откат конфигурации проекта $PROJECT_NAME выполнен пользователем $DISPLAY_NAME" >> vault_docker_lab.log || error_exit "Не удалось записать лог"
success_print "Информация об операции записана в журнал аудита"

echo ""
echo "======================================================"
success_print "Откат конфигурации Vault для проекта ${PROJECT_NAME} завершён успешно!"
echo "Все ресурсы, связанные с проектом, были удалены:"
echo "1. Секреты Spotify API по пути secret/${PROJECT_NAME}/dev/streaming/spotify"
echo "2. Роль AppRole ${PROJECT_NAME}-vault-agent"
echo "3. Политика ${PROJECT_NAME}-vault-agent-policy"
echo "4. Локальные файлы учетных данных"
echo "======================================================"