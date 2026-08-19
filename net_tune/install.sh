#!/bin/bash

# Receive-path tuning for the camera interface
# Usage: ./install.sh <interface-name> [rx-ring-size] [rmem-max-bytes]
#
# Two independent knobs, both persistent across reboots:
#
#   1. net.core.rmem_max - the ceiling a process may ask for with SO_RCVBUF,
#      raised to 128 MB through a /etc/sysctl.d drop-in. It is only a ceiling:
#      the receiving application still has to request the larger buffer, so
#      raising it changes nothing on its own.
#
#   2. The NIC's RX ring - descriptors the driver keeps queued for incoming
#      frames, raised to 4096. `ethtool -G` alone is forgotten on reboot or
#      replug, so the value is stored as `ethtool.ring-rx` on the interface's
#      NetworkManager profile - the same place link_local and data_out keep
#      their settings. NetworkManager reapplies it on every activation, so no
#      dispatcher script, service or udev rule of ours is involved.
#
# Many USB-to-Ethernet adapters implement no ring parameters at all. That is
# not an error here: the sysctl still applies and the RX ring is left alone
# with a warning.

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
source "$SCRIPT_DIR/../lib/net_detect.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

INTERFACE_NAME="$1"
DESIRED_RX_RING="${2:-4096}"
DESIRED_RMEM_MAX="${3:-134217728}"

SYSCTL_CONF="/etc/sysctl.d/99-hdk-net-tune.conf"
# Pre-install values, so uninstall.sh can put them back.
STATE_FILE="/etc/hdk/net_tune.conf"
# ethtool.* connection properties landed in NetworkManager 1.32.
NM_MIN_MAJOR=1
NM_MIN_MINOR=32

if [ -z "$INTERFACE_NAME" ]; then
    echo "Error: No interface name provided."
    echo "Usage: $0 <interface-name> [rx-ring-size] [rmem-max-bytes]"
    exit 1
fi

if ! [[ "$DESIRED_RX_RING" =~ ^[0-9]+$ ]] || ! [[ "$DESIRED_RMEM_MAX" =~ ^[0-9]+$ ]]; then
    echo "Error: rx-ring-size and rmem-max-bytes must be numeric."
    echo "Usage: $0 <interface-name> [rx-ring-size] [rmem-max-bytes]"
    exit 1
fi

if ! ip link show "$INTERFACE_NAME" > /dev/null 2>&1; then
    log "Error: Network interface '$INTERFACE_NAME' does not exist."
    exit 1
fi

# Interface names may contain characters that are invalid in a shell variable
# name (e.g. 'eth-cam'), so the state keys use a sanitized form.
IFACE_KEY="$(printf '%s' "$INTERFACE_NAME" | tr -c 'A-Za-z0-9' '_')"

state_get() {
    [ -f "$STATE_FILE" ] || return 0
    grep -m1 "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true
}

# Records a pre-install value once; a re-run must not overwrite it with our own.
state_set_once() {
    if [ -n "$(state_get "$1")" ]; then
        return 0
    fi
    sudo install -d -m 755 "$(dirname "$STATE_FILE")"
    printf '%s=%s\n' "$1" "$2" | sudo tee -a "$STATE_FILE" >/dev/null
}

# Reads the live RX ring: `ethtool -g` prints the driver maximum first and the
# current setting second, one 'RX:' line each.
current_rx_ring() {
    sudo ethtool -g "$1" 2>/dev/null | awk '/^RX:/ { n++; if (n == 2) { print $2; exit } }'
}

log "Starting receive-path tuning for interface: $INTERFACE_NAME"

# ---------------------------------------------------------------------------
# 1. Socket receive buffer ceiling (system-wide)
# ---------------------------------------------------------------------------

CURRENT_RMEM_MAX="$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")"
state_set_once RMEM_MAX_PREV "$CURRENT_RMEM_MAX"

log "Setting net.core.rmem_max=$DESIRED_RMEM_MAX (currently ${CURRENT_RMEM_MAX:-unknown}) via $SYSCTL_CONF..."
sudo bash -c "cat > $SYSCTL_CONF" <<EOL
# Installed by hdk_setup (net_tune). Ceiling for SO_RCVBUF, raised so the
# receiving application can request a buffer large enough for burst traffic.
net.core.rmem_max = $DESIRED_RMEM_MAX
EOL
sudo chmod 644 "$SYSCTL_CONF"

# -p applies just this file; --system would replay every sysctl on the box.
sudo sysctl -q -p "$SYSCTL_CONF"

APPLIED_RMEM_MAX="$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")"
if [ "$APPLIED_RMEM_MAX" == "$DESIRED_RMEM_MAX" ]; then
    log "net.core.rmem_max is now $APPLIED_RMEM_MAX."
else
    log "Warning: net.core.rmem_max is $APPLIED_RMEM_MAX, expected $DESIRED_RMEM_MAX."
fi

# systemd-sysctl applies /etc/sysctl.d/*.conf in filename order and
# /etc/sysctl.conf last, so a setting in either place can win at the next boot.
CONFLICTS=""
for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf; do
    [ -f "$f" ] || continue
    [ "$f" == "$SYSCTL_CONF" ] && continue
    if grep -qE '^[[:space:]]*net\.core\.rmem_max' "$f" 2>/dev/null; then
        CONFLICTS="$CONFLICTS $f"
    fi
done
if [ -n "$CONFLICTS" ]; then
    log "Warning: net.core.rmem_max is also set in:$CONFLICTS - remove it there or the value may be overridden on the next boot."
