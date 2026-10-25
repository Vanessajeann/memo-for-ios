#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-ffmpeg.sh simulator > build/logs/ffmpeg-simulator.log 2>&1
xcodebuild -project Memo.xcodeproj -scheme Memo -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/build/SimulatorData" \
  MEMO_FFMPEG_ROOT="$PWD/build/ffmpeg-simulator" ARCHS="$(uname -m)" \
  CODE_SIGNING_ALLOWED=NO build > build/logs/simulator-build.log 2>&1
runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and "iOS-18" in x["identifier"]]; assert r; print(sorted(r)[-1])')"
device="$(xcrun simctl create Memo-UI-Capture com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max "$runtime")"
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl status_bar "$device" override --time '09:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$device" build/SimulatorData/Build/Products/Release-iphonesimulator/Memo.app
mkdir -p outputs/ui
for tab in 0 1 2 3; do
  xcrun simctl terminate "$device" app.memo.ios >/dev/null 2>&1 || true
  SIMCTL_CHILD_MEMO_UI_TAB="$tab" SIMCTL_CHILD_MEMO_UI_CAPTURE=1 xcrun simctl launch "$device" app.memo.ios
  sleep 3
  xcrun simctl io "$device" screenshot "outputs/ui/tab-$tab.png"
done
xcrun simctl ui "$device" appearance dark
xcrun simctl terminate "$device" app.memo.ios
SIMCTL_CHILD_MEMO_UI_TAB=0 SIMCTL_CHILD_MEMO_UI_CAPTURE=1 xcrun simctl launch "$device" app.memo.ios
sleep 3
xcrun simctl io "$device" screenshot outputs/ui/live-dark.png
xcrun simctl ui "$device" appearance light
xcrun simctl terminate "$device" app.memo.ios
container="$(xcrun simctl get_app_container "$device" app.memo.ios data)"
fixture="$(python3 -c 'from pathlib import Path; print(sorted(Path("build/native-tests/media").glob("run-*/input.mp4"))[-1])')"
mkdir -p "$container/Documents/Recordings"
for item in 1 2 3; do cp "$fixture" "$container/Documents/Recordings/测试录像-$item.mp4"; done
SIMCTL_CHILD_MEMO_UI_TAB=1 SIMCTL_CHILD_MEMO_UI_CAPTURE=1 SIMCTL_CHILD_MEMO_UI_LIBRARY_SELECTION=1 xcrun simctl launch "$device" app.memo.ios
sleep 3
xcrun simctl io "$device" screenshot outputs/ui/library-selection.png
