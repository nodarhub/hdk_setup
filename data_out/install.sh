#!/bin/bash

# Static IPv4 configuration for the data-out interface (NetworkManager)
# Usage: ./install.sh <interface-name>
#
# Point-to-point link to the receiving computer: an address and nothing else, so
# this interface can never take over the box's default route. Address matches
# OnLogic's ethLAN1 (network/config/netplan/01-ethLAN1.yaml).

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
source "$SCRIPT_DIR/../lib/net_detect.sh"

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

# Reconfigure the interface's NetworkManager profile; this module never creates
# one of its own. The profile is found even with the cable out, so the data-out
# link does not have to be connected to run this.
CON="$(nm_profile_uuid_for "$INTERFACE_NAME")"
if [ -z "$CON" ]; then
    echo "Error: NetworkManager has no profile for '$INTERFACE_NAME'."
    echo "Connect its cable once so NetworkManager creates one (it persists afterwards),"
    echo "or check 'nmcli device status' in case the device is unmanaged."
    exit 1
fi

log "Configuring $INTERFACE_NAME as $DATA_IP (no default route) on connection '$(nm_profile_name "$CON")'..."

sudo nmcli connection modify "$CON" \
    ipv4.method manual \
    ipv4.addresses "$DATA_IP" \
    ipv4.gateway "" \
    ipv4.route-metric -1 \
    ipv4.never-default yes \
    ipv6.method ignore \
    connection.autoconnect yes

# Activating needs carrier; without it the profile applies when the cable goes in.
if [ "$(cat "/sys/class/net/$INTERFACE_NAME/carrier" 2>/dev/null || echo 0)" = "1" ]; then
    sudo nmcli connection up "$CON"
else
    log "No cable on $INTERFACE_NAME; settings will apply when it is connected."
fi

log "Data-out interface configured: $INTERFACE_NAME -> $DATA_IP (connection: $(nm_profile_name "$CON"))."
