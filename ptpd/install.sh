#!/bin/bash

# PTP (ptpd) installation script
# Usage: ./install.sh -i <interface>
#
# Used on the Orin Nano, whose camera adapter has no PTP hardware clock. ptpd
# uses software timestamping by default and handles a single interface.

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
    echo "Error: An interface is required."
    echo "Usage: $0 -i <interface>"
    exit 1
fi

log "Starting ptpd installation for interface: $INTERFACE"

# Ensure ptpd is installed
if ! command -v ptpd >/dev/null 2>&1; then
    log "ptpd not found. Installing..."
    sudo apt update
    sudo apt install -y ptpd
else
    log "ptpd is already installed."
fi

# Variables
PTPD_CONFIG_DIR="/etc/ptpd"
PTPD_CONFIG_PATH="$PTPD_CONFIG_DIR/ptpd.conf"
PTPD_SERVICE_FILE="/etc/systemd/system/ptpd.service"

# Create config directory
sudo mkdir -p "$PTPD_CONFIG_DIR"

# Generate the ptpd.conf file
log "Generating ptpd configuration file at $PTPD_CONFIG_PATH..."
sudo tee "$PTPD_CONFIG_PATH" > /dev/null << EOF
[global]
# Run ptpd in foreground so systemd (Type=simple) can supervise it directly
foreground=y

# Log to a file
log_file=/var/log/ptpd2.log

# Log level: LOG_ERR, LOG_WARNING, LOG_NOTICE, LOG_INFO, LOG_ALL
log_level=LOG_INFO

[ptpengine]
# Operate as a master clock
preset=masteronly

# Network interface to use for PTP
interface=$INTERFACE

# Use End-to-End delay mechanism (E2E)
delay_mechanism=E2E

# Announce messages sent every 250 ms (2^-2)
log_announce_interval=-2

# Sync messages sent every 125 ms (2^-3)
log_sync_interval=-3

# Minimum delay request interval: 125 ms (2^-3)
log_delayreq_interval=-3
log_delayreq_interval_initial=-3

# Number of missed Announce messages before timeout (40 x 250 ms = 10s)
announce_receipt_timeout=40
EOF

# Create systemd service file
log "Creating systemd service file at $PTPD_SERVICE_FILE..."
sudo tee "$PTPD_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=ptpd (PTP master) Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/ptpd -c $PTPD_CONFIG_PATH -i $INTERFACE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
log "Reloading systemd and enabling ptpd service..."
sudo systemctl daemon-reload
sudo systemctl enable ptpd
sudo systemctl restart ptpd

log "ptpd installation complete."
log "Check status with: systemctl status ptpd"
