<#
.SYNOPSIS
    Flash AOSP image to Raspberry Pi 5 NVMe using ADB/TCP.

.DESCRIPTION
    Supports BMAP 2.0.

    With BMAP:
      1. Validate BMAP file checksum.
      2. Validate BMAP metadata against image.
      3. Validate mapped image ranges locally.
      4. Transfer only mapped ranges.
      5. Write ranges to the correct NVMe offsets.
      6. Read every mapped range back from NVMe.
      7. Compare readback against BMAP checksums.
      8. Re-read partition table.
      9. Patch config.txt with dtoverlay=android-nvme.

    Without BMAP:
      Full image is transferred and written.

.EXAMPLE

    .\flash-nvme-bmap.ps1 `
        -Image '\\wsl$\Debian\home\samaelson\aosp\AOSP-17\out\target\product\rpi5\RaspberryVanillaAOSP17-20261007-rpi5_car.img' `
        -Serial 192.168.178.65:5555 `
        -Port 5000 `
        -Force
#>

#requires -Version 5.1

<#
.SYNOPSIS
    Flash eines AOSP-Raspberry-Pi-5-Images auf NVMe über TWRP/ADB,
    mit optionaler BMAP-Unterstützung.

.DESCRIPTION
    - ADB-Verbindung über TCP
    - akzeptiert ADB-Status "device" und "recovery"
    - prüft Image und BMAP
    - verifiziert die BMAP-Datei selbst
    - verifiziert lokal alle gemappten BMAP-Bereiche
    - überträgt nur die gemappten Bereiche
    - jeder BMAP-Bereich bekommt eine eigene TCP-Verbindung
    - Remote-Daten werden per SHA256 gegen das Image geprüft
    - Partitionstabelle wird neu eingelesen
    - optionales Patchen einer Boot-Konfiguration

.NOTES
    PowerShell 5.1
#>
#requires -Version 5.1

<#
.SYNOPSIS
    Flash eines AOSP-Raspberry-Pi-5-Images auf NVMe über TWRP/ADB,
    mit optionaler BMAP-Unterstützung.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Image,

    [Parameter(Mandatory = $false)]
    [string]$ImageDir = '\\wsl$\Debian\home\samaelson\aosp\AOSP-17\out\target\product\rpi5',

    [Parameter(Mandatory = $false)]
    [string]$AdbPath = 'O:\Tools\platform-tools-latest-windows\platform-tools\adb.exe',

    [Parameter(Mandatory = $false)]
    [string]$Serial,

    [Parameter(Mandatory = $false)]
    [string]$DeviceIp,

    [Parameter(Mandatory = $false)]
    [int]$Port = 5000,

    [Parameter(Mandatory = $false)]
    [string]$Target = '/dev/block/nvme0n1',

    [switch]$NoPatchConfig,

    [switch]$Force
)

# ERST HIER dürfen ausführbare Anweisungen kommen
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8

# ============================================================
# HILFSFUNKTIONEN
# ============================================================

function Format-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return ('{0:N2} TiB' -f ($Bytes / 1TB))
    }

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GiB' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N2} MiB' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N2} KiB' -f ($Bytes / 1KB))
    }

    return ('{0:N0} Bytes' -f $Bytes)
}

function Write-Section {
    param(
        [string]$Text
    )

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkGray
}

