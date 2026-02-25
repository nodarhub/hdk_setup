#!/bin/bash

# HDK Setup Script - Main orchestrator for target device setup
# Usage examples:
#   Jetson:   ./install.sh -d jetson
#   OnLogic:  ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3
#   With external time sync: ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true
#   With custom sync IP:     ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true -sync-ip 10.0.0.50/24

set -e
set -o pipefail
trap 'echo "Error occurred at $BASH_COMMAND"' ERR

# Get script directory
SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

# Default values
DEVICE_TYPE=""
CAMERA_INTERFACE_1="ethLAN2"
CAMERA_INTERFACE_2="ethLAN3"
INSTALL_AUTOSTART=false
EXTERNAL_TIME_SYNC=false
SYNC_IP="192.168.30.25/24"

# Logging function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      DEVICE_TYPE="$2"
      if [[ "$DEVICE_TYPE" != "jetson" && "$DEVICE_TYPE" != "onlogic" ]]; then
        echo "Error: Invalid device type '$DEVICE_TYPE'. Must be 'jetson' or 'onlogic'."
        exit 1
      fi
      shift 2
      ;;
    -cam_if1)
      CAMERA_INTERFACE_1="$2"
      shift 2
      ;;
    -cam_if2)
      CAMERA_INTERFACE_2="$2"
      shift 2
      ;;
    -autostart)
      if [[ "$2" == "true" || "$2" == "false" ]]; then
        INSTALL_AUTOSTART="$2"
      else
        echo "Error: Invalid value '$2' for -autostart. Must be true or false."
        exit 1
      fi
      shift 2
      ;;
    -external-time-sync)
      if [[ "$2" == "true" || "$2" == "false" ]]; then
        EXTERNAL_TIME_SYNC="$2"
      else
        echo "Error: Invalid value '$2' for -external-time-sync. Must be true or false."
        exit 1
      fi
      shift 2
      ;;
    -sync-ip)
      SYNC_IP="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo "Usage: $0 -d <jetson|onlogic> [-cam_if1 <iface>] [-cam_if2 <iface>] [-autostart <true|false>] [-external-time-sync <true|false>] [-sync-ip <ip/cidr>]"
      exit 1
      ;;
  esac
done

# Validate required flags
if [[ -z "$DEVICE_TYPE" ]]; then
  echo "Error: Device type (-d) is required."
  echo "Usage: $0 -d <jetson|onlogic> [-cam_if1 <iface>] [-cam_if2 <iface>] [-autostart <true|false>] [-external-time-sync <true|false>] [-sync-ip <ip/cidr>]"
  exit 1
fi

log "=========================================="
log "HDK Setup Script"
log "Device type: $DEVICE_TYPE"
if [ "$EXTERNAL_TIME_SYNC" == "true" ]; then
  log "External time sync: enabled (IP: $SYNC_IP)"
fi
log "=========================================="

# Step 1: Disable background services
log "[1/8] Disabling background services..."
"$SCRIPT_DIR/background_services/disable_background_services.sh"

# Step 2: MTU Setup (Jetson only - OnLogic MTU is set via netplan in network setup)
if [ "$DEVICE_TYPE" == "jetson" ]; then
  log "[2/8] Setting up MTU for eth0..."
  "$SCRIPT_DIR/mtu/install.sh" eth0
else
  log "[2/8] Skipping MTU setup (OnLogic - handled via netplan)"
fi

# Step 3: Network Setup (OnLogic only)
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[3/8] Setting up network for $CAMERA_INTERFACE_1 and $CAMERA_INTERFACE_2..."
  "$SCRIPT_DIR/network/install.sh" "$CAMERA_INTERFACE_1" "$CAMERA_INTERFACE_2" -external-time-sync "$EXTERNAL_TIME_SYNC" -sync-ip "$SYNC_IP"
else
  log "[3/8] Skipping network setup (Jetson)"
fi

# Step 4: PTP Slave Setup (OnLogic only, when external time sync is enabled)
if [ "$EXTERNAL_TIME_SYNC" == "true" ] && [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[4/8] Setting up PTP slave for ethLAN4..."
  "$SCRIPT_DIR/ptp_slave/install.sh" -i ethLAN4
else
  log "[4/8] Skipping PTP slave setup (not enabled or not OnLogic)"
fi

# Step 5: PHC2SYS Setup (OnLogic only, when external time sync is enabled)
if [ "$EXTERNAL_TIME_SYNC" == "true" ] && [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[5/8] Setting up phc2sys for ethLAN4..."
  "$SCRIPT_DIR/phc2sys/install.sh" -i ethLAN4
else
  log "[5/8] Skipping phc2sys setup (not enabled or not OnLogic)"
fi

# Step 6: PTP Setup
log "[6/8] Setting up PTP..."
if [ "$DEVICE_TYPE" == "jetson" ]; then
  "$SCRIPT_DIR/ptp/install.sh" -i eth0
elif [ "$DEVICE_TYPE" == "onlogic" ]; then
  "$SCRIPT_DIR/ptp/install.sh" -i "$CAMERA_INTERFACE_1" -i "$CAMERA_INTERFACE_2"
fi

# Step 7: Clock Setup
log "[7/8] Setting up clock service..."
"$SCRIPT_DIR/clock/install.sh"

# Step 8: Hammerhead Autostart (optional)
if [ "$INSTALL_AUTOSTART" == "true" ]; then
  log "[8/8] Setting up Hammerhead autostart service..."
  "$SCRIPT_DIR/hammerhead/install.sh" -external-time-sync "$EXTERNAL_TIME_SYNC"
else
  log "[8/8] Skipping Hammerhead autostart (disabled by default, use -autostart true to enable)"
fi

log "=========================================="
log "HDK Setup completed successfully!"
log "=========================================="
