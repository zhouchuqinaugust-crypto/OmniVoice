#!/usr/bin/env python3

import argparse
import json
import shutil
import subprocess
import traceback
import wave
from pathlib import Path
from typing import Optional

import mlx_whisper
import numpy as np


TARGET_SAMPLE_RATE = 16_000
MIN_SPEECH_RMS = 0.0012
MIN_SPEECH_PEAK = 0.015
WEAK_SIGNAL_RMS = 0.012
WEAK_SIGNAL_PEAK = 0.12
TARGET_RMS = 0.12
MAX_GAIN = 12.0
HIGH_PASS_CUTOFF_HZ = 80.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Transcribe audio with mlx-whisper and emit JSON.")
    parser.add_argument("--audio", required=True, help="Audio file path.")
    parser.add_argument("--model", required=True, help="MLX model repo or local model directory.")
    parser.add_argument("--language", default="auto", help="Language code or 'auto'.")
    parser.add_argument(
        "--candidate-languages",
        default=None,
        help="Optional comma-separated shortlist of language codes to try instead of auto detection.",
    )
    parser.add_argument("--prompt", default=None, help="Optional initial prompt.")
    return parser.parse_args()


def decode_pcm_wav(audio_path: Path) -> np.ndarray:
    with wave.open(str(audio_path), "rb") as wav_file:
        channel_count = wav_file.getnchannels()
        sample_width = wav_file.getsampwidth()
        sample_rate = wav_file.getframerate()
        frame_count = wav_file.getnframes()
        frame_bytes = wav_file.readframes(frame_count)

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

    return resample_audio(audio, sample_rate)


def collapse_channels(audio: np.ndarray, channel_count: int) -> np.ndarray:
    audio = audio.reshape(-1, channel_count)
    channel_rms = np.sqrt(np.mean(np.square(audio), axis=0))
    strongest_channel = int(np.argmax(channel_rms))

    if channel_count == 2:
        quietest_rms = float(np.min(channel_rms))
        strongest_rms = float(channel_rms[strongest_channel])
        if quietest_rms > 0 and strongest_rms / quietest_rms < 1.25:
            return audio.mean(axis=1).astype(np.float32)

    return audio[:, strongest_channel].astype(np.float32)


