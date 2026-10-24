#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-ios}"
source_commit=3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587
fingerprint="$(python3 -c 'import hashlib; from pathlib import Path; print(hashlib.sha256(Path("scripts/build-ffmpeg.sh").read_bytes()+Path("scripts/patch-ffmpeg.py").read_bytes()).hexdigest())')"
build_key="$source_commit-$fingerprint"
source_dir="$PWD/build/ffmpeg-source"
prefix="$PWD/build/ffmpeg-$target"
if [ -f "$prefix/.memo-commit" ] && [ "$(cat "$prefix/.memo-commit")" = "$build_key" ]; then
  exit 0
fi
mkdir -p build
if [ ! -d "$source_dir/.git" ]; then
  git init "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/FFmpeg/FFmpeg.git
fi
git -C "$source_dir" fetch --depth 1 origin "$source_commit"
git -C "$source_dir" checkout --detach FETCH_HEAD
test "$(git -C "$source_dir" rev-parse HEAD)" = "$source_commit"
python3 scripts/patch-ffmpeg.py "$source_dir"
mkdir -p "build/ffmpeg-work-$target"
cd "build/ffmpeg-work-$target"
flags=(--prefix="$prefix" --disable-autodetect --disable-asm --disable-programs
  --disable-doc --disable-debug --enable-pic --disable-shared --enable-static
  --disable-avdevice --disable-avfilter --disable-swresample --disable-swscale
  --disable-postproc --disable-everything --enable-network
  --enable-protocol=file,http,https,tcp,tls,crypto,rtmp,rtmps,rtmpt,rtmpts,rtp,udp
  --enable-demuxer=mov,matroska,flv,hls,mpegts,aac,rtsp,rtp
  --enable-muxer=matroska,mp4
  --enable-parser=aac,h264,hevc,mpegaudio,opus,av1,vp9
  --enable-decoder=aac,h264,hevc,mp3,opus
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,null)
if [ "$target" = ios ]; then
  sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
  flags+=(--enable-cross-compile --target-os=darwin --arch=aarch64
    --cc="$(xcrun --sdk iphoneos --find clang)" --sysroot="$sdk"
    --extra-cflags='-arch arm64 -miphoneos-version-min=18.0'
    --extra-ldflags='-arch arm64 -miphoneos-version-min=18.0'
    --enable-securetransport)
elif [ "$target" = host ]; then
  if [ "$(uname -s)" = Darwin ]; then
    flags+=(--enable-securetransport --cc="$(xcrun --sdk macosx --find clang)"
      --sysroot="$(xcrun --sdk macosx --show-sdk-path)")
  fi
else
  echo "Unsupported target: $target" >&2; exit 1
fi
"$source_dir/configure" "${flags[@]}"
make -j 4
make install
printf '%s\n' "$build_key" > "$prefix/.memo-commit"
# Relinking materials accompany each IPA artifact (LGPL static libraries).
cp "$source_dir/COPYING.LGPLv2.1" "$prefix/"
