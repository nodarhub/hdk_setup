#!/bin/bash

# HDK Setup Script - Main orchestrator for target device setup
# Usage examples:
#   Jetson AGX Orin: ./install.sh -d jetson
#   Jetson Orin Nano: ./install.sh -d orin-nano
#   OnLogic:  ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3
#   With external time sync: ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true
#   With custom sync IP:     ./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true -sync-ip 10.0.0.50/24
#   Orin Nano with a data-out adapter: ./install.sh -d orin-nano -cam_if enxAAA -data_if enxBBB
#   With the NODAR SDK: ./install.sh -d jetson -sdk true -uuid <uuid> -activation-key ABCDE-ABCDE-ABCDE-ABCDE

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
# Optional second USB adapter on the Orin Nano (data-out uplink). Its addressing
# is fixed in data_out/install.sh.
DATA_OUT_INTERFACE=""
# Data-out adapter from a previous install, if the selection has changed.
PREV_DATA_OUT_INTERFACE=""
# Records which USB adapter got which role, for uninstall.
IFACE_STATE_FILE="/etc/hdk/interfaces.conf"
# NODAR SDK (hammerhead + nodar_viewer). Opt-in, like -autostart.
INSTALL_SDK=false
SDK_UUID=""
SDK_ACTIVATION_KEY=""
# The SDK, its licence and its config all belong to the invoking user, not root.
RUN_USER="${SUDO_USER:-$USER}"

USAGE="Usage: $0 -d <jetson|orin-nano|onlogic> [-cam_if <iface>] [-cam_if1 <iface>] [-cam_if2 <iface>] [-data_if <iface>] [-autostart <true|false>] [-external-time-sync <true|false>] [-sync-ip <ip/cidr>] [-power-mode <n>] [-sdk <true|false>] [-uuid <uuid>] [-activation-key <key>]"

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
    -sdk)
      if [[ "$2" == "true" || "$2" == "false" ]]; then
        INSTALL_SDK="$2"
      else
        echo "Error: Invalid value '$2' for -sdk. Must be true or false."
        exit 1
      fi
      shift 2
      ;;
    -uuid)
      SDK_UUID="$2"
      shift 2
      ;;
    -activation-key)
      SDK_ACTIVATION_KEY="$2"
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

if [[ -n "$DATA_OUT_INTERFACE" && "$DEVICE_TYPE" != "orin-nano" ]]; then
  echo "Error: -data_if is only supported on -d orin-nano (AGX Orin has an onboard uplink; OnLogic uses ethLAN1 via netplan)."
  exit 1
fi

# The SDK credentials do nothing without -sdk true; silently skipping is confusing.
if [[ "$INSTALL_SDK" != "true" ]] && [[ -n "$SDK_UUID" || -n "$SDK_ACTIVATION_KEY" ]]; then
  echo "Warning: -uuid/-activation-key given without -sdk true; the SDK will not be installed."
fi

# The autostart service can't answer hammerhead's activation prompt, so it needs
# the SDK already there. Refuse now rather than aborting at the last step.
if [[ "$INSTALL_AUTOSTART" == "true" && "$INSTALL_SDK" != "true" && ! -x /usr/bin/hammerhead ]]; then
  echo "Error: -autostart true requires Hammerhead. Add: -sdk true -uuid <uuid> -activation-key <key>"
  exit 1
fi

USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"

