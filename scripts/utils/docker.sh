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

configure_docker_tcp_listening() {
  echo "[Docker Utils] Configuring Docker to listen on TCP (0.0.0.0:2375)..."
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << EOF
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2375"]
}
EOF

  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF
  echo "[Docker Utils] ✅ Docker TCP configuration files created (/etc/docker/daemon.json, /etc/systemd/system/docker.service.d/override.conf)."
}

reload_and_restart_docker() {
  echo "[Docker Utils] Reloading systemd daemon and restarting Docker service..."
  if ! systemctl daemon-reload; then
    echo "[Docker Utils] ERROR: systemctl daemon-reload failed!"
    exit 1
  fi
  if ! systemctl restart docker; then
    echo "[Docker Utils] ERROR: systemctl restart docker failed!"
    systemctl status docker --no-pager
    exit 1
  fi
  
  echo "[Docker Utils] Waiting for Docker service to become active after restart..."
  local max_attempts=12 # Approx 60 seconds (12 * 5s)
  local attempt=1
  while (( attempt <= max_attempts )); do
    if systemctl is-active --quiet docker; then
      echo "[Docker Utils] ✅ Docker is active (attempt $attempt/$max_attempts)."
      sleep 2 # Add a small additional delay to ensure Docker socket is ready
      return 0 # Success
    fi
    echo "[Docker Utils] Waiting for Docker to become active... (attempt $attempt/$max_attempts, sleeping 5s)"
    sleep 5
    ((attempt++))
  done

  echo "[Docker Utils] ERROR: Docker did not become active after $max_attempts attempts post-restart."
  systemctl status docker --no-pager
  exit 1
}

verify_docker_setup() {
  echo "[Docker Utils] Verifying Docker operational status..."
  local max_attempts_netstat=12 # Approx 60 seconds
  local attempt_netstat=1
  local listening=false
  while (( attempt_netstat <= max_attempts_netstat )); do
    if netstat -tuln | grep -q ':2375'; then
      echo "[Docker Utils] ✅ Docker is listening on port 2375 (attempt $attempt_netstat/$max_attempts_netstat)."
      listening=true
      break
    fi
    echo "[Docker Utils] Waiting for Docker to listen on port 2375... (attempt $attempt_netstat/$max_attempts_netstat, sleeping 5s)"
    sleep 5
    ((attempt_netstat++))
  done

  if [ "$listening" != "true" ]; then
    echo '[Docker Utils] ERROR: Docker is not listening on port 2375 after multiple attempts!'
    systemctl status docker --no-pager
    exit 1
  fi

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
    echo "[Docker Utils] --- Listening Ports (grep 2375) ---"
    netstat -tuln | grep 2375 || echo "[Docker Utils] Port 2375 not found in netstat output."
    echo "[Docker Utils] --- Docker Daemon Config (/etc/docker/daemon.json) ---"
    cat /etc/docker/daemon.json
    echo "[Docker Utils] --- Systemd Override (/etc/systemd/system/docker.service.d/override.conf) ---"
    cat /etc/systemd/system/docker.service.d/override.conf
    exit 1
  fi
  echo "[Docker Utils] ✅ Docker operational status verified successfully."
} 