Param(
  [Parameter(Mandatory = $true)]
  [string]$SourceZipPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [Int64]$PartSizeBytes = 1900MB
)

$ErrorActionPreference = "Stop"

function Get-FileSha256 {
  param([string]$Path)

  return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

$sourceFile = Get-Item (Resolve-Path $SourceZipPath)
if ($sourceFile.Length -le 0) {
  throw "Source ZIP is empty: $($sourceFile.FullName)"
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path $outputRoot) {
  Remove-Item $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$archiveName = $sourceFile.Name
$archiveBaseName = [System.IO.Path]::GetFileNameWithoutExtension($archiveName)
$manifestPath = Join-Path $outputRoot ($archiveBaseName + ".manifest.json")

$bufferSize = 4MB
$buffer = New-Object byte[] $bufferSize
$parts = New-Object System.Collections.Generic.List[object]
$inputStream = [System.IO.File]::OpenRead($sourceFile.FullName)

try {
  $partIndex = 0
  while ($inputStream.Position -lt $inputStream.Length) {
    $partIndex += 1
    $partName = "{0}.part{1:D2}" -f $archiveName, $partIndex
    $partPath = Join-Path $outputRoot $partName
    $partStream = [System.IO.File]::Open($partPath, [System.IO.FileMode]::CreateNew)
    $writtenToPart = 0L

    try {
      while ($writtenToPart -lt $PartSizeBytes -and $inputStream.Position -lt $inputStream.Length) {
        $remainingForPart = $PartSizeBytes - $writtenToPart
        $readLength = [Math]::Min([Int64]$buffer.Length, $remainingForPart)
        $read = $inputStream.Read($buffer, 0, [int]$readLength)
        if ($read -le 0) {
          break
        }

        $partStream.Write($buffer, 0, $read)
        $writtenToPart += $read
      }
    }
    finally {
      $partStream.Dispose()
    }

    $partInfo = Get-Item $partPath
    $parts.Add([ordered]@{
      name = $partInfo.Name
      bytes = $partInfo.Length
      sha256 = Get-FileSha256 -Path $partInfo.FullName
    }) | Out-Null
  }
}
finally {
  $inputStream.Dispose()
}

$manifest = [ordered]@{
  format_version = 2
  archive_name = $archiveName
  archive_bytes = $sourceFile.Length
  archive_sha256 = Get-FileSha256 -Path $sourceFile.FullName
  part_size_bytes = $PartSizeBytes
  created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  parts = $parts
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host ("Split asset ready: {0} part(s), total bytes {1}" -f $parts.Count, $sourceFile.Length)
Write-Host ("Manifest: {0}" -f $manifestPath)
