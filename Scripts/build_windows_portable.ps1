Param(
  [string]$PortableName = "Vukho.AI-Windows-Portable",
  [string]$FfmpegDir = "",
  [string]$PortablePythonVersion = "3.11.9",
  [switch]$SkipNpmInstall,
  [switch]$SkipDiarizationRuntime,
  [switch]$OpenFolder
)

$ErrorActionPreference = "Stop"

if ($SkipDiarizationRuntime) {
  throw "Diarization runtime is mandatory for Windows portable builds. Remove -SkipDiarizationRuntime."
}
$buildProgressActivity = "Building Windows portable app"

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

function Write-Step {
  param([string]$Message)

  Write-Host ""
  Write-Host $Message
}

function Write-BuildProgress {
  param(
    [string]$Status,
    [int]$PercentComplete
  )

  Write-Progress -Id 0 -Activity $buildProgressActivity -Status $Status -PercentComplete $PercentComplete
  Write-Step $Status
}

function Format-ByteSize {
  param([Int64]$Bytes)

  if ($Bytes -lt 0) {
    return "0 B"
  }

  $units = @("B", "KB", "MB", "GB", "TB")
  $value = [double]$Bytes
  $unitIndex = 0

  while ($value -ge 1024 -and $unitIndex -lt ($units.Length - 1)) {
    $value /= 1024
    $unitIndex++
  }

  if ($unitIndex -eq 0) {
    return "{0} {1}" -f [Int64][Math]::Round($value), $units[$unitIndex]
  }

  return "{0:N1} {1}" -f $value, $units[$unitIndex]
}

function Format-Duration {
  param([TimeSpan]$Duration)

  if ($Duration.TotalHours -ge 1) {
    return $Duration.ToString("hh\:mm\:ss")
  }

  return $Duration.ToString("mm\:ss")
}

function Update-DownloadProgress {
  param(
    [string]$Activity,
    [Int64]$BytesReceived,
    $TotalBytes,
    [TimeSpan]$Elapsed,
    [int]$ProgressId = 1
  )

  $speedBytesPerSecond = 0.0
  if ($Elapsed.TotalSeconds -gt 0) {
    $speedBytesPerSecond = $BytesReceived / $Elapsed.TotalSeconds
  }

  $speedText = if ($speedBytesPerSecond -gt 0) {
    "{0}/s" -f (Format-ByteSize -Bytes ([Int64][Math]::Round($speedBytesPerSecond)))
  } else {
    "calculating speed..."
  }

  $progress = @{
    Id = $ProgressId
    Activity = $Activity
  }

  if ($null -ne $TotalBytes -and $TotalBytes -gt 0) {
    $percentComplete = [Math]::Min([Math]::Round(($BytesReceived * 100.0) / $TotalBytes), 100)
    $status = "{0} of {1} ({2}%) at {3}" -f `
      (Format-ByteSize -Bytes $BytesReceived), `
      (Format-ByteSize -Bytes $TotalBytes), `
      $percentComplete, `
      $speedText

    if ($speedBytesPerSecond -gt 0 -and $BytesReceived -lt $TotalBytes) {
      $remainingSeconds = ($TotalBytes - $BytesReceived) / $speedBytesPerSecond
      $status += ", ETA $(Format-Duration -Duration ([TimeSpan]::FromSeconds([Math]::Max($remainingSeconds, 0))))"
    }

    $progress.Status = $status
    $progress.PercentComplete = [int]$percentComplete
  } else {
    $progress.Status = "{0} downloaded at {1}" -f (Format-ByteSize -Bytes $BytesReceived), $speedText
  }

  Write-Progress @progress
}

