#!/bin/bash

# Link-local IPv4 configuration for the camera interface (NetworkManager)
# Usage: ./install.sh <interface-name>
#
# Cameras on the Jetson devkits use IPv4 link-local (169.254.x.x). This sets
# ipv4.method=link-local on the interface's NetworkManager connection.

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
source "$SCRIPT_DIR/../lib/net_detect.sh"

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

# Modify the interface's existing profile; create one only if none exists. The
# profile is found even with the cable out, so the camera link does not have to
# be connected to run this.
CON="$(nm_profile_uuid_for "$INTERFACE_NAME")"
if [ -n "$CON" ]; then
    log "Setting ipv4.method=link-local on existing connection '$(nm_profile_name "$CON")'."
    sudo nmcli connection modify "$CON" ipv4.method link-local
else
    CON="hdk-camera-$INTERFACE_NAME"
    log "No profile found for $INTERFACE_NAME; creating '$CON'."
    sudo nmcli connection add type ethernet ifname "$INTERFACE_NAME" \
        con-name "$CON" ipv4.method link-local
fi

# Activating needs carrier; without it the profile applies when the cable goes in.
if [ "$(cat "/sys/class/net/$INTERFACE_NAME/carrier" 2>/dev/null || echo 0)" = "1" ]; then
    sudo nmcli connection up "$CON"
else
    log "No cable on $INTERFACE_NAME; settings will apply when it is connected."
fi

log "Link-local IPv4 configured for $INTERFACE_NAME (connection: $(nm_profile_name "$CON"))."
