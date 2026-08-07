#!/bin/bash

# Static IPv4 configuration for the data-out interface (NetworkManager)
# Usage: ./install.sh <interface-name>
#
# The data-out uplink mirrors OnLogic's ethLAN1 (see
# network/config/netplan/01-ethLAN1.yaml): a fixed static address plus a
# high-metric default route, so it sits below Wi-Fi and onboard Ethernet.

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Fixed data-out addressing (matches OnLogic ethLAN1).
DATA_IP="10.10.1.10/24"
DATA_GW="10.10.1.1"
DATA_METRIC="500"

INTERFACE_NAME="$1"
if [ -z "$INTERFACE_NAME" ]; then
    echo "Error: No interface name provided."
    echo "Usage: $0 <interface-name>"
    exit 1
fi

if ! command -v nmcli >/dev/null 2>&1; then
    echo "Error: nmcli (NetworkManager) not found; cannot configure the data-out interface."
    exit 1
fi

if ! ip link show "$INTERFACE_NAME" > /dev/null 2>&1; then
    log "Error: Network interface '$INTERFACE_NAME' does not exist."
    exit 1
fi

# Warn if another interface is already on the target subnet (ambiguous routing).
SUBNET_PREFIX="$(echo "${DATA_IP%%/*}" | cut -d. -f1-3)."
CONFLICT="$(ip -o -4 addr show 2>/dev/null \
    | awk -v pre="$SUBNET_PREFIX" -v self="$INTERFACE_NAME" \
        '$2 != self && index($4, pre) == 1 { print $2 }')"
if [ -n "$CONFLICT" ]; then
    log "Warning: ${SUBNET_PREFIX}0/24 is already in use on: $(echo "$CONFLICT" | tr '\n' ' ')"
fi

# Reconfigure the profile NetworkManager already bound to the device; this
# module never creates a profile of its own.
CON="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE_NAME" 2>/dev/null || true)"
if [ -z "$CON" ] || [ "$CON" == "--" ]; then
    echo "Error: No NetworkManager profile is bound to '$INTERFACE_NAME'."
    echo "Check 'nmcli device status' - the adapter must be plugged in and managed"
    echo "by NetworkManager so there is a profile to reconfigure."
    exit 1
fi

log "Configuring $INTERFACE_NAME as $DATA_IP via $DATA_GW (metric $DATA_METRIC) on connection '$CON'..."

sudo nmcli connection modify "$CON" \
    ipv4.method manual \
    ipv4.addresses "$DATA_IP" \
    ipv4.gateway "$DATA_GW" \
    ipv4.route-metric "$DATA_METRIC" \
    ipv4.never-default no \
    ipv6.method ignore \
    connection.autoconnect yes

# Re-activate so the change takes effect now
sudo nmcli connection up "$CON"

log "Data-out interface configured: $INTERFACE_NAME -> $DATA_IP (connection: $CON)."
