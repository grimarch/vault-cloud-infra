#!/bin/bash
# DigitalOcean Droplet Agent Utility Functions
# This script is intended to be sourced by other scripts.

set -u # Treat unset variables as an error
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed

# Configure DigitalOcean Agent for custom SSH port
# Usage: configure_do_agent <ssh_port>
configure_do_agent() {
  local ssh_port="$1"
  echo "[Agent Utils] Configuring DigitalOcean Agent for SSH port $ssh_port..."
  AGENT_SERVICE_UPDATED=false

  if [ "$ssh_port" != "22" ]; then
    # Check different possible locations for the agent service
    if [ -f /etc/systemd/system/droplet-agent.service ]; then
      sed -i "s|ExecStart=/opt/digitalocean/bin/droplet-agent -syslog|ExecStart=/opt/digitalocean/bin/droplet-agent -syslog -sshd_port=$ssh_port|" /etc/systemd/system/droplet-agent.service
      AGENT_SERVICE_UPDATED=true
      echo "[Agent Utils] DigitalOcean Agent service file updated for port $ssh_port (/etc/systemd/system/droplet-agent.service)"
    elif [ -f /lib/systemd/system/droplet-agent.service ]; then
      sed -i "s|ExecStart=/opt/digitalocean/bin/droplet-agent -syslog|ExecStart=/opt/digitalocean/bin/droplet-agent -syslog -sshd_port=$ssh_port|" /lib/systemd/system/droplet-agent.service
      AGENT_SERVICE_UPDATED=true
      echo "[Agent Utils] DigitalOcean Agent service file updated for port $ssh_port (/lib/systemd/system/droplet-agent.service)"
    else
      echo "[Agent Utils] WARNING: DigitalOcean Agent service file not found, Console may not work with custom SSH port"
    fi
  else
    echo "[Agent Utils] Using standard SSH port 22 - DigitalOcean Agent should work by default"
    AGENT_SERVICE_UPDATED=false
  fi

  export AGENT_SERVICE_UPDATED # Export for use in parent script if sourced
}

# Restart and verify DigitalOcean Agent
# Usage: restart_and_verify_do_agent <agent_service_updated>
restart_and_verify_do_agent() {
  local agent_service_updated="$1"
  echo "[Agent Utils] Restarting and verifying DigitalOcean Agent..."

  if [ "$agent_service_updated" = "true" ]; then
    echo "[Agent Utils] Reloading systemd and restarting DigitalOcean Agent..."
    systemctl daemon-reload
    if systemctl is-active --quiet droplet-agent; then
      systemctl stop droplet-agent
      sleep 2
    fi
    systemctl start droplet-agent
    echo "[Agent Utils] DigitalOcean Agent restarted with new SSH port configuration"
    systemctl enable droplet-agent
    if systemctl is-active --quiet droplet-agent; then
      echo "[Agent Utils] DigitalOcean Agent is running - Console access should work"
    else
      echo "[Agent Utils] WARNING: DigitalOcean Agent failed to start - Console may not work"
      systemctl status droplet-agent --no-pager || true
    fi
  else
    if systemctl is-active --quiet droplet-agent; then
      echo "[Agent Utils] DigitalOcean Agent is already running for standard SSH port"
    else
      echo "[Agent Utils] Starting DigitalOcean Agent..."
      systemctl start droplet-agent
      systemctl enable droplet-agent
      if systemctl is-active --quiet droplet-agent; then
        echo "[Agent Utils] DigitalOcean Agent started successfully"
      else
        echo "[Agent Utils] WARNING: DigitalOcean Agent failed to start"
        systemctl status droplet-agent --no-pager || true
      fi
    fi
  fi
} 