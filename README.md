# HDK Setup

Hardware Development Kit setup scripts for configuring Linux-based hardware for real-time camera and network operations.

## Supported Platforms

- **NVIDIA Jetson Orin AGX** - Embedded GPU computing device
- **OnLogic with Orin AGX** - Industrial edge computing platform

## Overview

This repository provides automated setup for:

- **Network Configuration** - Multi-interface setup with jumbo frames (MTU 9000) for high-bandwidth camera streaming
- **PTP (Precision Time Protocol)** - Sub-microsecond clock synchronization across devices (with hardware timestamping)
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
└── ptp/                 # Linux PTP setup
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
| ethLAN2-5 | Static (10.10.x.1), MTU 9000 | Camera interfaces |

Also configures ISC DHCP server with subnets for each camera interface:
- 10.10.2.0/24, 10.10.3.0/24, 10.10.4.0/24, 10.10.5.0/24

### PTP (Both platforms)

Installs and configures Linux PTP (ptp4l) for precision time synchronization:

- Operates as PTP master clock
- Uses E2E (End-to-End) delay mechanism
- Creates `linuxptp.service` for automatic startup

### Clock (Both platforms)

Maximizes CPU/GPU clocks for optimal real-time performance:

- Sets maximum power profile (`nvpmodel -m 0`)
- Runs `jetson_clocks` for maximum CPU, GPU, and EMC (memory) frequencies
- Maximizes VIC (Video Image Compositor) frequency if available
- Automatically restores default clocks on shutdown

## Requirements

- Linux (Ubuntu/Debian-based)
- sudo privileges (scripts invoke sudo internally as needed)
- For Jetson: NVIDIA Jetson Orin AGX with JetPack
- For OnLogic: OnLogic with Orin AGX and multiple Ethernet interfaces

## Services Installed

- `linuxptp.service` - PTP clock synchronization (both platforms)
- `clocks.service` - Clock maximization at startup (both platforms)
- `clocks-restore.service` - Clock restoration on shutdown (both platforms)
- `isc-dhcp-server` - DHCP server for camera networks (OnLogic)