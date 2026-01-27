#!/bin/bash

# HDK Uninstall Script - Main orchestrator for target device uninstall
# Usage examples:
#   Jetson:   ./uninstall.sh -d jetson
#   OnLogic:  ./uninstall.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3

set -e
set -o pipefail
trap 'echo "Error occurred at $BASH_COMMAND"' ERR

# Get script directory
SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

# Default values
DEVICE_TYPE=""
CAMERA_INTERFACE_1="ethLAN2"
CAMERA_INTERFACE_2="ethLAN3"

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
    *)
      echo "Error: Unknown option '$1'"
      echo "Usage: $0 -d <jetson|onlogic> [-cam_if1 <iface>] [-cam_if2 <iface>]"
      exit 1
      ;;
  esac
done

# Validate required flags
if [[ -z "$DEVICE_TYPE" ]]; then
  echo "Error: Device type (-d) is required."
  echo "Usage: $0 -d <jetson|onlogic> [-cam_if1 <iface>] [-cam_if2 <iface>]"
  exit 1
fi

log "=========================================="
log "HDK Uninstall Script"
log "Device type: $DEVICE_TYPE"
log "=========================================="

# Step 1: Hammerhead autostart uninstall
log "[1/7] Uninstalling Hammerhead autostart service..."
"$SCRIPT_DIR/hammerhead/uninstall.sh" || log "Hammerhead uninstall completed with warnings"

# Step 2: Clock uninstall
log "[2/7] Uninstalling clock service..."
"$SCRIPT_DIR/clock/uninstall.sh" || log "Clock uninstall completed with warnings"

# Step 3: phc2sys uninstall
log "[3/7] Uninstalling phc2sys..."
"$SCRIPT_DIR/phc2sys/uninstall.sh" || log "phc2sys uninstall completed with warnings"

# Step 4: PTP slave uninstall
log "[4/7] Uninstalling PTP slave..."
"$SCRIPT_DIR/ptp_slave/uninstall.sh" || log "PTP slave uninstall completed with warnings"

# Step 5: PTP uninstall
log "[5/7] Uninstalling PTP..."
"$SCRIPT_DIR/ptp/uninstall.sh" || log "PTP uninstall completed with warnings"

# Step 6: Network uninstall (OnLogic only)
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[6/7] Uninstalling network..."
  "$SCRIPT_DIR/network/uninstall.sh" || log "Network uninstall completed with warnings"
else
  log "[6/7] Skipping network uninstall (Jetson)"
fi

# Step 7: MTU uninstall (Jetson only - OnLogic MTU is handled via netplan in network uninstall)
if [ "$DEVICE_TYPE" == "jetson" ]; then
  log "[7/7] Uninstalling MTU for eth0..."
  "$SCRIPT_DIR/mtu/uninstall.sh" eth0 || log "MTU uninstall completed with warnings"
else
  log "[7/7] Skipping MTU uninstall (OnLogic - handled via netplan)"
fi

log "=========================================="
log "HDK Uninstall completed successfully!"
log "=========================================="