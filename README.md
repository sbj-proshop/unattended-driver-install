# NvidiaInstall.ps1

Automatically detects your NVIDIA GPU, looks up the latest Game Ready driver from NVIDIA's official service, downloads and installs it silently.

## Features

- **GPU Detection** — Identifies your NVIDIA GPU via WMI and the PCI IDs database
- **Series Classification** — Maps your device ID to the correct product series (RTX 50/40/30/20, GTX 16)
- **Latest Driver Lookup** — Queries NVIDIA's official `AjaxDriverService` API for the most recent WHQL driver
- **Silent Installation** — Runs the installer with `/s` (optionally with `-clean`)
- **Auto-cleanup** — Deletes downloaded files after installation

## Usage

```powershell
.\NvidiaInstall.ps1 [-clean] [-folder <path>]
```

### Parameters

| Parameter  | Description                                        |
|------------|----------------------------------------------------|
| `-clean`   | Passes the `-clean` flag to the installer (clean install) |
| `-folder`  | Download directory (default: `$env:temp`)          |

### Examples

```powershell
# Standard install
.\NvidiaInstall.ps1

# Clean install
.\NvidiaInstall.ps1 -clean

# Specify a custom download folder
.\NvidiaInstall.ps1 -folder "D:\Downloads"
```

## How it works

1. Detects an NVIDIA GPU using the `CIM_VideoController` WMI class (PCI vendor ID `10DE`)
2. Extracts the device ID and optionally looks up the human-readable name from `pci-ids.ucw.cz`
3. Determines the product series ID (`psid`) used by NVIDIA's driver API
4. Calls NVIDIA's `DriverManualLookup` service to get the latest driver version and download URL
5. Downloads the driver using `Start-BitsTransfer`
6. Runs the installer silently (with optional `-clean` switch)
7. Deletes the temporary files and exits

## Requirements

- Windows (PowerShell 5.1 or later)
- An NVIDIA GPU
- Internet connection
