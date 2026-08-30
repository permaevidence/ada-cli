#!/usr/bin/env python3
"""Probe and QA media files: metadata, frames, contact sheet, audio, cut points.

Always prints a JSON summary (duration, container, streams). Optional modes
add more, and can be combined in one call:

  --frames N            extract N frames spread across the duration
  --at SECONDS          extract a frame at a timestamp (repeatable)
  --sheet [CxR]         ONE tiled contact-sheet image with timestamped thumbs
                        (default 6x5). The cheap way to locate an event —
                        inspect the sheet, then pull 1-2 full frames with --at.
  --audio               loudness stats (volumedetect + EBU R128) and a
                        waveform PNG — lets a vision model verify mixes,
                        mutes, and fades without hearing the audio
  --spectrogram         with --audio, also render a spectrogram PNG
  --scenes [THRESHOLD]  timestamps of hard cuts (scene-change detection,
                        default threshold 0.4)
  --silence             silence intervals (speech/dead-air boundaries)

Usage:
  python3 probe_video.py input.mp4
  python3 probe_video.py input.mp4 --sheet --out-dir qa
  python3 probe_video.py output.mp4 --audio --frames 4 --out-dir qa
  python3 probe_video.py input.mp4 --scenes 0.3 --silence
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Probe and QA a media file.")
    parser.add_argument("video", type=Path, help="Input media path")
    parser.add_argument("--frames", type=int, default=0, help="Extract N frames spread across the duration")
    parser.add_argument("--at", type=float, action="append", default=[], help="Extract a frame at this timestamp (seconds); repeatable")
    parser.add_argument("--sheet", nargs="?", const="6x5", default=None, metavar="CxR",
                        help="Render a tiled contact sheet (default grid 6x5)")
    parser.add_argument("--audio", action="store_true", help="Audio loudness stats + waveform PNG")
    parser.add_argument("--spectrogram", action="store_true", help="With --audio, also render a spectrogram PNG")
    parser.add_argument("--scenes", nargs="?", const=0.4, default=None, type=float, metavar="THRESHOLD",
                        help="Detect scene changes (default threshold 0.4)")
    parser.add_argument("--silence", action="store_true", help="Detect silence intervals")
    parser.add_argument("--silence-noise", default="-30dB", help="silencedetect noise floor (default -30dB)")
    parser.add_argument("--silence-duration", type=float, default=0.5, help="Minimum silence length in seconds (default 0.5)")
    parser.add_argument("--out-dir", type=Path, default=Path("video_qa"), help="Output directory for images")
    return parser.parse_args()


def run(cmd: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def probe(path: Path) -> dict:
    result = run([
        "ffprobe", "-v", "error",
        "-show_entries",
        "format=duration,size,format_name:"
        "stream=index,codec_type,codec_name,width,height,avg_frame_rate,pix_fmt,sample_rate,channels",
        "-of", "json", str(path),
    ])
    if result.returncode != 0:
        print(f"error: ffprobe failed: {result.stderr.strip()}", file=sys.stderr)
        raise SystemExit(1)
    return json.loads(result.stdout)


def summarize(raw: dict) -> dict:
    fmt = raw.get("format", {})
    summary: dict = {
        "container": fmt.get("format_name"),
        "duration_s": round(float(fmt["duration"]), 3) if fmt.get("duration") else None,
        "size_bytes": int(fmt["size"]) if fmt.get("size") else None,
        "streams": [],
    }
    for stream in raw.get("streams", []):
        entry: dict = {
            "index": stream.get("index"),
            "type": stream.get("codec_type"),
            "codec": stream.get("codec_name"),
        }
        if stream.get("codec_type") == "video":
            entry.update(
                width=stream.get("width"),
                height=stream.get("height"),
                fps=stream.get("avg_frame_rate"),
                pix_fmt=stream.get("pix_fmt"),
            )
        elif stream.get("codec_type") == "audio":
            entry.update(
                sample_rate=stream.get("sample_rate"),
                channels=stream.get("channels"),
            )
        summary["streams"].append(entry)
    summary["has_audio"] = any(s["type"] == "audio" for s in summary["streams"])
    summary["has_video"] = any(s["type"] == "video" for s in summary["streams"])
    return summary


def spread_timestamps(duration: float, count: int) -> List[float]:
    if count <= 0:
        return []
    if count == 1:
        return [duration / 2]
    start, end = 0.1, max(duration - 0.2, 0.1)
    step = (end - start) / (count - 1)
    return [round(start + i * step, 2) for i in range(count)]


def extract_frame(path: Path, ts: float, out_dir: Path) -> Optional[Path]:
    out = out_dir / f"frame_{ts:08.2f}s.jpg"
    result = run([
        "ffmpeg", "-y", "-v", "error",
        "-ss", f"{ts:.2f}", "-i", str(path),
        "-frames:v", "1", "-q:v", "2", str(out),
    ])
    if result.returncode != 0 or not out.exists():
        print(f"warning: failed to extract frame at {ts}s: {result.stderr.strip()}", file=sys.stderr)
        return None
    return out


def contact_sheet(path: Path, duration: float, grid: str, out_dir: Path) -> dict:
    match = re.fullmatch(r"(\d+)x(\d+)", grid.strip().lower())
    if not match:
        return {"error": f"bad --sheet grid '{grid}', expected like 6x5"}
    cols, rows = int(match.group(1)), int(match.group(2))
    count = cols * rows
    fps = count / max(duration, 0.1)
    out = out_dir / "contact_sheet.png"

    def drawtext(fontfile: Optional[str]) -> str:
        font = f"fontfile={fontfile}:" if fontfile else ""
        return (
            f"drawtext={font}text='%{{pts\\:hms}}':x=4:y=4:fontsize=20:fontcolor=white:"
            "box=1:boxcolor=black@0.6:boxborderw=4,"
        )

    base = f"fps={fps:.6f},{{ts}}scale=320:-2,tile={cols}x{rows}"
    # drawtext may be missing from the build or lack a default font;
    # degrade from explicit font -> fontconfig default -> no labels.
    attempts: List[tuple] = []
    arial = "/System/Library/Fonts/Supplemental/Arial.ttf"
    if Path(arial).exists():
        attempts.append((drawtext(arial), True))
    attempts.append((drawtext(None), True))
    attempts.append(("", False))
    for ts_part, labelled in attempts:
        result = run([
            "ffmpeg", "-y", "-v", "error", "-i", str(path),
            "-vf", base.format(ts=ts_part),
            "-frames:v", "1", str(out),
        ])
        if result.returncode == 0 and out.exists():
            interval = duration / count
            return {
                "image": str(out),
                "grid": f"{cols}x{rows}",
                "thumbnails": count,
                "seconds_per_thumbnail": round(interval, 2),
                "timestamps_burned_in": labelled,
                "note": "Read left-to-right, top-to-bottom." + (
                    "" if labelled else
                    f" No timestamp labels (no drawtext font); thumbnail k covers ~[k*{interval:.2f}s, (k+1)*{interval:.2f}s)."
                ),
            }
    return {"error": f"contact sheet failed: {result.stderr.strip()[:300]}"}


def audio_report(path: Path, duration: float, out_dir: Path, want_spectrogram: bool) -> dict:
    report: dict = {}

    detect = run([
        "ffmpeg", "-v", "info", "-i", str(path),
        "-map", "0:a:0", "-af", "volumedetect,ebur128", "-f", "null", "-",
    ])
    log = detect.stderr
    mean = re.search(r"mean_volume:\s*(-?[\d.]+) dB", log)
    peak = re.search(r"max_volume:\s*(-?[\d.]+) dB", log)
    if mean:
        report["mean_volume_db"] = float(mean.group(1))
    if peak:
        report["peak_volume_db"] = float(peak.group(1))
    integrated = re.findall(r"I:\s*(-?[\d.]+) LUFS", log)
    lra = re.findall(r"LRA:\s*(-?[\d.]+) LU", log)
    if integrated:
        report["integrated_loudness_lufs"] = float(integrated[-1])
    if lra:
        report["loudness_range_lu"] = float(lra[-1])
    if not report:
        return {"error": f"no audio stats (does the file have audio?): {detect.stderr.strip()[-200:]}"}

    wave = out_dir / "waveform.png"
    result = run([
        "ffmpeg", "-y", "-v", "error", "-i", str(path),
        "-filter_complex", "[0:a:0]showwavespic=s=1920x480:split_channels=1",
        "-frames:v", "1", str(wave),
    ])
    if result.returncode == 0 and wave.exists():
        report["waveform"] = str(wave)
        report["waveform_note"] = (
            f"Full duration {duration:.2f}s maps linearly to the 1920px width "
            f"({duration / 1920:.4f}s per px). Verify mutes (flat gaps), fades (ramps), and mix balance visually."
        )

    if want_spectrogram:
        spec = out_dir / "spectrogram.png"
        result = run([
            "ffmpeg", "-y", "-v", "error", "-i", str(path),
            "-filter_complex", "[0:a:0]showspectrumpic=s=1920x512:legend=1",
            "-frames:v", "1", str(spec),
        ])
        if result.returncode == 0 and spec.exists():
            report["spectrogram"] = str(spec)

    return report


def scene_changes(path: Path, threshold: float) -> dict:
    result = run([
        "ffmpeg", "-v", "info", "-i", str(path),
        "-filter:v", f"select='gt(scene,{threshold})',showinfo",
        "-an", "-f", "null", "-",
    ])
    stamps = [round(float(m), 3) for m in re.findall(r"pts_time:([\d.]+)", result.stderr)]
    return {
        "threshold": threshold,
        "cut_count": len(stamps),
        "cut_timestamps_s": stamps,
        "note": "Candidate hard cuts. Confirm a cut with --at <t-0.2> and --at <t+0.2> before trimming on it.",
    }


def silence_intervals(path: Path, noise: str, min_duration: float) -> dict:
    result = run([
        "ffmpeg", "-v", "info", "-i", str(path),
        "-af", f"silencedetect=noise={noise}:d={min_duration}", "-f", "null", "-",
    ])
    log = result.stderr
    starts = [float(m) for m in re.findall(r"silence_start:\s*(-?[\d.]+)", log)]
    ends = re.findall(r"silence_end:\s*(-?[\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)", log)
    intervals = []
    for i, start in enumerate(starts):
        if i < len(ends):
            intervals.append({
                "start_s": round(start, 3),
                "end_s": round(float(ends[i][0]), 3),
                "duration_s": round(float(ends[i][1]), 3),
            })
        else:
            intervals.append({"start_s": round(start, 3), "end_s": None, "duration_s": None})
    return {
        "noise_floor": noise,
        "min_duration_s": min_duration,
        "silence_count": len(intervals),
        "intervals": intervals,
    }


def main() -> int:
    args = parse_args()
    video = args.video.expanduser().resolve()
    if not video.exists():
        print(f"error: file not found: {video}", file=sys.stderr)
        return 2
    for tool in ("ffprobe", "ffmpeg"):
        if shutil.which(tool) is None:
            print(f"error: {tool} not found on PATH", file=sys.stderr)
            return 1

    summary = summarize(probe(video))
    duration = summary.get("duration_s")
    needs_images = args.frames > 0 or args.at or args.sheet or args.audio

    out_dir = args.out_dir.expanduser().resolve()
    if needs_images:
        out_dir.mkdir(parents=True, exist_ok=True)

    timestamps = list(args.at)
    if args.frames > 0:
        if duration is None:
            print("error: cannot spread frames, duration unknown; use --at", file=sys.stderr)
            return 1
        timestamps.extend(spread_timestamps(duration, args.frames))

    if timestamps:
        frames = []
        for ts in sorted(set(timestamps)):
            frame = extract_frame(video, ts, out_dir)
            if frame is not None:
                frames.append(str(frame))
        summary["qa_frames"] = frames

    if args.sheet:
        if not summary["has_video"] or duration is None:
            summary["contact_sheet"] = {"error": "no video stream or unknown duration"}
        else:
            summary["contact_sheet"] = contact_sheet(video, duration, args.sheet, out_dir)

    if args.audio:
        if not summary["has_audio"]:
            summary["audio"] = {"error": "file has no audio stream"}
        else:
            summary["audio"] = audio_report(video, duration or 0.0, out_dir, args.spectrogram)

    if args.scenes is not None:
        if not summary["has_video"]:
            summary["scenes"] = {"error": "file has no video stream"}
        else:
            summary["scenes"] = scene_changes(video, args.scenes)

    if args.silence:
        if not summary["has_audio"]:
            summary["silence"] = {"error": "file has no audio stream"}
        else:
            summary["silence"] = silence_intervals(video, args.silence_noise, args.silence_duration)

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
