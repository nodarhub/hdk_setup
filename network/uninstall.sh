#!/bin/bash

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting network cleanup..."

# Ensure netplan is installed
if ! command -v netplan >/dev/null 2>&1; then
  log "Netplan not found. Installing..."
  sudo apt update
  sudo apt install -y netplan.io
else
  log "Netplan is already installed."
fi

# Restore isc-dhcp-server config
if [ -f /etc/default/isc-dhcp-server.bak ]; then
    log "Restoring /etc/default/isc-dhcp-server from backup..."
    sudo cp /etc/default/isc-dhcp-server.bak /etc/default/isc-dhcp-server
else
    log "Backup not found: /etc/default/isc-dhcp-server.bak (skipping restore)"
fi

# Remove systemd override for isc-dhcp-server
OVERRIDE_PATH="/etc/systemd/system/isc-dhcp-server.service.d/override.conf"
if [ -f "$OVERRIDE_PATH" ]; then
    log "Removing systemd override: $OVERRIDE_PATH"
    sudo rm "$OVERRIDE_PATH"
else
    log "Systemd override not found (skipping)"
fi

log "Reloading systemd daemon..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# Delete custom netplan files (with checks)
log "Checking for custom netplan files to delete..."
for file in \
    /etc/netplan/01-ethLAN0.yaml \
    /etc/netplan/01-ethLAN1.yaml \
    /etc/netplan/01-ethLAN1.yaml.bak \
    /etc/netplan/01-l4tbr0.yaml \
    /etc/netplan/10-camera.yaml
do
    if [ -f "$file" ]; then
        log "Deleting $file"
        sudo rm "$file"
    else
        log "Skipping $file (not found)"
    fi
done

# Remove wait_for_interfaces from /usr/local/bin
WAIT_SCRIPT="/usr/local/bin/wait_for_interfaces"
if [ -f "$WAIT_SCRIPT" ]; then
    log "Removing $WAIT_SCRIPT"
    sudo rm "$WAIT_SCRIPT"
else
    log "wait_for_interfaces not found in /usr/local/bin (skipping)"
fi

# Disable and stop isc-dhcp-server
log "Stopping and disabling isc-dhcp-server..."
sudo systemctl stop isc-dhcp-server || true
sudo systemctl disable isc-dhcp-server || true

# Apply remaining netplan config (if any)
log "Applying remaining netplan config..."
sudo netplan apply

log "Network cleanup complete."