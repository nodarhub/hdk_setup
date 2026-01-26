#!/bin/bash

# Hammerhead service installation script
# Usage: ./install.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting Hammerhead service installation..."

# Variables
HAMMERHEAD_BIN="/usr/bin/hammerhead"
SERVICE_FILE="/etc/systemd/system/hammerhead.service"
# Get the actual user (handle sudo case)
RUN_USER="${SUDO_USER:-$USER}"

# Check that hammerhead binary exists
if [ ! -x "$HAMMERHEAD_BIN" ]; then
    echo "Error: Hammerhead executable not found at $HAMMERHEAD_BIN"
    echo "Please install hammerhead before running this script."
    exit 1
fi

# Create systemd service file
log "Creating systemd service file at $SERVICE_FILE..."
sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Hammerhead Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=$RUN_USER
ExecStart=$HAMMERHEAD_BIN
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
log "Reloading systemd and enabling hammerhead service..."
sudo systemctl daemon-reload
sudo systemctl enable hammerhead
sudo systemctl restart hammerhead

log "Hammerhead service installation complete."
log "Check status with: systemctl status hammerhead"