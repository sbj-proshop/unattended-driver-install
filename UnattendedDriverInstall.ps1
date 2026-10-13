<#
.SYNOPSIS
    Unattended driver installer for AMD, Nvidia and Intel hardware.
    
.DESCRIPTION
    This script detects AMD, Nvidia and Intel hardware in the system and installs the appropriate drivers.
    For AMD hardware (chipset or GPU), it downloads and installs the latest drivers from AMD directly.
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

.PARAMETER CacheRoot
    Folder holding the shared driver package cache. Defaults to the application share.
    Installers are stored there so a rebuild only costs a version probe, not a full download.

.PARAMETER NoCache
    Ignore the cache and download every driver directly from the vendor.

.EXAMPLE
    .\UnattendedDriverInstall.ps1 -WhatIf
    Shows what the script would do without executing.

.EXAMPLE
    .\UnattendedDriverInstall.ps1 -SkipChipset
    Installs only the AMD graphics driver (if AMD GPU is present).

.NOTES
    Author: SBJ - Proshop a/s
    Version: 1.4

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
    [string]$LogPath,        # optional custom log file
    [string]$CacheRoot = '\\DUTZO_WDS\ApplicationShare\DriverCache',
    [switch]$NoCache         # bypass the cache and always download
)

# Preserve original console colors so they can be restored on every exit path.
$script:originalBackgroundColor = $Host.UI.RawUI.BackgroundColor
$script:originalForegroundColor = $Host.UI.RawUI.ForegroundColor

# Temporary folders created during the run; cleaned up on every exit path.
$script:tempFolders = @()

# Path of the run log. Set by Initialize-LogFile before any other work.
$script:LogFilePath = $null

# Open the run log. The script is tested on build machines where the console scrolls past
# and is never captured, so every message also goes to a file.
function Initialize-LogFile {
    param (
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $env:TEMP "UnattendedDriverInstall_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    }
    try {
        $parent = Split-Path -Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -LiteralPath $Path -Value "Unattended driver install started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME" -ErrorAction Stop
        $script:LogFilePath = $Path
        Write-Host -ForegroundColor DarkGray "Logging to $Path"
    } catch {
        Write-Host -ForegroundColor Yellow "Could not open log file ${Path}: $($_.Exception.Message)"
    }
}

# Function to write colored messages (mirroring NvidiaInstall.ps1 style)
function Write-Log {
    param (
        [string]$Message,
        [string]$Color = 'White'
    )
    Write-Host -ForegroundColor $Color $Message
    if ($script:LogFilePath) {
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value "$(Get-Date -Format 'HH:mm:ss')  $Message" -ErrorAction Stop
        } catch {
        }
    }
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

# Fetch a page body with curl.exe. Supply Referer for hosts that reject direct links.
# Returns the response body as an array of lines.
function Invoke-CurlWeb {
    param(
        [string]$Url,
        [string]$Referer = ''
    )
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe was not found. It ships with Windows 10/11 and PowerShell 7.'
    }
    $ProgressPreference = 'SilentlyContinue'
    $curlArgs = @('-sS', '--connect-timeout', '30', '--max-time', '120',
        '-A', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
    if ($Referer) {
        $curlArgs += @('-e', $Referer)
    }
    $curlArgs += $Url
    & curl.exe @curlArgs
}

# Download a file with curl.exe. Supply Referer for hosts that reject direct links.
# Returns $true when curl succeeded and the file exists.
function Invoke-CurlDownload {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Referer = ''
    )
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe was not found. It ships with Windows 10/11 and PowerShell 7.'
    }
    $ProgressPreference = 'SilentlyContinue'
    $curlArgs = @('-L', '-sS', '-f', '--connect-timeout', '30', '--max-time', '7200',
        '-A', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
    if ($Referer) {
        $curlArgs += @('-e', $Referer)
    }
    $curlArgs += @('-o', $Dest, $Url)
    & curl.exe @curlArgs 2>$null
    return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Dest))
}

