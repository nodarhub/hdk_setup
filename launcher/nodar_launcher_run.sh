#!/usr/bin/env bash
# Nodar Launcher — terminal wrapper
# Opened by the .desktop icon and the autostart entry.
# Tries terminal emulators in order until one works.

SCRIPT="$HOME/.config/nodar/nodar_launcher.py"
TITLE="Nodar Launcher"

if ! [ -f "$SCRIPT" ]; then
    echo "Launcher not found: $SCRIPT" >&2
    exit 1
fi

if command -v gnome-terminal &>/dev/null; then
    exec gnome-terminal --title="$TITLE" -- python3 "$SCRIPT"
elif command -v xterm &>/dev/null; then
    exec xterm -title "$TITLE" -e python3 "$SCRIPT"
elif command -v x-terminal-emulator &>/dev/null; then
    exec x-terminal-emulator -e python3 "$SCRIPT"
elif command -v konsole &>/dev/null; then
    exec konsole --title "$TITLE" -e python3 "$SCRIPT"
else
    echo "No terminal emulator found. Install gnome-terminal or xterm." >&2
    exit 1
fi
