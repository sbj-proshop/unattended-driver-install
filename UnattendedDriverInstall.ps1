<#
.SYNOPSIS
    Unattended driver installer for AMD, Nvidia and Intel hardware.
    
.DESCRIPTION
    This script detects AMD, Nvidia and Intel hardware in the system and installs the appropriate drivers.
    For AMD hardware (chipset or GPU), it downloads and installs the latest drivers from TechPowerUp.
    For Nvidia-only systems, it uses the original Nvidia download/install logic.
    For Intel graphics, it downloads and installs the latest driver from Intel's download mirror.
    The script mirrors the logging style and user experience of the original NvidiaInstall.ps1 script.

.PARAMETER Clean
    Kept for compatibility with the original Nvidia script; ignored for AMD installations.

.PARAMETER WhatIf
    Shows what would happen without executing the installation.

.PARAMETER SkipChipset
    Do not install the AMD chipset driver.

.PARAMETER SkipGraphics
    Do not install the AMD graphics driver.

.PARAMETER LogPath
    Optional custom log file path.

.EXAMPLE
    .\UnattendedDriverInstall.ps1 -WhatIf
    Shows what the script would do without executing.

.EXAMPLE
    .\UnattendedDriverInstall.ps1 -SkipChipset
    Installs only the AMD graphics driver (if AMD GPU is present).

.NOTES
    Author: SBJ - Proshop a/s
    Version: 1.2

    Exit codes:
        0 - Success (all requested installations completed successfully)
        1 - No supported AMD/Nvidia/Intel hardware detected, all installations were skipped, or an unexpected error occurred
        2 - Download failure (failed to download a driver from its source)
        3 - Installation failure (an installer returned a non-zero exit code)
#>

param (
    [switch]$Clean,          # kept for compatibility; ignored for AMD
    [switch]$WhatIf,         # show actions without executing
    [switch]$SkipChipset,    # do not install chipset driver
    [switch]$SkipGraphics,   # do not install graphics driver
    [string]$LogPath         # optional custom log file
)

# Preserve original console colors so they can be restored on every exit path.
$script:originalBackgroundColor = $Host.UI.RawUI.BackgroundColor
$script:originalForegroundColor = $Host.UI.RawUI.ForegroundColor

# Temporary folders created during the run; cleaned up on every exit path.
$script:tempFolders = @()

# Function to write colored messages (mirroring NvidiaInstall.ps1 style)
function Write-Log {
    param (
        [string]$Message,
        [string]$Color = 'White'
    )
    Write-Host -ForegroundColor $Color $Message
}

# Prompt for keypress before exiting (mirroring NvidiaInstall.ps1 style)
function Wait-ForKeyPress {
    Write-Host "Press any key to exit..."
    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
}

# Register a temporary folder so it is cleaned up on every exit path.
function Register-TempFolder {
    param (
        [string]$Path
    )
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $script:tempFolders += $Path
    }
}

