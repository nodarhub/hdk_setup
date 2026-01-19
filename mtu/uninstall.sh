#!/bin/bash

# MTU cleanup script
# Usage: ./cleanup.sh <interface-name>

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Check if the interface name is passed as an argument
if [ -z "$1" ]; then
    echo "Error: No interface name provided."
    echo "Usage: $0 <interface-name>"
    exit 1
fi

# Set the interface name from the first argument
INTERFACE_NAME="$1"
DEFAULT_MTU=1500

log "Starting MTU cleanup for interface: $INTERFACE_NAME"

# Define the dispatcher script path
DISPATCHER_SCRIPT_PATH="/etc/NetworkManager/dispatcher.d/99-mtu-$INTERFACE_NAME"

# Check if the interface exists
if ! ip link show "$INTERFACE_NAME" > /dev/null 2>&1; then
    log "Warning: Network interface '$INTERFACE_NAME' does not exist. Continuing with cleanup..."
fi

# Remove the dispatcher script if it exists
if [ -f "$DISPATCHER_SCRIPT_PATH" ]; then
    log "Removing dispatcher script at $DISPATCHER_SCRIPT_PATH..."
    sudo rm -f "$DISPATCHER_SCRIPT_PATH"
else
    log "No dispatcher script found for $INTERFACE_NAME at $DISPATCHER_SCRIPT_PATH."
fi

# Reset the MTU to the default value if interface exists
if ip link show "$INTERFACE_NAME" > /dev/null 2>&1; then
    log "Resetting MTU to $DEFAULT_MTU for $INTERFACE_NAME..."
    sudo ip link set dev "$INTERFACE_NAME" mtu "$DEFAULT_MTU"

    # Verify the MTU change
    log "Verifying the MTU reset..."
    MTU_VALUE=$(ip link show "$INTERFACE_NAME" | grep -o 'mtu [0-9]*' | awk '{print $2}')

    if [ "$MTU_VALUE" == "$DEFAULT_MTU" ]; then
        log "MTU successfully reset to $DEFAULT_MTU for $INTERFACE_NAME."
    else
        log "Warning: Failed to reset MTU. Current MTU is $MTU_VALUE."
    fi
fi

log "MTU cleanup completed for $INTERFACE_NAME."