# Autodetect the Orin Nano's USB-to-Ethernet adapters and confirm with the user.
# The camera adapter is required, data-out is optional. Explicit -cam_if /
# -data_if flags win and skip detection.
resolve_orin_nano_interfaces() {
  local candidates=() remaining=() reply i

  mapfile -t candidates < <(detect_usb_ethernet)

  # An explicitly requested data-out adapter can never also be the camera.
  if [ -n "$DATA_OUT_INTERFACE" ]; then
    local filtered=()
    for i in "${candidates[@]}"; do
      [ "$i" != "$DATA_OUT_INTERFACE" ] && filtered+=("$i")
    done
    candidates=("${filtered[@]}")
  fi

  # List hub-attached adapters (the devkit's Type-A sockets) first, so the
  # camera default lands on a USB-A adapter rather than on name order.
  if [ "${#candidates[@]}" -gt 1 ]; then
    local hubbed=() direct=()
    for i in "${candidates[@]}"; do
      case "$(usb_port_path "$i")" in
        *.*) hubbed+=("$i") ;;
        *)   direct+=("$i") ;;
      esac
    done
    candidates=("${hubbed[@]}" "${direct[@]}")
  fi

  if [ -n "$CAMERA_INTERFACE" ]; then
    : # explicit -cam_if wins
  elif [ "${#candidates[@]}" -eq 0 ]; then
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
      log "    $((i + 1))) ${candidates[$i]}  [$(usb_port_hint "${candidates[$i]}")$(usb_link_note "${candidates[$i]}")]"
    done
    if [ -e /dev/tty ]; then
      read -rp "Select the CAMERA (data-in) interface [1-${#candidates[@]}] or type an interface name (Enter for 1): " reply </dev/tty || true
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

  # Only offered when a spare adapter is left over, so single-adapter installs
  # are never prompted.
  if [ -z "$DATA_OUT_INTERFACE" ]; then
    for i in "${candidates[@]}"; do
      [ "$i" != "$CAMERA_INTERFACE" ] && remaining+=("$i")
    done

    # Root-port adapters (the devkit's Type-C socket) first - the reverse of the
    # camera ordering, so the Enter default is the likely data-out adapter.
    if [ "${#remaining[@]}" -gt 1 ]; then
      local rooted=() hubbed2=()
      for i in "${remaining[@]}"; do
        case "$(usb_port_path "$i")" in
          *.*) hubbed2+=("$i") ;;
          *)   rooted+=("$i") ;;
        esac
      done
      remaining=("${rooted[@]}" "${hubbed2[@]}")
    fi

    if [ "${#remaining[@]}" -gt 0 ]; then
      if [ -e /dev/tty ]; then
        log "Spare USB Ethernet adapter(s) available for data-out:"
        for i in "${!remaining[@]}"; do
          log "    $((i + 1))) ${remaining[$i]}  [$(usb_port_hint "${remaining[$i]}")$(usb_link_note "${remaining[$i]}")]"
        done
        reply=""
        read -rp "Select the DATA-OUT interface [1-${#remaining[@]}], type an interface name, or 'skip' (Enter for 1): " reply </dev/tty || true
        if [[ "${reply,,}" == "s" || "${reply,,}" == "skip" ]]; then
          log "Skipping data-out interface setup."
        elif [ -z "$reply" ]; then
          DATA_OUT_INTERFACE="${remaining[0]}"
        elif [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#remaining[@]}" ]; then
          DATA_OUT_INTERFACE="${remaining[$((reply - 1))]}"
        else
          DATA_OUT_INTERFACE="$reply"
        fi
      else
        log "Spare USB Ethernet adapter(s) detected but no terminal available; skipping data-out setup (pass -data_if <iface> to configure it)."
      fi
    fi
  fi

  if [ -n "$DATA_OUT_INTERFACE" ] && [ "$DATA_OUT_INTERFACE" == "$CAMERA_INTERFACE" ]; then
    echo "Error: The data-out interface cannot be the same as the camera interface ('$CAMERA_INTERFACE')."
    exit 1
  fi
}

# Record the resolved roles for uninstall.sh.
write_interface_state() {
  sudo install -d -m 755 "$(dirname "$IFACE_STATE_FILE")"
  printf 'CAMERA_INTERFACE=%s\nDATA_OUT_INTERFACE=%s\n' \
    "$CAMERA_INTERFACE" "$DATA_OUT_INTERFACE" | sudo tee "$IFACE_STATE_FILE" >/dev/null
}

# Per-board settings: AGX Orin uses eth0 and MAXN (mode 0); Orin Nano uses the
# autodetected USB adapter and MAXN SUPER (mode 2).
if [[ "$DEVICE_TYPE" == "jetson" ]]; then
  CAMERA_INTERFACE="${CAMERA_INTERFACE:-eth0}"
  POWER_MODE="${POWER_MODE:-0}"
elif [[ "$DEVICE_TYPE" == "orin-nano" ]]; then
  # Read before write_interface_state overwrites it.
  if [ -f "$IFACE_STATE_FILE" ]; then
    PREV_DATA_OUT_INTERFACE="$(grep -m1 '^DATA_OUT_INTERFACE=' "$IFACE_STATE_FILE" | cut -d= -f2- || true)"
  fi
  resolve_orin_nano_interfaces
  POWER_MODE="${POWER_MODE:-2}"
  log "Orin Nano camera interface: $CAMERA_INTERFACE"
  if [ -n "$DATA_OUT_INTERFACE" ]; then
    log "Orin Nano data-out interface: $DATA_OUT_INTERFACE"
  fi
  write_interface_state
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