# Remove all registered temporary folders.
function Remove-TempFolders {
    foreach ($folder in $script:tempFolders) {
        if ($folder -and (Test-Path -LiteralPath $folder)) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:tempFolders = @()
}

# Restore the console colors that were active when the script started.
function Reset-ConsoleColors {
    $Host.UI.RawUI.BackgroundColor = $script:originalBackgroundColor
    $Host.UI.RawUI.ForegroundColor = $script:originalForegroundColor
}

# Function to handle errors and prompt for keypress before exiting.
# Cleans up temporary folders and restores console colors before exiting.
function Exit-WithError {
    param (
        [string]$Message,
        [int]$ExitCode = 1
    )
    Write-Log -Message $Message -Color 'Red'
    Remove-TempFolders
    Reset-ConsoleColors
    Wait-ForKeyPress
    exit $ExitCode
}

# Retry a script block that throws or returns no data (up to MaxAttempts times).
function Invoke-WithRetry {
    param (
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Name,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 5
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $result = & $ScriptBlock
            if ($null -ne $result -and -not ($result -is [string] -and $result.Length -eq 0)) {
                return $result
            }
            throw 'No data returned.'
        } catch {
            if ($attempt -eq $MaxAttempts) { throw }
            Write-Log -Message "Warning: $Name failed (attempt $attempt/$MaxAttempts): $($_.Exception.Message). Retrying in ${DelaySeconds}s..." -Color 'Yellow'
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# TechPowerUp helper functions (from download-tpu.ps1 and download-tpu-radeon.ps1)
function Invoke-TpuWeb {
    param(
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Data = ''
    )
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe was not found. It ships with Windows 10/11 and PowerShell 7.'
    }
    $ProgressPreference = 'SilentlyContinue'
    $jar = Join-Path ([System.IO.Path]::GetTempPath()) ("tpu_cookies_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    try {
        $curlArgs = @('-sS', '--connect-timeout', '30', '--max-time', '120',
            '-b', $jar, '-c', $jar, '-A', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
        if ($Method -eq 'POST') {
            $curlArgs += @('-X', 'POST', '--data', $Data)
        }
        $curlArgs += $Url
        & curl.exe @curlArgs
    } finally {
        Remove-Item -LiteralPath $jar -Force -ErrorAction SilentlyContinue
    }
}

function Get-TpuRedirect {
    param(
        [string]$Url,
        [string]$Data
    )
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe was not found. It ships with Windows 10/11 and PowerShell 7.'
    }
    $ProgressPreference = 'SilentlyContinue'
    $jar = Join-Path ([System.IO.Path]::GetTempPath()) ("tpu_cookies_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    try {
        $headers = & curl.exe -sS -D - -o NUL --connect-timeout 30 --max-time 60 `
            -b $jar -c $jar -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -X POST --data $Data $Url 2>$null
        foreach ($line in $headers) {
            if ($line -match '^location:\s*(\S+)\s*$') {
                $loc = $Matches[1]
                if ($loc -notmatch '^https?://') { $loc = 'https://www.techpowerup.com' + $loc }
                return $loc
            }
        }
        return $null
    } finally {
        Remove-Item -LiteralPath $jar -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-TpuDownload {
    param(
        [string]$Url,
        [string]$Dest
    )
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe was not found. It ships with Windows 10/11 and PowerShell 7.'
    }
    $ProgressPreference = 'SilentlyContinue'
    $jar = Join-Path ([System.IO.Path]::GetTempPath()) ("tpu_cookies_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    try {
        & curl.exe -L -sS -f --connect-timeout 30 --max-time 3600 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -o $Dest $Url 2>$null
        return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Dest))
    } finally {
        Remove-Item -LiteralPath $jar -Force -ErrorAction SilentlyContinue
    }
}

function Get-AMDDriverInfoFromTpu {
    param(
        [string]$PageUrl
    )
    Write-Log -Message "Fetching $PageUrl ..." -Color 'Green'
    $page = (Invoke-WithRetry -Name "Fetch $PageUrl" -ScriptBlock { Invoke-TpuWeb $PageUrl }) -join "`n"
    if (-not $page) { throw "Failed to fetch $PageUrl" }

    $idMatch    = [regex]::Match($page, 'name="id" value="(\d+)"')
    $titleMatch = [regex]::Match($page, '<h3 class="title">\s*(.*?)\s*</h3>', 'Singleline')
    $fileMatch  = [regex]::Match($page, '<div class="filename" title="File Name">(.*?)</div>', 'Singleline')
    $shaMatch   = [regex]::Match($page, 'hash-name">SHA256:</div>\s*<div class="hash-value">([0-9A-Fa-f]{64})</div>', 'Singleline')

    if (-not $idMatch.Success) { throw 'Could not find a version "id" on the page.' }

    $id       = $idMatch.Groups[1].Value
    $version  = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { "id $id" }
    $fileName = if ($fileMatch.Success)  { $fileMatch.Groups[1].Value.Trim() } else { "techpowerup-$id.exe" }
    $sha256   = if ($shaMatch.Success)   { $shaMatch.Groups[1].Value.ToUpperInvariant() } else { '' }

    Write-Log -Message "Latest: $version (id=$id)" -Color 'Green'
    if ($sha256) { Write-Log -Message "Expected SHA256: $sha256" -Color 'Green' }

    return @{ Id = $id; Version = $version; FileName = $fileName; SHA256 = $sha256 }
}

function Download-AMDDriverFromTpu {
    param(
        [string]$PageUrl,
        [string]$DestinationFolder,
        [switch]$WhatIf
    )
    $info = Get-AMDDriverInfoFromTpu -PageUrl $PageUrl
    $id = $info.Id
    $fileName = $info.FileName
    $sha256 = $info.SHA256

    Write-Log -Message "Fetching mirror list ..." -Color 'Green'
    $mirrors = (Invoke-WithRetry -Name 'TechPowerUp mirror list' -ScriptBlock { Invoke-TpuWeb $PageUrl -Method POST -Data "id=$id" }) -join "`n"
    $buttons = [regex]::Matches($mirrors, '<button type="submit" name="server_id" value="(\d+)"[^>]*>(.*?)</button>', 'Singleline')
    if ($buttons.Count -eq 0) { throw 'Could not find any mirror servers.' }

    $servers = foreach ($b in $buttons) {
        $inner = $b.Groups[2].Value
        [pscustomobject]@{
            Id      = [int]$b.Groups[1].Value
            Name    = ([regex]::Match($inner, 'server-name">(.*?)</span>', 'Singleline')).Groups[1].Value
            Closest = $inner -match 'class="closest"'
        }
    }
    $servers = @($servers | Sort-Object -Property @{ Expression = 'Closest'; Descending = $true })

    if (-not (Test-Path -LiteralPath $DestinationFolder)) { New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null }
    $installerPath = Join-Path $DestinationFolder $fileName

    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would download AMD driver from TechPowerUp (mirror selection)" -Color 'Yellow'
        Write-Log -Message "WhatIf: Would save to $installerPath" -Color 'Yellow'
        return $installerPath
    }

    Write-Log -Message "Downloading AMD driver..." -Color 'Green'
    $success = $false
    foreach ($srv in $servers) {
        $tag = if ($srv.Closest) { ' (closest)' } else { '' }
        Write-Log -Message "Trying mirror: $($srv.Name)$tag" -Color 'Yellow'
        $cdl = Get-TpuRedirect $PageUrl ("id=$id&server_id=$($srv.Id)")
        if (-not $cdl) { Write-Log -Message "Warning: No download link returned from $($srv.Name)" -Color 'Yellow'; continue }
        Write-Log -Message "  CDN URL: $cdl" -Color 'Green'
        if (Invoke-TpuDownload $cdl $installerPath) {
            if (-not $sha256) {
                $success = $true
                break
            }
            $actual = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
            if ($actual -eq $sha256) {
                $success = $true
                break
            }
            Write-Log -Message "Warning: SHA256 mismatch from $($srv.Name) ($actual) - trying next mirror" -Color 'Yellow'
            Write-Log -Message "Removing failed download: $installerPath" -Color 'DarkGray'
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log -Message "Warning: Download failed from $($srv.Name)" -Color 'Yellow'
        }
    }
    if (-not $success) {
        throw 'All mirrors failed. Please retry later.'
    }
    Write-Log -Message "Download finished." -Color 'Green'
    return $installerPath
}

function Install-AMDDriver {
    param(
        [string]$InstallerPath,
        [ValidateSet('Chipset', 'Graphics')]
        [string]$DriverType = 'Chipset',
        [switch]$WhatIf
    )
    $installArgs = if ($DriverType -eq 'Chipset') { @('/install') } else { @('-install') }
    Write-Log -Message "Installing AMD $DriverType driver with arguments: $installArgs" -Color 'Green'
    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would execute Start-Process -FilePath '$InstallerPath' -ArgumentList $installArgs -Wait -PassThru" -Color 'Yellow'
        return 0
    }
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        if ($proc.ExitCode -in 2, 3010) {
            Write-Log -Message "AMD installer exited with code $($proc.ExitCode). Installation succeeded but a reboot is required." -Color 'Yellow'
            return 0
        }
        Write-Log -Message "AMD installer exited with code $($proc.ExitCode). The installation may not have completed successfully." -Color 'Yellow'
        return 3
    }
    Write-Log -Message "AMD installation completed successfully." -Color 'Green'
    return 0
}

