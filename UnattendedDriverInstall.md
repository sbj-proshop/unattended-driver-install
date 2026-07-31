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

## 3. Installation Logic
- If AMD hardware (chipset or GPU) is detected → proceeds with AMD installer (unless both skip flags are set)
- If Nvidia GPU is detected → proceeds with Nvidia download/install logic (regardless of AMD presence)
- If neither AMD nor Nvidia hardware is detected (or all installations are skipped) → exits with error "No supported AMD/Nvidia hardware detected or all installations were skipped"

## 4. AMD Driver Acquisition
- Downloads latest AMD chipset driver from TechPowerUp (https://www.techpowerup.com/download/amd-ryzen-chipset-drivers/)
- Downloads latest AMD graphics driver from TechPowerUp (https://www.techpowerup.com/download/amd-radeon-graphics-drivers/)
- Uses TechPowerUp's token-based mirror download flow with SHA-256 verification
- In WhatIf mode, shows the URL and mirror selection that would be used without executing
- Creates separate temporary folders: $env:TEMP\AMDChipsetInstall_<guid> and $env:TEMP\AMDGraphicsInstall_<guid> (GUID suffix avoids collisions between concurrent runs)
- Temporary folders are registered for cleanup on every exit path (success and failure)

## 5. AMD Installation Process
- Downloads each installer to its respective temporary folder
- Executes with the silent switch: /install
- In WhatIf mode, shows what would be executed without running
- Post-install: waits 3 seconds, resets console colors to green/black, prompts for keypress
- Cleans up temporary folders on success or failure
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
  * In WhatIf mode, shows the download/install commands without executing
  * On any failure, logs a red error and reports exit code 2
  * Waits 3 seconds post-install for display stabilization
  * Restores console to green/black before exit prompt
  * Exits immediately with the Nvidia result code

## 7. Logging & User Experience
- Errors: Red text (Write-Host -ForegroundColor Red)
- Warnings: Yellow text (Write-Host -ForegroundColor Yellow)
- Success/info: Green text (Write-Host -ForegroundColor Green)
- On failure: Prompts for keypress before exiting (mirroring Nvidia script)
- Console color changes match the original script's style for both AMD and Nvidia sections

## 8. Exit Codes
- 0 – Success (all requested installations completed successfully)
- 1 – No supported AMD/Nvidia hardware detected, all installations were skipped, or an unexpected error occurred
- 2 – Download failure (failed to download a driver from its source; applies to both AMD and Nvidia downloads)
- 3 – Installation failure (an installer returned a non-zero exit code)

Notes:
- AMD installer non-zero exit codes are normalized to 3; AMD download failures are normalized to 2.
- NVIDIA installer failures report 3; NVIDIA download/info failures report 2.
- All error paths clean up temporary folders and restore the console colors that were active when the script started.