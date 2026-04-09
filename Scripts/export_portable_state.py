#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
from pathlib import Path
from typing import Any


APP_IDENTIFIER = "com.admin.ghostmic-cross"


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def default_source_state() -> Path:
    home = Path.home()
    system = platform.system().lower()

    if system == "darwin":
        return home / "Library" / "Application Support" / APP_IDENTIFIER / "state.json"

    if system == "windows":
        appdata = Path(os.environ.get("APPDATA", home / "AppData" / "Roaming"))
        return appdata / APP_IDENTIFIER / "state.json"

    xdg_data_home = Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share"))
    return xdg_data_home / APP_IDENTIFIER / "state.json"


def default_output_state() -> Path:
    return repo_root() / "ghostmic-cross" / "portable-build" / "portable-state.local.json"


def sanitize_state(raw: dict[str, Any]) -> dict[str, Any]:
    settings = dict(raw.get("settings") or {})
    portable_settings = {
        "default_profile": settings.get("default_profile", "maximum_quality"),
        "language_mode": settings.get("language_mode", "auto"),
        "diarization_enabled": bool(settings.get("diarization_enabled", True)),
        # Leave machine-specific paths empty so the portable build can auto-detect bundled runtimes.
        "output_folder_path": "",
        "python_path": None,
        "diarization_python_path": None,
        "huggingface_token": settings.get("huggingface_token"),
        "openai_model": settings.get("openai_model", "gpt-4o-mini"),
        "openai_api_key": settings.get("openai_api_key"),
    }

    return {
        "settings": portable_settings,
        # Never ship queue history in a portable seed.
        "jobs": [],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export current GhostMic settings into a portable first-run seed file.",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=default_source_state(),
        help="Path to the current state.json file.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=default_output_state(),
        help="Destination for the portable seed JSON.",
    )
    args = parser.parse_args()

    source = args.source.expanduser().resolve()
    output = args.output.expanduser().resolve()

    if not source.exists():
        raise SystemExit(f"State file was not found: {source}")

    raw = json.loads(source.read_text(encoding="utf-8"))
    portable = sanitize_state(raw)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(portable, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    settings = portable["settings"]
    print(f"Portable seed written to: {output}")
    print(f"Hugging Face token included: {bool((settings.get('huggingface_token') or '').strip())}")
    print(f"OpenAI API key included: {bool((settings.get('openai_api_key') or '').strip())}")
    print("Queue history included: False")
    print("Python paths included: False")
    print("Output folder included: False")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
