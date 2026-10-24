#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-ffmpeg.sh host
mkdir -p build/native-tests
flags=(-std=c11 -D_DEFAULT_SOURCE -DMEMO_NATIVE_TEST -I Native -I build/ffmpeg-host/include
  Native/MemoCapture.c tests/native-harness.c -L build/ffmpeg-host/lib
  -lavformat -lavcodec -lavutil -lm -lpthread)
if [ "$(uname -s)" = Darwin ]; then
  flags+=(-framework Security -framework CoreFoundation)
fi
cc "${flags[@]}" -o build/native-tests/harness
python3 tests/native-media.py build/native-tests/harness build/native-tests/media
