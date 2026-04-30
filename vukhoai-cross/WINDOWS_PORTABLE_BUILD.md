# Windows Portable Build

This setup is for producing a Windows build that can be opened directly by launching the app `.exe` from a prepared folder.

## What "portable" means here

The output folder contains:

- the built Windows `.exe`
- `resources/transcribe.py`
- optional `portable-state.json` for first-run settings
- `python\python.exe` with the transcription runtime already installed
- `python-diarization\python.exe` with the diarization runtime already installed
- optional `ffmpeg.exe` / `ffprobe.exe` next to the `.exe`

On first launch, the app will:

- seed settings from `portable-state.json` if no app state exists yet
- auto-detect the bundled Python runtimes near the executable
- auto-detect `ffmpeg.exe` and `ffprobe.exe` near the executable

The build validates imports from the bundled runtimes before it reports success. A release package should not ask an end user to install Python packages.

## 1. Export current settings into a portable seed

Run from the repository root on the machine that currently has the settings you want:

```bash
python3 Scripts/export_portable_state.py
```

This writes:

`vukhoai-cross/portable-build/portable-state.local.json`

Included:

- default profile
- language mode
- mandatory speaker diarization
- Hugging Face token
- OpenAI model
- OpenAI API key

Intentionally not included:

- queue history
- machine-specific Python paths
- machine-specific output folder path

The seed file is ignored by git.

## 2. One-click Windows app

On Windows, double-click:

`Build Windows Portable.cmd`

Default behavior:

- tries to download the latest ready-to-run Windows ZIP from GitHub Releases
- extracts it into `vukhoai-cross/portable-build/windows/`
- validates that the extracted package contains the embedded Python runtime and ready transcription modules
- opens the folder when done

If no release ZIP is available yet, it falls back to a local source build only when the machine already has the required toolchain.

If the downloaded ZIP is stale or incomplete, the bootstrap script now rejects it instead of launching a broken app.

What the local fallback does automatically:

- exports current app settings into a portable first-run seed if local app state exists
- downloads the official Windows embeddable Python runtime
- installs transcription packages into `python\Lib\site-packages`
- installs diarization packages into `python-diarization\Lib\site-packages`
- verifies `faster_whisper`, `whisperx`, and `pyannote.audio` imports from the bundled runtimes
- runs the Tauri Windows build
- creates a portable output folder with:
  - the `.exe`
  - `resources/transcribe.py`
  - bundled `python`
  - bundled `python-diarization`
  - `portable-state.json` if settings were exported

The ready-made release asset is published as:

`Vukho.AI-Windows-Portable.zip`

You can also run the bootstrap PowerShell script directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scripts\get_or_build_windows_portable.ps1
```

If you explicitly want to compile locally from source, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scripts\build_windows_portable.ps1 -FfmpegDir "C:\path\to\ffmpeg\bin"
```

`-SkipDiarizationRuntime` is rejected by the build script because normal jobs require diarization.

Output:

`vukhoai-cross/portable-build/windows/Vukho.AI-Windows-Portable/`

The resulting folder contains the app `.exe` plus everything the runtime can auto-discover.

## 3. Automatic repository build and release

The repository includes GitHub Actions workflows that:

- build the Windows portable app
- upload a workflow artifact
- publish a stable release ZIP for regular users

The release asset name is:

`Vukho.AI-Windows-Portable.zip`

The stable release tag is:

`windows-portable-latest`

## 4. Optional repository secrets

If you want the downloaded GitHub Actions artifact to contain preseeded settings, configure:

- `PORTABLE_HUGGINGFACE_TOKEN` as a GitHub secret
- `PORTABLE_OPENAI_API_KEY` as a GitHub secret
- `PORTABLE_OPENAI_MODEL` as a GitHub variable if you want a non-default model

These values are injected into `portable-state.json` during the workflow build.

## 5. Important limitation

This repository cannot produce a working Windows executable from the current macOS ARM host by itself.

A real Windows `.exe` still has to be built on a Windows machine, or on a properly configured Windows CI runner, because the current host only has the `aarch64-apple-darwin` Rust target installed and no Windows linker/toolchain is configured.
