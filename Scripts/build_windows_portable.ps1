Param(
  [string]$PortableName = "Vukho.AI-Windows-Portable",
  [string]$FfmpegDir = "",
  [string]$PortablePythonVersion = "3.11.9",
  [switch]$SkipNpmInstall,
  [switch]$SkipDiarizationRuntime,
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

  throw "Python 3.11 was not found. Install Python 3.11 on the build machine first."
}

function Get-PythonMajorMinor {
  param([string]$PythonExe)

  $output = & $PythonExe -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')" 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = ($output | Out-String).Trim()
    throw "Could not read Python version from $PythonExe. $text"
  }

  return (($output | Select-Object -First 1) -as [string]).Trim()
}

function Ensure-BuildVenv {
  param(
    [string]$PythonLauncher,
    [string]$VersionFlag,
    [string]$VenvPath,
    [string]$ExpectedMajorMinor
  )

  $venvPython = Join-Path $VenvPath "Scripts\python.exe"
  $needsCreate = -not (Test-Path $venvPython)

  if (-not $needsCreate) {
    $actualMajorMinor = Get-PythonMajorMinor -PythonExe $venvPython
    if ($actualMajorMinor -ne $ExpectedMajorMinor) {
      Remove-Item $VenvPath -Recurse -Force
      $needsCreate = $true
    }
  }

  if ($needsCreate) {
    $launcherLeaf = [System.IO.Path]::GetFileNameWithoutExtension($PythonLauncher).ToLowerInvariant()
    if ($launcherLeaf -eq "py") {
      Invoke-NativeCommand -FilePath $PythonLauncher -ArgumentList @($VersionFlag, "-m", "venv", $VenvPath)
    } else {
      Invoke-NativeCommand -FilePath $PythonLauncher -ArgumentList @("-m", "venv", $VenvPath)
    }
  }

  $actualMajorMinor = Get-PythonMajorMinor -PythonExe $venvPython
  if ($actualMajorMinor -ne $ExpectedMajorMinor) {
    throw "The build Python is $actualMajorMinor, but portable Python is $ExpectedMajorMinor. Install Python $ExpectedMajorMinor on the build machine."
  }

  Invoke-NativeCommand -FilePath $venvPython -ArgumentList @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel")
  return $venvPython
}

function Invoke-DownloadFile {
  param(
    [string]$Uri,
    [string]$OutFile
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $request = @{
    Uri = $Uri
    OutFile = $OutFile
    Headers = @{
      "User-Agent" = "VukhoAI-Windows-Portable-Build"
    }
  }

  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $request.UseBasicParsing = $true
  }

  Invoke-WebRequest @request | Out-Null
}

function Initialize-EmbeddedPython {
  param(
    [string]$Version,
    [string]$Destination,
    [string]$DownloadRoot
  )

  $zipName = "python-$Version-embed-amd64.zip"
  $zipPath = Join-Path $DownloadRoot $zipName
  $downloadUrl = "https://www.python.org/ftp/python/$Version/$zipName"

  New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null

  if (-not (Test-Path $zipPath)) {
    Write-Host "Downloading portable Python $Version..."
    Invoke-DownloadFile -Uri $downloadUrl -OutFile $zipPath
  }

  if (Test-Path $Destination) {
    Remove-Item $Destination -Recurse -Force
  }

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Expand-Archive -Path $zipPath -DestinationPath $Destination -Force

  $sitePackages = Join-Path $Destination "Lib\site-packages"
  New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null

  $pthFile = Get-ChildItem -Path $Destination -Filter "python*._pth" -File |
    Select-Object -First 1

  if ($null -eq $pthFile) {
    throw "Embedded Python _pth file was not found in $Destination."
  }

  $updatedLines = New-Object System.Collections.Generic.List[string]
  $hasSitePackages = $false
  $hasImportSite = $false

  foreach ($line in Get-Content $pthFile.FullName) {
    $trimmed = $line.Trim()

    if ($trimmed -eq "Lib\site-packages") {
      $hasSitePackages = $true
    }

    if ($trimmed -eq "import site" -or $trimmed -eq "#import site") {
      if (-not $hasImportSite) {
        [void]$updatedLines.Add("import site")
      }
      $hasImportSite = $true
      continue
    }

    [void]$updatedLines.Add($line)
  }

  if (-not $hasSitePackages) {
    [void]$updatedLines.Add("Lib\site-packages")
  }

  if (-not $hasImportSite) {
    [void]$updatedLines.Add("import site")
  }

  Set-Content -Path $pthFile.FullName -Encoding ASCII -Value $updatedLines.ToArray()

  $pythonExe = Join-Path $Destination "python.exe"
  if (-not (Test-Path $pythonExe)) {
    throw "Embedded python.exe was not found in $Destination."
  }

  return $pythonExe
}

function Install-TargetRequirements {
  param(
    [string]$BuildPython,
    [string]$TargetPythonRoot,
    [string]$RequirementsPath
  )

  $sitePackages = Join-Path $TargetPythonRoot "Lib\site-packages"
  New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null

  Invoke-NativeCommand -FilePath $BuildPython -ArgumentList @(
    "-m",
    "pip",
    "install",
    "--upgrade",
    "--prefer-binary",
    "--no-warn-script-location",
    "--target",
    $sitePackages,
    "-r",
    $RequirementsPath
  )
}

