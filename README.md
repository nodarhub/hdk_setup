# Setup and Customize your own HDK

The HDK comes with pre-setup software and system configurations. The operating system we use is Linux-based. Although the pre-setup configurations captures most of the use cases, anyone might still want special configurations for their needs (e.g. network setting, background Hammerhead services). We provides in this [repository](https://github.com/nodarhub/hdk_setup) some convenient scripts to help you 
1. customize your HDK and
2. completely reinstall the HDK.

## Supported Platforms

- **NVIDIA Jetson Orin AGX** - Embedded GPU computing device
- **NVIDIA Jetson Orin Nano** - Entry-level embedded GPU computing device
- **OnLogic with Orin AGX** - Industrial edge computing platform

## Overview

This [repository](https://github.com/nodarhub/hdk_setup) provides automated setup for:

- **Background Services** - Disables unnecessary system services (updates, indexing, diagnostics) for a stable real-time environment
- **Network Configuration** - Multi-interface setup with jumbo frames (MTU 9000) for high-bandwidth camera streaming (OnLogic and AGX Orin); IPv4 link-local addressing for the camera interface on Jetson devkits
- **PTP (Precision Time Protocol)** - Clock synchronization across devices (hardware timestamping via ptp4l on AGX Orin/OnLogic; software timestamping via ptpd on Orin Nano)
- **External Time Sync** - PTP slave and PHC2SYS for synchronizing to an external PTP grandmaster (OnLogic only, opt-in)
- **Clock Optimization** - Jetson CPU/GPU clock maximization for real-time processing
- **DHCP Server** - Automatic IP assignment for connected cameras

## Directory Structure

```
hdk_setup/
├── install.sh           # Main installation script
├── uninstall.sh         # Main uninstallation script
├── lib/                 # Shared helpers (USB Ethernet interface detection)
│   └── net_detect.sh
├── background_services/ # Disable unnecessary system services
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
├── link_local/          # IPv4 link-local for the Jetson camera interface
│   ├── install.sh
│   └── uninstall.sh
├── data_out/            # Static IP for the Orin Nano data-out interface
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
├── ptp/                 # Linux PTP (ptp4l) master setup — AGX Orin & OnLogic
│   ├── install.sh
│   └── uninstall.sh
├── ptpd/                # ptpd master setup — Orin Nano (software timestamping)
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

### Jetson AGX Orin

```bash
./install.sh -d jetson
```

### Jetson Orin Nano

```bash
./install.sh -d orin-nano
```

The camera uplink on the Orin Nano is a USB-to-Ethernet adapter (e.g. UGREEN), whose interface name is MAC-derived and not fixed. The installer **autodetects** it (by finding the USB-attached Ethernet interface) and asks you to confirm:

```
Detected USB Ethernet adapter 'enx6c1ff7171c1e'. Press Enter to use it, or type another interface name:
```

Press Enter to accept, or type a different name. If several USB adapters are present you'll get a numbered list to pick from. To skip the prompt entirely (or for non-interactive installs), pass the interface explicitly:

```bash
./install.sh -d orin-nano -cam_if enx6c1ff7171c1e
```

This uses nvpmodel mode `2` (MAXN SUPER). Because the adapter has no PTP hardware clock, PTP runs via `ptpd` (software timestamping) instead of `ptp4l`.

#### Optional second adapter for data-out

A second USB-to-Ethernet adapter (e.g. USB-C to RJ45) can be used as the **data-out** uplink, configured with the static address `10.10.1.10/24`. This is entirely optional — with a single adapter the install behaves exactly as above and never asks about it.

When a spare USB adapter is detected, the installer asks which one to use after the camera interface has been chosen:

```
Multiple USB Ethernet adapters detected:
    1) enx6c1ff7171c1e
    2) enx00e04c680001
Select the CAMERA (data-in) interface [1-2] or type an interface name (Enter for 1): 1
Spare USB Ethernet adapter(s) available for data-out:
    1) enx00e04c680001
