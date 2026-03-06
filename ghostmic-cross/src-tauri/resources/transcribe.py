#!/usr/bin/env python3

import argparse
import importlib.util
import json
import os
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

PROFILE_TO_MODEL = {
    "max": "large-v3",
    "balanced": "medium",
    "fast": "small",
}


@dataclass
class Segment:
    start: float
    end: float
    speaker: str
    text: str


def emit_progress(percent: float, stage: str, eta_seconds: Optional[float] = None) -> None:
    payload: Dict[str, Any] = {
        "percent": max(0.0, min(100.0, float(percent))),
        "stage": stage,
    }
    if eta_seconds is not None and eta_seconds >= 0:
        payload["eta_seconds"] = float(eta_seconds)

    print("GHOSTMIC_PROGRESS " + json.dumps(payload, ensure_ascii=False), flush=True)


def format_timestamp(seconds: float) -> str:
    value = max(seconds, 0.0)
    millis = int(round(value * 1000.0))
    hours = millis // 3_600_000
    millis -= hours * 3_600_000
    minutes = millis // 60_000
    millis -= minutes * 60_000
    secs = millis // 1000
    millis -= secs * 1000
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def write_txt(path: str, segments: List[Segment]) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        for segment in segments:
            line = (
                f"[{format_timestamp(segment.start)} - {format_timestamp(segment.end)}] "
                f"{segment.speaker}: {segment.text}"
            )
            handle.write(line + "\n")


def normalize_segments(
    raw_segments: List[Dict[str, Any]],
    diarization_requested: bool,
    diarization_applied: bool,
) -> List[Segment]:
    """
    Merge consecutive segments that belong to the same speaker.
    This keeps one continuous speaker block until speaker changes.
    """
    normalized: List[Segment] = []
    speaker_map: Dict[str, str] = {}
    next_speaker_index = 1

    def speaker_label(raw: Optional[str]) -> str:
        nonlocal next_speaker_index
        if not raw:
            return "SPEAKER_01"

        if raw not in speaker_map:
            speaker_map[raw] = f"SPEAKER_{next_speaker_index:02d}"
            next_speaker_index += 1
        return speaker_map[raw]

    for item in raw_segments:
        start = float(item.get("start") or 0.0)
        end = float(item.get("end") or start)
        if end < start:
            end = start

        text = " ".join(str(item.get("text") or "").split())
        if not text:
            continue

        source_speaker = item.get("speaker") if (diarization_requested and diarization_applied) else None
        speaker = speaker_label(source_speaker)

        if normalized and normalized[-1].speaker == speaker:
            normalized[-1].end = max(normalized[-1].end, end)
            normalized[-1].text = f"{normalized[-1].text} {text}".strip()
            continue

        normalized.append(
            Segment(
                start=start,
                end=end,
                speaker=speaker,
                text=text,
            )
        )

    return normalized


