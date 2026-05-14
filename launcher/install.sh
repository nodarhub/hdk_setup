#!/bin/bash

# Nodar Launcher installation script
# Installs nodar_launcher.py, nodar_launcher_run.sh, and nodar_launcher.cfg to
# ~/.config/nodar/, then creates a Desktop icon and an autostart entry.
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
RUN_SCRIPT="$NODAR_DIR/nodar_launcher_run.sh"
DESKTOP_SRC="$USER_HOME/Desktop/nodar_launcher.desktop"
AUTOSTART_DST="$USER_HOME/.config/autostart/nodar_launcher.desktop"

# ── 1. Install files to ~/.config/nodar/ ──────────────────────────────────────
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

# ── Helper: write a .desktop file ─────────────────────────────────────────────
write_desktop() {
    local path="$1"
    local autostart="$2"   # true | false
    sudo -u "$RUN_USER" tee "$path" > /dev/null << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Nodar Launcher
GenericName=Nodar Launcher
Comment=Interactive launcher for Hammerhead and Nodar Viewer
Exec=$RUN_SCRIPT
Icon=utilities-terminal
Terminal=false
StartupNotify=false
Categories=Utility;
EOF
    if [ "$autostart" = "true" ]; then
        sudo -u "$RUN_USER" tee -a "$path" > /dev/null << EOF
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
EOF
    fi
}

# ── 2. Desktop icon ────────────────────────────────────────────────────────────
log "Creating desktop icon at $DESKTOP_SRC..."
sudo -u "$RUN_USER" mkdir -p "$USER_HOME/Desktop"
write_desktop "$DESKTOP_SRC" false
sudo chmod +x "$DESKTOP_SRC"

# Mark as trusted so GNOME allows double-clicking without a warning dialog
if command -v gio &>/dev/null; then
    sudo -u "$RUN_USER" gio set "$DESKTOP_SRC" metadata::trusted true 2>/dev/null && \
        log "Desktop icon marked as trusted." || \
        log "Note: could not mark icon as trusted — right-click → Allow Launching."
fi

log "Desktop icon created: $DESKTOP_SRC"

# ── 3. Autostart entry ─────────────────────────────────────────────────────────
log "Creating autostart entry at $AUTOSTART_DST..."
sudo -u "$RUN_USER" mkdir -p "$USER_HOME/.config/autostart"
write_desktop "$AUTOSTART_DST" true
log "Autostart entry created: $AUTOSTART_DST"

log "Nodar Launcher installation complete."
log "The launcher will start automatically at next login."
log "To disable autostart: rm $AUTOSTART_DST"
