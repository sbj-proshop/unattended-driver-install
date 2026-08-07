# UnattendedDriverInstall.ps1 Script Features
## 1. Parameter Block
- [switch]$Clean - kept for compatibility with NvidiaInstall.ps1; ignored for AMD installations
- [switch]$WhatIf - shows actions without executing the installation
- [switch]$SkipChipset - do not install the AMD chipset driver
- [switch]$SkipGraphics - do not install the AMD graphics driver
- [string]$LogPath - optional custom log file path (folder used for temp files if specified)

## 2. Hardware Detection
- AMD Chipset: Detects SM Bus Controller and/or PCI Encryption/Decryption Controller devices with vendor ID PCI\VEN_1022*
- AMD GPU: Detects devices with vendor ID PCI\VEN_1002*
- Nvidia GPU: Uses original logic from NvidiaInstall.ps1 (PCI\VEN_10DE*)
- Intel GPU: Detects devices with vendor ID PCI\VEN_8086*

## 3. Installation Logic
- If AMD hardware (chipset or GPU) is detected → proceeds with AMD installer (unless both skip flags are set)
- If Nvidia GPU is detected → proceeds with Nvidia download/install logic (regardless of AMD presence)
- If Intel GPU is detected → proceeds with Intel download/install logic (regardless of AMD/NVIDIA presence)
- If neither AMD nor Nvidia nor Intel hardware is detected (or all installations are skipped) → exits with error "No supported AMD/Nvidia/Intel hardware detected or all installations were skipped"

## 4. AMD Driver Acquisition
- Downloads latest AMD chipset driver from TechPowerUp (https://www.techpowerup.com/download/amd-ryzen-chipset-drivers/)
- Downloads latest AMD graphics driver from TechPowerUp (https://www.techpowerup.com/download/amd-radeon-graphics-drivers/)
- Uses TechPowerUp's token-based mirror download flow with SHA-256 verification
- In WhatIf mode, shows generic download messages without executing
- Creates separate temporary folders: $env:TEMP\AMDChipsetInstall_<guid> and $env:TEMP\AMDGraphicsInstall_<guid> (GUID suffix avoids collisions between concurrent runs)
- Temporary folders are registered for cleanup on every exit path (success and failure)

## 5. AMD Installation Process
- Downloads each installer to its respective temporary folder
- Executes with the silent switch: /install (Chipset) or -install (Graphics)
- In WhatIf mode, shows generic messages without executing (e.g., "Would download AMD driver from TechPowerUp (mirror selection)")
- Cleans up temporary folders on success or failure
- Exit code handling: AMD exit codes 2 and 3010 (reboot required) are treated as success (return 0); other non-zero exit codes return 3 (installation failure)
- Exit code propagation: returns the first failure exit code (2 for download failure, 3 for installation failure) if any AMD installation fails

## 6. Nvidia Installation
- Runs whenever an Nvidia GPU is detected, independent of AMD hardware presence
- Uses the same logic as the original NvidiaInstall.ps1 script, factored into dedicated functions mirroring the AMD flow:
  * Get-NvidiaDriverInfo - resolves the GPU device ID, looks up the PCI device name (pci-ids.ucw.cz), derives the series name and product series ID (psid), then queries NVIDIA's AjaxDriverService API for the latest driver version and download URL
  * Download-NvidiaDriver - downloads the installer into a temporary folder using BITS transfer
  * Install-NvidiaDriver - executes the installer with /s (plus -clean when -Clean is specified) and returns an exit code
- Maintains same logging style, user experience, and error handling
- Respects -Clean and -WhatIf parameters appropriately
- Specific Nvidia section behavior:
  * Resets console to dark blue/white background
  * Clears host display
  * Creates a temporary folder named NVIDIA_<guid> (GUID suffix avoids collisions) under the folder derived from -LogPath (or $env:temp)
  * In WhatIf mode, shows generic messages without executing (e.g., "Would download Nvidia driver from X to Y")
  * On any failure, logs a red error and reports exit code 2
  * Restores console to green/black before exit prompt
  * No longer exits immediately: when Intel hardware is also present, continues to the Intel flow and reports a combined exit code

## 7. Intel Installation
- Runs whenever an Intel GPU is detected, independent of AMD/NVIDIA hardware presence
- Downloads the latest Intel graphics driver from Intel's official download mirror
- Extracts the full download URL (downloadmirror.intel.com) from Intel's download page (https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html) and downloads with an appropriate referer header
- Installs the driver silently using -s --terminateProcesses --report <log> flags
- Maintains same logging style, user experience, and error handling as other sections
- Respects -WhatIf parameter appropriately
- Specific Intel section behavior:
  * Creates a temporary folder named INTEL_<guid> (GUID suffix avoids collisions) under the folder derived from -LogPath (or $env:temp)
  * In WhatIf mode, shows generic messages without executing (e.g., "Would download Intel driver from X to Y")
  * On any failure, logs a red error and reports exit code 2
  * Saves IntelGFX.log to the parent directory of the temp folder before cleanup
  * Restores console to green/black before exit prompt
  * Reports a combined exit code with any other installed drivers

## 8. Logging & User Experience
- Errors: Red text (Write-Host -ForegroundColor Red)
- Warnings: Yellow text (Write-Host -ForegroundColor Yellow)
- Success/info: Green text (Write-Host -ForegroundColor Green)
- On failure: Prompts for keypress before exiting (mirroring Nvidia script)
- Console color changes match the original script's style for AMD, Nvidia, and Intel sections

## 9. Exit Codes
- 0 – Success (all requested installations completed successfully)
- 1 – No supported AMD/Nvidia/Intel hardware detected, all installations were skipped, or an unexpected error occurred
- 2 – Download failure (failed to download a driver from its source; applies to AMD, Nvidia, and Intel downloads)
- 3 – Installation failure (an installer returned a non-zero exit code)

Notes:
- AMD installer exit codes 2 and 3010 (reboot required) are treated as success; other non-zero codes are normalized to 3. AMD download failures are normalized to 2.
- NVIDIA installer failures report 3; NVIDIA download/info failures report 2.
- Intel installer failures report 3; Intel download/info failures report 2.
- When multiple driver installs run (e.g., AMD chipset + NVIDIA GPU, or AMD + Intel), the script installs them all and reports the first failure exit code in install order (chipset → graphics → NVIDIA → Intel).
- All error paths clean up temporary folders and restore the console colors that were active when the script started.