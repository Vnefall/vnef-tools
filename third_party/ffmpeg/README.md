# FFmpeg Bundling Checklist

If you ship FFmpeg binaries alongside vnef-tools or your game:

1. Place the FFmpeg executable in `third_party/ffmpeg/bin/`.
2. Include the correct license text:
   - `LICENSE.LGPL` (if built without GPL/nonfree)
   - or `LICENSE.GPL` (if built with GPL parts)
3. Include `build_flags.txt` with the exact `./configure` flags.
4. Provide the **exact source** used to build the binary:
   - either place the source archive in `third_party/ffmpeg/source/`
   - or include a `SOURCE_URL.txt` pointing to the exact tarball

This keeps you compliant with FFmpeg’s licensing requirements.
