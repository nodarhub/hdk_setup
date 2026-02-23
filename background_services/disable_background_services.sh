#!/bin/bash

# Immediately stop known update-related services if they exist
for svc in \
    update-notifier.service \
    unattended-upgrades.service \
    ubuntu-report.service \
    packagekit.service \
    apt-daily.service \
    apt-daily-upgrade.service
do
    if systemctl list-unit-files "$svc" &>/dev/null; then
        echo "Stopping $svc"
        sudo systemctl stop "$svc"
    else
        echo "$svc not found, skipping"
    fi
done

# Kill known background processes (safe even if not running)
for proc in update-notifier unattended-upgrade ubuntu-report; do
    sudo pkill -f "$proc" 2>/dev/null || true
done

# Define the services and timers to be checked
services=(
    "apt-daily.timer"                # Daily download of apt package lists
    "apt-daily-upgrade.timer"        # Daily automatic apt package upgrades
    "apt-daily.service"              # Apt service for daily downloads (triggered by apt-daily.timer)
    "apt-daily-upgrade.service"      # Apt service for daily upgrades (triggered by apt-daily-upgrade.timer)
    "bluetooth"                      # Bluetooth
    "packagekit.service"             # Provides automatic updates and package management
    "unattended-upgrades.service"    # Automatically installs security updates
    "apport-autoreport.timer"        # Checks and reports crash reports
    "fwupd-refresh.timer"            # Refreshes firmware updates via fwupd
    "motd-news.timer"                # Checks for new system messages or updates (Message of the Day)
    "ua-timer.timer"                 # Ubuntu Advantage (UA) timer for Ubuntu Pro tasks
    "ua-timer.service"               # Ubuntu Advantage (UA) service for repeated tasks
    "update-notifier-download.timer" # Downloads data for failed package installations
    "update-notifier-motd.timer"     # Checks for Ubuntu version updates (MOTD-based)
    "systemd-networkd-wait-online.service" # Don't wait for internet to complete the boot process

    # Tracker services
    "tracker-extract-3.service"      # Extracts metadata from files
    "tracker-miner-fs-3.service"     # Indexes files and directories
    "tracker-miner-fs-control-3.service"   # Controls coordination for filesystem indexing
    "tracker-miner-rss-3.service"    # Mines RSS feeds (if enabled)
    "tracker-store-3.service"        # Stores Tracker metadata
    "tracker-writeback-3.service"    # Writes index changes back to disk
    "tracker-xdg-portal-3.service"   # Interfaces with XDG portal for Tracker data

    # Additional background/diagnostic services
    "speech-dispatcher.service"      # Provides text-to-speech for accessibility (disable if not needed)
    "speech-dispatcher.socket"       # Socket for speech-dispatcher (prevents on-demand activation)
    "ubuntu-report.service"          # Sends diagnostic/usage reports to Ubuntu (disable if offline or undesired)
)

# Make sure any pending systemd changes are applied first
sudo systemctl daemon-reload

# Array to hold the units that need to be stopped/disabled/masked
usr_services_to_change=()
sys_services_to_change=()
for service in "${services[@]}"; do
    if systemctl --user list-unit-files "$service" &>/dev/null; then
        active_status=$(systemctl --user is-active "$service" 2>/dev/null)
        enabled_status=$(systemctl --user is-enabled "$service" 2>/dev/null)
        if [ "$active_status" != "inactive" ] || [ "$enabled_status" != "masked" ]; then
            echo "--user $service, active_status: ${active_status}, enabled_status: ${enabled_status}"
            usr_services_to_change+=("$service")
        else
            echo "$service is already disabled and masked in --user"
        fi
    fi
    if systemctl list-unit-files "$service" &>/dev/null; then
        active_status=$(systemctl is-active "$service" 2>/dev/null)
        enabled_status=$(systemctl is-enabled "$service" 2>/dev/null)
        if [ "$active_status" != "inactive" ] || [ "$enabled_status" != "masked" ]; then
            echo "system-wide $service, active_status: ${active_status}, enabled_status: ${enabled_status}"
            sys_services_to_change+=("$service")
        else
            echo "$service is already disabled and masked system-wide"
        fi
    fi
done

# If there are units to change, run bulk commands
if [ ${#usr_services_to_change[@]} -gt 0 ]; then
    units_to_stop="${usr_services_to_change[*]}"
    echo "Bulk stopping --user services: $units_to_stop"
    systemctl --user stop "${usr_services_to_change[@]}"
    echo "Bulk disabling --user services: $units_to_stop"
    systemctl --user disable "${usr_services_to_change[@]}"
    echo "Bulk masking --user services: $units_to_stop"
    systemctl --user mask "${usr_services_to_change[@]}"
    sudo systemctl daemon-reload
else
    echo "No --user services require changes."
fi
if [ ${#sys_services_to_change[@]} -gt 0 ]; then
    units_to_stop="${sys_services_to_change[*]}"
    echo "Bulk stopping system services: $units_to_stop"
    sudo systemctl stop "${sys_services_to_change[@]}"
    echo "Bulk disabling system services: $units_to_stop"
    sudo systemctl disable "${sys_services_to_change[@]}"
    echo "Bulk masking system services: $units_to_stop"
    sudo systemctl mask "${sys_services_to_change[@]}"
    sudo systemctl daemon-reload
else
    echo "No system services require changes."
fi

# Remove cached files that could trigger upgrade/update notifications
if [ -f /var/lib/update-notifier/updates-available ]; then
    sudo rm -f /var/lib/update-notifier/updates-available
fi

if [ -d /var/lib/update-notifier/package-data-downloads ]; then
    sudo rm -rf /var/lib/update-notifier/package-data-downloads
fi

if [ -f /var/lib/ubuntu-release-upgrader/release-upgrade-available ]; then
    sudo rm -f /var/lib/ubuntu-release-upgrader/release-upgrade-available
fi

# Suppress future release upgrade prompts
echo -e "[DEFAULT]\nPrompt=never" | sudo tee /etc/update-manager/release-upgrades > /dev/null

# Prevent future reinstallation of upgrader components
sudo apt-mark hold ubuntu-release-upgrader-core update-manager-core
