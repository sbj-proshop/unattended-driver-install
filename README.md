# Unattended Driver Install Repository

This repository contains PowerShell scripts for unattended installation of graphics drivers for NVIDIA and Intel along with chiptset and graphics drivers for AMD hardware.

## Scripts

### 1. NvidiaInstall.ps1
Automatically detects your NVIDIA GPU, looks up the latest Game Ready driver from NVIDIA's official service, downloads and installs it silently. Intended to run standalone, not along side with `UnattendedDriverInstall.ps1`.

**Best for:** Systems with only NVIDIA GPUs where you want the original NVIDIA-only installation logic.

### 2. UnattendedDriverInstall.ps1
Unattended driver installer for AMD, NVIDIA, and Intel hardware. This script detects AMD, NVIDIA, and Intel hardware in the system and installs the appropriate drivers.

**Best for:** Systems with any combination of AMD, NVIDIA, or Intel graphics hardware where you want automatic detection and installation of the appropriate drivers. Intended to run on systems that are missing drivers (i.e. a newly installed system).

## Features (UnattendedDriverInstall.ps1)

- **Multi-Vendor Support** — Detects and installs drivers for AMD (chipset and GPU), NVIDIA, and Intel graphics
- **Smart Detection** — Uses WMI to identify hardware by PCI vendor IDs
- **AMD Support** — Downloads latest chipset and graphics drivers from TechPowerUp with SHA-256 verification
- **NVIDIA Support** — Uses the same logic as NvidiaInstall.ps1 to get latest drivers from NVIDIA's AjaxDriverService API
- **Intel Support** — Downloads latest drivers from Intel's official download mirror
- **Flexible Installation** — Options to skip specific components (chipset/graphics) for AMD
- **Silent Installation** — All installations run silently with appropriate parameters
- **Auto-cleanup** — Deletes temporary download folders after installation
- **WhatIf Mode** — Preview actions without executing
- **Detailed Logging** — Color-coded output for easy tracking

## Usage

### NvidiaInstall.ps1
```powershell
.\NvidiaInstall.ps1 [-clean] [-folder <path>]
```

| Parameter  | Description                                        |
|------------|----------------------------------------------------|
| `-clean`   | Passes the `-clean` flag to the installer (clean install) |
| `-folder`  | Download directory (default: `$env:temp`)          |

### UnattendedDriverInstall.ps1
```powershell
.\UnattendedDriverInstall.ps1 [-Clean] [-WhatIf] [-SkipChipset] [-SkipGraphics] [-LogPath <path>]
```

| Parameter     | Description                                                                      |
|---------------|----------------------------------------------------------------------------------|
| `-Clean`      | For NVIDIA only (passes `/clean` to NVIDIA installer; ignored for AMD)           |
| `-WhatIf`     | Shows actions without executing                                                  |
| `-SkipChipset`| Skip AMD chipset driver install                                                  |
| `-SkipGraphics`| Skip AMD graphics driver install                                                |
| `-LogPath`    | Custom log file path (folder used for temp files). Only used for Intel installer |

## Examples

### NvidiaInstall.ps1
```powershell
# Standard install
.\NvidiaInstall.ps1

# Clean install
.\NvidiaInstall.ps1 -clean

# Specify a custom download folder
.\NvidiaInstall.ps1 -folder "D:\Downloads"
```

### UnattendedDriverInstall.ps1
```powershell
# Standard install (detects hardware and installs appropriate drivers)
.\UnattendedDriverInstall.ps1

# Preview what would happen without installing
.\UnattendedDriverInstall.ps1 -WhatIf

# Install NVIDIA driver with clean install option
.\UnattendedDriverInstall.ps1 -Clean

# Install only AMD graphics driver (skip chipset)
.\UnattendedDriverInstall.ps1 -SkipChipset

# Specify custom log/temp folder
.\UnattendedDriverInstall.ps1 -LogPath "D:\Logs"
```

## How it works (UnattendedDriverInstall.ps1)

1. Detects hardware using WMI queries:
   - AMD Chipset: SM Bus Controller and/or PCI Encryption/Decryption Controller (PCI\VEN_1022*)
   - AMD GPU: PCI\VEN_1002*
   - NVIDIA GPU: PCI\VEN_10DE* (uses original NvidiaInstall.ps1 logic)
   - Intel GPU: PCI\VEN_8086*

2. Based on detected hardware and parameters:
   - Installs AMD chipset driver (if detected and not skipped)
   - Installs AMD graphics driver (if detected and not skipped)
   - Installs NVIDIA driver (if NVIDIA GPU detected)
   - Installs Intel driver (if Intel GPU detected)

3. For each driver type:
   - Downloads the latest driver from the appropriate source
   - Verifies downloads where possible (SHA-256 for AMD)
   - Runs the installer silently with appropriate parameters
   - Cleans up temporary files
   - Tracks exit codes

4. Exits with appropriate code:
   - 0: Success
   - 1: No supported hardware detected or all installations skipped
   - 2: Download failure
   - 3: Installation failure

## Supported Hardware

### AMD
- **Chipset**: All AMD chipsets that uses either AM4 or AM5 sockets
  - Uses the official AMD Adrenaline installer for chipset drivers
- **Graphics**: All AMD GPUs that AMD Adrenaline supports
  - Uses the official AMD Adrenaline installer for graphics drivers

### NVIDIA
- **GPU Series**:
  - RTX 50 Series
  - RTX 40 Series
  - RTX 30 Series
  - RTX 20 Series
  - GTX 16 Series
- All NVIDIA GPUs (PCI\VEN_10DE*) are supported
- Both `UnattendedDriverInstall.ps1` and `NvidiaInstall.ps1` falls back to treating unknown NVIDIA GPUs as RTX 40 Series.

### Intel
- **Graphics**: All Intel GPUs (PCI\VEN_8086*)
  - Intel Arc and integrated graphics drivers

## Requirements

- Windows (PowerShell 5.1 or later)
- AMD chipset or GPU, NVIDIA or Intel GPU
- Internet connection
