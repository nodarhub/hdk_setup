#!/bin/bash

# Shared helpers, sourced by install.sh / uninstall.sh.

# Print USB-attached Ethernet interface names, one per line. Detection is by
# device path (must go through USB), not by name, so it works with the
# MAC-derived names USB adapters get and excludes the onboard PCIe NIC.
detect_usb_ethernet() {
  local path iface
  for path in /sys/class/net/*; do
    [ -e "$path" ] || continue
    iface="$(basename "$path")"
    # Skip loopback, virtual, and the USB device-mode gadget interfaces.
    case "$iface" in
      lo|l4tbr0|usb[0-9]*|rndis[0-9]*|ncm[0-9]*|docker*|veth*|virbr*|dummy*) continue ;;
    esac
    [ -d "$path/wireless" ] && continue
    if readlink -f "$path/device" 2>/dev/null | grep -q '/usb'; then
      echo "$iface"
    fi
  done
}

# Print the USB port an interface is attached to (e.g. "2-1.1"), empty if none.
usb_port_path() {
  local d
  d="$(readlink -f "/sys/class/net/$1/device" 2>/dev/null || true)"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/idVendor" ] && { basename "$d"; return 0; }
    d="$(dirname "$d")"
  done
}

# Describe where an adapter is plugged in. On the Orin Nano devkit the four
# Type-A sockets sit behind an on-board hub (ports like 2-1.1) while the Type-C
# socket is a direct root port (2-2), so hub depth is a reliable hint there.
# It is only a hint: an external hub or a different carrier board breaks it.
usb_port_hint() {
  local port
  port="$(usb_port_path "$1")"
  case "$port" in
    "")  echo "unknown port" ;;
    *.*) echo "port $port, behind hub - likely USB-A" ;;
    *)   echo "port $port, direct root port - likely USB-C" ;;
  esac
}

# Print ", NO CABLE" when an interface has no carrier, empty otherwise. Reading
# carrier fails on a down interface, which counts as no link.
usb_link_note() {
  [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null || echo 0)" = "1" ] || echo ", NO CABLE"
}

# Print the UUID of the NetworkManager profile for an interface, empty if none.
# Checks the active connection first, then persisted profiles by interface-name:
# a profile outlives its cable being unplugged, while 'device show' only reports
# active ones. UUIDs are used because profile names may contain colons, which
# would break nmcli's terse output.
nm_profile_uuid_for() {
  local uuid
  uuid="$(nmcli -g GENERAL.CON-UUID device show "$1" 2>/dev/null || true)"
  if [ -n "$uuid" ] && [ "$uuid" != "--" ]; then
    echo "$uuid"
    return 0
  fi
  while IFS= read -r uuid; do
    [ -n "$uuid" ] || continue
    if [ "$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null || true)" = "$1" ]; then
      echo "$uuid"
      return 0
    fi
  done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null | awk -F: '$2=="802-3-ethernet"{print $1}')
}

# Print a profile's display name, falling back to its UUID.
nm_profile_name() {
  nmcli -g connection.id connection show "$1" 2>/dev/null || echo "$1"
}
