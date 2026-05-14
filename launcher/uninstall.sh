#!/bin/bash

# Nodar Launcher cleanup script
# Removes the desktop icon, autostart entry, and installed launcher files.
# Usage: ./uninstall.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting Nodar Launcher cleanup..."

# Get the actual user (handle sudo case)
RUN_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo ~"$RUN_USER")"

NODAR_DIR="$USER_HOME/.config/nodar"
DESKTOP_SRC="$USER_HOME/Desktop/nodar_launcher.desktop"
AUTOSTART_DST="$USER_HOME/.config/autostart/nodar_launcher.desktop"

# Remove desktop icon
if [ -f "$DESKTOP_SRC" ]; then
    log "Removing desktop icon: $DESKTOP_SRC"
    rm -f "$DESKTOP_SRC"
else
    log "Desktop icon not found: $DESKTOP_SRC"
fi

# Remove autostart entry
if [ -f "$AUTOSTART_DST" ]; then
    log "Removing autostart entry: $AUTOSTART_DST"
    rm -f "$AUTOSTART_DST"
else
    log "Autostart entry not found: $AUTOSTART_DST"
fi

# Remove installed launcher files
for f in nodar_launcher.py nodar_launcher_run.sh; do
    if [ -f "$NODAR_DIR/$f" ]; then
        log "Removing $NODAR_DIR/$f"
        rm -f "$NODAR_DIR/$f"
    fi
done

# Leave nodar_launcher.cfg in place — it may contain user edits.
log "Note: $NODAR_DIR/nodar_launcher.cfg was preserved (may contain user edits)."
log "      Remove it manually if no longer needed."

log "Nodar Launcher cleanup completed."
