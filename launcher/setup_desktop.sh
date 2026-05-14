#!/usr/bin/env bash
# setup_desktop.sh — install Nodar Launcher on this Ubuntu machine.
#
# What it does:
#   1. Copies nodar_launcher.py, nodar_launcher.cfg, and nodar_launcher_run.sh
#      to ~/.config/nodar/
#   2. Creates ~/Desktop/nodar_launcher.desktop  (double-click icon)
#   3. Creates ~/.config/autostart/nodar_launcher.desktop  (auto-launch on login)
#
# Run once after deploying the files, or re-run to update.

set -euo pipefail

HERE="$(cd -- "$(dirname "$0")" && pwd)"

NODAR_DIR="$HOME/.config/nodar"
RUN_SCRIPT="$NODAR_DIR/nodar_launcher_run.sh"
DESKTOP_SRC="$HOME/Desktop/nodar_launcher.desktop"
AUTOSTART_DST="$HOME/.config/autostart/nodar_launcher.desktop"

# ── 1. Install files to ~/.config/nodar/ ─────────────────────────────────────
mkdir -p "$NODAR_DIR"

cp "$HERE/nodar_launcher.py"      "$NODAR_DIR/nodar_launcher.py"
cp "$HERE/nodar_launcher_run.sh"  "$NODAR_DIR/nodar_launcher_run.sh"
chmod +x "$NODAR_DIR/nodar_launcher_run.sh"

# Copy the config only if one doesn't already exist (don't overwrite user edits)
if [ ! -f "$NODAR_DIR/nodar_launcher.cfg" ]; then
    cp "$HERE/nodar_launcher.cfg" "$NODAR_DIR/nodar_launcher.cfg"
    echo "Config installed: $NODAR_DIR/nodar_launcher.cfg"
else
    echo "Config already exists, skipping: $NODAR_DIR/nodar_launcher.cfg"
fi

# ── Helper: write the .desktop file content ───────────────────────────────────
write_desktop() {
    local path="$1"
    local autostart="$2"   # true | false
    cat > "$path" <<EOF
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
        cat >> "$path" <<EOF
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
EOF
    fi
}

# ── 2. Desktop icon ───────────────────────────────────────────────────────────
mkdir -p "$HOME/Desktop"
write_desktop "$DESKTOP_SRC" false
chmod +x "$DESKTOP_SRC"

# Mark as trusted so GNOME allows double-clicking without a warning dialog
if command -v gio &>/dev/null; then
    gio set "$DESKTOP_SRC" metadata::trusted true 2>/dev/null && \
        echo "Desktop icon marked as trusted." || \
        echo "Note: could not mark icon as trusted — right-click → Allow Launching."
fi

echo "Desktop icon created:   $DESKTOP_SRC"

# ── 3. Autostart entry ────────────────────────────────────────────────────────
mkdir -p "$HOME/.config/autostart"
write_desktop "$AUTOSTART_DST" true
echo "Autostart entry created: $AUTOSTART_DST"

echo ""
echo "Done. The launcher will start automatically at next login."
echo "To disable autostart:  rm $AUTOSTART_DST"
