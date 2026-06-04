#!/bin/bash

# Nodar Launcher cleanup script
# Removes downloaded/generated launcher data, then removes the desktop icon,
# autostart entry, and installed launcher files.
# Usage: ./uninstall.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

log "Starting Nodar Launcher cleanup..."

# Get the actual user (handle sudo case)
RUN_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo ~"$RUN_USER")"

NODAR_DIR="$USER_HOME/.config/nodar"
DESKTOP_SRC="$USER_HOME/Desktop/nodar_launcher.desktop"
AUTOSTART_DST="$USER_HOME/.config/autostart/nodar_launcher.desktop"

# ── 1. Launcher-managed data (uuid, activation key, downloads, configs) ────────
# Prefer the installed copy; fall back to the source-tree copy.
LAUNCHER_PY="$NODAR_DIR/nodar_launcher.py"
if [ ! -f "$LAUNCHER_PY" ]; then
    LAUNCHER_PY="$SCRIPT_DIR/nodar_launcher.py"
fi

if [ -f "$LAUNCHER_PY" ]; then
    log "Removing launcher-generated files..."
    sudo -u "$RUN_USER" python3 "$LAUNCHER_PY" --uninstall
else
    log "Warning: nodar_launcher.py not found; skipping launcher data cleanup."
fi

# ── 2. Desktop icon ────────────────────────────────────────────────────────────
if [ -f "$DESKTOP_SRC" ]; then
    log "Removing desktop icon: $DESKTOP_SRC"
    rm -f "$DESKTOP_SRC"
else
    log "Desktop icon not found: $DESKTOP_SRC"
fi

# ── 3. Autostart entry ─────────────────────────────────────────────────────────
if [ -f "$AUTOSTART_DST" ]; then
    log "Removing autostart entry: $AUTOSTART_DST"
    rm -f "$AUTOSTART_DST"
else
    log "Autostart entry not found: $AUTOSTART_DST"
fi

# ── 4. Installed script files ──────────────────────────────────────────────────
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
