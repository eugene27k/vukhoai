#!/usr/bin/env python3

import argparse
import importlib.util
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROFILE_TO_MODEL = {
    "max": "large-v3",
    "balanced": "medium",
    "fast": "small",
}

EXPECTED_AUTO_LANGUAGES = {"uk"}
UKRAINIAN_LANGUAGE = "uk"


@dataclass
class Segment:
    start: float
    end: float
    speaker: str
    text: str


@dataclass
class FasterWhisperRuntime:
    device: str
    compute_type: str
    notice: Optional[str] = None


def emit_progress(percent: float, stage: str, eta_seconds: Optional[float] = None) -> None:
    payload: Dict[str, Any] = {
        "percent": max(0.0, min(100.0, float(percent))),
        "stage": stage,
    }
    if eta_seconds is not None and eta_seconds >= 0:
        payload["eta_seconds"] = float(eta_seconds)

    print("VUKHOAI_PROGRESS " + json.dumps(payload, ensure_ascii=False), flush=True)


def emit_notice(message: str) -> None:
    payload = {"message": str(message or "").strip()}
    print("VUKHOAI_NOTICE " + json.dumps(payload, ensure_ascii=False), flush=True)


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


def clean_text(value: Any) -> str:
    return " ".join(str(value or "").split())