# Publisher fragments expected in the Authenticode subject of each vendor's installer.
$script:AmdPublisher = 'Advanced Micro Devices'
$script:NvidiaPublisher = 'NVIDIA'
$script:IntelPublisher = 'Intel'

# Vendors publish no checksum beside these downloads, so the Authenticode signature is the
# integrity gate. Cached copies are checked too: a corrupt file on the share carries the
# right name and the wrong bytes, and would otherwise reach every machine instead of one.
function Assert-InstallerSignature {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$ExpectedPublisher
    )
    $fileName = [System.IO.Path]::GetFileName($InstallerPath)
    $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($signature.Status -ne 'Valid') {
        throw "$fileName failed Authenticode validation (status: $($signature.Status))."
    }
    $subject = $signature.SignerCertificate.Subject
    if ($subject -notmatch [regex]::Escape($ExpectedPublisher)) {
        throw "$fileName is signed by an unexpected publisher: $subject"
    }
    Write-Log -Message "Signature verified: $subject" -Color 'Green'
}

# --- Driver package cache -------------------------------------------------------------
# Installers are kept on the application share so a rebuild costs a version probe instead
# of a full download. The file name carries the version, so the directory listing is the
# whole index and there is no metadata file to fall out of step with the files.

$script:CacheEnabled = $false
$script:CacheRootPath = $null
$script:CacheKeepVersions = 2

# Confirm the cache root is reachable and writable. A cache that cannot be reached must
# cost bandwidth, never a build, so every failure here falls back to a direct download.
function Initialize-DriverCache {
    param(
        [string]$Root,
        [switch]$Disabled
    )
    if ($Disabled) {
        Write-Log -Message "CACHE-OFF  Disabled by -NoCache." -Color 'DarkGray'
        return
    }
    if ([string]::IsNullOrWhiteSpace($Root)) {
        Write-Log -Message "CACHE-OFF  No cache root configured." -Color 'DarkGray'
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $Root)) {
            New-Item -ItemType Directory -Path $Root -Force -ErrorAction Stop | Out-Null
        }
        $probePath = Join-Path $Root ".writetest-$([System.Guid]::NewGuid().ToString('N'))"
        Set-Content -LiteralPath $probePath -Value 'probe' -ErrorAction Stop
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        $script:CacheRootPath = $Root
        $script:CacheEnabled = $true
        Write-Log -Message "CACHE-ON   $Root (read/write)" -Color 'Green'
    } catch {
        Write-Log -Message "CACHE-OFF  $Root is unavailable: $($_.Exception.Message)" -Color 'Yellow'
        Write-Log -Message "Drivers will be downloaded directly from the vendor." -Color 'Yellow'
    }
}

# Full path of a cached installer, or $null when it is not cached.
function Get-CachedDriverPath {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$FileName
    )
    if (-not $script:CacheEnabled) { return $null }
    $candidate = Join-Path (Join-Path $script:CacheRootPath $Category) $FileName
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

# Full path of the most recently cached installer in a category, or $null when empty.
function Get-NewestCachedDriverPath {
    param(
        [Parameter(Mandatory)][string]$Category
    )
    if (-not $script:CacheEnabled) { return $null }
    $categoryPath = Join-Path $script:CacheRootPath $Category
    if (-not (Test-Path -LiteralPath $categoryPath)) { return $null }
    $newest = Get-ChildItem -LiteralPath $categoryPath -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { return $newest.FullName }
    return $null
}

