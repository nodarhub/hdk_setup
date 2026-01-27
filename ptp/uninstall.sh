#!/bin/bash

# PTP (LinuxPTP) uninstall script
# Usage: ./uninstall.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting PTP cleanup..."

# Variables
PTP_SERVICE_NAME="linuxptp"
PTP_CONFIG_PATH="/etc/linuxptp/linuxptp.conf"
PTP_SERVICE_FILE="/etc/systemd/system/linuxptp.service"

# Stop the systemd service if running
if systemctl list-units --type=service --all | grep -q "$PTP_SERVICE_NAME.service"; then
    log "Stopping systemd service: $PTP_SERVICE_NAME"
    sudo systemctl stop $PTP_SERVICE_NAME 2>/dev/null || log "Service $PTP_SERVICE_NAME is not running."
    sudo systemctl disable $PTP_SERVICE_NAME 2>/dev/null || log "Service $PTP_SERVICE_NAME is not enabled."
else
    log "Service $PTP_SERVICE_NAME does not exist."
fi

# Remove the service file
if [ -f "$PTP_SERVICE_FILE" ]; then
    log "Removing service file: $PTP_SERVICE_FILE"
    sudo rm -f "$PTP_SERVICE_FILE"
else
    log "Service file $PTP_SERVICE_FILE not found."
fi

# Reload systemd
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Remove the configuration file
if [ -f "$PTP_CONFIG_PATH" ]; then
    log "Removing configuration file: $PTP_CONFIG_PATH"
    sudo rm -f "$PTP_CONFIG_PATH"
else
    log "Configuration file $PTP_CONFIG_PATH not found."
fi

log "PTP uninstall completed."