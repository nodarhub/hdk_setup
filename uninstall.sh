#!/bin/bash

# HDK Uninstall Script - Main orchestrator for target device uninstall
# Usage examples:
#   Jetson AGX Orin:  ./uninstall.sh -d jetson
#   Jetson Orin Nano: ./uninstall.sh -d orin-nano
#   OnLogic:  ./uninstall.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3

set -e
set -o pipefail
trap 'echo "Error occurred at $BASH_COMMAND"' ERR

# Get script directory
SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

# Shared helpers (interface detection)
source "$SCRIPT_DIR/lib/net_detect.sh"

# Default values
DEVICE_TYPE=""
CAMERA_INTERFACE_1="ethLAN2"
CAMERA_INTERFACE_2="ethLAN3"
CAMERA_INTERFACE=""

USAGE="Usage: $0 -d <jetson|orin-nano|onlogic> [-cam_if <iface>] [-cam_if1 <iface>] [-cam_if2 <iface>]"

# Logging function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      DEVICE_TYPE="$2"
      if [[ "$DEVICE_TYPE" != "jetson" && "$DEVICE_TYPE" != "orin-nano" && "$DEVICE_TYPE" != "onlogic" ]]; then
        echo "Error: Invalid device type '$DEVICE_TYPE'. Must be 'jetson', 'orin-nano' or 'onlogic'."
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
    -cam_if)
      CAMERA_INTERFACE="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo "$USAGE"
      exit 1
      ;;
  esac
done

# Validate required flags
if [[ -z "$DEVICE_TYPE" ]]; then
  echo "Error: Device type (-d) is required."
  echo "$USAGE"
  exit 1
fi

# Resolve the interface (must match install.sh). For orin-nano, best-effort
# autodetect the USB adapter unless given explicitly (uninstall never prompts).
if [[ "$DEVICE_TYPE" == "jetson" ]]; then
  CAMERA_INTERFACE="${CAMERA_INTERFACE:-eth0}"
elif [[ "$DEVICE_TYPE" == "orin-nano" && -z "$CAMERA_INTERFACE" ]]; then
  CAMERA_INTERFACE="$(detect_usb_ethernet | head -n1)"
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

# Step 3: PHC2SYS uninstall (safe no-op if never installed)
log "[3/7] Uninstalling phc2sys..."
"$SCRIPT_DIR/phc2sys/uninstall.sh" || log "phc2sys uninstall completed with warnings"

# Step 4: PTP Slave uninstall (safe no-op if never installed)
log "[4/7] Uninstalling PTP slave..."
"$SCRIPT_DIR/ptp_slave/uninstall.sh" || log "PTP slave uninstall completed with warnings"

# Re-enable systemd-timesyncd in case it was disabled by external time sync
log "[4/7] Re-enabling systemd-timesyncd..."
sudo systemctl enable systemd-timesyncd 2>/dev/null || true
sudo systemctl start systemd-timesyncd 2>/dev/null || true

# Step 5: PTP uninstall (Orin Nano uses ptpd; AGX Orin and OnLogic use ptp4l)
log "[5/7] Uninstalling PTP..."
if [ "$DEVICE_TYPE" == "orin-nano" ]; then
  "$SCRIPT_DIR/ptpd/uninstall.sh" || log "ptpd uninstall completed with warnings"
else
  "$SCRIPT_DIR/ptp/uninstall.sh" || log "PTP uninstall completed with warnings"
fi

# Step 6: Network uninstall (OnLogic only)
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[6/7] Uninstalling network..."
  "$SCRIPT_DIR/network/uninstall.sh" || log "Network uninstall completed with warnings"
else
  log "[6/7] Skipping network uninstall (Jetson)"
fi

# Step 7: Camera interface uninstall (Jetson only): IPv4 link-local, plus MTU on
# AGX Orin (the Orin Nano never sets MTU 9000). OnLogic MTU/addressing is handled
# via netplan in the network uninstall step.
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[7/7] Camera interface cleanup handled in network step (OnLogic - netplan)"
elif [ -z "$CAMERA_INTERFACE" ]; then
  log "[7/7] Skipping camera interface uninstall (no USB Ethernet adapter detected; pass -cam_if <iface> to clean it up)"
else
  log "[7/7] Uninstalling camera interface config for $CAMERA_INTERFACE..."
  if [ "$DEVICE_TYPE" == "jetson" ]; then
    "$SCRIPT_DIR/mtu/uninstall.sh" "$CAMERA_INTERFACE" || log "MTU uninstall completed with warnings"
  fi
  "$SCRIPT_DIR/link_local/uninstall.sh" "$CAMERA_INTERFACE" || log "Link-local uninstall completed with warnings"
fi

log "=========================================="
log "HDK Uninstall completed successfully!"
log "=========================================="