# Keep the current version and one fallback.
# Why ordered by write time: AMD (25.9.1), Nvidia (581.57) and Intel (101.8864) version
# strings share no format that sorts correctly, and acquisition order is what is wanted.
# Save-DriverToCache stamps each entry as it lands, so the write time is the time it was
# cached rather than whatever timestamp the download arrived with.
function Remove-StaleCacheEntries {
    param(
        [Parameter(Mandatory)][string]$Category
    )
    if (-not $script:CacheEnabled) { return }
    $categoryPath = Join-Path $script:CacheRootPath $Category
    if (-not (Test-Path -LiteralPath $categoryPath)) { return }

    $stale = Get-ChildItem -LiteralPath $categoryPath -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $script:CacheKeepVersions
    foreach ($entry in $stale) {
        try {
            Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
            Write-Log -Message "PRUNE      $($entry.Name)" -Color 'DarkGray'
        } catch {
            Write-Log -Message "PRUNE      Skipped $($entry.Name), in use by another machine." -Color 'DarkGray'
        }
    }

    $abandoned = Get-ChildItem -LiteralPath $categoryPath -Filter '*.part' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) }
    foreach ($entry in $abandoned) {
        Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue
    }
}

# Copy a verified installer into the cache.
# Why the staging name: several workstations image at once and race for the same new
# version. The copy lands on a per-machine temporary name and is renamed into place, so a
# half-written file never carries a name that claims to be complete. Losing that race is a
# normal outcome, not an error.
function Save-DriverToCache {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$FileName,
        [switch]$WhatIf
    )
    if ($WhatIf -or -not $script:CacheEnabled) { return }
    try {
        $categoryPath = Join-Path $script:CacheRootPath $Category
        if (-not (Test-Path -LiteralPath $categoryPath)) {
            New-Item -ItemType Directory -Path $categoryPath -Force -ErrorAction Stop | Out-Null
        }
        $finalPath = Join-Path $categoryPath $FileName
        if (Test-Path -LiteralPath $finalPath) {
            Write-Log -Message "STORE      $FileName was already cached." -Color 'DarkGray'
            return
        }

        $stagingPath = Join-Path $categoryPath "$FileName.$env:COMPUTERNAME-$([System.Guid]::NewGuid().ToString('N')).part"
        Copy-Item -LiteralPath $SourcePath -Destination $stagingPath -Force -ErrorAction Stop
        try {
            Move-Item -LiteralPath $stagingPath -Destination $finalPath -ErrorAction Stop

            # Why the file is restamped: pruning keeps the newest entries by write time, and
            # a copied file inherits the source timestamp. Start-BitsTransfer can give the
            # downloaded file the server's Last-Modified date, which would make a brand new
            # package look like the oldest one and get it pruned first.
            $cached = Get-Item -LiteralPath $finalPath
            $cached.LastWriteTime = Get-Date
            Write-Log -Message "STORE      $finalPath ($([math]::Round($cached.Length / 1MB, 1)) MB)" -Color 'Green'
        } catch {
            Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
            Write-Log -Message "STORE      Another machine cached $FileName first." -Color 'DarkGray'
        }

        Remove-StaleCacheEntries -Category $Category
    } catch {
        Write-Log -Message "STORE      Could not cache ${FileName}: $($_.Exception.Message)" -Color 'Yellow'
    }
}

# Local, signature-verified copy of a cached installer, or $null when the cache holds no
# usable copy and the caller must download. A cached file that fails verification is
# deleted, so the next machine to ask gets a clean one instead of the same bad bytes.
#
# The installer always runs from the local temp folder and never from the share, so that
# extraction never writes beside the cached copy.
function Get-CachedDriverCopy {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [Parameter(Mandatory)][string]$Publisher,
        [switch]$WhatIf
    )
    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would look for $Category/$FileName in the cache before downloading." -Color 'Yellow'
        return $null
    }
    if (-not $script:CacheEnabled) { return $null }

    $cachedPath = Get-CachedDriverPath -Category $Category -FileName $FileName
    if (-not $cachedPath) {
        Write-Log -Message "MISS       $Category/$FileName is not cached." -Color 'DarkGray'
        return $null
    }

    $sizeMb = [math]::Round((Get-Item -LiteralPath $cachedPath).Length / 1MB, 1)
    Write-Log -Message "HIT        $cachedPath ($sizeMb MB)" -Color 'Green'

    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    }
    $localPath = Join-Path $DestinationFolder $FileName
    try {
        Copy-Item -LiteralPath $cachedPath -Destination $localPath -Force -ErrorAction Stop
        Assert-InstallerSignature -InstallerPath $localPath -ExpectedPublisher $Publisher
        return $localPath
    } catch {
        Write-Log -Message "Cached $FileName is unusable: $($_.Exception.Message)" -Color 'Yellow'
        Write-Log -Message "Discarding it and downloading from the vendor." -Color 'Yellow'
        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $cachedPath -Force -ErrorAction SilentlyContinue
        return $null
    }
}

