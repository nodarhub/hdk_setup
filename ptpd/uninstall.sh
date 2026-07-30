#!/bin/bash

# PTP (ptpd) uninstall script
# Usage: ./uninstall.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting ptpd cleanup..."

# Variables
PTPD_SERVICE_NAME="ptpd"
PTPD_CONFIG_PATH="/etc/ptpd/ptpd.conf"
PTPD_SERVICE_FILE="/etc/systemd/system/ptpd.service"

# Stop the systemd service if running
if systemctl list-units --type=service --all | grep -q "$PTPD_SERVICE_NAME.service"; then
    log "Stopping systemd service: $PTPD_SERVICE_NAME"
    sudo systemctl stop $PTPD_SERVICE_NAME 2>/dev/null || log "Service $PTPD_SERVICE_NAME is not running."
    sudo systemctl disable $PTPD_SERVICE_NAME 2>/dev/null || log "Service $PTPD_SERVICE_NAME is not enabled."
else
    log "Service $PTPD_SERVICE_NAME does not exist."
fi

# Remove the service file
if [ -f "$PTPD_SERVICE_FILE" ]; then
    log "Removing service file: $PTPD_SERVICE_FILE"
    sudo rm -f "$PTPD_SERVICE_FILE"
else
    log "Service file $PTPD_SERVICE_FILE not found."
fi

# Reload systemd
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Remove the configuration file
if [ -f "$PTPD_CONFIG_PATH" ]; then
    log "Removing configuration file: $PTPD_CONFIG_PATH"
    sudo rm -f "$PTPD_CONFIG_PATH"
else
    log "Configuration file $PTPD_CONFIG_PATH not found."
fi

log "ptpd uninstall completed."
