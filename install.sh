#!/bin/bash

# HDK Setup Script - Main orchestrator for target device setup
# Usage examples:
#   Jetson AGX Orin: ./install.sh -d jetson
#   Jetson Orin Nano: ./install.sh -d orin-nano
#   OnLogic:  ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3
#   With external time sync: ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true
#   With custom sync IP:     ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true -sync-ip 10.0.0.50/24

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
INSTALL_AUTOSTART=false
EXTERNAL_TIME_SYNC=false
SYNC_IP="192.168.30.25/24"
# Jetson-only settings, resolved per board after flag parsing.
CAMERA_INTERFACE=""
POWER_MODE=""

USAGE="Usage: $0 -d <jetson|orin-nano|onlogic> [-cam_if <iface>] [-cam_if1 <iface>] [-cam_if2 <iface>] [-autostart <true|false>] [-external-time-sync <true|false>] [-sync-ip <ip/cidr>] [-power-mode <n>]"

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
    -power-mode)
      POWER_MODE="$2"
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

# Autodetect the Orin Nano's USB-to-Ethernet camera adapter and confirm with the
# user. An explicit -cam_if wins and skips detection.
resolve_orin_nano_interface() {
  [ -n "$CAMERA_INTERFACE" ] && return 0

  local candidates=() reply i
  mapfile -t candidates < <(detect_usb_ethernet)

  if [ "${#candidates[@]}" -eq 0 ]; then
    log "No USB Ethernet adapter detected. Available interfaces:"
    ip -o link show | awk -F': ' '{print "    " $2}'
    if [ -e /dev/tty ]; then
      read -rp "Enter the camera interface name: " reply </dev/tty || true
      CAMERA_INTERFACE="$reply"
    fi
  elif [ "${#candidates[@]}" -eq 1 ]; then
    CAMERA_INTERFACE="${candidates[0]}"
    if [ -e /dev/tty ]; then
      read -rp "Detected USB Ethernet adapter '${candidates[0]}'. Press Enter to use it, or type another interface name: " reply </dev/tty || true
      [ -n "$reply" ] && CAMERA_INTERFACE="$reply"
    fi
  else
    log "Multiple USB Ethernet adapters detected:"
    for i in "${!candidates[@]}"; do
      log "    $((i + 1))) ${candidates[$i]}"
    done
    if [ -e /dev/tty ]; then
      read -rp "Select [1-${#candidates[@]}] or type an interface name (Enter for 1): " reply </dev/tty || true
    fi
    if [ -z "$reply" ]; then
      CAMERA_INTERFACE="${candidates[0]}"
    elif [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#candidates[@]}" ]; then
      CAMERA_INTERFACE="${candidates[$((reply - 1))]}"
    else
      CAMERA_INTERFACE="$reply"
    fi
  fi

  if [ -z "$CAMERA_INTERFACE" ]; then
    echo "Error: No camera interface selected. Pass one explicitly with -cam_if <iface>."
    exit 1
  fi
}

# Per-board settings: AGX Orin uses eth0 and MAXN (mode 0); Orin Nano uses the
# autodetected USB adapter and MAXN SUPER (mode 2).
if [[ "$DEVICE_TYPE" == "jetson" ]]; then
  CAMERA_INTERFACE="${CAMERA_INTERFACE:-eth0}"
  POWER_MODE="${POWER_MODE:-0}"
elif [[ "$DEVICE_TYPE" == "orin-nano" ]]; then
  resolve_orin_nano_interface
  POWER_MODE="${POWER_MODE:-2}"
  log "Orin Nano camera interface: $CAMERA_INTERFACE"
else
  POWER_MODE="${POWER_MODE:-0}"
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

# Step 2: Camera interface setup (Jetson only): IPv4 link-local, plus MTU 9000
# on AGX Orin. The Orin Nano's USB adapter is unreliable at 9000, so it stays
# at the default MTU. OnLogic handles both via netplan in the network step.
if [ "$DEVICE_TYPE" == "jetson" ]; then
  log "[2/8] Configuring camera interface $CAMERA_INTERFACE (MTU 9000 + IPv4 link-local)..."
  "$SCRIPT_DIR/mtu/install.sh" "$CAMERA_INTERFACE"
  "$SCRIPT_DIR/link_local/install.sh" "$CAMERA_INTERFACE"
elif [ "$DEVICE_TYPE" == "orin-nano" ]; then
  log "[2/8] Configuring camera interface $CAMERA_INTERFACE (IPv4 link-local; default MTU)..."
  "$SCRIPT_DIR/link_local/install.sh" "$CAMERA_INTERFACE"
else
  log "[2/8] Camera interface setup deferred to network step (OnLogic - netplan + DHCP)"
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
  log "[4/8] Disabling systemd-timesyncd (NTP) to avoid conflicts with PHC2SYS..."
  sudo systemctl stop systemd-timesyncd 2>/dev/null || true
  sudo systemctl disable systemd-timesyncd 2>/dev/null || true
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

# Step 6: PTP Setup. AGX Orin and OnLogic use ptp4l (hardware timestamping);
# the Orin Nano's adapter has no PTP hardware clock, so it uses ptpd (software).
log "[6/8] Setting up PTP..."
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  "$SCRIPT_DIR/ptp/install.sh" -i "$CAMERA_INTERFACE_1" -i "$CAMERA_INTERFACE_2"
elif [ "$DEVICE_TYPE" == "orin-nano" ]; then
  "$SCRIPT_DIR/ptpd/install.sh" -i "$CAMERA_INTERFACE"
else
  "$SCRIPT_DIR/ptp/install.sh" -i "$CAMERA_INTERFACE"
fi

# Step 7: Clock Setup. Orin Nano also pins the fan to max (it runs hotter under
# sustained max clocks); AGX/OnLogic keep dynamic fan control.
log "[7/8] Setting up clock service (nvpmodel mode $POWER_MODE)..."
if [ "$DEVICE_TYPE" == "orin-nano" ]; then
  "$SCRIPT_DIR/clock/install.sh" -power-mode "$POWER_MODE" -fan true
else
  "$SCRIPT_DIR/clock/install.sh" -power-mode "$POWER_MODE"
fi

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
