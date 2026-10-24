#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'iOS archive requires macOS and Xcode. Use the GitHub Actions workflow.' >&2
  exit 1
fi
mkdir -p build/logs outputs
{
  echo 'Memo iOS platform and UI port beta — device acceptance pending'
  echo "Commit: $(git rev-parse HEAD)"
  echo "Build: ${GITHUB_RUN_NUMBER:-1}"
  xcodebuild -version
  xcrun swift --version
  xcodegen --version
} | tee outputs/BUILD-INFO.txt
node tests/works-observer.cjs App/works-observe.js
swift test --package-path MemoCore 2>&1 | tee build/logs/core-tests.log
bash scripts/test-native.sh 2>&1 | tee build/logs/native-tests.log
bash scripts/build-ffmpeg.sh ios 2>&1 | tee build/logs/ffmpeg-ios.log
python3 scripts/prepare-assets.py
xcodegen generate 2>&1 | tee build/logs/project.log
xcodebuild -project Memo.xcodeproj -scheme Memo -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$PWD/build/Memo.xcarchive" \
  -derivedDataPath "$PWD/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  archive 2>&1 | tee build/logs/archive.log
python3 scripts/package-ipa.py
python3 scripts/package-relink.py
(cd outputs && shasum -a 256 Memo-ios-port-beta-unsigned.ipa Memo-relink-materials.tar.gz > SHA256SUMS.txt)
{
  echo '### Memo iOS development build'
  echo 'Unsigned platform/UI port beta (original media and FFmpeg stream copy).'
  echo 'Official login, platform permissions, background capture and multi-stream stability need device testing.'
  echo 'Re-sign locally. No signing certificate is stored in this repository.'
} >> "${GITHUB_STEP_SUMMARY:-build/logs/summary.md}"
