#!/bin/bash

# PHC2SYS uninstall script
# Usage: ./uninstall.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting PHC2SYS cleanup..."

# Variables
SERVICE_NAME="phc2sys"
SERVICE_FILE="/etc/systemd/system/phc2sys.service"

# Stop the systemd service if running
if systemctl list-units --type=service --all | grep -q "$SERVICE_NAME.service"; then
    log "Stopping systemd service: $SERVICE_NAME"
    sudo systemctl stop $SERVICE_NAME 2>/dev/null || log "Service $SERVICE_NAME is not running."
    sudo systemctl disable $SERVICE_NAME 2>/dev/null || log "Service $SERVICE_NAME is not enabled."
else
    log "Service $SERVICE_NAME does not exist."
fi

# Remove the service file
if [ -f "$SERVICE_FILE" ]; then
    log "Removing service file: $SERVICE_FILE"
    sudo rm -f "$SERVICE_FILE"
else
    log "Service file $SERVICE_FILE not found."
fi

# Reload systemd
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

log "PHC2SYS cleanup completed."