function Invoke-NativeCommand {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList = @()
  )

  $output = & $FilePath @ArgumentList 2>&1
  $exitCode = $LASTEXITCODE

  if ($null -ne $output) {
    foreach ($line in $output) {
      Write-Host $line
    }
  }

  if ($exitCode -ne 0) {
    $joinedArgs = ($ArgumentList | ForEach-Object { $_ }) -join " "
    throw ("Command failed with exit code {0}: {1} {2}" -f $exitCode, $FilePath, $joinedArgs).Trim()
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
    [string]$OutFile,
    [string]$Activity = "Downloading file"
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Add-Type -AssemblyName System.Net.Http

  $httpHandler = New-Object System.Net.Http.HttpClientHandler
  $httpHandler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $httpClient = New-Object System.Net.Http.HttpClient($httpHandler)
  $httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("VukhoAI-Windows-Portable-Build")

  $response = $null
  $inputStream = $null
  $outputStream = $null

  try {
    $response = $httpClient.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    [void]$response.EnsureSuccessStatusCode()

    $totalBytes = $response.Content.Headers.ContentLength
    $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $outputStream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    $buffer = New-Object byte[] 262144
    $bytesReceived = 0L
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressUpdate = [TimeSpan]::FromSeconds(-1)

    while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $outputStream.Write($buffer, 0, $read)
      $bytesReceived += $read

      if (($stopwatch.Elapsed - $lastProgressUpdate).TotalMilliseconds -ge 200) {
        Update-DownloadProgress `
          -Activity $Activity `
          -BytesReceived $bytesReceived `
          -TotalBytes $totalBytes `
          -Elapsed $stopwatch.Elapsed `
          -ProgressId 1
        $lastProgressUpdate = $stopwatch.Elapsed
      }
    }

    Update-DownloadProgress `
      -Activity $Activity `
      -BytesReceived $bytesReceived `
      -TotalBytes $totalBytes `
      -Elapsed $stopwatch.Elapsed `
      -ProgressId 1
  }
  finally {
    Write-Progress -Id 1 -Activity $Activity -Completed

    if ($null -ne $outputStream) {
      $outputStream.Dispose()
    }

    if ($null -ne $inputStream) {
      $inputStream.Dispose()
    }

    if ($null -ne $response) {
      $response.Dispose()
    }

    $httpClient.Dispose()
    $httpHandler.Dispose()
  }
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
    Write-Step "Downloading portable Python $Version..."
    Invoke-DownloadFile -Uri $downloadUrl -OutFile $zipPath -Activity "Downloading portable Python $Version"
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

function Install-TargetPackages {
  param(
    [string]$BuildPython,
    [string]$TargetPythonRoot,
    [string[]]$Packages,
    [string]$IndexUrl = ""
  )

  if ($null -eq $Packages -or $Packages.Count -eq 0) {
    return
  }

  $sitePackages = Join-Path $TargetPythonRoot "Lib\site-packages"
  New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null

  $arguments = @(
    "-m",
    "pip",
    "install",
    "--upgrade",
    "--prefer-binary",
    "--no-warn-script-location",
    "--target",
    $sitePackages
  )

  if (-not [string]::IsNullOrWhiteSpace($IndexUrl)) {
    $arguments += @("--index-url", $IndexUrl)
  }

  $arguments += $Packages
  Invoke-NativeCommand -FilePath $BuildPython -ArgumentList $arguments
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
  $tempScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-python-check-" + [System.IO.Path]::GetRandomFileName() + ".py")
  $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-python-check-" + [System.IO.Path]::GetRandomFileName() + ".out")
  $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-python-check-" + [System.IO.Path]::GetRandomFileName() + ".err")

  try {
    Remove-Item Env:\PYTHONHOME -ErrorAction SilentlyContinue
    Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
    Set-Content -Path $tempScriptPath -Value $script -Encoding ASCII
    $process = Start-Process `
      -FilePath $PythonExe `
      -ArgumentList @($tempScriptPath) `
      -NoNewWindow `
      -Wait `
      -PassThru `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath

    $stdoutText = if (Test-Path $stdoutPath) { [System.IO.File]::ReadAllText($stdoutPath) } else { "" }
    $stderrText = if (Test-Path $stderrPath) { [System.IO.File]::ReadAllText($stderrPath) } else { "" }

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
      Write-Host $stdoutText.TrimEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
      Write-Host $stderrText.TrimEnd()
    }

    if ($process.ExitCode -ne 0) {
      $detail = @($stdoutText, $stderrText) -join [Environment]::NewLine
      $detail = $detail.Trim()
      if ([string]::IsNullOrWhiteSpace($detail)) {
        throw "Python module validation failed for $PythonExe."
      }

      throw "Python module validation failed for ${PythonExe}: $detail"
    }
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

    Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Test-TorchCudaBuild {
  param(
    [string]$PythonExe,
    [string]$Label
  )

  $hadPythonHome = Test-Path Env:\PYTHONHOME
  $hadPythonPath = Test-Path Env:\PYTHONPATH
  $oldPythonHome = $env:PYTHONHOME
  $oldPythonPath = $env:PYTHONPATH
  $tempScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-torch-check-" + [System.IO.Path]::GetRandomFileName() + ".py")
  $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-torch-check-" + [System.IO.Path]::GetRandomFileName() + ".out")
  $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-torch-check-" + [System.IO.Path]::GetRandomFileName() + ".err")
  $script = @"
import sys
import torch

cuda_version = getattr(torch.version, "cuda", None)
cuda_built = False

try:
    cuda_built = bool(torch.backends.cuda.is_built())
except Exception:
    cuda_built = bool(cuda_version)

if not cuda_built and not cuda_version:
    print(
        "Torch CUDA build is missing. "
        f"torch.__version__={torch.__version__}, torch.version.cuda={cuda_version}",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    "Torch CUDA build validated: "
    f"torch.__version__={torch.__version__}, torch.version.cuda={cuda_version}"
)
"@

  try {
    Remove-Item Env:\PYTHONHOME -ErrorAction SilentlyContinue
    Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
    Set-Content -Path $tempScriptPath -Value $script -Encoding ASCII
    $process = Start-Process `
      -FilePath $PythonExe `
      -ArgumentList @($tempScriptPath) `
      -NoNewWindow `
      -Wait `
      -PassThru `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath

    $stdoutText = if (Test-Path $stdoutPath) { [System.IO.File]::ReadAllText($stdoutPath) } else { "" }
    $stderrText = if (Test-Path $stderrPath) { [System.IO.File]::ReadAllText($stderrPath) } else { "" }

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
      Write-Host $stdoutText.TrimEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
      Write-Host $stderrText.TrimEnd()
    }

    if ($process.ExitCode -ne 0) {
      $detail = @($stdoutText, $stderrText) -join [Environment]::NewLine
      $detail = $detail.Trim()
      if ([string]::IsNullOrWhiteSpace($detail)) {
        throw "$Label is present but PyTorch was built without CUDA support."
      }

      throw "$Label is present but PyTorch was built without CUDA support. $detail"
    }
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

    Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue
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
    [string[]]$RequiredModules,
    [string[]]$PreInstallPackages = @(),
    [string]$PreInstallIndexUrl = "",
    [switch]$RequireCudaTorchBuild,
    [int]$PreparePercent,
    [int]$InstallPercent,
    [int]$ValidatePercent
  )

  $runtimeRoot = Join-Path $PortableRoot $RuntimeName
  Write-BuildProgress -Status "Preparing embedded Python runtime: $RuntimeName" -PercentComplete $PreparePercent
  $pythonExe = Initialize-EmbeddedPython `
    -Version $Version `
    -Destination $runtimeRoot `
    -DownloadRoot $DownloadRoot

  Write-BuildProgress -Status "Installing Python packages for $RuntimeName" -PercentComplete $InstallPercent
  Install-TargetRequirements `
    -BuildPython $BuildPython `
    -TargetPythonRoot $runtimeRoot `
    -RequirementsPath $RequirementsPath

  if ($PreInstallPackages.Count -gt 0) {
    Write-Step "Installing pinned runtime packages for $RuntimeName"
    Install-TargetPackages `
      -BuildPython $BuildPython `
      -TargetPythonRoot $runtimeRoot `
      -Packages $PreInstallPackages `
      -IndexUrl $PreInstallIndexUrl
  }

  Write-BuildProgress -Status "Validating Python packages for $RuntimeName" -PercentComplete $ValidatePercent
  Test-PythonModules -PythonExe $pythonExe -RequiredModules $RequiredModules
  if ($RequireCudaTorchBuild) {
    Test-TorchCudaBuild -PythonExe $pythonExe -Label $RuntimeName
  }
  return $pythonExe
}

function Write-PortablePackageManifest {
  param(
    [string]$PortableRoot,
    [string]$ExecutableName,
    [string]$PythonVersion,
    [bool]$HasDiarizationRuntime,
    [bool]$HasFfmpeg
  )

  $manifestPath = Join-Path $PortableRoot "portable-package.json"
  $manifest = [ordered]@{
    format_version = 1
    package_kind = "windows-portable"
    python_runtime_kind = "embedded"
    portable_python_version = $PythonVersion
    executable = $ExecutableName
    transcribe_script = "resources/transcribe.py"
    transcription_runtime = "python/python.exe"
    diarization_runtime = if ($HasDiarizationRuntime) { "python-diarization/python.exe" } else { $null }
    ffmpeg_bundled = $HasFfmpeg
    created_at_utc = [DateTime]::UtcNow.ToString("o")
  }

  $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")
$appRoot = Join-Path $repoRoot "vukhoai-cross"
$tauriRoot = Join-Path $appRoot "src-tauri"
$portableBuildRoot = Join-Path $appRoot "portable-build"
$portableRoot = Join-Path $portableBuildRoot "windows\$PortableName"
$downloadRoot = Join-Path $portableBuildRoot "downloads"
$seedPath = Join-Path $portableBuildRoot "portable-state.local.json"
$resourceRoot = Join-Path $portableRoot "resources"
$mainRequirements = Join-Path $repoRoot "Scripts\requirements.txt"
$diarizationRequirements = Join-Path $repoRoot "Scripts\requirements-diarization.txt"
$diarizationTorchIndexUrl = if ($env:VUKHOAI_DIARIZATION_TORCH_INDEX_URL) {
  $env:VUKHOAI_DIARIZATION_TORCH_INDEX_URL
} else {
  "https://download.pytorch.org/whl/cu126"
}
$diarizationTorchPackages = @(
  "torch==2.8.0",
  "torchvision==0.23.0",
  "torchaudio==2.8.0"
)
$portablePythonMajorMinor = (($PortablePythonVersion -split "\.") | Select-Object -First 2) -join "."
$buildVenvPath = Join-Path $portableBuildRoot "python-build-$portablePythonMajorMinor"

if (-not (Test-IsWindowsHost)) {
  throw "This script must be run on Windows."
}

Write-BuildProgress -Status "Checking local build prerequisites..." -PercentComplete 5
$null = Require-Command -Name "cargo" -Hint "Install Rust with rustup first."
$null = Require-Command -Name "npm" -Hint "Install Node.js 20+ first."
$pythonLauncher = Resolve-PythonLauncher
Write-BuildProgress -Status "Preparing Python build environment..." -PercentComplete 12
$buildPython = Ensure-BuildVenv `
  -PythonLauncher $pythonLauncher `
  -VersionFlag "-$portablePythonMajorMinor" `
  -VenvPath $buildVenvPath `
  -ExpectedMajorMinor $portablePythonMajorMinor

try {
  Write-BuildProgress -Status "Exporting portable settings..." -PercentComplete 18
  Invoke-NativeCommand -FilePath $buildPython -ArgumentList @((Join-Path $repoRoot "Scripts\export_portable_state.py"))
} catch {
  Write-Warning "Portable settings export was skipped: $($_.Exception.Message)"
}

Push-Location $appRoot
try {
  if (-not $SkipNpmInstall) {
    Write-BuildProgress -Status "Installing Node.js dependencies..." -PercentComplete 25
    Invoke-NativeCommand -FilePath "npm" -ArgumentList @("install")
  }

  Write-BuildProgress -Status "Compiling the Tauri Windows app..." -PercentComplete 45
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

Write-BuildProgress -Status "Packaging portable app files..." -PercentComplete 68
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
  -RequiredModules @("faster_whisper") `
  -PreparePercent 76 `
  -InstallPercent 80 `
  -ValidatePercent 86

$diarizationPython = $null
if (-not $SkipDiarizationRuntime) {
  $diarizationPython = New-PortablePythonRuntime `
    -RuntimeName "python-diarization" `
    -Version $PortablePythonVersion `
    -BuildPython $buildPython `
    -DownloadRoot $downloadRoot `
    -PortableRoot $portableRoot `
    -RequirementsPath $diarizationRequirements `
    -RequiredModules @("faster_whisper", "whisperx", "pyannote.audio") `
    -PreInstallPackages $diarizationTorchPackages `
    -PreInstallIndexUrl $diarizationTorchIndexUrl `
    -RequireCudaTorchBuild `
    -PreparePercent 88 `
    -InstallPercent 92 `
    -ValidatePercent 96
}

if ($FfmpegDir) {
  Write-BuildProgress -Status "Copying ffmpeg binaries into the portable package..." -PercentComplete 98
  foreach ($binaryName in @("ffmpeg.exe", "ffprobe.exe")) {
    $sourceBinary = Join-Path $FfmpegDir $binaryName
    if (Test-Path $sourceBinary) {
      Copy-Item $sourceBinary (Join-Path $portableRoot $binaryName) -Force
    }
  }
}

Write-BuildProgress -Status "Writing portable package manifest..." -PercentComplete 99
Write-PortablePackageManifest `
  -PortableRoot $portableRoot `
  -ExecutableName $releaseExe.Name `
  -PythonVersion $PortablePythonVersion `
  -HasDiarizationRuntime ($null -ne $diarizationPython -and (Test-Path $diarizationPython)) `
  -HasFfmpeg (Test-Path (Join-Path $portableRoot "ffmpeg.exe"))

Write-Progress -Id 0 -Activity $buildProgressActivity -Status "Portable Windows build is ready." -PercentComplete 100
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

Write-Progress -Id 0 -Activity $buildProgressActivity -Completed

if ($OpenFolder) {
  Invoke-Item $portableRoot
}
