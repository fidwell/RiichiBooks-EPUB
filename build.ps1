function Write-UInt16LE($stream, [uint16]$v) {
    $stream.WriteByte($v -band 0xFF)
    $stream.WriteByte(($v -shr 8) -band 0xFF)
}
function Write-UInt32LE($stream, [uint32]$v) {
    $stream.WriteByte($v -band 0xFF)
    $stream.WriteByte(($v -shr 8) -band 0xFF)
    $stream.WriteByte(($v -shr 16) -band 0xFF)
    $stream.WriteByte(($v -shr 24) -band 0xFF)
}

function Get-CRC32 {
    param([byte[]]$data)
    $crc = [uint32]::MaxValue
    $table = 0..255 | ForEach-Object {
        $c = [uint32]$_
        for ($i = 0; $i -lt 8; $i++) {
            if ($c -band 1) { $c = 0xEDB88320 -bxor ($c -shr 1) }
            else { $c = $c -shr 1 }
        }
        $c
    }
    foreach ($b in $data) {
        $crc = $table[($crc -bxor $b) -band 0xFF] -bxor ($crc -shr 8)
    }
    return $crc -bxor 0xFFFFFFFF
}

function Add-ZipEntry {
    param(
        [System.IO.Stream]$stream,
        [string]$entryName,
        [byte[]]$data,
        [bool]$compress,
        [System.Collections.Generic.List[object]]$centralDir
    )

    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($entryName)
    $crc = Get-CRC32 $data
    $uncompressedSize = [uint32]$data.Length
    $offset = [uint32]$stream.Position

    if ($compress) {
        $ms = New-Object System.IO.MemoryStream
        $deflate = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionLevel]::Optimal)
        $deflate.Write($data, 0, $data.Length)
        $deflate.Dispose()
        $compressedData = $ms.ToArray()
        $compressionMethod = [uint16]8  # Deflate
    }
    else {
        $compressedData = $data
        $compressionMethod = [uint16]0  # Store
    }

    $compressedSize = [uint32]$compressedData.Length

    # Local file header
    Write-UInt32LE $stream 0x04034b50        # signature
    Write-UInt16LE $stream 20               # version needed
    Write-UInt16LE $stream 0                # flags
    Write-UInt16LE $stream $compressionMethod
    Write-UInt16LE $stream 0                # mod time
    Write-UInt16LE $stream 0                # mod date
    Write-UInt32LE $stream $crc
    Write-UInt32LE $stream $compressedSize
    Write-UInt32LE $stream $uncompressedSize
    Write-UInt16LE $stream ([uint16]$nameBytes.Length)
    Write-UInt16LE $stream 0                # extra field length
    $stream.Write($nameBytes, 0, $nameBytes.Length)
    $stream.Write($compressedData, 0, $compressedData.Length)

    $centralDir.Add(@{
            Name              = $nameBytes
            CompressionMethod = $compressionMethod
            CRC               = $crc
            CompressedSize    = $compressedSize
            UncompressedSize  = $uncompressedSize
            Offset            = $offset
        })
}

function New-Epub {
    param(
        [string]$SourceDir,
        [string]$OutputFile
    )

    $SourceDir = (Resolve-Path $SourceDir).Path.TrimEnd('\')
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)
    if (Test-Path $OutputFile) { Remove-Item $OutputFile }

    $mimetypePath = Join-Path $SourceDir "mimetype"

    $stream = [System.IO.File]::Open($OutputFile, 'Create')
    $centralDir = [System.Collections.Generic.List[object]]::new()

    try {
        # mimetype must be the first entry in the archive and stored uncompressed
        if (-not (Test-Path -LiteralPath $mimetypePath)) {
            throw "mimetype not found in $SourceDir"
        }
        Add-ZipEntry $stream "mimetype" ([System.IO.File]::ReadAllBytes($mimetypePath)) $false $centralDir

        # All other files, compressed, at the archive root
        Get-ChildItem -Path $SourceDir -Recurse -File |
        Where-Object { $_.FullName -ne $mimetypePath } |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($SourceDir.Length + 1).Replace('\', '/')
            $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
            Add-ZipEntry $stream $relativePath $bytes $true $centralDir
        }

        # Central directory
        $cdOffset = [uint32]($stream.Position)
        foreach ($entry in $centralDir) {
            Write-UInt32LE $stream 0x02014b50         # CD signature
            Write-UInt16LE $stream 20                 # version made by
            Write-UInt16LE $stream 20                 # version needed
            Write-UInt16LE $stream 0                  # flags
            Write-UInt16LE $stream $entry.CompressionMethod
            Write-UInt16LE $stream 0                  # mod time
            Write-UInt16LE $stream 0                  # mod date
            Write-UInt32LE $stream $entry.CRC
            Write-UInt32LE $stream $entry.CompressedSize
            Write-UInt32LE $stream $entry.UncompressedSize
            Write-UInt16LE $stream ([uint16]$entry.Name.Length)
            Write-UInt16LE $stream 0                  # extra length
            Write-UInt16LE $stream 0                  # comment length
            Write-UInt16LE $stream 0                  # disk start
            Write-UInt16LE $stream 0                  # internal attrs
            Write-UInt32LE $stream 0                  # external attrs
            Write-UInt32LE $stream $entry.Offset
            $stream.Write($entry.Name, 0, $entry.Name.Length)
        }

        $cdSize = [uint32]($stream.Position - $cdOffset)

        # End of central directory
        Write-UInt32LE $stream 0x06054b50             # EOCD signature
        Write-UInt16LE $stream 0                      # disk number
        Write-UInt16LE $stream 0                      # disk with CD
        Write-UInt16LE $stream ([uint16]$centralDir.Count)
        Write-UInt16LE $stream ([uint16]$centralDir.Count)
        Write-UInt32LE $stream $cdSize
        Write-UInt32LE $stream $cdOffset
        Write-UInt16LE $stream 0                      # comment length

    }
    finally {
        $stream.Dispose()
    }

    Write-Host "Created: $OutputFile"
}

$src = Join-Path $PSScriptRoot "src"
$dist = Join-Path $PSScriptRoot "dist"

if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "No src/ found in $PSScriptRoot"
    exit 1
}

New-Item -Path $dist -ItemType Directory -Force | Out-Null
$outputFile = Join-Path $dist "RiichiBook1.epub"

# Stamp modified time in content.opf
$opf = Join-Path $src "OEBPS\content.opf"
if (Test-Path $opf) {
    $now = (Get-Date).ToUniversalTime()
    $content = [System.IO.File]::ReadAllText($opf)
    $content = $content -replace '<meta property="dcterms:modified">[^<]*</meta>',
        "<meta property=`"dcterms:modified`">$($now.ToString("yyyy-MM-ddTHH:mm:ssZ"))</meta>"
    [System.IO.File]::WriteAllText($opf, $content, (New-Object System.Text.UTF8Encoding($false)))
}

New-Epub -SourceDir $src -OutputFile $outputFile
