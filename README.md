# Memo for iOS

将 [Memo 3.2.0-beta1](https://github.com/Vanessajeann/Memo/tree/v3.2.0-beta1) 全部功能移植到 iPhone / iPad。首要目标：**iPhone 16 Pro Max / iOS 18.6.2**，用户在本地自行签名安装。

## 当前状态

**0.2.0 直链录制测试版，尚未完成全部平台功能移植。**

- HLS、HTTP-FLV、RTMP(S)、RTSP 直链：FFmpeg stream copy，最多九路独立开始／停止、停止全部，有限次数重连。
- 先写 MKV，再无转码整理为 MP4；整理失败保留 MKV，支持手动重新整理。取消整理不会将部分文件当成完整 MP4 发布。
- 录像列表、MP4 回看、分享／另存、导入和相册保存。录制或整理中的文件不能删除。
- 源管理、Android JSON 备份兼容、请求头校验、Cookie 的主机范围限制和默认 TLS 证书验证。
- 单路 HLS 预览；长按直播源可开启真实后台收听（有音轨、无需自定义请求头的 HLS）。无声录制仅申请有限后台时间，到期停止并尽量保留片段。

仍待移植：抖音／Bilibili 分享解析、作品与图集、分 P／画质／音轨／DASH、完整下载队列、九路自动预览及全部视觉细节。完整范围见 [PARITY.md](docs/PARITY.md)。后台长录、iPhone 安装和多路稳定性需要真机专项验证，不能由 CI 编译或桌面媒体测试代替。

本地媒体测试覆盖 HTTP/HLS 采集、音视频包不变、MP4 解码、鉴权、跨主机重定向、读阻塞取消、已写片段停止、禁止覆盖、失败保片和取消合成；macOS CI 会重跑这些测试。

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
