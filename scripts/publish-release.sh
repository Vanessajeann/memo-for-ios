#!/bin/bash
set -euo pipefail
mkdir -p release-assets
gh run download "$MEMO_RUN_ID" --repo "$GH_REPO" \
  --name "Memo-iOS-port-beta-unsigned-$MEMO_RUN_NUMBER" --dir release-assets
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

平台功能与 UI 移植测试版，对标 Android Memo 3.2.0-beta1；目标 iPhone 16 Pro Max / iOS 18.6.2。IPA 未签名，请使用自己的有效证书和描述文件重签。

- 四页导航：直播、录像、作品、设置；九格玻璃卡片、自动 HLS 预览、深色模式与大字体布局。
- 抖音／Bilibili 直播分享解析、当前会话画质，录制重连时重新取源；保留 HLS、HTTP-FLV、RTMP(S)、RTSP 原流录制。
- 官方网页登录与独立退出；抖音主页／视频／图集，Bilibili BV／AV／短链／UP 主页／分 P／实际可用画质。
- 搜索、列表／网格、分页／获取全部／暂停、选择与批量下载；持久化队列、iOS 后台文件传输、图集已完成页复用。
- 视频与音轨原字节下载、DASH 无转码合成；批量分享、相册、Files、图片浏览与缩放、源备份兼容。
- 真实 HLS 音频收听与有限后台时间处理；非 HLS 可录制，当前预览需要系统兼容的 HLS。

**验证边界**：真实账号登录／验证、平台接口权限、完整真实主页、多路预览稳定性及长时间锁屏录制仍需真机验收。iOS 强制退出后不保证直播不断；系统后台下载与实时录制是不同机制。沿用原版对试看／加密／多段 durl／付费专用入口的限制。

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
