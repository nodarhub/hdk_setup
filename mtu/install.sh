#!/bin/bash

# MTU installation script
# Usage: ./install.sh <interface-name> [mtu-value]

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Check if the interface name is passed as an argument
if [ -z "$1" ]; then
    echo "Error: No interface name provided."
    echo "Usage: $0 <interface-name> [mtu-value]"
    exit 1
fi

# Set the interface name from the first argument
INTERFACE_NAME="$1"
DESIRED_MTU="${2:-9000}"

log "Starting MTU installation for interface: $INTERFACE_NAME with MTU: $DESIRED_MTU"

# Check if the interface exists
if ! ip link show "$INTERFACE_NAME" > /dev/null 2>&1; then
    log "Error: Network interface '$INTERFACE_NAME' does not exist."
    exit 1
fi

# Create or overwrite the dispatcher script
DISPATCHER_SCRIPT_PATH="/etc/NetworkManager/dispatcher.d/99-mtu-$INTERFACE_NAME"
log "Creating or overwriting dispatcher script at $DISPATCHER_SCRIPT_PATH..."

sudo bash -c "cat > $DISPATCHER_SCRIPT_PATH" <<EOL
#!/bin/bash

IFACE=\$1
STATUS=\$2
DESIRED_MTU=$DESIRED_MTU

# Only proceed if the interface is the one specified and the status is 'up'
if [ "\$IFACE" == "$INTERFACE_NAME" ] && [ "\$STATUS" == "up" ]; then
    # Get the current MTU value of the interface
    CURRENT_MTU=\$(ip link show "\$IFACE" | grep -o 'mtu [0-9]*' | awk '{print \$2}')

    # Check if the current MTU is already the desired value
    if [ "\$CURRENT_MTU" != "\$DESIRED_MTU" ]; then
        # MTU is not the desired value, so bring the interface down, set MTU, and bring it back up
        ip link set dev "\$IFACE" down
        ip link set dev "\$IFACE" mtu "\$DESIRED_MTU"
        ip link set dev "\$IFACE" up
        echo "MTU set to \$DESIRED_MTU for \$IFACE."
    else
        # MTU is already correct, no action needed
        echo "MTU is already \$DESIRED_MTU for \$IFACE, no changes made."
    fi
fi
EOL

# Make the dispatcher script executable
log "Making the dispatcher script executable..."
sudo chmod +x "$DISPATCHER_SCRIPT_PATH"

log "MTU installation complete for $INTERFACE_NAME."
log "Note: MTU change will be applied automatically when the interface comes up."