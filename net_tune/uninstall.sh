#!/bin/bash

# Receive-path tuning cleanup
# Usage: ./uninstall.sh <interface-name>
#
# Clears ethtool.ring-rx from the interface's NetworkManager profile and removes
# the sysctl drop-in, then restores the values recorded at install time
# (/etc/hdk/net_tune.conf). If that record is gone, the persistent config is
# still removed and the kernel and driver defaults return on the next boot.

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
source "$SCRIPT_DIR/../lib/net_detect.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

INTERFACE_NAME="$1"

SYSCTL_CONF="/etc/sysctl.d/99-hdk-net-tune.conf"
STATE_FILE="/etc/hdk/net_tune.conf"

if [ -z "$INTERFACE_NAME" ]; then
    echo "Error: No interface name provided."
    echo "Usage: $0 <interface-name>"
    exit 1
fi

IFACE_KEY="$(printf '%s' "$INTERFACE_NAME" | tr -c 'A-Za-z0-9' '_')"

state_get() {
    [ -f "$STATE_FILE" ] || return 0
    grep -m1 "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true
}

state_drop() {
    [ -f "$STATE_FILE" ] || return 0
    sudo sed -i "/^$1=/d" "$STATE_FILE"
}

log "Starting receive-path tuning cleanup for interface: $INTERFACE_NAME"

# 1. Clear the stored ring size, so NetworkManager stops reapplying it.
if ! command -v nmcli >/dev/null 2>&1; then
    log "nmcli (NetworkManager) not found; no stored RX ring to clear."
else
    CON="$(nm_profile_uuid_for "$INTERFACE_NAME")"
    if [ -z "$CON" ]; then
        log "No NetworkManager profile found for $INTERFACE_NAME; nothing to clear."
    elif [ -z "$(nmcli -g ethtool.ring-rx connection show "$CON" 2>/dev/null || true)" ]; then
        log "No ethtool.ring-rx set on connection '$(nm_profile_name "$CON")'; nothing to clear."
    else
        log "Clearing ethtool.ring-rx from connection '$(nm_profile_name "$CON")'..."
        # An empty value unsets a scalar property; older nmcli wants the -prop form.
        sudo nmcli connection modify "$CON" ethtool.ring-rx "" 2>/dev/null ||
            sudo nmcli connection modify "$CON" -ethtool.ring-rx 2>/dev/null ||
            log "Warning: Failed to clear ethtool.ring-rx on $CON."
    fi
fi

# 2. Put the ring itself back, since clearing the property alone only takes
#    effect on the next activation.
RX_RING_PREV="$(state_get "RX_RING_PREV_$IFACE_KEY")"
if ! ip link show "$INTERFACE_NAME" > /dev/null 2>&1; then
    log "Warning: Network interface '$INTERFACE_NAME' does not exist; skipping the RX ring restore."
elif ! command -v ethtool >/dev/null 2>&1; then
    log "ethtool not found; skipping the RX ring restore."
elif [ -z "$RX_RING_PREV" ]; then
    log "No recorded RX ring size for $INTERFACE_NAME; leaving it as is (the driver default returns on reboot)."
else
    RX_CURRENT="$(sudo ethtool -g "$INTERFACE_NAME" 2>/dev/null | awk '/^RX:/ { n++; if (n == 2) { print $2; exit } }')"
    if [ "$RX_CURRENT" == "$RX_RING_PREV" ]; then
        log "RX ring is already $RX_RING_PREV for $INTERFACE_NAME, no changes made."
    else
        log "Restoring RX ring to $RX_RING_PREV for $INTERFACE_NAME (currently ${RX_CURRENT:-unknown})..."
        sudo ethtool -G "$INTERFACE_NAME" rx "$RX_RING_PREV" || log "Warning: Failed to restore the RX ring for $INTERFACE_NAME."
    fi
fi
state_drop "RX_RING_PREV_$IFACE_KEY"

# 3. Socket receive buffer ceiling (system-wide).
if [ -f "$SYSCTL_CONF" ]; then
    log "Removing $SYSCTL_CONF..."
    sudo rm -f "$SYSCTL_CONF"
else
    log "No sysctl drop-in found at $SYSCTL_CONF."
fi

RMEM_MAX_PREV="$(state_get RMEM_MAX_PREV)"
if [ -n "$RMEM_MAX_PREV" ]; then
    log "Restoring net.core.rmem_max to $RMEM_MAX_PREV..."
    sudo sysctl -q -w "net.core.rmem_max=$RMEM_MAX_PREV" || log "Warning: Failed to restore net.core.rmem_max."
else
    log "No recorded net.core.rmem_max; the kernel default returns on the next boot."
fi
state_drop RMEM_MAX_PREV

# Keep the file only while it still holds another interface's recorded ring size.
if [ -f "$STATE_FILE" ] && [ ! -s "$STATE_FILE" ]; then
    sudo rm -f "$STATE_FILE"
fi

log "Receive-path tuning cleanup completed for $INTERFACE_NAME."
