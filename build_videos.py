#!/usr/bin/env python3
"""Build-time video pipeline.

Steps:
1) Convert input videos to WebM (VP9) using FFmpeg.
2) Wrap WebM bytes into a simple .video container:
   - Header: 4s magic "VID0"
   - uint32 version (1)
   - uint64 webm_size_bytes
   - Payload: raw WebM bytes

No decoding or parsing of WebM is performed; bytes are copied verbatim.
"""

from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

MAGIC = b"VID0"
VERSION = 1
HEADER_STRUCT = struct.Struct("<4sIQ")  # magic, version, webm_size

VIDEO_EXTS = {
    ".mp4",
    ".mov",
    ".mkv",
    ".avi",
    ".webm",
    ".m4v",
    ".mpg",
    ".mpeg",
    ".wmv",
    ".flv",
}


def run_ffmpeg(
    src: Path,
    dst_webm: Path,
    args: argparse.Namespace,
    ffmpeg_path: str,
    ffmpeg_lib_dir: str | None,
) -> None:
    cmd = [
        ffmpeg_path,
        "-y" if args.force else "-n",
        "-i",
        str(src),
        "-c:v",
        "libvpx-vp9",
        "-b:v",
        "0",
        "-crf",
        str(args.crf),
        "-row-mt",
        "1",
        "-deadline",
        args.deadline,
        "-cpu-used",
        str(args.cpu_used),
    ]

    if args.audio:
        cmd += ["-c:a", "libopus", "-b:a", f"{args.audio_bitrate}k"]
    else:
        cmd += ["-an"]

    cmd += [str(dst_webm)]

    env = os.environ.copy()
    if ffmpeg_lib_dir:
        if os.name == "nt":
            env["PATH"] = ffmpeg_lib_dir + os.pathsep + env.get("PATH", "")
        elif sys.platform == "darwin":
            env["DYLD_LIBRARY_PATH"] = ffmpeg_lib_dir + os.pathsep + env.get("DYLD_LIBRARY_PATH", "")
        else:
            env["LD_LIBRARY_PATH"] = ffmpeg_lib_dir + os.pathsep + env.get("LD_LIBRARY_PATH", "")

    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed for {src}\n{proc.stdout}")


def wrap_webm_to_video(src_webm: Path, dst_video: Path, force: bool) -> None:
    if dst_video.exists() and not force:
        raise FileExistsError(f"Output exists: {dst_video}")

    size = src_webm.stat().st_size
    header = HEADER_STRUCT.pack(MAGIC, VERSION, size)

    with src_webm.open("rb") as fin, dst_video.open("wb") as fout:
        fout.write(header)
        shutil.copyfileobj(fin, fout, length=1024 * 1024)


def iter_inputs(src: Path, recursive: bool) -> list[Path]:
    if src.is_file():
        return [src]

    if not src.is_dir():
        raise FileNotFoundError(f"Input path not found: {src}")

    pattern = "**/*" if recursive else "*"
    files = [p for p in src.glob(pattern) if p.is_file() and p.suffix.lower() in VIDEO_EXTS]
    return sorted(files)


def resolve_ffmpeg(args: argparse.Namespace) -> tuple[str, str | None]:
    if args.ffmpeg:
        return args.ffmpeg, None

    tool_root = Path(__file__).resolve().parent
    bundled = tool_root / "third_party" / "ffmpeg" / "bin" / "ffmpeg"
    if os.name == "nt":
        bundled = bundled.with_suffix(".exe")
    if bundled.exists():
        lib_dir = (tool_root / "third_party" / "ffmpeg" / "lib")
        return str(bundled), (str(lib_dir) if lib_dir.exists() else None)

    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise FileNotFoundError("ffmpeg not found in PATH (or use --ffmpeg)")
    return ffmpeg, None


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert videos to WebM (VP9) and wrap into .video")
    parser.add_argument("src", type=Path, help="Input file or directory")
    parser.add_argument("out", type=Path, help="Output directory")
    parser.add_argument("--recursive", action="store_true", help="Scan input directory recursively")
    parser.add_argument("--keep-webm", action="store_true", help="Keep intermediate .webm files")
    parser.add_argument("--force", action="store_true", help="Overwrite outputs if they exist")
    parser.add_argument("--ffmpeg", type=str, default="", help="Path to ffmpeg binary (optional)")

    # VP9 settings
    parser.add_argument("--crf", type=int, default=30, help="VP9 quality (lower=better, 15-40 typical)")
    parser.add_argument("--deadline", default="good", choices=["realtime", "good", "best"], help="Encoding deadline")
    parser.add_argument("--cpu-used", type=int, default=4, help="VP9 speed/quality tradeoff (0-8)")

    # Audio
    parser.add_argument("--audio", action="store_true", help="Keep audio (Opus)")
    parser.add_argument("--audio-bitrate", type=int, default=128, help="Opus bitrate in kbps")

    args = parser.parse_args()

    ffmpeg_path, ffmpeg_lib_dir = resolve_ffmpeg(args)
    print(f"Using ffmpeg: {ffmpeg_path}")
    if ffmpeg_lib_dir:
        print(f"Using ffmpeg libs: {ffmpeg_lib_dir}")
    print("Note: If you bundle ffmpeg, see THIRD_PARTY.md for licensing requirements.")

    inputs = iter_inputs(args.src, args.recursive)
    if not inputs:
        print("No input videos found.")
        return 1

    args.out.mkdir(parents=True, exist_ok=True)

    for src in inputs:
        rel = src.name
        stem = Path(rel).stem
        webm_path = args.out / f"{stem}.webm"
        video_path = args.out / f"{stem}.video"

        run_ffmpeg(src, webm_path, args, ffmpeg_path, ffmpeg_lib_dir)
        wrap_webm_to_video(webm_path, video_path, args.force)

        if not args.keep_webm:
            try:
                webm_path.unlink()
            except FileNotFoundError:
                pass

        print(f"Built {video_path}")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(2)