function Get-NvidiaDriverInfo {
    param(
        [Parameter(Mandatory)]$GPU
    )
    [System.Net.ServicePointManager]::SecurityProtocol = 3072 -bor 768 -bor 192

    # Device ID lookup (same as original)
    $deviceId = if ($GPU.PNPDeviceID -match 'DEV_([0-9A-F]{4})') { $matches[1] }

    $pciName = $null
    if ($deviceId) {
        try {
            $content = Invoke-WithRetry -Name 'PCI device name lookup' -MaxAttempts 2 -DelaySeconds 2 -ScriptBlock {
                $req = [System.Net.HttpWebRequest]::Create("https://pci-ids.ucw.cz/read/PC/10de/$deviceId")
                $req.Timeout = 10000
                $resp = $req.GetResponse()
                try {
                    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                    $reader.ReadToEnd()
                } finally {
                    $resp.Close()
                }
            }
            if ($content -match 'Name:\s*([^<]*)') {
                $pciName = $matches[1].Trim()
            }
        } catch {
            Write-Log -Message "Warning: Could not look up PCI device name ($($_.Exception.Message))" -Color 'Yellow'
        }
    }

    $seriesName = $null
    if ($deviceId) {
        $id = [Convert]::ToInt32($deviceId, 16)
        $seriesName = switch ($true) {
            { $id -ge 0x2B00 -and $id -le 0x2FFF } { "NVIDIA GeForce RTX 50 Series" }
            { $id -ge 0x2600 -and $id -le 0x2AFF } { "NVIDIA GeForce RTX 40 Series" }
            { $id -ge 0x2200 -and $id -le 0x25FF } { "NVIDIA GeForce RTX 30 Series" }
            { $id -ge 0x1E00 -and $id -le 0x1F7F -and $id -ne 0x1F0A } { "NVIDIA GeForce RTX 20 Series" }
            { $id -eq 0x1F0A -or ($id -ge 0x1F80 -and $id -le 0x21FF) } { "NVIDIA GeForce GTX 16 Series" }
            { $id -ge 0x1000 -and $id -le 0x17FF } { "NVIDIA GeForce GTX 10 Series" }
        }
    }

    $gpuName = $pciName, $seriesName, $GPU.Name, $GPU.Description, $GPU.Caption | Where-Object { $_ } | Select-Object -First 1

    Write-Log -Message "Nvidia card detected: $gpuName" -Color 'Green'

    $psid = $null
    if ($deviceId) {
        $id = [Convert]::ToInt32($deviceId, 16)
        $psid = switch ($true) {
            { $id -ge 0x2B00 -and $id -le 0x2FFF } { 131 }
            { $id -ge 0x2600 -and $id -le 0x2AFF } { 127 }
            { $id -ge 0x2200 -and $id -le 0x25FF } { 120 }
            { $id -ge 0x1E00 -and $id -le 0x1F7F -and $id -ne 0x1F0A } { 107 }
            { $id -eq 0x1F0A -or ($id -ge 0x1F80 -and $id -le 0x21FF) } { 112 }
            { $id -ge 0x1000 -and $id -le 0x17FF } { 104 }
        }
    }

    if (-not $psid) {
        $psid = switch -Wildcard ($gpuName) {
            '*RTX 50*'  { 131 }
            '*RTX 40*'  { 127 }
            '*RTX 30*'  { 120 }
            '*RTX 20*'  { 107 }
            '*GTX 16*'  { 112 }
            '*GTX 10*'  { 104 }
            default     { 127 }
        }
    }

    Write-Log -Message "Product series ID`t$psid" -Color 'Green'

    $apiUrl = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=$psid&osID=57&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"

    Write-Log -Message "Checking for latest driver version..." -Color 'Green'
    try {
        $response = Invoke-WithRetry -Name 'Nvidia driver service' -ScriptBlock {
            Invoke-WebRequest -Uri $apiUrl -Method GET -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        }
        $json = $response.Content | ConvertFrom-Json
    } catch {
        throw 'Failed to contact Nvidia driver service.'
    }

    if ($json.Success -ne "1" -or -not $json.IDS) {
        throw 'Failed to retrieve driver information from Nvidia.'
    }

    $version = $json.IDS[0].downloadInfo.Version
    $downloadUrl = $json.IDS[0].downloadInfo.DownloadURL

    Write-Log -Message "Latest version`t`t$version" -Color 'Green'

    return @{ Version = $version; DownloadUrl = $downloadUrl; GpuName = $gpuName }
}

