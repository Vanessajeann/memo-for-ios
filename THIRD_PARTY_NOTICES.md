# Third-party components

## FFmpeg 7.1.5

- Upstream: https://github.com/FFmpeg/FFmpeg
- Commit: `3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587` (`n7.1.5`).
- Libraries: libavformat, libavcodec, libavutil. Static linkage; no GPL, nonfree or version3-only configure option enabled.
- License: GNU Lesser General Public License version 2.1 or later, plus the notices and component licenses in the complete upstream source.
- Configuration: `scripts/build-ffmpeg.sh`; only required protocols, demuxers, parsers, native decoders, bitstream filters and Matroska/MP4 muxers are enabled. No re-encoding is performed by MemoCapture.
- Modifications: `scripts/patch-ffmpeg.py` enables peer certificate verification by default and makes custom cookies exact-host scoped (ignoring an HTTP port) with an explicit secure-transport guard. The build fails if the pinned source layout changes.

Each recording-build artifact includes `Memo-relink-materials.tar.gz`: the actual patched FFmpeg source and license texts, iOS static libraries/headers, application source and generated application object files. These allow replacing/relinking the LGPL component using a compatible Apple toolchain. Relinking or signing does not require disclosing the user's private certificate to this project.

To rebuild: install Xcode 16.4+ and XcodeGen, then execute `bash scripts/build-ios.sh`. To replace the LGPL implementation, adjust the pinned source/configuration, regenerate its libraries with a compatible ABI, and relink the application using the supplied object files and Xcode build/link settings; alternatively rebuild the supplied MIT application source. Re-sign the resulting app with your own valid identity and provisioning profile. Reverse engineering/debugging of modifications to the LGPL library is permitted by its license.

The original Android Memo MIT license is preserved in LICENSE. No binary or extracted code from the original third-party IPA is incorporated into this implementation.

## Platform and UI port (0.3.0)

The Swift platform models and webpage observer are ported from Memo 3.2.0-beta1, commit 4327a64e45bd4ff88d99e022d1afde6335593270 (MIT). The original research attribution is retained: yt-dlp Bilibili extractor (Unlicense), https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/bilibili.py; Douyin response schema references https://github.com/Johnserf-Seed/f2 and https://github.com/JoeanAmier/TikTokDownloader. No third-party signing algorithm or parsing service is bundled. WKWebView, AVFoundation, Network and URLSession are system frameworks.
