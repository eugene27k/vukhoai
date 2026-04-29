Param(
  [Parameter(Mandatory = $true)]
  [string]$SourceRoot,

  [Parameter(Mandatory = $true)]
  [string]$ZipPath
)

$ErrorActionPreference = "Stop"

$resolvedSource = Resolve-Path $SourceRoot
$sourceRootPath = [System.IO.Path]::GetFullPath($resolvedSource.Path)

if (-not (Test-Path $sourceRootPath -PathType Container)) {
  throw "Source directory was not found: $sourceRootPath"
}

$zipDestination = [System.IO.Path]::GetFullPath($ZipPath)
$zipParent = Split-Path -Parent $zipDestination
if (-not [string]::IsNullOrWhiteSpace($zipParent)) {
  New-Item -ItemType Directory -Force -Path $zipParent | Out-Null
}

if (Test-Path $zipDestination) {
  Remove-Item $zipDestination -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$files = Get-ChildItem -Path $sourceRootPath -Recurse -File
$sourcePrefix = $sourceRootPath.TrimEnd('\', '/')
$rootEntryName = Split-Path -Leaf $sourceRootPath
$zipStream = [System.IO.File]::Open($zipDestination, [System.IO.FileMode]::CreateNew)

try {
  $archive = [System.IO.Compression.ZipArchive]::new(
    $zipStream,
    [System.IO.Compression.ZipArchiveMode]::Create,
    $false
  )

  try {
    $index = 0
    foreach ($file in $files) {
      $index += 1
      $entryName = $file.FullName.Substring($sourcePrefix.Length).TrimStart('\', '/')
      $entryName = (($rootEntryName + "\" + $entryName) -replace '\\', '/')

      if ([string]::IsNullOrWhiteSpace($entryName)) {
        continue
      }

      Write-Progress `
        -Id 2 `
        -Activity "Packaging Windows portable ZIP" `
        -Status $entryName `
        -PercentComplete ([Math]::Round(($index * 100.0) / [Math]::Max($files.Count, 1), 0))

      $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = $file.LastWriteTime

      $inputStream = [System.IO.File]::OpenRead($file.FullName)
      $entryStream = $entry.Open()

      try {
        $inputStream.CopyTo($entryStream)
      }
      finally {
        $entryStream.Dispose()
        $inputStream.Dispose()
      }
    }
  }
  finally {
    Write-Progress -Id 2 -Activity "Packaging Windows portable ZIP" -Completed
    $archive.Dispose()
  }
}
finally {
  $zipStream.Dispose()
}

$zipInfo = Get-Item $zipDestination
Write-Host ("Created ZIP: {0} ({1:N1} MB)" -f $zipInfo.FullName, ($zipInfo.Length / 1MB))
