<#
.SYNOPSIS
  Flashes an AOSP disk image to the NVMe of a Raspberry Pi 5 running TWRP, over Wi-Fi.

.DESCRIPTION
  The image is gzip-compressed on the fly and streamed over TCP into
  "nc | gunzip | dd" on the Pi, so nothing is stored on the device.
  Requires TWRP with adb over TCP (adb connect <ip>:5555) or USB adb.

  WARNING: the whole target device (default /dev/block/nvme0n1) is overwritten.

.EXAMPLE
  .\flash-nvme.ps1
  .\flash-nvme.ps1 -Image 'C:\img\RaspberryVanillaAOSP17-20261005-rpi5_car.img' -Serial 192.168.178.65:5555
#>
param(
    [string]$Image,
    [string]$ImageDir = '\\wsl$\Debian\home\samaelson\aosp\AOSP-17\out\target\product\rpi5',
    [string]$AdbPath = 'O:\Tools\platform-tools-latest-windows\platform-tools\adb.exe',
    [string]$Serial,
    [string]$DeviceIp,
    [int]$Port = 5000,
    [string]$Target = '/dev/block/nvme0n1',
    [switch]$NoPatchConfig,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $AdbPath)) {
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "adb.exe nicht gefunden: $AdbPath" }
    $AdbPath = $cmd.Source
}
$serialArgs = @()
if ($Serial) { $serialArgs = @('-s', $Serial) }

function Invoke-Adb {
    # The device prints linker warnings on stderr; with 'Stop' PowerShell 5.1 would abort on them
    $ErrorActionPreference = 'Continue'
    & $AdbPath @serialArgs @args 2>$null
}

function Get-LocalChunkHash([string]$Path, [long]$Offset, [int]$Length) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $null = $fs.Seek($Offset, 'Begin')
        $buf = New-Object byte[] $Length
        $read = 0
        while ($read -lt $Length) {
            $n = $fs.Read($buf, $read, $Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($buf, 0, $read)) -replace '-', '').ToLower()
    } finally { $fs.Dispose() }
}

function Get-RemoteChunkHash([long]$SkipMB, [int]$CountMB) {
    $out = Invoke-Adb shell "dd if=$Target bs=1M skip=$SkipMB count=$CountMB 2>/dev/null | sha256sum"
    return (($out | Select-Object -Last 1) -split '\s+')[0].Trim().ToLower()
}

# 1. Image
if (-not $Image) {
    $latest = Get-ChildItem $ImageDir -Filter 'RaspberryVanillaAOSP17-*.img' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "Kein Image in $ImageDir gefunden." }
    $Image = $latest.FullName
}
if (-not (Test-Path $Image)) { throw "Image nicht gefunden: $Image" }
$imgSize = (Get-Item $Image).Length
Write-Host ("Image:  {0} ({1:N2} GB)" -f $Image, ($imgSize / 1GB))

# 2. Device
$state = (Invoke-Adb get-state | Select-Object -First 1)
if ($state -notin @('device', 'recovery')) {
    throw ("adb-Zustand von '{0}': '{1}' (erwartet: device oder recovery). Tipp: 'adb disconnect' und danach 'adb connect <ip>:5555' ausfuehren." -f $Serial, $state)
}
$isBlock = Invoke-Adb shell "test -b $Target && echo yes"
if (($isBlock | Select-Object -Last 1) -ne 'yes') { throw "$Target existiert auf dem Geraet nicht." }
$devSize = [long](($(Invoke-Adb shell "blockdev --getsize64 $Target") | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1))
Write-Host ("Ziel:   {0} ({1:N2} GB)" -f $Target, ($devSize / 1GB))
if ($imgSize -gt $devSize) { throw 'Das Image ist groesser als das Zielgeraet.' }

# 3. IP of the Pi
if (-not $DeviceIp) {
    if ($Serial -match '^([\d\.]+):\d+$') {
        $DeviceIp = $Matches[1]
    } else {
        $ifc = (Invoke-Adb shell 'ifconfig wlan0') -join "`n"
        if ($ifc -match 'inet addr:([\d\.]+)') { $DeviceIp = $Matches[1] }
    }
}
if (-not $DeviceIp) { throw 'IP des Pi nicht ermittelt, bitte -DeviceIp angeben.' }
Write-Host "Pi-IP: $DeviceIp (Port $Port)"

# 4. Confirmation
if (-not $Force) {
    Write-Host ''
    Write-Host "ACHTUNG: $Target wird KOMPLETT ueberschrieben." -ForegroundColor Yellow
    if ((Read-Host "Zum Fortfahren 'YES' eingeben") -ne 'YES') { Write-Host 'Abgebrochen.'; return }
}