fi

# ---------------------------------------------------------------------------
# 2. NIC receive ring
# ---------------------------------------------------------------------------

# nmcli stores the setting, but only the driver knows its ring limits, so
# ethtool is still needed to read them.
if ! command -v ethtool >/dev/null 2>&1; then
    log "ethtool not found. Installing ethtool..."
    sudo apt install -y ethtool || {
        sudo apt-get update
        sudo apt-get install -y ethtool
    }
fi

RING_INFO="$(sudo ethtool -g "$INTERFACE_NAME" 2>/dev/null || true)"
RX_MAX="$(awk '/^RX:/ { print $2; exit }' <<<"$RING_INFO")"
RX_CURRENT="$(awk '/^RX:/ { n++; if (n == 2) { print $2; exit } }' <<<"$RING_INFO")"

if ! [[ "$RX_MAX" =~ ^[0-9]+$ ]] || ! [[ "$RX_CURRENT" =~ ^[0-9]+$ ]]; then
    log "Warning: '$INTERFACE_NAME' reports no RX ring parameters (usual for USB-to-Ethernet adapters); leaving the ring untouched."
    log "         The net.core.rmem_max change above is unaffected."
    log "Receive-path tuning complete for $INTERFACE_NAME (sysctl only)."
    exit 0
fi

state_set_once "RX_RING_PREV_$IFACE_KEY" "$RX_CURRENT"

if [ "$DESIRED_RX_RING" -gt "$RX_MAX" ]; then
    log "Warning: requested RX ring $DESIRED_RX_RING exceeds the driver maximum $RX_MAX; using $RX_MAX."
    DESIRED_RX_RING="$RX_MAX"
fi

log "RX ring for $INTERFACE_NAME: $RX_CURRENT descriptors (driver maximum $RX_MAX), target $DESIRED_RX_RING."

# Applies the ring directly, for the cases where NetworkManager cannot hold the
# setting. Effective immediately but forgotten on reboot or replug.
apply_ring_live() {
    if [ "$RX_CURRENT" == "$DESIRED_RX_RING" ]; then
        log "RX ring is already $DESIRED_RX_RING for $INTERFACE_NAME, no changes made."
    elif sudo ethtool -G "$INTERFACE_NAME" rx "$DESIRED_RX_RING"; then
        log "RX ring set to $DESIRED_RX_RING for $INTERFACE_NAME (until the next reboot or replug)."
    else
        log "Warning: '$INTERFACE_NAME' does not accept a ring resize; leaving it at $RX_CURRENT."
    fi
}

if ! command -v nmcli >/dev/null 2>&1; then
    log "Warning: nmcli (NetworkManager) not found; the RX ring cannot be made persistent."
    apply_ring_live
    exit 0
fi

# NetworkManager keeps the setting on the profile - but only from 1.32 onwards.
NM_VERSION="$(nmcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
NM_MAJOR="${NM_VERSION%%.*}"
NM_MINOR="$(cut -d. -f2 <<<"$NM_VERSION")"

if [ -z "$NM_VERSION" ] || [ "$NM_MAJOR" -lt "$NM_MIN_MAJOR" ] ||
   { [ "$NM_MAJOR" -eq "$NM_MIN_MAJOR" ] && [ "$NM_MINOR" -lt "$NM_MIN_MINOR" ]; }; then
    log "Warning: NetworkManager ${NM_VERSION:-unknown} has no ethtool.ring-rx property (needs $NM_MIN_MAJOR.$NM_MIN_MINOR+); the RX ring cannot be made persistent."
    apply_ring_live
    exit 0
fi

# Reconfigure the interface's existing profile; this module never creates one of
# its own. On the Orin Nano the link_local step runs first and guarantees one.
# The profile is found by interface name, so the cable need not be connected.
CON="$(nm_profile_uuid_for "$INTERFACE_NAME")"
if [ -z "$CON" ]; then
    log "Warning: NetworkManager has no profile for '$INTERFACE_NAME'; the RX ring cannot be made persistent."
    log "         Connect its cable once so NetworkManager creates one, then re-run this step."
    apply_ring_live
    exit 0
fi

log "Setting ethtool.ring-rx=$DESIRED_RX_RING on connection '$(nm_profile_name "$CON")'..."
if ! sudo nmcli connection modify "$CON" ethtool.ring-rx "$DESIRED_RX_RING"; then
    log "Warning: NetworkManager rejected ethtool.ring-rx; falling back to a non-persistent ethtool setting."
    apply_ring_live
    exit 0
fi

# NetworkManager applies ethtool settings when it activates the profile.
if [ "$(cat "/sys/class/net/$INTERFACE_NAME/carrier" 2>/dev/null || echo 0)" = "1" ]; then
    # Reactivating also resets the ring, which briefly bounces the link.
    sudo nmcli connection up "$CON" >/dev/null
else
    log "No cable on $INTERFACE_NAME; the RX ring will be applied when it is connected."
fi

RX_APPLIED="$(current_rx_ring "$INTERFACE_NAME")"
log "Receive-path tuning complete for $INTERFACE_NAME (rmem_max=$APPLIED_RMEM_MAX, RX ring=${RX_APPLIED:-pending}, stored on connection '$(nm_profile_name "$CON")')."
log "Note: NetworkManager reapplies the RX ring on every activation - check it with: nmcli -f ethtool connection show '$(nm_profile_name "$CON")'"
