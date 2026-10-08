# NVIDIA Unattended Driver Install - Agent Guidance

## Prerequisites
- Windows PowerShell 5.1 or later
- Internet connection
- NVIDIA GPU (for NvidiaInstall.ps1) or AMD/NVIDIA/Intel GPU (for UnattendedDriverInstall.ps1)

## Script Usage

### NvidiaInstall.ps1
Installs latest NVIDIA driver silently.
```powershell
.\NvidiaInstall.ps1 [-clean] [-folder <path>]
```
- `-clean`: Passes `/clean` to installer for clean install
- `-folder`: Download directory (default: `$env:temp`)

### UnattendedDriverInstall.ps1
Installs AMD, NVIDIA, or Intel drivers based on detected hardware.
```powershell
.\UnattendedDriverInstall.ps1 [-Clean] [-WhatIf] [-SkipChipset] [-SkipGraphics] [-LogPath <path>]
```
- `-Clean`: For NVIDIA only (passes `/clean` to NVIDIA installer; ignored for AMD)
- `-WhatIf`: Shows actions without executing
- `-SkipChipset`: Skip AMD chipset driver install
- `-SkipGraphics`: Skip AMD graphics driver install
- `-LogPath`: Custom log file path (folder used for temp files)

## Important Notes
- All scripts download drivers to a temporary folder and clean up after installation
- Scripts wait for user keypress before exiting (press any key)
- NvidiaInstall.ps1 detects GPU via WMI and queries NVIDIA's AjaxDriverService API
- UnattendedDriverInstall.ps1 detects AMD chipset (SM Bus Controller) and GPU, Intel GPU, and falls back to NVIDIA logic
- AMD driver logic downloads both installers from AMD directly (drivers.amd.com requires the AMD driver page as `Referer`), verifies the Authenticode signature, and installs silently
  - Chipset version comes from `drivers.amd.com/drivers/installer/chipset/version.txt`; the installer is `AMD_Chipset_Software.exe` beside it
  - Graphics version is read off the minimal-setup filename on `amd.com/en/support/download/drivers.html`, then the full package URL is built as `drivers.amd.com/drivers/whql-amd-software-adrenalin-edition-<version>-win11-c.exe`
- Intel driver logic downloads latest installer from Intel's download mirror and installs silently with -s --terminateProcesses --report <log> flags
- No build, test, or CI configuration exists in this repository