# 5. Start receiver on the Pi (the pipe has to run on the device, hence the quotes)
$remote = "killall nc 2>/dev/null; nc -l -p $Port | gunzip | dd of=$Target bs=4M > /tmp/flash.log 2>&1; sync"
$argLine = (($serialArgs | ForEach-Object { $_ }) -join ' ') + " shell `"$remote`""
$recv = Start-Process -FilePath $AdbPath -ArgumentList $argLine -WindowStyle Hidden -PassThru

try {
    # 6. Connect (the listener needs a moment)
    $client = $null
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $client = New-Object Net.Sockets.TcpClient
            $client.Connect($DeviceIp, $Port)
            break
        } catch {
            $client.Dispose(); $client = $null
            if ($recv.HasExited) { throw 'Empfaenger auf dem Pi ist vorzeitig beendet.' }
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $client) { throw "Keine Verbindung zu ${DeviceIp}:$Port" }

    # 7. Stream
    $net = $client.GetStream()
    $gz = New-Object IO.Compression.GZipStream($net, [IO.Compression.CompressionLevel]::Fastest)
    $fs = [IO.File]::OpenRead($Image)
    $buf = New-Object byte[] (4MB)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastUi = 0
    try {
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $gz.Write($buf, 0, $n)
            if ($sw.ElapsedMilliseconds - $lastUi -ge 1000) {
                $lastUi = $sw.ElapsedMilliseconds
                $pct = [int](100 * $fs.Position / $imgSize)
                $mbs = ($fs.Position / 1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 1)
                Write-Progress -Activity 'Flashe NVMe' -PercentComplete $pct `
                    -Status ("{0:N2} / {1:N2} GB, {2:N0} MB/s gelesen" -f ($fs.Position / 1GB), ($imgSize / 1GB), $mbs)
            }
        }
        $gz.Dispose()      # flushes and closes the connection
        $client.Close()
    } finally {
        $fs.Dispose()
        Write-Progress -Activity 'Flashe NVMe' -Completed
    }

    # 8. Wait for dd + sync on the Pi
    Write-Host 'Warte auf dd/sync auf dem Pi ...'
    if (-not $recv.WaitForExit(900000)) { throw 'Zeitueberschreitung beim Warten auf den Pi.' }
} finally {
    if (-not $recv.HasExited) { $recv.Kill() }
}

Write-Host ''
Write-Host 'dd-Ausgabe:'
Invoke-Adb shell 'cat /tmp/flash.log'

# 9. Verify head and tail
if ($imgSize % 1MB -eq 0) {
    $imgMB = [long]($imgSize / 1MB)
    $chunk = [int][math]::Min(32, $imgMB)
    $ok = $true
    foreach ($skip in @(0, ($imgMB - $chunk))) {
        $local = Get-LocalChunkHash $Image ($skip * 1MB) ($chunk * 1MB)
        $remote = Get-RemoteChunkHash $skip $chunk
        if ($local -eq $remote) {
            Write-Host "Pruefsumme ok  (ab ${skip} MB, $chunk MB)" -ForegroundColor Green
        } else {
            Write-Host "Pruefsumme FEHLER (ab ${skip} MB)" -ForegroundColor Red
            $ok = $false
        }
    }
    if (-not $ok) { throw 'Verifikation fehlgeschlagen, bitte erneut flashen.' }
} else {
    Write-Host 'Image-Groesse ist kein Vielfaches von 1 MB, Verifikation uebersprungen.' -ForegroundColor Yellow
}

# 10. Re-read partition table
$null = Invoke-Adb shell "blockdev --rereadpt $Target"
Start-Sleep -Seconds 2

# 11. The AOSP image boots with the SD card fstab; the NVMe overlay is required
if (-not $NoPatchConfig) {
    $bootPart = $Target + 'p1'
    $patch = "mkdir -p /mnt/nvmeboot && mount -t vfat $bootPart /mnt/nvmeboot && " +
             "(grep -q '^dtoverlay=android-nvme' /mnt/nvmeboot/config.txt || " +
             "printf '\n# Android fstab for NVMe\ndtoverlay=android-nvme\n' >> /mnt/nvmeboot/config.txt); " +
             "sync; tail -n 4 /mnt/nvmeboot/config.txt; umount /mnt/nvmeboot"
    Write-Host ''
    Write-Host "config.txt auf $bootPart patchen (dtoverlay=android-nvme):"
    Invoke-Adb shell $patch
}

Write-Host ''
Write-Host 'Partitionen:'
Invoke-Adb shell "ls -l $Target*"
Write-Host ''
Write-Host 'Fertig. In TWRP jetzt Reboot -> System waehlen (setzt BOOT_ORDER 0xf416).' -ForegroundColor Green
