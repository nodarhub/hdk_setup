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

# ── Launcher-managed data (uuid, activation key, downloads, configs) ────────
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

# ── Installed script files ──────────────────────────────────────────────────
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
