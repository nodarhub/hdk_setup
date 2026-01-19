#!/bin/bash

# PTP (LinuxPTP) installation script
# Usage: ./install.sh -i <interface1> [-i <interface2>]
# Examples:
#   ./install.sh -i eth0
#   ./install.sh -i ethLAN2 -i ethLAN3

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Parse arguments
INTERFACES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i)
      INTERFACES+=("$2")
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo "Usage: $0 -i <interface1> [-i <interface2>]"
      exit 1
      ;;
  esac
done

if [ ${#INTERFACES[@]} -eq 0 ]; then
    echo "Error: At least one interface is required."
    echo "Usage: $0 -i <interface1> [-i <interface2>]"
    exit 1
fi

log "Starting PTP installation for interfaces: ${INTERFACES[*]}"

# Ensure linuxptp is installed
if ! command -v ptp4l >/dev/null 2>&1; then
    log "LinuxPTP not found. Installing..."
    sudo apt update
    sudo apt install -y linuxptp
else
    log "LinuxPTP is already installed."
fi

# Variables
PTP_CONFIG_DIR="/etc/linuxptp"
PTP_CONFIG_PATH="$PTP_CONFIG_DIR/linuxptp.conf"
PTP_SERVICE_FILE="/etc/systemd/system/linuxptp.service"

# Create config directory
sudo mkdir -p "$PTP_CONFIG_DIR"

# Generate the linuxptp.conf file
log "Generating PTP configuration file at $PTP_CONFIG_PATH..."
sudo tee "$PTP_CONFIG_PATH" > /dev/null << EOF
[global]
# Enable verbose logging for real-time monitoring
verbose 1

# Send logs to the system log
use_syslog 1

# Set maximum log level (6 = LOG_INFO)
logging_level 6

# Operate as a master clock (0 = disabled, 1 = enabled)
slaveOnly 0

# Use proportional-integral (PI) servo for clock synchronization
clock_servo pi

# Use End-to-End delay mechanism (E2E)
delay_mechanism E2E

# Announce messages sent every 250 ms (2^-2). Sending fast helps slaves find a master quicker on reboot
logAnnounceInterval -2

# Number of missed Announce messages before timeout. At 250 ms, this is 40 = 10s. This tells Slaves to wait for
# 10s of no timeouts before giving up on the Master
announceReceiptTimeout 40

# Sync messages sent every 125 ms (2^-3)
# The purpose of these is to maintain tight clock synchronization
logSyncInterval -3

# Minimum delay request interval: 125 ms (2^-3)
logMinDelayReqInterval -3

tx_timestamp_timeout 100
EOF

# Build interface arguments for ptp4l
IFACE_ARGS=""
for iface in "${INTERFACES[@]}"; do
    IFACE_ARGS="$IFACE_ARGS -i $iface"
done

# Create systemd service file
log "Creating systemd service file at $PTP_SERVICE_FILE..."
sudo tee "$PTP_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=LinuxPTP (ptp4l) Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'ptp4l -f $PTP_CONFIG_PATH $IFACE_ARGS -m -H || ptp4l -f $PTP_CONFIG_PATH $IFACE_ARGS -m -S'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
log "Reloading systemd and enabling linuxptp service..."
sudo systemctl daemon-reload
sudo systemctl enable linuxptp
sudo systemctl restart linuxptp

log "PTP installation complete."
log "Check status with: systemctl status linuxptp"