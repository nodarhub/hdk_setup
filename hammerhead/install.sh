#!/bin/bash

# Hammerhead service installation script
# Usage: ./install.sh [-external-time-sync <true|false>]

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Parse optional flags
EXTERNAL_TIME_SYNC=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -external-time-sync)
      EXTERNAL_TIME_SYNC="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo "Usage: $0 [-external-time-sync <true|false>]"
      exit 1
      ;;
  esac
done

log "Starting Hammerhead service installation..."

# Variables
HAMMERHEAD_BIN="/usr/bin/hammerhead"
SERVICE_FILE="/etc/systemd/system/hammerhead.service"
JOURNALD_CONF="/etc/systemd/journald.conf"
# Get the actual user (handle sudo case)
RUN_USER="${SUDO_USER:-$USER}"

# Check that hammerhead binary exists
if [ ! -x "$HAMMERHEAD_BIN" ]; then
    echo "Error: Hammerhead executable not found at $HAMMERHEAD_BIN"
    echo "Please install hammerhead before running this script."
    exit 1
fi

# Update journald.conf to allow debug level logging
if grep -q "MaxLevelStore=notice" "$JOURNALD_CONF" 2>/dev/null; then
    log "Updating journald.conf to enable debug level logging..."
    sudo sed -i 's/MaxLevelStore=notice/MaxLevelStore=debug/' "$JOURNALD_CONF"
    sudo sed -i 's/MaxLevelSyslog=notice/MaxLevelSyslog=debug/' "$JOURNALD_CONF"
    sudo systemctl restart systemd-journald
    log "journald configuration updated and restarted."
fi

# Set service dependencies based on external time sync flag
if [ "$EXTERNAL_TIME_SYNC" == "true" ]; then
  AFTER_DEPS="network.target isc-dhcp-server.service phc2sys.service linuxptp-slave.service linuxptp.service"
  WANTS_DEPS="network.target isc-dhcp-server.service phc2sys.service linuxptp-slave.service linuxptp.service"
else
  AFTER_DEPS="network.target isc-dhcp-server.service linuxptp.service"
  WANTS_DEPS="network.target isc-dhcp-server.service linuxptp.service"
fi

# Create systemd service file
log "Creating systemd service file at $SERVICE_FILE..."
sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Hammerhead Service
After=$AFTER_DEPS
Wants=$WANTS_DEPS

[Service]
Type=simple
User=$RUN_USER
ExecStart=/usr/bin/stdbuf -oL -eL $HAMMERHEAD_BIN
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