function Test-PythonModules {
  param(
    [string]$PythonExe,
    [string[]]$RequiredModules
  )

  $moduleList = ($RequiredModules | ForEach-Object {
    '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"'
  }) -join ", "

  $script = @"
import importlib
import sys

modules = [$moduleList]

def has_module(name):
    try:
        if name == "faster_whisper":
            from faster_whisper import WhisperModel  # noqa: F401
            return True
        importlib.import_module(name)
        return True
    except Exception:
        return False

missing = [name for name in modules if not has_module(name)]
if missing:
    print("Missing modules: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

print("Validated modules: " + ", ".join(modules))
"@

  $hadPythonHome = Test-Path Env:\PYTHONHOME
  $hadPythonPath = Test-Path Env:\PYTHONPATH
  $oldPythonHome = $env:PYTHONHOME
  $oldPythonPath = $env:PYTHONPATH

  try {
    Remove-Item Env:\PYTHONHOME -ErrorAction SilentlyContinue
    Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
    Invoke-NativeCommand -FilePath $PythonExe -ArgumentList @("-c", $script)
  }
  finally {
    if ($hadPythonHome) {
      $env:PYTHONHOME = $oldPythonHome
    } else {
      Remove-Item Env:\PYTHONHOME -ErrorAction SilentlyContinue
    }

    if ($hadPythonPath) {
      $env:PYTHONPATH = $oldPythonPath
    } else {
      Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
    }
  }
}

function New-PortablePythonRuntime {
  param(
    [string]$RuntimeName,
    [string]$Version,
    [string]$BuildPython,
    [string]$DownloadRoot,
    [string]$PortableRoot,
    [string]$RequirementsPath,
    [string[]]$RequiredModules
  )

  $runtimeRoot = Join-Path $PortableRoot $RuntimeName
  $pythonExe = Initialize-EmbeddedPython `
    -Version $Version `
    -Destination $runtimeRoot `
    -DownloadRoot $DownloadRoot

  Write-Host "Installing Python packages for $RuntimeName..."
  Install-TargetRequirements `
    -BuildPython $BuildPython `
    -TargetPythonRoot $runtimeRoot `
    -RequirementsPath $RequirementsPath

  Test-PythonModules -PythonExe $pythonExe -RequiredModules $RequiredModules
  return $pythonExe
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")
$appRoot = Join-Path $repoRoot "ghostmic-cross"
$tauriRoot = Join-Path $appRoot "src-tauri"
$portableBuildRoot = Join-Path $appRoot "portable-build"
$portableRoot = Join-Path $portableBuildRoot "windows\$PortableName"
$downloadRoot = Join-Path $portableBuildRoot "downloads"
$seedPath = Join-Path $portableBuildRoot "portable-state.local.json"
$resourceRoot = Join-Path $portableRoot "resources"
$mainRequirements = Join-Path $repoRoot "Scripts\requirements.txt"
$diarizationRequirements = Join-Path $repoRoot "Scripts\requirements-diarization.txt"
$portablePythonMajorMinor = (($PortablePythonVersion -split "\.") | Select-Object -First 2) -join "."
$buildVenvPath = Join-Path $portableBuildRoot "python-build-$portablePythonMajorMinor"

if (-not (Test-IsWindowsHost)) {
  throw "This script must be run on Windows."
}

$null = Require-Command -Name "cargo" -Hint "Install Rust with rustup first."
$null = Require-Command -Name "npm" -Hint "Install Node.js 20+ first."
$pythonLauncher = Resolve-PythonLauncher
$buildPython = Ensure-BuildVenv `
  -PythonLauncher $pythonLauncher `
  -VersionFlag "-$portablePythonMajorMinor" `
  -VenvPath $buildVenvPath `
  -ExpectedMajorMinor $portablePythonMajorMinor

try {
  Invoke-NativeCommand -FilePath $buildPython -ArgumentList @((Join-Path $repoRoot "Scripts\export_portable_state.py"))
} catch {
  Write-Warning "Portable settings export was skipped: $($_.Exception.Message)"
}

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

$mainPython = New-PortablePythonRuntime `
  -RuntimeName "python" `
  -Version $PortablePythonVersion `
  -BuildPython $buildPython `
  -DownloadRoot $downloadRoot `
  -PortableRoot $portableRoot `
  -RequirementsPath $mainRequirements `
  -RequiredModules @("faster_whisper")

$diarizationPython = $null
if (-not $SkipDiarizationRuntime) {
  $diarizationPython = New-PortablePythonRuntime `
    -RuntimeName "python-diarization" `
    -Version $PortablePythonVersion `
    -BuildPython $buildPython `
    -DownloadRoot $downloadRoot `
    -PortableRoot $portableRoot `
    -RequirementsPath $diarizationRequirements `
    -RequiredModules @("faster_whisper", "whisperx", "pyannote.audio")
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
Write-Host "Bundled Python runtime included: $(Test-Path $mainPython)"
Write-Host "Bundled diarization runtime included: $($null -ne $diarizationPython -and (Test-Path $diarizationPython))"
Write-Host "Bundled ffmpeg included: $(Test-Path (Join-Path $portableRoot 'ffmpeg.exe'))"

if ($OpenFolder) {
  Invoke-Item $portableRoot
}
