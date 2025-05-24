#!/bin/bash
# Network Setup Utility Functions
# This script is intended to be sourced by other scripts.

set -u # Treat unset variables as an error
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed

ensure_systemd_resolved_active() {
  echo "[Net Utils] Ensuring systemd-resolved is active..."
  if ! systemctl is-active --quiet systemd-resolved; then
    echo "[Net Utils] systemd-resolved is not active. Attempting to start/restart..."
    if systemctl restart systemd-resolved; then
      sleep 3 # Give it a moment
      if systemctl is-active --quiet systemd-resolved; then
        echo "[Net Utils] systemd-resolved started successfully."
      else
        echo "[Net Utils] WARNING: systemd-resolved failed to start after restart. Network issues might persist."
        # As a fallback, try to populate /etc/resolv.conf directly if systemd-resolved is problematic
        echo "[Net Utils] Attempting to set public DNS in /etc/resolv.conf as a fallback."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        echo "[Net Utils] Fallback /etc/resolv.conf created with Google and Cloudflare DNS."
      fi
    else
      echo "[Net Utils] ERROR: Failed to execute 'systemctl restart systemd-resolved'."
    fi
  else
    echo "[Net Utils] systemd-resolved is already active."
  fi
}

ensure_resolv_conf_setup() {
  echo "[Net Utils] Ensuring /etc/resolv.conf is correctly set up..."
  local STUB_RESOLV_CONF="/run/systemd/resolve/stub-resolv.conf"
  local ETC_RESOLV_CONF="/etc/resolv.conf"

  if [ -f "$STUB_RESOLV_CONF" ]; then
    # If stub-resolv.conf exists, /etc/resolv.conf should be a symlink to it or its relative path.
    if [ ! -L "$ETC_RESOLV_CONF" ] || ([ -L "$ETC_RESOLV_CONF" ] && [ ! -e "$ETC_RESOLV_CONF" ]); then
      echo "[Net Utils] $ETC_RESOLV_CONF is not a correct symlink or missing. Fixing for systemd-resolved..."
      rm -f "$ETC_RESOLV_CONF"
      ln -sf "$STUB_RESOLV_CONF" "$ETC_RESOLV_CONF"
      echo "[Net Utils] Symlink created: $ETC_RESOLV_CONF -> $STUB_RESOLV_CONF"
    else
      # Check if symlink points to the correct target
      local current_target
      current_target=$(readlink "$ETC_RESOLV_CONF")
      if [ "$current_target" != "$STUB_RESOLV_CONF" ] && [ "$current_target" != "../run/systemd/resolve/stub-resolv.conf" ] && [ "$current_target" != "stub-resolv.conf" ]; then # Added relative possibility
        echo "[Net Utils] $ETC_RESOLV_CONF points to '$current_target', but expected '$STUB_RESOLV_CONF' (or relative). Re-linking."
        rm -f "$ETC_RESOLV_CONF"
        ln -sf "$STUB_RESOLV_CONF" "$ETC_RESOLV_CONF"
        echo "[Net Utils] Symlink corrected: $ETC_RESOLV_CONF -> $STUB_RESOLV_CONF"
      else
        echo "[Net Utils] $ETC_RESOLV_CONF is correctly symlinked to systemd-resolved stub."
      fi
    fi
  elif [ ! -f "$ETC_RESOLV_CONF" ]; then
    # If stub-resolv.conf doesn't exist AND /etc/resolv.conf doesn't exist, create a basic fallback.
    echo "[Net Utils] $ETC_RESOLV_CONF does not exist and $STUB_RESOLV_CONF not found. Creating a basic $ETC_RESOLV_CONF with public DNS..."
    echo "nameserver 8.8.8.8" > "$ETC_RESOLV_CONF"
    echo "nameserver 1.1.1.1" >> "$ETC_RESOLV_CONF"
    echo "[Net Utils] Fallback $ETC_RESOLV_CONF created."
  else
    echo "[Net Utils] $ETC_RESOLV_CONF exists and $STUB_RESOLV_CONF not found. Using existing $ETC_RESOLV_CONF."
  fi

  echo "[Net Utils] Current $ETC_RESOLV_CONF content:"
  cat "$ETC_RESOLV_CONF" || echo "[Net Utils] WARNING: Failed to cat $ETC_RESOLV_CONF"
}

test_dns_and_connectivity() {
  echo "[Net Utils] Testing DNS resolution and basic connectivity..."
  local targets=("google.com" "registry-1.docker.io" "apt.releases.hashicorp.com" "mirrors.digitalocean.com")
  local all_successful=true

  for target in "${targets[@]}"; do
    echo "[Net Utils] Pinging $target..."
    if ping -c 2 "$target"; then
      echo "[Net Utils] Ping to $target successful."
    else
      echo "[Net Utils] WARNING: Ping to $target failed."
      all_successful=false
    fi
  done

  if $all_successful; then
    echo "[Net Utils] All pings successful."
  else
    echo "[Net Utils] WARNING: One or more ping tests failed. This might indicate network or DNS resolution issues."
  fi
}

perform_network_checks() {
  echo "--- Performing Network Checks (via network_utils.sh) ---"
  ensure_systemd_resolved_active
  ensure_resolv_conf_setup # This should ideally run after systemd-resolved is confirmed active
  test_dns_and_connectivity
  echo "--- Network Checks Done (via network_utils.sh) ---"
} 