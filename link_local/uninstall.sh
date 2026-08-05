#!/bin/bash

# Link-local IPv4 cleanup for the camera interface (NetworkManager)
# Usage: ./uninstall.sh <interface-name>

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
    log "nmcli (NetworkManager) not found; nothing to revert."
    exit 0
fi

CREATED="hdk-camera-$INTERFACE_NAME"
if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$CREATED"; then
    # We created this profile during install; remove it entirely.
    log "Removing connection profile '$CREATED'..."
    sudo nmcli connection delete "$CREATED" || log "Failed to delete $CREATED"
else
    # We modified an existing profile; revert its IPv4 method to automatic.
    CON="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE_NAME" 2>/dev/null || true)"
    if [ -n "$CON" ] && [ "$CON" != "--" ]; then
        log "Reverting ipv4.method to auto on connection '$CON' (applies on next activation)..."
        sudo nmcli connection modify "$CON" ipv4.method auto || log "Failed to modify $CON"
        # Not reactivating here: on a camera network with no DHCP server, bringing
        # the connection up with method=auto would time out ("IP config could not
        # be reserved"). The reverted setting takes effect on the next boot/replug.
    else
        log "No link-local connection found for $INTERFACE_NAME; nothing to revert."
    fi
fi

log "Link-local cleanup completed for $INTERFACE_NAME."
