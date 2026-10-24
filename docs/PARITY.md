# 完整功能验收范围

目标为 Memo 3.2.0-beta1 全部功能与原直播录制器直链能力。开发验证包不缩减最终范围。必须区分源码实现、CI 编译通过、真机验证通过；下表“已写入”不代表真机通过。

| 模块 | 必须保留的能力 | 当前状态 |
|---|---|---|
| 源管理 | 最多九路，增删改，名称、地址、请求头，去重，画质 ID | 核心和界面已写入 |
| 源备份 | MemoSources v1，Android JSON 导入导出，Cookie/Referer/agent/qualityId | 已写入 |
| 预览 | 九路、放大、全屏、静音／声音、列表／网格 | 仅单路无请求头 HLS 预览已写入 |
| 协议 | HLS、HTTP-FLV、RTMP(S)、RTSP | FFmpeg 待接入 |
| 抖音直播 | 短链／分享文案，重新取源，原画选择，验证／未开播提示 | 待移植 DouyinResolver |
| Bilibili 直播 | 房间解析、会话复用、实际开放画质、HLS／FLV | 待移植 BiliApi/BiliModel |
| 录制 | 多路独立开始／停止／停止全部，原流保存 | 待移植 RecorderService |
| 恢复 | 卡流、媒体进度、网络切换、重连分段、异常保存 | 重试策略已写入，引擎未接入 |
| 封装 | MKV→无转码 MP4，AAC 兼容，失败保留 MKV | 待移植 RecordingCommand |
| 诊断 | 错误分类、每路诊断／复制、脱敏 | 待移植 RecordingDiagnostics |
| 抖音作品 | 博主主页、分页／全部／暂停、搜索、选择、列表／网格、清空 | 待移植 WorksModel/WorksPanel |
| 视频／图集 | 可用无水印原文件、原图顺序、预览、失败补齐 | 待移植 |
| 抖音会话 | 官方网页登录／验证、数据观察、管理与退出 | 待改写为 WKWebView |
| Bilibili 点播 | BV/AV、分享／短链、UP 主页、分 P、搜索／选择／分页 | 待移植 BiliApi/BiliPanel |
| Bilibili 媒体 | 当前会话画质、独立音轨、DASH 下载和无转码合成、合成预览 | 待移植 DashCommand |
| Bilibili 登录 | 官方网页登录、会话验证、独立退出 | 待移植 BiliSession |
| 队列 | 排队、进度、取消、重试、持久化、重开状态恢复 | 待移植 DownloadService |
| 文件 | 录像列表、回看、批量导出／分享／删除、导入、相册／Files | 待移植 MediaTransfer/MediaExport |
| 界面 | 玻璃效果、动效、前后台资源释放、导航布局 | 初始 SwiftUI 已写入 |
| 后台 | 锁屏、切 App、音频中断、长录、低电量、资源压力 | 待集成与真机专项验证 |

平台接口沿用上游会话权限边界，不假装取得未开放档位。上游暂不支持的付费专用入口、DRM、仅试看内容、多段 durl 等不标为支持。

原 IPA 的 FFmpeg 字符串不能证明所有协议可用。按输入协议、封装、编解码和服务器请求头分别测试，保留原版九路、预览、静音、全屏、录制及文件管理语义。
