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
DATA_OUT_INTERFACE=""
# Written by install.sh on Orin Nano; records the adapter roles.
IFACE_STATE_FILE="/etc/hdk/interfaces.conf"

USAGE="Usage: $0 -d <jetson|orin-nano|onlogic> [-cam_if <iface>] [-cam_if1 <iface>] [-cam_if2 <iface>] [-data_if <iface>]"

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
    -data_if)
      DATA_OUT_INTERFACE="$2"
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

# Read one key out of the state file install.sh wrote (empty if absent).
read_interface_state() {
  [ -f "$IFACE_STATE_FILE" ] || return 0
  grep -m1 "^$1=" "$IFACE_STATE_FILE" 2>/dev/null | cut -d= -f2- || true
}

# Resolve the interfaces (must match install.sh). For orin-nano, prefer the roles
# recorded at install time, else autodetect (uninstall never prompts). Flags win.
if [[ "$DEVICE_TYPE" == "jetson" ]]; then
  CAMERA_INTERFACE="${CAMERA_INTERFACE:-eth0}"
elif [[ "$DEVICE_TYPE" == "orin-nano" ]]; then
  if [ -z "$CAMERA_INTERFACE" ]; then
    CAMERA_INTERFACE="$(read_interface_state CAMERA_INTERFACE)"
  fi
  if [ -z "$DATA_OUT_INTERFACE" ]; then
    DATA_OUT_INTERFACE="$(read_interface_state DATA_OUT_INTERFACE)"
  fi
  if [ -z "$CAMERA_INTERFACE" ]; then
    # Never mistake the data-out adapter for the camera one.
    CAMERA_INTERFACE="$(detect_usb_ethernet | grep -vx "$DATA_OUT_INTERFACE" | head -n1 || true)"
  fi
fi

log "=========================================="
log "HDK Uninstall Script"
log "Device type: $DEVICE_TYPE"
log "=========================================="

# Step 1: Hammerhead autostart uninstall
log "[1/9] Uninstalling Hammerhead autostart service..."
"$SCRIPT_DIR/hammerhead/uninstall.sh" || log "Hammerhead uninstall completed with warnings"

# Step 2: Clock uninstall
log "[2/9] Uninstalling clock service..."
"$SCRIPT_DIR/clock/uninstall.sh" || log "Clock uninstall completed with warnings"

# Step 3: PHC2SYS uninstall (safe no-op if never installed)
log "[3/9] Uninstalling phc2sys..."
"$SCRIPT_DIR/phc2sys/uninstall.sh" || log "phc2sys uninstall completed with warnings"

# Step 4: PTP Slave uninstall (safe no-op if never installed)
log "[4/9] Uninstalling PTP slave..."
"$SCRIPT_DIR/ptp_slave/uninstall.sh" || log "PTP slave uninstall completed with warnings"

# Re-enable systemd-timesyncd in case it was disabled by external time sync
log "[4/9] Re-enabling systemd-timesyncd..."
sudo systemctl enable systemd-timesyncd 2>/dev/null || true
sudo systemctl start systemd-timesyncd 2>/dev/null || true

# Step 5: PTP uninstall (Orin Nano uses ptpd; AGX Orin and OnLogic use ptp4l)
log "[5/9] Uninstalling PTP..."
if [ "$DEVICE_TYPE" == "orin-nano" ]; then
  "$SCRIPT_DIR/ptpd/uninstall.sh" || log "ptpd uninstall completed with warnings"
else
  "$SCRIPT_DIR/ptp/uninstall.sh" || log "PTP uninstall completed with warnings"
fi

# Step 6: Network uninstall (OnLogic only)
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[6/9] Uninstalling network..."
  "$SCRIPT_DIR/network/uninstall.sh" || log "Network uninstall completed with warnings"
else
  log "[6/9] Skipping network uninstall (Jetson)"
fi

# Step 7: Data-out interface uninstall (Orin Nano, or any board via -data_if)
if [ -n "$DATA_OUT_INTERFACE" ]; then
  log "[7/9] Uninstalling data-out interface config for $DATA_OUT_INTERFACE..."
  "$SCRIPT_DIR/data_out/uninstall.sh" "$DATA_OUT_INTERFACE" || log "Data-out uninstall completed with warnings"
else
  log "[7/9] Skipping data-out interface uninstall (none configured; pass -data_if <iface> to clean one up)"
fi

# Step 8: Camera interface uninstall (Jetson only): IPv4 link-local, plus MTU on
# AGX Orin (the Orin Nano never sets MTU 9000). OnLogic MTU/addressing is handled
# via netplan in the network uninstall step.
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[8/9] Camera interface cleanup handled in network step (OnLogic - netplan)"
elif [ -z "$CAMERA_INTERFACE" ]; then
  log "[8/9] Skipping camera interface uninstall (no USB Ethernet adapter detected; pass -cam_if <iface> to clean it up)"
else
  log "[8/9] Uninstalling camera interface config for $CAMERA_INTERFACE..."
  if [ "$DEVICE_TYPE" == "jetson" ]; then
    "$SCRIPT_DIR/mtu/uninstall.sh" "$CAMERA_INTERFACE" || log "MTU uninstall completed with warnings"
  fi
  "$SCRIPT_DIR/link_local/uninstall.sh" "$CAMERA_INTERFACE" || log "Link-local uninstall completed with warnings"
fi

# Step 9: Receive-path tuning uninstall (Orin Nano). Restores the pre-install
# rmem_max and RX ring from /etc/hdk/net_tune.conf; a safe no-op if never
# installed. Runs before the /etc/hdk cleanup below, which needs the directory
# empty to remove it.
if [ "$DEVICE_TYPE" != "orin-nano" ]; then
  log "[9/9] Skipping receive-path tuning uninstall (Orin Nano only)"
elif [ -z "$CAMERA_INTERFACE" ]; then
  log "[9/9] Skipping receive-path tuning uninstall (no camera interface resolved; pass -cam_if <iface> to clean it up)"
else
  log "[9/9] Uninstalling receive-path tuning for $CAMERA_INTERFACE..."
  "$SCRIPT_DIR/net_tune/uninstall.sh" "$CAMERA_INTERFACE" || log "Receive-path tuning uninstall completed with warnings"
fi

# Drop the recorded interface roles (no-op if never written).
if [ -f "$IFACE_STATE_FILE" ]; then
  log "Removing $IFACE_STATE_FILE..."
  sudo rm -f "$IFACE_STATE_FILE"
  sudo rmdir "$(dirname "$IFACE_STATE_FILE")" 2>/dev/null || true
fi

log "=========================================="
log "HDK Uninstall completed successfully!"
log "=========================================="
