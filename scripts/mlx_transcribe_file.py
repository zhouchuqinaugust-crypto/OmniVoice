#!/usr/bin/env python3

import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from typing import BinaryIO, Iterator, Optional

import numpy as np

from mlx_transcribe import (
    TARGET_SAMPLE_RATE,
    candidate_languages,
    collapse_channels,
    is_nearly_silent,
    is_weak_signal,
    prepare_audio_for_transcription,
    should_reject_transcript,
    summarize_decode_metrics,
    transcription_score,
    transcribe_audio,
)


PCM_WAV_FORMAT = 0x0001
WAVE_FORMAT_EXTENSIBLE = 0xFFFE
PCM_SUBFORMAT_GUID = bytes.fromhex("0100000000001000800000aa00389b71")


class PCMHeader:
    def __init__(
        self,
        channel_count: int,
        sample_width: int,
        sample_rate: int,
        data_offset: int,
        data_size: int,
    ) -> None:
        self.channel_count = channel_count
        self.sample_width = sample_width
        self.sample_rate = sample_rate
        self.data_offset = data_offset
        self.data_size = data_size


def parse_pcm_wav_header(file_handle: BinaryIO) -> PCMHeader:
    file_handle.seek(0)
    riff_header = file_handle.read(12)
    if len(riff_header) < 12:
        raise ValueError("Invalid WAV file: header is too short")

    riff_id, _, wave_id = struct.unpack("<4sI4s", riff_header)
    if riff_id != b"RIFF" or wave_id != b"WAVE":
        raise ValueError("Invalid WAV file: expected RIFF/WAVE")

    format_code = None
    channel_count = None
    sample_rate = None
    sample_width = None
    data_offset = None
    data_size = None

    while True:
        chunk_header = file_handle.read(8)
        if len(chunk_header) == 0:
            break
        if len(chunk_header) < 8:
            raise ValueError("Invalid WAV file: truncated chunk header")

        chunk_id, chunk_size = struct.unpack("<4sI", chunk_header)
        chunk_data_offset = file_handle.tell()

        if chunk_id == b"fmt ":
            fmt_data = file_handle.read(chunk_size)
            if len(fmt_data) < 16:
                raise ValueError("Invalid WAV file: fmt chunk is too short")

            (
                format_code,
                channel_count,
                sample_rate,
                _byte_rate,
                _block_align,
                bits_per_sample,
            ) = struct.unpack("<HHIIHH", fmt_data[:16])
            sample_width = bits_per_sample // 8

            if format_code == WAVE_FORMAT_EXTENSIBLE:
                if len(fmt_data) < 40:
                    raise ValueError("Invalid WAV file: extensible fmt chunk is too short")
                subformat_guid = fmt_data[24:40]
                if subformat_guid != PCM_SUBFORMAT_GUID:
                    raise ValueError(f"Unsupported WAV extensible subformat: {subformat_guid.hex()}")
                format_code = PCM_WAV_FORMAT
        elif chunk_id == b"data":
            data_offset = chunk_data_offset
            data_size = chunk_size
            file_handle.seek(chunk_size, os.SEEK_CUR)
        else:
            file_handle.seek(chunk_size, os.SEEK_CUR)

        if chunk_size % 2:
            file_handle.seek(1, os.SEEK_CUR)

    if format_code != PCM_WAV_FORMAT:
        raise ValueError(f"Unsupported WAV format: {format_code}")
    if channel_count is None or sample_rate is None or sample_width is None:
        raise ValueError("Invalid WAV file: missing fmt chunk")
    if data_offset is None or data_size is None:
        raise ValueError("Invalid WAV file: missing data chunk")
    if sample_width not in {1, 2, 4}:
        raise ValueError(f"Unsupported WAV sample width: {sample_width * 8} bits")

    return PCMHeader(
        channel_count=channel_count,
        sample_width=sample_width,
        sample_rate=sample_rate,
        data_offset=data_offset,
        data_size=data_size,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transcribe a local audio file with mlx-whisper, chunking large inputs and emitting JSON."
    )
    parser.add_argument("--audio", required=True, help="Audio file path.")
    parser.add_argument("--model", required=True, help="MLX model repo or local model directory.")
    parser.add_argument("--language", default="auto", help="Language code or 'auto'.")
    parser.add_argument(
        "--candidate-languages",
        default=None,
        help="Optional comma-separated shortlist of language codes to try instead of auto detection.",
    )
    parser.add_argument("--prompt", default=None, help="Optional initial prompt.")
    parser.add_argument(
        "--chunk-seconds",
        type=int,
        default=900,
        help="Chunk size in seconds for long recordings. Defaults to 900 seconds.",
    )
    parser.add_argument(
        "--diarize",
        action="store_true",
        help="Try to label speakers with pyannote.audio when available.",
    )
    return parser.parse_args()


