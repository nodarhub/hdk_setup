#!/bin/bash

# Link-local IPv4 configuration for the camera interface (NetworkManager)
# Usage: ./install.sh <interface-name>
#
# Cameras on the Jetson devkits use IPv4 link-local (169.254.x.x). This sets
# ipv4.method=link-local on the interface's NetworkManager connection.

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

INTERFACE_NAME="$1"
if [ -z "$INTERFACE_NAME" ]; then
    echo "Error: No interface name provided."
    echo "Usage: $0 <interface-name>"
    exit 1
fi

if ! command -v nmcli >/dev/null 2>&1; then
    echo "Error: nmcli (NetworkManager) not found; cannot configure link-local."
    exit 1
fi

if ! ip link show "$INTERFACE_NAME" > /dev/null 2>&1; then
    log "Error: Network interface '$INTERFACE_NAME' does not exist."
    exit 1
fi

log "Configuring IPv4 link-local for $INTERFACE_NAME..."

# Modify the profile already bound to the device; create one only if none is.
CON="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE_NAME" 2>/dev/null || true)"
if [ -n "$CON" ] && [ "$CON" != "--" ]; then
    log "Setting ipv4.method=link-local on existing connection '$CON'."
    sudo nmcli connection modify "$CON" ipv4.method link-local
else
    CON="hdk-camera-$INTERFACE_NAME"
    log "No active profile bound to $INTERFACE_NAME; creating '$CON'."
    sudo nmcli connection add type ethernet ifname "$INTERFACE_NAME" \
        con-name "$CON" ipv4.method link-local
fi

# Re-activate so the change takes effect now
sudo nmcli connection up "$CON"

log "Link-local IPv4 configured for $INTERFACE_NAME (connection: $CON)."
