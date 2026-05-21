#!/bin/bash

# Nodar Launcher installation script
# Installs nodar_launcher.py, nodar_launcher_run.sh, and nodar_launcher.cfg to
# ~/.config/nodar/.
# Usage: ./install.sh

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting Nodar Launcher installation..."

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

# Get the actual user (handle sudo case)
RUN_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo ~"$RUN_USER")"

NODAR_DIR="$USER_HOME/.config/nodar"

# ── Install files to ~/.config/nodar/ ──────────────────────────────────────
log "Installing launcher files to $NODAR_DIR..."
sudo -u "$RUN_USER" mkdir -p "$NODAR_DIR"

sudo cp "$SCRIPT_DIR/nodar_launcher.py"     "$NODAR_DIR/nodar_launcher.py"
sudo cp "$SCRIPT_DIR/nodar_launcher_run.sh" "$NODAR_DIR/nodar_launcher_run.sh"
sudo chmod +x "$NODAR_DIR/nodar_launcher_run.sh"
sudo chown "$RUN_USER" "$NODAR_DIR/nodar_launcher.py" "$NODAR_DIR/nodar_launcher_run.sh"

# Copy config only if one doesn't already exist (don't overwrite user edits)
if [ ! -f "$NODAR_DIR/nodar_launcher.cfg" ]; then
    sudo cp "$SCRIPT_DIR/nodar_launcher.cfg" "$NODAR_DIR/nodar_launcher.cfg"
    sudo chown "$RUN_USER" "$NODAR_DIR/nodar_launcher.cfg"
    log "Config installed: $NODAR_DIR/nodar_launcher.cfg"
else
    log "Config already exists, skipping: $NODAR_DIR/nodar_launcher.cfg"
fi

log "Nodar Launcher installation complete."
