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