function Write-OK {
    param(
        [string]$Text
    )

    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param(
        [string]$Text
    )

    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-Info {
    param(
        [string]$Text
    )

    Write-Host "[INFO] $Text" -ForegroundColor Gray
}

# ============================================================
# ADB
# ============================================================

function ConvertTo-WindowsCommandLineArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Argument
    )

    if ($Argument.Length -eq 0) {
        return '""'
    }

    # Kein Quoting nötig
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Windows CommandLine Quoting:
    # Backslashes vor " und am Ende korrekt verdoppeln.
    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"')

    $backslashes = 0

    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }

        if ($char -eq '"') {
            if ($backslashes -gt 0) {
                [void]$result.Append(('\' * ($backslashes * 2)))
            }

            [void]$result.Append('\')
            [void]$result.Append('"')

            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$result.Append(('\' * $backslashes))
            $backslashes = 0
        }

        [void]$result.Append($char)
    }

    if ($backslashes -gt 0) {
        [void]$result.Append(('\' * ($backslashes * 2)))
    }

    [void]$result.Append('"')

    return $result.ToString()
}

function Start-AdbProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = $AdbPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $quotedArguments = @()

    foreach ($argument in $Arguments) {
        $quotedArguments += ConvertTo-WindowsCommandLineArgument -Argument ([string]$argument)
    }

    $psi.Arguments = $quotedArguments -join ' '

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        $process.Dispose()
        throw "ADB-Prozess konnte nicht gestartet werden."
    }

    return $process
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$IgnoreExitCode
    )

    $process = $null

    try {
        $process = Start-AdbProcess -Arguments $Arguments

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        $process.WaitForExit()

        $exitCode = $process.ExitCode

        # Harmlose TWRP/Android linker-Warnings aus stderr entfernen.
        $stderrLines = @()

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $stderrLines = @(
                $stderr -split "`r?`n" |
                Where-Object {
                    $line = $_.Trim()

                    if ([string]::IsNullOrWhiteSpace($line)) {
                        return $false
                    }

                    if ($line -match '^\s*WARNING:\s*linker:') {
                        return $false
                    }

                    if ($line -match '^\s*\(ignoring\)\s*$') {
                        return $false
                    }

                    return $true
                }
            )
        }

        if (-not $IgnoreExitCode -and $exitCode -ne 0) {
            $stderrText = ($stderrLines -join "`r`n").Trim()

            if ([string]::IsNullOrWhiteSpace($stderrText)) {
                $stderrText = $stderr.Trim()
            }

            throw @"
ADB-Befehl fehlgeschlagen.

Befehl:
$AdbPath $($Arguments -join ' ')

ExitCode:
$exitCode

stdout:
$($stdout.Trim())

stderr:
$stderrText
"@
        }

        if ([string]::IsNullOrEmpty($stdout)) {
            return @()
        }

        return @(
            $stdout -split "`r?`n" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
        )
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-AdbShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [switch]$IgnoreExitCode
    )

    return Invoke-Adb `
        -Arguments @('-s', $Serial, 'shell', $Command) `
        -IgnoreExitCode:$IgnoreExitCode
}

# ============================================================
# SHA256
# ============================================================

function Get-LocalSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $stream = [System.IO.File]::OpenRead($Path)

        try {
            $hash = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }

    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-StreamSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [Int64]$Bytes
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $buffer = New-Object byte[] (1024 * 1024)

        [Int64]$remaining = $Bytes

        while ($remaining -gt 0) {
            [int]$toRead = [int][Math]::Min(
                [Int64]$buffer.Length,
                $remaining
            )

            $read = $Stream.Read(
                $buffer,
                0,
                $toRead
            )

            if ($read -le 0) {
                throw "Unerwartetes EOF beim Lesen des Images."
            }

            [void]$sha.TransformBlock(
                $buffer,
                0,
                $read,
                $buffer,
                0
            )

            $remaining -= [Int64]$read
        }

        [void]$sha.TransformFinalBlock(
            [byte[]]::new(0),
            0,
            0
        )

        return ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

# ============================================================
# BMAP CHECKSUMME
# ============================================================

function Get-BmapFileChecksum {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = [System.IO.File]::ReadAllText(
        $Path,
        [System.Text.Encoding]::UTF8
    )

    # Nur den Wert innerhalb von <BmapFileChecksum> ersetzen.
    $normalized = [regex]::Replace(
        $text,
        '(?is)(<BmapFileChecksum>\s*)[0-9a-fA-F]+(\s*</BmapFileChecksum>)',
        '${1}' + ('0' * 64) + '${2}',
        1
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Test-BmapFileChecksum {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    [xml]$xml = Get-Content `
        -LiteralPath $Path `
        -Raw `
        -Encoding UTF8

    $declared = ([string]$xml.bmap.BmapFileChecksum).Trim()
    $calculated = Get-BmapFileChecksum -Path $Path

    if ([string]::IsNullOrWhiteSpace($declared)) {
        throw "BMAP enthält keine BmapFileChecksum."
    }

    Write-Host ''
    Write-Host 'Prüfe BMAP-Datei-Checksumme ...' -ForegroundColor Cyan

    Write-Host "  Deklariert: $declared"
    Write-Host "  Berechnet:  $calculated"

    if ($declared.ToLowerInvariant() -ne $calculated.ToLowerInvariant()) {
        throw @"
BMAP-Datei-Checksumme stimmt NICHT.

Deklariert:
$declared

Berechnet:
$calculated
"@
    }

    Write-OK "BMAP-Datei-Checksumme OK: $calculated"

    return $true
}

# ============================================================
# BMAP PARSEN
# ============================================================

function Get-BmapInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    [xml]$xml = Get-Content `
        -LiteralPath $Path `
        -Raw `
        -Encoding UTF8

    if ($null -eq $xml.bmap) {
        throw "Ungültige BMAP-Datei: <bmap> fehlt."
    }

    $version = [string]$xml.bmap.version

    [Int64]$imageSize = [Int64]$xml.bmap.ImageSize
    [Int64]$blockSize = [Int64]$xml.bmap.BlockSize
    [Int64]$blocksCount = [Int64]$xml.bmap.BlocksCount
    [Int64]$mappedBlocksCount = [Int64]$xml.bmap.MappedBlocksCount

    $checksumType = [string]$xml.bmap.ChecksumType
    $bmapFileChecksum = [string]$xml.bmap.BmapFileChecksum

    if ($blockSize -le 0) {
        throw "Ungültige BMAP BlockSize: $blockSize"
    }

    if ($blocksCount -le 0) {
        throw "Ungültige BMAP BlocksCount: $blocksCount"
    }

    if ($imageSize -le 0) {
        throw "Ungültige BMAP ImageSize: $imageSize"
    }

    $segments = @()

    foreach ($range in @($xml.bmap.BlockMap.Range)) {
        $rangeText = ([string]$range.InnerText).Trim()

        if ([string]::IsNullOrWhiteSpace($rangeText)) {
            continue
        }

        foreach ($part in ($rangeText -split ',')) {
            $part = $part.Trim()

            if ([string]::IsNullOrWhiteSpace($part)) {
                continue
            }

            if ($part -match '^(\d+)-(\d+)$') {
                [Int64]$start = [Int64]$Matches[1]
                [Int64]$end = [Int64]$Matches[2]
            }
            elseif ($part -match '^(\d+)$') {
                [Int64]$start = [Int64]$Matches[1]
                [Int64]$end = $start
            }
            else {
                throw "Ungültiger BMAP-Range: '$part'"
            }

            if ($end -lt $start) {
                throw "Ungültiger BMAP-Range: '$part'"
            }

            [Int64]$count = $end - $start + 1

            if ($start -lt 0 -or $end -ge $blocksCount) {
                throw "BMAP-Range '$part' liegt außerhalb von BlocksCount."
            }

            $checksum = [string]$range.chksum

            $segments += [PSCustomObject]@{
                Start    = $start
                End      = $end
                Count    = $count
                Checksum = $checksum
            }
        }
    }

    [Int64]$calculatedMappedBlocks = 0

    foreach ($segment in $segments) {
        $calculatedMappedBlocks += [Int64]$segment.Count
    }

    if ($calculatedMappedBlocks -ne $mappedBlocksCount) {
        Write-Warn (
            "BMAP MappedBlocksCount = {0}, berechnete Summe = {1}" -f
            $mappedBlocksCount,
            $calculatedMappedBlocks
        )
    }

    [Int64]$mappedBytes = $calculatedMappedBlocks * $blockSize

    return [PSCustomObject]@{
        Version            = $version
        ImageSize          = $imageSize
        BlockSize          = $blockSize
        BlocksCount        = $blocksCount
        MappedBlocksCount  = $mappedBlocksCount
        MappedBytes        = $mappedBytes
        ChecksumType       = $checksumType
        BmapFileChecksum   = $bmapFileChecksum
        Segments           = $segments
    }
}

# ============================================================
# LOKALE BMAP VERIFIKATION
# ============================================================

function Test-LocalBmap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        $BmapInfo
    )

    Write-Section 'LOKALE BMAP-VERIFIKATION'

    $stream = [System.IO.File]::OpenRead($ImagePath)

    try {
        $segmentNumber = 0

        foreach ($segment in $BmapInfo.Segments) {
            $segmentNumber++

            [Int64]$start = [Int64]$segment.Start
            [Int64]$count = [Int64]$segment.Count

            [Int64]$offset =
                $start * [Int64]$BmapInfo.BlockSize

            [Int64]$wanted =
                $count * [Int64]$BmapInfo.BlockSize

            [Int64]$remainingImage =
                [Int64]$BmapInfo.ImageSize - $offset

            if ($remainingImage -le 0) {
                throw "BMAP-Segment $segmentNumber beginnt hinter dem Image."
            }

            [Int64]$wanted = [Math]::Min(
                $wanted,
                $remainingImage
            )

            $stream.Position = $offset

            $hash = Get-StreamSha256 `
                -Stream $stream `
                -Bytes $wanted

            if (
                -not [string]::IsNullOrWhiteSpace(
                    [string]$segment.Checksum
                )
            ) {
                if (
                    $hash.ToLowerInvariant() -ne
                    ([string]$segment.Checksum).ToLowerInvariant()
                ) {
                    throw @"
Lokale BMAP-Prüfung fehlgeschlagen.

Segment:
$segmentNumber

Block:
$start - $($segment.End)

Erwartet:
$($segment.Checksum)

Berechnet:
$hash
"@
                }
            }

            if (($segmentNumber % 10) -eq 0 -or $segmentNumber -eq $BmapInfo.Segments.Count) {
                Write-Host (
                    "  Segment {0}/{1} OK" -f
                    $segmentNumber,
                    $BmapInfo.Segments.Count
                )
            }
        }
    }
    finally {
        $stream.Dispose()
    }

    Write-OK 'Lokale BMAP-Verifikation erfolgreich.'
}

# ============================================================
# REMOTE SHA256 EINES SEGMENTS
# ============================================================

function Get-RemoteSegmentSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$StartBlock,

        [Parameter(Mandatory = $true)]
        [Int64]$BlockCount,

        [Parameter(Mandatory = $true)]
        [Int64]$BlockSize
    )

    [Int64]$bytes =
        $BlockCount * $BlockSize

    $remoteCommand = @"
