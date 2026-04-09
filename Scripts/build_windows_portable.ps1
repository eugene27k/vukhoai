Param(
  [string]$PortableName = "Vukho.AI-Windows-Portable",
  [string]$FfmpegDir = "",
  [switch]$SkipNpmInstall,
  [switch]$OpenFolder
)

$ErrorActionPreference = "Stop"

function Test-IsWindowsHost {
  if (Get-Variable -Name "IsWindows" -ErrorAction SilentlyContinue) {
    return [bool]$IsWindows
  }

  return $env:OS -eq "Windows_NT"
}

function Require-Command {
  param(
    [string]$Name,
    [string]$Hint
  )

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw "$Name was not found. $Hint"
  }

  return $command.Source
}

function Invoke-NativeCommand {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList = @()
  )

  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    $joinedArgs = ($ArgumentList | ForEach-Object { $_ }) -join " "
    throw ("Command failed with exit code {0}: {1} {2}" -f $LASTEXITCODE, $FilePath, $joinedArgs).Trim()
  }
}

function Resolve-PythonLauncher {
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    return $py.Source
  }

  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($python) {
    return $python.Source
  }

  throw "Python was not found. Install Python 3.11 or newer first."
}

function Ensure-Venv {
  param(
    [string]$PythonLauncher,
    [string]$VersionFlag,
    [string]$VenvPath,
    [string]$RequirementsPath
  )

  $venvPython = Join-Path $VenvPath "Scripts\python.exe"
  if (-not (Test-Path $venvPython)) {
    $launcherLeaf = [System.IO.Path]::GetFileNameWithoutExtension($PythonLauncher).ToLowerInvariant()
    if ($launcherLeaf -eq "py") {
      Invoke-NativeCommand -FilePath $PythonLauncher -ArgumentList @($VersionFlag, "-m", "venv", $VenvPath)
    } else {
      Invoke-NativeCommand -FilePath $PythonLauncher -ArgumentList @("-m", "venv", $VenvPath)
    }
  }

  Invoke-NativeCommand -FilePath $venvPython -ArgumentList @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel")
  Invoke-NativeCommand -FilePath $venvPython -ArgumentList @("-m", "pip", "install", "-r", $RequirementsPath)
  return $venvPython
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")
$appRoot = Join-Path $repoRoot "ghostmic-cross"
$tauriRoot = Join-Path $appRoot "src-tauri"
$portableBuildRoot = Join-Path $appRoot "portable-build"
$portableRoot = Join-Path $portableBuildRoot "windows\$PortableName"
$seedPath = Join-Path $portableBuildRoot "portable-state.local.json"
$resourceRoot = Join-Path $portableRoot "resources"
$mainRequirements = Join-Path $repoRoot "Scripts\requirements.txt"
$diarizationRequirements = Join-Path $repoRoot "Scripts\requirements-diarization.txt"

if (-not (Test-IsWindowsHost)) {
  throw "This script must be run on Windows."
}

$null = Require-Command -Name "cargo" -Hint "Install Rust with rustup first."
$null = Require-Command -Name "npm" -Hint "Install Node.js 20+ first."
$pythonLauncher = Resolve-PythonLauncher

try {
  Invoke-NativeCommand -FilePath $pythonLauncher -ArgumentList @((Join-Path $repoRoot "Scripts\export_portable_state.py"))
} catch {
  Write-Warning "Portable settings export was skipped: $($_.Exception.Message)"
}

$null = Ensure-Venv `
  -PythonLauncher $pythonLauncher `
  -VersionFlag "-3.11" `
  -VenvPath (Join-Path $repoRoot ".venv") `
  -RequirementsPath $mainRequirements

$null = Ensure-Venv `
  -PythonLauncher $pythonLauncher `
  -VersionFlag "-3.11" `
  -VenvPath (Join-Path $repoRoot ".venv-diarization") `
  -RequirementsPath $diarizationRequirements

Push-Location $appRoot
try {
  if (-not $SkipNpmInstall) {
    Invoke-NativeCommand -FilePath "npm" -ArgumentList @("install")
  }

  Invoke-NativeCommand -FilePath "npm" -ArgumentList @("run", "tauri", "build", "--", "--no-bundle")
}
finally {
  Pop-Location
}

$releaseExe = Get-ChildItem (Join-Path $tauriRoot "target\release\*.exe") |
  Where-Object { $_.Name -notmatch "(?i)(setup|installer|updater)" } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $releaseExe) {
  throw "Could not find the built Windows executable under src-tauri\target\release."
}

if (Test-Path $portableRoot) {
  Remove-Item $portableRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $resourceRoot | Out-Null

Copy-Item $releaseExe.FullName (Join-Path $portableRoot $releaseExe.Name)
Copy-Item (Join-Path $tauriRoot "resources\transcribe.py") (Join-Path $resourceRoot "transcribe.py")

if (Test-Path $seedPath) {
  Copy-Item $seedPath (Join-Path $portableRoot "portable-state.json")
}

foreach ($envName in @(".venv", ".venv-diarization")) {
  $sourceEnv = Join-Path $repoRoot $envName
  if (Test-Path $sourceEnv) {
    Copy-Item $sourceEnv (Join-Path $portableRoot $envName) -Recurse -Force
  }
}

if ($FfmpegDir) {
  foreach ($binaryName in @("ffmpeg.exe", "ffprobe.exe")) {
    $sourceBinary = Join-Path $FfmpegDir $binaryName
    if (Test-Path $sourceBinary) {
      Copy-Item $sourceBinary (Join-Path $portableRoot $binaryName) -Force
    }
  }
}

Write-Host ""
Write-Host "Portable Windows build created:"
Write-Host "  $portableRoot"
Write-Host ""
Write-Host "Open this file on Windows:"
Write-Host "  $(Join-Path $portableRoot $releaseExe.Name)"
Write-Host ""
if (Test-Path $seedPath) {
  Write-Host "portable-state.json included: yes"
} else {
  Write-Host "portable-state.json included: no"
}
Write-Host "Bundled .venv included: $(Test-Path (Join-Path $portableRoot '.venv'))"
Write-Host "Bundled .venv-diarization included: $(Test-Path (Join-Path $portableRoot '.venv-diarization'))"

if ($OpenFolder) {
  Invoke-Item $portableRoot
}