function Download-NvidiaDriver {
    param(
        [Parameter(Mandatory)][string]$DownloadUrl,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [switch]$WhatIf
    )
    $dlFile = Join-Path $DestinationFolder "$Version.exe"
    Write-Log -Message "Downloading the latest version to $dlFile" -Color 'Green'

    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would download Nvidia driver from $DownloadUrl to $dlFile" -Color 'Yellow'
        return $dlFile
    }

    try {
        Start-BitsTransfer -Source $DownloadUrl -Destination $dlFile -ErrorAction Stop
    } catch {
        throw 'Download failed.'
    }

    Write-Log -Message "Download finished." -Color 'Green'
    return $dlFile
}

function Install-NvidiaDriver {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [switch]$Clean,
        [switch]$WhatIf
    )
    $installArgs = @("/s")
    if ($Clean.IsPresent) {
        $installArgs += "-clean"
    }

    Write-Log -Message "Installing Nvidia driver with arguments: $installArgs" -Color 'Green'
    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would execute Start-Process -FilePath '$InstallerPath' -ArgumentList $installArgs -Wait -PassThru" -Color 'Yellow'
        return 0
    }

    $proc = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Log -Message "Nvidia installer exited with code $($proc.ExitCode). The installation may not have completed successfully." -Color 'Yellow'
        return 3
    }
    Write-Log -Message "Nvidia installation completed successfully." -Color 'Green'
    return 0
}