Select the DATA-OUT interface [1-1] or type an interface name (Enter to skip):
```

Press Enter to skip data-out setup. For non-interactive installs, pass both interfaces explicitly (data-out is skipped when there is no terminal and no `-data_if`):

```bash
./install.sh -d orin-nano -cam_if enx6c1ff7171c1e -data_if enx00e04c680001
```

The chosen roles are recorded in `/etc/hdk/interfaces.conf` so `uninstall.sh` reverts the right adapter.

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
| `-d` | Yes | — | Device type: `jetson` (AGX Orin), `orin-nano`, or `onlogic` |
| `-cam_if1` | No | `ethLAN2` | First camera interface (OnLogic) |
| `-cam_if2` | No | `ethLAN3` | Second camera interface (OnLogic) |
| `-cam_if` | No | `eth0` (jetson) / autodetected USB adapter (orin-nano) | Camera/PTP interface for Jetson boards. On Orin Nano, overrides autodetection of the USB-to-Ethernet adapter |
| `-data_if` | No | — (skipped) | Orin Nano only: second USB-to-Ethernet adapter to configure as the data-out uplink (static `10.10.1.10/24`). Optional; skipped unless given or selected at the prompt |
| `-power-mode` | No | `0` (jetson) / `2` (orin-nano) | nvpmodel index of the max-performance profile |
| `-autostart` | No | `false` | Enable Hammerhead autostart service |
| `-external-time-sync` | No | `false` | Enable external PTP time sync (OnLogic only) |
| `-sync-ip` | No | `192.168.30.25/24` | IP/CIDR for ethLAN4 when external time sync is enabled |

## Uninstallation

### Jetson Devices

```bash
./uninstall.sh -d jetson
./uninstall.sh -d orin-nano
```

On Orin Nano the adapter roles are read back from `/etc/hdk/interfaces.conf` (written during install), so both the camera and data-out interfaces are reverted correctly. If that file is missing the camera adapter is autodetected instead; if an adapter is unplugged or was configured by an older install, pass `-cam_if <iface>` and/or `-data_if <iface>` to clean it up, or ignore the skip notice (it's a safe no-op).

### OnLogic Devices

```bash
./uninstall.sh -d onlogic
```

The uninstall script always attempts to clean up PTP slave and PHC2SYS services (safe no-ops if never installed) and re-enables `systemd-timesyncd`.

## Modules

### Background Services (Both platforms)

Disables unnecessary system services to ensure a stable, predictable real-time environment:

- **Update services** - apt-daily, unattended-upgrades, update-notifier, packagekit
- **Indexing services** - Tracker file indexing and metadata extraction
- **Diagnostic services** - ubuntu-report, apport crash reporting, MOTD news
- **Other** - Bluetooth, speech-dispatcher, firmware update checks

Also removes cached update notifications and suppresses future release upgrade prompts. This step is not reverted during uninstall, as these services are generally undesirable on real-time target devices.

### MTU

Configures jumbo frames (MTU 9000) for high-performance data transfer.

- **AGX Orin**: Creates a NetworkManager dispatcher script to automatically apply settings when interfaces come up
- **Orin Nano**: Not configured — the USB-to-Ethernet adapter is unreliable at MTU 9000, so the camera interface stays at the default MTU
- **OnLogic**: MTU is configured via netplan in the Network module

### Link-Local (Jetson only)

GigE Vision cameras on the AGX Orin and Orin Nano devkits use IPv4 link-local
(`169.254.x.x`) addressing. This module sets `ipv4.method=link-local` on the
camera interface's NetworkManager connection so the host can reach them —
automating what was previously a manual step in the Network settings GUI.

- Applied to `eth0` (AGX Orin) or the autodetected USB adapter (Orin Nano)
- Modifies the interface's existing NetworkManager profile; if none is bound, a
  dedicated `hdk-camera-<iface>` profile is created
- Not used on OnLogic, which assigns static camera addresses and runs a DHCP server

### Data-Out (Orin Nano only)

Configures an optional second USB-to-Ethernet adapter as the data-out uplink,
matching what `ethLAN1` does on OnLogic:

| Setting | Value |
|---------|-------|
| Address | `10.10.1.10/24` |
| Default route | via `10.10.1.1`, metric `500` |
| IPv6 | disabled |

The metric keeps this route below Wi-Fi and onboard Ethernet, so it does not
hijack normal outbound traffic. The values are fixed in `data_out/install.sh`.

- Opt-in: nothing is configured unless `-data_if` is passed or a spare adapter is
  selected at the prompt
- Modifies the interface's existing NetworkManager profile; if none is bound, a
  dedicated `hdk-data-<iface>` profile is created
- Warns (without failing) if another interface already holds an address in
  `10.10.1.0/24`

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

### PTP Master

The device acts as the PTP master clock for the connected cameras. Two backends
are used depending on the board's timestamping capabilities:

**ptp4l — AGX Orin & OnLogic** (`ptp/`)

- Linux PTP (`ptp4l`) with hardware timestamping (falls back to software if unavailable)
- Uses E2E (End-to-End) delay mechanism
- Creates `linuxptp.service` for automatic startup and restart on failure

**ptpd — Orin Nano** (`ptpd/`)

- The Orin Nano's camera adapter has no PTP hardware clock, so `ptpd` is used
  with software timestamping (`preset=masteronly`)
- Same E2E delay mechanism and announce/sync intervals as the ptp4l config
- Generates `/etc/ptpd/ptpd.conf` and creates `ptpd.service` for automatic startup and restart on failure

### PTP Slave (OnLogic only, opt-in)

Configures the device as a PTP slave to synchronize time from an external PTP grandmaster. Only installed when `-external-time-sync true` is passed.

- Operates as PTP slave clock on ethLAN4 using **Layer 2 PTP** (Ethernet frames, not IP)
- The IP address on ethLAN4 is not required for PTP synchronization since Layer 2 is used. If `-sync-ip` is specified, it is recommended to be on the same subnet as the PTP grandmaster for debugging and management purposes (e.g., ping, SSH)
- Syncs to external PTP master (e.g., network grandmaster clock)
- Creates `linuxptp-slave.service` for automatic startup

> **WARNING:** When `-external-time-sync true` is enabled, `systemd-timesyncd` (NTP) is disabled to prevent conflicts with PHC2SYS. This means the system clock is **entirely dependent on the external PTP master**. If the PTP master is unavailable, the system clock will not be synchronized and **may drift or reset to 1970**. **Always ensure a PTP grandmaster is reachable on ethLAN4 before enabling this option.**

### PHC2SYS (OnLogic only, opt-in)

Synchronizes the system clock from the PTP hardware clock. Only installed when `-external-time-sync true` is passed.

- Transfers time from the PTP hardware clock (PHC) to CLOCK_REALTIME
- Runs after PTP slave has synchronized with the external master
- Creates `phc2sys.service` for automatic startup
- `systemd-timesyncd` is disabled during install to give PHC2SYS sole control of the system clock (re-enabled on uninstall)

### Clock (Both platforms)

Maximizes CPU/GPU clocks for optimal real-time performance:

- Sets maximum power profile (`nvpmodel -m <mode>`; mode `0` = MAXN on AGX Orin, mode `2` = MAXN SUPER on Orin Nano, override with `-power-mode`)
- Runs `jetson_clocks` for maximum CPU, GPU, and EMC (memory) frequencies
- Maximizes VIC (Video Image Compositor) frequency if available
- **Orin Nano only:** pins the fan to maximum (stops `nvfancontrol`, which would
  otherwise return the fan to its dynamic thermal curve), since the Nano runs
  hotter under sustained max clocks. AGX Orin / OnLogic keep dynamic fan control.
- Automatically restores default clocks on shutdown

### Hammerhead Autostart (Optional)

Creates a systemd service to automatically start Hammerhead on boot:

- Runs as the user who installs the service (to access user config files)
- Starts after network, DHCP, and PTP services are ready
- When external time sync is enabled, also waits for PTP slave and PHC2SYS services
- Automatically restarts on failure
- Updates journald log level for debug output visibility

**Managing the Hammerhead service (when installed with `-autostart true`):**

```bash
# Check service status
sudo systemctl status hammerhead

