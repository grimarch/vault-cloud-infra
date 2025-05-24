#!/bin/bash

# This script is used to unseal the standby nodes of the Vault cluster.

EXTERNAL_PORT=$1

echo '[Vault unseal] Waiting for standby nodes...'
UNSEAL_KEY=$(grep 'Unseal Key 1' /opt/vault_lab/.vault_docker_lab_1_init | awk '{print $NF}')
until [ "$(VAULT_ADDR="https://127.0.0.1:${EXTERNAL_PORT}" vault status 2>/dev/null | grep Initialized | awk '{print $2}')" = "true" ]; do sleep 1; printf '.'; done
VAULT_ADDR="https://127.0.0.1:${EXTERNAL_PORT}" vault operator unseal "${UNSEAL_KEY}"
echo '[Vault unseal] Done.'
