Param(
  [string]$Repository = "eugene27k/vukhoai",
  [string]$ReleaseTag = "windows-portable-latest",
  [string]$AssetName = "Vukho.AI-Windows-Portable.zip",
  [switch]$ForceDownload,
  [switch]$ForceLocalBuild,
  [switch]$OpenFolder
)

$ErrorActionPreference = "Stop"
$prepareProgressActivity = "Preparing Windows portable app"

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

function Write-PrepareProgress {
  param(
    [string]$Status,
    [int]$PercentComplete
  )

  Write-Progress -Id 0 -Activity $prepareProgressActivity -Status $Status -PercentComplete $PercentComplete
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

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Add-Type -AssemblyName System.Net.Http

  $httpHandler = New-Object System.Net.Http.HttpClientHandler
  $httpHandler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $httpClient = New-Object System.Net.Http.HttpClient($httpHandler)
  $httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("VukhoAI-Windows-Bootstrap")

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
          -Activity "Downloading ready-made Windows build" `
          -BytesReceived $bytesReceived `
          -TotalBytes $totalBytes `
          -Elapsed $stopwatch.Elapsed `
          -ProgressId 1
        $lastProgressUpdate = $stopwatch.Elapsed
      }
    }

    Update-DownloadProgress `
      -Activity "Downloading ready-made Windows build" `
      -BytesReceived $bytesReceived `
      -TotalBytes $totalBytes `
      -Elapsed $stopwatch.Elapsed `
      -ProgressId 1
  }
  finally {
    Write-Progress -Id 1 -Activity "Downloading ready-made Windows build" -Completed

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

function Join-PortableReleaseParts {
  param(
    [string]$ManifestPath,
    [string]$DownloadRoot,
    [string]$ZipPath,
    [string]$Repository,
    [string]$ReleaseTag
  )

  if (-not (Test-Path $ManifestPath)) {
    throw "Missing release manifest: $ManifestPath"
  }

  $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
  $parts = @($manifest.parts)
  if ($parts.Count -eq 0) {
    throw "Release manifest does not contain any parts."
  }

  if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
  }

  $zipParent = Split-Path -Parent $ZipPath
  if (-not [string]::IsNullOrWhiteSpace($zipParent)) {
    New-Item -ItemType Directory -Force -Path $zipParent | Out-Null
  }

  $archiveName = if ($manifest.archive_name) { [string]$manifest.archive_name } else { [System.IO.Path]::GetFileName($ZipPath) }
  $outputStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

  try {
    $partIndex = 0
    foreach ($part in $parts) {
      $partIndex += 1
      $partName = [string]$part.name
      if ([string]::IsNullOrWhiteSpace($partName)) {
        throw "Release manifest contains an empty part name."
      }

      $partPath = Join-Path $DownloadRoot $partName
      $partUrl = "https://github.com/$Repository/releases/download/$ReleaseTag/$partName"
      Write-PrepareProgress -Status "Downloading release part $partIndex of $($parts.Count)..." -PercentComplete (10 + [Math]::Min([int](($partIndex * 40.0) / [Math]::Max($parts.Count, 1)), 40))
      Invoke-PortableDownload -Uri $partUrl -OutFile $partPath

      $inputStream = [System.IO.File]::OpenRead($partPath)
      try {
        $inputStream.CopyTo($outputStream)
      }
      finally {
        $inputStream.Dispose()
      }
    }
  }
  finally {
    $outputStream.Dispose()
  }

  if ($manifest.archive_bytes) {
    $expectedBytes = [Int64]$manifest.archive_bytes
    $actualBytes = (Get-Item $ZipPath).Length
    if ($expectedBytes -ne $actualBytes) {
      throw "Reassembled archive size mismatch for $archiveName. Expected $expectedBytes bytes, got $actualBytes bytes."
    }
  }
}

function Resolve-PortableExe {
  param([string]$PortableRoot)

  return Get-ChildItem -Path $PortableRoot -Filter "*.exe" -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "(?i)(setup|installer|updater)" } |
    Sort-Object FullName |
    Select-Object -First 1
}

function Test-PortablePythonModules {
  param(
    [string]$PythonExe,
    [string[]]$RequiredModules,
    [string]$Label
  )

  if (-not (Test-Path $PythonExe)) {
    throw "$Label was not found: $PythonExe"
  }

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
        throw "$Label is present but its Python packages are not ready."
      }

      throw "$Label is present but its Python packages are not ready. $detail"
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

function Test-PortableTorchCudaBuild {
  param(
    [string]$PythonExe,
    [string]$Label
  )

  if (-not (Test-Path $PythonExe)) {
    throw "$Label was not found: $PythonExe"
  }

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

  $hadPythonHome = Test-Path Env:\PYTHONHOME
  $hadPythonPath = Test-Path Env:\PYTHONPATH
  $oldPythonHome = $env:PYTHONHOME
  $oldPythonPath = $env:PYTHONPATH
  $tempScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-torch-check-" + [System.IO.Path]::GetRandomFileName() + ".py")
  $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-torch-check-" + [System.IO.Path]::GetRandomFileName() + ".out")
  $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vukhoai-torch-check-" + [System.IO.Path]::GetRandomFileName() + ".err")

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

function Assert-PortablePackageReady {
  param([string]$PortableRoot)

  $portableExe = Resolve-PortableExe -PortableRoot $PortableRoot
  if ($null -eq $portableExe) {
    throw "The package does not contain a runnable .exe."
  }

  $transcribeScript = Join-Path $PortableRoot "resources\transcribe.py"
  if (-not (Test-Path $transcribeScript)) {
    throw "The package is missing resources\transcribe.py."
  }

  $embeddedPython = Join-Path $PortableRoot "python\python.exe"
  if (-not (Test-Path $embeddedPython)) {
    $legacyVenv = Join-Path $PortableRoot ".venv\Scripts\python.exe"
    if (Test-Path $legacyVenv) {
      throw "The downloaded package uses the legacy .venv layout. A rebuilt package with embedded Python is required."
    }

    throw "The package is missing the embedded transcription runtime (python\python.exe)."
  }

  Test-PortablePythonModules `
    -PythonExe $embeddedPython `
    -RequiredModules @("faster_whisper") `
    -Label "Embedded transcription runtime"

  $diarizationPython = Join-Path $PortableRoot "python-diarization\python.exe"
  if (Test-Path $diarizationPython) {
    Test-PortablePythonModules `
      -PythonExe $diarizationPython `
      -RequiredModules @("faster_whisper", "whisperx", "pyannote.audio") `
      -Label "Embedded diarization runtime"
    Test-PortableTorchCudaBuild `
      -PythonExe $diarizationPython `
      -Label "Embedded diarization runtime"
  }

  return $portableExe
}

if (-not (Test-IsWindowsHost)) {
  throw "This script must be run on Windows."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")
$appRoot = Join-Path $repoRoot "vukhoai-cross"
$downloadRoot = Join-Path $appRoot "portable-build\downloads"
$windowsRoot = Join-Path $appRoot "portable-build\windows"
$portableRoot = Join-Path $windowsRoot "Vukho.AI-Windows-Portable"
$zipPath = Join-Path $downloadRoot $AssetName
$manifestName = ([System.IO.Path]::GetFileNameWithoutExtension($AssetName)) + ".manifest.json"
$manifestPath = Join-Path $downloadRoot $manifestName
$releaseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag/$AssetName"
$manifestUrl = "https://github.com/$Repository/releases/download/$ReleaseTag/$manifestName"
$localBuildScript = Join-Path $scriptRoot "build_windows_portable.ps1"

if (-not (Test-Path $localBuildScript)) {
  throw "Missing local build script: $localBuildScript"
}

if (-not $ForceLocalBuild) {
  Write-Step "Checking for the latest ready-to-run Windows build..."

  try {
    Write-PrepareProgress -Status "Preparing download folder..." -PercentComplete 5
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $windowsRoot | Out-Null

    if (Test-Path $zipPath) {
      Remove-Item $zipPath -Force
    }

    if (Test-Path $manifestPath) {
      Remove-Item $manifestPath -Force
    }

    try {
      Write-PrepareProgress -Status "Downloading release manifest..." -PercentComplete 15
      Invoke-PortableDownload -Uri $manifestUrl -OutFile $manifestPath
      Join-PortableReleaseParts `
        -ManifestPath $manifestPath `
        -DownloadRoot $downloadRoot `
        -ZipPath $zipPath `
        -Repository $Repository `
        -ReleaseTag $ReleaseTag
    } catch {
      if (Test-Path $manifestPath) {
        Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
      }

      Write-PrepareProgress -Status "Downloading ready-made Windows build..." -PercentComplete 15
      Invoke-PortableDownload -Uri $releaseUrl -OutFile $zipPath
    }

    if (Test-Path $portableRoot) {
      Remove-Item $portableRoot -Recurse -Force
    }

    Write-PrepareProgress -Status "Expanding downloaded archive..." -PercentComplete 80
    Expand-Archive -Path $zipPath -DestinationPath $windowsRoot -Force

    Write-PrepareProgress -Status "Validating extracted Windows app..." -PercentComplete 92
    $portableExe = Assert-PortablePackageReady -PortableRoot $portableRoot

    Write-PrepareProgress -Status "Windows portable app is ready." -PercentComplete 100
    Write-Host "Ready-to-run Windows app downloaded successfully."
    Write-Host "Path: $portableRoot"

    if ($OpenFolder) {
      Invoke-Item $portableRoot
    } else {
      Invoke-Item $portableExe.FullName
    }

    exit 0
  } catch {
    Write-Progress -Id 1 -Activity "Downloading ready-made Windows build" -Completed
    Write-Progress -Id 0 -Activity $prepareProgressActivity -Completed
    Write-Warning "Prebuilt Windows app download or validation failed: $($_.Exception.Message)"

    if ($ForceDownload) {
      throw "Could not prepare a valid prebuilt Windows app. Try again later or install local build prerequisites."
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
Write-Progress -Id 0 -Activity $prepareProgressActivity -Completed
& $localBuildScript -OpenFolder:$OpenFolder
