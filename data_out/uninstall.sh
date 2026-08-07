#!/bin/bash

# Static IPv4 cleanup for the data-out interface (NetworkManager)
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

CREATED="hdk-data-$INTERFACE_NAME"
if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$CREATED"; then
    # We created this profile during install; remove it entirely.
    log "Removing connection profile '$CREATED'..."
    sudo nmcli connection delete "$CREATED" || log "Failed to delete $CREATED"
else
    # We modified an existing profile; revert it to automatic addressing.
    CON="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE_NAME" 2>/dev/null || true)"
    if [ -n "$CON" ] && [ "$CON" != "--" ]; then
        log "Reverting connection '$CON' to DHCP (applies on next activation)..."
        # Gateway first: nmcli rejects an address-less profile with a gateway.
        sudo nmcli connection modify "$CON" \
            ipv4.gateway "" \
            ipv4.addresses "" \
            ipv4.route-metric -1 \
            ipv4.never-default no \
            ipv4.method auto \
            ipv6.method auto || log "Failed to modify $CON"
        # Not reactivating: with no DHCP server on the data-out segment,
        # method=auto would time out. Takes effect on the next boot/replug.
    else
        log "No connection found for $INTERFACE_NAME; nothing to revert."
    fi
fi

log "Data-out cleanup completed for $INTERFACE_NAME."
