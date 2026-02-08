# Third-Party Notes

This tool relies on **FFmpeg** to transcode source videos into WebM (VP9).

If you **bundle FFmpeg binaries** with your game/tools, you must comply with
FFmpeg’s license terms (LGPL/GPL). This typically means:

- Ship FFmpeg as a separate executable (preferred).
- Include the **exact license text** that applies to your FFmpeg build.
- Provide the **exact FFmpeg source** (or a link to the exact source archive)
  and the **build flags** used to produce the binary.

Recommended layout (if you bundle):

```
third_party/ffmpeg/
  bin/ffmpeg[.exe]
  LICENSE.(LGPL|GPL)
  build_flags.txt
  source/ (or a link file)
```

See `third_party/ffmpeg/README.md` for a checklist.
