#!/bin/bash
set -euo pipefail
mkdir -p release-assets
gh run download "$MEMO_RUN_ID" --repo "$GH_REPO" \
  --name "Memo-iOS-direct-recording-test-unsigned-$MEMO_RUN_NUMBER" --dir release-assets
(cd release-assets && sha256sum --check SHA256SUMS.txt)
version="$(python3 - <<'PY'
import plistlib,re,zipfile
from pathlib import Path
files=list(Path('release-assets').glob('*.ipa'))
assert len(files)==1
with zipfile.ZipFile(files[0]) as z:
    info=plistlib.loads(z.read('Payload/Memo.app/Info.plist'))
v=info['CFBundleShortVersionString']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',v)
print(v)
PY
)"
tag="ios-v$version-build.$MEMO_RUN_NUMBER"
if gh release view "$tag" --repo "$GH_REPO" >/dev/null 2>&1; then
  echo "Release $tag already exists; existing assets are unchanged."
  exit 0
fi
cat > release-assets/RELEASE-NOTES.md <<EOF
## Memo iOS $version · build $MEMO_RUN_NUMBER

直链录制测试版，目标 iPhone 16 Pro Max / iOS 18.6.2。IPA 未签名，安装前请使用自己的有效证书与描述文件重签。

- 原流录制、独立停止、有限重连，MKV 采集后整理 MP4；失败保留原片。
- 源管理、Android 源备份兼容、HLS 预览、录像回看／分享／导入／相册保存。
- 真实 HLS 音频收听与有限后台时间处理；后台长录、多路稳定性仍需真机验证。
- 抖音／Bilibili 分享解析与作品下载等完整功能仍在移植。

发布前已通过核心测试、原生媒体测试、arm64 编译归档和打包校验。这不代表真机录制专项测试已经完成。

附件包含 IPA、SHA256SUMS.txt、构建信息与 LGPL 完整源码／重新链接材料。

提交：$MEMO_COMMIT

构建：https://github.com/$GH_REPO/actions/runs/$MEMO_RUN_ID
EOF
gh release create "$tag" release-assets/*.ipa release-assets/*.tar.gz \
  release-assets/SHA256SUMS.txt release-assets/BUILD-INFO.txt \
  --repo "$GH_REPO" --target "$MEMO_COMMIT" \
  --title "Memo iOS $version · build $MEMO_RUN_NUMBER" \
  --prerelease --notes-file release-assets/RELEASE-NOTES.md
