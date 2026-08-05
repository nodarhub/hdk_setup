#!/bin/bash

# Clock service installation script (Jetson clocks)
# Usage: ./install.sh [-power-mode <n>] [-fan <true|false>]
#
# The nvpmodel index of the maximum performance profile is board specific:
#   AGX Orin  -> 0 (MAXN)
#   Orin Nano -> 2 (MAXN SUPER)

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

# Parse arguments
POWER_MODE="0"
FAN_MAX="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -power-mode)
      POWER_MODE="$2"
      shift 2
      ;;
    -fan)
      FAN_MAX="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo "Usage: $0 [-power-mode <n>] [-fan <true|false>]"
      exit 1
      ;;
  esac
done

if ! [[ "$POWER_MODE" =~ ^[0-9]+$ ]]; then
  echo "Error: -power-mode must be a non-negative integer, got '$POWER_MODE'."
  exit 1
fi

if [[ "$FAN_MAX" != "true" && "$FAN_MAX" != "false" ]]; then
  echo "Error: -fan must be true or false, got '$FAN_MAX'."
  exit 1
fi

log "Starting clock service installation (nvpmodel mode $POWER_MODE)..."

# Path for the clocks script
CLOCKS_SCRIPT="/usr/local/bin/clocks.sh"
SERVICE_FILE="/etc/systemd/system/clocks.service"
RESTORE_SERVICE_FILE="/etc/systemd/system/clocks-restore.service"

# Create the clocks.sh script
log "Creating clocks.sh script at $CLOCKS_SCRIPT..."
CLOCKS_SCRIPT_CONTENT='#!/bin/bash -e

# Usage: sudo ./clocks.sh <--max|--restore> [--fan]

if [ $(whoami) != root ]; then
   echo "Error: Run this script as a root user"
   exit 1
fi

clkfile=/tmp/defclocks.conf
pwrfile=/tmp/defpower.conf

if [ -e /sys/devices/platform/13e10000.host1x/15340000.vic ]; then
   vicctrl=/sys/devices/platform/13e10000.host1x/15340000.vic
   vicfreqctrl=$vicctrl/devfreq/15340000.vic
elif [ -e /sys/devices/platform/13e40000.host1x/15340000.vic ]; then
   vicctrl=/sys/devices/platform/13e40000.host1x/15340000.vic
   vicfreqctrl=$vicctrl/devfreq/15340000.vic
fi

maxclocks() {
   if [ ! -e $clkfile ]; then
       jetson_clocks --store $clkfile
       if [ -n "$vicctrl" ]; then
           echo "$vicfreqctrl/governor:$(cat $vicfreqctrl/governor)" >> $clkfile
           echo "$vicfreqctrl/max_freq:$(cat $vicfreqctrl/max_freq)" >> $clkfile
           echo "$vicctrl/power/control:$(cat $vicctrl/power/control)" >> $clkfile
       fi
   fi

   if [ ! -e $pwrfile ]; then
       echo $(nvpmodel -q | tail -n1) > $pwrfile
   fi

   nvpmodel -m '"$POWER_MODE"'
   jetson_clocks

   if [ -n "$vicctrl" ]; then
       echo on > $vicctrl/power/control
       echo userspace > $vicfreqctrl/governor
       sleep 1
       maxfreq=$(cat $vicfreqctrl/available_frequencies | rev | cut -f1 -d" " | rev)
       echo $maxfreq > $vicfreqctrl/max_freq
       echo $maxfreq > $vicfreqctrl/userspace/set_freq
   fi

   if [ "$fan_only" = true ]; then
       jetson_clocks --fan
   fi
}

restore() {
   if [ -e $clkfile ]; then
       jetson_clocks --restore $clkfile > /dev/null 2>&1
   fi

   if [ -e $pwrfile ]; then
       nvpmodel -m $(cat $pwrfile)
   fi
}

action="$1"
fan_only=false

if [[ "$2" == "--fan" ]]; then
   fan_only=true
fi

case "$action" in
   --restore)
       restore
       ;;
   --max)
       maxclocks
       ;;
   *)
       echo "Unknown option '\''$action'\''."
       echo "Usage: $(basename $0) <--max|--restore> [--fan]"
       exit 1
       ;;
esac
'
echo "$CLOCKS_SCRIPT_CONTENT" | sudo tee "$CLOCKS_SCRIPT" > /dev/null
sudo chmod +x "$CLOCKS_SCRIPT"

# Create the main service file
log "Creating main clocks service file at $SERVICE_FILE..."
# With -fan true, stop nvfancontrol first (it would otherwise override the fan
# back to its thermal curve) and pin clocks + fan to maximum.
if [ "$FAN_MAX" == "true" ]; then
  CLOCKS_EXEC="ExecStartPre=-/usr/bin/systemctl stop nvfancontrol
ExecStart=/usr/local/bin/clocks.sh --max --fan"
else
  CLOCKS_EXEC="ExecStart=/usr/local/bin/clocks.sh --max"
fi
SERVICE_FILE_CONTENT="[Unit]
Description=Set Jetson Clocks to Max or Restore
After=multi-user.target

[Service]
Type=oneshot
$CLOCKS_EXEC
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"
echo "$SERVICE_FILE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null

# Create the restore service file
log "Creating restore clocks service file at $RESTORE_SERVICE_FILE..."
RESTORE_SERVICE_FILE_CONTENT="[Unit]
Description=Restore Jetson Clocks on Shutdown
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/clocks.sh --restore

[Install]
WantedBy=halt.target reboot.target
"
echo "$RESTORE_SERVICE_FILE_CONTENT" | sudo tee "$RESTORE_SERVICE_FILE" > /dev/null

# Reload systemd and enable services
log "Reloading systemd and enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable clocks.service
sudo systemctl enable clocks-restore.service

# Start the main service immediately
log "Starting clocks service..."
sudo systemctl start clocks.service

log "Clock service installation complete."
log "Clocks will be set to maximum on boot and restored on shutdown."