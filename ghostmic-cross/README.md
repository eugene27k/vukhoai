# GhostMic Cross (Tauri)

Cross-platform desktop app (macOS + Windows target) for local/offline transcription using the existing `transcribe.py` pipeline.

## What is implemented

- Import `.m4a` / `.mp4`
- Queue processing (one job at a time)
- Statuses: `queued`, `processing`, `done`, `failed`, `cancelled`
- Real-time progress, stage, ETA
- Cancel / Retry / Delete
- Re-transcribe from an existing finished item
- Transcript viewer with toggles:
  - show/hide speakers
  - show/hide timestamps
- Copy and Export TXT based on current viewer toggles
- Settings modal:
  - quality profile
  - language mode
  - diarization on/off
  - output folder
  - optional Python path
  - stored OpenAI fields (for future protocol feature in this app)

## Current limitation

- OpenAI protocol generation UI/flow is **not yet ported** in this Tauri app (the fields are stored only).

## Prerequisites

- Node.js 20+
- Rust toolchain (stable)
- Python 3.10+
- Python dependencies:

```bash
cd ".."
python3 -m venv .venv
source .venv/bin/activate
pip install -r Scripts/requirements.txt
```

Optional for better `.mp4` normalization and duration probing:
- `ffmpeg`
- `ffprobe`

## Run (dev)

```bash
cd ghostmic-cross
npm install
npm run tauri dev
```

If Python is not auto-detected, set it in Settings (`Python path`) or via env:

```bash
export GHOSTMIC_PYTHON="/absolute/path/to/python3"
```

## Build

```bash
cd ghostmic-cross
npm run tauri build -- --debug
```

Output artifacts are in:
- `ghostmic-cross/src-tauri/target/debug/bundle/`

## Data storage

State and queue are stored in the app data directory as JSON (`state.json`) plus cache folders.