function Get-IntelDriverInfo {
    Write-Log -Message "Checking for latest Intel graphics driver..." -Color 'Green'
     
    $intelPageUrl = "https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html"
     
    try {
        $page = (Invoke-WithRetry -Name "Fetch Intel driver page" -ScriptBlock {
            Invoke-WebRequest -Uri $intelPageUrl -Method GET -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop -Headers @{ Referer = "https://www.intel.com/"; 'User-Agent' = 'curl/8.18.0'; Accept = '*/*' }
        })
         
        # Extract the full download URL from page (look for .exe download links)
        $urlMatch = $page.Content -match '(?:href|data-file)["\s]*= ["'']([^"'']*gfx_win[^"'']*\.exe)["'']'
        if ($urlMatch) {
            $downloadUrl = $Matches[1]
            if ($downloadUrl -notmatch '^https?://') {
                $downloadUrl = 'https://downloadmirror.intel.com/' + $downloadUrl.TrimStart('/')
            }
        } else {
            # Fallback: look for any full .exe URL that points at Intel's download mirror
            $exeMatches = [regex]::Matches($page.Content, 'https://downloadmirror\.intel\.com/[^"'' ]+\.exe', 'IgnoreCase')
            if ($exeMatches.Count -gt 0) {
                $downloadUrl = $exeMatches[0].Value
            } else {
                throw 'Could not find Intel driver download URL on download page'
            }
        }

        # Extract filename from the URL (e.g., gfx_win_101.8864.exe)
        $fileName = [System.IO.Path]::GetFileName($downloadUrl)
         
        # Extract version from filename if possible (e.g., gfx_win_101.8864.exe -> 101.8864)
        $version = ''
        if ($fileName -match '[\._](\d+\.\d+)\.exe$') {
            $version = $Matches[1]
        }
         
        Write-Log -Message "Latest Intel driver: $fileName (version: $version)" -Color 'Green'
        return @{ FileName = $fileName; Version = $version; DownloadUrl = $downloadUrl }
    } catch {
        Write-Log -Message "Failed to get Intel driver information: $($_.Exception.Message)" -Color 'Red'
        throw
    }
}