def decode_with_ffmpeg(audio_path: Path) -> np.ndarray:
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path is None:
        raise RuntimeError(
            "Unsupported audio format without ffmpeg. Provide a PCM WAV file or install ffmpeg."
        )

    command = [
        ffmpeg_path,
        "-nostdin",
        "-v",
        "error",
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
    output = subprocess.run(command, capture_output=True, check=True)
    return np.frombuffer(output.stdout, dtype=np.int16).astype(np.float32) / 32768.0


def load_audio(audio_path: Path) -> np.ndarray:
    if audio_path.suffix.lower() in {".wav", ".wave"}:
        return decode_pcm_wav(audio_path)

    return decode_with_ffmpeg(audio_path)


def resample_audio(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    if sample_rate == TARGET_SAMPLE_RATE:
        return audio

    if audio.size == 0:
        return audio.astype(np.float32)

    duration = audio.shape[0] / float(sample_rate)
    target_length = max(1, int(round(duration * TARGET_SAMPLE_RATE)))
    source_positions = np.linspace(0.0, duration, num=audio.shape[0], endpoint=False)
    target_positions = np.linspace(0.0, duration, num=target_length, endpoint=False)
    return np.interp(target_positions, source_positions, audio).astype(np.float32)


def analyze_audio(audio: np.ndarray) -> dict:
    if audio.size == 0:
        return {
            "duration_seconds": 0.0,
            "peak": 0.0,
            "rms": 0.0,
        }

    float_audio = audio.astype(np.float32, copy=False)
    return {
        "duration_seconds": float(float_audio.shape[0] / TARGET_SAMPLE_RATE),
        "peak": float(np.max(np.abs(float_audio))),
        "rms": float(np.sqrt(np.mean(np.square(float_audio), dtype=np.float64))),
    }


def high_pass_filter(audio: np.ndarray, cutoff_hz: float = HIGH_PASS_CUTOFF_HZ) -> np.ndarray:
    if audio.size < 2:
        return audio.astype(np.float32, copy=False)

    dt = 1.0 / TARGET_SAMPLE_RATE
    rc = 1.0 / (2.0 * np.pi * cutoff_hz)
    alpha = rc / (rc + dt)

    filtered = np.empty_like(audio, dtype=np.float32)
    previous_input = float(audio[0])
    previous_output = 0.0
    filtered[0] = 0.0

    for index in range(1, audio.shape[0]):
        current_input = float(audio[index])
        current_output = alpha * (previous_output + current_input - previous_input)
        filtered[index] = current_output
        previous_input = current_input
        previous_output = current_output

    return filtered


def prepare_audio_for_transcription(audio: np.ndarray) -> tuple[np.ndarray, dict]:
    if audio.size == 0:
        metrics = analyze_audio(audio)
        metrics.update(
            {
                "processed_peak": 0.0,
                "processed_rms": 0.0,
                "gain": 1.0,
                "gain_db": 0.0,
            }
        )
        return audio.astype(np.float32), metrics

    prepared = audio.astype(np.float32, copy=False)
    prepared = prepared - np.mean(prepared, dtype=np.float64)
    prepared = high_pass_filter(prepared)

    raw_metrics = analyze_audio(prepared)
    raw_peak = raw_metrics["peak"]
    raw_rms = raw_metrics["rms"]

    gain = 1.0
    if raw_peak > 0.0 and raw_rms > 0.0:
        gain = min(
            MAX_GAIN,
            0.96 / max(raw_peak, 1e-6),
            TARGET_RMS / max(raw_rms, 1e-6),
        )
        gain = max(1.0, gain)

    prepared = np.clip(prepared * gain, -1.0, 1.0).astype(np.float32)
    processed_metrics = analyze_audio(prepared)
    processed_metrics.update(
        {
            "raw_peak": raw_peak,
            "raw_rms": raw_rms,
            "processed_peak": processed_metrics["peak"],
            "processed_rms": processed_metrics["rms"],
            "gain": float(gain),
            "gain_db": float(20.0 * np.log10(gain)) if gain > 0 else 0.0,
        }
    )
    return prepared, processed_metrics


def is_nearly_silent(audio_metrics: dict) -> bool:
    return (
        audio_metrics["raw_rms"] < MIN_SPEECH_RMS
        and audio_metrics["raw_peak"] < MIN_SPEECH_PEAK
    )


def is_weak_signal(audio_metrics: dict) -> bool:
    return (
        audio_metrics["raw_rms"] < WEAK_SIGNAL_RMS
        or audio_metrics["raw_peak"] < WEAK_SIGNAL_PEAK
        or audio_metrics["gain_db"] >= 12.0
    )


def summarize_decode_metrics(result: dict) -> dict:
    segments = result.get("segments") or []
    spoken_segments = [segment for segment in segments if (segment.get("text") or "").strip()]
    if not spoken_segments:
        return {
            "avg_logprob": None,
            "max_no_speech_prob": None,
            "max_compression_ratio": None,
        }

    return {
        "avg_logprob": float(
            np.mean([segment.get("avg_logprob", -10.0) for segment in spoken_segments])
        ),
        "max_no_speech_prob": float(
            np.max([segment.get("no_speech_prob", 0.0) for segment in spoken_segments])
        ),
        "max_compression_ratio": float(
            np.max([segment.get("compression_ratio", 0.0) for segment in spoken_segments])
        ),
    }


def should_reject_transcript(text: str, audio_metrics: dict, decode_metrics: dict) -> bool:
    if not text.strip():
        return True

    avg_logprob = decode_metrics.get("avg_logprob")
    max_no_speech_prob = decode_metrics.get("max_no_speech_prob")
    max_compression_ratio = decode_metrics.get("max_compression_ratio")

    if is_nearly_silent(audio_metrics):
        return True

    weak_signal = is_weak_signal(audio_metrics)
    if weak_signal and avg_logprob is not None and avg_logprob < -0.85:
        return True

    if (
        weak_signal
        and max_no_speech_prob is not None
        and max_no_speech_prob > 0.55
        and (avg_logprob is None or avg_logprob < -0.2)
    ):
        return True

    if (
        max_compression_ratio is not None
        and max_compression_ratio > 2.6
        and avg_logprob is not None
        and avg_logprob < -0.3
    ):
        return True

    return False


def transcription_score(text: str, decode_metrics: dict) -> float:
    if not text.strip():
        return float("-inf")

    avg_logprob = decode_metrics["avg_logprob"]
    max_no_speech_prob = decode_metrics["max_no_speech_prob"]
    max_compression_ratio = decode_metrics["max_compression_ratio"]

    score = avg_logprob if avg_logprob is not None else -5.0
    if max_no_speech_prob is not None:
        score -= max_no_speech_prob * 0.5
    if max_compression_ratio is not None:
        score -= max(0.0, max_compression_ratio - 2.0) * 0.3
    return float(score)


def transcribe_audio(
    audio: np.ndarray,
    args: argparse.Namespace,
    prompt: Optional[str],
    language: Optional[str],
) -> dict:
    decode_options = {
        "path_or_hf_repo": args.model,
        "verbose": None,
        "temperature": 0.0,
        "compression_ratio_threshold": 2.0,
        "logprob_threshold": -0.8,
        "no_speech_threshold": 0.45,
        "condition_on_previous_text": False,
    }

    if language:
        decode_options["language"] = language

    if prompt:
        decode_options["initial_prompt"] = prompt

    return mlx_whisper.transcribe(audio, **decode_options)


def candidate_languages(args: argparse.Namespace) -> list[Optional[str]]:
    if args.candidate_languages:
        candidates = []
        for value in args.candidate_languages.split(","):
            normalized = value.strip().lower()
            if normalized and normalized != "auto" and normalized not in candidates:
                candidates.append(normalized)
        if candidates:
            return candidates

    if args.language and args.language != "auto":
        return [args.language.lower()]

    return [None]


def main() -> int:
    args = parse_args()
    audio_path = Path(args.audio).expanduser()

    try:
        audio = load_audio(audio_path)
        prepared_audio, audio_metrics = prepare_audio_for_transcription(audio)
        if is_nearly_silent(audio_metrics):
            result = {"text": "", "language": None, "segments": []}
        else:
            prompt = None if is_weak_signal(audio_metrics) else args.prompt
            best_candidate = None
            best_score = float("-inf")

            for language in candidate_languages(args):
                candidate_result = transcribe_audio(prepared_audio, args, prompt, language)
                candidate_decode_metrics = summarize_decode_metrics(candidate_result)

                if prompt and should_reject_transcript(
                    candidate_result.get("text") or "",
                    audio_metrics,
                    candidate_decode_metrics,
                ):
                    retry_result = transcribe_audio(prepared_audio, args, None, language)
                    retry_decode_metrics = summarize_decode_metrics(retry_result)
                    retry_text = (retry_result.get("text") or "").strip()
                    retry_text = "" if should_reject_transcript(retry_text, audio_metrics, retry_decode_metrics) else retry_text
                    retry_score = transcription_score(retry_text, retry_decode_metrics)

                    candidate_text = (candidate_result.get("text") or "").strip()
                    candidate_text = "" if should_reject_transcript(candidate_text, audio_metrics, candidate_decode_metrics) else candidate_text
                    candidate_score = transcription_score(candidate_text, candidate_decode_metrics)

                    if retry_score >= candidate_score:
                        candidate_result = retry_result
                        candidate_decode_metrics = retry_decode_metrics
                        candidate_text = retry_text
                    else:
                        candidate_text = candidate_text
                else:
                    candidate_text = (candidate_result.get("text") or "").strip()
                    candidate_text = "" if should_reject_transcript(candidate_text, audio_metrics, candidate_decode_metrics) else candidate_text

                candidate_score = transcription_score(candidate_text, candidate_decode_metrics)
                if candidate_score > best_score:
                    best_score = candidate_score
                    best_candidate = (
                        candidate_result,
                        candidate_text,
                        candidate_decode_metrics,
                    )

            if best_candidate is None:
                result = {"text": "", "language": None, "segments": []}
            else:
                result, chosen_text, decode_metrics = best_candidate
                result = dict(result)
                result["text"] = chosen_text
    except Exception:
        traceback.print_exc()
        return 1

    decode_metrics = locals().get("decode_metrics", summarize_decode_metrics(result))
    text = (result.get("text") or "").strip()
    if should_reject_transcript(text, audio_metrics, decode_metrics):
        text = ""

    payload = {
        "text": text,
        "language": result.get("language"),
        "audio_metrics": audio_metrics,
        "decode_metrics": decode_metrics,
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
