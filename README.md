# vnef-tools

Build-time utilities for VNEF media.

## build_videos.py
Converts input videos to **VP9 WebM** and wraps them into a simple `.video` container:

- 4 bytes magic: `VID0`
- 4 bytes version (uint32 LE, `1`)
- 8 bytes webm size (uint64 LE)
- raw WebM bytes

### Usage
```bash
./build_videos.py <input-file-or-dir> <output-dir> --recursive
```

Common options:
- `--audio` keep audio (Opus)
- `--keep-webm` keep intermediate `.webm`
- `--force` overwrite outputs

Requires `ffmpeg` in PATH.
