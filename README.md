# Memo for iOS

将 [Memo 3.2.0-beta1](https://github.com/Vanessajeann/Memo/tree/v3.2.0-beta1) 全部功能移植到 iPhone / iPad。首要目标：**iPhone 16 Pro Max / iOS 18.6.2**，用户在本地自行签名安装。

## 当前状态

**开发初期，尚未完成全功能移植。** 首份 `Memo-dev-bootstrap-unsigned.ipa` 仅用于构建、源管理、Android 源备份兼容和 HLS 直链预览验证，暂不能作为直播录制工具。

已写入：SwiftUI 工程、九路源管理与网格／列表、增删改、JSON 导入导出、单路 HLS 预览、真实音频播放会话、核心校验与重试策略测试、macOS 构建和未签名 IPA 打包。

待移植：FFmpeg 多协议与多路录制、平台解析、抖音作品与图集、Bilibili 分 P／画质／音轨／DASH、下载队列、录像整理与系统导出。完整范围见 [PARITY.md](docs/PARITY.md)。**编译成功不表示录制完成。**

## 获取开发构建

Actions → iOS development build，成功后下载 Artifacts 中的 `Memo-iOS-dev-bootstrap-unsigned-<编号>`。解压后核对 SHA256SUMS.txt，再用自己的证书和匹配描述文件重签 IPA。当前包不包含推送／App Group 扩展。

不需要向仓库或工作流上传 p12、密码和描述文件，不自动发布正式 Release。证书只用于安装，不改变 iOS 后台限制。

## 本地构建

需要 macOS、Xcode 16.4+（iOS 18 SDK）和 XcodeGen 2.46+：

```bash
brew install xcodegen
bash scripts/build-ios.sh
```

也可执行 `xcodegen generate` 后在 Xcode 打开 Memo.xcodeproj，设置自己的 Team 并真机运行。Core 测试：`swift test --package-path MemoCore`。

## 上游基线

基于 `Vanessajeann/Memo` 的 **pre-view / v3.2.0-beta1**，提交 `4327a64e45bd4ff88d99e022d1afde6335593270`，不是仍处于 3.1 基线的 main。上传 APK 的 SHA-256 与该 Release 一致。版本与文件哈希见 [upstream.json](reference/upstream.json)。Android 仓库保持原样。

## 后台与隐私

锁屏、切 App 长录是核心验收目标。iOS 18 后台音频用于真实媒体播放，声明权限不保证拉流不断；普通后台文件下载与实时直播录制分开设计。不循环静音音频保活，不依赖 iOS 26 专用 API。上划关闭、系统终止和重启不保证持续录制，已收到片段需保存，恢复时准确记录缺口。见 [BACKGROUND.md](docs/BACKGROUND.md)。

源链接和请求头保存在设备内；导出备份含 Cookie，会先提示。不要向此公开仓库提交真实 Cookie、私人源备份、录像和签名材料。当前无解析服务器。

## 许可

自有源码采用 MIT，保留上游 Memo 许可。当前 iOS 包尚未引入 FFmpeg；引入时需提供准确版本、组件选项、来源、许可证与适用的重新链接材料。
