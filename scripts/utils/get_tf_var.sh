#!/usr/bin/env bash
# Utility: get_tf_var.sh
# Usage: get_tf_var.sh ENV_VAR_NAME TF_OUTPUT_NAME [REQUIRED]
# Prints the value or exits with error if REQUIRED is set and not found.

set -euo pipefail

ENV_VAR_NAME="$1"
TF_OUTPUT_NAME="$2"
REQUIRED="${3:-}" # any value = required

# Определяем путь к корневому каталогу проекта (два уровня вверх от скрипта)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Try from environment
value="${!ENV_VAR_NAME:-}"

# If not set, try terraform output
if [ -z "$value" ]; then
  if command -v terraform &>/dev/null && [ -f "${PROJECT_ROOT}/terraform.tfstate" ]; then
    # Переходим в корень проекта для выполнения terraform output
    cd "${PROJECT_ROOT}" || {
      echo "[get_tf_var.sh] ERROR: Failed to change to project root directory" >&2
      exit 1
    }
    value=$(terraform output -raw "$TF_OUTPUT_NAME" 2>/dev/null || true)
  fi
fi

if [ -z "$value" ] && [ -n "$REQUIRED" ]; then
  echo "[get_tf_var.sh] ERROR: $ENV_VAR_NAME not set and terraform output $TF_OUTPUT_NAME not found" >&2
  exit 1
fi

# Print value (may be empty if not required)
echo "$value" 