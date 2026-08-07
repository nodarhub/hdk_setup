#!/bin/bash

# Static IPv4 configuration for the data-out interface (NetworkManager)
# Usage: ./install.sh <interface-name>
#
# Point-to-point link to the receiving computer: an address and nothing else, so
# this interface can never take over the box's default route. Address matches
# OnLogic's ethLAN1 (network/config/netplan/01-ethLAN1.yaml).

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Fixed data-out address (matches OnLogic ethLAN1).
DATA_IP="10.10.1.10/24"

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
# module never creates a profile of its own. NM only binds one once the device
# has carrier, so a missing profile usually means the cable is not connected.
CON="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE_NAME" 2>/dev/null || true)"
CARRIER="$(cat "/sys/class/net/$INTERFACE_NAME/carrier" 2>/dev/null || echo 0)"
if [ -z "$CON" ] || [ "$CON" == "--" ]; then
    if [ "$CARRIER" != "1" ]; then
        echo "Error: '$INTERFACE_NAME' has no link, so NetworkManager has no profile for it."
        echo "Connect the data-out cable to the receiving computer, wait for the link"
        echo "to come up, then re-run."
    else
        echo "Error: No NetworkManager profile is bound to '$INTERFACE_NAME'."
        echo "The link is up, so the device is likely unmanaged - check 'nmcli device status';"
        echo "if it says 'unmanaged', run 'sudo nmcli device set $INTERFACE_NAME managed yes'."
    fi
    exit 1
fi

# Carrier can still be down here if NetworkManager is set to ignore-carrier.
if [ "$CARRIER" != "1" ]; then
    log "Warning: $INTERFACE_NAME has no carrier; check the data-out cable."
fi

log "Configuring $INTERFACE_NAME as $DATA_IP (no default route) on connection '$CON'..."

sudo nmcli connection modify "$CON" \
    ipv4.method manual \
    ipv4.addresses "$DATA_IP" \
    ipv4.gateway "" \
    ipv4.route-metric -1 \
    ipv4.never-default yes \
    ipv6.method ignore \
    connection.autoconnect yes

# Re-activate so the change takes effect now
sudo nmcli connection up "$CON"

log "Data-out interface configured: $INTERFACE_NAME -> $DATA_IP (connection: $CON)."
