#!/bin/bash
# Docker Setup Utility Functions
# This script is intended to be sourced by other scripts.

# Ensure strict mode for the functions defined here, even if the calling script doesn't set it.
# However, the calling script's set -e will cause exit on error within these functions.
set -u # Treat unset variables as an error
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed

ensure_docker_installed_and_running() {
  echo "[Docker Utils] Ensuring Docker is installed and running..."
  if ! command -v docker &> /dev/null; then
    echo "[Docker Utils] Docker command not found, attempting to install via apt..."
    # Assuming apt-get update has been run recently by the calling script
    if ! apt-get install -yq docker.io; then
        echo "[Docker Utils] ERROR: Failed to install docker.io!"
        exit 1
    fi
  fi

  if ! systemctl is-active --quiet docker; then
    echo "[Docker Utils] Docker service is not active, attempting to start..."
    if ! systemctl start docker; then
      echo "[Docker Utils] ERROR: Failed to start Docker via systemctl start!"
      systemctl status docker --no-pager # Show status for diagnostics
      exit 1
    fi
    sleep 3 # Give Docker some time to start up
    if ! systemctl is-active --quiet docker; then
      echo "[Docker Utils] ERROR: Docker did not become active after starting!"
      systemctl status docker --no-pager
      exit 1
    fi
  fi
  echo "[Docker Utils] ✅ Docker is installed and running."
}

configure_docker_dns() {
  echo "[Docker Utils] Configuring Docker DNS to use firewall-allowed nameservers..."
  
  # Create Docker daemon configuration directory
  mkdir -p /etc/docker
  
  # Configure Docker to use specific DNS servers that match our firewall rules
  # This prevents DNS resolution timeouts when Docker tries to use system DNS (127.0.0.53)
  # which is blocked by our restrictive firewall configuration
  cat > /etc/docker/daemon.json << EOF
{
  "dns": ["8.8.8.8", "1.1.1.1", "8.8.4.4", "1.0.0.1"],
  "dns-opts": ["ndots:2", "timeout:3"],
  "dns-search": ["localdomain"]
}
EOF
  
  echo "[Docker Utils] ✅ Docker DNS configuration created (/etc/docker/daemon.json)"
  echo "[Docker Utils] DNS servers: 8.8.8.8, 1.1.1.1, 8.8.4.4, 1.0.0.1"
  echo "[Docker Utils] Note: Docker service restart required for DNS changes to take effect"
}

test_docker_dns() {
  echo "[Docker Utils] Testing Docker DNS resolution..."
  
  # Test Docker DNS resolution with a simple container
  if docker run --rm alpine:latest nslookup registry-1.docker.io > /dev/null 2>&1; then
    echo "[Docker Utils] ✅ Docker DNS resolution test PASSED (registry-1.docker.io resolved)"
  else
    echo "[Docker Utils] ⚠️  Docker DNS resolution test FAILED"
    echo "[Docker Utils] Attempting diagnosis..."
    docker run --rm alpine:latest nslookup registry-1.docker.io || true
    echo "[Docker Utils] This may indicate DNS configuration issues"
  fi
}

verify_docker_setup() {
  echo "[Docker Utils] Verifying Docker operational status..."
  
  # Check if Docker service is active
  if ! systemctl is-active --quiet docker; then
    echo "[Docker Utils] ERROR: Docker service is not active!"
    systemctl status docker --no-pager
    exit 1
  fi
  
  # Check if Docker socket exists and is accessible
  if [ ! -S /var/run/docker.sock ]; then
    echo "[Docker Utils] ERROR: Docker socket not found at /var/run/docker.sock!"
    exit 1
  fi

  # Test Docker functionality
  local max_attempts_version=12 # Approx 60 seconds
  local attempt_version=1
  local responsive=false
  while (( attempt_version <= max_attempts_version )); do
    (set +o pipefail; docker version &>/dev/null)
    if [ $? -eq 0 ]; then 
      echo "[Docker Utils] ✅ Docker API is responsive ('docker version' successful on attempt $attempt_version/$max_attempts_version)."
      responsive=true
      break
    fi
    echo "[Docker Utils] Waiting for Docker API to respond... (attempt $attempt_version/$max_attempts_version, sleeping 5s)"
    sleep 5
    ((attempt_version++))
  done

  if [ "$responsive" != "true" ]; then
    echo "[Docker Utils] ERROR: Failed to connect to Docker API via 'docker version' after multiple attempts."
    echo "[Docker Utils] Attempting diagnostics..."
    echo "[Docker Utils] --- Docker Status ---"
    systemctl status docker --no-pager
    echo "[Docker Utils] --- Docker Socket Permissions ---"
    ls -la /var/run/docker.sock || echo "[Docker Utils] Cannot list docker socket."
    exit 1
  fi
  echo "[Docker Utils] ✅ Docker operational status verified successfully."
} 