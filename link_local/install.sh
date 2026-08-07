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
CARRIER="$(cat "/sys/class/net/$INTERFACE_NAME/carrier" 2>/dev/null || echo 0)"
if [ -n "$CON" ] && [ "$CON" != "--" ]; then
    log "Setting ipv4.method=link-local on existing connection '$CON'."
    sudo nmcli connection modify "$CON" ipv4.method link-local
elif [ "$CARRIER" != "1" ]; then
    # Stop before creating anything: NetworkManager will not activate a profile
    # on a link-less device, so this would fail and leave a stale profile behind.
    echo "Error: '$INTERFACE_NAME' has no link and no NetworkManager profile."
    echo "Connect the camera cable and wait for the link to come up, then re-run."
    exit 1
else
    CON="hdk-camera-$INTERFACE_NAME"
    log "No active profile bound to $INTERFACE_NAME; creating '$CON'."
    sudo nmcli connection add type ethernet ifname "$INTERFACE_NAME" \
        con-name "$CON" ipv4.method link-local
fi

# Carrier can still be down here if NetworkManager is set to ignore-carrier.
if [ "$CARRIER" != "1" ]; then
    log "Warning: $INTERFACE_NAME has no carrier; check the camera cable."
fi

# Re-activate so the change takes effect now
sudo nmcli connection up "$CON"

log "Link-local IPv4 configured for $INTERFACE_NAME (connection: $CON)."