def safe_float(value: Any, fallback: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def infer_speaker_from_words(item: Dict[str, Any]) -> Optional[str]:
    words = item.get("words")
    if not isinstance(words, list):
        return None

    weights: Dict[str, float] = {}
    for word in words:
        if not isinstance(word, dict):
            continue

        speaker = word.get("speaker")
        if not speaker:
            continue

        start = safe_float(word.get("start"))
        end = safe_float(word.get("end"), start)
        weight = max(end - start, 0.001)
        weights[speaker] = weights.get(speaker, 0.0) + weight

    if not weights:
        return None

    return max(weights, key=weights.get)


def split_segment_by_speaker_runs(item: Dict[str, Any]) -> List[Dict[str, Any]]:
    start = safe_float(item.get("start"))
    end = safe_float(item.get("end"), start)
    if end < start:
        end = start

    text = clean_text(item.get("text"))
    words = item.get("words")
    if not isinstance(words, list):
        return [
            {
                "start": start,
                "end": end,
                "text": text,
                "speaker": item.get("speaker") or infer_speaker_from_words(item),
            }
        ]

    prepared_words: List[Dict[str, Any]] = []
    for word in words:
        if not isinstance(word, dict):
            continue

        token = clean_text(word.get("word") or word.get("text"))
        if not token:
            continue

        word_start = safe_float(word.get("start"), start)
        word_end = safe_float(word.get("end"), word_start)
        if word_end < word_start:
            word_end = word_start

        prepared_words.append(
            {
                "start": word_start,
                "end": word_end,
                "text": token,
                "speaker": word.get("speaker"),
            }
        )

    if not prepared_words:
        return [
            {
                "start": start,
                "end": end,
                "text": text,
                "speaker": item.get("speaker") or infer_speaker_from_words(item),
            }
        ]

    runs: List[Dict[str, Any]] = []
    current: Optional[Dict[str, Any]] = None
    fallback_speaker = item.get("speaker") or infer_speaker_from_words(item)

    for word in prepared_words:
        speaker = word.get("speaker") or (current.get("speaker") if current else None) or fallback_speaker
        if current and current.get("speaker") == speaker:
            current["end"] = max(float(current["end"]), float(word["end"]))
            current["text"] = f"{current['text']} {word['text']}".strip()
            continue

        if current:
            runs.append(current)

        current = {
            "start": word["start"],
            "end": word["end"],
            "text": word["text"],
            "speaker": speaker,
        }

    if current:
        runs.append(current)

    if not runs:
        return [
            {
                "start": start,
                "end": end,
                "text": text,
                "speaker": fallback_speaker,
            }
        ]

    runs[0]["start"] = min(float(runs[0]["start"]), start)
    runs[-1]["end"] = max(float(runs[-1]["end"]), end)
    return runs


def should_retry_whisperx(exc: Exception) -> bool:
    message = f"{type(exc).__name__}: {exc}".lower()
    return "badzipfile" in message or "file is not a zip file" in message


def should_retry_with_ukrainian(language_mode: str, detected_language: Optional[str]) -> bool:
    if language_mode != "auto" or not detected_language:
        return False
    return detected_language.lower() not in EXPECTED_AUTO_LANGUAGES


def wrong_language_notice(detected_language: Optional[str]) -> str:
    actual = detected_language or "unknown"
    return (
        f"Auto language detection returned '{actual}', but Vukho.AI is configured for Ukrainian "
        "transcription. Retrying once with Ukrainian forced to avoid wrong-language hallucinations."
    )


def clear_silero_vad_cache() -> None:
    hub_dir = Path.home() / ".cache" / "torch" / "hub"
    targets = [
        hub_dir / "master.zip",
        hub_dir / "snakers4_silero-vad_master",
        hub_dir / "trusted_list",
    ]

    for target in targets:
        if not target.exists():
            continue
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
        else:
            try:
                target.unlink()
            except OSError:
                pass


def resolve_faster_whisper_runtime(profile: str) -> FasterWhisperRuntime:
    try:
        import ctranslate2  # type: ignore
    except Exception as exc:
        return FasterWhisperRuntime(
            device="cpu",
            compute_type="int8",
            notice=f"CTranslate2 GPU probe is unavailable ({type(exc).__name__}). Using CPU transcription.",
        )

    cuda_count = 0
    try:
        cuda_count = int(ctranslate2.get_cuda_device_count())
    except Exception:
        cuda_count = 0

    if cuda_count <= 0:
        return FasterWhisperRuntime(device="cpu", compute_type="int8")

    supported_compute_types: set[str] = set()
    try:
        supported_compute_types = set(ctranslate2.get_supported_compute_types("cuda", 0))
    except Exception:
        supported_compute_types = set()

    if not supported_compute_types:
        return FasterWhisperRuntime(
            device="cpu",
            compute_type="int8",
            notice="CUDA GPU was detected, but CTranslate2 could not resolve a supported CUDA compute type. Falling back to CPU.",
        )

    preferred = ["float16", "int8_float16", "int8", "float32", "int8_float32"]
    if profile == "fast":
        preferred = ["int8_float16", "float16", "int8", "float32", "int8_float32"]

    compute_type = next((item for item in preferred if item in supported_compute_types), None)
    if not compute_type:
        return FasterWhisperRuntime(
            device="cpu",
            compute_type="int8",
            notice="CUDA GPU was detected, but no compatible CTranslate2 CUDA compute type was available. Falling back to CPU.",
        )

    return FasterWhisperRuntime(
        device="cuda",
        compute_type=compute_type,
        notice=f"Using NVIDIA CUDA acceleration for faster-whisper ({compute_type}).",
    )


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
    segments_to_process: List[Dict[str, Any]] = []

    def speaker_label(raw: Optional[str]) -> str:
        nonlocal next_speaker_index
        if not raw:
            return "SPEAKER_01"

        if raw not in speaker_map:
            speaker_map[raw] = f"SPEAKER_{next_speaker_index:02d}"
            next_speaker_index += 1
        return speaker_map[raw]

    for item in raw_segments:
        if diarization_requested and diarization_applied:
            segments_to_process.extend(split_segment_by_speaker_runs(item))
        else:
            segments_to_process.append(item)

    for item in segments_to_process:
        start = safe_float(item.get("start"))
        end = safe_float(item.get("end"), start)
        if end < start:
            end = start

        text = clean_text(item.get("text"))
        if not text:
            continue

        source_speaker = None
        if diarization_requested and diarization_applied:
            source_speaker = item.get("speaker") or infer_speaker_from_words(item)
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

    model = whisperx.load_model(
        model_name,
        device=device,
        compute_type=compute_type,
        vad_method="silero",
    )
    transcribe_kwargs: Dict[str, Any] = {
        "batch_size": 8,
    }
    if language_mode == "uk":
        transcribe_kwargs["language"] = UKRAINIAN_LANGUAGE

    emit_progress(20, "Transcribing")
    result = model.transcribe(audio_path, **transcribe_kwargs)
    segments = result.get("segments", [])

    detected_language = result.get("language") if language_mode == "auto" else UKRAINIAN_LANGUAGE
    language_retry_reason: Optional[str] = None
    if should_retry_with_ukrainian(language_mode, detected_language):
        original_language = detected_language
        language_retry_reason = f"auto_detected_{original_language}_forced_uk"
        emit_notice(wrong_language_notice(original_language))
        emit_progress(22, "Retrying with Ukrainian")
        retry_kwargs = dict(transcribe_kwargs)
        retry_kwargs["language"] = UKRAINIAN_LANGUAGE
        result = model.transcribe(audio_path, **retry_kwargs)
        segments = result.get("segments", [])
        detected_language = UKRAINIAN_LANGUAGE

    alignment_applied = False
    alignment_error: Optional[str] = None
    result_for_speakers: Dict[str, Any] = result
    diarization_pipeline: Optional[Any] = None

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
        hf_token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
        try:
            from whisperx.diarize import DiarizationPipeline  # type: ignore

            emit_progress(68, "Checking diarization readiness")
            diarization_pipeline = DiarizationPipeline(
                token=hf_token,
                device=device,
            )
        except Exception as exc:  # pragma: no cover - fallback path
            diarization_error = f"{type(exc).__name__}: {exc}"
            if not hf_token:
                diarization_error += " Configure HF token if pyannote models are not already cached."
            emit_notice(f"Diarization preflight failed. {diarization_error}")

    if diarization_enabled and diarization_pipeline is not None:
        try:
            emit_progress(82, "Applying diarization")
            diarized = diarization_pipeline(audio_path)
            assigned = whisperx.assign_word_speakers(diarized, result_for_speakers)
            segments = assigned.get("segments", segments)
            diarization_applied = True
        except Exception as exc:  # pragma: no cover - fallback path
            diarization_error = f"{type(exc).__name__}: {exc}"
            if not hf_token:
                diarization_error += " Configure HF token if pyannote models are not already cached."

    meta = {
        "engine": "whisperx",
        "detected_language": detected_language,
        "language_retry_reason": language_retry_reason,
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
    profile: str,
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    from faster_whisper import WhisperModel  # type: ignore

    runtime = resolve_faster_whisper_runtime(profile)
    if runtime.notice:
        emit_notice(runtime.notice)

    emit_progress(10, "Loading model")
    model = WhisperModel(model_name, device=runtime.device, compute_type=runtime.compute_type)
    language = None if language_mode == "auto" else UKRAINIAN_LANGUAGE

    emit_progress(15, "Transcribing")
    generated_segments, info = model.transcribe(
        audio_path,
        language=language,
        vad_filter=True,
        word_timestamps=True,
    )

    detected_language = getattr(info, "language", None)
    language_retry_reason: Optional[str] = None
    if should_retry_with_ukrainian(language_mode, detected_language):
        original_language = detected_language
        language_retry_reason = f"auto_detected_{original_language}_forced_uk"
        emit_notice(wrong_language_notice(original_language))
        emit_progress(17, "Retrying with Ukrainian")
        generated_segments, info = model.transcribe(
            audio_path,
            language=UKRAINIAN_LANGUAGE,
            vad_filter=True,
            word_timestamps=True,
        )
        detected_language = UKRAINIAN_LANGUAGE

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
        "runtime_device": runtime.device,
        "runtime_compute_type": runtime.compute_type,
        "detected_language": detected_language,
        "language_retry_reason": language_retry_reason,
        "alignment_applied": False,
        "alignment_error": "Alignment unavailable without whisperx.",
        "diarization_applied": False,
        "diarization_error": "Diarization unavailable without whisperx + pyannote.",
    }
    return segments, meta


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vukho.AI local transcription pipeline")
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
    whisperx_succeeded = False

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
            whisperx_succeeded = True
        except Exception as whisperx_error:
            fallback_events.append(f"whisperx unavailable: {type(whisperx_error).__name__}: {whisperx_error}")
            if should_retry_whisperx(whisperx_error):
                emit_notice("WhisperX cache looks corrupted. Retrying once after clearing cached Silero VAD files.")
                clear_silero_vad_cache()
                try:
                    raw_segments, engine_meta = transcribe_with_whisperx(
                        audio_path=args.input,
                        model_name=model_name,
                        language_mode=args.language,
                        diarization_enabled=diarization_requested,
                    )
                    whisperx_succeeded = True
                except Exception as retry_error:
                    whisperx_error = retry_error
                    fallback_events.append(
                        f"whisperx unavailable after retry: {type(retry_error).__name__}: {retry_error}"
                    )

            if not whisperx_succeeded:
                emit_notice(
                    "WhisperX is unavailable for this run. Falling back to faster-whisper, so diarization will be skipped."
                )
                emit_progress(6, "Falling back to faster-whisper")
                try:
                    raw_segments, engine_meta = transcribe_with_faster_whisper(
                        audio_path=args.input,
                        model_name=model_name,
                        language_mode=args.language,
                        total_duration_seconds=total_duration_seconds,
                        profile=args.profile,
                    )
                except Exception as fallback_error:
                    print("Transcription failed in both whisperx and faster-whisper.", file=sys.stderr)
                    print(f"whisperx error: {whisperx_error}", file=sys.stderr)
                    print(f"faster-whisper error: {fallback_error}", file=sys.stderr)
                    return 3
    else:
        fallback_events.append("whisperx unavailable: module not installed")
        emit_notice(
            "WhisperX is not installed in the selected diarization Python. Falling back to faster-whisper without diarization."
        )
        try:
            raw_segments, engine_meta = transcribe_with_faster_whisper(
                audio_path=args.input,
                model_name=model_name,
                language_mode=args.language,
                total_duration_seconds=total_duration_seconds,
                profile=args.profile,
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
        "speaker_count": len({segment.speaker for segment in segments}),
        "diarization_requested": diarization_requested,
        "diarization_applied": diarization_applied,
        "diarization_fallback_reason": diarization_fallback_reason,
        "engine": engine_meta.get("engine"),
        "runtime_device": engine_meta.get("runtime_device"),
        "runtime_compute_type": engine_meta.get("runtime_compute_type"),
        "detected_language": engine_meta.get("detected_language"),
        "language_retry_reason": engine_meta.get("language_retry_reason"),
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