# Last resort when the vendor version probe fails: install the newest cached package.
# Returns $null when nothing is cached, leaving the caller to report the original failure.
function Resolve-CachedFallbackPackage {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [Parameter(Mandatory)][string]$Publisher
    )
    $cachedPath = Get-NewestCachedDriverPath -Category $Category
    if (-not $cachedPath) { return $null }

    $fileName = [System.IO.Path]::GetFileName($cachedPath)
    Write-Log -Message "FALLBACK   Version probe failed; installing newest cached package $fileName." -Color 'Yellow'
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    }
    $localPath = Join-Path $DestinationFolder $fileName
    Copy-Item -LiteralPath $cachedPath -Destination $localPath -Force -ErrorAction Stop
    Assert-InstallerSignature -InstallerPath $localPath -ExpectedPublisher $Publisher
    return $localPath
}

# AMD's driver page, which names the current Adrenalin release and is also the Referer
# that drivers.amd.com demands on every download.
$script:AmdDriverPageUrl = 'https://www.amd.com/en/support/download/drivers.html'
$script:AmdChipsetVersionUrl = 'https://drivers.amd.com/drivers/installer/chipset/version.txt'
$script:AmdChipsetInstallerUrl = 'https://drivers.amd.com/drivers/installer/chipset/AMD_Chipset_Software.exe'

# Read the current Adrenalin release from the AMD driver page and build the download URL
# for the full package. Returns a hashtable with Url, FileName and Version.
#
# Why "-c": AMD splits the Adrenalin package by driver branch. The "-a" branch carries the
# Ryzen desktop integrated GPUs (Raphael 164E, Granite Ridge 13C0) and RDNA2; the "-b" branch
# carries RDNA3/RDNA4 and the Phoenix APUs. A machine with a Ryzen desktop CPU and a current
# Radeon card spans both, and only "-c" ships both branches. Picking "-a" or "-b" leaves one
# of the two devices on the Microsoft Basic Display Adapter.
function Get-AMDGraphicsDriverInfo {
    Write-Log -Message "Checking for latest AMD graphics driver..." -Color 'Green'
    $page = (Invoke-WithRetry -Name 'Fetch AMD driver page' -ScriptBlock { Invoke-CurlWeb $script:AmdDriverPageUrl }) -join "`n"
    if (-not $page) { throw "Failed to fetch $script:AmdDriverPageUrl" }

    $versionMatch = [regex]::Match($page, 'adrenalin-edition-(\d+(?:\.\d+)+)-minimalsetup', 'IgnoreCase')
    if (-not $versionMatch.Success) {
        throw 'Could not read the Adrenalin release from the AMD driver page. The page layout may have changed.'
    }

    $version = $versionMatch.Groups[1].Value
    $fileName = "whql-amd-software-adrenalin-edition-$version-win11-c.exe"
    Write-Log -Message "Latest: AMD Software Adrenalin Edition $version ($fileName)" -Color 'Green'
    return @{ Url = "https://drivers.amd.com/drivers/$fileName"; FileName = $fileName; Version = $version }
}