def transcribe_with_whisperx(
    audio_path: str,
    model_name: str,
    language_mode: str,
    diarization_enabled: bool,
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    import whisperx  # type: ignore
    import torch  # type: ignore

    emit_progress(10, "Loading WhisperX model")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    compute_type = "float16" if device == "cuda" else "int8"

    model = whisperx.load_model(model_name, device=device, compute_type=compute_type)
    transcribe_kwargs: Dict[str, Any] = {
        "batch_size": 8,
        "vad_filter": True,
    }
    if language_mode == "uk":
        transcribe_kwargs["language"] = "uk"

    emit_progress(20, "Transcribing")
    result = model.transcribe(audio_path, **transcribe_kwargs)
    segments = result.get("segments", [])

    detected_language = result.get("language") if language_mode == "auto" else "uk"
    alignment_applied = False
    alignment_error: Optional[str] = None
    result_for_speakers: Dict[str, Any] = result

    if detected_language and segments:
        try:
            emit_progress(55, "Aligning timestamps")
            align_model, metadata = whisperx.load_align_model(language_code=detected_language, device=device)
            aligned = whisperx.align(
                result["segments"],
                align_model,
                metadata,
                audio_path,
                device,
                return_char_alignments=False,
            )
            result_for_speakers = aligned
            segments = aligned.get("segments", segments)
            alignment_applied = True
        except Exception as exc:  # pragma: no cover - fallback path
            alignment_error = f"{type(exc).__name__}: {exc}"

    diarization_applied = False
    diarization_error: Optional[str] = None

    if diarization_enabled:
        try:
            emit_progress(75, "Applying diarization")
            diarization_pipeline = whisperx.DiarizationPipeline(
                use_auth_token=os.environ.get("HF_TOKEN"),
                device=device,
            )
            diarized = diarization_pipeline(audio_path)
            assigned = whisperx.assign_word_speakers(diarized, result_for_speakers)
            segments = assigned.get("segments", segments)
            diarization_applied = True
        except Exception as exc:  # pragma: no cover - fallback path
            diarization_error = f"{type(exc).__name__}: {exc}"

    meta = {
        "engine": "whisperx",
        "detected_language": detected_language,
        "alignment_applied": alignment_applied,
        "alignment_error": alignment_error,
        "diarization_applied": diarization_applied,
        "diarization_error": diarization_error,
    }
    return segments, meta


def transcribe_with_faster_whisper(
    audio_path: str,
    model_name: str,
    language_mode: str,
    total_duration_seconds: Optional[float],
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    from faster_whisper import WhisperModel  # type: ignore

    emit_progress(10, "Loading model")
    model = WhisperModel(model_name, device="cpu", compute_type="int8")
    language = None if language_mode == "auto" else "uk"

    emit_progress(15, "Transcribing")
    generated_segments, info = model.transcribe(
        audio_path,
        language=language,
        vad_filter=True,
        word_timestamps=True,
    )

    started_at = time.time()
    last_reported = 15.0

    segments: List[Dict[str, Any]] = []
    for segment in generated_segments:
        start = float(segment.start or 0.0)
        end = float(segment.end or segment.start or 0.0)
        text = (segment.text or "").strip()

        segments.append(
            {
                "start": start,
                "end": end,
                "text": text,
                "speaker": None,
            }
        )

        if total_duration_seconds and total_duration_seconds > 0 and end > 0:
            normalized = min(max(end / total_duration_seconds, 0.0), 1.0)
            progress = 15.0 + normalized * 80.0

            elapsed = max(time.time() - started_at, 0.001)
            speed = end / elapsed
            remaining_audio = max(total_duration_seconds - end, 0.0)
            eta_seconds = remaining_audio / speed if speed > 0 else None

            if progress - last_reported >= 0.5:
                emit_progress(progress, "Transcribing", eta_seconds)
                last_reported = progress

    meta = {
        "engine": "faster-whisper",
        "detected_language": getattr(info, "language", None),
        "alignment_applied": False,
        "alignment_error": "Alignment unavailable without whisperx.",
        "diarization_applied": False,
        "diarization_error": "Diarization unavailable without whisperx + pyannote.",
    }
    return segments, meta


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GhostMic local transcription pipeline")
    parser.add_argument("--input", required=True, help="Path to input audio file")
    parser.add_argument("--output", required=True, help="Path to output TXT file")
    parser.add_argument("--meta", required=True, help="Path to metadata JSON file")
    parser.add_argument("--profile", choices=["max", "balanced", "fast"], default="max")
    parser.add_argument("--language", choices=["auto", "uk"], default="auto")
    parser.add_argument("--diarization", choices=["on", "off"], default="on")
    parser.add_argument("--duration-seconds", type=float, default=0.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not os.path.exists(args.input):
        print(f"Input file not found: {args.input}", file=sys.stderr)
        return 2

    model_name = PROFILE_TO_MODEL[args.profile]
    diarization_requested = args.diarization == "on"
    total_duration_seconds = args.duration_seconds if args.duration_seconds > 0 else None

    output_dir = os.path.dirname(args.output)
    meta_dir = os.path.dirname(args.meta)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    if meta_dir:
        os.makedirs(meta_dir, exist_ok=True)

    raw_segments: List[Dict[str, Any]]
    engine_meta: Dict[str, Any]
    fallback_events: List[str] = []

    emit_progress(2, "Initializing")

    whisperx_installed = importlib.util.find_spec("whisperx") is not None

    if whisperx_installed:
        try:
            raw_segments, engine_meta = transcribe_with_whisperx(
                audio_path=args.input,
                model_name=model_name,
                language_mode=args.language,
                diarization_enabled=diarization_requested,
            )
        except Exception as whisperx_error:
            fallback_events.append(f"whisperx unavailable: {type(whisperx_error).__name__}: {whisperx_error}")
            emit_progress(6, "Falling back to faster-whisper")
            try:
                raw_segments, engine_meta = transcribe_with_faster_whisper(
                    audio_path=args.input,
                    model_name=model_name,
                    language_mode=args.language,
                    total_duration_seconds=total_duration_seconds,
                )
            except Exception as fallback_error:
                print("Transcription failed in both whisperx and faster-whisper.", file=sys.stderr)
                print(f"whisperx error: {whisperx_error}", file=sys.stderr)
                print(f"faster-whisper error: {fallback_error}", file=sys.stderr)
                return 3
    else:
        fallback_events.append("whisperx unavailable: module not installed")
        try:
            raw_segments, engine_meta = transcribe_with_faster_whisper(
                audio_path=args.input,
                model_name=model_name,
                language_mode=args.language,
                total_duration_seconds=total_duration_seconds,
            )
        except Exception as fallback_error:
            print("Transcription failed in faster-whisper.", file=sys.stderr)
            print(f"faster-whisper error: {fallback_error}", file=sys.stderr)
            return 3

    emit_progress(96, "Finalizing output")
    diarization_applied = bool(engine_meta.get("diarization_applied")) if diarization_requested else False

    segments = normalize_segments(
        raw_segments=raw_segments,
        diarization_requested=diarization_requested,
        diarization_applied=diarization_applied,
    )

    write_txt(args.output, segments)

    diarization_fallback_reason = None
    if diarization_requested and not diarization_applied:
        diarization_fallback_reason = engine_meta.get("diarization_error") or "Diarization failed; fallback to SPEAKER_01."

    metadata = {
        "input": args.input,
        "output": args.output,
        "profile": args.profile,
        "model": model_name,
        "language_mode": args.language,
        "segment_count": len(segments),
        "diarization_requested": diarization_requested,
        "diarization_applied": diarization_applied,
        "diarization_fallback_reason": diarization_fallback_reason,
        "engine": engine_meta.get("engine"),
        "detected_language": engine_meta.get("detected_language"),
        "alignment_applied": bool(engine_meta.get("alignment_applied")),
        "alignment_error": engine_meta.get("alignment_error"),
        "fallback_events": fallback_events,
    }

    with open(args.meta, "w", encoding="utf-8") as handle:
        json.dump(metadata, handle, ensure_ascii=False, indent=2)

    emit_progress(100, "Done", 0)

    print(f"Created TXT transcript: {args.output}")
    print(f"Segments: {len(segments)}")
    if diarization_fallback_reason:
        print(f"Diarization fallback: {diarization_fallback_reason}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