function Download-IntelDriver {
    param(
        [Parameter(Mandatory)][string]$DownloadUrl,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [switch]$WhatIf
    )
    
    $destPath = Join-Path $DestinationFolder $FileName
    
    Write-Log -Message "Downloading Intel driver $FileName to $destPath" -Color 'Green'
    
    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would download Intel driver from $DownloadUrl to $destPath" -Color 'Yellow'
        return $destPath
    }
    
    try {
        # Ensure destination folder exists
        if (-not (Test-Path -LiteralPath $DestinationFolder)) {
            New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
        }
        
        # Download with referer header
        & curl.exe -L -sS -f --connect-timeout 30 --max-time 3600 `
            -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' `
            -e 'http://www.intel.com/' `
            -o $destPath $DownloadUrl 2>$null
        
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $destPath)) {
            throw 'Download failed'
        }
        
        Write-Log -Message "Intel driver download finished." -Color 'Green'
        return $destPath
    } catch {
        Write-Log -Message "Intel driver download failed: $($_.Exception.Message)" -Color 'Red'
        throw
    }
}

function Install-IntelDriver {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [switch]$WhatIf
    )
     
    # Build install arguments with critical switches for unattended installation
    $driverDir = Split-Path -Path $InstallerPath -Parent
    $logPath = Join-Path $driverDir "IntelGFX.log"
    $installArgs = @("-s", "--terminateProcesses", "--report", $logPath)
    
    # Optionally add --noExtras to avoid potential conflicts with additional components
    # $installArgs += "--noExtras"
    
    Write-Log -Message "Installing Intel driver with arguments: $installArgs" -Color 'Green'
     
    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would execute Start-Process -FilePath '$InstallerPath' -ArgumentList $installArgs -Wait -PassThru" -Color 'Yellow'
        return 0
    }
     
    try {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru
        $rawCode = $proc.ExitCode
        $code = $rawCode
        if ($code -ge 1000) { $code -= 1000 }

        if ($code -eq 0) {
            Write-Log -Message "Intel installation completed successfully." -Color 'Green'
            return 0
        }

        # Reboot/shutdown-required codes are successful installs per Intel's readme
        if ($code -in 2, 14, 17, 18) {
            Write-Log -Message "Intel installer exited with code $rawCode (documented code $code). Installation succeeded but a reboot is required." -Color 'Yellow'
            return 0
        }

        Write-Log -Message "Intel installer exited with code $rawCode (documented code $code)." -Color 'Yellow'

        # Provide specific guidance based on Intel's documented exit codes
        switch ($code) {
            1  { Write-Log -Message "Generic error. Refer to the installation log file for details." -Color 'Red' }
            5  { Write-Log -Message "Platform not supported. Check Windows version compatibility." -Color 'Red' }
            6  { Write-Log -Message "Installer was closed by the user before the installation could complete." -Color 'Red' }
            7  { Write-Log -Message "Invalid command. Check the command-line arguments." -Color 'Red' }
            8  { Write-Log -Message "Driver file not found. The installer could not find a suitable driver." -Color 'Red' }
            9  { Write-Log -Message "Driver digital signature missing." -Color 'Red' }
            10 { Write-Log -Message "Extras digital signature missing." -Color 'Red' }
            11 { Write-Log -Message "Insufficient disk space. Clean temporary files or specify different temp location." -Color 'Red' }
            13 { Write-Log -Message "Reboot required before installation can continue." -Color 'Red' }
            15 { Write-Log -Message "Close required processes before installation. Consider using --terminateProcesses switch." -Color 'Red' }
            16 { Write-Log -Message "Another installation in progress. Wait for other installations to complete." -Color 'Red' }
            default { Write-Log -Message "Refer to Intel installation_readme.txt for exit code $code details." -Color 'Red' }
        }

        return 3
    } catch {
        Write-Log -Message "Intel driver installation failed: $($_.Exception.Message)" -Color 'Red'
        return 3
    }
}

try {
    # Hardware Detection
    Write-Log -Message "Detecting hardware..." -Color 'Green'

    # AMD Chipset detection (specific devices: SM Bus Controller and/or PCI Encryption/Decryption Controller)
    $amdChipsetDevices = Get-CimInstance -Class Win32_PnPEntity -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.PNPDeviceID -like "PCI\VEN_1022*" -and 
            ($_.Name -like "*SM Bus Controller*" -or $_.Name -like "*PCI Encryption/Decryption Controller*")
        }
    $hasAmdChipset = ($null -ne $amdChipsetDevices -and $amdChipsetDevices.Count -gt 0)

    # AMD GPU detection
    $amdGpuDevices = Get-CimInstance -Class Win32_PnPEntity -ErrorAction SilentlyContinue | 
        Where-Object { $_.PNPDeviceID -like "PCI\VEN_1002*" }
    $hasAmdGpu = ($null -ne $amdGpuDevices -and $amdGpuDevices.Count -gt 0)

    # Nvidia GPU detection (using original logic from NvidiaInstall.ps1)
    $nvidiaGpu = Get-CimInstance -Class CIM_VideoController | Where-Object { $_.PNPDeviceID -like "PCI\VEN_10DE*" } | Select-Object -First 1
    $hasNvidiaGpu = ($null -ne $nvidiaGpu)

    # Intel GPU detection
    $intelGpu = Get-CimInstance -Class CIM_VideoController | Where-Object { $_.PNPDeviceID -like "PCI\VEN_8086*" } | Select-Object -First 1
    $hasIntelGpu = ($null -ne $intelGpu)

    Write-Log -Message "AMD Chipset detected: $hasAmdChipset" -Color 'Green'
    Write-Log -Message "AMD GPU detected: $hasAmdGpu" -Color 'Green'
    Write-Log -Message "Nvidia GPU detected: $hasNvidiaGpu" -Color 'Green'
    Write-Log -Message "Intel GPU detected: $hasIntelGpu" -Color 'Green'

    # Determine What to Install
    $installChipset = $hasAmdChipset -and -not $SkipChipset
    $installGraphics = $hasAmdGpu -and -not $SkipGraphics
    $installNvidia = $hasNvidiaGpu
    $installIntel = $hasIntelGpu

    $amdExitCodes = @()
    $nvidiaExitCode = 0
    $intelExitCode = 0

    # Install AMD chipset first (if needed and not skipped)
    if ($installChipset) {
        Write-Log -Message "AMD chipset detected. Proceeding with AMD chipset driver installation." -Color 'Green'
        $tempFolder = "$env:TEMP\AMDChipsetInstall_$([System.Guid]::NewGuid().ToString('N'))"
        Register-TempFolder $tempFolder
        try {
            $installerPath = Download-AMDDriverFromTpu -PageUrl 'https://www.techpowerup.com/download/amd-ryzen-chipset-drivers/' -DestinationFolder $tempFolder -WhatIf:$WhatIf
            $exitCode = Install-AMDDriver -InstallerPath $installerPath -DriverType Chipset -WhatIf:$WhatIf
            $amdExitCodes += $exitCode
        } catch {
            Write-Log -Message "AMD chipset driver installation failed: $($_.Exception.Message)" -Color 'Red'
            $amdExitCodes += 2
        } finally {
            if (-not $WhatIf) {
                Write-Log -Message "Cleaning up temporary folder: $tempFolder" -Color 'DarkGray'
                Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Install AMD graphics second (if needed and not skipped)
    if ($installGraphics) {
        Write-Log -Message "AMD GPU detected. Proceeding with AMD graphics driver installation." -Color 'Green'
        $tempFolder = "$env:TEMP\AMDGraphicsInstall_$([System.Guid]::NewGuid().ToString('N'))"
        Register-TempFolder $tempFolder
        try {
            $installerPath = Download-AMDDriverFromTpu -PageUrl 'https://www.techpowerup.com/download/amd-radeon-graphics-drivers/' -DestinationFolder $tempFolder -WhatIf:$WhatIf
            $exitCode = Install-AMDDriver -InstallerPath $installerPath -DriverType Graphics -WhatIf:$WhatIf
            $amdExitCodes += $exitCode
            Start-Sleep -Seconds 5
        } catch {
            Write-Log -Message "AMD graphics driver installation failed: $($_.Exception.Message)" -Color 'Red'
            $amdExitCodes += 2
        } finally {
            if (-not $WhatIf) {
                Write-Log -Message "Cleaning up temporary folder: $tempFolder" -Color 'DarkGray'
                Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Install NVIDIA drivers if NVIDIA GPU is present (regardless of AMD)
    if ($installNvidia) {
        Write-Log -Message "Nvidia hardware detected. Proceeding with Nvidia driver installation." -Color 'Green'

        # Reset console colors for Nvidia section (as in original)
        $Host.UI.RawUI.BackgroundColor = 'DarkBlue'
        $Host.UI.RawUI.ForegroundColor = 'White'
        Clear-Host

        try {
            $info = Get-NvidiaDriverInfo -GPU $nvidiaGpu

            # Temporary folder handling (adapted from original)
            $folder = if ($LogPath -and (Split-Path -Path $LogPath -Parent)) { Split-Path -Path $LogPath -Parent } else { "$env:temp" }
            $nvidiaTempFolder = "$folder\NVIDIA_$([System.Guid]::NewGuid().ToString('N'))"
            Register-TempFolder $nvidiaTempFolder
            New-Item -Path $nvidiaTempFolder -ItemType Directory -Force | Out-Null

            $dlFile = Download-NvidiaDriver -DownloadUrl $info.DownloadUrl -Version $info.Version -DestinationFolder $nvidiaTempFolder -WhatIf:$WhatIf
            $nvidiaExitCode = Install-NvidiaDriver -InstallerPath $dlFile -Clean:$Clean -WhatIf:$WhatIf
            Start-Sleep -Seconds 5
        } catch {
            Write-Log -Message "Nvidia driver installation failed: $($_.Exception.Message)" -Color 'Red'
            $nvidiaExitCode = 2
        } finally {
            if (-not $WhatIf) {
                Write-Log -Message "Cleaning up temporary folder: $nvidiaTempFolder" -Color 'DarkGray'
                Remove-Item -LiteralPath $nvidiaTempFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Install Intel drivers if Intel GPU is present (regardless of AMD/NVIDIA)
    if ($installIntel) {
        Write-Log -Message "Intel hardware detected. Proceeding with Intel driver installation." -Color 'Green'

        try {
            $info = Get-IntelDriverInfo

            # Temporary folder handling
            $folder = if ($LogPath -and (Split-Path -Path $LogPath -Parent)) { Split-Path -Path $LogPath -Parent } else { "$env:temp" }
            $intelTempFolder = "$folder\INTEL_$([System.Guid]::NewGuid().ToString('N'))"
            Register-TempFolder $intelTempFolder
            New-Item -Path $intelTempFolder -ItemType Directory -Force | Out-Null

            $dlFile = Download-IntelDriver -DownloadUrl $info.DownloadUrl -FileName $info.FileName -DestinationFolder $intelTempFolder -WhatIf:$WhatIf
            $intelExitCode = Install-IntelDriver -InstallerPath $dlFile -WhatIf:$WhatIf
            Start-Sleep -Seconds 5
        } catch {
            Write-Log -Message "Intel driver installation failed: $($_.Exception.Message)" -Color 'Red'
            $intelExitCode = 2
        } finally {
            if ($intelTempFolder) {
                $intelLog = Join-Path $intelTempFolder "IntelGFX.log"
                if (Test-Path -LiteralPath $intelLog) {
                    $logDest = Split-Path -Path $intelTempFolder -Parent
                    Copy-Item -LiteralPath $intelLog -Destination $logDest -Force
                    Write-Log -Message "Intel installation log saved to $(Join-Path $logDest 'IntelGFX.log')" -Color 'DarkGray'
                }
                if (-not $WhatIf) {
                    Write-Log -Message "Cleaning up temporary folder: $intelTempFolder" -Color 'DarkGray'
                    Remove-Item -LiteralPath $intelTempFolder -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # Determine overall exit code: first non-zero across all installed drivers (chipset → graphics → NVIDIA → Intel)
    $allExitCodes = @($amdExitCodes) + @($nvidiaExitCode) + @($intelExitCode)
    $overallExitCode = 0
    foreach ($code in $allExitCodes) {
        if ($code -ne 0) {
            $overallExitCode = $code
            break
        }
    }

    # If any drivers were installed, wait and exit with the combined exit code
    if ($installChipset -or $installGraphics -or $installNvidia -or $installIntel) {
        # Post-install wait and cleanup (mirroring Nvidia script)
        Start-Sleep -Seconds 3
        $Host.UI.RawUI.BackgroundColor = 'Green'
        Write-Host -ForegroundColor Black -BackgroundColor Green "Driver installed. Press any button to exit."
        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null

        exit $overallExitCode
    }

    # If we got here and nothing was installed, error out
    if (-not $installChipset -and -not $installGraphics -and -not $installNvidia -and -not $installIntel) {
        Exit-WithError -Message "No supported AMD/Nvidia/Intel hardware detected or all installations were skipped." -ExitCode 1
    }
} catch {
    Exit-WithError -Message "Unexpected error: $($_.Exception.Message)" -ExitCode 1
}
