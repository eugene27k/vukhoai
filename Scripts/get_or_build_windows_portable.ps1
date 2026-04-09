Param(
  [string]$Repository = "eugene27k/vukhoai",
  [string]$ReleaseTag = "windows-portable-latest",
  [string]$AssetName = "Vukho.AI-Windows-Portable.zip",
  [switch]$ForceDownload,
  [switch]$ForceLocalBuild,
  [switch]$OpenFolder
)

$ErrorActionPreference = "Stop"

function Test-IsWindowsHost {
  if (Get-Variable -Name "IsWindows" -ErrorAction SilentlyContinue) {
    return [bool]$IsWindows
  }

  return $env:OS -eq "Windows_NT"
}

function Write-Step {
  param([string]$Message)

  Write-Host ""
  Write-Host $Message
}

function Test-CommandExists {
  param([string]$Name)

  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-LocalBuildPrerequisites {
  $hasPython = (Test-CommandExists "py") -or (Test-CommandExists "python")
  return (Test-CommandExists "cargo") -and (Test-CommandExists "npm") -and $hasPython
}

function Invoke-PortableDownload {
  param(
    [string]$Uri,
    [string]$OutFile
  )

  $request = @{
    Uri = $Uri
    OutFile = $OutFile
    Headers = @{
      "User-Agent" = "VukhoAI-Windows-Bootstrap"
    }
  }

  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $request.UseBasicParsing = $true
  }

  Invoke-WebRequest @request | Out-Null
}

function Resolve-PortableExe {
  param([string]$PortableRoot)

  return Get-ChildItem -Path $PortableRoot -Filter "*.exe" -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "(?i)(setup|installer|updater)" } |
    Sort-Object FullName |
    Select-Object -First 1
}

if (-not (Test-IsWindowsHost)) {
  throw "This script must be run on Windows."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")
$appRoot = Join-Path $repoRoot "ghostmic-cross"
$downloadRoot = Join-Path $appRoot "portable-build\downloads"
$windowsRoot = Join-Path $appRoot "portable-build\windows"
$portableRoot = Join-Path $windowsRoot "Vukho.AI-Windows-Portable"
$zipPath = Join-Path $downloadRoot $AssetName
$releaseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag/$AssetName"
$localBuildScript = Join-Path $scriptRoot "build_windows_portable.ps1"

if (-not (Test-Path $localBuildScript)) {
  throw "Missing local build script: $localBuildScript"
}

if (-not $ForceLocalBuild) {
  Write-Step "Checking for the latest ready-to-run Windows build..."

  try {
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $windowsRoot | Out-Null

    if (Test-Path $zipPath) {
      Remove-Item $zipPath -Force
    }

    Invoke-PortableDownload -Uri $releaseUrl -OutFile $zipPath

    if (Test-Path $portableRoot) {
      Remove-Item $portableRoot -Recurse -Force
    }

    Expand-Archive -Path $zipPath -DestinationPath $windowsRoot -Force

    $portableExe = Resolve-PortableExe -PortableRoot $portableRoot
    if ($null -eq $portableExe) {
      throw "The downloaded archive did not contain a runnable .exe."
    }

    Write-Host "Ready-to-run Windows app downloaded successfully."
    Write-Host "Path: $portableRoot"

    if ($OpenFolder) {
      Invoke-Item $portableRoot
    } else {
      Invoke-Item $portableExe.FullName
    }

    exit 0
  } catch {
    Write-Warning "Prebuilt Windows app download failed: $($_.Exception.Message)"

    if ($ForceDownload) {
      throw "Could not download the prebuilt Windows app. Try again later or install local build prerequisites."
    }
  }
}

if (-not (Test-LocalBuildPrerequisites)) {
  throw @"
No ready-made Windows app could be downloaded, and this machine is not set up for local compilation.

To continue, choose one of these paths:
- wait for the GitHub release asset to appear and rerun this script, or
- install Rust (cargo), Node.js, Python, and Visual Studio Build Tools, then rerun this script.
"@
}

Write-Step "Falling back to a local Windows build from source..."
& $localBuildScript -OpenFolder:$OpenFolder
