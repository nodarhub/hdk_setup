#!/bin/bash

# PHC2SYS installation script - Syncs system clock from PTP hardware clock
# Usage: ./install.sh -i <interface>
# Example: ./install.sh -i ethLAN4

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Parse arguments
INTERFACE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i)
      INTERFACE="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo "Usage: $0 -i <interface>"
      exit 1
      ;;
  esac
done

if [ -z "$INTERFACE" ]; then
    echo "Error: Interface is required."
    echo "Usage: $0 -i <interface>"
    exit 1
fi

log "Starting PHC2SYS installation for interface: $INTERFACE"

# Ensure linuxptp is installed (provides phc2sys)
if ! command -v phc2sys >/dev/null 2>&1; then
    log "phc2sys not found. Installing linuxptp..."
    sudo apt update
    sudo apt install -y linuxptp
else
    log "phc2sys is already installed."
fi

# Variables
PHC2SYS_SERVICE_FILE="/etc/systemd/system/phc2sys.service"

# Create systemd service file
log "Creating systemd service file at $PHC2SYS_SERVICE_FILE..."
sudo tee "$PHC2SYS_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=PHC2SYS - Sync system clock from PTP hardware clock
After=network.target linuxptp-slave.service
Wants=network.target linuxptp-slave.service

[Service]
Type=simple
ExecStart=/usr/sbin/phc2sys -s $INTERFACE -c CLOCK_REALTIME -O 0 -S 0.1 -R 4 -m
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
log "Reloading systemd and enabling phc2sys service..."
sudo systemctl daemon-reload
sudo systemctl enable phc2sys
sudo systemctl restart phc2sys

log "PHC2SYS installation complete."
log "Check status with: systemctl status phc2sys"