# NODAR SDK (optional), before the numbered steps: step 10 enables a service that
# runs hammerhead with no terminal, so it needs an installed, activated binary.
# `|| SDK_RC=$?` keeps the exact code without tripping errexit or the ERR trap;
# exit 2 means installed but not activated.
if [ "$INSTALL_SDK" == "true" ]; then
  log "[SDK] Installing NODAR SDK..."
  SDK_RC=0
  "$SCRIPT_DIR/sdk/install.sh" -uuid "$SDK_UUID" -activation-key "$SDK_ACTIVATION_KEY" || SDK_RC=$?
  if [ "$SDK_RC" -eq 2 ] && [ "$INSTALL_AUTOSTART" == "true" ]; then
    echo "Error: Hammerhead is not activated; -autostart true would restart-loop on its prompt."
    exit 1
  elif [ "$SDK_RC" -ne 0 ] && [ "$SDK_RC" -ne 2 ]; then
    echo "Error: NODAR SDK installation failed."
    exit 1
  fi
else
  log "[SDK] Skipping NODAR SDK (disabled by default, use -sdk true to enable)"
fi

# Step 1: Disable background services
log "[1/10] Disabling background services..."
"$SCRIPT_DIR/background_services/disable_background_services.sh"

# Step 2: Camera interface setup (Jetson only): IPv4 link-local, plus MTU 9000
# on AGX Orin. The Orin Nano's USB adapter is unreliable at 9000, so it stays
# at the default MTU. OnLogic handles both via netplan in the network step.
if [ "$DEVICE_TYPE" == "jetson" ]; then
  log "[2/10] Configuring camera interface $CAMERA_INTERFACE (MTU 9000 + IPv4 link-local)..."
  "$SCRIPT_DIR/mtu/install.sh" "$CAMERA_INTERFACE"
  "$SCRIPT_DIR/link_local/install.sh" "$CAMERA_INTERFACE"
elif [ "$DEVICE_TYPE" == "orin-nano" ]; then
  log "[2/10] Configuring camera interface $CAMERA_INTERFACE (IPv4 link-local; default MTU)..."
  "$SCRIPT_DIR/link_local/install.sh" "$CAMERA_INTERFACE"
else
  log "[2/10] Camera interface setup deferred to network step (OnLogic - netplan + DHCP)"
fi

# Step 3: Receive-path tuning on the camera interface (Orin Nano only): a 128 MB
# ceiling for SO_RCVBUF (sysctl drop-in) and a 4096-descriptor RX ring (stored as
# ethtool.ring-rx on the adapter's NetworkManager profile, so it must run after
# the link-local step that guarantees the profile exists). Adapters whose driver
# has no ring parameters are skipped with a warning, not an error.
if [ "$DEVICE_TYPE" == "orin-nano" ]; then
  log "[3/10] Tuning the receive path on $CAMERA_INTERFACE (rmem_max 128 MB + RX ring 4096)..."
  "$SCRIPT_DIR/net_tune/install.sh" "$CAMERA_INTERFACE"
else
  log "[3/10] Skipping receive-path tuning (Orin Nano only)"
fi

# Step 4: Data-out interface (Orin Nano only, optional second USB adapter).
# A changed selection reverts the previous adapter first, otherwise it would keep
# the same static address and collide with the new one.
if [ -n "$PREV_DATA_OUT_INTERFACE" ] && [ "$PREV_DATA_OUT_INTERFACE" != "$DATA_OUT_INTERFACE" ]; then
  log "[4/10] Data-out adapter changed; reverting $PREV_DATA_OUT_INTERFACE first..."
  "$SCRIPT_DIR/data_out/uninstall.sh" "$PREV_DATA_OUT_INTERFACE" || log "Reverting $PREV_DATA_OUT_INTERFACE completed with warnings"
fi
if [ "$DEVICE_TYPE" == "orin-nano" ] && [ -n "$DATA_OUT_INTERFACE" ]; then
  log "[4/10] Configuring data-out interface $DATA_OUT_INTERFACE (static 10.10.1.10/24)..."
  "$SCRIPT_DIR/data_out/install.sh" "$DATA_OUT_INTERFACE"