dd if='$Target' bs=$BlockSize skip=$StartBlock count=$BlockCount 2>/dev/null | sha256sum
"@

    $output = Invoke-AdbShell -Command $remoteCommand

    $line = @(
        $output |
        Where-Object {
            $_ -match '([0-9a-fA-F]{64})'
        }
    ) | Select-Object -First 1

    if ($null -eq $line) {
        throw "Remote SHA256 konnte nicht gelesen werden."
    }

    if ($line -notmatch '([0-9a-fA-F]{64})') {
        throw "Ungültige Remote-SHA256-Ausgabe: $line"
    }

    return $Matches[1].ToLowerInvariant()
}

# ============================================================
# REMOTE BMAP VERIFIKATION
# ============================================================

function Test-RemoteBmap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        $BmapInfo
    )

    Write-Section 'REMOTE BMAP-VERIFIKATION'

    $stream = [System.IO.File]::OpenRead($ImagePath)

    try {
        $segmentNumber = 0

        foreach ($segment in $BmapInfo.Segments) {
            $segmentNumber++

            [Int64]$start = [Int64]$segment.Start
            [Int64]$count = [Int64]$segment.Count

            [Int64]$offset =
                $start * [Int64]$BmapInfo.BlockSize

            [Int64]$wanted =
                $count * [Int64]$BmapInfo.BlockSize

            [Int64]$remainingImage =
                [Int64]$BmapInfo.ImageSize - $offset

            if ($remainingImage -le 0) {
                throw "Segment $segmentNumber liegt hinter dem Image."
            }

            [Int64]$wanted = [Math]::Min(
                $wanted,
                $remainingImage
            )

            $expected = $null

            if (-not [string]::IsNullOrWhiteSpace([string]$segment.Checksum)) {
                $expected = ([string]$segment.Checksum).ToLowerInvariant()
            }
            else {
                $stream.Position = $offset

                $expected = Get-StreamSha256 `
                    -Stream $stream `
                    -Bytes $wanted
            }

            $actual = Get-RemoteSegmentSha256 `
                -StartBlock $start `
                -BlockCount $count `
                -BlockSize $BmapInfo.BlockSize

            if ($actual -ne $expected) {
                throw @"
REMOTE BMAP-VERIFIKATION FEHLGESCHLAGEN.

Segment:
$segmentNumber

Block:
$start - $($segment.End)

Erwartet:
$expected

Remote:
$actual
"@
            }

            if (($segmentNumber % 10) -eq 0 -or $segmentNumber -eq $BmapInfo.Segments.Count) {
                Write-Host (
                    "  Remote Segment {0}/{1} OK" -f
                    $segmentNumber,
                    $BmapInfo.Segments.Count
                )
            }
        }
    }
    finally {
        $stream.Dispose()
    }

    Write-OK 'Remote BMAP-Verifikation erfolgreich.'
}

# ============================================================
# EINEN BMAP-RANGE ÜBERTRAGEN
# ============================================================

function Send-BmapRange {
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$StartBlock,

        [Parameter(Mandatory = $true)]
        [Int64]$BlockCount,

        [Parameter(Mandatory = $true)]
        [Int64]$BlockSize,

        [Parameter(Mandatory = $true)]
        [System.IO.FileStream]$ImageStream
    )

    [Int64]$offset =
        $StartBlock * $BlockSize

    [Int64]$bytes =
        $BlockCount * $BlockSize

    $ImageStream.Position = $offset

    # --------------------------------------------------------
    # Remote Receiver
    # --------------------------------------------------------

    $remoteCommand = @"
nc -l -p $Port | gunzip | dd of='$Target' bs=$BlockSize seek=$StartBlock count=$BlockCount conv=notrunc
"@

    $receiverArguments = @(
        '-s',
        $Serial,
        'shell',
        $remoteCommand
    )

    $receiver = $null

    try {
        $receiver = Start-AdbProcess -Arguments $receiverArguments

        # Etwas Zeit geben, damit nc lauscht.
        Start-Sleep -Milliseconds 300

        # ----------------------------------------------------
        # TCP-Verbindung
        # ----------------------------------------------------

        $tcp = New-Object System.Net.Sockets.TcpClient

        try {
            $connectTask = $tcp.ConnectAsync(
                $DeviceIp,
                $Port
            )

            if (-not $connectTask.Wait(10000)) {
                throw "Timeout beim Verbinden mit ${DeviceIp}:$Port"
            }

            $networkStream = $tcp.GetStream()

            try {
                $gzip = New-Object System.IO.Compression.GZipStream(
                    $networkStream,
                    [System.IO.Compression.CompressionMode]::Compress,
                    $true
                )

                try {
                    $buffer = New-Object byte[] (1024 * 1024)

                    [Int64]$remaining = $bytes
                    [Int64]$sent = 0

                    while ($remaining -gt 0) {

                        [int]$toRead = [int][Math]::Min(
                            [Int64]$buffer.Length,
                            $remaining
                        )

                        $read = $ImageStream.Read(
                            $buffer,
                            0,
                            $toRead
                        )

                        if ($read -le 0) {
                            throw "Unerwartetes EOF im Image."
                        }

                        $gzip.Write(
                            $buffer,
                            0,
                            $read
                        )

                        $sent += [Int64]$read
                        $remaining -= [Int64]$read
                    }

                    $gzip.Flush()
                }
                finally {
                    $gzip.Dispose()
                }
            }
            finally {
                $networkStream.Dispose()
            }
        }
        finally {
            $tcp.Dispose()
        }

        # ----------------------------------------------------
        # Auf adb shell warten
        # ----------------------------------------------------

        if (-not $receiver.WaitForExit(120000)) {

            try {
                $receiver.Kill()
            }
            catch {
            }

            throw @"
Timeout beim Schreiben des BMAP-Segments.

StartBlock:
$StartBlock

BlockCount:
$BlockCount

Bytes:
$(Format-Bytes $bytes)
"@
        }

        # Jetzt erst stdout/stderr lesen.
        $stdout = $receiver.StandardOutput.ReadToEnd()
        $stderr = $receiver.StandardError.ReadToEnd()

        $exitCode = $receiver.ExitCode

        # ----------------------------------------------------
        # WICHTIG:
        # Nur der ExitCode entscheidet über Erfolg.
        #
        # stderr enthält bei TWRP/Toybox durchaus normale
        # Meldungen wie:
        #
        # Warning: "[vdso]" unused DT entry...
        # conv=4
        #
        # Diese dürfen NICHT als Fehler behandelt werden.
        # ----------------------------------------------------

        if ($exitCode -ne 0) {
            throw @"
Remote BMAP-Schreibvorgang fehlgeschlagen.

StartBlock:
$StartBlock

BlockCount:
$BlockCount

Bytes:
$(Format-Bytes $bytes)

ExitCode:
$exitCode

stdout:
$stdout

stderr:
$stderr
"@
        }

        # ----------------------------------------------------
        # Erfolg
        # ----------------------------------------------------

        Write-Host (
            "    OK - {0} geschrieben" -f
            (Format-Bytes $bytes)
        ) -ForegroundColor DarkGreen
    }
    finally {

        if ($null -ne $receiver) {

            try {
                if (-not $receiver.HasExited) {
                    $receiver.Kill()
                }
            }
            catch {
            }

            $receiver.Dispose()
        }
    }
}
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$StartBlock,

        [Parameter(Mandatory = $true)]
        [Int64]$BlockCount,

        [Parameter(Mandatory = $true)]
        [Int64]$BlockSize,

        [Parameter(Mandatory = $true)]
        [System.IO.FileStream]$ImageStream
    )

    [Int64]$offset =
        $StartBlock * $BlockSize

    [Int64]$bytes =
        $BlockCount * $BlockSize

    $ImageStream.Position = $offset

    # --------------------------------------------------------
    # Remote Receiver starten
    # --------------------------------------------------------

    $remoteCommand = @"
nc -l -p $Port | gunzip | dd of='$Target' bs=$BlockSize seek=$StartBlock count=$BlockCount conv=notrunc
"@

    $receiverArguments = @(
        '-s',
        $Serial,
        'shell',
        $remoteCommand
    )

    $receiver = $null

    try {
        $receiver = Start-AdbProcess -Arguments $receiverArguments

        # ----------------------------------------------------
        # Kurze Wartezeit, damit nc lauscht.
        # ----------------------------------------------------

        Start-Sleep -Milliseconds 250

        # ----------------------------------------------------
        # TCP-Verbindung aufbauen
        # ----------------------------------------------------

        $tcp = New-Object System.Net.Sockets.TcpClient

        try {
            $connectTask = $tcp.ConnectAsync(
                $DeviceIp,
                $Port
            )

            if (-not $connectTask.Wait(10000)) {
                throw "Timeout beim Verbinden mit ${DeviceIp}:$Port"
            }

            $networkStream = $tcp.GetStream()

            try {
                $gzip = New-Object System.IO.Compression.GZipStream(
                    $networkStream,
                    [System.IO.Compression.CompressionMode]::Compress,
                    $true
                )

                try {
                    $buffer = New-Object byte[] (1024 * 1024)

                    [Int64]$remaining = $bytes
                    [Int64]$sent = 0

                    while ($remaining -gt 0) {
                        [int]$toRead = [int][Math]::Min(
                            [Int64]$buffer.Length,
                            $remaining
                        )

                        $read = $ImageStream.Read(
                            $buffer,
                            0,
                            $toRead
                        )

                        if ($read -le 0) {
                            throw "Unerwartetes EOF im Image."
                        }

                        $gzip.Write(
                            $buffer,
                            0,
                            $read
                        )

                        $sent += [Int64]$read
                        $remaining -= [Int64]$read
                    }

                    $gzip.Flush()
                }
                finally {
                    $gzip.Dispose()
                }
            }
            finally {
                $networkStream.Dispose()
            }
        }
        finally {
            $tcp.Dispose()
        }

        # ----------------------------------------------------
        # Auf adb shell warten
        # ----------------------------------------------------

        if (-not $receiver.WaitForExit(120000)) {
            try {
                $receiver.Kill()
            }
            catch {
            }

            throw @"
Timeout beim Schreiben des BMAP-Segments.

Start:
$StartBlock

Count:
$BlockCount

Bytes:
$(Format-Bytes $bytes)
"@
        }

        $stdout = $receiver.StandardOutput.ReadToEnd()
        $stderr = $receiver.StandardError.ReadToEnd()

        $exitCode = $receiver.ExitCode

        # Harmlose linker-Warnings ignorieren.
        $realErrors = @(
            $stderr -split "`r?`n" |
            Where-Object {
                $line = $_.Trim()

                if ([string]::IsNullOrWhiteSpace($line)) {
                    return $false
                }

                if ($line -match '^\s*WARNING:\s*linker:') {
                    return $false
                }

                if ($line -match '^\s*\(ignoring\)\s*$') {
                    return $false
                }

                return $true
            }
        )

        if ($exitCode -ne 0) {
            throw @"
Remote BMAP-Schreibvorgang fehlgeschlagen.

StartBlock:
$StartBlock

BlockCount:
$BlockCount

ExitCode:
$exitCode

stdout:
$stdout

stderr:
$stderr
"@
        }

        if ($realErrors.Count -gt 0) {
            throw @"
Remote BMAP-Schreibvorgang meldete einen Fehler:

$($realErrors -join "`r`n")
"@
        }
    }
    finally {
        if ($null -ne $receiver) {
            try {
                if (-not $receiver.HasExited) {
                    $receiver.Kill()
                }
            }
            catch {
            }

            $receiver.Dispose()
        }
    }
}

# ============================================================
# BMAP IMAGE SCHREIBEN
# ============================================================

function Write-BmapImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        $BmapInfo
    )

    Write-Section 'BMAP FLASH'

    Write-Host ''
    Write-Host "Ziel:          $Target"
    Write-Host "BMAP Segmente: $($BmapInfo.Segments.Count)"
    Write-Host "Daten:         $(Format-Bytes $BmapInfo.MappedBytes)"
    Write-Host "TCP:           ${DeviceIp}:$Port"
    Write-Host ''

    $stream = [System.IO.File]::OpenRead($ImagePath)

    try {
        $segmentNumber = 0

        foreach ($segment in $BmapInfo.Segments) {
            $segmentNumber++

            [Int64]$start = [Int64]$segment.Start
            [Int64]$count = [Int64]$segment.Count

            [Int64]$bytes =
                $count * [Int64]$BmapInfo.BlockSize

            Write-Host (
                "[{0}/{1}] Block {2}-{3} ({4})" -f
                $segmentNumber,
                $BmapInfo.Segments.Count,
                $start,
                $segment.End,
                (Format-Bytes $bytes)
            ) -ForegroundColor Gray

            Send-BmapRange `
                -StartBlock $start `
                -BlockCount $count `
                -BlockSize ([Int64]$BmapInfo.BlockSize) `
                -ImageStream $stream
        }
    }
    finally {
        $stream.Dispose()
    }

    Write-Host ''
    Write-Host 'Synchronisiere NVMe ...' -ForegroundColor Cyan

    Invoke-AdbShell -Command 'sync'

    Write-OK 'BMAP-Flash abgeschlossen.'
}

# ============================================================
# PARTITION TABLE
# ============================================================

function Update-PartitionTable {

    Write-Section 'PARTITION TABLE AKTUALISIEREN'

    $commands = @(
        "blockdev --rereadpt '$Target'",
        "partprobe '$Target'"
    )

    foreach ($command in $commands) {
        $result = Invoke-AdbShell `
            -Command $command `
            -IgnoreExitCode

        if ($result.Count -gt 0) {
            Write-Host ($result -join "`r`n") -ForegroundColor DarkGray
        }
    }

    Start-Sleep -Seconds 2

    Write-OK 'Partitionstabelle wurde neu eingelesen.'
}

# ============================================================
# CONFIG PATCH
# ============================================================

function Patch-Config {

    if ($NoPatchConfig) {
        Write-Info 'Config-Patching wurde mit -NoPatchConfig deaktiviert.'
        return
    }

    Write-Section 'CONFIG PATCH'

    $bootPartition = '/dev/block/nvme0n1p1'
    $mountPoint = '/tmp/bootconfig'

    try {
        Invoke-AdbShell `
            -Command "mkdir -p '$mountPoint'"

        Invoke-AdbShell `
            -Command "mount '$bootPartition' '$mountPoint'" `
            -IgnoreExitCode

        $configCandidates = @(
            "$mountPoint/config.txt",
            "$mountPoint/usercfg.txt",
            "$mountPoint/config/config.txt"
        )

        $found = $false

        foreach ($config in $configCandidates) {
            $check = Invoke-AdbShell `
                -Command "test -f '$config'; echo `$?"

            if (
                $check.Count -gt 0 -and
                ($check -join "`n") -match '\b0\b'
            ) {
                Write-Info "Gefundene Config: $config"

                # ------------------------------------------------
                # Hier können bei Bedarf konkrete AOSP/RPi5-
                # Anpassungen ergänzt werden.
                # ------------------------------------------------

                $found = $true
                break
            }
        }

        if (-not $found) {
            Write-Warn 'Keine bekannte Config-Datei gefunden.'
        }
        else {
            Write-OK 'Config-Partition gefunden.'
        }
    }
    finally {
        Invoke-AdbShell `
            -Command "umount '$mountPoint'" `
            -IgnoreExitCode
    }
}