# Start / stop / restart
sudo systemctl start hammerhead
sudo systemctl stop hammerhead
sudo systemctl restart hammerhead

# Follow logs in real time
sudo journalctl -u hammerhead -f
```

## Requirements

- Linux (Ubuntu/Debian-based)
- sudo privileges (scripts invoke sudo internally as needed)
- For Jetson: NVIDIA Jetson Orin AGX or Orin Nano with JetPack
- For OnLogic: OnLogic with Orin AGX and multiple Ethernet interfaces

## Services Installed

- `linuxptp.service` - PTP master clock synchronization via ptp4l (AGX Orin, OnLogic)
- `ptpd.service` - PTP master clock synchronization via ptpd (Orin Nano)
- `linuxptp-slave.service` - PTP slave clock synchronization (OnLogic, when `-external-time-sync true`)
- `phc2sys.service` - PHC to system clock sync (OnLogic, when `-external-time-sync true`)
- `clocks.service` - Clock maximization at startup (both platforms)
- `clocks-restore.service` - Clock restoration on shutdown (both platforms)
- `isc-dhcp-server` - DHCP server for camera networks (OnLogic)
- `hammerhead.service` - Hammerhead autostart (optional, both platforms)

## Troubleshooting

### Orin Nano hangs on boot with the USB Ethernet adapter plugged in

**Symptom:** With the USB-to-Ethernet adapter connected, the Orin Nano stalls
during boot showing `Start HTTP Boot over IPv4` / `IPv6` (or the `Start PXE over
IPv4` / `IPv6` equivalents). Unplugging the adapter and booting works fine.

**Cause:** When the USB adapter is present, UEFI enumerates it as a new network
device and adds HTTP/PXE network-boot entries to the boot order. By default the
Jetson firmware inserts newly discovered devices at the **top** of the boot
order, so the firmware tries (and waits on) network boot before reaching the SD
card / NVMe.

**Fix (do both):**

1. **Stop new devices from jumping to the top of the boot order.** In UEFI
   setup: `Device Manager` → `NVIDIA Configuration` → `Boot Configuration` →
   set **"Add new devices to top or bottom of boot order"** to **bottom**.
   This keeps future network-boot entries below your OS disks.

2. **Move the OS disk to the top of the current boot order.** In UEFI setup:
   `Boot Maintenance Manager` → `Boot Options` → `Change Boot Order`, and put
   the SD card (`UEFI SD Device`) and/or NVMe (`UEFI <drive name>`) ahead of the
   `UEFI PXEv4/PXEv6/HTTPv4/HTTPv6` entries.

After step 1 the network-boot entries stop reappearing above the disks on
subsequent boots, so the hang does not return when the adapter is replugged.
