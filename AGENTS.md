# Project Guardrails

## Core Engine Contract

The transcription + diarization + GPU processing path is the core product contract for Vukho.AI.

- Do not change the core engine, runtime selection, GPU preflight, WhisperX/pyannote path, or mandatory diarization behavior unless the user explicitly asks for that change or provides a concrete bug that requires it.
- Do not introduce transcription-only fallbacks, silent CPU fallbacks, or "skip diarization" behavior for successful jobs.
- If the core path fails, preserve fail-fast behavior with clear diagnostics instead of degrading output quality.
- When a core-engine fix is required, make the smallest targeted change possible, verify it directly, and avoid broad refactors.
- Treat `transcribe.py`, runtime packaging, CUDA checks, and diarization settings as high-risk files. Read them carefully before editing and explain why a change is necessary.