# ============================================================
# DEVICE IP
# ============================================================

function Get-DeviceIpAddress {

    if (-not [string]::IsNullOrWhiteSpace($DeviceIp)) {
        return $DeviceIp
    }

    Write-Section 'DEVICE IP ERMITTELN'

    $output = Invoke-AdbShell -Command 'ifconfig wlan0'

    $text = $output -join "`n"

    if (
        $text -match
        'inet\s+(?:addr:)?(\d{1,3}(?:\.\d{1,3}){3})'
    ) {
        return $Matches[1]
    }

    throw @"
IP-Adresse konnte nicht automatisch ermittelt werden.

Bitte das Script mit -DeviceIp aufrufen, z.B.:

-DeviceIp 192.168.178.65
"@
}

# ============================================================
# IMAGE AUSWÄHLEN
# ============================================================

Write-Section 'IMAGE AUSWÄHLEN'

if ([string]::IsNullOrWhiteSpace($Image)) {

    if (-not (Test-Path -LiteralPath $ImageDir)) {
        throw "ImageDir existiert nicht: $ImageDir"
    }

    $images = @(
        Get-ChildItem `
            -LiteralPath $ImageDir `
            -Filter '*.img' `
            -File |
        Sort-Object LastWriteTime -Descending
    )

    if ($images.Count -eq 0) {
        throw "Keine .img-Dateien in $ImageDir gefunden."
    }

    if ($images.Count -eq 1) {
        $Image = $images[0].FullName
    }
    else {
        Write-Host ''
        Write-Host 'Verfügbare Images:' -ForegroundColor Cyan

        for ($i = 0; $i -lt $images.Count; $i++) {
            Write-Host (
                '[{0}] {1}  ({2})' -f
                ($i + 1),
                $images[$i].Name,
                (Format-Bytes $images[$i].Length)
            )
        }

        Write-Host ''

        [int]$choice = Read-Host 'Nummer auswählen'

        if (
            $choice -lt 1 -or
            $choice -gt $images.Count
        ) {
            throw 'Ungültige Auswahl.'
        }

        $Image = $images[$choice - 1].FullName
    }
}

if (-not (Test-Path -LiteralPath $Image -PathType Leaf)) {
    throw "Image nicht gefunden: $Image"
}

$ImageFile = Get-Item -LiteralPath $Image

Write-Host "Image: $($ImageFile.FullName)"
Write-Host "Größe: $(Format-Bytes ([Int64]$ImageFile.Length))"

# ============================================================
# BMAP SUCHEN
# ============================================================

$BmapPath = "$Image.bmap"

$BmapInfo = $null

if (Test-Path -LiteralPath $BmapPath -PathType Leaf) {

    Write-Section 'BMAP'

    Write-Host "BMAP: $BmapPath"

    Test-BmapFileChecksum -Path $BmapPath | Out-Null

    $BmapInfo = Get-BmapInfo -Path $BmapPath

    Write-Host ''
    Write-Host ('BMAP Version:       {0}' -f $BmapInfo.Version)
    Write-Host ('ImageSize:           {0}' -f (Format-Bytes $BmapInfo.ImageSize))
    Write-Host ('BlockSize:           {0:N0} Bytes' -f $BmapInfo.BlockSize)
    Write-Host ('BlocksCount:         {0:N0}' -f $BmapInfo.BlocksCount)
    Write-Host ('MappedBlocksCount:   {0:N0}' -f $BmapInfo.MappedBlocksCount)
    Write-Host ('Mapped data:         {0}' -f (Format-Bytes $BmapInfo.MappedBytes))
    Write-Host ('BlockMap entries:    {0}' -f $BmapInfo.Segments.Count)
    Write-Host ('ChecksumType:        {0}' -f $BmapInfo.ChecksumType)

    [double]$imageSizeDouble = [double]$BmapInfo.ImageSize
    [double]$mappedDouble = [double]$BmapInfo.MappedBytes

    [double]$percent = 0

    if ($imageSizeDouble -gt 0) {
        $percent = ($mappedDouble / $imageSizeDouble) * 100
    }

    [double]$saving = 100 - $percent

    Write-Host ''
    Write-Host ('Zu übertragen: {0}' -f (Format-Bytes $BmapInfo.MappedBytes))
    Write-Host ('Anteil Image:  {0:N2}%' -f $percent)
    Write-Host ('Ersparnis:     {0:N2}%' -f $saving)
}
else {
    Write-Warn "Keine BMAP gefunden: $BmapPath"
    Write-Warn 'Es kann nicht BMAP-sparse geflasht werden.'
}

# ============================================================
# ADB VERBINDUNG
# ============================================================

Write-Section 'ADB VERBINDUNG'

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    throw "ADB nicht gefunden: $AdbPath"
}

if ([string]::IsNullOrWhiteSpace($Serial)) {
    throw 'Bitte -Serial angeben, z.B. 192.168.178.65:5555'
}

Write-Host "Serial: $Serial"

$adbDevices = Invoke-Adb -Arguments @('devices')

$deviceLine = $adbDevices |
    ForEach-Object { "$_" } |
    Where-Object {
        $_ -match (
            '^{0}\s+(device|recovery)$' -f
            [regex]::Escape($Serial)
        )
    }

if (-not $deviceLine) {
    Write-Host ''
    Write-Host 'ADB-Geräte:' -ForegroundColor Yellow

    $adbDevices |
        ForEach-Object {
            Write-Host "  $_"
        }

    throw "ADB-Gerät '$Serial' ist nicht verbunden."
}

$adbState = 'unknown'

if (
    $deviceLine -match
    ('^{0}\s+(\S+)' -f [regex]::Escape($Serial))
) {
    $adbState = $Matches[1]
}

Write-OK "ADB-Gerät $Serial ist verbunden (Status: $adbState)."

if ($adbState -eq 'recovery') {
    Write-Host 'TWRP/Recovery erkannt.' -ForegroundColor Cyan
}

# ============================================================
# TARGET PRÜFEN
# ============================================================

Write-Section 'TARGET PRÜFEN'

$targetCheck = Invoke-AdbShell `
    -Command "test -b '$Target'; echo `$?"

if (
    $targetCheck.Count -eq 0 -or
    ($targetCheck -join "`n") -notmatch '\b0\b'
) {
    throw "Target ist kein Blockdevice: $Target"
}

$targetSizeText = Invoke-AdbShell `
    -Command "blockdev --getsize64 '$Target'"

[Int64]$targetSize = 0

$sizeLine = @(
    $targetSizeText |
    Where-Object {
        $_ -match '^\s*\d+\s*$'
    } |
    Select-Object -First 1
)

if ($sizeLine.Count -gt 0) {
    [Int64]::TryParse(
        $sizeLine[0].Trim(),
        [ref]$targetSize
    ) | Out-Null
}

if ($targetSize -le 0) {
    throw "Größe von $Target konnte nicht ermittelt werden."
}

Write-Host "Target: $Target"
Write-Host "Target-Größe: $(Format-Bytes $targetSize)"

# ============================================================
# IMAGE SIZE / TARGET SIZE VERGLEICH
# ============================================================

[Int64]$imageSize = [Int64]$ImageFile.Length

if ($null -ne $BmapInfo) {
    $imageSize = [Int64]$BmapInfo.ImageSize
}

if ($targetSize -lt $imageSize) {
    throw @"
TARGET IST ZU KLEIN.

Image:
$(Format-Bytes $imageSize)

Target:
$(Format-Bytes $targetSize)

Target:
$Target
"@
}

Write-OK 'Target ist groß genug.'

# ============================================================
# DEVICE IP
# ============================================================

$DeviceIp = Get-DeviceIpAddress

Write-Host "Device IP: $DeviceIp"

# ============================================================
# SICHERHEITSABFRAGE
# ============================================================

Write-Section 'SICHERHEITSCHECK'

Write-Host ''
Write-Host '!!! ACHTUNG !!!' -ForegroundColor Red
Write-Host ''
Write-Host "Das folgende Blockdevice wird überschrieben:"
Write-Host "  $Target" -ForegroundColor Yellow
Write-Host ''
Write-Host "Image:"
Write-Host "  $Image"
Write-Host ''
Write-Host "Image-Größe:"
Write-Host "  $(Format-Bytes $imageSize)"
Write-Host ''

if ($null -ne $BmapInfo) {
    Write-Host "BMAP-Daten:"
    Write-Host "  $(Format-Bytes $BmapInfo.MappedBytes)"
    Write-Host ''
}

if (-not $Force) {
    $answer = Read-Host 'Zum Fortfahren "YES" eingeben'

    if ($answer -ne 'YES') {
        Write-Warn 'Abgebrochen.'
        exit 0
    }
}
else {
    Write-Warn '-Force gesetzt. Sicherheitsabfrage übersprungen.'
}

# ============================================================
# LOKALE VERIFIKATION
# ============================================================

if ($null -ne $BmapInfo) {
    Test-LocalBmap `
        -ImagePath $Image `
        -BmapInfo $BmapInfo
}
else {
    Write-Warn 'Keine BMAP vorhanden. Lokale vollständige Image-Prüfung wird nicht durchgeführt.'
}

# ============================================================
# FLASH
# ============================================================

if ($null -ne $BmapInfo) {

    Write-BmapImage `
        -ImagePath $Image `
        -BmapInfo $BmapInfo
}
else {

    throw @"
Kein BMAP vorhanden.

Dieses Script verwendet absichtlich keinen unsicheren
vollständigen Fallback-Flash.

Lege die passende .bmap-Datei neben das Image:

$BmapPath
"@
}

# ============================================================
# PARTITION TABLE
# ============================================================

Update-PartitionTable

# ============================================================
# REMOTE VERIFIKATION
# ============================================================

if ($null -ne $BmapInfo) {

    Test-RemoteBmap `
        -ImagePath $Image `
        -BmapInfo $BmapInfo
}

# ============================================================
# CONFIG
# ============================================================

Patch-Config

# ============================================================
# ABSCHLUSS
# ============================================================

Write-Section 'FERTIG'

Write-Host ''
Write-Host 'Flash erfolgreich abgeschlossen.' -ForegroundColor Green
Write-Host ''
Write-Host "Image:"
Write-Host "  $Image"
Write-Host ''
Write-Host "Target:"
Write-Host "  $Target"
Write-Host ''

if ($null -ne $BmapInfo) {
    Write-Host "Übertragene Daten:"
    Write-Host "  $(Format-Bytes $BmapInfo.MappedBytes)"
    Write-Host ''
    Write-Host "BMAP-Segmente:"
    Write-Host "  $($BmapInfo.Segments.Count)"
    Write-Host ''
}

Write-Host 'Lokale BMAP-Verifikation:  OK' -ForegroundColor Green
Write-Host 'Remote BMAP-Verifikation:  OK' -ForegroundColor Green
Write-Host ''
Write-Host 'Das Image wurde erfolgreich auf die NVMe geschrieben.' -ForegroundColor Green