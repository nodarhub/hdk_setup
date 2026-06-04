#!/usr/bin/env bash
# Nodar Launcher — installation script
#
# Downloads nodar_launcher.py from the Nodar documentation site, installs it
# together with the run wrapper and default config to ~/.config/nodar/, and
# creates a desktop icon and autostart entry.
#
# Usage (as the target user, or with sudo):
#   ./install.sh

set -euo pipefail

LAUNCHER_URL="https://docs.nodarsensor.net/launcher/nodar_launcher.py"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

# Resolve the actual target user when run via sudo
RUN_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo ~"$RUN_USER")"

NODAR_DIR="$USER_HOME/.config/nodar"
RUN_SCRIPT="$NODAR_DIR/nodar_launcher_run.sh"

log "Installing Nodar Launcher for user: $RUN_USER"

# ── 1. Create install directory ───────────────────────────────────────────────
sudo -u "$RUN_USER" mkdir -p "$NODAR_DIR"

# ── 2. Download nodar_launcher.py ─────────────────────────────────────────────
log "Downloading launcher from $LAUNCHER_URL ..."
if command -v curl &>/dev/null; then
    sudo -u "$RUN_USER" curl -fsSL "$LAUNCHER_URL" -o "$NODAR_DIR/nodar_launcher.py"
elif command -v wget &>/dev/null; then
    sudo -u "$RUN_USER" wget -q "$LAUNCHER_URL" -O "$NODAR_DIR/nodar_launcher.py"
else
    echo "Error: neither curl nor wget is available." >&2
    exit 1
fi
sudo -u "$RUN_USER" chmod +x "$NODAR_DIR/nodar_launcher.py"
log "Launcher installed: $NODAR_DIR/nodar_launcher.py"

# ── 3. Install run wrapper ────────────────────────────────────────────────────
sudo cp "$SCRIPT_DIR/nodar_launcher_run.sh" "$RUN_SCRIPT"
sudo chmod +x "$RUN_SCRIPT"
sudo chown "$RUN_USER" "$RUN_SCRIPT"
log "Run wrapper installed: $RUN_SCRIPT"

# ── 4. Install default config (skip if user already has one) ─────────────────
CFG="$NODAR_DIR/nodar_launcher.cfg"
if [ ! -f "$CFG" ]; then
    sudo cp "$SCRIPT_DIR/nodar_launcher.cfg" "$CFG"
    sudo chown "$RUN_USER" "$CFG"
    log "Config installed: $CFG"
else
    log "Config already exists — skipping to preserve user edits: $CFG"
fi

# ── 5. Helper: write a .desktop file ─────────────────────────────────────────
write_desktop() {
    local path="$1"
    local autostart="${2:-false}"
    sudo -u "$RUN_USER" tee "$path" > /dev/null <<EOF
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
        sudo -u "$RUN_USER" tee -a "$path" > /dev/null <<EOF
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
EOF
    fi
    sudo chmod +x "$path"
}

# ── 6. Desktop icon ───────────────────────────────────────────────────────────
DESKTOP_FILE="$USER_HOME/Desktop/nodar_launcher.desktop"
sudo -u "$RUN_USER" mkdir -p "$USER_HOME/Desktop"
write_desktop "$DESKTOP_FILE" false

if command -v gio &>/dev/null; then
    sudo -u "$RUN_USER" gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null \
        && log "Desktop icon marked as trusted." \
        || log "Note: could not mark icon as trusted — right-click → Allow Launching."
fi
log "Desktop icon created: $DESKTOP_FILE"

# ── 7. Autostart entry ────────────────────────────────────────────────────────
AUTOSTART_FILE="$USER_HOME/.config/autostart/nodar_launcher.desktop"
sudo -u "$RUN_USER" mkdir -p "$USER_HOME/.config/autostart"
write_desktop "$AUTOSTART_FILE" true
log "Autostart entry created: $AUTOSTART_FILE"

log "Installation complete. The launcher will start automatically at next login."
log "To uninstall: sudo ./uninstall.sh"