elif [ "$DEVICE_TYPE" == "orin-nano" ]; then
  log "[4/10] Skipping data-out interface setup (no adapter selected)"
else
  log "[4/10] Skipping data-out interface setup (Orin Nano only)"
fi

# Step 5: Network Setup (OnLogic only)
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[5/10] Setting up network for $CAMERA_INTERFACE_1 and $CAMERA_INTERFACE_2..."
  "$SCRIPT_DIR/network/install.sh" "$CAMERA_INTERFACE_1" "$CAMERA_INTERFACE_2" -external-time-sync "$EXTERNAL_TIME_SYNC" -sync-ip "$SYNC_IP"
else
  log "[5/10] Skipping network setup (Jetson)"
fi

# Step 6: PTP Slave Setup (OnLogic only, when external time sync is enabled)
if [ "$EXTERNAL_TIME_SYNC" == "true" ] && [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[6/10] Disabling systemd-timesyncd (NTP) to avoid conflicts with PHC2SYS..."
  sudo systemctl stop systemd-timesyncd 2>/dev/null || true
  sudo systemctl disable systemd-timesyncd 2>/dev/null || true
  log "[6/10] Setting up PTP slave for ethLAN4..."
  "$SCRIPT_DIR/ptp_slave/install.sh" -i ethLAN4
else
  log "[6/10] Skipping PTP slave setup (not enabled or not OnLogic)"
fi

# Step 7: PHC2SYS Setup (OnLogic only, when external time sync is enabled)
if [ "$EXTERNAL_TIME_SYNC" == "true" ] && [ "$DEVICE_TYPE" == "onlogic" ]; then
  log "[7/10] Setting up phc2sys for ethLAN4..."
  "$SCRIPT_DIR/phc2sys/install.sh" -i ethLAN4
else
  log "[7/10] Skipping phc2sys setup (not enabled or not OnLogic)"
fi

# Step 8: PTP Setup. AGX Orin and OnLogic use ptp4l (hardware timestamping);
# the Orin Nano's adapter has no PTP hardware clock, so it uses ptpd (software).
log "[8/10] Setting up PTP..."
if [ "$DEVICE_TYPE" == "onlogic" ]; then
  "$SCRIPT_DIR/ptp/install.sh" -i "$CAMERA_INTERFACE_1" -i "$CAMERA_INTERFACE_2"
elif [ "$DEVICE_TYPE" == "orin-nano" ]; then
  "$SCRIPT_DIR/ptpd/install.sh" -i "$CAMERA_INTERFACE"
else
  "$SCRIPT_DIR/ptp/install.sh" -i "$CAMERA_INTERFACE"
fi

# Step 9: Clock Setup. Orin Nano also pins the fan to max (it runs hotter under
# sustained max clocks); AGX/OnLogic keep dynamic fan control.
log "[9/10] Setting up clock service (nvpmodel mode $POWER_MODE)..."
if [ "$DEVICE_TYPE" == "orin-nano" ]; then
  "$SCRIPT_DIR/clock/install.sh" -power-mode "$POWER_MODE" -fan true
else
  "$SCRIPT_DIR/clock/install.sh" -power-mode "$POWER_MODE"
fi

# Step 10: Hammerhead Autostart (optional)
if [ "$INSTALL_AUTOSTART" == "true" ]; then
  # The service runs hammerhead with no -c, so it needs these in the user's
  # config dir. Warn only - they can still be added before the next reboot.
  MISSING_CONFIG=()
  for f in extrinsics.ini intrinsics.ini master_config.ini; do
    [ -f "$USER_HOME/.config/nodar/config/$f" ] || MISSING_CONFIG+=("$f")
  done
  if [ "${#MISSING_CONFIG[@]}" -gt 0 ]; then
    log "Warning: hammerhead.service needs ~/.config/nodar/config/{${MISSING_CONFIG[*]}} - still missing."
  fi
  log "[10/10] Setting up Hammerhead autostart service..."
  "$SCRIPT_DIR/hammerhead/install.sh" -external-time-sync "$EXTERNAL_TIME_SYNC"
else
  log "[10/10] Skipping Hammerhead autostart (disabled by default, use -autostart true to enable)"
fi

log "=========================================="
log "HDK Setup completed successfully!"
log "=========================================="
