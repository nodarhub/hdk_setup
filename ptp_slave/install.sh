#!/bin/bash

# PTP Slave installation script
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

log "Starting PTP Slave installation for interface: $INTERFACE"

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
PTP_SLAVE_CONFIG_PATH="$PTP_CONFIG_DIR/linuxptp_slave.conf"
PTP_SLAVE_SERVICE_FILE="/etc/systemd/system/linuxptp-slave.service"

# Create config directory
sudo mkdir -p "$PTP_CONFIG_DIR"

# Generate the linuxptp_slave.conf file
log "Generating PTP slave configuration file at $PTP_SLAVE_CONFIG_PATH..."
sudo tee "$PTP_SLAVE_CONFIG_PATH" > /dev/null << EOF
[global]
# Enable verbose logging for real-time monitoring
verbose 1

# Send logs to the system log
use_syslog 1

# Set maximum log level (6 = LOG_INFO)
logging_level 6

# Operate as a slave clock (0 = disabled, 1 = enabled)
slaveOnly 1

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

# Create systemd service file
log "Creating systemd service file at $PTP_SLAVE_SERVICE_FILE..."
sudo tee "$PTP_SLAVE_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=LinuxPTP Slave (ptp4l) Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'ptp4l -2 -i $INTERFACE -f $PTP_SLAVE_CONFIG_PATH -m -H || ptp4l -2 -i $INTERFACE -f $PTP_SLAVE_CONFIG_PATH -m -S'
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=linuxptp-slave

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
log "Reloading systemd and enabling linuxptp-slave service..."
sudo systemctl daemon-reload
sudo systemctl enable linuxptp-slave
sudo systemctl restart linuxptp-slave

log "PTP Slave installation complete."
log "Check status with: systemctl status linuxptp-slave"