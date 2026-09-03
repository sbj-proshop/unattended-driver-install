param (
    [switch]$clean = $false,
    [string]$folder = "$env:temp"
)

$gpu = Get-CimInstance -Class CIM_VideoController | Where-Object { $_.PNPDeviceID -like "PCI\VEN_10DE*" } | Select-Object -First 1

if (-not $gpu) {
    Write-Host -ForegroundColor Red "No Nvidia GPU detected. Press Enter to exit..."
    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    exit
}

$deviceId = if ($gpu.PNPDeviceID -match 'DEV_([0-9A-F]{4})') { $matches[1] }

$pciName = $null
if ($deviceId) {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = 3072 -bor 768 -bor 192
        $req = [System.Net.HttpWebRequest]::Create("https://pci-ids.ucw.cz/read/PC/10de/$deviceId")
        $req.Timeout = 10000
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $content = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        if ($content -match 'Name:\s*([^<]*)') {
            $pciName = $matches[1].Trim()
        }
    } catch {
        Write-Host -ForegroundColor Yellow "Warning: Could not look up PCI device name ($($_.Exception.Message))"
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

$gpuName = $pciName, $seriesName, $gpu.Name, $gpu.Description, $gpu.Caption | Where-Object { $_ } | Select-Object -First 1

Write-Host -ForegroundColor Green "Nvidia card detected: $gpuName"
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

Write-Host "Product series ID`t$psid"

$apiUrl = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=$psid&osID=57&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"

Write-Host "Checking for latest driver version..."
try {
    $response = Invoke-WebRequest -Uri $apiUrl -Method GET -UseBasicParsing
    $json = $response.Content | ConvertFrom-Json
} catch {
    Write-Host -ForegroundColor Red "Failed to contact Nvidia driver service."
    Write-Host "Press any key to exit..."
    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

if ($json.Success -ne "1" -or -not $json.IDS) {
    Write-Host -ForegroundColor Red "Failed to retrieve driver information from Nvidia."
    Write-Host "Press any key to exit..."
    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

$version = $json.IDS[0].downloadInfo.Version
$downloadUrl = $json.IDS[0].downloadInfo.DownloadURL

Write-Host "Latest version`t`t$version"

$nvidiaTempFolder = "$folder\NVIDIA"
New-Item -Path $nvidiaTempFolder -ItemType Directory 2>&1 | Out-Null

$dlFile = "$nvidiaTempFolder\$version.exe"
Write-Host "Downloading the latest version to $dlFile"
Start-BitsTransfer -Source $downloadUrl -Destination $dlFile

if (-not $?) {
    Write-Host -ForegroundColor Red "Download failed."
    Write-Host "Press any key to exit..."
    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

Write-Host "Download finished."

Write-Host "Installing Nvidia drivers now..."
$installArgs = @("/s")
if ($clean) {
    $installArgs += "-clean"
}
$proc = Start-Process -FilePath $dlFile -ArgumentList $installArgs -Wait -PassThru

if ($proc.ExitCode -ne 0) {
    Write-Host -ForegroundColor Yellow "Installer exited with code $($proc.ExitCode). The installation may not have completed successfully."
}

Write-Host "Deleting downloaded files"
Remove-Item $nvidiaTempFolder -Recurse -Force -ErrorAction SilentlyContinue

# Sleep to wait for display to blip after driver install and let the powershell window settle so that redraw still works.
Start-Sleep -Seconds 3

$Host.UI.RawUI.BackgroundColor = 'Green'
Write-Host -ForegroundColor Black -BackgroundColor Green "Driver installed. Press any button to exit."
$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
exit