# Read the current chipset driver version from AMD's plain-text version file.
# Returns a hashtable with Url, FileName and Version.
function Get-AMDChipsetDriverInfo {
    Write-Log -Message "Checking for latest AMD chipset driver..." -Color 'Green'
    $version = ((Invoke-WithRetry -Name 'Fetch AMD chipset version' -ScriptBlock { Invoke-CurlWeb $script:AmdChipsetVersionUrl -Referer $script:AmdDriverPageUrl }) -join '').Trim()
    if ($version -notmatch '^\d+(\.\d+)+$') {
        throw "AMD chipset version file returned an unexpected value: '$version'"
    }

    $fileName = "AMD_Chipset_Software_$version.exe"
    Write-Log -Message "Latest: AMD Chipset Software $version" -Color 'Green'
    return @{ Url = $script:AmdChipsetInstallerUrl; FileName = $fileName; Version = $version }
}

# Download an AMD installer. Returns the path it was saved to; the caller verifies it.
# Why the Referer: drivers.amd.com answers direct links with a 302 to its
# "Download Incomplete" page unless the AMD driver page is sent as the Referer.
function Download-AMDDriver {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [switch]$WhatIf
    )
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    }
    $installerPath = Join-Path $DestinationFolder $FileName

    if ($WhatIf) {
        Write-Log -Message "WhatIf: Would download $Url" -Color 'Yellow'
        Write-Log -Message "WhatIf: Would save to $installerPath" -Color 'Yellow'
        return $installerPath
    }

    Write-Log -Message "Downloading $FileName ..." -Color 'Green'
    Invoke-WithRetry -Name "Download $FileName" -ScriptBlock {
        if (-not (Invoke-CurlDownload $Url $installerPath -Referer $script:AmdDriverPageUrl)) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            throw "curl.exe could not download $Url"
        }
        $true
    } | Out-Null

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

# Identify the installed Nvidia card and the product series ID its drivers are published
# under. Resolved from the local PCI device ID, so it stays available when the version
# probe cannot reach Nvidia. Returns a hashtable with Psid and GpuName.
function Get-NvidiaProductSeries {
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

    return @{ Psid = $psid; GpuName = $gpuName }
}

