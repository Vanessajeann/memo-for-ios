# iOS 18.6.2 后台验收

已接入独立 FFmpeg 录制任务、HLS 真实音频收听和有限后台时间处理。audio 权限不是长期录制完成证明。

前台录制时点直播卡片右上角的 `···`，选择“后台收听”，实际直播音频会播放。设置页显示音轨检测、缓冲和实际收听状态；等“正在收听直播音频”后再锁屏。有音轨且播放器正在播放时，使用合法音频后台模式；缓冲、来电或暂停后申请有限后台时间，到期停止采集并尽量保留 MKV。未开启收听、FLV/RTMP/RTSP 或无音轨场景不能保证长期后台，切回前台后可整理保留的片段。所有持续性与中断行为均需脱离调试器真机测试。

0.3.1 修复 HLS 音轨误判：不再把播放前 `AVURLAsset.loadTracks(.audio)` 返回空数组当作无音轨；由独立、可取消、有限时的 FFmpeg 探测检查真实音频包，不生成文件，也不影响录制句柄。网络失败与取消返回错误，只有成功识别视频且未发现音频流才提示无音轨。播放器失败、结束和启动超时会清理收听状态；切源／停止会取消旧探测并隔离过期回调。系统播放器采用公开的 `continuesIfPossible` 后台策略。这些修复不代表长期锁屏验收完成。

## 实现要求

- 拉流与文件写入独立于界面生命周期，关闭预览不能停止用户明确启动的录制。
- stream copy、低内存、分段落盘、失败保留可恢复片段。
- 有限文件下载使用后台 URLSession 时，持久化任务映射与过期链接处理，完成后合成不能依赖前台定时器。
- 静音录制、无音轨、多路及另一 App 抢占音频单独验证；不以循环静音音频或伪装 VoIP 保活。
- 不依赖 iOS 26 的 BGContinuedProcessingTask；自签不会解锁无限后台。
- 上划关闭／系统终止／重启不保证不断流，重开恢复时准确记录缺口。

## 真机矩阵

使用 Release 构建并脱离调试器，检查实际文件增长、时长、声画同步、时间轴缺口与结束原因。

| 场景 | 验证内容 |
|---|---|
| 前台 1/3/9 路 | 并发、内存、发热、文件完整性 |
| 锁屏 10/30/120 分钟 | 实际媒体连续性 |
| 切 App／其他 App 发声／来电 | 中断处理及恢复 |
| 无音轨／静音目标 | 实际后台可达边界 |
| Wi-Fi↔蜂窝／断网／链接过期 | 重连、重新取源、片段保护 |
| 低电量／空间不足／资源压力 | 可靠结束、保留原片 |
| 强制退出／重启 | 重开恢复、缺口展示 |

官方依据：

- https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback
- https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)
- https://developer.apple.com/videos/play/wwdc2025/227/
