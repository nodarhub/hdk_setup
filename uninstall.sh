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

# Step 1: Clock uninstall
log "[1/4] Uninstalling clock service..."
"$SCRIPT_DIR/clock/uninstall.sh" || log "Clock uninstall completed with warnings"

# Step 2: PTP uninstall
log "[2/4] Uninstalling PTP..."
"$SCRIPT_DIR/ptp/uninstall.sh" || log "PTP uninstall completed with warnings"

# Step 3: Network uninstall (OnLogic only)
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[3/4] Uninstalling network..."
  "$SCRIPT_DIR/network/uninstall.sh" || log "Network uninstall completed with warnings"
else
  log "[3/4] Skipping network uninstall (Jetson)"
fi

# Step 4: MTU uninstall (Jetson only - OnLogic MTU is handled via netplan in network uninstall)
if [ "$DEVICE_TYPE" == "jetson" ]; then
  log "[4/4] Uninstalling MTU for eth0..."
  "$SCRIPT_DIR/mtu/uninstall.sh" eth0 || log "MTU uninstall completed with warnings"
else
  log "[4/4] Skipping MTU uninstall (OnLogic - handled via netplan)"
fi

log "=========================================="
log "HDK Uninstall completed successfully!"
log "=========================================="