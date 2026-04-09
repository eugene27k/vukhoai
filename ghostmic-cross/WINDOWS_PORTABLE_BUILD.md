# Windows Portable Build

This setup is for producing a Windows build that can be opened directly by launching the app `.exe` from a prepared folder.

## What "portable" means here

The output folder contains:

- the built Windows `.exe`
- `resources/transcribe.py`
- optional `portable-state.json` for first-run settings
- optional `.venv` and `.venv-diarization` folders next to the `.exe`
- optional `ffmpeg.exe` / `ffprobe.exe` next to the `.exe`

On first launch, the app will:

- seed settings from `portable-state.json` if no app state exists yet
- auto-detect `.venv` and `.venv-diarization` near the executable
- auto-detect `ffmpeg.exe` and `ffprobe.exe` near the executable

This is the most reliable path to a self-contained Windows package with the current architecture.

## 1. Export current settings into a portable seed

Run from the repository root on the machine that currently has the settings you want:

```bash
python3 Scripts/export_portable_state.py
```

This writes:

`ghostmic-cross/portable-build/portable-state.local.json`

Included:

- default profile
- language mode
- diarization on/off
- Hugging Face token
- OpenAI model
- OpenAI API key

Intentionally not included:

- queue history
- machine-specific Python paths
- machine-specific output folder path

The seed file is ignored by git.

## 2. Prepare Windows Python runtimes

On the Windows build machine, create:

- `.venv`
- `.venv-diarization`

in the repository root if you want the portable package to run without manual Python configuration.

The app will auto-detect these folders when they are copied next to the `.exe`.

## 3. Optional: prepare ffmpeg sidecars

If you want stronger `.mp4` support in the portable package, place:

- `ffmpeg.exe`
- `ffprobe.exe`

in some folder and pass that folder to the build script.

## 4. Build the portable Windows package

Run this on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scripts\build_windows_portable.ps1
```

Optional with ffmpeg sidecars:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scripts\build_windows_portable.ps1 -FfmpegDir "C:\path\to\ffmpeg\bin"
```

Output:

`ghostmic-cross/portable-build/windows/Vukho.AI-Windows-Portable/`

The resulting folder contains the app `.exe` plus everything the runtime can auto-discover.

## 5. Important limitation

This repository cannot produce a working Windows executable from the current macOS ARM host by itself.

A real Windows `.exe` still has to be built on a Windows machine, or on a properly configured Windows CI runner, because the current host only has the `aarch64-apple-darwin` Rust target installed and no Windows linker/toolchain is configured.
