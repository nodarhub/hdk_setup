#!/bin/bash

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Usage check
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <INTERFACE_1> <INTERFACE_2>"
  exit 1
fi

IFACE1="$1"
IFACE2="$2"

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
CONFIG_DIR="$SCRIPT_DIR/config"

# Ensure netplan is installed
if ! command -v netplan >/dev/null 2>&1; then
  log "Netplan not found. Installing..."
  sudo apt update
  sudo apt install -y netplan.io
else
  log "Netplan is already installed."
fi

# Ensure /etc/netplan exists
if [ ! -d /etc/netplan ]; then
  log "Creating /etc/netplan directory..."
  sudo mkdir -p /etc/netplan
fi

# Setup the DHCP server and copy the configuration
if [ ! -f /etc/default/isc-dhcp-server.bak ]; then
  log "Backing up /etc/default/isc-dhcp-server"
  sudo cp /etc/default/isc-dhcp-server /etc/default/isc-dhcp-server.bak
else
  log "/etc/default/isc-dhcp-server.bak already exists. Not creating a backup"
fi

log "Recreating /etc/default/isc-dhcp-server with DHCP on $IFACE1 and $IFACE2"
echo -e "INTERFACESv4=\"$IFACE1 $IFACE2\"\nINTERFACESv6=\"\"" | sudo tee /etc/default/isc-dhcp-server > /dev/null

log "Copying the dhcpd.conf"
sudo cp "$CONFIG_DIR/dhcp/dhcpd.conf" /etc/dhcp/dhcpd.conf

# Create wait_for_interfaces script in /usr/local/bin
log "Installing wait_for_interfaces to /usr/local/bin"
sudo tee /usr/local/bin/wait_for_interfaces > /dev/null <<'SCRIPT'
#!/bin/bash
# Check that interfaces have a valid 10.10.x.x IPv4 address
# Used as ExecStartPre for isc-dhcp-server

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <interface1> <interface2>"
    exit 1
fi

for iface in "$@"; do
    ip_addr=$(ip -o -4 addr show "$iface" | awk '{print $4}' | cut -d/ -f1)
    if [[ "$ip_addr" =~ ^10\.10 ]]; then
        echo "$iface is up with IP $ip_addr"
    else
        echo "$iface does not have a valid 10.10.x.x IPv4 address."
        exit 1
    fi
done

echo "All interfaces are ready."
exit 0
SCRIPT
sudo chmod +x /usr/local/bin/wait_for_interfaces

log "Writing override.conf for isc-dhcp-server with interfaces $IFACE1 and $IFACE2"
sudo mkdir -p /etc/systemd/system/isc-dhcp-server.service.d
sudo tee /etc/systemd/system/isc-dhcp-server.service.d/override.conf > /dev/null <<EOF
[Unit]
# Clear out the existing Wants= and After= lines
Wants=
After=
# Now specify that we only want basic networking up
After=network.target
Wants=network.target

[Service]
# Check that the interfaces are up.
ExecStartPre=/usr/local/bin/wait_for_interfaces $IFACE1 $IFACE2
Restart=on-failure
RestartSec=5
EOF

# Install the netplan
log "Installing Netplan configuration"
sudo cp "$CONFIG_DIR/netplan"/*.yaml /etc/netplan/
sudo chmod 600 /etc/netplan/*.yaml
sudo netplan generate
sudo netplan apply 2>/dev/null
sleep 5

set +e
log "Reloading systemd and enabling isc-dhcp-server"
sudo systemctl daemon-reload
sudo systemctl enable isc-dhcp-server
log "Stopping and starting isc-dhcp-server"
sudo systemctl stop isc-dhcp-server
sudo systemctl start isc-dhcp-server
set -e

log "Network installation complete."