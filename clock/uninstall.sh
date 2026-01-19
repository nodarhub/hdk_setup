#!/bin/bash

# Clock service cleanup script (Jetson clocks)
# Usage: ./cleanup.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting clock service cleanup..."

# Paths for clocks script and service files
CLOCKS_SCRIPT="/usr/local/bin/clocks.sh"
SERVICE_FILE="/etc/systemd/system/clocks.service"
RESTORE_SERVICE_FILE="/etc/systemd/system/clocks-restore.service"

# Function to stop and disable services if they exist
stop_and_disable_services() {
  for service in clocks.service clocks-restore.service; do
    if systemctl list-units --type=service --all | grep -q "$service"; then
      log "Stopping and disabling service: $service"
      sudo systemctl stop "$service" || log "Failed to stop $service, skipping."
      sudo systemctl disable "$service" || log "Failed to disable $service, skipping."
    else
      log "Service $service does not exist, skipping."
    fi
  done
}

# Stop and disable clocks services
stop_and_disable_services

# Remove the service files
log "Removing service files..."
if [ -f "$SERVICE_FILE" ]; then
  sudo rm -f "$SERVICE_FILE"
  log "Removed $SERVICE_FILE"
else
  log "No service file found at $SERVICE_FILE."
fi

if [ -f "$RESTORE_SERVICE_FILE" ]; then
  sudo rm -f "$RESTORE_SERVICE_FILE"
  log "Removed $RESTORE_SERVICE_FILE"
else
  log "No restore service file found at $RESTORE_SERVICE_FILE."
fi

# Remove the clocks script
log "Removing clocks script..."
if [ -f "$CLOCKS_SCRIPT" ]; then
  sudo rm -f "$CLOCKS_SCRIPT"
  log "Removed $CLOCKS_SCRIPT"
else
  log "No clocks script found at $CLOCKS_SCRIPT."
fi

# Reload systemd to apply changes
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

log "Clock service cleanup completed."