def decode_pcm_frames(
    frame_bytes: bytes,
    sample_width: int,
    channel_count: int,
    sample_rate: int,
) -> np.ndarray:
    if sample_width == 1:
        audio = np.frombuffer(frame_bytes, dtype=np.uint8).astype(np.float32)
        audio = (audio - 128.0) / 128.0
    elif sample_width == 2:
        audio = np.frombuffer(frame_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    elif sample_width == 4:
        audio = np.frombuffer(frame_bytes, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"Unsupported WAV sample width: {sample_width * 8} bits")

    if channel_count > 1:
        audio = collapse_channels(audio, channel_count)

    if sample_rate != TARGET_SAMPLE_RATE and audio.size:
        duration = audio.shape[0] / float(sample_rate)
        target_length = max(1, int(round(duration * TARGET_SAMPLE_RATE)))
        source_positions = np.linspace(0.0, duration, num=audio.shape[0], endpoint=False)
        target_positions = np.linspace(0.0, duration, num=target_length, endpoint=False)
        audio = np.interp(target_positions, source_positions, audio).astype(np.float32)

    return audio.astype(np.float32, copy=False)


def probe_duration_seconds(audio_path: Path) -> Optional[float]:
    if audio_path.suffix.lower() in {".wav", ".wave"}:
        with audio_path.open("rb") as audio_file:
            header = parse_pcm_wav_header(audio_file)
            frame_size = header.sample_width * header.channel_count
            frame_count = header.data_size // frame_size
            return frame_count / float(header.sample_rate)

    ffprobe_path = shutil.which("ffprobe")
    if ffprobe_path is None:
        return None

    command = [
        ffprobe_path,
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(audio_path),
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        return None

    try:
        duration = float(result.stdout.strip())
    except ValueError:
        return None

    if duration <= 0:
        return None
    return duration


def probe_duration_seconds_with_afinfo(audio_path: Path) -> Optional[float]:
    afinfo_path = shutil.which("afinfo") or "/usr/bin/afinfo"
    if not Path(afinfo_path).exists():
        return None

    result = subprocess.run([afinfo_path, str(audio_path)], capture_output=True, text=True)
    if result.returncode != 0:
        return None

    for line in result.stdout.splitlines():
        normalized = line.strip().lower()
        if not normalized.startswith("estimated duration:"):
            continue

        value = normalized.removeprefix("estimated duration:").strip().split(" ", 1)[0]
        try:
            duration = float(value)
        except ValueError:
            return None
        return duration if duration > 0 else None

    return None


def iter_pcm_wav_chunks(
    audio_path: Path,
    chunk_seconds: int,
) -> Iterator[tuple[float, float, np.ndarray]]:
    with audio_path.open("rb") as audio_file:
        header = parse_pcm_wav_header(audio_file)
        channel_count = header.channel_count
        sample_width = header.sample_width
        sample_rate = header.sample_rate
        frame_size = sample_width * channel_count
        frames_per_chunk = max(1, int(sample_rate * chunk_seconds))
        bytes_per_chunk = frames_per_chunk * frame_size
        chunk_index = 0
        bytes_remaining = header.data_size

        audio_file.seek(header.data_offset)

        while bytes_remaining > 0:
            frame_bytes = audio_file.read(min(bytes_per_chunk, bytes_remaining))
            if not frame_bytes:
                break
            bytes_remaining -= len(frame_bytes)

            extra_bytes = len(frame_bytes) % frame_size
            if extra_bytes:
                frame_bytes = frame_bytes[:-extra_bytes]
            if not frame_bytes:
                break

            start_seconds = chunk_index * chunk_seconds
            audio = decode_pcm_frames(
                frame_bytes=frame_bytes,
                sample_width=sample_width,
                channel_count=channel_count,
                sample_rate=sample_rate,
            )
            duration_seconds = audio.shape[0] / float(TARGET_SAMPLE_RATE) if audio.size else 0.0
            yield start_seconds, duration_seconds, audio
            chunk_index += 1


def decode_audio_chunk_with_ffmpeg(
    audio_path: Path,
    start_seconds: float,
    chunk_seconds: int,
) -> np.ndarray:
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path is None:
        raise RuntimeError(
            "Non-WAV audio chunking requires ffmpeg or macOS afconvert. Install ffmpeg, use macOS, or provide a PCM WAV file."
        )

    command = [
        ffmpeg_path,
        "-nostdin",
        "-v",
        "error",
        "-ss",
        str(start_seconds),
        "-t",
        str(chunk_seconds),
        "-i",
        str(audio_path),
        "-f",
        "s16le",
        "-ac",
        "1",
        "-ar",
        str(TARGET_SAMPLE_RATE),
        "-",
    ]
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", errors="ignore"))

    audio = np.frombuffer(result.stdout, dtype=np.int16).astype(np.float32)
    if audio.size == 0:
        return np.zeros(0, dtype=np.float32)
    return (audio / 32768.0).astype(np.float32, copy=False)


def iter_ffmpeg_chunks(
    audio_path: Path,
    chunk_seconds: int,
    duration_seconds: Optional[float],
) -> Iterator[tuple[float, float, np.ndarray]]:
    chunk_index = 0

    while True:
        start_seconds = chunk_index * chunk_seconds
        if duration_seconds is not None and start_seconds >= duration_seconds:
            break

        audio = decode_audio_chunk_with_ffmpeg(audio_path, start_seconds, chunk_seconds)
        if audio.size == 0:
            break

        actual_duration_seconds = audio.shape[0] / float(TARGET_SAMPLE_RATE)
        yield start_seconds, actual_duration_seconds, audio

        if actual_duration_seconds < chunk_seconds * 0.98:
            break

        chunk_index += 1


def convert_audio_with_afconvert(audio_path: Path) -> Path:
    afconvert_path = shutil.which("afconvert") or "/usr/bin/afconvert"
    if not Path(afconvert_path).exists():
        raise RuntimeError(
            "Non-WAV audio chunking requires ffmpeg or macOS afconvert. Install ffmpeg, use macOS, or provide a PCM WAV file."
        )

    temp_file = tempfile.NamedTemporaryFile(
        prefix="omnivoice-transcribe-",
        suffix=".wav",
        delete=False,
    )
    temp_path = Path(temp_file.name)
    temp_file.close()

    command = [
        afconvert_path,
        str(audio_path),
        str(temp_path),
        "-f",
        "WAVE",
        "-d",
        f"LEI16@{TARGET_SAMPLE_RATE}",
        "-c",
        "1",
    ]
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        temp_path.unlink(missing_ok=True)
        error = result.stderr.decode("utf-8", errors="ignore").strip()
        if not error:
            error = result.stdout.decode("utf-8", errors="ignore").strip()
        raise RuntimeError(f"afconvert failed to decode audio: {error}")

    return temp_path


def iter_afconvert_chunks(
    audio_path: Path,
    chunk_seconds: int,
) -> Iterator[tuple[float, float, np.ndarray]]:
    converted_path = convert_audio_with_afconvert(audio_path)
    try:
        yield from iter_pcm_wav_chunks(converted_path, chunk_seconds)
    finally:
        converted_path.unlink(missing_ok=True)


def total_chunk_count(duration_seconds: Optional[float], chunk_seconds: int) -> Optional[int]:
    if duration_seconds is None:
        return None
    if duration_seconds <= 0:
        return 0
    return max(1, int(math.ceil(duration_seconds / float(chunk_seconds))))


def iter_audio_chunks(
    audio_path: Path,
    chunk_seconds: int,
    duration_seconds: Optional[float],
) -> Iterator[tuple[float, float, np.ndarray]]:
    if audio_path.suffix.lower() in {".wav", ".wave"}:
        yield from iter_pcm_wav_chunks(audio_path, chunk_seconds)
        return

    if shutil.which("ffmpeg") is not None:
        yield from iter_ffmpeg_chunks(audio_path, chunk_seconds, duration_seconds)
        return

    yield from iter_afconvert_chunks(audio_path, chunk_seconds)


def transcribe_chunk(
    audio: np.ndarray,
    args: argparse.Namespace,
) -> tuple[dict, dict]:
    prepared_audio, audio_metrics = prepare_audio_for_transcription(audio)
    if is_nearly_silent(audio_metrics):
        return {"text": "", "language": None, "segments": []}, audio_metrics

    prompt = None if is_weak_signal(audio_metrics) else args.prompt
    best_candidate = None
    best_score = float("-inf")

    for language in candidate_languages(args):
        candidate_result = transcribe_audio(prepared_audio, args, prompt, language)
        candidate_decode_metrics = summarize_decode_metrics(candidate_result)

        candidate_text = (candidate_result.get("text") or "").strip()
        should_retry_without_prompt = (
            prompt is not None
            and should_reject_transcript(candidate_text, audio_metrics, candidate_decode_metrics)
        )

        if should_retry_without_prompt:
            retry_result = transcribe_audio(prepared_audio, args, None, language)
            retry_decode_metrics = summarize_decode_metrics(retry_result)
            retry_text = (retry_result.get("text") or "").strip()
            retry_score = transcription_score(retry_text, retry_decode_metrics)
            candidate_score = transcription_score(candidate_text, candidate_decode_metrics)
            if retry_score >= candidate_score:
                candidate_result = retry_result
                candidate_decode_metrics = retry_decode_metrics
                candidate_text = retry_text

        candidate_score = transcription_score(candidate_text, candidate_decode_metrics)
        if candidate_score > best_score:
            best_score = candidate_score
            best_candidate = (
                dict(candidate_result),
                candidate_text,
            )

    if best_candidate is None:
        return {"text": "", "language": None, "segments": []}, audio_metrics

    chosen_result, chosen_text = best_candidate
    chosen_result["text"] = chosen_text
    return chosen_result, audio_metrics


def chunk_segments(
    chunk_result: dict,
    chunk_start_seconds: float,
    chunk_duration_seconds: float,
) -> list[dict]:
    segments = []
    for segment in chunk_result.get("segments") or []:
        text = (segment.get("text") or "").strip()
        if not text:
            continue

        start_seconds = segment.get("start")
        end_seconds = segment.get("end")
        if start_seconds is None:
            start_seconds = 0.0
        if end_seconds is None:
            end_seconds = chunk_duration_seconds

        start_seconds = chunk_start_seconds + float(start_seconds)
        end_seconds = chunk_start_seconds + float(end_seconds)
        if end_seconds < start_seconds:
            end_seconds = start_seconds

        segments.append(
            {
                "start": start_seconds,
                "end": end_seconds,
                "text": text,
                "speaker": None,
            }
        )

    if not segments:
        text = (chunk_result.get("text") or "").strip()
        if text:
            segments.append(
                {
                    "start": chunk_start_seconds,
                    "end": chunk_start_seconds + chunk_duration_seconds,
                    "text": text,
                    "speaker": None,
                }
            )

    return segments


def optional_diarization(audio_path: Path) -> tuple[list[dict], Optional[str], Optional[str]]:
    try:
        from pyannote.audio import Pipeline
    except Exception:
        return [], None, "Speaker labels need pyannote.audio. Transcript was exported without diarization."

    token = (
        os.environ.get("PYANNOTE_AUTH_TOKEN")
        or os.environ.get("HF_TOKEN")
        or os.environ.get("HUGGINGFACE_TOKEN")
    )
    if not token:
        return (
            [],
            None,
            "Speaker labels need a Hugging Face token in PYANNOTE_AUTH_TOKEN, HF_TOKEN, or HUGGINGFACE_TOKEN.",
        )

    model_id = "pyannote/speaker-diarization-3.1"
    try:
        pipeline = Pipeline.from_pretrained(model_id, use_auth_token=token)
        diarization = pipeline(str(audio_path))
    except Exception as error:
        return [], None, f"Speaker diarization failed: {error}"

    speaker_turns = []
    for segment, _, speaker in diarization.itertracks(yield_label=True):
        speaker_turns.append(
            {
                "start": float(segment.start),
                "end": float(segment.end),
                "speaker": str(speaker),
            }
        )

    return speaker_turns, model_id, None


def assign_speaker(speaker_turns: list[dict], start_seconds: float, end_seconds: float) -> Optional[str]:
    best_speaker = None
    best_overlap = 0.0

    for turn in speaker_turns:
        overlap = min(end_seconds, turn["end"]) - max(start_seconds, turn["start"])
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = turn["speaker"]

    return best_speaker


def main() -> int:
    args = parse_args()
    audio_path = Path(args.audio).expanduser()
    warnings = []

    try:
        chunk_seconds = max(60, args.chunk_seconds)
        duration_seconds = probe_duration_seconds(audio_path) or probe_duration_seconds_with_afinfo(audio_path)
        expected_chunk_count = total_chunk_count(duration_seconds, chunk_seconds)
        all_segments = []
        last_language = None
        processed_chunk_count = 0

        for index, (chunk_start_seconds, chunk_duration_seconds, audio) in enumerate(
            iter_audio_chunks(audio_path, chunk_seconds, duration_seconds),
            start=1,
        ):
            processed_chunk_count = index
            chunk_end_seconds = chunk_start_seconds + chunk_duration_seconds
            chunk_label = (
                f"{index}/{expected_chunk_count}"
                if expected_chunk_count is not None
                else f"{index}/?"
            )
            print(
                f"[OmniVoice] Transcribing chunk {chunk_label} "
                f"({chunk_start_seconds:.0f}s - {chunk_end_seconds:.0f}s)",
                file=sys.stderr,
                flush=True,
            )
            chunk_result, audio_metrics = transcribe_chunk(audio, args)
            if is_nearly_silent(audio_metrics):
                warnings.append(
                    f"Skipped chunk {index}: audio level was near silent "
                    f"(raw_rms={audio_metrics.get('raw_rms', 0.0):.6f}, "
                    f"raw_peak={audio_metrics.get('raw_peak', 0.0):.6f})."
                )
                continue

            segments = chunk_segments(
                chunk_result=chunk_result,
                chunk_start_seconds=chunk_start_seconds,
                chunk_duration_seconds=chunk_duration_seconds,
            )
            if not segments:
                warnings.append(f"Chunk {index} produced no transcript text.")
                continue

            all_segments.extend(segments)
            if chunk_result.get("language"):
                last_language = chunk_result.get("language")

        if duration_seconds is None and processed_chunk_count > 0 and all_segments:
            duration_seconds = max(segment["end"] for segment in all_segments)

        if processed_chunk_count == 0:
            payload = {
                "text": "",
                "language": None,
                "duration_seconds": duration_seconds,
                "diarization_performed": False,
                "diarization_method": None,
                "warnings": warnings,
                "segments": [],
            }
            print(json.dumps(payload, ensure_ascii=False))
            return 0

        diarization_performed = False
        diarization_method = None
        if args.diarize and all_segments:
            print("[OmniVoice] Running speaker diarization", file=sys.stderr, flush=True)
            speaker_turns, diarization_method, diarization_warning = optional_diarization(audio_path)
            if diarization_warning:
                warnings.append(diarization_warning)
            if speaker_turns:
                diarization_performed = True
                for segment in all_segments:
                    segment["speaker"] = assign_speaker(
                        speaker_turns=speaker_turns,
                        start_seconds=segment["start"],
                        end_seconds=segment["end"],
                    )

        combined_text = "\n".join(
            segment["text"].strip()
            for segment in all_segments
            if segment["text"].strip()
        ).strip()

        payload = {
            "text": combined_text,
            "language": last_language,
            "duration_seconds": duration_seconds,
            "diarization_performed": diarization_performed,
            "diarization_method": diarization_method,
            "warnings": warnings,
            "segments": all_segments,
        }
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    except Exception as error:
        if os.environ.get("OMNIVOICE_DEBUG_TRANSCRIBE_FILE") == "1":
            traceback.print_exc()
        else:
            print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
