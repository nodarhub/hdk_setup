# HDK Setup

Hardware Development Kit setup scripts for configuring Linux-based hardware for real-time camera and network operations.

## Supported Platforms

- **NVIDIA Jetson Orin AGX** - Embedded GPU computing device
- **OnLogic with Orin AGX** - Industrial edge computing platform

## Overview

This repository provides automated setup for:

- **Network Configuration** - Multi-interface setup with jumbo frames (MTU 9000) for high-bandwidth camera streaming
- **PTP (Precision Time Protocol)** - Sub-microsecond clock synchronization across devices (with hardware timestamping)
- **External Time Sync** - PTP slave and PHC2SYS for synchronizing to an external PTP grandmaster (OnLogic only)
- **Clock Optimization** - Jetson CPU/GPU clock maximization for real-time processing
- **DHCP Server** - Automatic IP assignment for connected cameras

## Directory Structure

```
hdk_setup/
├── install.sh           # Main installation script
├── uninstall.sh         # Main uninstallation script
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

### With Hammerhead Autostart

To automatically start Hammerhead on boot:

```bash
./install.sh -d jetson -autostart true
./install.sh -d onlogic -autostart true
```

The `-autostart` flag is `false` by default.

## Uninstallation

### Jetson Devices

```bash
./uninstall.sh -d jetson
```

### OnLogic Devices

```bash
./uninstall.sh -d onlogic
```

## Modules

### MTU

Configures jumbo frames (MTU 9000) for high-performance data transfer.

- **Jetson**: Creates a NetworkManager dispatcher script to automatically apply settings when interfaces come up
- **OnLogic**: MTU is configured via netplan in the Network module

### Network (OnLogic only)

Configures multi-interface network setup:

| Interface | Configuration | Purpose |
|-----------|---------------|---------|
| ethLAN0 | DHCP | Management interface |
| ethLAN1 | Static (10.10.1.10/24) | Gateway interface |
| ethLAN2, 3, 5 | Static (10.10.x.1), MTU 9000 | Camera interfaces |
| ethLAN4 | Static (192.168.30.25/24) | External PTP time sync |

Also configures ISC DHCP server with subnets for camera interfaces:
- 10.10.2.0/24, 10.10.3.0/24, 10.10.5.0/24

### PTP Master (Both platforms)

Installs and configures Linux PTP (ptp4l) for precision time synchronization:

- Operates as PTP master clock for connected cameras
- Uses E2E (End-to-End) delay mechanism
- Creates `linuxptp.service` for automatic startup and restart on failure

### PTP Slave (OnLogic only)

Configures the device as a PTP slave to synchronize time from an external PTP grandmaster:

- Operates as PTP slave clock on ethLAN4
- Syncs to external PTP master (e.g., network grandmaster clock)
- Creates `linuxptp-slave.service` for automatic startup

### PHC2SYS (OnLogic only)

Synchronizes the system clock from the PTP hardware clock:

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
- Automatically restarts on failure
- Updates journald log level for debug output visibility

## Requirements

- Linux (Ubuntu/Debian-based)
- sudo privileges (scripts invoke sudo internally as needed)
- For Jetson: NVIDIA Jetson Orin AGX with JetPack
- For OnLogic: OnLogic with Orin AGX and multiple Ethernet interfaces

## Services Installed

- `linuxptp.service` - PTP master clock synchronization (both platforms)
- `linuxptp-slave.service` - PTP slave clock synchronization (OnLogic)
- `phc2sys.service` - PHC to system clock sync (OnLogic)
- `clocks.service` - Clock maximization at startup (both platforms)
- `clocks-restore.service` - Clock restoration on shutdown (both platforms)
- `isc-dhcp-server` - DHCP server for camera networks (OnLogic)
- `hammerhead.service` - Hammerhead autostart (optional, both platforms)