# Ask Nvidia for the current driver release for a product series.
# Returns a hashtable with Version, FileName and DownloadUrl.
function Get-NvidiaDriverInfo {
    param(
        [Parameter(Mandatory)][int]$Psid
    )
    $apiUrl = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=$Psid&osID=57&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"

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

    return @{ Version = $version; FileName = "$version.exe"; DownloadUrl = $downloadUrl }
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
        
        if (-not (Invoke-CurlDownload $DownloadUrl $destPath -Referer 'http://www.intel.com/')) {
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
    Initialize-LogFile -Path $LogPath
    Initialize-DriverCache -Root $CacheRoot -Disabled:$NoCache

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
            $installerPath = $null
            try {
                $info = Get-AMDChipsetDriverInfo
                $installerPath = Get-CachedDriverCopy -Category 'amd-chipset' -FileName $info.FileName -DestinationFolder $tempFolder -Publisher $script:AmdPublisher -WhatIf:$WhatIf
                if (-not $installerPath) {
                    $installerPath = Download-AMDDriver -Url $info.Url -FileName $info.FileName -DestinationFolder $tempFolder -WhatIf:$WhatIf
                    if (-not $WhatIf) {
                        Assert-InstallerSignature -InstallerPath $installerPath -ExpectedPublisher $script:AmdPublisher
                        Save-DriverToCache -Category 'amd-chipset' -SourcePath $installerPath -FileName $info.FileName
                    }
                }
            } catch {
                Write-Log -Message "AMD chipset lookup or download failed: $($_.Exception.Message)" -Color 'Yellow'
                if (-not $WhatIf) {
                    $installerPath = Resolve-CachedFallbackPackage -Category 'amd-chipset' -DestinationFolder $tempFolder -Publisher $script:AmdPublisher
                }
                if (-not $installerPath) { throw }
            }

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
            $installerPath = $null
            try {
                $info = Get-AMDGraphicsDriverInfo
                $installerPath = Get-CachedDriverCopy -Category 'amd-graphics' -FileName $info.FileName -DestinationFolder $tempFolder -Publisher $script:AmdPublisher -WhatIf:$WhatIf
                if (-not $installerPath) {
                    $installerPath = Download-AMDDriver -Url $info.Url -FileName $info.FileName -DestinationFolder $tempFolder -WhatIf:$WhatIf
                    if (-not $WhatIf) {
                        Assert-InstallerSignature -InstallerPath $installerPath -ExpectedPublisher $script:AmdPublisher
                        Save-DriverToCache -Category 'amd-graphics' -SourcePath $installerPath -FileName $info.FileName
                    }
                }
            } catch {
                Write-Log -Message "AMD graphics lookup or download failed: $($_.Exception.Message)" -Color 'Yellow'
                if (-not $WhatIf) {
                    $installerPath = Resolve-CachedFallbackPackage -Category 'amd-graphics' -DestinationFolder $tempFolder -Publisher $script:AmdPublisher
                }
                if (-not $installerPath) { throw }
            }

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

        try {
            # Cached per product series: a GTX 10 machine and an RTX 50 machine need
            # different packages, and both are kept.
            $series = Get-NvidiaProductSeries -GPU $nvidiaGpu
            $nvidiaCategory = "nvidia\$($series.Psid)"

            # Temporary folder handling (adapted from original)
            $folder = if ($LogPath -and (Split-Path -Path $LogPath -Parent)) { Split-Path -Path $LogPath -Parent } else { "$env:temp" }
            $nvidiaTempFolder = "$folder\NVIDIA_$([System.Guid]::NewGuid().ToString('N'))"
            Register-TempFolder $nvidiaTempFolder
            New-Item -Path $nvidiaTempFolder -ItemType Directory -Force | Out-Null

            $dlFile = $null
            try {
                $info = Get-NvidiaDriverInfo -Psid $series.Psid
                $dlFile = Get-CachedDriverCopy -Category $nvidiaCategory -FileName $info.FileName -DestinationFolder $nvidiaTempFolder -Publisher $script:NvidiaPublisher -WhatIf:$WhatIf
                if (-not $dlFile) {
                    $dlFile = Download-NvidiaDriver -DownloadUrl $info.DownloadUrl -Version $info.Version -DestinationFolder $nvidiaTempFolder -WhatIf:$WhatIf
                    if (-not $WhatIf) {
                        Assert-InstallerSignature -InstallerPath $dlFile -ExpectedPublisher $script:NvidiaPublisher
                        Save-DriverToCache -Category $nvidiaCategory -SourcePath $dlFile -FileName $info.FileName
                    }
                }
            } catch {
                Write-Log -Message "Nvidia lookup or download failed: $($_.Exception.Message)" -Color 'Yellow'
                if (-not $WhatIf) {
                    $dlFile = Resolve-CachedFallbackPackage -Category $nvidiaCategory -DestinationFolder $nvidiaTempFolder -Publisher $script:NvidiaPublisher
                }
                if (-not $dlFile) { throw }
            }

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

            $dlFile = $null
            try {
                $dlFile = Get-CachedDriverCopy -Category 'intel' -FileName $info.FileName -DestinationFolder $intelTempFolder -Publisher $script:IntelPublisher -WhatIf:$WhatIf
                if (-not $dlFile) {
                    $dlFile = Download-IntelDriver -DownloadUrl $info.DownloadUrl -FileName $info.FileName -DestinationFolder $intelTempFolder -WhatIf:$WhatIf
                    if (-not $WhatIf) {
                        Assert-InstallerSignature -InstallerPath $dlFile -ExpectedPublisher $script:IntelPublisher
                        Save-DriverToCache -Category 'intel' -SourcePath $dlFile -FileName $info.FileName
                    }
                }
            } catch {
                Write-Log -Message "Intel download failed: $($_.Exception.Message)" -Color 'Yellow'
                if (-not $WhatIf) {
                    $dlFile = Resolve-CachedFallbackPackage -Category 'intel' -DestinationFolder $intelTempFolder -Publisher $script:IntelPublisher
                }
                if (-not $dlFile) { throw }
            }

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
