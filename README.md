# HDK Setup

Hardware Development Kit setup scripts for configuring Linux-based hardware for real-time camera and network operations.

## Supported Platforms

- **NVIDIA Jetson Orin AGX** - Embedded GPU computing device
- **OnLogic with Orin AGX** - Industrial edge computing platform

## Overview

This repository provides automated setup for:

- **Background Services** - Disables unnecessary OS services (updates, trackers, etc.) for real-time stability
- **Network Configuration** - Multi-interface setup with jumbo frames (MTU 9000) for high-bandwidth camera streaming
- **PTP (Precision Time Protocol)** - Sub-microsecond clock synchronization across devices (with hardware timestamping)
- **External Time Sync** - PTP slave and PHC2SYS for synchronizing to an external PTP grandmaster (OnLogic only, opt-in)
- **Clock Optimization** - Jetson CPU/GPU clock maximization for real-time processing
- **DHCP Server** - Automatic IP assignment for connected cameras

## Directory Structure

```
hdk_setup/
├── install.sh           # Main installation script
├── uninstall.sh         # Main uninstallation script
├── background_services/ # Disable unnecessary OS services
│   └── disable_background_services.sh
├── clock/               # Jetson clock optimization
│   ├── install.sh
│   └── uninstall.sh
├── hammerhead/          # Hammerhead autostart service
│   ├── install.sh
│   └── uninstall.sh
├── mtu/                 # MTU (jumbo frames) configuration
│   ├── install.sh
│   └── uninstall.sh
├── network/             # OnLogic network & DHCP setup
│   ├── install.sh
│   ├── uninstall.sh
│   └── config/
│       ├── dhcp/
│       │   └── dhcpd.conf
│       └── netplan/
│           ├── 01-ethLAN0.yaml
│           ├── 01-ethLAN1.yaml
│           ├── 10-camera.yaml
│           └── 01-l4tbr0.yaml
├── ptp/                 # Linux PTP master setup
│   ├── install.sh
│   └── uninstall.sh
├── ptp_slave/           # Linux PTP slave setup (external time sync)
│   ├── install.sh
│   └── uninstall.sh
└── phc2sys/             # PHC to system clock sync
    ├── install.sh
    └── uninstall.sh
```

## Installation

### Jetson Devices

```bash
./install.sh -d jetson
```

### OnLogic Devices

```bash
./install.sh -d onlogic
```

### With Custom Camera Interfaces

```bash
./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3
```

### With External Time Sync (OnLogic only)

To synchronize time from an external PTP grandmaster via ethLAN4:

```bash
./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true
```

This reconfigures ethLAN4 from a camera interface to a PTP sync interface (default IP: `192.168.30.25/24`), installs the PTP slave service, and installs PHC2SYS to sync the system clock.

### With External Time Sync and Custom IP

```bash
./install.sh -d onlogic -cam_if1 ethLAN2 -cam_if2 ethLAN3 -external-time-sync true -sync-ip 10.0.0.50/24
```

### With Hammerhead Autostart

To automatically start Hammerhead on boot:

```bash
./install.sh -d jetson -autostart true
./install.sh -d onlogic -autostart true
```

The `-autostart` flag is `false` by default.

### All Flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `-d` | Yes | — | Device type: `jetson` or `onlogic` |
| `-cam_if1` | No | `ethLAN2` | First camera interface (OnLogic) |
| `-cam_if2` | No | `ethLAN3` | Second camera interface (OnLogic) |
| `-autostart` | No | `false` | Enable Hammerhead autostart service |
| `-external-time-sync` | No | `false` | Enable external PTP time sync (OnLogic only) |
| `-sync-ip` | No | `192.168.30.25/24` | IP/CIDR for ethLAN4 when external time sync is enabled |

## Uninstallation

### Jetson Devices

```bash
./uninstall.sh -d jetson
```

### OnLogic Devices

```bash
./uninstall.sh -d onlogic
```

The uninstall script always attempts to clean up PTP slave and PHC2SYS services. These are safe no-ops if the services were never installed.

## Modules

### Background Services

Disables unnecessary OS background services for real-time stability:

