# Memo for iOS

将 [Memo 3.2.0-beta1](https://github.com/Vanessajeann/Memo/tree/v3.2.0-beta1) 全部功能移植到 iPhone / iPad。首要目标：**iPhone 16 Pro Max / iOS 18.6.2**，用户在本地自行签名安装。

## 当前状态

**0.3.0 平台功能与 UI 移植测试版。已补入平台业务代码，真实账号／平台接口与长期后台仍需设备验收。**

- 对标原版四页导航：直播、录像、作品、设置；九个固定玻璃卡片、列表／网格、深色模式和大字体布局。
- 抖音与 Bilibili 直播分享解析、实际可用画质，重连时重新获取媒体地址；保留 HLS、HTTP-FLV、RTMP(S)、RTSP 原流录制，最多九路独立停止和重连分段。
- 官方 WKWebView 登录、会话复用、独立退出；抖音博主主页作品与原图图集；Bilibili BV／AV／短链／UP 主页／分 P／实际可用画质与音轨。
- 搜索、勾选、批量下载、分页、获取全部／暂停、结果清空；持久化队列、系统后台文件下载、图集已完成页复用。Bilibili 执行前刷新媒体，指定画质不自动降档。
- 视频和音轨原字节保存，DASH 音视频无转码合成。录像和图片可回看、缩放、批量分享、导出至 Files、保存相册和删除；支持多文件录像导入。
- HLS 自动静音小窗与全屏预览；本机随机路径 HLS relay 为平台预览附带 Referer／User-Agent，Cookie 只给选中源同主机同协议；切 App 或页面释放小窗，不影响独立录制。
- Android MemoSources v1 备份兼容；Cookie 不写入作品和下载队列。媒体传输只接受匹配平台的 HTTPS CDN。

**仍须真机验收**：官方登录和平台验证、账号实际权限、真实主页完整分页、多路预览／录制稳定性、音频中断、长期锁屏、相册格式支持和重签安装。非 HLS 媒体仍可录制，当前预览依赖系统兼容 HLS，并未实现 FFmpeg 全协议视频渲染。iOS 的系统后台下载与实时直播录制分开；无声音频后台录制仅有有限系统时间，强制退出后不保证直播连续。详见 [PARITY.md](docs/PARITY.md)。

验证覆盖原生合成媒体、DASH 音视频包保持不变、取消与禁止覆盖、Core 平台解析／权限边界和 WK observer；CI 另构建模拟器并捕获 iPhone 16 Pro Max 的四页及深色界面。

## 下载每个版本

每个成功的 main 分支构建都会直接发布到 [Releases](https://github.com/Vanessajeann/memo-for-ios/releases)，标签格式为 `ios-v<版本>-build.<构建号>`。失败的构建不会发布 IPA；重跑不会覆盖已发布附件。

目前均标记为预发布版。Release 附件包括未签名 IPA、SHA256SUMS.txt、构建信息以及 LGPL 完整源码／重新链接材料。核对校验值后，用自己的证书与匹配描述文件重签安装。无需向仓库上传证书和密码。

原 0.1.0 预览验证版单独补发，明确标记为没有录制引擎；新录制测试版不与它混淆。Actions 的临时构建附件仍保留用于诊断。

## 本地构建

需要 macOS、Xcode 16.4+（iOS 18 SDK）和 XcodeGen 2.46+：

```bash
brew install xcodegen ffmpeg
bash scripts/build-ios.sh
```

也可执行 `xcodegen generate` 后在 Xcode 打开 Memo.xcodeproj，设置自己的 Team 并真机运行。Core 测试：`swift test --package-path MemoCore`。

## 上游基线

基于 `Vanessajeann/Memo` 的 **pre-view / v3.2.0-beta1**，提交 `4327a64e45bd4ff88d99e022d1afde6335593270`，不是仍处于 3.1 基线的 main。上传 APK 的 SHA-256 与该 Release 一致。版本与文件哈希见 [upstream.json](reference/upstream.json)。Android 仓库保持原样。

## 后台与隐私

锁屏、切 App 长录是核心验收目标。iOS 18 后台音频用于真实媒体播放，声明权限不保证拉流不断；普通后台文件下载与实时直播录制分开设计。不循环静音音频保活，不依赖 iOS 26 专用 API。上划关闭、系统终止和重启不保证持续录制，已收到片段需保存，恢复时准确记录缺口。见 [BACKGROUND.md](docs/BACKGROUND.md)。

源链接和请求头保存在设备内；导出备份含 Cookie，会先提示。不要向此公开仓库提交真实 Cookie、私人源备份、录像和签名材料。当前无解析服务器。

## 许可

自有源码采用 MIT，保留上游 Memo 许可。FFmpeg 7.1.5 的来源、配置、补丁和 LGPL 重新链接材料见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。每次构建附带完整源码、库和应用对象文件。
