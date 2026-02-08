# vnef-tools

Build-time utilities for VNEF media.

## build_videos (Odin)
Converts input videos to **VP9 WebM** and wraps them into a simple `.video` container:

- 4 bytes magic: `VID0`
- 4 bytes version (uint32 LE, `1`)
- 8 bytes webm size (uint64 LE)
- raw WebM bytes

### Usage
```bash
# Run directly
odin run build_videos.odin -file -- <input-file-or-dir> <output-dir> --recursive

# Or build a binary
odin build build_videos.odin -out:build_videos
./build_videos <input-file-or-dir> <output-dir> --recursive
```

Common options:
- `--audio` extract audio to `.ogg` (Opus)
- `--audio-out <dir>` output directory for extracted audio
- `--keep-webm` keep intermediate `.webm`
- `--force` overwrite outputs
- `--ffmpeg /path/to/ffmpeg` use a specific ffmpeg binary

Requires `ffmpeg` in PATH (or bundled under `third_party/ffmpeg`).

### Suggested layout (Vnefall)
- Source videos: `demo/assets/videos_src/` (mp4/webm)
- Generated videos: `demo/runtime/videos/` (`.video`)
- Extracted audio: `demo/runtime/video_audio/` (`.ogg`)

## build_videos.py (legacy)
Python fallback with the same behavior. Prefer the Odin tool.

### Licensing (FFmpeg)
If you bundle FFmpeg binaries, follow the checklist in `THIRD_PARTY.md`
and `third_party/ffmpeg/README.md`.