- Stops and masks automatic update services (apt-daily, unattended-upgrades)
- Disables package management daemons (PackageKit, update-notifier)
- Stops tracker/indexing services
- Removes cached update data and suppresses upgrade prompts

### MTU

Configures jumbo frames (MTU 9000) for high-performance data transfer.

- **Jetson**: Creates a NetworkManager dispatcher script to automatically apply settings when interfaces come up
- **OnLogic**: MTU is configured via netplan in the Network module

### Network (OnLogic only)

Configures multi-interface network setup:

**Default (without `-external-time-sync`):**

| Interface | Configuration | Purpose |
|-----------|---------------|---------|
| ethLAN0 | DHCP | Management interface |
| ethLAN1 | Static (10.10.1.10/24) | Gateway interface |
| ethLAN2, 3, 4, 5 | Static (10.10.x.1), MTU 9000 | Camera interfaces |

**With `-external-time-sync true`:**

| Interface | Configuration | Purpose |
|-----------|---------------|---------|
| ethLAN0 | DHCP | Management interface |
| ethLAN1 | Static (10.10.1.10/24) | Gateway interface |
| ethLAN2, 3, 5 | Static (10.10.x.1), MTU 9000 | Camera interfaces |
| ethLAN4 | Static (192.168.30.25/24 or custom) | External PTP time sync |

When external time sync is enabled, ethLAN4's MTU 9000 and DHCP subnet are removed, and the interface is reconfigured for PTP synchronization.

Also configures ISC DHCP server with subnets for camera interfaces.

### PTP Master (Both platforms)

Installs and configures Linux PTP (ptp4l) for precision time synchronization:

- Operates as PTP master clock for connected cameras
- Uses E2E (End-to-End) delay mechanism
- Creates `linuxptp.service` for automatic startup and restart on failure

### PTP Slave (OnLogic only, opt-in)

Configures the device as a PTP slave to synchronize time from an external PTP grandmaster. Only installed when `-external-time-sync true` is passed.

- Operates as PTP slave clock on ethLAN4
- Syncs to external PTP master (e.g., network grandmaster clock)
- Creates `linuxptp-slave.service` for automatic startup

### PHC2SYS (OnLogic only, opt-in)

Synchronizes the system clock from the PTP hardware clock. Only installed when `-external-time-sync true` is passed.

- Transfers time from the PTP hardware clock (PHC) to CLOCK_REALTIME
- Runs after PTP slave has synchronized with the external master
- Creates `phc2sys.service` for automatic startup

### Clock (Both platforms)

Maximizes CPU/GPU clocks for optimal real-time performance:

- Sets maximum power profile (`nvpmodel -m 0`)
- Runs `jetson_clocks` for maximum CPU, GPU, and EMC (memory) frequencies
- Maximizes VIC (Video Image Compositor) frequency if available
- Automatically restores default clocks on shutdown

### Hammerhead Autostart (Optional)

Creates a systemd service to automatically start Hammerhead on boot:

- Runs as the user who installs the service (to access user config files)
- Starts after network, DHCP, and PTP services are ready
- When external time sync is enabled, also waits for PTP slave and PHC2SYS services
- Automatically restarts on failure
- Updates journald log level for debug output visibility

## Requirements

- Linux (Ubuntu/Debian-based)
- sudo privileges (scripts invoke sudo internally as needed)
- For Jetson: NVIDIA Jetson Orin AGX with JetPack
- For OnLogic: OnLogic with Orin AGX and multiple Ethernet interfaces

## Services Installed

- `linuxptp.service` - PTP master clock synchronization (both platforms)
- `linuxptp-slave.service` - PTP slave clock synchronization (OnLogic, when `-external-time-sync true`)
- `phc2sys.service` - PHC to system clock sync (OnLogic, when `-external-time-sync true`)
- `clocks.service` - Clock maximization at startup (both platforms)
- `clocks-restore.service` - Clock restoration on shutdown (both platforms)
- `isc-dhcp-server` - DHCP server for camera networks (OnLogic)
- `hammerhead.service` - Hammerhead autostart (optional, both platforms)
