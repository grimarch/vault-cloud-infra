#!/bin/bash
set -euo pipefail

# Get parameters
NUM_NODES=${1:-5}
FLOATING_IP=${2:-"127.0.0.1"}
OUTPUT_FILE=${3:-"/opt/vault_lab/docker-compose.yml"}

# Start the docker-compose file
cat > "$OUTPUT_FILE" << 'EOF'
version: '3.8'

networks:
  vault_docker_lab_network:
    driver: bridge
    ipam:
      config:
        - subnet: 10.1.42.0/24

services:
EOF

# Generate service definitions for each node
for i in $(seq 1 "$NUM_NODES"); do
  # Calculate ports - match Terraform logic exactly
  if [ "$i" -eq 1 ]; then
    EXTERNAL_PORT=8200
  elif [ "$i" -eq 2 ]; then
    EXTERNAL_PORT=8220
  else
    # For nodes 3+: 8200 + ((idx - 1) * 10) + 20
    # idx is 0-based in Terraform, but i is 1-based here, so idx = i - 1
    EXTERNAL_PORT=$((8200 + ((i - 2) * 10) + 20))
  fi
  
  # Calculate IP address
  IP_ADDR="10.1.42.$((100 + i))"
  
  # Append service definition
  cat >> "$OUTPUT_FILE" << EOF
  vault_docker_lab_${i}:
    image: hashicorp/vault:latest
    container_name: vault_docker_lab_${i}
    hostname: vault_docker_lab_${i}
    command: ["vault", "server", "-config", "/vault/config/server.hcl", "-log-level", "info"]
    cap_add:
      - IPC_LOCK
      - SYSLOG
    environment:
      - VAULT_LICENSE=https://www.hashicorp.com/products/vault/pricing
      - VAULT_CLUSTER_ADDR=https://${IP_ADDR}:8201
      - VAULT_REDIRECT_ADDR=https://${FLOATING_IP}:${EXTERNAL_PORT}
      - VAULT_CACERT=/vault/certs/vault_docker_lab_ca.pem
    volumes:
      - /opt/vault_lab/containers/vault_docker_lab_${i}/certs:/vault/certs
      - /opt/vault_lab/containers/vault_docker_lab_${i}/config:/vault/config
      - /opt/vault_lab/containers/vault_docker_lab_${i}/logs:/vault/logs
    ports:
      - "${EXTERNAL_PORT}:8200"
    networks:
      vault_docker_lab_network:
        ipv4_address: ${IP_ADDR}
    healthcheck:
      test: ["CMD", "vault", "status"]
      interval: 10s
      timeout: 2s
      start_period: 10s
      retries: 2

EOF
done

echo "Docker Compose file generated at $OUTPUT_FILE with $NUM_NODES nodes" 