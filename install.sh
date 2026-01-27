#!/bin/bash

# HDK Setup Script - Main orchestrator for target device setup
# Usage examples:
#   Jetson:   ./install.sh -d jetson
#   OnLogic:  ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3

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
    *)
      echo "Error: Unknown option '$1'"
      echo "Usage: $0 -d <jetson|onlogic> [-cam_if1 <iface>] [-cam_if2 <iface>] [-autostart <true|false>]"
      exit 1
      ;;
  esac
done

# Validate required flags
if [[ -z "$DEVICE_TYPE" ]]; then
  echo "Error: Device type (-d) is required."
  echo "Usage: $0 -d <jetson|onlogic> [-cam_if1 <iface>] [-cam_if2 <iface>] [-autostart <true|false>]"
  exit 1
fi

log "=========================================="
log "HDK Setup Script"
log "Device type: $DEVICE_TYPE"
log "=========================================="

# Step 1: MTU Setup (Jetson only - OnLogic MTU is set via netplan in network setup)
if [ "$DEVICE_TYPE" == "jetson" ]; then
  log "[1/7] Setting up MTU for eth0..."
  "$SCRIPT_DIR/mtu/install.sh" eth0
else
  log "[1/7] Skipping MTU setup (OnLogic - handled via netplan)"
fi

# Step 2: Network Setup (OnLogic only)
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[2/7] Setting up network for $CAMERA_INTERFACE_1 and $CAMERA_INTERFACE_2..."
  "$SCRIPT_DIR/network/install.sh" "$CAMERA_INTERFACE_1" "$CAMERA_INTERFACE_2"
else
  log "[2/7] Skipping network setup (Jetson)"
fi

# Step 3: PTP slave Setup (OnLogic only)
log "[3/7] Setting up PTP slave..."
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[3/7] Setting up PTP slave for ethLAN4..."
  "$SCRIPT_DIR/ptp_slave/install.sh" -i ethLAN4
else
  log "[3/7] Skipping PTP slave setup (Jetson)"
fi

# Step 4: phc2sys Setup (OnLogic only)
log "[4/7] Setting up phc2sys..."
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[4/7] Setting up phc2sys for ethLAN4..."
  "$SCRIPT_DIR/phc2sys/install.sh" -i ethLAN4
else
  log "[4/7] Skipping phc2sys setup (Jetson)"
fi

# Step 5: PTP Setup
log "[5/7] Setting up PTP..."
if [ "$DEVICE_TYPE" == "jetson" ]; then
  "$SCRIPT_DIR/ptp/install.sh" -i eth0
elif [ "$DEVICE_TYPE" == "onlogic" ]; then
  "$SCRIPT_DIR/ptp/install.sh" -i "$CAMERA_INTERFACE_1" -i "$CAMERA_INTERFACE_2"
fi

# Step 6: Clock Setup
log "[6/7] Setting up clock service..."
"$SCRIPT_DIR/clock/install.sh"

# Step 7: Hammerhead Autostart (optional)
if [ "$INSTALL_AUTOSTART" == "true" ]; then
  log "[7/7] Setting up Hammerhead autostart service..."
  "$SCRIPT_DIR/hammerhead/install.sh"
else
  log "[7/7] Skipping Hammerhead autostart (disabled by default, use -autostart true to enable)"
fi

log "=========================================="
log "HDK Setup completed successfully!"
log "=========================================="